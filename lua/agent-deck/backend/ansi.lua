-- backend/ansi.lua — ANSI escape sequence stripping utility
--
-- Used by the cmux backend to clean raw terminal output from
-- `cmux read-screen` before presenting it to the user.
-- Strips CSI sequences, OSC sequences, single-char escapes,
-- and carriage returns.
local M = {}

--- Strip ANSI escape sequences from terminal output text.
--- Returns clean plain text suitable for display in a Neovim buffer.
function M.strip(text)
  if not text then return "" end
  text = text:gsub("\27%[[\032-\063]*[\064-\126]", "")  -- CSI sequences (e.g. \27[0m, \27[38;5;12m)
  text = text:gsub("\27%].-\a", "")                      -- OSC sequences (BEL terminated)
  text = text:gsub("\27%].-\27\\", "")                   -- OSC sequences (ST terminated)
  text = text:gsub("\27.", "")                            -- single-char escape sequences
  text = text:gsub("\r", "")                              -- carriage returns
  return text
end

return M
