-- ui/info.lua — floating debug/info window for agent-deck
-- Shows: current project, live Neovide buffers, project sessions,
--        last selection, status totals, persist path, binary path.
local M = {}

local STATUS_ICONS = {
  running = "●", waiting = "◐", idle = "○", error = "✗", stopped = "■",
}

local function pad(s, n)
  s = tostring(s or "")
  return s .. string.rep(" ", math.max(0, n - #s))
end

local function section(lines, title)
  table.insert(lines, "")
  table.insert(lines, " " .. title)
  table.insert(lines, " " .. string.rep("─", #title + 1))
end

local function row(lines, ...)
  local parts = { " " }
  for _, v in ipairs({...}) do
    table.insert(parts, tostring(v))
  end
  table.insert(lines, table.concat(parts, ""))
end

function M.show()
  local state   = require("agent-deck.state")
  local persist = require("agent-deck.persist")
  local lines   = {}

  -- ── Header ──────────────────────────────────────────────────────────────
  table.insert(lines, "")
  table.insert(lines, "  agent-deck.nvim — Info / Debug" )
  table.insert(lines, "  " .. string.rep("━", 50))

  -- ── Backend ─────────────────────────────────────────────────────────────
  local backend_name = require("agent-deck.backend").name()
  section(lines, "Backend")
  row(lines, "  active    ", backend_name)

  -- ── Project ─────────────────────────────────────────────────────────────
  section(lines, "Project")
  row(lines, "  current   ", state.current_project or "(none)")
  row(lines, "  cwd       ", vim.fn.getcwd())

  -- ── Live Neovide Buffers ────────────────────────────────────────────────
  local buf_map = state._session_bufs or {}
  local live_count = 0
  local live_rows = {}

  for session_id, buf in pairs(buf_map) do
    local valid   = vim.api.nvim_buf_is_valid(buf)
    local job_id  = valid and vim.b[buf].terminal_job_id or nil
    local alive   = job_id and (vim.fn.jobwait({job_id}, 0)[1] == -1)
    if alive then live_count = live_count + 1 end

    -- Match session_id to a title from state.sessions
    local title = session_id:sub(1, 8)
    for _, s in ipairs(state.sessions) do
      if s.id == session_id then title = s.title or title; break end
    end

    table.insert(live_rows, string.format(
      "  ◆ %-24s  buf#%-4s  job#%-6s  %s",
      title,
      valid   and tostring(buf)    or "dead",
      job_id  and tostring(job_id) or "none",
      alive   and "● alive" or "○ dead"
    ))
  end

  section(lines, string.format("Neovide Buffers  (%d live)", live_count))
  if #live_rows == 0 then
    row(lines, "  (none)")
  else
    table.sort(live_rows)
    for _, r in ipairs(live_rows) do
      table.insert(lines, r)
    end
  end

  -- ── Project Sessions ────────────────────────────────────────────────────
  local ps = state.project_sessions()
  section(lines, string.format(
    "Project Sessions  (%s · %d tracked)",
    state.current_project or "none", #ps
  ))
  if #ps == 0 then
    row(lines, "  (none)")
  else
    for _, s in ipairs(ps) do
      local icon    = STATUS_ICONS[s.status] or "?"
      local has_buf = state.get_buf(s.id) and "[buf live]" or "          "
      row(lines,
        "  ", icon, " ",
        pad(s.title or s.id, 22), "  ",
        pad(s.status or "?", 9),
        pad(s.tool   or "?", 10),
        has_buf
      )
    end
  end

  -- ── Last Selection ──────────────────────────────────────────────────────
  local saved = persist.get_last(state.current_project)
  section(lines, "Last Selection  (Dal)")
  if not saved then
    row(lines, "  (none saved)")
  else
    row(lines, "  project   ", saved.project or "(none)")
    row(lines, "  layout    ", saved.layout  or "?")
    local id_list = {}
    for _, id in ipairs(saved.session_ids or {}) do
      -- Resolve short title
      local label = id:sub(1, 8)
      for _, s in ipairs(state.sessions) do
        if s.id == id then label = (s.title or label) .. " (" .. id:sub(1,8) .. ")"; break end
      end
      table.insert(id_list, label)
    end
    row(lines, "  sessions  ", table.concat(id_list, ", "))
  end

  -- ── Status Totals ───────────────────────────────────────────────────────
  local st = state.status or {}
  section(lines, "Status Totals")
  row(lines, string.format(
    "  ● running %-4s  ◐ waiting %-4s  ○ idle %-4s  ✗ error %-4s  total %s",
    st.running or 0, st.waiting or 0, st.idle or 0, st.error or 0, st.total or #state.sessions
  ))

  -- ── Persist File ────────────────────────────────────────────────────────
  section(lines, "Persistence")
  local data_dir  = vim.fn.stdpath("data") .. "/agent-deck"
  local map_file  = data_dir .. "/map.json"
  local projects  = persist.all_projects()
  -- filter out internal keys
  local proj_count = 0
  for _, k in ipairs(projects) do
    if not k:match("^_") then proj_count = proj_count + 1 end
  end
  row(lines, "  file      ", map_file)
  row(lines, "  projects  ", proj_count)

  -- ── Binary ──────────────────────────────────────────────────────────────
  section(lines, "Binary")
  local bin_name = backend_name == "cmux" and "cmux" or "agent-deck"
  local bin = vim.fn.exepath(bin_name)
  row(lines, "  " .. bin_name .. "  ", bin ~= "" and bin or "(not found in PATH)")

  -- ── Footer ──────────────────────────────────────────────────────────────
  table.insert(lines, "")
  table.insert(lines, "  q / <Esc> close   y yank to clipboard")
  table.insert(lines, "")

  -- ── Normal buffer in a split ────────────────────────────────────────────
  -- Reuse existing AgentDeckInfo buffer if present
  local buf
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.fn.bufname(b) == "AgentDeckInfo" then
      buf = b
      break
    end
  end
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "AgentDeckInfo")
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype    = "nofile"
  vim.bo[buf].bufhidden  = "hide"
  vim.bo[buf].swapfile   = false

  -- Open in a split (or switch to existing window showing this buf)
  local existing_win
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == buf then
      existing_win = w
      break
    end
  end

  if existing_win then
    vim.api.nvim_set_current_win(existing_win)
  else
    vim.cmd("botright split")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_win_set_height(win, math.min(#lines, 30))
  end

  local opts = { buffer = buf, silent = true }
  local full_text = table.concat(lines, "\n")

  vim.keymap.set("n", "q",     "<cmd>close<cr>", opts)
  vim.keymap.set("n", "<Esc>", "<cmd>close<cr>", opts)
  vim.keymap.set("n", "y", function()
    vim.fn.setreg("+", full_text)
    vim.notify("agent-deck: info yanked to clipboard")
  end, opts)
end

return M
