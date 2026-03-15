-- ui/output.lua — last-response markdown float
local M = {}

function M.show()
  local state   = require("agent-deck.state")
  local cli     = require("agent-deck.cli")
  local session = state.primary_session()

  if not session then
    vim.notify(
      "agent-deck: no session for project '" .. (state.current_project or "?") .. "'",
      vim.log.levels.WARN
    )
    return
  end

  local is_running = session.status == "running"

  cli.session_output(session.id, function(ok, data)
    if not ok then
      vim.notify("agent-deck: failed to get output", vim.log.levels.ERROR)
      return
    end

    -- Normalise output: data may be a JSON object or a raw string
    local text = ""
    if type(data) == "table" then
      text = data.output or data.text or data.content or vim.inspect(data)
    elseif type(data) == "string" then
      text = data
    end

    local lines = vim.split(text, "\n", { plain = true })

    local usable_h = vim.o.lines
      - vim.o.cmdheight
      - (vim.o.laststatus > 0 and 1 or 0)
      - (vim.o.showtabline > 0 and 1 or 0)

    local width  = math.floor(vim.o.columns * 0.70)
    local height = math.floor(usable_h      * 0.70)
    local row    = math.floor((usable_h    - height) / 2)
    local col    = math.floor((vim.o.columns - width) / 2)

    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly   = true
    vim.bo[buf].bufhidden  = "wipe"
    vim.bo[buf].filetype   = "markdown"

    local session_label = session.title or session.id
    local title
    if is_running then
      title = " [Running — previous response] " .. session_label .. " "
    else
      title = " Output: " .. session_label .. " "
    end

    local win = vim.api.nvim_open_win(buf, true, {
      relative  = "editor",
      row       = row,
      col       = col,
      width     = width,
      height    = height,
      border    = "rounded",
      title     = title,
      title_pos = "center",
      style     = "minimal",
    })

    if is_running then
      vim.notify("agent-deck: session is running — showing previous response", vim.log.levels.INFO)
    end

    local opts = { buffer = buf, silent = true }

    local function close()
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
    end

    vim.keymap.set("n", "q",     close, opts)
    vim.keymap.set("n", "<Esc>", close, opts)

    -- y: yank entire output to system clipboard
    vim.keymap.set("n", "y", function()
      vim.fn.setreg("+", text)
      vim.notify("agent-deck: output yanked to clipboard")
    end, opts)

    -- Mark this window so other modules can detect it
    vim.w[win].agent_deck_output = true
  end)
end

return M
