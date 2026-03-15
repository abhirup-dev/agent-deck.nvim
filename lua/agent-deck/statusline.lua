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
