-- backend/cmux.lua — cmux backend implementation
--
-- When backend="cmux", this module replaces the agent-deck CLI as the session
-- management engine. Instead of delegating to an external daemon, the Neovim
-- plugin directly creates cmux surfaces, sends commands, and tracks metadata
-- in persist.lua.
--
-- cmux is a native macOS terminal app with a CLI + Unix socket API. Sessions
-- run in cmux's own GPU-accelerated UI (libghostty) rather than in Neovim
-- terminal buffers.
--
-- CLI command mapping (cmux v0.63+):
--   tree --all --json       → list all surfaces across workspaces
--   send --surface <id>     → send text to a surface
--   send-key --surface <id> → send keypress (enter, ctrl+c, etc.)
--   new-split <dir>         → create split; returns "OK surface:X workspace:Y"
--   new-workspace --name    → create workspace; returns "OK workspace:X"
--   close-surface --surface → close a surface
--   read-screen --surface   → read terminal output
--   select-workspace        → switch to workspace (for focus)
--   close-workspace         → close a workspace
--
-- Spawn pattern: identical to cli.lua — vim.uv.spawn + stdout pipe +
-- vim.schedule for Neovim API safety.
local M = {}

local log         = require("agent-deck.logger")
local persist     = require("agent-deck.persist")
local ansi        = require("agent-deck.backend.ansi")
local cmux_status = require("agent-deck.backend.cmux_status")

-- ── Binary resolution ─────────────────────────────────────────────────────────
local _bin = vim.fn.exepath("cmux")
if _bin == "" then
  -- cmux ships its CLI inside the app bundle; check common locations
  local fallbacks = {
    "/Applications/cmux.app/Contents/Resources/bin/cmux",
    "/usr/local/bin/cmux",
  }
  for _, fb in ipairs(fallbacks) do
    if vim.fn.executable(fb) == 1 then
      _bin = fb
      break
    end
  end
  if _bin == "" then
    _bin = "cmux"  -- last resort; will surface spawn-failed error
  end
end
log.info("cmux backend: resolved binary → " .. _bin)

-- ── Low-level async spawn ─────────────────────────────────────────────────────

--- Spawn the cmux binary with the given args list.
--- Callback receives (success:bool, raw_stdout:string).
--- Identical pattern to cli.lua's run_raw.
local function run_raw(args, callback)
  local stdout_chunks = {}
  local stdout = vim.uv.new_pipe()
  local handle
  log.debug("cmux run_raw: " .. table.concat(args, " "))
  handle = vim.uv.spawn(_bin, {
    args  = args,
    stdio = { nil, stdout, nil },
  }, function(code)
    stdout:close()
    handle:close()
    vim.schedule(function()
      if code ~= 0 then
        log.warn("cmux run_raw: exit code " .. code .. " for: " .. table.concat(args, " "))
      end
      callback(code == 0, table.concat(stdout_chunks))
    end)
  end)
  if not handle then
    stdout:close()
    log.error("cmux run_raw: spawn failed for: " .. table.concat(args, " "))
    vim.schedule(function()
      callback(false, "cmux: spawn failed (binary not found?)")
    end)
    return
  end
  stdout:read_start(function(_, chunk)
    if chunk then
      table.insert(stdout_chunks, chunk)
    end
  end)
end

--- Run a cmux command that returns JSON output.
--- Callback receives (success:bool, decoded_table_or_raw_string).
local function run_json(args, callback)
  run_raw(args, function(ok, raw)
    if not ok then
      callback(false, raw)
      return
    end
    if raw == "" then
      callback(true, nil)
      return
    end
    local dec_ok, data = pcall(vim.json.decode, raw)
    if not dec_ok then
      log.warn("cmux run_json: JSON decode failed for: " .. table.concat(args, " ")
        .. " — raw: " .. raw:sub(1, 200))
    end
    callback(dec_ok, dec_ok and data or raw)
  end)
end

-- ── Helpers ───────────────────────────────────────────────────────────────────

--- Parse cmux "OK <ref> [<ref>...]" response lines.
--- Returns a table of ref strings, e.g. {"surface:3", "workspace:2"}.
local function parse_ok_refs(raw)
  local refs = {}
  if not raw or not raw:match("^OK") then return refs end
  for ref in raw:gmatch("([%w]+:[%w%-]+)") do
    table.insert(refs, ref)
  end
  return refs
end

--- Extract a specific ref type from parsed refs.
--- E.g. extract_ref(refs, "surface") → "surface:3"
local function extract_ref(refs, prefix)
  for _, r in ipairs(refs) do
    if r:match("^" .. prefix .. ":") then return r end
  end
  return nil
end

--- Fetch all live surfaces via `tree --all --json`.
--- Callback receives (success, {surface_ref = {workspace_ref=..., pane_ref=..., title=...}}).
local function get_live_surfaces(callback)
  run_json({ "tree", "--all", "--json" }, function(ok, data)
    if not ok then
      callback(false, data)
      return
    end
    local surfaces = {}
    local windows = (type(data) == "table" and data.windows) or {}
    for _, win in ipairs(windows) do
      for _, ws in ipairs(win.workspaces or {}) do
        local ws_ref = ws.ref or ""
        local ws_title = ws.title or ""
        for _, pane in ipairs(ws.panes or {}) do
          for _, surf in ipairs(pane.surfaces or {}) do
            local sref = surf.ref or ""
            if sref ~= "" then
              surfaces[sref] = {
                workspace_ref = ws_ref,
                workspace_title = ws_title,
                pane_ref = pane.ref or "",
                title = surf.title or "",
                type = surf.type or "terminal",
              }
            end
          end
        end
      end
    end
    callback(true, surfaces)
  end)
end

--- Extract workspaces from tree JSON data.
--- Returns list of {ref, title, description, surface_count}.
local function extract_workspaces(tree_data)
  local result = {}
  local windows = (type(tree_data) == "table" and tree_data.windows) or {}
  for _, win in ipairs(windows) do
    for _, ws in ipairs(win.workspaces or {}) do
      local surf_count = 0
      for _, pane in ipairs(ws.panes or {}) do
        surf_count = surf_count + #(pane.surfaces or {})
      end
      table.insert(result, {
        ref         = ws.ref or "",
        title       = ws.title or "",
        description = ws.description,
        surface_count = surf_count,
      })
    end
  end
  return result
end

-- ── Interface methods ─────────────────────────────────────────────────────────

--- Derive aggregate status counts from the session list.
--- Mirrors the shape of `agent-deck status --json`:
---   { running, waiting, idle, error, stopped, total }
function M.status(cb)
  M.list_sessions(function(ok, sessions)
    if not ok then
      log.warn("cmux status: list_sessions failed")
      cb(false, sessions)
      return
    end
    local counts = { running = 0, waiting = 0, idle = 0, error = 0, stopped = 0, total = 0 }
    for _, s in ipairs(sessions) do
      counts.total = counts.total + 1
      local st = s.status or "idle"
      counts[st] = (counts[st] or 0) + 1
    end
    log.debug("cmux status: " .. counts.total .. " total, "
      .. counts.running .. " running, " .. counts.waiting .. " waiting, "
      .. counts.stopped .. " stopped")
    cb(true, counts)
  end)
end

--- List all tracked cmux sessions.
--- Cross-references persist metadata with live cmux surfaces via `tree --all --json`.
function M.list_sessions(cb)
  get_live_surfaces(function(ok, live_surfaces)
    if not ok then
      log.error("cmux list_sessions: tree failed — " .. tostring(live_surfaces))
      cb(false, live_surfaces)
      return
    end

    local all_cmux = persist.all_cmux_sessions()
    local result = {}
    local live_count = 0
    local tracked_count = 0

    for ref, _ in pairs(live_surfaces) do live_count = live_count + 1 end

    for surface_id, meta in pairs(all_cmux) do
      tracked_count = tracked_count + 1
      local alive = live_surfaces[surface_id] ~= nil
      local status

      if not alive then
        status = "stopped"
      elseif meta.tool == "claude" and meta.claude_session_id and meta.claude_session_id ~= "" then
        status = cmux_status.detect(meta.path, meta.claude_session_id)
      else
        status = "running"
      end

      table.insert(result, {
        id                = surface_id,
        title             = meta.title or surface_id,
        path              = meta.path,
        group             = meta.group,
        tool              = meta.tool,
        command           = meta.command,
        status            = status,
        claude_session_id = meta.claude_session_id,
        created_at        = meta.created_at,
      })
    end

    log.debug("cmux list_sessions: " .. live_count .. " live surfaces, "
      .. tracked_count .. " tracked sessions, " .. #result .. " returned")
    cb(true, result)
  end)
end

--- Show details for a specific session.
--- Returns the persisted metadata + verifies surface is alive.
function M.session_show(id, cb)
  local meta = persist.get_cmux_session(id)
  if not meta then
    log.warn("cmux session_show: session not found in persist — " .. tostring(id))
    vim.schedule(function()
      cb(false, "cmux: session not found — " .. tostring(id))
    end)
    return
  end

  get_live_surfaces(function(ok, live_surfaces)
    if not ok then
      log.warn("cmux session_show: tree failed for " .. id)
      cb(false, live_surfaces)
      return
    end

    local alive = live_surfaces[id] ~= nil
    local status
    if not alive then
      status = "stopped"
    elseif meta.tool == "claude" and meta.claude_session_id and meta.claude_session_id ~= "" then
      status = cmux_status.detect(meta.path, meta.claude_session_id)
    else
      status = "running"
    end

    log.debug("cmux session_show: " .. id .. " alive=" .. tostring(alive) .. " status=" .. status)
    cb(true, vim.tbl_extend("force", meta, { status = status }))
  end)
end

--- Send text to a cmux surface.
--- Uses `cmux send --surface <id> -- <text>` + `cmux send-key --surface <id> enter`.
function M.session_send(id, text, opts, cb)
  log.info("cmux session_send: sending " .. #text .. " chars to surface " .. id)
  run_raw({ "send", "--surface", id, "--", text }, function(ok, raw)
    if not ok then
      log.error("cmux session_send: send failed for " .. id .. " — " .. tostring(raw))
      vim.notify("agent-deck [cmux]: failed to send to " .. id, vim.log.levels.ERROR)
      if cb then cb(false, raw) end
      return
    end
    -- Send enter key to submit
    run_raw({ "send-key", "--surface", id, "enter" }, function(ok2, raw2)
      if not ok2 then
        log.warn("cmux session_send: send-key enter failed for " .. id)
      else
        log.debug("cmux session_send: sent successfully to " .. id)
      end
      if cb then cb(ok2, raw2) end
    end)
  end)
end

--- Read screen output from a cmux surface.
--- Uses `cmux read-screen --surface <id> --scrollback --lines 200` with ANSI stripping.
function M.session_output(id, cb)
  log.debug("cmux session_output: reading screen for " .. id)
  run_raw({ "read-screen", "--surface", id, "--scrollback", "--lines", "200" }, function(ok, raw)
    if not ok then
      log.warn("cmux session_output: read-screen failed for " .. id .. " — returning empty")
      vim.notify("agent-deck [cmux]: read-screen failed for " .. id, vim.log.levels.WARN)
      cb(true, { output = "" })
      return
    end
    local cleaned = ansi.strip(raw)
    log.debug("cmux session_output: got " .. #cleaned .. " chars (stripped from " .. #raw .. " raw)")
    cb(true, { output = cleaned })
  end)
end

--- Start a session by rebuilding and sending the tool command.
--- Unlike the initial launch (which uses --session-id for new sessions),
--- restart always uses --resume since the conversation already exists.
function M.session_start(id, cb)
  local meta = persist.get_cmux_session(id)
  if not meta then
    log.error("cmux session_start: session not found in persist — " .. tostring(id))
    vim.notify("agent-deck [cmux]: session not found — " .. tostring(id), vim.log.levels.ERROR)
    vim.schedule(function()
      cb(false, "cmux: session not found — " .. tostring(id))
    end)
    return
  end

  -- Rebuild command for current state using session_cmd (picks --resume
  -- for existing conversations, handles claude wrapper + env)
  local cmd
  local tool = meta.tool or "claude"
  if tool == "claude" and meta.claude_session_id and meta.claude_session_id ~= "" then
    local scmd = require("agent-deck.session_cmd")
    cmd = scmd.build_cmd(meta)  -- always --resume for existing sessions
  else
    cmd = meta.command or tool
  end

  if not cmd then
    log.error("cmux session_start: could not build command for " .. id)
    vim.schedule(function() cb(false, "cmux: no command for " .. id) end)
    return
  end

  local full_cmd = "cd " .. vim.fn.shellescape(meta.path or vim.fn.getcwd()) .. " && " .. cmd
  log.info("cmux session_start: sending '" .. full_cmd .. "' to " .. id)

  -- Send command to the surface shell (assumes tool has been stopped and
  -- the surface is at a shell prompt — use session_stop first if needed)
  run_raw({ "send", "--surface", id, "--", full_cmd }, function(ok, raw)
    if not ok then
      log.error("cmux session_start: send failed for " .. id)
      vim.notify("agent-deck [cmux]: failed to start " .. (meta.title or id), vim.log.levels.ERROR)
      cb(false, raw)
      return
    end
    run_raw({ "send-key", "--surface", id, "enter" }, function(ok2, raw2)
      if ok2 then
        log.info("cmux session_start: started " .. (meta.title or id))
        vim.notify("agent-deck [cmux]: started " .. (meta.title or id))
      end
      cb(ok2, raw2)
    end)
  end)
end

--- Stop a session by creating a new empty surface then closing the old one.
--- cmux has no process-kill API; close-surface is the only way to terminate
--- the running tool. New surface is created FIRST to avoid "cannot close
--- last surface" error.
function M.session_stop(id, cb)
  local meta = persist.get_cmux_session(id)
  local wref = meta and meta.workspace_id
  log.info("cmux session_stop: create+close " .. id .. " in " .. (wref or "?"))

  if not wref then
    log.warn("cmux session_stop: no workspace for " .. id)
    cb(false, "cmux: no workspace for " .. id)
    return
  end

  -- Step 1: create new surface FIRST (so old one is never the last)
  run_raw({ "new-split", "right", "--workspace", wref }, function(ok, raw)
    if not ok then
      log.warn("cmux session_stop: new-split failed — " .. tostring(raw))
      cb(false, raw)
      return
    end

    local refs = parse_ok_refs(raw)
    local new_ref = extract_ref(refs, "surface")

    -- Step 2: close the old surface (safe now)
    run_raw({ "close-surface", "--surface", id }, function(ok2, _)
      if not ok2 then
        log.warn("cmux session_stop: close-surface failed for " .. id .. " (continuing)")
      end

      -- Update persist to point to the new surface
      if new_ref and meta then
        persist.remove_cmux_session(id)
        meta.surface_id = new_ref
        meta.id = new_ref
        persist.set_cmux_session(new_ref, meta)
        if meta.group then
          persist.remove_session(meta.group, id)
          persist.add_session(meta.group, new_ref)
        end
        log.info("cmux session_stop: replaced " .. id .. " → " .. new_ref)
      end

      vim.notify("agent-deck [cmux]: stopped " .. (meta and meta.title or id))
      cb(true, raw)
    end)
  end)
end

--- Restart a session: create new surface first, close old one, run the tool command.
--- Order matters: new-split BEFORE close-surface, because cmux refuses to close
--- the last surface in a workspace.
function M.session_restart(id, cb)
  local meta = persist.get_cmux_session(id)
  if not meta then
    log.error("cmux session_restart: session not found — " .. tostring(id))
    cb(false, "cmux: session not found — " .. tostring(id))
    return
  end

  -- Rebuild command for current state.
  -- Always use the bare tool name as base — never meta.command, which may
  -- contain a resume command from a previous restart and would double up.
  local cmd
  local tool = meta.tool or "claude"
  if tool == "claude" and meta.claude_session_id and meta.claude_session_id ~= "" then
    local scmd = require("agent-deck.session_cmd")
    meta.id = meta.id or meta.surface_id or id  -- ensure id for build_cmd logging
    cmd = scmd.build_cmd(vim.tbl_extend("force", meta, { command = nil }))
  elseif tool == "codex" and meta.codex_thread_id and meta.codex_thread_id ~= "" then
    cmd = "codex resume " .. meta.codex_thread_id
  else
    cmd = tool
  end

  if not cmd then
    log.error("cmux session_restart: could not build command for " .. id)
    cb(false, "cmux: no command for " .. id)
    return
  end

  local wref = meta.workspace_id
  local path = meta.path or vim.fn.getcwd()
  local full_cmd = "cd " .. vim.fn.shellescape(path) .. " && " .. cmd
  log.info("cmux session_restart: " .. id .. " → " .. full_cmd)

  -- Step 1: create a new surface FIRST (so the old one is never the last)
  run_raw({ "new-split", "right", "--workspace", wref }, function(ok, raw)
    if not ok then
      log.error("cmux session_restart: new-split failed in " .. (wref or "?"))
      cb(false, "cmux: failed to create new surface")
      return
    end

    local refs = parse_ok_refs(raw)
    local new_ref = extract_ref(refs, "surface")
    if not new_ref then
      log.error("cmux session_restart: could not extract surface ref")
      cb(false, "cmux: could not determine new surface ref")
      return
    end

    -- Step 2: close the OLD surface (safe now — new one exists)
    run_raw({ "close-surface", "--surface", id }, function(ok2, _)
      if not ok2 then
        log.warn("cmux session_restart: close-surface failed for " .. id .. " (continuing)")
      end

      -- Step 3: update persist with new surface ref.
      -- Keep command as bare tool name (not the resume variant) so future
      -- restarts don't double up resume arguments.
      persist.remove_cmux_session(id)
      meta.surface_id = new_ref
      meta.id = new_ref
      meta.command = tool  -- bare tool name, not the resume command
      persist.set_cmux_session(new_ref, meta)
      if meta.group then
        persist.remove_session(meta.group, id)
        persist.add_session(meta.group, new_ref)
      end

      -- Step 4: send the tool command to the new surface
      run_raw({ "send", "--surface", new_ref, "--", full_cmd }, function(ok3, _)
        if not ok3 then
          log.error("cmux session_restart: send failed for " .. new_ref)
          cb(false, "cmux: failed to send command")
          return
        end
        run_raw({ "send-key", "--surface", new_ref, "enter" }, function(ok4, raw4)
          if ok4 then
            log.info("cmux session_restart: restarted " .. (meta.title or id) .. " as " .. new_ref)
            vim.notify("agent-deck [cmux]: restarted " .. (meta.title or id))
          end
          cb(ok4, raw4)
        end)
      end)
    end)
  end)
end

--- Delete a session by closing the cmux surface and removing persist metadata.
function M.session_delete(id, cb)
  local meta = persist.get_cmux_session(id)
  log.info("cmux session_delete: closing surface " .. id
    .. " (title=" .. (meta and meta.title or "?") .. ")")
  run_raw({ "close-surface", "--surface", id }, function(ok, raw)
    persist.remove_cmux_session(id)
    if meta and meta.group then
      persist.remove_session(meta.group, id)
    end
    if ok then
      vim.notify("agent-deck [cmux]: deleted " .. (meta and meta.title or id))
      log.info("cmux session_delete: closed and removed " .. id)
    else
      log.error("cmux session_delete: close-surface failed for " .. id .. " — " .. tostring(raw))
      vim.notify("agent-deck [cmux]: failed to delete " .. id, vim.log.levels.ERROR)
    end
    cb(ok, raw)
  end)
end

--- Launch a new session in cmux.
---
--- Flow:
---   1. Find/create workspace for the group
---   2. Create a new split surface in the workspace
---   3. Generate UUID for claude_session_id
---   4. Build and send the tool command
---   5. Store metadata in persist
function M.launch(path, opts, cb)
  opts = opts or {}
  local tool  = opts.tool or "claude"
  local title = opts.title or tool
  local group = opts.group or "default"

  log.info("cmux launch: tool=" .. tool .. " title='" .. title
    .. "' group=" .. group .. " path=" .. path)

  -- Step 1: list existing workspaces via tree to find one for this group
  run_json({ "tree", "--all", "--json" }, function(ok, tree_data)
    if not ok then
      log.error("cmux launch: tree failed")
      vim.notify("agent-deck [cmux]: failed to list workspaces", vim.log.levels.ERROR)
      cb(false, tree_data)
      return
    end

    local workspaces = extract_workspaces(tree_data)
    local workspace_ref = nil
    for _, ws in ipairs(workspaces) do
      if ws.title == group and ws.ref ~= "" then
        workspace_ref = ws.ref
        log.debug("cmux launch: found existing workspace " .. ws.ref .. " for group " .. group)
        break
      end
    end

    local function create_surface(wref)
      -- Step 2: create a new split surface in the workspace
      log.debug("cmux launch: creating split in workspace " .. wref)
      run_raw({ "new-split", "right", "--workspace", wref }, function(ok2, raw)
        if not ok2 then
          log.error("cmux launch: new-split failed in workspace " .. wref .. " — " .. tostring(raw))
          vim.notify("agent-deck [cmux]: failed to create surface", vim.log.levels.ERROR)
          cb(false, raw)
          return
        end

        local refs = parse_ok_refs(raw)
        local surface_ref = extract_ref(refs, "surface")
        if not surface_ref then
          log.error("cmux launch: could not extract surface ref from new-split response: " .. raw)
          cb(false, "cmux: could not determine surface ref from new-split response")
          return
        end
        log.info("cmux launch: created " .. surface_ref .. " in " .. wref)

        -- Step 3: generate UUID for claude_session_id
        local uuid = vim.fn.system("uuidgen"):gsub("%s+", "")
        log.debug("cmux launch: generated UUID " .. uuid .. " for claude_session_id")

        -- Step 4: build command (uses agent-deck config for claude wrapper/env)
        local cmd
        if tool == "claude" then
          local scmd = require("agent-deck.session_cmd")
          cmd = scmd.build_cmd_new(
            { tool = "claude", claude_session_id = uuid, id = "cmux-new", path = path },
            function() return false end  -- new session, conv never exists yet
          )
        elseif tool == "codex" then
          cmd = "codex"
        elseif tool == "opencode" then
          cmd = "opencode"
        else
          cmd = tool
        end
        log.info("cmux launch: sending command '" .. cmd .. "' to " .. surface_ref)

        -- cd to project path first, then send the tool command
        -- cmux surfaces default to ~ ; we need the correct cwd for
        -- Claude's .jsonl path encoding and project context.
        local full_cmd = "cd " .. vim.fn.shellescape(path) .. " && " .. cmd
        log.debug("cmux launch: full command: " .. full_cmd)
        run_raw({ "send", "--surface", surface_ref, "--", full_cmd }, function(ok3, _)
          if not ok3 then
            log.error("cmux launch: send failed for " .. surface_ref)
            vim.notify("agent-deck [cmux]: failed to send command", vim.log.levels.ERROR)
            cb(false, "cmux: failed to send command to " .. surface_ref)
            return
          end
          run_raw({ "send-key", "--surface", surface_ref, "enter" }, function(ok4, _)
            if not ok4 then
              log.error("cmux launch: send-key enter failed for " .. surface_ref)
              cb(false, "cmux: failed to send enter to " .. surface_ref)
              return
            end

            -- Step 5: store metadata in persist
            -- Use UTC date string (not unix int) so codex.infer_thread_id's
            -- SQLite strftime('%s', created_at) converts correctly to epoch.
            -- Local time would cause a timezone offset mismatch.
            local now = os.date("!%Y-%m-%d %H:%M:%S")
            persist.set_cmux_session(surface_ref, {
              surface_id        = surface_ref,
              workspace_id      = wref,
              tool              = tool,
              title             = title,
              path              = path,
              group             = group,
              command           = cmd,
              claude_session_id = (tool == "claude") and uuid or nil,
              created_at        = now,
            })
            persist.add_session(group, surface_ref)

            log.info("cmux launch: session '" .. title .. "' launched successfully"
              .. " (surface=" .. surface_ref .. ", workspace=" .. wref .. ")")
            vim.notify("agent-deck [cmux]: launched '" .. title .. "'")

            cb(true, {
              id                = surface_ref,
              title             = title,
              path              = path,
              group             = group,
              tool              = tool,
              command           = cmd,
              claude_session_id = (tool == "claude") and uuid or nil,
              created_at        = now,
            })
          end)
        end)
      end)
    end

    if workspace_ref then
      create_surface(workspace_ref)
    else
      -- Step 1b: create a new named workspace for this group
      log.info("cmux launch: creating new workspace for group " .. group)
      run_raw({ "new-workspace", "--name", group, "--cwd", path }, function(ok2, raw)
        if not ok2 then
          log.error("cmux launch: new-workspace failed for group " .. group .. " — " .. tostring(raw))
          vim.notify("agent-deck [cmux]: failed to create workspace", vim.log.levels.ERROR)
          cb(false, raw)
          return
        end
        local refs = parse_ok_refs(raw)
        local wref = extract_ref(refs, "workspace")
        if not wref then
          log.error("cmux launch: could not extract workspace ref from response: " .. raw)
          cb(false, "cmux: could not determine workspace ref from new-workspace response")
          return
        end
        log.info("cmux launch: created " .. wref .. " for group " .. group)
        create_surface(wref)
      end)
    end
  end)
end

--- List cmux workspaces as groups.
--- Returns { groups: [{name, session_count, ...}] } matching agent-deck format.
function M.group_list(cb)
  log.debug("cmux group_list: fetching workspaces via tree")
  run_json({ "tree", "--all", "--json" }, function(ok, tree_data)
    if not ok then
      log.error("cmux group_list: tree failed")
      cb(false, tree_data)
      return
    end

    local workspaces = extract_workspaces(tree_data)

    -- Count tracked surfaces per workspace
    local all_cmux = persist.all_cmux_sessions()
    local ws_counts = {}
    for _, meta in pairs(all_cmux) do
      local wid = meta.workspace_id
      if wid then
        ws_counts[wid] = (ws_counts[wid] or 0) + 1
      end
    end

    local groups = {}
    for _, ws in ipairs(workspaces) do
      table.insert(groups, {
        name          = ws.title,
        workspace_id  = ws.ref,
        session_count = ws_counts[ws.ref] or 0,
      })
    end

    log.debug("cmux group_list: " .. #groups .. " workspace(s)")
    cb(true, { groups = groups })
  end)
end

--- Create a new cmux workspace.
function M.group_create(name, cb)
  log.info("cmux group_create: creating workspace '" .. name .. "'")
  run_raw({ "new-workspace", "--name", name }, function(ok, raw)
    if ok then
      log.info("cmux group_create: workspace '" .. name .. "' created — " .. raw:gsub("%s+$", ""))
    else
      log.error("cmux group_create: failed to create workspace '" .. name .. "'")
      vim.notify("agent-deck [cmux]: failed to create workspace '" .. name .. "'", vim.log.levels.ERROR)
    end
    cb(ok, raw)
  end)
end

--- Move a session to a different group (persist-only for cmux).
--- cmux does not support cross-workspace surface moves natively.
function M.group_move(id, group, cb)
  local meta = persist.get_cmux_session(id)
  if meta then
    meta.group = group
    persist.set_cmux_session(id, meta)
    log.info("cmux group_move: updated group for " .. id .. " → " .. group .. " (persist-only)")
  else
    log.warn("cmux group_move: session " .. id .. " not found in persist")
  end
  vim.schedule(function()
    cb(true, nil)
  end)
end

--- Update a session field in persist (cmux metadata is plugin-managed).
function M.session_set(id, field, value, cb)
  local meta = persist.get_cmux_session(id)
  if meta then
    local key = field:gsub("-", "_")
    meta[key] = value
    persist.set_cmux_session(id, meta)
    log.debug("cmux session_set: " .. id .. "." .. key .. " = " .. tostring(value))
  else
    log.warn("cmux session_set: session " .. id .. " not found in persist")
  end
  vim.schedule(function()
    cb(true, nil)
  end)
end

--- Focus a cmux surface: bring its workspace to the front.
--- Uses `cmux select-workspace --workspace <wref>` since cmux has no
--- direct focus-surface command.
function M.focus_session(id, cb)
  local meta = persist.get_cmux_session(id)
  local wref = meta and meta.workspace_id
  log.info("cmux focus_session: focusing " .. id
    .. " (workspace=" .. (wref or "?") .. ")")

  if wref then
    run_raw({ "select-workspace", "--workspace", wref }, function(ok, raw)
      if not ok then
        log.warn("cmux focus_session: select-workspace failed for " .. wref)
        vim.notify("agent-deck [cmux]: failed to focus " .. id, vim.log.levels.WARN)
      else
        log.debug("cmux focus_session: selected workspace " .. wref)
      end
      if cb then cb(ok, raw) end
    end)
  else
    log.warn("cmux focus_session: no workspace_id for " .. id)
    vim.notify("agent-deck [cmux]: no workspace info for " .. id, vim.log.levels.WARN)
    if cb then vim.schedule(function() cb(false, "no workspace_id") end) end
  end
end

--- Health check: verify cmux is reachable via `cmux ping`.
function M.health_check()
  run_raw({ "ping" }, function(ok, raw)
    if ok then
      log.info("cmux health_check: ping succeeded — cmux is reachable")
      vim.notify("agent-deck [cmux]: connected to cmux")
    else
      log.error("cmux health_check: ping failed — " .. (raw or "unknown error")
        .. ". Is cmux running? Ensure socket access is enabled in cmux Settings.")
      vim.notify("agent-deck [cmux]: cannot reach cmux! Is it running?", vim.log.levels.ERROR)
    end
  end)
end

return M
