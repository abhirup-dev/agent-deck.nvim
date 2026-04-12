-- ui/picker.lua — multi-level session picker
--
-- Level 1: Snacks.picker showing all sessions with tier-based sorting
-- Level 2: vim.ui.select for spawn mode (single / splits / floats)
--
-- Tier system (why):
--   The session list can contain dozens of sessions from many projects.
--   We surface the most relevant ones at the top via three tiers:
--     Tier 1 (◆  green):  session has a live Neovide buffer open — instant reattach
--     Tier 2 (◈  orange): session in the current project group — likely relevant
--     Tier 3 (    dim):   all other sessions
--   Tier labels ("attached", "group", "") are included in the fuzzy search text
--   so the user can filter with "attached" or "group" in the query.
--
-- Buffer caching:
--   open_session_terminal checks state.get_buf() before spawning. If a live
--   buffer exists, the session is opened instantly by pointing a window at it.
--   New sessions use claude --resume <claude_session_id> to attach to the right
--   conversation even when multiple sessions share the same working directory.
local M = {}

local log = require("agent-deck.logger")

local ICONS = {
  running = "●",
  waiting = "◐",
  idle    = "○",
  error   = "✗",
  stopped = "■",
}

local STATUS_HL = {
  running = "DiagnosticOk",
  waiting = "DiagnosticWarn",
  idle    = "Comment",
  error   = "DiagnosticError",
  stopped = "Comment",
}

-- Tier icons and highlights for the leading indicator column
-- tier 1: session has a live buffer open in Neovide
-- tier 2: session belongs to the current project group
-- tier 3: everything else
local TIER_ICON = { "◆ ", "◈ ", "  " }  -- solid diamond, open diamond, blank
local TIER_HL   = { "DiagnosticOk", "DiagnosticWarn", "Comment" }
local TIER_LABEL = { "attached", "group", "" }  -- included in search text

local function time_ago(created_at)
  if not created_at then return "" end
  local ts = tonumber(created_at)
  if not ts then return "" end
  local diff = os.time() - ts
  if diff < 3600 then
    return string.format("%dm", math.floor(diff / 60))
  end
  return string.format("%dh", math.floor(diff / 3600))
end

local claude_paths = require("agent-deck.claude_paths")
local session_cmd  = require("agent-deck.session_cmd")

--- Spawn a new terminal for a session using the enriched session object.
---
--- ── Command selection ──────────────────────────────────────────────────────────
---
---   Case 1 – claude, conv file EXISTS  → `claude --resume <claude_session_id>`
---     The conversation is already initialised; resume attaches to the exact
---     session regardless of which directory other sessions live in.
---     Critical for multiple sessions sharing the same cwd: without --resume,
---     both would re-attach to "the last conversation in that directory",
---     clobbering each other's context.
---
---   Case 2 – claude, conv file MISSING → `claude --session-id <claude_session_id>`
---     The session was just created by `agent-deck launch`.  agent-deck
---     pre-generates a UUID and starts claude in a tmux pane with
---     `claude --session-id <uuid>`.  We use the SAME flag and the SAME UUID so
---     the nvim terminal and the agent-deck tmux pane share one session identity.
---     Using `--resume` here would fail with "No conversation found" because the
---     .jsonl file does not exist yet.  Using plain `claude` (no flag) would
---     create a NEW session with a DIFFERENT UUID — diverging from agent-deck's
---     record and breaking `claude --resume` from any external terminal.
---
---   Case 3 – codex with a known Codex thread ID
---     Resume the exact Codex conversation with `codex resume <thread-id>`.
---     The thread ID is inferred from Codex's local state DB on first reopen
---     and then persisted by agent-deck.nvim.
---
---   Case 4 – non-claude tool, or no resume identifier
---     Use session.command (e.g. "codex", "opencode") or fall back to tool name.
---
--- ── Snacks vs plain split ──────────────────────────────────────────────────────
---   Snacks.terminal is preferred (styled float/split with title and border).
---   Falls back to a bare split + termopen() when Snacks is not loaded.
---   Either path caches the buffer with bufhidden=hide for instant reattach.
local function spawn_terminal(session)
  local state = require("agent-deck.state")
  local cwd   = session.path or vim.fn.getcwd()
  -- cmux-enriched sessions have _cmd_ready=true — command already built by
  -- enrich_cmux_sessions. Agent-deck sessions go through build_cmd_new.
  local cmd   = session._cmd_ready and session.command
    or session_cmd.build_cmd_new(session, claude_paths.conv_exists)
  if not cmd then
    vim.notify("agent-deck: session is running in agent-deck but has no conversation yet.\n"
      .. "Send a first message in the agent-deck terminal, then retry.", vim.log.levels.WARN)
    return
  end

  -- Helper: mark buf as hidden (survives window close), set keymaps, register TermClose
  local function cache(buf)
    vim.bo[buf].bufhidden = "hide"
    state.set_buf(session.id, buf)
    -- Insert newline without submitting — mirrors claudecode.nvim's <S-CR> binding.
    -- Sends the kitty-protocol Shift+Enter sequence that Claude CLI interprets as
    -- "insert newline" rather than "submit".
    vim.keymap.set("t", "<C-S-j>", function()
      vim.api.nvim_feedkeys("\x1b[13;2u", "t", true)
    end, { buffer = buf, silent = true, desc = "multi-line edit (newline without submit)" })
    -- Cmd-V paste: send clipboard as bracketed paste directly to the terminal job.
    -- Bypasses Neovim's paste path so flash.nvim / search mode never see the content.
    local function paste_to_terminal()
      local job_id = vim.b[buf].terminal_job_id
      if job_id then
        vim.fn.chansend(job_id, "\x1b[200~" .. vim.fn.getreg("+") .. "\x1b[201~")
      end
    end
    vim.keymap.set("t", "<D-v>", paste_to_terminal, { buffer = buf, silent = true })
    vim.keymap.set("n", "<D-v>", function()
      vim.cmd("startinsert")
      vim.schedule(paste_to_terminal)
    end, { buffer = buf, silent = true })
    vim.api.nvim_create_autocmd("TermClose", {
      buffer = buf, once = true,
      callback = function()
        vim.schedule(function()
          log.debug("spawn_terminal: TermClose for session " .. session.id .. " — evicting cache")
          state.clear_buf(session.id)
        end)
      end,
    })
  end

  local ok, snacks = pcall(require, "snacks")
  if ok and snacks.terminal then
    snacks.terminal(cmd, {
      cwd = cwd,
      win = {
        title  = " " .. (session.title or session.id) .. " ",
        border = "rounded",
        keys   = {
          term_normal = false,  -- Esc passes through; use <C-x> to exit terminal mode
          q = { "<cmd>close<cr>", mode = "n" },  -- q closes window in terminal normal mode
        },
      },
    })
    cache(vim.api.nvim_get_current_buf())
  else
    -- Snacks not available — plain split fallback
    vim.cmd("split")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, buf)
    vim.fn.termopen(cmd, { cwd = cwd })
    local cur = vim.api.nvim_get_current_buf()
    -- q closes the window in terminal normal mode (mirrors Snacks path)
    vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = cur, desc = "close terminal" })
    cache(cur)
    vim.cmd("startinsert")
  end
end

--- Open a terminal for a session, reusing a cached buffer if available.
---
--- Fast path: state.get_buf() returns a live bufnr → open in a split instantly.
--- Slow path: no live buffer → fetch session_show to get claude_session_id,
---   then call spawn_terminal with the enriched object.
---
--- The session_show fetch is skipped for the fast path because we are reusing
--- an existing process — there is nothing new to spawn, so the session ID
--- doesn't matter for terminal creation.
local function open_session_terminal(session)
  local state    = require("agent-deck.state")
  local existing = state.get_buf(session.id)

  if existing then
    -- Fast path: live buffer — point a new window at it, no spawn needed
    log.info("open_session_terminal: reusing live buf " .. existing
      .. " for session " .. session.id)
    vim.cmd("split")
    vim.api.nvim_win_set_buf(0, existing)
    vim.cmd("startinsert")
    return
  end

  -- cmux backend: build command from persist metadata directly.
  -- Uses session_cmd.build_cmd (shared util, always --resume for existing
  -- sessions). Does NOT use the agent-deck path (session_show callback,
  -- codex.enrich_session, build_cmd_new decision tree).
  if require("agent-deck.backend").name() == "cmux" then
    local persist = require("agent-deck.persist")
    local scmd    = require("agent-deck.session_cmd")
    local meta    = persist.get_cmux_session(session.id)
    if not meta then
      log.warn("open_session_terminal (cmux): no persist data for " .. session.id)
      vim.notify("agent-deck: session metadata not found for " .. session.id, vim.log.levels.WARN)
      return
    end
    -- Ensure id is set (persist stores surface_id, not id)
    meta.id = meta.id or meta.surface_id or session.id
    -- build_cmd uses --resume for claude sessions with claude_session_id,
    -- bare command for other tools
    local cmd = scmd.build_cmd(meta)
    local cwd = meta.path or vim.fn.getcwd()
    log.info("open_session_terminal (cmux): spawning terminal for " .. session.id
      .. " cmd=" .. cmd .. " cwd=" .. cwd)
    spawn_terminal(vim.tbl_extend("force", session, meta, { command = cmd, path = cwd, _cmd_ready = true }))
    return
  end

  -- Slow path (agent-deck backend): fetch full details to get claude_session_id, then spawn
  log.debug("open_session_terminal: no live buf for " .. session.id .. " — fetching session_show")
  require("agent-deck.backend").session_show(session.id, function(ok, data)
    local enriched = (ok and type(data) == "table")
      and vim.tbl_extend("force", session, data)
      or session
    if not ok then
      log.warn("open_session_terminal: session_show failed for " .. session.id .. " — using list data")
    end
    require("agent-deck.codex").enrich_session(enriched, function(final_session)
      vim.schedule(function() spawn_terminal(final_session) end)
    end)
  end)
end

--- Dispatch one or more selected sessions to the appropriate terminal mode.
---
--- Single session: open directly, no layout prompt needed.
--- Multiple sessions (2-3): show layout picker (single / splits / floats).
---   Max 3 enforced because more than 3 parallel terminals becomes unusable
---   and the float layout math assumes a reasonable window width per terminal.
---
--- set_last() is called BEFORE the open call so the layout is persisted even
--- if the open fails (e.g. window creation error). This is intentional: we
--- want Dal to retry the same selection, not fall back to a previous one.
function M.spawn_sessions(sessions)
  if #sessions == 0 then return end
  local parallel = require("agent-deck.ui.parallel")
  log.info("spawn_sessions: " .. #sessions .. " session(s) selected")

  if #sessions == 1 then
    -- Single session: persist as "single" so Dal reopens without a layout prompt
    parallel.set_last(sessions, "single")
    open_session_terminal(sessions[1])
    return
  end

  if #sessions > 3 then
    log.warn("spawn_sessions: " .. #sessions .. " sessions selected; truncating to 3")
    vim.notify("agent-deck: max 3 sessions for parallel mode — truncating", vim.log.levels.WARN)
    sessions = { unpack(sessions, 1, 3) }
  end

  vim.ui.select({
    "Attach (single terminal — first selected)",
    "Parallel — horizontal splits",
    "Parallel — floating tiles",
  }, { prompt = "How to open?" }, function(choice)
    if not choice then return end
    if choice:match("^Attach") then
      -- User chose single even though multiple were selected — only open the first
      log.info("spawn_sessions: attach single → " .. sessions[1].id)
      parallel.set_last({ sessions[1] }, "single")  -- persist only the one opened
      open_session_terminal(sessions[1])
    elseif choice:match("splits") then
      log.info("spawn_sessions: parallel splits → " .. #sessions .. " sessions")
      parallel.set_last(sessions, "split")   -- persist before open (overwrites old loaded)
      parallel.open_split(sessions)
    elseif choice:match("float") then
      log.info("spawn_sessions: parallel floats → " .. #sessions .. " sessions")
      parallel.set_last(sessions, "float")   -- persist before open (overwrites old loaded)
      parallel.open_float(sessions)
    end
  end)
end

function M.pick()
  local backend = require("agent-deck.backend")
  local state   = require("agent-deck.state")
  local persist = require("agent-deck.persist")

  backend.list_sessions(function(ok, sessions)
    if not ok then
      log.error("pick: list_sessions failed")
      vim.notify("agent-deck: failed to list sessions", vim.log.levels.ERROR)
      return
    end

    log.debug("pick: got " .. #sessions .. " sessions from list_sessions")

    -- Classify sessions into three tiers for display priority.
    -- Tier 1 (◆ green):  has a live Neovide buffer — can be reattached instantly
    -- Tier 2 (◈ orange): in the current project's persist map — likely relevant
    -- Tier 3 (   dim):   everything else (other projects, untracked sessions)
    local project     = state.current_project
    local entry       = project and persist.get(project)
    local project_ids = {}
    if entry and entry.sessions then
      for _, id in ipairs(entry.sessions) do project_ids[id] = true end
    end
    log.debug("pick: project=" .. (project or "nil") .. ", project_ids=" .. vim.inspect(project_ids))

    local function get_tier(s)
      if state.get_buf(s.id) then return 1 end  -- live buffer → instant reattach
      if project_ids[s.id]   then return 2 end  -- in project map → likely wanted
      return 3
    end

    local items = {}
    for _, s in ipairs(sessions) do
      local tier = get_tier(s)
      items[#items + 1] = {
        text    = table.concat({
          TIER_LABEL[tier], ICONS[s.status] or "?",
          s.title or s.id, s.status or "", s.tool or "", s.group or "",
        }, " "),
        session = s,
        _tier   = tier,
      }
    end

    -- Stable sort by tier (tier 1 first, then 2, then 3)
    table.sort(items, function(a, b) return a._tier < b._tier end)

    state._picker_open = true

    Snacks.picker({
      title   = "Sessions · " .. (project or "all"),
      items   = items,
      preview = "none",

      format = function(item)
        local s      = item.session
        local tier   = item._tier
        local st_hl  = STATUS_HL[s.status] or "Normal"
        local title_hl = tier < 3 and "Normal" or "Comment"
        return {
          { TIER_ICON[tier],                              TIER_HL[tier] },
          { (ICONS[s.status] or "?") .. " ",             st_hl },
          { string.format("%-26s ", s.title or s.id),    title_hl },
          { string.format("%-9s",   s.status or "?"),    st_hl },
          { string.format(" %-11s", s.tool or "?"),       "String" },
          { " " .. time_ago(s.created_at),                "Comment" },
        }
      end,

      confirm = function(picker, item)
        -- Collect multi-selected items
        local selected = {}
        local ok2, sel = pcall(function() return picker:selected() end)
        if ok2 and sel and #sel > 0 then
          selected = sel
        elseif item then
          selected = { item }
        end

        picker:close()
        state._picker_open = false

        if #selected == 0 then return end

        local sess_list = {}
        for _, it in ipairs(selected) do
          table.insert(sess_list, it.session)
        end
        M.spawn_sessions(sess_list)
      end,

      -- Called when picker is dismissed without confirming (Esc, q, etc.)
      on_close = function()
        state._picker_open = false
      end,

      actions = {
        ad_new = function(picker)
          picker:close()
          state._picker_open = false
          vim.schedule(M.new_session)
        end,

        ad_delete = function(picker, item)
          if not item or not item.session then return end
          local id = item.session.id
          require("agent-deck.backend").session_delete(id, function(ok2, _)
            vim.schedule(function()
              if ok2 then
                vim.notify("agent-deck: deleted " .. id)
                -- Also remove from persist map
                if project then
                  persist.remove_session(project, id)
                end
                picker:close()
                state._picker_open = false
                M.pick()
              else
                vim.notify("agent-deck: failed to delete " .. id, vim.log.levels.ERROR)
              end
            end)
          end)
        end,

        ad_stop = function(_, item)
          if not item or not item.session then return end
          require("agent-deck.backend").session_stop(item.session.id, function(ok2, _)
            if ok2 then
              vim.notify("agent-deck: stopped " .. (item.session.title or item.session.id))
            end
          end)
        end,

        ad_restart = function(_, item)
          if not item or not item.session then return end
          require("agent-deck.backend").session_restart(item.session.id, function(ok2, _)
            if ok2 then
              vim.notify("agent-deck: restarted " .. (item.session.title or item.session.id))
            end
          end)
        end,
      },

      win = {
        input = {
          keys = {
            -- None of these conflict with Snacks.picker defaults
            ["<C-n>"] = { "ad_new",     mode = { "i", "n" } },
            ["<C-d>"] = { "ad_delete",  mode = { "i", "n" } },
            ["<C-k>"] = { "ad_stop",    mode = { "i", "n" } },
            ["<C-r>"] = { "ad_restart", mode = { "i", "n" } },
          },
        },
      },
    })
  end)
end

--- Launch a new session wizard: tool → title → launch → persist.
---
--- After launch the session is immediately visible in the picker (status=waiting).
--- Opening it via the picker calls open_session_terminal → spawn_terminal, which
--- detects the missing .jsonl file and uses `claude --session-id <pre-generated-id>`
--- to match what agent-deck started in its tmux pane.  Once the user sends the
--- first message, the .jsonl file is written and `claude --resume <id>` works from
--- any external terminal — keeping nvim and the agent-deck CLI fully in sync.
function M.new_session()
  local state   = require("agent-deck.state")
  local group   = require("agent-deck.group")
  local persist = require("agent-deck.persist")

  local project = state.current_project or group.current_project()
  local cwd     = vim.fn.getcwd()

  vim.ui.select({ "claude", "codex", "opencode" }, { prompt = "Select tool:" }, function(tool)
    if not tool then return end
    vim.ui.input({ prompt = "Session title: " }, function(title)
      if not title or title == "" then return end
      require("agent-deck.backend").launch(cwd, {
        tool  = tool,
        title = title,
        group = project,
      }, function(ok, data)
        if ok and type(data) == "table" and data.id then
          persist.add_session(project, data.id)
          vim.notify("agent-deck: launched '" .. title .. "' (" .. data.id .. ")")
          require("agent-deck.backend").list_sessions(function(ok2, sessions)
            if ok2 then state.set_sessions(sessions) end
          end)
          -- For claude: check after 2s if session is still waiting (needs
          -- permission or approval in agent-deck terminal before Neovim can open it)
          if tool == "claude" then
            vim.defer_fn(function()
              require("agent-deck.backend").session_show(data.id, function(ok3, detail)
                if ok3 and type(detail) == "table" and detail.status == "waiting" then
                  local claude_paths = require("agent-deck.claude_paths")
                  local sid = detail.claude_session_id or ""
                  local has_conv = sid ~= "" and claude_paths.conv_exists(cwd, sid)
                  if not has_conv then
                    vim.notify("agent-deck: '" .. title .. "' is waiting in agent-deck.\n"
                      .. "Approve permissions or send first message there before opening in Neovim.",
                      vim.log.levels.WARN)
                  end
                end
              end)
            end, 2000)
          end
        else
          vim.notify("agent-deck: launch failed", vim.log.levels.ERROR)
        end
      end)
    end)
  end)
end

--- Focus a session in cmux's UI (cmux backend only).
--- Opens a single-select picker; on confirm, calls backend.focus_session
--- to bring the cmux surface/workspace to the front.
function M.focus_pick()
  local backend = require("agent-deck.backend")
  if backend.name() ~= "cmux" then
    vim.notify("agent-deck: focus_pick is only available with the cmux backend", vim.log.levels.WARN)
    return
  end

  local state = require("agent-deck.state")
  local sessions = state.get_sessions()
  if not sessions or #sessions == 0 then
    vim.notify("agent-deck: no sessions to focus", vim.log.levels.INFO)
    return
  end

  -- Build picker items
  local items = {}
  for _, s in ipairs(sessions) do
    local icon = ICONS[s.status] or "?"
    local label = icon .. "  " .. (s.title or s.id) .. "  [" .. (s.group or "") .. "]"
    table.insert(items, { text = label, session = s })
  end

  vim.ui.select(items, {
    prompt = "Focus session in cmux:",
    format_item = function(item) return item.text end,
  }, function(choice)
    if not choice then return end
    log.info("focus_pick: focusing " .. choice.session.id .. " in cmux")
    backend.focus_session(choice.session.id, function(ok, _)
      if not ok then
        vim.notify("agent-deck: failed to focus " .. choice.session.id, vim.log.levels.ERROR)
      end
    end)
  end)
end

return M
