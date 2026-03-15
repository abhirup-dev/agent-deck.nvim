-- state.lua — runtime session cache (in-memory, not persisted)
--
-- This module is the single source of truth for what is currently known
-- about sessions within this Neovim instance. Everything here is ephemeral:
-- it is rebuilt on every poll and lost on Neovim restart. For durable
-- storage use persist.lua.
--
-- Notable design choices:
--   • _session_bufs: maps session_id → bufnr so reopening a session from the
--     picker is instant (no new process, no re-spawn). The buffer stays alive
--     via bufhidden=hide even after its window is closed.
--   • buf_alive(): only returns true if the underlying terminal job is still
--     running. A valid-but-dead buffer is silently evicted so the next open
--     spawns fresh.
local M = {}

M.sessions        = {}   -- full list from `agent-deck list --json`
M.status          = {}   -- aggregated counts from `agent-deck status --json`
M.current_project = nil  -- slug string, e.g. "post-service-group"
M._picker_open    = false
M._session_bufs   = {}   -- session_id → bufnr (native terminal buffers, bufhidden=hide)

-- ── Buffer liveness check ─────────────────────────────────────────────────────

-- buf_alive: returns true only when the buffer exists AND its terminal job is
-- still running. We use jobwait with a 0-ms timeout as a non-blocking probe.
-- A return value of -1 means "still running"; anything else means exited.
-- This is the gate for buffer reuse — stale mappings are evicted lazily on
-- the next get_buf call rather than proactively, keeping the hot path cheap.
local function buf_alive(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then return false end
  local job_id = vim.b[buf].terminal_job_id
  if not job_id then return false end
  return vim.fn.jobwait({job_id}, 0)[1] == -1  -- -1 = still running
end

-- ── Buffer cache API ──────────────────────────────────────────────────────────

--- Return the cached bufnr for a session if its process is still alive.
--- Evicts the mapping and returns nil if the buffer is dead or missing.
--- Callers use this to decide: reuse (fast path) vs termopen (slow path).
function M.get_buf(session_id)
  local buf = M._session_bufs[session_id]
  if buf and buf_alive(buf) then return buf end
  -- Stale entry — evict lazily so the next open spawns a fresh process
  M._session_bufs[session_id] = nil
  return nil
end

--- Register a new native terminal buffer for a session.
--- Called immediately after vim.fn.termopen() so all subsequent opens reuse it.
function M.set_buf(session_id, buf)
  M._session_bufs[session_id] = buf
end

--- Remove the buffer mapping for a session (called from TermClose autocmd).
--- Does NOT kill the buffer — TermClose fires after the process already exited.
function M.clear_buf(session_id)
  M._session_bufs[session_id] = nil
end

-- ── Session list API ──────────────────────────────────────────────────────────

--- Replace the full session list (called after every `agent-deck list --json`).
function M.set_sessions(sessions)
  M.sessions = sessions or {}
end

--- Replace the aggregated status counts (called after every `agent-deck status --json`).
function M.set_status(status)
  M.status = status or {}
end

--- Set the active project slug.
--- This controls which sessions appear in the picker's project tier and which
--- sessions are targeted by refresh/kill/restart commands.
function M.set_project(project)
  M.current_project = project
end

-- ── Project session helpers ───────────────────────────────────────────────────

--- Return the subset of M.sessions that belong to the current project.
--- Membership is determined by the persist map, NOT by the session's group
--- field — this lets us track sessions regardless of how they were created.
function M.project_sessions()
  if not M.current_project then return {} end
  local ok, persist = pcall(require, "agent-deck.persist")
  if not ok then return {} end
  local entry = persist.get(M.current_project)
  if not entry or not entry.sessions then return {} end

  -- Build a set of persisted IDs for O(1) lookup
  local id_set = {}
  for _, id in ipairs(entry.sessions) do
    id_set[id] = true
  end

  -- Filter live session list to only those in the project's persist entry
  local result = {}
  for _, s in ipairs(M.sessions) do
    if id_set[s.id] then
      table.insert(result, s)
    end
  end
  return result
end

--- Lookup a single session object by its agent-deck ID.
function M.get_session(id)
  for _, s in ipairs(M.sessions) do
    if s.id == id then return s end
  end
  return nil
end

--- Return the highest-priority session for the current project.
--- Priority order: running > waiting > any (first in list).
--- Used by send.lua / statusline to pick a default target.
function M.primary_session()
  local ps = M.project_sessions()
  for _, s in ipairs(ps) do
    if s.status == "running" then return s end
  end
  for _, s in ipairs(ps) do
    if s.status == "waiting" then return s end
  end
  return ps[1]
end

return M
