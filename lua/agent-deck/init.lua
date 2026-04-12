-- init.lua — agent-deck.nvim entry point
--
-- Responsibilities:
--   • setup(): bootstrap persist, resolve initial project, start polling timer,
--     register user commands and autocmds.
--   • Polling timer: fast (3s) when picker is open or a session is running;
--     slow (15s) otherwise. Pauses on FocusLost, resumes on FocusGained.
--   • Auto-sync: on every poll, sessions whose agent-deck group matches the
--     current project slug are added to the persist map. This ensures sessions
--     created outside Neovide are tracked without the user running Dag.
--   • Public commands: refresh (Dar), refresh_sessions (DaR), import_sessions,
--     kill_all, set_group (Dag).
local M = {}

local log = require("agent-deck.logger")

local _timer         = nil
local _fast_interval = 3000   -- 3s: picker open or a project session is running
local _slow_interval = 15000  -- 15s: otherwise
local _last_status   = {}     -- cached status for change detection

-- ── Helpers ──────────────────────────────────────────────────────────────────

local function is_active()
  local ok, state = pcall(require, "agent-deck.state")
  if not ok then return false end
  if state._picker_open then return true end
  for _, s in ipairs(state.project_sessions()) do
    if s.status == "running" then return true end
  end
  return false
end

local function do_poll()
  local backend = require("agent-deck.backend")
  local state   = require("agent-deck.state")

  -- Step 1: fetch aggregate status counts (cheap, always runs)
  backend.status(function(ok, data)
    if not ok or type(data) ~= "table" then
      log.debug("do_poll: status fetch failed or returned non-table")
      return
    end

    -- Detect any change in status counts so we know whether to fetch the full list
    local changed = false
    for k, v in pairs(data) do
      if _last_status[k] ~= v then changed = true; break end
    end
    _last_status = data
    state.set_status(data)

    -- Step 2: fetch the full session list only when:
    --   a) status counts changed (something started/stopped/errored), OR
    --   b) the picker is open (needs up-to-date items for display)
    -- This avoids a list call on every poll tick when nothing has changed.
    if changed or state._picker_open then
      log.debug("do_poll: fetching full session list (changed=" .. tostring(changed)
        .. ", picker_open=" .. tostring(state._picker_open) .. ")")
      backend.list_sessions(function(ok2, sessions)
        if ok2 and type(sessions) == "table" then
          state.set_sessions(sessions)
          local project = state.current_project
          if project then
            local persist = require("agent-deck.persist")
            local grp     = require("agent-deck.group")
            -- Auto-sync: persist any session whose slugified agent-deck group
            -- matches the current project slug. This catches sessions that were
            -- created in the external agent-deck terminal (outside Neovide)
            -- without requiring the user to run Dag or import_sessions.
            for _, s in ipairs(sessions) do
              if s.status ~= "error" and grp.slugify(s.group or "") == project then
                persist.add_session(project, s.id)
              end
            end
            -- Prune any errored sessions from the persist map
            persist.load_project(project)

            -- ── Codex thread sync ──────────────────────────────────────────────
            -- Codex thread IDs live only in Codex's own SQLite DB. The plugin
            -- resolves them via codex.enrich_session (shared util) and persists
            -- the mapping. Threads appear only after the user sends the first
            -- message, so poll-based sync catches them after launch.
            --
            -- agent-deck and cmux backends use separate persist stores:
            --   agent-deck: persist._codex_threads[agent-deck-session-id]
            --   cmux:       persist._cmux_sessions[surface-ref].codex_thread_id
            local codex = require("agent-deck.codex")

            if backend.name() == "cmux" then
              -- cmux backend: read from cmux persist, enrich, write back
              for _, s in ipairs(sessions) do
                if (s.tool or "") == "codex"
                  and s.status ~= "error" and s.status ~= "stopped"
                  and grp.slugify(s.group or "") == project then
                  local cmeta = persist.get_cmux_session(s.id)
                  if cmeta and (not cmeta.codex_thread_id or cmeta.codex_thread_id == "") then
                    log.debug("poll (cmux): codex session " .. s.id .. " — no thread, enriching")
                    -- codex.enrich_session needs: tool, path, created_at, id
                    cmeta.id = cmeta.id or cmeta.surface_id or s.id
                    codex.enrich_session(cmeta, function(enriched)
                      local tid = enriched and enriched.codex_thread_id
                      if tid then
                        -- Write back to cmux persist so session_restart can use it
                        cmeta.codex_thread_id = tid
                        persist.set_cmux_session(s.id, cmeta)
                        log.info("poll (cmux): codex thread synced — " .. s.id .. " → " .. tid)
                      else
                        log.debug("poll (cmux): codex thread not yet available for " .. s.id)
                      end
                    end)
                  end
                end
              end
            else
              -- agent-deck backend: uses _codex_threads persist + session_show
              for _, s in ipairs(sessions) do
                if (s.tool or "") == "codex"
                  and s.status ~= "error" and s.status ~= "stopped"
                  and grp.slugify(s.group or "") == project then
                  local saved = persist.get_codex_thread(s.id)
                  if not saved or saved == "" then
                    log.debug("poll: codex session " .. s.id .. " in project — no persisted thread, enriching")
                    backend.session_show(s.id, function(ok3, detail)
                      if ok3 and type(detail) == "table" then
                        codex.enrich_session(detail, function(enriched)
                          local tid = enriched and enriched.codex_thread_id
                          if tid then
                            log.info("poll: codex thread synced — " .. s.id .. " → " .. tid)
                          else
                            log.debug("poll: codex thread not yet available for " .. s.id)
                          end
                        end)
                      end
                    end)
                  end
                end
              end
            end
          end
        else
          log.warn("do_poll: list_sessions failed or returned non-table")
        end
      end)
    end
  end)
end

local function reset_timer()
  if _timer then
    _timer:stop()
    _timer:close()
    _timer = nil
  end
  local interval = is_active() and _fast_interval or _slow_interval
  _timer = vim.uv.new_timer()
  _timer:start(interval, interval, function()
    vim.schedule(do_poll)
  end)
end

-- ── setup() ──────────────────────────────────────────────────────────────────

function M.setup(opts)
  opts = opts or {}

  -- Apply custom_claude_cmd override before backend init (cmux launch uses it too)
  if opts.custom_claude_cmd then
    require("agent-deck.session_cmd").set_custom_claude_cmd(opts.custom_claude_cmd)
  end

  -- Initialize backend dispatch layer before anything else uses it
  local backend = require("agent-deck.backend")
  backend.init(opts.backend)

  local persist = require("agent-deck.persist")
  local group   = require("agent-deck.group")
  local state   = require("agent-deck.state")

  -- Load persisted map (also runs schema migrations)
  persist.load()

  -- Resolve initial project slug.
  -- Priority: _cwd_projects[cwd] > group.current_project() (git root slug).
  -- We prefer the persisted mapping because the user may have explicitly set
  -- a group name (e.g. "post-service-group") that differs from the git root
  -- directory name ("post-service"). Using group.current_project() in that
  -- case would produce the wrong slug and Dal would fail to find the sessions.
  local cwd     = vim.fn.getcwd()
  local project = persist.get_cwd_project(cwd) or group.current_project()
  log.info("setup: cwd=" .. cwd .. ", resolved project=" .. (project or "nil"))
  state.set_project(project)

  -- load_project called here is mostly a no-op (state.sessions is empty before
  -- first poll). Its real effect is to clear stale errored sessions; the guard
  -- inside load_project skips pruning when state is empty.
  persist.load_project(project)

  -- Initial poll: populates state.sessions so load_project can prune on next call
  do_poll()

  -- Start polling timer (fast or slow interval based on is_active())
  reset_timer()

  -- ── Commands ───────────────────────────────────────────────────────────
  vim.api.nvim_create_user_command("AgentDeckInfo", function()
    require("agent-deck.ui.info").show()
  end, { desc = "agent-deck: show debug info" })

  vim.api.nvim_create_user_command("AgentDeckLog", function()
    require("agent-deck.logger").show_log()
  end, { desc = "agent-deck: open debug log" })

  vim.api.nvim_create_user_command("AgentDeckLogClear", function()
    require("agent-deck.logger").clear_log()
  end, { desc = "agent-deck: clear debug log" })

  -- ── Autocmds ───────────────────────────────────────────────────────────────
  local ag = vim.api.nvim_create_augroup("AgentDeck", { clear = true })

  vim.api.nvim_create_autocmd("DirChanged", {
    group = ag,
    callback = function()
      local cwd2        = vim.fn.getcwd()
      -- Same resolution logic as setup(): prefer saved cwd mapping over auto-detect.
      -- Without this check, DirChanged would call group.current_project() and reset
      -- the project to the git-root slug, breaking Dal after session restore.
      local new_project = persist.get_cwd_project(cwd2) or group.current_project()
      log.info("DirChanged: cwd=" .. cwd2 .. ", project=" .. (new_project or "nil"))
      state.set_project(new_project)
      persist.load_project(new_project)
      reset_timer()
    end,
  })

  local ag_focus = vim.api.nvim_create_augroup("AgentDeckFocus", { clear = true })
  vim.api.nvim_create_autocmd("FocusLost", {
    group = ag_focus,
    callback = function()
      if _timer then _timer:stop() end
    end,
  })
  vim.api.nvim_create_autocmd("FocusGained", {
    group = ag_focus,
    callback = function()
      reset_timer()
      do_poll()
    end,
  })

  -- Start the staleness detection timer (2-min periodic CLI-ahead check).
  -- Only relevant for agent-deck backend — cmux sessions don't have CLI-ahead drift.
  if backend.name() ~= "cmux" then
    require("agent-deck.sync").start_timer()
  end

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group    = ag,
    callback = function() require("agent-deck.sync").stop_timer() end,
  })
end

-- ── Public commands ───────────────────────────────────────────────────────────

--- Restart all project sessions in the external agent-deck daemon (Dar).
---
--- Problem this solves: after `session restart`, agent-deck picks the "last
--- conversation in the session's working directory" for each session. If two
--- sessions share the same path, BOTH end up pointing at the same claude
--- conversation — the one most recently used. The second session loses its
--- distinct conversation history.
---
--- Solution: save each session's claude_session_id BEFORE restarting, then
--- restore it via `session set <id> claude-session-id <orig>` AFTER. This
--- pins each session back to its own conversation regardless of directory.
---
--- This is distinct from DaR (refresh_sessions / parallel.refresh()), which
--- kills and respawns the Neovide-side terminal buffers. Dar operates on the
--- external daemon; DaR operates on Neovide's internal buffers.
function M.refresh()
  local state   = require("agent-deck.state")
  local backend = require("agent-deck.backend")
  local ps      = state.project_sessions()
  if #ps == 0 then
    vim.notify("agent-deck: no sessions for current project", vim.log.levels.WARN)
    return
  end

  -- ── cmux backend: simple restart via respawn-pane ─────────────────────────
  -- No agent-deck-specific workarounds needed (codex stop→set→start,
  -- claude_session_id restore). respawn-pane kills the process and starts
  -- the new command atomically.
  if backend.name() == "cmux" then
    log.info("refresh (Dar/cmux): restarting " .. #ps .. " session(s) via respawn-pane")
    local done = 0
    for _, s in ipairs(ps) do
      backend.session_restart(s.id, function(ok2)
        done = done + 1
        if ok2 then
          vim.notify("agent-deck: restarted " .. (s.title or s.id))
        else
          vim.notify("agent-deck: failed to restart " .. (s.title or s.id), vim.log.levels.ERROR)
        end
        if done == #ps then do_poll() end
      end)
    end
    return
  end

  -- ── agent-deck backend: full restart with workarounds ─────────────────────
  log.info("refresh (Dar): restarting " .. #ps .. " session(s) in external agent-deck")

  -- Step 1: fetch full details for all sessions to capture their claude_session_id
  local count    = #ps
  local fetched  = 0
  local details  = {}  -- agent-deck session id → full session data (including claude_session_id)

  for _, s in ipairs(ps) do
    backend.session_show(s.id, function(ok, data)
      fetched = fetched + 1
      if ok and type(data) == "table" then
        details[s.id] = data
        log.debug("refresh (Dar): saved claude_session_id=" .. (data.claude_session_id or "nil")
          .. " for " .. s.id)
      else
        log.warn("refresh (Dar): session_show failed for " .. s.id .. " — restart may collide")
      end
      if fetched == count then
        -- Step 2: look up codex thread IDs from persist
        local persist = require("agent-deck.persist")
        local codex_threads = {}
        for _, s2 in ipairs(ps) do
          local tool = (details[s2.id] or {}).tool or s2.tool or ""
          if tool == "codex" then
            local saved = persist.get_codex_thread(s2.id)
            if saved and saved ~= "" then
              codex_threads[s2.id] = saved
              log.debug("refresh (Dar): persisted codex_thread_id=" .. saved .. " for " .. s2.id)
            end
          end
        end

        -- Step 3: restart each session
        local done = 0
        local function on_restart_done(s2, ok2)
          done = done + 1
          local tool = (details[s2.id] or {}).tool or s2.tool or ""
          if ok2 then
            vim.notify("agent-deck: restarted " .. (s2.title or s2.id))
            local orig_id = details[s2.id] and details[s2.id].claude_session_id
            if orig_id and orig_id ~= "" then
              log.debug("refresh (Dar): restoring claude_session_id=" .. orig_id .. " for " .. s2.id)
              backend.session_set(s2.id, "claude-session-id", orig_id, function() end)
            end
            if tool == "codex" and codex_threads[s2.id] then
              backend.session_set(s2.id, "command", "codex", function() end)
            end
          else
            log.error("refresh (Dar): session_restart failed for " .. (s2.title or s2.id))
            vim.notify("agent-deck: failed to restart " .. (s2.title or s2.id), vim.log.levels.ERROR)
          end
          if done == count then do_poll() end
        end

        for _, s2 in ipairs(ps) do
          local tool = (details[s2.id] or {}).tool or s2.tool or ""
          local thread_id = codex_threads[s2.id]
          if tool == "codex" and thread_id then
            -- agent-deck "session restart" uses its own thread resolution which
            -- picks the wrong thread. Workaround: stop → set command → start.
            log.debug("refresh (Dar): stop→set→start for codex " .. s2.id
              .. " thread=" .. thread_id)
            backend.session_stop(s2.id, function()
              backend.session_set(s2.id, "command", "codex resume " .. thread_id, function()
                backend.session_start(s2.id, function(ok2)
                  on_restart_done(s2, ok2)
                end)
              end)
            end)
          else
            backend.session_restart(s2.id, function(ok2) on_restart_done(s2, ok2) end)
          end
        end
      end
    end)
  end
end

--- Kill all native terminal buffers in Neovide and respawn fresh.
--- Use to reload latest claude session state inside Neovide.
function M.refresh_sessions()
  require("agent-deck.ui.parallel").refresh()
end

--- Scan `list --json` for sessions matching the current project's group or path.
--- Add untracked session IDs to the persist map.
function M.import_sessions()
  local state   = require("agent-deck.state")
  local persist = require("agent-deck.persist")
  local project = state.current_project
  if not project then
    vim.notify("agent-deck: no current project", vim.log.levels.WARN)
    return
  end

  local cwd = vim.fn.getcwd()
  require("agent-deck.backend").list_sessions(function(ok, sessions)
    if not ok or type(sessions) ~= "table" then
      vim.notify("agent-deck: failed to list sessions", vim.log.levels.ERROR)
      return
    end

    local added = 0
    for _, s in ipairs(sessions) do
      local matches_group = s.group and s.group:find(project, 1, true)
      local matches_path  = s.path  and s.path:find(cwd,     1, true)
      if matches_group or matches_path then
        local entry = persist.get(project)
        local already = false
        if entry and entry.sessions then
          for _, id in ipairs(entry.sessions) do
            if id == s.id then already = true; break end
          end
        end
        if not already then
          persist.add_session(project, s.id)
          added = added + 1
        end
      end
    end

    state.set_sessions(sessions)
    vim.notify(string.format("agent-deck: imported %d session(s) into '%s'", added, project))
  end)
end

--- Stop all sessions belonging to the current project.
function M.kill_all()
  local state   = require("agent-deck.state")
  local backend = require("agent-deck.backend")
  local ps      = state.project_sessions()
  if #ps == 0 then
    vim.notify("agent-deck: no sessions for project", vim.log.levels.WARN)
    return
  end
  for _, s in ipairs(ps) do
    backend.session_stop(s.id, function(ok, _)
      if ok then
        vim.notify("agent-deck: stopped " .. (s.title or s.id))
      end
    end)
  end
end

--- Attach an existing agent-deck group into Neovide (Dag → "Attach existing group").
---
--- Flow:
---   1. List all groups from agent-deck (group list --json)
---   2. User picks a group via vim.ui.select
---   3. Fetch full session list, filter to the chosen group
---   4. Update state.current_project and persist map for this cwd
---   5. Open the sessions via spawn_sessions (asks split/float/single)
---
--- Why slugify?
---   agent-deck group names are arbitrary strings (e.g. "Post Service").
---   Internally we use slugs (e.g. "post-service") as map keys. Slugifying
---   ensures consistency with auto-detected project names from group.lua.
local function attach_group()
  local backend = require("agent-deck.backend")
  local state   = require("agent-deck.state")
  local persist = require("agent-deck.persist")
  local grp     = require("agent-deck.group")

  backend.group_list(function(ok, data)
    if not ok or type(data) ~= "table" then
      log.error("attach_group: group_list failed")
      vim.notify("agent-deck: failed to list groups", vim.log.levels.ERROR)
      return
    end

    local groups = data.groups or {}
    if #groups == 0 then
      vim.notify("agent-deck: no groups found", vim.log.levels.WARN)
      return
    end
    log.debug("attach_group: got " .. #groups .. " group(s) from agent-deck")

    -- Build display items: "name (N sessions)"
    local items = {}
    for _, g in ipairs(groups) do
      table.insert(items, string.format("%s  (%d sessions)", g.name, g.session_count or 0))
    end

    vim.schedule(function()
      vim.ui.select(items, { prompt = "Attach group:" }, function(choice, idx)
        if not choice or not idx then return end
        local group_name = groups[idx].name
        local slug       = grp.slugify(group_name)
        log.info("attach_group: selected group='" .. group_name .. "', slug=" .. slug)

        -- Fetch the full session list; filter to only this group's sessions
        backend.list_sessions(function(ok2, sessions)
          if not ok2 or type(sessions) ~= "table" then
            log.error("attach_group: list_sessions failed after group pick")
            vim.notify("agent-deck: failed to list sessions", vim.log.levels.ERROR)
            return
          end

          local group_sessions = {}
          for _, s in ipairs(sessions) do
            if s.group == group_name then
              table.insert(group_sessions, s)
            end
          end

          if #group_sessions == 0 then
            vim.notify("agent-deck: group '" .. group_name .. "' has no sessions", vim.log.levels.WARN)
            return
          end
          log.info("attach_group: found " .. #group_sessions .. " session(s) in group '" .. group_name .. "'")

          -- Pin cwd → slug so future restarts resolve to this group without Dag
          state.set_project(slug)
          persist.save_cwd_project(vim.fn.getcwd(), slug)
          state.set_sessions(sessions)
          for _, s in ipairs(group_sessions) do
            persist.add_session(slug, s.id)
          end

          vim.notify(string.format("agent-deck: attached '%s' — %d session(s)", group_name, #group_sessions))

          -- Open sessions in Neovide; spawn_sessions handles layout selection
          -- and calls set_last() to persist the selection for Dal
          vim.schedule(function()
            require("agent-deck.ui.picker").spawn_sessions(group_sessions)
          end)
        end)
      end)
    end)
  end)
end

--- Create a new named group in agent-deck and move current sessions into it.
---
--- Flow:
---   1. User provides a group name (default = current project slug)
---   2. Slugify the name → use as new project key
---   3. Migrate old sessions from old project key to new key in persist
---   4. Create the group in agent-deck (group create — required before group move)
---   5. Move each current project session into the new group (group move)
---   6. Save cwd → new slug mapping
---
--- Why group_create before group_move?
---   agent-deck requires the group to exist before sessions can be moved into it.
---   group_move silently fails (no error, no-op) if the target group doesn't exist.
---   We call group_create first even if the group already exists (idempotent).
local function create_group()
  local state   = require("agent-deck.state")
  local persist = require("agent-deck.persist")
  local grp     = require("agent-deck.group")
  local backend = require("agent-deck.backend")
  local current = state.current_project or grp.current_project()

  vim.ui.input({
    prompt  = "New group name: ",
    default = current,
  }, function(input)
    if not input or input == "" then return end
    local slug = grp.slugify(input)
    log.info("create_group: new slug=" .. slug .. " (was=" .. (current or "nil") .. ")")
    state.set_project(slug)
    persist.save_cwd_project(vim.fn.getcwd(), slug)

    -- If the slug changed, migrate sessions from the old key to the new one
    -- so existing tracked sessions are not orphaned under the old project key
    if slug ~= current then
      local old_entry = persist.get(current) or {}
      local new_entry = persist.get(slug)   or {}
      new_entry.sessions = vim.list_extend(
        new_entry.sessions or {},
        old_entry.sessions or {}
      )
      new_entry.group = slug
      persist.set(slug, new_entry)
      log.info("create_group: migrated " .. #(old_entry.sessions or {}) .. " session(s) from " .. (current or "nil") .. " → " .. slug)
    end

    local ps = state.project_sessions()
    -- Must create group first — group_move fails silently if group doesn't exist
    backend.group_create(slug, function(ok, _)
      if not ok then
        log.warn("create_group: group_create failed for " .. slug .. " (may already exist — continuing)")
        vim.notify("agent-deck: failed to create group " .. slug, vim.log.levels.WARN)
      end
      for _, s in ipairs(ps) do
        backend.group_move(s.id, slug, function(ok2, _)
          if not ok2 then
            log.warn("create_group: group_move failed for " .. (s.title or s.id) .. " → " .. slug)
            vim.notify("agent-deck: failed to move " .. (s.title or s.id) .. " → " .. slug, vim.log.levels.WARN)
          else
            log.debug("create_group: moved " .. (s.title or s.id) .. " → " .. slug)
          end
        end)
      end
      do_poll()
    end)
    vim.notify("agent-deck: project group → " .. slug)
  end)
end

--- Pick between attaching an existing group or creating a new one.
function M.set_group()
  vim.ui.select(
    { "Attach existing group", "Create new group" },
    { prompt = "Group action:" },
    function(choice)
      if not choice then return end
      if choice:match("^Attach") then
        attach_group()
      else
        create_group()
      end
    end
  )
end

return M
