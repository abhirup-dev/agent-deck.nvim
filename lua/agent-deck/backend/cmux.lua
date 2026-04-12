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
  local fallback = "/usr/local/bin/cmux"
  if vim.fn.executable(fallback) == 1 then
    _bin = fallback
  else
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
--- Cross-references persist metadata with live cmux surfaces.
function M.list_sessions(cb)
  run_json({ "list-surfaces", "--json" }, function(ok, surfaces_data)
    if not ok then
      log.error("cmux list_sessions: list-surfaces failed — " .. tostring(surfaces_data))
      cb(false, surfaces_data)
      return
    end

    -- Build a set of live surface IDs for O(1) lookup
    local live_surfaces = {}
    local surfaces_list = surfaces_data
    if type(surfaces_data) == "table" and surfaces_data.surfaces then
      surfaces_list = surfaces_data.surfaces
    end
    local live_count = 0
    if type(surfaces_list) == "table" then
      for _, surf in ipairs(surfaces_list) do
        local sid = surf.surface_id or surf.id
        if sid then
          live_surfaces[sid] = true
          live_count = live_count + 1
        end
      end
    end

    -- Cross-reference with persisted metadata
    local all_cmux = persist.all_cmux_sessions()
    local result = {}
    local tracked_count = 0

    for surface_id, meta in pairs(all_cmux) do
      tracked_count = tracked_count + 1
      local alive = live_surfaces[surface_id]
      local status

      if not alive then
        status = "stopped"
      elseif meta.tool == "claude" and meta.claude_session_id and meta.claude_session_id ~= "" then
        -- Use .jsonl-based status detection for Claude sessions
        status = cmux_status.detect(meta.path, meta.claude_session_id)
      else
        -- Non-Claude tools: surface exists = running
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

  -- Verify surface is still alive
  run_json({ "list-surfaces", "--json" }, function(ok, data)
    if not ok then
      log.warn("cmux session_show: list-surfaces failed for " .. id)
      cb(false, data)
      return
    end

    local alive = false
    local surfaces_list = data
    if type(data) == "table" and data.surfaces then
      surfaces_list = data.surfaces
    end
    if type(surfaces_list) == "table" then
      for _, surf in ipairs(surfaces_list) do
        local sid = surf.surface_id or surf.id
        if sid == id then alive = true; break end
      end
    end

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
--- cmux send-surface --surface <id> "<text>" + cmux send-key-surface --surface <id> enter
function M.session_send(id, text, opts, cb)
  log.info("cmux session_send: sending " .. #text .. " chars to surface " .. id)
  run_raw({ "send-surface", "--surface", id, text }, function(ok, raw)
    if not ok then
      log.error("cmux session_send: send-surface failed for " .. id .. " — " .. tostring(raw))
      vim.notify("agent-deck [cmux]: failed to send to " .. id, vim.log.levels.ERROR)
      if cb then cb(false, raw) end
      return
    end
    -- Send enter key to submit
    run_raw({ "send-key-surface", "--surface", id, "enter" }, function(ok2, raw2)
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
--- Uses cmux read-screen with ANSI stripping.
function M.session_output(id, cb)
  log.debug("cmux session_output: reading screen for " .. id)
  run_raw({ "read-screen", "--surface", id, "--scrollback", "--lines", "200" }, function(ok, raw)
    if not ok then
      -- Fallback: read-screen may be experimental
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

--- Start a session by re-sending the stored command to the surface.
function M.session_start(id, cb)
  local meta = persist.get_cmux_session(id)
  if not meta or not meta.command then
    log.error("cmux session_start: no stored command for session " .. tostring(id))
    vim.notify("agent-deck [cmux]: no command stored for " .. tostring(id), vim.log.levels.ERROR)
    vim.schedule(function()
      cb(false, "cmux: no stored command for session " .. tostring(id))
    end)
    return
  end
  log.info("cmux session_start: re-sending command '" .. meta.command .. "' to " .. id)
  run_raw({ "send-surface", "--surface", id, meta.command }, function(ok, raw)
    if not ok then
      log.error("cmux session_start: send-surface failed for " .. id)
      vim.notify("agent-deck [cmux]: failed to start " .. (meta.title or id), vim.log.levels.ERROR)
      cb(false, raw)
      return
    end
    run_raw({ "send-key-surface", "--surface", id, "enter" }, function(ok2, raw2)
      if ok2 then
        log.info("cmux session_start: started " .. (meta.title or id))
        vim.notify("agent-deck [cmux]: started " .. (meta.title or id))
      end
      cb(ok2, raw2)
    end)
  end)
end

--- Stop a session by sending Ctrl-C to the surface.
function M.session_stop(id, cb)
  log.info("cmux session_stop: sending ctrl-c to " .. id)
  run_raw({ "send-key-surface", "--surface", id, "ctrl-c" }, function(ok, raw)
    if ok then
      log.debug("cmux session_stop: ctrl-c sent to " .. id)
      vim.notify("agent-deck [cmux]: stopped " .. id)
    else
      log.warn("cmux session_stop: failed to send ctrl-c to " .. id)
      vim.notify("agent-deck [cmux]: failed to stop " .. id, vim.log.levels.WARN)
    end
    cb(ok, raw)
  end)
end

--- Restart a session: stop (ctrl-c) then start (resend command) after a delay.
function M.session_restart(id, cb)
  log.info("cmux session_restart: restarting " .. id)
  M.session_stop(id, function(ok, _)
    if not ok then
      log.error("cmux session_restart: stop failed for " .. id)
      cb(false, "cmux: failed to stop session " .. tostring(id))
      return
    end
    -- 500ms delay to let ctrl-c take effect before resending command
    vim.defer_fn(function()
      M.session_start(id, cb)
    end, 500)
  end)
end

--- Delete a session by closing the cmux surface and removing persist metadata.
function M.session_delete(id, cb)
  -- Fetch metadata BEFORE removing so we can clean up project session list
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

  -- Step 1: list existing workspaces to find one for this group
  run_json({ "list-workspaces", "--json" }, function(ok, ws_data)
    if not ok then
      log.error("cmux launch: list-workspaces failed")
      vim.notify("agent-deck [cmux]: failed to list workspaces", vim.log.levels.ERROR)
      cb(false, ws_data)
      return
    end

    local workspaces = ws_data
    if type(ws_data) == "table" and ws_data.workspaces then
      workspaces = ws_data.workspaces
    end

    -- Look for an existing workspace matching the group name
    local workspace_id = nil
    if type(workspaces) == "table" then
      for _, ws in ipairs(workspaces) do
        local ws_name = ws.name or ws.title or ""
        local ws_id   = ws.workspace_id or ws.id
        if ws_name == group and ws_id then
          workspace_id = ws_id
          log.debug("cmux launch: found existing workspace " .. ws_id .. " for group " .. group)
          break
        end
      end
    end

    local function create_surface(wid)
      -- Step 2: create a new split surface in the workspace
      log.debug("cmux launch: creating split in workspace " .. wid)
      run_json({ "new-split", "--workspace", wid, "right", "--json" }, function(ok2, split_data)
        if not ok2 then
          log.error("cmux launch: new-split failed in workspace " .. wid)
          vim.notify("agent-deck [cmux]: failed to create surface", vim.log.levels.ERROR)
          cb(false, split_data)
          return
        end

        local surface_id = nil
        if type(split_data) == "table" then
          surface_id = split_data.surface_id or split_data.id
        end
        if not surface_id then
          log.error("cmux launch: could not extract surface_id from new-split response")
          cb(false, "cmux: could not determine surface_id from new-split response")
          return
        end
        log.info("cmux launch: created surface " .. surface_id .. " in workspace " .. wid)

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
        log.info("cmux launch: sending command '" .. cmd .. "' to surface " .. surface_id)

        -- Send command to surface
        run_raw({ "send-surface", "--surface", surface_id, cmd }, function(ok3, _)
          if not ok3 then
            log.error("cmux launch: send-surface failed for " .. surface_id)
            vim.notify("agent-deck [cmux]: failed to send command", vim.log.levels.ERROR)
            cb(false, "cmux: failed to send command to surface " .. surface_id)
            return
          end
          run_raw({ "send-key-surface", "--surface", surface_id, "enter" }, function(ok4, _)
            if not ok4 then
              log.error("cmux launch: send-key enter failed for " .. surface_id)
              cb(false, "cmux: failed to send enter to surface " .. surface_id)
              return
            end

            -- Step 5: store metadata in persist
            local now = os.time()
            persist.set_cmux_session(surface_id, {
              surface_id        = surface_id,
              workspace_id      = wid,
              tool              = tool,
              title             = title,
              path              = path,
              group             = group,
              command           = cmd,
              claude_session_id = (tool == "claude") and uuid or nil,
              created_at        = now,
            })
            persist.add_session(group, surface_id)

            log.info("cmux launch: session '" .. title .. "' launched successfully"
              .. " (surface=" .. surface_id .. ", workspace=" .. wid .. ")")
            vim.notify("agent-deck [cmux]: launched '" .. title .. "'")

            cb(true, {
              id                = surface_id,
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

    if workspace_id then
      -- Workspace exists — create surface in it
      create_surface(workspace_id)
    else
      -- Step 1b: create a new named workspace for this group
      log.info("cmux launch: creating new workspace for group " .. group)
      run_json({ "new-workspace", "--name", group, "--json" }, function(ok2, new_ws)
        if not ok2 then
          log.error("cmux launch: new-workspace failed for group " .. group)
          vim.notify("agent-deck [cmux]: failed to create workspace", vim.log.levels.ERROR)
          cb(false, new_ws)
          return
        end
        local wid = nil
        if type(new_ws) == "table" then
          wid = new_ws.workspace_id or new_ws.id
        end
        if not wid then
          log.error("cmux launch: could not extract workspace_id from new-workspace response")
          cb(false, "cmux: could not determine workspace_id from new-workspace response")
          return
        end
        log.info("cmux launch: created workspace " .. wid .. " for group " .. group)
        create_surface(wid)
      end)
    end
  end)
end

--- List cmux workspaces as groups.
--- Returns { groups: [{name, session_count, ...}] } matching agent-deck format.
function M.group_list(cb)
  log.debug("cmux group_list: fetching workspaces")
  run_json({ "list-workspaces", "--json" }, function(ok, data)
    if not ok then
      log.error("cmux group_list: list-workspaces failed")
      cb(false, data)
      return
    end

    local workspaces = data
    if type(data) == "table" and data.workspaces then
      workspaces = data.workspaces
    end

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
    if type(workspaces) == "table" then
      for _, ws in ipairs(workspaces) do
        local wid = ws.workspace_id or ws.id or ""
        table.insert(groups, {
          name          = ws.name or ws.title or wid,
          workspace_id  = wid,
          session_count = ws_counts[wid] or 0,
        })
      end
    end

    log.debug("cmux group_list: " .. #groups .. " workspace(s)")
    cb(true, { groups = groups })
  end)
end

--- Create a new cmux workspace.
function M.group_create(name, cb)
  log.info("cmux group_create: creating workspace '" .. name .. "'")
  run_json({ "new-workspace", "--name", name, "--json" }, function(ok, data)
    if ok then
      log.info("cmux group_create: workspace '" .. name .. "' created")
    else
      log.error("cmux group_create: failed to create workspace '" .. name .. "'")
      vim.notify("agent-deck [cmux]: failed to create workspace '" .. name .. "'", vim.log.levels.ERROR)
    end
    cb(ok, data)
  end)
end

--- Move a session to a different group (persist-only for cmux).
--- cmux does not support cross-workspace surface moves, so we just update
--- the persisted metadata.
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
    -- Map CLI-style field names to Lua keys
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

--- Focus a cmux surface: bring it to the front in cmux's UI.
--- cmux focus-surface --surface <id> + cmux select-workspace --workspace <wid>
function M.focus_session(id, cb)
  local meta = persist.get_cmux_session(id)
  log.info("cmux focus_session: focusing surface " .. id
    .. " (workspace=" .. (meta and meta.workspace_id or "?") .. ")")

  run_raw({ "focus-surface", "--surface", id }, function(ok, raw)
    if not ok then
      log.error("cmux focus_session: focus-surface failed for " .. id .. " — " .. tostring(raw))
      vim.notify("agent-deck [cmux]: failed to focus " .. id, vim.log.levels.ERROR)
      if cb then cb(false, raw) end
      return
    end
    -- Also select the workspace if we know it
    if meta and meta.workspace_id then
      run_raw({ "select-workspace", "--workspace", meta.workspace_id }, function(ok2, raw2)
        if not ok2 then
          log.warn("cmux focus_session: select-workspace failed for " .. meta.workspace_id)
        end
        if cb then cb(ok2, raw2) end
      end)
    else
      if cb then cb(true, raw) end
    end
  end)
end

--- Health check: verify cmux is reachable via `cmux ping`.
function M.health_check()
  run_raw({ "ping" }, function(ok, raw)
    if ok then
      log.info("cmux health_check: ping succeeded — cmux is reachable")
      vim.notify("agent-deck [cmux]: connected to cmux")
    else
      log.error("cmux health_check: ping failed — " .. (raw or "unknown error")
        .. ". Is cmux running? Ensure CMUX_SOCKET_MODE=allowAll if Neovide runs outside cmux.")
      vim.notify("agent-deck [cmux]: cannot reach cmux! Is it running?", vim.log.levels.ERROR)
    end
  end)
end

return M
