-- ui/send.lua — visual send + compose float
local M = {}

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function get_visual_selection()
  -- Works in both charwise and linewise visual modes.
  -- Call after leaving visual mode (operator-pending or <leader> mapping exits it).
  local start_pos = vim.fn.getpos("'<")
  local end_pos   = vim.fn.getpos("'>")
  local mode      = vim.fn.getregtype("")

  -- nvim 0.10+: vim.fn.getregion
  local ok, lines = pcall(vim.fn.getregion, start_pos, end_pos, { type = mode })
  if ok and type(lines) == "table" then
    return table.concat(lines, "\n")
  end

  -- fallback
  local raw = vim.fn.getline(start_pos[2], end_pos[2])
  if type(raw) == "string" then return raw end
  return table.concat(raw, "\n")
end

--- Ensure a session is in a state that accepts sends (running or waiting).
--- If idle or stopped, starts it first. cb(success:bool).
local function ensure_sendable(session, cb)
  if session.status == "running" or session.status == "waiting" then
    cb(true)
    return
  end
  if session.status == "idle" or session.status == "stopped" then
    require("agent-deck.cli").session_start(session.id, function(ok, _)
      if ok then
        -- Small delay to let the agent process reach waiting state
        vim.defer_fn(function() cb(true) end, 600)
      else
        cb(false)
      end
    end)
  else
    -- error state — can't send
    cb(false)
  end
end

local function do_send(text)
  local state   = require("agent-deck.state")
  local session = state.primary_session()

  if not session then
    vim.notify(
      "agent-deck: no session for project '" .. (state.current_project or "?") .. "'",
      vim.log.levels.WARN
    )
    return
  end

  ensure_sendable(session, function(ready)
    if not ready then
      vim.notify("agent-deck: could not start session for send", vim.log.levels.ERROR)
      return
    end
    require("agent-deck.cli").session_send(session.id, text, { no_wait = true }, function(ok, _)
      if ok then
        vim.notify("agent-deck: sent → " .. (session.title or session.id))
      else
        vim.notify("agent-deck: send failed", vim.log.levels.ERROR)
      end
    end)
  end)
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Send the current visual selection to the primary project session.
function M.send_selection()
  local text = get_visual_selection()
  if not text or text:match("^%s*$") then
    vim.notify("agent-deck: no selection", vim.log.levels.WARN)
    return
  end
  do_send(text)
end

--- Open a scratch float for composing a multi-line prompt.
--- <C-CR> submits, <Esc> cancels.
function M.compose()
  local usable_h = vim.o.lines
    - vim.o.cmdheight
    - (vim.o.laststatus > 0 and 1 or 0)
    - (vim.o.showtabline > 0 and 1 or 0)

  local width  = math.floor(vim.o.columns * 0.60)
  local height = math.floor(usable_h    * 0.40)
  local row    = math.floor((usable_h   - height) / 2)
  local col    = math.floor((vim.o.columns - width) / 2)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype  = "markdown"

  local win = vim.api.nvim_open_win(buf, true, {
    relative   = "editor",
    row        = row,
    col        = col,
    width      = width,
    height     = height,
    border     = "rounded",
    title      = " Compose prompt · <C-CR> send · <Esc> cancel ",
    title_pos  = "center",
    style      = "minimal",
  })

  -- Enter insert mode immediately
  vim.cmd("startinsert")

  local function submit()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local text  = table.concat(lines, "\n"):match("^%s*(.-)%s*$")
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if text and text ~= "" then
      do_send(text)
    end
  end

  local opts = { buffer = buf, silent = true }
  -- <C-CR> to submit (not <C-s> — conflicts with Claude Code stash keybinding)
  vim.keymap.set({ "i", "n" }, "<C-CR>", submit,                              opts)
  vim.keymap.set({ "i", "n" }, "<Esc>",  function()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end, opts)

  -- Unused but helpful: show win var for debugging
  vim.w[win].agent_deck_compose = true
end

return M
