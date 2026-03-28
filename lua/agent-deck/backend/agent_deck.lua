-- backend/agent_deck.lua — thin wrapper over cli.lua for the backend interface
--
-- Re-exports all cli.lua methods unchanged and adds focus_session() as a
-- no-op since agent-deck sessions live inside Neovim terminal buffers
-- (focusing is handled by the picker/parallel UI layer, not the backend).
local cli = require("agent-deck.cli")
local M = setmetatable({}, { __index = cli })

--- No-op for agent-deck backend: sessions live in Neovim terminals,
--- so "focusing" is handled by the UI layer (picker/parallel).
function M.focus_session(_, cb)
  if cb then cb(true, nil) end
end

--- Health check: verify agent-deck binary is reachable.
function M.health_check()
  local bin = vim.fn.exepath("agent-deck")
  if bin == "" then
    require("agent-deck.logger").warn("agent_deck backend: binary not found in PATH")
  end
end

return M
