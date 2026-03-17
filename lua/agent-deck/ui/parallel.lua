-- ui/parallel.lua — open N agent terminals as splits or tiled floats
--
-- Architecture overview:
--   Native termopen() is used instead of `agent-deck session attach` (tmux).
--   Reason: tmux sets TERM=tmux-256color, stripping the outer terminal's
--   capabilities. In Neovide this means broken Nerd Font glyphs, broken robot
--   logo, and broken statusline pills. Direct termopen() inherits Neovide's
--   full terminal capabilities.
--
-- Buffer caching (bufhidden=hide):
--   After a terminal is spawned, its buffer is kept alive even when the window
--   is closed (bufhidden=hide). The session_id → bufnr mapping lives in
--   state._session_bufs. Reopening a session from the picker is then instant
--   (nvim_win_set_buf) — no new process, no welcome screen, conversation
--   state exactly where the user left it.
--
-- claude --resume <id>:
--   When spawning, we use `claude --resume <claude_session_id>` instead of
--   plain `claude`. Without this, two sessions in the same directory would
--   both resume the same "last conversation", clobbering each other. The
--   claude_session_id comes from `agent-deck session show` (not in `list`).
--   prefetch_sessions() runs all show calls async before any windows open.
--
-- Keybinding rules (must match claude-code.lua):
--   terminal mode: <C-x> → normal, <C-hjkl> → window nav, all else passes through
--   normal  mode:  q → close_all  (NEVER q in terminal mode — blocks typing)
local M = {}

local log = require("agent-deck.logger")

-- Tracks all active parallel windows: { win, buf, session }
local _par_wins = {}

-- Track last-opened layout and sessions for <leader>Dal (load last)
local _last_layout   = "split"
local _last_sessions = {}   -- last sessions passed to open_split/open_float/set_last

-- ── Keymap helpers ────────────────────────────────────────────────────────────

local function setup_term_keymaps(buf)
  local opts = { buffer = buf, silent = true }
  -- Pass Esc through to the process; double-Esc must NOT exit terminal mode
  vim.keymap.set("t", "<Esc>", "<Esc>",                 opts)
  -- Exit terminal mode (matches claude-code.lua)
  vim.keymap.set("t", "<C-x>", "<C-\\><C-n>",          opts)
  -- Window navigation from terminal mode
  vim.keymap.set("t", "<C-h>", "<C-\\><C-n><C-w>h",    opts)
  vim.keymap.set("t", "<C-j>", "<C-\\><C-n><C-w>j",    opts)
  vim.keymap.set("t", "<C-k>", "<C-\\><C-n><C-w>k",    opts)
  vim.keymap.set("t", "<C-l>", "<C-\\><C-n><C-w>l",    opts)
  -- Insert a newline without submitting the prompt (multi-line editing).
  -- Sends the kitty-protocol Shift+Enter escape sequence (\x1b[13;2u) — the
  -- same sequence claudecode.nvim's <S-CR> binding sends.  Claude CLI treats
  -- this as "insert newline" rather than "submit".  <C-S-j> is used instead
  -- of <S-CR> so the binding works even in terminals that don't deliver
  -- modified Enter keys through the kitty protocol.
  vim.keymap.set("t", "<C-S-j>", function()
    vim.api.nvim_feedkeys("\x1b[13;2u", "t", true)
  end, vim.tbl_extend("force", opts, { desc = "multi-line edit (newline without submit)" }))
  -- Cmd-V paste: send clipboard as bracketed paste directly to the terminal job.
  -- Bypasses Neovim's paste path so flash.nvim / search mode never see the content.
  local function paste_to_terminal()
    local job_id = vim.b.terminal_job_id
    if job_id then
      vim.fn.chansend(job_id, "\x1b[200~" .. vim.fn.getreg("+") .. "\x1b[201~")
    end
  end
  vim.keymap.set("t", "<D-v>", paste_to_terminal, opts)
  vim.keymap.set("n", "<D-v>", function()
    vim.cmd("startinsert")
    vim.schedule(paste_to_terminal)
  end, opts)
  -- Close all parallel windows — NORMAL mode only (user presses <C-x> first)
  vim.keymap.set("n", "q", function() M.close_all() end, opts)
end

--- Register a TermClose autocmd to evict the buffer cache when the process exits.
--- We do NOT close the window here — the window may already be gone (user pressed q),
--- or the user may still be looking at the buffer. We only clean up the mapping so
--- the next open() knows to spawn a fresh process rather than reusing a dead buffer.
local function register_process_exit(buf, session_id)
  vim.api.nvim_create_autocmd("TermClose", {
    buffer = buf,
    once   = true,
    callback = function()
      vim.schedule(function()
        log.debug("terminal process exited for session " .. session_id .. " — evicting buf cache")
        require("agent-deck.state").clear_buf(session_id)
      end)
    end,
  })
end

--- Build the command string used to spawn a terminal for a session.
---
--- parallel.lua only ever opens sessions that were selected from the picker or
--- loaded from the last-layout persist.  By the time a session reaches this
--- function it is always an existing, previously-started session: its .jsonl
--- conversation file exists on disk and agent-deck's claude_session_id is the
--- real UUID (not the placeholder written at launch-time before claude runs).
--- Therefore `--resume` is always correct here — there is no need to check for
--- file existence or fall back to `--session-id` as picker.lua's spawn_terminal
--- does for brand-new sessions opened immediately after `<leader>Dan`.
---
--- Decision tree:
---   1. Tool is "claude" AND we have a claude_session_id from session_show
---      → `claude --resume <id>` attaches to the exact conversation.
---      Critical for multiple sessions sharing the same cwd: without --resume,
---      both would land on the "last conversation in that directory", clobbering
---      each other's context on every parallel refresh.
---   2. Any other tool, or claude without a known session ID
---      → use session.command (e.g. "codex", "opencode") or fall back to tool name.
local function build_cmd(session)
  local tool = session.tool or "claude"
  if tool == "claude" and session.claude_session_id and session.claude_session_id ~= "" then
    log.debug("build_cmd: using claude --resume " .. session.claude_session_id
      .. " for session " .. session.id)
    return "claude --resume " .. session.claude_session_id
  end
  local cmd = session.command or tool
  log.debug("build_cmd: using command '" .. cmd .. "' for session " .. session.id)
  return cmd
end

--- Pre-fetch full session details for all sessions before opening any windows.
---
--- Why prefetch instead of fetching per-window?
---   `agent-deck list --json` does NOT include claude_session_id. We need
---   `agent-deck session show <id> --json` for that field. Opening windows
---   before all shows complete would cause the first window to spawn immediately
---   (fast, possibly wrong cmd) while later windows wait. Prefetching ensures
---   all windows open with the correct --resume flag simultaneously.
local function prefetch_sessions(sessions, callback)
  local cli    = require("agent-deck.cli")
  local count  = #sessions
  local done   = 0
  local result = {}
  log.debug("prefetch_sessions: fetching details for " .. count .. " session(s)")
  for i, s in ipairs(sessions) do
    result[i] = s  -- default: use list data as-is if show fails
    cli.session_show(s.id, function(ok, data)
      done = done + 1
      if ok and type(data) == "table" then
        -- Merge show fields (claude_session_id, profile, etc.) onto the session object
        result[i] = vim.tbl_extend("force", s, data)
        log.debug("prefetch_sessions: got claude_session_id=" .. (data.claude_session_id or "nil")
          .. " for " .. s.id)
      else
        log.warn("prefetch_sessions: session_show failed for " .. s.id .. " — using list data")
      end
      if done == count then
        log.debug("prefetch_sessions: all " .. count .. " show(s) done")
        vim.schedule(function() callback(result) end)
      end
    end)
  end
end

--- Create a terminal in the given window WITHOUT entering insert mode.
---
--- Reuse vs spawn decision:
---   If state.get_buf() returns a live bufnr, the terminal process is still
---   running — we just point the window at the existing buffer. This is instant
---   and preserves scroll position and conversation context.
---   If there is no live buffer, we call termopen() with the built command and
---   mark the new buffer as bufhidden=hide so it survives window close.
---
--- Note: termopen() sometimes replaces the current buffer with a new one
--- (implementation detail). We re-query nvim_get_current_buf() after the call
--- to get the actual terminal buffer, then set bufhidden on that.
---
--- Caller MUST call startinsert after all windows are created (not here)
--- so focus lands in the last window, not each one sequentially.
local function start_terminal(win, session)
  vim.cmd("stopinsert")
  vim.api.nvim_set_current_win(win)

  local state    = require("agent-deck.state")
  local existing = state.get_buf(session.id)

  if existing then
    -- Fast path: reuse the live hidden buffer — no process spawn, instant display
    log.debug("start_terminal: reusing buf " .. existing .. " for session " .. session.id)
    vim.api.nvim_win_set_buf(win, existing)
  else
    -- Slow path: spawn a new native terminal process
    local cmd = build_cmd(session)
    local cwd = session.path or vim.fn.getcwd()
    log.info("start_terminal: spawning terminal '" .. cmd .. "' in " .. cwd
      .. " for session " .. session.id)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(win, buf)
    vim.fn.termopen(cmd, { cwd = cwd })
    buf = vim.api.nvim_get_current_buf()  -- termopen may replace buffer; re-query
    vim.bo[buf].bufhidden = "hide"        -- keep process alive when window closes
    state.set_buf(session.id, buf)
    register_process_exit(buf, session.id)
  end

  local cur_buf = vim.api.nvim_win_get_buf(win)
  setup_term_keymaps(cur_buf)
  table.insert(_par_wins, { win = win, buf = cur_buf, session = session })
  return cur_buf
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Deduplicate sessions by ID (safety guard for picker multi-select edge cases).
local function dedup(sessions)
  local seen, unique = {}, {}
  for _, s in ipairs(sessions) do
    if not seen[s.id] then seen[s.id] = true; unique[#unique+1] = s end
  end
  return unique
end

--- Open sessions in horizontal splits at the bottom of the screen.
---
--- Layout: one horizontal split at ~35% height for the first session;
--- additional sessions are added as vertical splits within that row so
--- all terminals share the same horizontal band, keeping editor space above.
---
--- _last_sessions is updated in memory here. Persist is the CALLER's
--- responsibility (spawn_sessions calls set_last before calling open_split).
--- This separation ensures internal operations (refresh, load_last) do not
--- accidentally overwrite the user's persisted loaded state.
function M.open_split(sessions)
  if #sessions == 0 then return end
  M.close_all()
  _last_layout   = "split"
  sessions       = dedup(sessions)
  _last_sessions = sessions  -- in-memory only; set_last() is the persist writer
  log.info("open_split: opening " .. #sessions .. " session(s) in horizontal splits")

  -- Prefetch claude_session_id for all sessions before creating any windows.
  -- This ensures every termopen() call uses --resume <correct_id>.
  prefetch_sessions(sessions, function(enriched)
    vim.cmd("stopinsert")

    local height = math.floor(vim.o.lines * 0.35)
    vim.cmd("botright " .. height .. "split")
    start_terminal(vim.api.nvim_get_current_win(), enriched[1])

    -- Additional sessions: vsplit within the first row so they tile horizontally
    for i = 2, #enriched do
      vim.api.nvim_set_current_win(_par_wins[1].win)
      vim.cmd("vsplit")
      start_terminal(vim.api.nvim_get_current_win(), enriched[i])
    end

    vim.cmd("wincmd =")  -- equalize widths so all terminals share space evenly

    -- Enter insert mode in each terminal after ALL windows exist.
    -- Doing this inside start_terminal would focus each window as it's created,
    -- causing flickering and leaving focus on the wrong (last) window.
    for _, entry in ipairs(_par_wins) do
      vim.api.nvim_set_current_win(entry.win)
      vim.cmd("startinsert")
    end
  end)
end

--- Open sessions as independent tiled floating windows side-by-side.
---
--- Layout: N floats equally spaced across 90% of editor width, vertically
--- centered at 60% height, with a 1-column gap between windows.
--- Each float has a rounded border and title showing the session name.
---
--- _last_sessions updated in memory only (see open_split note above).
function M.open_float(sessions)
  if #sessions == 0 then return end
  M.close_all()
  _last_layout   = "float"
  sessions       = dedup(sessions)
  _last_sessions = sessions  -- in-memory only; set_last() is the persist writer
  log.info("open_float: opening " .. #sessions .. " session(s) as floating tiles")

  prefetch_sessions(sessions, function(enriched)
    vim.cmd("stopinsert")

    local n = #enriched
    -- Subtract UI chrome (cmdline, statusline, tabline) from usable height
    local usable_h = vim.o.lines
      - vim.o.cmdheight
      - (vim.o.laststatus > 0 and 1 or 0)
      - (vim.o.showtabline > 0 and 1 or 0)

    local total_w = math.floor(vim.o.columns * 0.90)
    local height  = math.floor(usable_h       * 0.60)
    local gap     = 1
    local win_w   = math.floor((total_w - (n - 1) * gap) / n)
    local start_c = math.floor((vim.o.columns - total_w) / 2)
    local row     = math.floor((usable_h - height) / 2)

    for i, session in ipairs(enriched) do
      local col = start_c + (i - 1) * (win_w + gap)
      log.debug("open_float: window " .. i .. " at col=" .. col .. " w=" .. win_w)

      local buf = vim.api.nvim_create_buf(false, true)
      local win = vim.api.nvim_open_win(buf, true, {
        relative  = "editor",
        row       = row,
        col       = col,
        width     = win_w,
        height    = height,
        border    = "rounded",
        title     = " " .. (session.title or session.id) .. " ",
        title_pos = "center",
        style     = "minimal",
      })

      start_terminal(win, session)
    end

    for _, entry in ipairs(_par_wins) do
      if vim.api.nvim_win_is_valid(entry.win) then
        vim.api.nvim_set_current_win(entry.win)
        vim.cmd("startinsert")
      end
    end
  end)
end

--- Close all tracked parallel windows.
---
--- IMPORTANT: only WINDOWS are closed — buffers stay hidden and processes keep
--- running. This is the key behaviour that enables instant reattach from the
--- picker. To kill the processes, use M.refresh() instead.
function M.close_all()
  log.debug("close_all: closing " .. #_par_wins .. " parallel window(s) (buffers survive)")
  local wins = _par_wins
  _par_wins = {}
  for _, entry in ipairs(wins) do
    if vim.api.nvim_win_is_valid(entry.win) then
      vim.api.nvim_win_close(entry.win, true)
    end
  end
end

--- True when at least one parallel window is open.
function M.is_open()
  return #_par_wins > 0
end

--- Returns the current list of open parallel window entries {win, buf, session}.
--- Must be a getter (not a field alias) because close_all() reassigns _par_wins.
function M.get_open_wins()
  return _par_wins
end

--- Record a user-initiated session selection and persist it for Dal.
---
--- This is the ONLY function that writes to persist. open_split and open_float
--- do NOT call this — they only update in-memory state. Keeping persist writes
--- in one place prevents internal operations (refresh, load_last) from
--- accidentally overwriting what the user actually selected.
---
--- layout: "split" | "float" | "single"
function M.set_last(sessions, layout)
  _last_sessions = sessions or {}
  _last_layout   = layout or "single"
  local project  = require("agent-deck.state").current_project
  log.info("set_last: persisting " .. #_last_sessions .. " session(s), layout=" .. layout
    .. ", project=" .. (project or "nil"))
  require("agent-deck.persist").save_last(layout, _last_sessions, project)
end

local function do_open_last(sessions, layout)
  log.debug("do_open_last: layout=" .. layout .. ", sessions=" .. #sessions)
  if layout == "float" then
    M.open_float(sessions)
  elseif layout == "split" then
    M.open_split(sessions)
  else
    -- "single" — delegate to picker which handles single-session terminal open
    require("agent-deck.ui.picker").spawn_sessions(sessions)
  end
end

--- Reopen the last picker selection in the same layout (Dal).
---
--- Two code paths:
---   Fast path (same Neovide session): _last_sessions is still in memory.
---     Open immediately without any CLI calls.
---   Slow path (after Neovide restart): _last_sessions was wiped.
---     Read session IDs from persist file, resolve against live CLI list,
---     then open. If the live list is already cached in state.sessions we
---     skip the CLI call.
---
--- Why not just store full session objects in persist?
---   Session fields (status, title) change frequently. Storing only IDs and
---   resolving against the live list ensures we always display current state.
function M.load_last()
  local state   = require("agent-deck.state")
  local persist = require("agent-deck.persist")
  local project = state.current_project
  log.debug("load_last: project=" .. (project or "nil")
    .. ", in-memory sessions=" .. #_last_sessions)

  -- Fast path: in-memory state still populated (same Neovide session)
  if #_last_sessions > 0 then
    log.info("load_last: fast path — " .. #_last_sessions .. " sessions in memory")
    do_open_last(_last_sessions, _last_layout)
    return
  end

  -- Slow path: Neovide was restarted — read from persist file
  local saved = persist.get_last(project)
  if not saved or #(saved.session_ids or {}) == 0 then
    log.warn("load_last: no saved session_ids for project=" .. (project or "nil"))
    vim.notify("agent-deck: no saved session selection", vim.log.levels.WARN)
    return
  end

  local layout = saved.layout or "split"
  local ids    = saved.session_ids
  log.info("load_last: slow path — restoring " .. #ids .. " session(s) from persist, layout=" .. layout)

  local function resolve_and_open(sessions_list)
    -- Build ID set from the persisted list for fast lookup
    local id_set = {}
    for _, id in ipairs(ids) do id_set[id] = true end
    local found = {}
    for _, s in ipairs(sessions_list) do
      if id_set[s.id] then table.insert(found, s) end
    end
    if #found == 0 then
      log.warn("load_last: none of the " .. #ids .. " persisted session IDs exist in live list")
      vim.notify("agent-deck: saved sessions no longer exist — use <leader>Dag to reattach", vim.log.levels.WARN)
      return
    end
    log.info("load_last: resolved " .. #found .. "/" .. #ids .. " sessions; opening")
    -- Pin cwd → project so future restarts resolve correctly without needing Dag
    persist.save_cwd_project(vim.fn.getcwd(), project)
    _last_sessions = found
    _last_layout   = layout
    do_open_last(found, layout)
  end

  -- Avoid an extra CLI call if state.sessions was already populated by polling
  local state = require("agent-deck.state")
  if #state.sessions > 0 then
    log.debug("load_last: resolving against already-cached " .. #state.sessions .. " sessions")
    resolve_and_open(state.sessions)
  else
    log.debug("load_last: state empty — fetching fresh session list from CLI")
    require("agent-deck.cli").list_sessions(function(ok, sessions)
      if not ok or type(sessions) ~= "table" then
        log.error("load_last: list_sessions failed")
        vim.notify("agent-deck: failed to fetch sessions for Dal", vim.log.levels.ERROR)
        return
      end
      state.set_sessions(sessions)
      vim.schedule(function() resolve_and_open(sessions) end)
    end)
  end
end

--- Kill all native terminal buffers and respawn in the same layout (DaR).
---
--- Use this after an agent-deck daemon restart or when sessions have drifted
--- from the state shown in Neovide (e.g. resumed from a different terminal).
--- Unlike close_all(), this actually KILLS the processes — jobstop + buf_delete.
--- The respawn calls open_split/open_float which run prefetch_sessions again,
--- picking up the latest claude_session_id from the restarted daemon.
---
--- Contrast with Dar (init.lua M.refresh()): that restarts sessions in the
--- external agent-deck daemon via `session restart`. DaR (this function)
--- restarts the Neovide-side terminal buffers.
function M.refresh()
  local state = require("agent-deck.state")

  -- Snapshot currently displayed sessions before close_all() wipes _par_wins
  local current_sessions = {}
  local was_open = #_par_wins > 0
  local layout   = _last_layout

  for _, entry in ipairs(_par_wins) do
    table.insert(current_sessions, entry.session)
  end

  log.info("refresh (DaR): killing " .. #current_sessions .. " buffer(s) and respawning"
    .. ", layout=" .. layout)

  -- Close windows first (does not kill processes)
  M.close_all()

  -- Now kill all tracked terminal processes and delete their buffers
  local killed = 0
  for session_id, buf in pairs(state._session_bufs) do
    if vim.api.nvim_buf_is_valid(buf) then
      local job_id = vim.b[buf].terminal_job_id
      if job_id then
        log.debug("refresh: stopping job " .. job_id .. " for session " .. session_id)
        pcall(vim.fn.jobstop, job_id)
        killed = killed + 1
      end
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  state._session_bufs = {}
  log.debug("refresh: killed " .. killed .. " job(s); buf cache cleared")

  -- Respawn in the same layout so the user lands in the same view
  if was_open and #current_sessions > 0 then
    if layout == "float" then
      M.open_float(current_sessions)
    else
      M.open_split(current_sessions)
    end
  end
end

return M
