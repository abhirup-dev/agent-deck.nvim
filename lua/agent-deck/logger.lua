-- logger.lua — structured debug logger for agent-deck
--
-- Why a dedicated logger instead of raw vim.notify?
--   vim.notify is user-facing (shown in statusline/popups). Debug output
--   during normal operation would be noisy. This logger writes everything
--   to a persistent log file so decisions can be inspected post-hoc, and
--   only surfaces WARN/ERROR through vim.notify by default.
--
-- Log file:  ~/.local/share/nvim/agent-deck/debug.log
-- Commands:  :AgentDeckLog  — open log in split
--            :AgentDeckLogClear — truncate log file

local M = {}

local LOG_FILE = vim.fn.stdpath("data") .. "/agent-deck/debug.log"
local _debug_enabled = false  -- extra vim.notify for DEBUG level

-- ── Internal helpers ─────────────────────────────────────────────────────────

local LEVELS = { DEBUG = "DEBUG", INFO = "INFO", WARN = "WARN", ERROR = "ERROR" }

local function timestamp()
  return os.date("%H:%M:%S")
end

local function write_line(level, msg)
  local line = string.format("[%s] [%-5s] %s\n", timestamp(), level, msg)
  -- Append to log file (non-blocking, best-effort)
  local f = io.open(LOG_FILE, "a")
  if f then
    f:write(line)
    f:close()
  end
end

local function notify_level(level)
  if level == "ERROR" then return vim.log.levels.ERROR end
  if level == "WARN"  then return vim.log.levels.WARN  end
  return vim.log.levels.INFO
end

local function log(level, msg)
  write_line(level, msg)
  if level == "ERROR" or level == "WARN" then
    vim.schedule(function()
      vim.notify("agent-deck: " .. msg, notify_level(level))
    end)
  elseif level == "DEBUG" and _debug_enabled then
    vim.schedule(function()
      vim.notify("[ad:dbg] " .. msg, vim.log.levels.DEBUG)
    end)
  end
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Log a debug message (file only unless debug mode enabled).
--- Use for low-level decisions: buffer reuse, session ID lookups, etc.
function M.debug(msg) log("DEBUG", msg) end

--- Log an informational event (file only).
--- Use for state transitions: project set, session loaded, group synced.
function M.info(msg)  log("INFO",  msg) end

--- Log a warning — also surfaces via vim.notify.
function M.warn(msg)  log("WARN",  msg) end

--- Log an error — also surfaces via vim.notify.
function M.error(msg) log("ERROR", msg) end

--- Enable DEBUG messages in vim.notify (useful during active debugging).
function M.enable_debug()
  _debug_enabled = true
  M.info("debug mode enabled — DEBUG messages will appear in vim.notify")
end

function M.disable_debug()
  _debug_enabled = false
  M.info("debug mode disabled")
end

function M.debug_enabled() return _debug_enabled end

--- Open the log file in a bottom split for inspection.
function M.show_log()
  vim.fn.mkdir(vim.fn.fnamemodify(LOG_FILE, ":h"), "p")
  -- Touch the file if it doesn't exist yet
  local f = io.open(LOG_FILE, "a") ; if f then f:close() end
  vim.cmd("botright split " .. vim.fn.fnameescape(LOG_FILE))
  vim.cmd("normal! G")   -- jump to end (most recent entries)
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].bufhidden = "wipe"
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, silent = true })
  vim.keymap.set("n", "R", function()        -- manual refresh
    vim.cmd("edit!")
    vim.cmd("normal! G")
  end, { buffer = buf, silent = true, desc = "reload log" })
end

--- Truncate the log file.
function M.clear_log()
  local f = io.open(LOG_FILE, "w") ; if f then f:close() end
  M.info("log cleared")
end

return M
