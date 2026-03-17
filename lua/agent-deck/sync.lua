-- sync.lua — CLI-ahead staleness detection for parallel windows
--
-- When a Claude session is open in both a CLI tmux pane and a Neovim parallel
-- window (both using `claude --resume <id>`), they are separate processes.
-- If the user sends a message from the CLI after the Neovim buffer was opened,
-- the Neovim buffer will be behind. This module detects that condition every
-- 2 minutes and notifies the user to reopen with <leader>DaR.
--
-- Detection logic:
--   • CLI timestamp:    tmux list-panes -t <tmux_session> -F '#{pane_activity}'
--                       → Unix timestamp of last terminal output in the CLI pane
--   • Neovim timestamp: os.time() recorded in state._session_buf_times when
--                       termopen() spawned the buffer (set via state.set_buf)
--   • Stale condition:  pane_activity > buf_open_time
--
-- Only notifies when CLI is ahead. Never notifies when Neovim is ahead.
local M   = {}
local log = require("agent-deck.logger")

local INTERVAL_MS = 2 * 60 * 1000  -- 2 minutes

-- Per-session: last pane_activity value at which we notified (dedup).
-- Prevents repeated WARN for the same CLI activity timestamp.
local _notified = {}   -- session_id → pane_activity (int)
local _timer    = nil  -- vim.uv timer handle

--- Async tmux pane_activity query — mirrors cli.run_raw pattern.
--- Calls callback(pane_activity_int_or_nil).
local function tmux_pane_activity(tmux_session, callback)
  local chunks = {}
  local stdout = vim.uv.new_pipe()
  local handle
  handle = vim.uv.spawn("tmux", {
    args  = { "list-panes", "-t", tmux_session, "-F", "#{window_activity}" },
    stdio = { nil, stdout, nil },
  }, function(code)
    stdout:close()
    handle:close()
    vim.schedule(function()
      if code ~= 0 then callback(nil); return end
      callback(tonumber(vim.trim(table.concat(chunks))))
    end)
  end)
  if not handle then
    vim.schedule(function() callback(nil) end)
    return
  end
  stdout:read_start(function(_, chunk)
    if chunk then table.insert(chunks, chunk) end
  end)
end

--- Check all currently open parallel windows (async, non-blocking).
--- Notifies (WARN) only when CLI pane_activity > Neovim buf_open_time.
function M.check()
  local state = require("agent-deck.state")
  local par   = require("agent-deck.ui.parallel")
  local wins  = par.get_open_wins()
  if not wins or #wins == 0 then return end

  for _, entry in ipairs(wins) do
    local session  = entry.session
    local buf_time = state._session_buf_times[session.id]
    local tmux_s   = session.tmux_session
    if not buf_time or not tmux_s or tmux_s == "" then goto continue end

    -- Capture loop vars for async closure
    local sid   = session.id
    local title = session.title or session.id

    tmux_pane_activity(tmux_s, function(pane_activity)
      if not pane_activity then return end
      log.debug("sync.check: '" .. title .. "' pane=" .. pane_activity
        .. " buf_time=" .. buf_time .. " last_notified=" .. (_notified[sid] or 0))
      if pane_activity > buf_time and (_notified[sid] or 0) < pane_activity then
        _notified[sid] = pane_activity
        vim.notify(
          "agent-deck: '" .. title .. "' updated in CLI — reopen with <leader>DaR to sync",
          vim.log.levels.WARN
        )
      end
    end)

    ::continue::
  end
end

--- Start the 2-minute periodic staleness check timer.
function M.start_timer()
  if _timer then return end  -- already running
  _timer = vim.uv.new_timer()
  _timer:start(INTERVAL_MS, INTERVAL_MS, vim.schedule_wrap(M.check))
  log.debug("sync: timer started (" .. (INTERVAL_MS / 1000) .. "s interval)")
end

--- Stop the timer (called on VimLeavePre).
function M.stop_timer()
  if _timer then
    _timer:stop()
    _timer:close()
    _timer = nil
  end
end

--- Reset notification state for a session (e.g. after <leader>DaR refresh).
--- Not wired automatically yet — exposed for future use.
function M.reset(session_id)
  _notified[session_id] = nil
end

return M
