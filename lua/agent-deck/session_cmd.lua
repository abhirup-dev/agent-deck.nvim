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

-- ── Agent-deck config integration ───────────────────────────────────────────
-- Reads ~/.agent-deck/config.toml to use the same claude command, env file,
-- and flags that agent-deck uses when launching sessions in tmux.

local _ad_config = nil         -- lazy-loaded
local _custom_claude_cmd = nil -- set via setup({ custom_claude_cmd = "..." })

--- Parse the agent-deck config.toml for [claude] section.
--- Returns { command = "...", env_file = "...", auto_mode = bool }
local function get_ad_config()
  if _ad_config then return _ad_config end
  _ad_config = {}
  local path = vim.fn.expand("~/.agent-deck/config.toml")
  local f = io.open(path, "r")
  if not f then return _ad_config end
  local content = f:read("*a")
  f:close()
  -- Parse [claude] section
  local in_claude = false
  for line in content:gmatch("[^\r\n]+") do
    if line:match("^%[claude%]") then
      in_claude = true
    elseif line:match("^%[") then
      in_claude = false
    elseif in_claude then
      local k, v = line:match("^%s*(%w+)%s*=%s*(.+)$")
      if k and v then
        v = v:match('^"(.*)"$') or v  -- strip quotes
        if v == "true" then v = true
        elseif v == "false" then v = false end
        _ad_config[k] = v
      end
    end
  end
  return _ad_config
end

--- Set the custom claude command override from setup().
--- @param cmd string|nil
function M.set_custom_claude_cmd(cmd)
  _custom_claude_cmd = cmd
end

--- Get the claude base command.
--- Priority: custom_claude_cmd (setup) > agent-deck config.toml > "claude"
local function claude_base_cmd()
  if _custom_claude_cmd and _custom_claude_cmd ~= "" then return _custom_claude_cmd end
  local cfg = get_ad_config()
  return (cfg.command and cfg.command ~= "") and cfg.command or "claude"
end

--- Build env prefix string from agent-deck's claude env_file.
local function env_prefix()
  local cfg = get_ad_config()
  if not cfg.env_file or cfg.env_file == "" then return "" end
  local f = io.open(cfg.env_file, "r")
  if not f then return "" end
  local parts = {}
  for line in f:lines() do
    -- Skip comments and blank lines
    if not line:match("^%s*#") and line:match("=") then
      local k, v = line:match("^%s*([%w_]+)%s*=%s*(.+)$")
      if k and v then
        v = v:match('^"(.*)"$') or v  -- strip quotes
        parts[#parts + 1] = k .. "=" .. vim.fn.shellescape(v)
      end
    end
  end
  f:close()
  if #parts == 0 then return "" end
  return table.concat(parts, " ") .. " "
end

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
    local cmd = env_prefix() .. claude_base_cmd() .. " --resume " .. session.claude_session_id
    log.debug("session_cmd.build_cmd: " .. cmd .. " for session " .. session.id)
    return cmd
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
    local prefix = env_prefix()
    local bin = claude_base_cmd()
    local status = session.status or ""
    local has_conv = conv_exists_fn and conv_exists_fn(cwd, session.claude_session_id)
    log.debug("session_cmd.build_cmd_new: sid=" .. session.id
      .. " claude_session_id=" .. session.claude_session_id
      .. " status=" .. status .. " has_conv=" .. tostring(has_conv)
      .. " cwd=" .. cwd)
    if has_conv then
      -- Conv file exists → --resume always works
      local cmd = prefix .. bin .. " --resume " .. session.claude_session_id
      log.info("session_cmd.build_cmd_new: " .. cmd .. " for session " .. session.id)
      return cmd
    elseif status == "running" or status == "waiting" then
      -- Session running in agent-deck tmux but no .jsonl yet → can't open in
      -- Neovim (--session-id = "already in use", --resume = "no conversation").
      -- Send first message in agent-deck tmux to create .jsonl, then retry.
      log.warn("session_cmd.build_cmd_new: session " .. session.id
        .. " is " .. status .. " but no .jsonl — need first message in agent-deck first")
      return nil
    else
      -- Session not running, no conv file → --session-id claims the UUID
      local cmd = prefix .. bin .. " --session-id " .. session.claude_session_id
      log.info("session_cmd.build_cmd_new: " .. cmd .. " (new) for session " .. session.id)
      return cmd
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
