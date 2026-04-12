-- claude_paths.lua — Claude conversation file path utilities
--
-- Extracted from picker.lua to share with cmux_status.lua and other modules
-- that need to locate Claude's .jsonl conversation files.
--
-- Claude stores conversations under:
--   ~/.claude/projects/<encoded-path>/<session-id>.jsonl
-- where <encoded-path> is the absolute project path with every "/" replaced by "-".
local M = {}

--- Encode an absolute path the way Claude does for its projects directory.
--- Every "/" is replaced with "-".
--- @param path string  Absolute project path (e.g. "/Users/me/project")
--- @return string      Encoded path (e.g. "-Users-me-project")
function M.encode_path(path)
  if not path then return "" end
  -- Claude replaces both "/" and "." with "-" in project directory encoding
  return path:gsub("[/.]", "-")
end

--- Return the full .jsonl conversation file path for a given project path
--- and claude session ID.
--- @param path string        The project working directory (absolute path)
--- @param session_id string  The claude_session_id (UUID)
--- @return string            Full path to the .jsonl file
function M.conv_path(path, session_id)
  local encoded = M.encode_path(path)
  return vim.fn.expand("~/.claude/projects/") .. encoded .. "/" .. session_id .. ".jsonl"
end

--- Return true if a .jsonl conversation file exists for the given claude session ID
--- under the encoded project path in ~/.claude/projects/.
---
--- This predicate is the single source of truth for distinguishing a brand-new
--- session (file absent) from an existing conversation (file present).
--- @param path string        The project working directory (absolute path)
--- @param session_id string  The claude_session_id (UUID)
--- @return boolean
function M.conv_exists(path, session_id)
  if not path or not session_id or session_id == "" then return false end
  local fpath = M.conv_path(path, session_id)
  return vim.fn.filereadable(fpath) == 1
end

return M
