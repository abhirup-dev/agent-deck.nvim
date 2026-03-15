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
  local cli   = require("agent-deck.cli")
  local state = require("agent-deck.state")

  -- Step 1: fetch aggregate status counts (cheap, always runs)
  cli.status(function(ok, data)
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
      cli.list_sessions(function(ok2, sessions)
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
  local state = require("agent-deck.state")
  local cli   = require("agent-deck.cli")
  local ps    = state.project_sessions()
  if #ps == 0 then
    vim.notify("agent-deck: no sessions for current project", vim.log.levels.WARN)
    return
  end
  log.info("refresh (Dar): restarting " .. #ps .. " session(s) in external agent-deck")

  -- Step 1: fetch full details for all sessions to capture their claude_session_id
  local count    = #ps
  local fetched  = 0
  local details  = {}  -- agent-deck session id → full session data (including claude_session_id)

  for _, s in ipairs(ps) do
    cli.session_show(s.id, function(ok, data)
      fetched = fetched + 1
      if ok and type(data) == "table" then
        details[s.id] = data
        log.debug("refresh (Dar): saved claude_session_id=" .. (data.claude_session_id or "nil")
          .. " for " .. s.id)
      else
        log.warn("refresh (Dar): session_show failed for " .. s.id .. " — restart may collide")
      end
      if fetched == count then
        -- Step 2: restart each session, then restore its original claude_session_id
        local done = 0
        for _, s2 in ipairs(ps) do
          cli.session_restart(s2.id, function(ok2, _)
            done = done + 1
            if ok2 then
              vim.notify("agent-deck: restarted " .. (s2.title or s2.id))
              -- Restore the original claude_session_id so agent-deck keeps
              -- distinct conversations even when sessions share a path.
              -- Without this, agent-deck would assign the "last used in dir"
              -- conversation to whichever session was restarted last.
              local orig_id = details[s2.id] and details[s2.id].claude_session_id
              if orig_id and orig_id ~= "" then
                log.debug("refresh (Dar): restoring claude_session_id=" .. orig_id
                  .. " for " .. s2.id)
                cli.session_set(s2.id, "claude-session-id", orig_id, function() end)
              end
            else
              log.error("refresh (Dar): session_restart failed for " .. (s2.title or s2.id))
              vim.notify("agent-deck: failed to restart " .. (s2.title or s2.id), vim.log.levels.ERROR)
            end
            if done == count then
              do_poll()  -- refresh state cache after all restarts complete
            end
          end)
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
  require("agent-deck.cli").list_sessions(function(ok, sessions)
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
  local state = require("agent-deck.state")
  local cli   = require("agent-deck.cli")
  local ps    = state.project_sessions()
  if #ps == 0 then
    vim.notify("agent-deck: no sessions for project", vim.log.levels.WARN)
    return
  end
  for _, s in ipairs(ps) do
    cli.session_stop(s.id, function(ok, _)
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
  local cli     = require("agent-deck.cli")
  local state   = require("agent-deck.state")
  local persist = require("agent-deck.persist")
  local grp     = require("agent-deck.group")

  cli.group_list(function(ok, data)
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
        cli.list_sessions(function(ok2, sessions)
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
  local cli     = require("agent-deck.cli")
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
    cli.group_create(slug, function(ok, _)
      if not ok then
        log.warn("create_group: group_create failed for " .. slug .. " (may already exist — continuing)")
        vim.notify("agent-deck: failed to create group " .. slug, vim.log.levels.WARN)
      end
      for _, s in ipairs(ps) do
        cli.group_move(s.id, slug, function(ok2, _)
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
