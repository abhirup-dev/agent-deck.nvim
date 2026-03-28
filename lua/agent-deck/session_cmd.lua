-- session_cmd.lua — shared command-building logic for terminal sessions
--
-- Extracted from picker.lua:spawn_terminal and parallel.lua:build_cmd to
-- eliminate duplication. Both the agent-deck and cmux backends need to
-- construct the right command string for spawning AI tool sessions.
--
-- Two entry points:
--   build_cmd(session)     — for existing sessions (always uses --resume)
--   build_cmd_new(session) — for new sessions (uses --session-id if no conv file)
local M = {}

local log = require("agent-deck.logger")

--- Build the command string for an EXISTING session.
---
--- This is used by parallel.lua and any code path that opens a previously-started
--- session. By the time a session reaches this function, its .jsonl conversation
--- file exists on disk and the claude_session_id is the real UUID.
--- Therefore `--resume` is always correct here.
---
--- Decision tree:
---   1. Tool is "claude" AND we have claude_session_id → `claude --resume <id>`
---   2. Tool is "codex" AND we have codex_thread_id   → `codex resume <id>`
---   3. Any other tool or no identifier                → session.command or tool name
function M.build_cmd(session)
  local tool = session.tool or "claude"
  local base_cmd = session.command or tool
  if tool == "claude" and session.claude_session_id and session.claude_session_id ~= "" then
    log.debug("session_cmd.build_cmd: claude --resume " .. session.claude_session_id
      .. " for session " .. session.id)
    return "claude --resume " .. session.claude_session_id
  end
  if tool == "codex" and session.codex_thread_id and session.codex_thread_id ~= "" then
    log.debug("session_cmd.build_cmd: codex resume " .. session.codex_thread_id
      .. " for session " .. session.id)
    return base_cmd .. " resume " .. session.codex_thread_id
  end
  log.debug("session_cmd.build_cmd: using command '" .. base_cmd .. "' for session " .. session.id)
  return base_cmd
end

--- Build the command string for a NEW or possibly-new session.
---
--- This is used by picker.lua:spawn_terminal when opening a session that may
--- have just been created. The distinction from build_cmd() is:
---
---   - If the .jsonl file EXISTS → use --resume (conversation already started)
---   - If the .jsonl file is MISSING → use --session-id (new session, stay in
---     sync with the UUID agent-deck already assigned)
---
--- @param session table  Session object with tool, claude_session_id, path, etc.
--- @param conv_exists_fn function  (path, session_id) → bool; injected for testability
function M.build_cmd_new(session, conv_exists_fn)
  local tool = session.tool or "claude"
  local cwd = session.path or vim.fn.getcwd()
  local base_cmd = session.command or tool

  if tool == "claude" and session.claude_session_id and session.claude_session_id ~= "" then
    if conv_exists_fn and conv_exists_fn(cwd, session.claude_session_id) then
      -- Case 1: conversation file exists → resume the existing session
      log.info("session_cmd.build_cmd_new: claude --resume " .. session.claude_session_id
        .. " for session " .. session.id)
      return "claude --resume " .. session.claude_session_id
    else
      -- Case 2: file absent → new session; use --session-id to stay in sync
      log.info("session_cmd.build_cmd_new: claude --session-id " .. session.claude_session_id
        .. " (new, no conv file yet) for session " .. session.id)
      return "claude --session-id " .. session.claude_session_id
    end
  elseif tool == "codex" and session.codex_thread_id and session.codex_thread_id ~= "" then
    log.info("session_cmd.build_cmd_new: codex resume " .. session.codex_thread_id
      .. " for session " .. session.id)
    return base_cmd .. " resume " .. session.codex_thread_id
  end

  -- Non-claude tool or no known resume identifier
  log.info("session_cmd.build_cmd_new: '" .. base_cmd .. "' for session " .. session.id)
  return base_cmd
end

return M
