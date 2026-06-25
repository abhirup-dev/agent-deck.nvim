-- persist.lua — durable project→session map
--
-- Storage: ~/.local/share/nvim/agent-deck/map.json
--
-- Schema:
--   {
--     "project-slug": {
--       group:    "project-slug",          -- redundant, kept for debugging
--       sessions: ["id1", "id2", ...],     -- ALL sessions tracked for this project
--       loaded:   { layout, session_ids }  -- last Dal selection (subset of sessions)
--     },
--     "_codex_threads": { "<agent-deck-session-id>": "<codex-thread-id>" },
--     "_cwd_projects": { "/abs/path": "project-slug" },
--     -- ^^ reverse map: cwd → slug so setup() survives DirChanged / Neovide restart
--   }
--
-- Key design decisions:
--   • sessions vs loaded: "sessions" is the full tracked set (everything in the group).
--     "loaded" is what was explicitly opened via the picker. Dal restores "loaded" only.
--     This lets new sessions get auto-synced into "sessions" without polluting Dal.
--   • Atomic save: write to .tmp then rename to avoid partial JSON on crash.
--   • load_project() prune guard: if state.sessions is empty (before first poll),
--     skip pruning so persisted IDs are not lost before we have live data to compare.
--   • _cwd_projects: needed because group.current_project() (git root slug) can differ
--     from the explicit slug set via Dag. Without this, DirChanged would reset the
--     project to the wrong slug and Dal would fail after a Neovide restart.
local M = {}

local log = require("agent-deck.logger")

local DATA_DIR = vim.fn.stdpath("data") .. "/agent-deck"
local MAP_FILE = DATA_DIR .. "/map.json"

local _map = {}

local function ensure_dir()
  vim.fn.mkdir(DATA_DIR, "p")
end

--- Load map.json from disk into _map.
--- Also runs one-time migrations for old schema formats.
function M.load()
  ensure_dir()
  local ok, lines = pcall(vim.fn.readfile, MAP_FILE)
  if not ok or #lines == 0 then
    log.debug("persist.load: map file empty or missing — starting fresh")
    _map = {}
    return
  end
  local raw = table.concat(lines, "\n")
  local dec_ok, data = pcall(vim.json.decode, raw)
  _map = (dec_ok and type(data) == "table") and data or {}
  log.debug("persist.load: loaded map with " .. vim.tbl_count(_map) .. " top-level keys")

  -- Migration: old global _last_selection → per-project loaded field.
  -- The old schema stored the last picker selection as a single global key,
  -- which could not support multiple projects. New schema nests it per-project.
  local sel = _map["_last_selection"]
  if sel and sel.project then
    local proj = sel.project
    log.info("persist.load: migrating _last_selection for project=" .. proj)
    if not _map[proj] then
      _map[proj] = { group = proj, sessions = {} }
    end
    if not _map[proj].loaded then
      _map[proj].loaded = { layout = sel.layout, session_ids = sel.session_ids }
    end
    _map["_last_selection"] = nil
    M.save()
  end
end

--- Atomically write _map to disk (tmp + rename).
function M.save()
  ensure_dir()
  local tmp = MAP_FILE .. ".tmp"
  local enc_ok, encoded = pcall(vim.json.encode, _map)
  if not enc_ok then return end
  pcall(vim.fn.writefile, { encoded }, tmp)
  vim.uv.fs_rename(tmp, MAP_FILE, function() end)
end

--- Get the entry for a project (or nil).
function M.get(project)
  return _map[project]
end

--- Replace (or create) the entire entry for a project.
function M.set(project, entry)
  _map[project] = entry
  M.save()
end

--- List all tracked project slugs (excludes internal _ keys).
function M.all_projects()
  local result = {}
  for k in pairs(_map) do
    if not k:match("^_") then
      table.insert(result, k)
    end
  end
  return result
end

--- Add a session ID to a project's tracked list (idempotent).
--- Called from: auto-sync in do_poll, attach_group, new_session, import_sessions.
function M.add_session(project, session_id)
  if not _map[project] then
    _map[project] = { group = project, sessions = {} }
  end
  _map[project].sessions = _map[project].sessions or {}
  for _, id in ipairs(_map[project].sessions) do
    if id == session_id then return end  -- already tracked, skip save
  end
  log.debug("persist.add_session: " .. session_id .. " → project=" .. project)
  table.insert(_map[project].sessions, session_id)
  M.save()
end

--- Remove a session ID from a project's tracked list.
function M.remove_session(project, session_id)
  if not _map[project] then return end
  local sessions = _map[project].sessions or {}
  local pruned = {}
  for _, id in ipairs(sessions) do
    if id ~= session_id then
      table.insert(pruned, id)
    end
  end
  _map[project].sessions = pruned
  if _map["_codex_threads"] then
    _map["_codex_threads"][session_id] = nil
  end
  M.save()
end

--- Persist the loaded sessions for a project (layout + IDs).
--- `sessions` = only the sessions actually opened (not the whole group).
function M.save_last(layout, sessions, project)
  if not project then return end
  if not _map[project] then
    _map[project] = { group = project, sessions = {} }
  end
  local ids = {}
  for _, s in ipairs(sessions) do
    table.insert(ids, s.id)
  end
  _map[project].loaded = { layout = layout, session_ids = ids }
  M.save()
end

--- Return the loaded-sessions record for a project: { layout, session_ids } or nil.
function M.get_last(project)
  local entry = project and _map[project]
  return entry and entry.loaded or nil
end

--- Save cwd → project-slug mapping so setup() can restore the right project on restart.
function M.save_cwd_project(cwd, project)
  if not cwd or not project then return end
  if not _map["_cwd_projects"] then _map["_cwd_projects"] = {} end
  _map["_cwd_projects"][cwd] = project
  M.save()
end

--- Return the project slug previously associated with this cwd (or nil).
function M.get_cwd_project(cwd)
  local m = _map["_cwd_projects"]
  return m and cwd and m[cwd] or nil
end

--- Persist the Codex thread ID associated with an agent-deck session.
function M.set_codex_thread(session_id, thread_id)
  if not session_id or not thread_id or thread_id == "" then return end
  _map["_codex_threads"] = _map["_codex_threads"] or {}
  if _map["_codex_threads"][session_id] == thread_id then return end
  _map["_codex_threads"][session_id] = thread_id
  log.debug("persist.set_codex_thread: " .. session_id .. " -> " .. thread_id)
  M.save()
end

--- Return the persisted Codex thread ID for an agent-deck session (or nil).
function M.get_codex_thread(session_id)
  local m = _map["_codex_threads"]
  return m and session_id and m[session_id] or nil
end

--- Cross-reference this project's sessions with the live state cache.
---
--- Pruning rules:
---   • Skip entirely if state.sessions is empty — this happens during setup()
---     before the first poll completes. Without this guard, all persisted IDs
---     would be pruned on startup because live={} and every ID looks "missing".
---   • Drop IDs whose live status is explicitly "error" (session died permanently).
---   • Keep IDs with status=nil (session not yet returned by list, transient),
---     and all other statuses (running, waiting, idle, stopped).
---
--- No M.save() here: pruning is a transient operation derived from live state.
--- Persisting it would cause an extra write on every poll and could permanently
--- drop sessions that are temporarily missing from the list response.
function M.load_project(project)
  if not _map[project] then return end
  local ok, state = pcall(require, "agent-deck.state")
  if not ok then return end

  -- Guard: do not prune before first poll — state.sessions is empty and we
  -- would incorrectly evict all persisted IDs.
  if #state.sessions == 0 then
    log.debug("persist.load_project: skipping prune for " .. project .. " (state empty, first poll pending)")
    return
  end

  -- Build status map for O(1) lookup
  local live = {}
  for _, s in ipairs(state.sessions) do
    live[s.id] = s.status
  end

  local sessions = _map[project].sessions or {}
  local kept = {}
  local pruned_count = 0
  for _, id in ipairs(sessions) do
    local status = live[id]
    if status == "error" then
      -- Explicitly errored: remove from tracking (session is dead and won't recover)
      log.debug("persist.load_project: pruning errored session " .. id .. " from " .. project)
      pruned_count = pruned_count + 1
    else
      table.insert(kept, id)
    end
  end
  _map[project].sessions = kept
  if pruned_count > 0 then
    log.info("persist.load_project: pruned " .. pruned_count .. " errored session(s) from " .. project)
  end
  -- No M.save() — transient pruning, not a user-initiated mutation
end

-- ── cmux session metadata ────────────────────────────────────────────────────
-- When backend="cmux", session metadata is managed by the plugin (not an
-- external daemon). These accessors store per-surface data under the
-- "_cmux_sessions" key in map.json.

--- Return the cmux session metadata for a surface ID (or nil).
function M.get_cmux_session(surface_id)
  local m = _map["_cmux_sessions"]
  return m and surface_id and m[surface_id] or nil
end

--- Store cmux session metadata for a surface ID.
--- data = { surface_id, workspace_id, tool, title, path, group,
---          command, claude_session_id, created_at }
function M.set_cmux_session(surface_id, data)
  _map["_cmux_sessions"] = _map["_cmux_sessions"] or {}
  _map["_cmux_sessions"][surface_id] = data
  M.save()
end

--- Remove cmux session metadata for a surface ID.
function M.remove_cmux_session(surface_id)
  if _map["_cmux_sessions"] then
    _map["_cmux_sessions"][surface_id] = nil
    M.save()
  end
end

--- Return all cmux session metadata (table: surface_id → data).
function M.all_cmux_sessions()
  return _map["_cmux_sessions"] or {}
end

return M
