-- backend.lua — dispatch layer for backend abstraction
--
-- Single entry point for all backend operations. Callers use
-- require("agent-deck.backend") instead of require("agent-deck.cli").
--
-- Supports two backends:
--   "agent-deck" (default) — wraps cli.lua, sessions in tmux via agent-deck daemon
--   "cmux"                 — native cmux surfaces, plugin is the daemon
--
-- init() must be called from setup() before any method is invoked.
-- All interface methods are forwarded to the active backend implementation.
local M = {}

local log   = require("agent-deck.logger")
local _impl = nil
local _name = "agent-deck"  -- default backend

--- Initialize the backend. Must be called once from setup().
--- @param backend_name string|nil  "agent-deck" (default) or "cmux"
function M.init(backend_name)
  _name = backend_name or "agent-deck"
  if _name == "cmux" then
    _impl = require("agent-deck.backend.cmux")
  else
    _impl = require("agent-deck.backend.agent_deck")
  end
  log.info("backend.init: using '" .. _name .. "' backend")
  -- Health check for cmux: verify app is running
  if _impl.health_check then
    _impl.health_check()
  end
end

--- Return the active backend name ("agent-deck" or "cmux").
function M.name()
  return _name
end

-- ── Method forwarding ────────────────────────────────────────────────────────
-- Every interface method is forwarded to the active backend implementation.
-- assert(_impl) guards against calling before init().

local METHODS = {
  "status", "list_sessions", "session_show", "session_send",
  "session_output", "session_start", "session_stop", "session_restart",
  "session_delete", "launch", "group_list", "group_create",
  "group_move", "session_set", "focus_session",
}

for _, method in ipairs(METHODS) do
  M[method] = function(...)
    assert(_impl, "backend.init() not called — call require('agent-deck').setup() first")
    return _impl[method](...)
  end
end

return M
