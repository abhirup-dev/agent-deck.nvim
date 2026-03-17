-- statusline.lua — lualine_x component for agent-deck
-- Shows: "AD ● 2  ◐ 1" (only counts for current project; "" when nothing active)
local M = {}

local ICONS = {
  running = "●",
  waiting = "◐",
  idle    = "○",
  error   = "✗",
  stopped = "■",
}

-- Display order: most important first
local ORDER = { "running", "waiting", "idle", "error", "stopped" }

--- Returns "title (group)" for the parallel session window that is currently
--- focused. Empty when the current window is not an agent-deck parallel terminal.
function M.focused_session()
  local ok, par = pcall(require, "agent-deck.ui.parallel")
  if not ok then return "" end
  local wins = par.get_open_wins()
  if not wins or #wins == 0 then return "" end
  local cur = vim.api.nvim_get_current_win()
  for _, entry in ipairs(wins) do
    if entry.win == cur and vim.api.nvim_win_is_valid(entry.win) then
      local s = entry.session
      local title = s.title or s.id
      local group = s.group
      return (group and group ~= "") and (title .. " (" .. group .. ")") or title
    end
  end
  return ""
end

function M.component()
  local ok, state = pcall(require, "agent-deck.state")
  if not ok then return "" end

  local ps = state.project_sessions()
  if #ps == 0 then return "" end

  local counts = {}
  for _, s in ipairs(ps) do
    local st = s.status or "idle"
    counts[st] = (counts[st] or 0) + 1
  end

  local parts = { "AD" }
  for _, status in ipairs(ORDER) do
    local n = counts[status]
    if n and n > 0 then
      table.insert(parts, ICONS[status] .. " " .. n)
    end
  end

  -- Only emit if there's at least one status segment beyond "AD"
  if #parts == 1 then return "" end
  return table.concat(parts, "  ")
end

return M
