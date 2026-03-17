-- codex.lua — resolve agent-deck Codex sessions to real Codex thread IDs
--
-- agent-deck stores only its own session ID for Codex sessions. To reopen a
-- real Codex conversation after a Neovim restart we need the underlying Codex
-- thread UUID used by `codex resume <thread-id>`.
--
-- Resolution strategy:
--   1. Reuse a persisted mapping if one already exists.
--   2. Otherwise, infer the thread from Codex's local SQLite state by matching
--      cwd and nearest created_at timestamp to the agent-deck session.
--   3. Persist the inferred mapping so future restores are deterministic.
local M = {}

local log = require("agent-deck.logger")

local function sql_quote(s)
  return "'" .. tostring(s):gsub("'", "''") .. "'"
end

local function codex_state_db()
  local files = vim.fn.glob(vim.fn.expand("~/.codex/state_*.sqlite"), false, true)
  local best_path, best_ver
  for _, path in ipairs(files) do
    local ver = tonumber(path:match("state_(%d+)%.sqlite$"))
    if ver and (not best_ver or ver > best_ver) then
      best_ver = ver
      best_path = path
    end
  end
  return best_path
end

local function run_sql(sql, cb)
  local db = codex_state_db()
  if not db then
    log.debug("codex.run_sql: no ~/.codex/state_*.sqlite found")
    cb(false, nil)
    return
  end
  if vim.fn.executable("sqlite3") ~= 1 then
    log.warn("codex.run_sql: sqlite3 not found in PATH")
    cb(false, nil)
    return
  end
  vim.system({ "sqlite3", "-readonly", db, sql }, { text = true }, function(obj)
    vim.schedule(function()
      cb(obj.code == 0, vim.trim(obj.stdout or ""))
    end)
  end)
end

local function thread_exists(thread_id, cb)
  local sql = "select count(*) from threads where id = " .. sql_quote(thread_id) .. ";"
  run_sql(sql, function(ok, out)
    cb(ok and out == "1")
  end)
end

local function infer_thread_id(session, cb)
  if not session.path or not session.created_at then
    cb(nil)
    return
  end

  local created_at = sql_quote(session.created_at)
  local sql = table.concat({
    "select id || '|' || abs(created_at - strftime('%s', " .. created_at .. "))",
    "from threads",
    "where cwd = " .. sql_quote(session.path),
    "order by abs(created_at - strftime('%s', " .. created_at .. ")) asc, updated_at desc",
    "limit 1;",
  }, " ")

  run_sql(sql, function(ok, out)
    if not ok or out == "" then
      cb(nil)
      return
    end
    local thread_id, diff = out:match("^([^|]+)|(%d+)$")
    diff = tonumber(diff)
    if not thread_id or not diff or diff > 600 then
      log.debug("codex.infer_thread_id: no close thread match for session " .. (session.id or "nil"))
      cb(nil)
      return
    end
    log.debug("codex.infer_thread_id: matched " .. thread_id .. " (diff=" .. diff .. "s) for session "
      .. (session.id or "nil"))
    cb(thread_id)
  end)
end

--- Enrich a session object with `codex_thread_id` when possible.
function M.enrich_session(session, cb)
  if (session.tool or "") ~= "codex" then
    cb(session)
    return
  end

  local persist = require("agent-deck.persist")
  local saved = persist.get_codex_thread(session.id)
  if saved and saved ~= "" then
    thread_exists(saved, function(ok)
      if ok then
        cb(vim.tbl_extend("force", session, { codex_thread_id = saved }))
      else
        infer_thread_id(session, function(thread_id)
          if thread_id then
            persist.set_codex_thread(session.id, thread_id)
            cb(vim.tbl_extend("force", session, { codex_thread_id = thread_id }))
          else
            cb(session)
          end
        end)
      end
    end)
    return
  end

  infer_thread_id(session, function(thread_id)
    if thread_id then
      persist.set_codex_thread(session.id, thread_id)
      cb(vim.tbl_extend("force", session, { codex_thread_id = thread_id }))
    else
      cb(session)
    end
  end)
end

return M
