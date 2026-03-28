-- backend/cmux_status.lua — .jsonl tail parser for session status detection
--
-- Claude stores conversation state in .jsonl files under:
--   ~/.claude/projects/<encoded-path>/<session-id>.jsonl
--
-- This module reads the tail of a .jsonl file (last 8KB) and determines
-- the session's status based on the last JSON entry:
--
--   type == "assistant" + stop_reason == "end_turn" → "waiting"
--     (Claude finished responding, awaiting user input)
--
--   type == "human" or "user" → "running"
--     (user sent a message, Claude is processing)
--
--   file missing or empty → "idle"
--     (session exists but no conversation yet)
--
-- Performance: single seek + read of at most 8KB — sub-millisecond for any
-- file size. No full file scan needed.
local M = {}

local log          = require("agent-deck.logger")
local claude_paths = require("agent-deck.claude_paths")

--- Detect the status of a Claude session by reading the tail of its .jsonl file.
---
--- @param path string     The project working directory (absolute path)
--- @param session_id string  The claude_session_id (UUID)
--- @return string  One of: "waiting", "running", "idle"
function M.detect(path, session_id)
  if not path or not session_id or session_id == "" then
    return "idle"
  end

  local fpath = claude_paths.conv_path(path, session_id)
  local f = io.open(fpath, "r")
  if not f then
    log.debug("cmux_status.detect: file not found — " .. fpath)
    return "idle"
  end

  -- Seek to end minus 8KB and read the tail
  local size = f:seek("end")
  if size == 0 then
    f:close()
    return "idle"
  end

  local seek_pos = math.max(0, size - 8192)
  f:seek("set", seek_pos)
  local tail = f:read("*a")
  f:close()

  if not tail or tail == "" then
    return "idle"
  end

  -- Find the last non-empty line (JSON entry)
  local last_line = nil
  for line in tail:gmatch("[^\n]+") do
    if line:match("%S") then
      last_line = line
    end
  end

  if not last_line then
    return "idle"
  end

  local ok, entry = pcall(vim.json.decode, last_line)
  if not ok or type(entry) ~= "table" then
    log.debug("cmux_status.detect: failed to parse last JSON line in " .. fpath)
    return "idle"
  end

  -- Decision tree based on entry type and stop_reason
  local entry_type = entry.type
  if entry_type == "assistant" then
    if entry.stop_reason == "end_turn" then
      return "waiting"
    end
    -- Assistant message without end_turn — still generating
    return "running"
  elseif entry_type == "human" or entry_type == "user" then
    return "running"
  end

  -- Unknown entry type — default to idle
  return "idle"
end

return M
