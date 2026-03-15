-- cli.lua — async agent-deck CLI wrapper
--
-- Design notes:
--   • All I/O is async via vim.uv (libuv). Callbacks are NEVER called from a
--     libuv thread directly; they are always delivered via vim.schedule() so
--     callers can freely call any Neovim API.
--   • stdout is streamed in chunks and concatenated; JSON is decoded only after
--     on_exit fires (exit code + complete stdout are both needed for correctness).
--   • run_raw: raw stdout string callback — used when the command produces no
--     JSON (session start/stop/restart/delete).
--   • M.run: JSON-decoded callback — used for commands that return structured
--     data (list, status, session show, launch, group list).
local M = {}

-- ── Binary resolution ─────────────────────────────────────────────────────────
-- Resolve once at module load so every call uses the same binary.
-- exepath("agent-deck") searches $PATH; if that fails (e.g. PATH not set
-- correctly in Neovide's launch environment) we fall back to the known
-- install location. Final fallback keeps the binary name as-is so the
-- spawn error message is actionable ("agent-deck not found").
local _bin = vim.fn.exepath("agent-deck")
if _bin == "" then
  local fallback = vim.fn.expand("~/.local/bin/agent-deck")
  if vim.fn.executable(fallback) == 1 then
    _bin = fallback
  else
    _bin = "agent-deck" -- last resort; will surface spawn-failed error
  end
end

-- ── Low-level async spawn ─────────────────────────────────────────────────────

--- Spawn the agent-deck binary with the given args list.
--- Callback receives (success:bool, raw_stdout:string).
--- stderr is intentionally discarded — agent-deck writes progress to stderr
--- which would contaminate JSON parsing; errors are signalled via exit code.
local function run_raw(args, callback)
  local stdout_chunks = {}
  local stdout = vim.uv.new_pipe()
  local handle
  handle = vim.uv.spawn(_bin, {
    args  = args,
    stdio = { nil, stdout, nil },  -- stdin=nil, stdout=pipe, stderr=nil
  }, function(code)
    -- on_exit fires in libuv context — must schedule before any nvim API call
    stdout:close()
    handle:close()
    vim.schedule(function()
      callback(code == 0, table.concat(stdout_chunks))
    end)
  end)
  if not handle then
    -- Spawn failed immediately (binary missing, permission denied, etc.)
    vim.schedule(function()
      callback(false, "agent-deck: spawn failed (binary not found?)")
    end)
    return
  end
  stdout:read_start(function(_, chunk)
    if chunk then
      table.insert(stdout_chunks, chunk)
    end
  end)
end

-- ── High-level JSON runner ────────────────────────────────────────────────────

--- Run an agent-deck command that returns JSON output.
--- Callback receives (success:bool, decoded_table_or_raw_string).
--- Falls back to raw string if JSON decoding fails so callers always get
--- something actionable even from unexpected output.
function M.run(args, callback)
  run_raw(args, function(ok, raw)
    if not ok then
      callback(false, raw)
      return
    end
    -- Empty stdout is valid for commands that succeed silently
    if raw == "" then
      callback(true, nil)
      return
    end
    local dec_ok, data = pcall(vim.json.decode, raw)
    callback(dec_ok, dec_ok and data or raw)
  end)
end

-- ── Convenience wrappers ─────────────────────────────────────────────────────

--- status --json → {waiting,running,idle,error,stopped,total}
function M.status(cb)
  M.run({ "status", "--json" }, cb)
end

--- list --json → [{id,title,path,group,tool,command,status,profile,created_at}]
function M.list_sessions(cb)
  M.run({ "list", "--json" }, cb)
end

--- session show <id> --json → full session object
function M.session_show(id, cb)
  M.run({ "session", "show", id, "--json" }, cb)
end

--- session send <id> <text>
--- opts: { wait=true } | { no_wait=true }
function M.session_send(id, text, opts, cb)
  opts = opts or {}
  local args = { "session", "send", id, text }
  if opts.wait then
    table.insert(args, "--wait")
  elseif opts.no_wait then
    table.insert(args, "--no-wait")
  end
  run_raw(args, function(ok, raw)
    cb(ok, raw)
  end)
end

--- session output <id> --json → last response object
function M.session_output(id, cb)
  M.run({ "session", "output", id, "--json" }, cb)
end

function M.session_start(id, cb)
  run_raw({ "session", "start", id }, cb)
end

function M.session_stop(id, cb)
  run_raw({ "session", "stop", id }, cb)
end

function M.session_restart(id, cb)
  run_raw({ "session", "restart", id }, cb)
end

function M.session_delete(id, cb)
  run_raw({ "session", "delete", id }, cb)
end

--- launch <path> opts --json → {id,...} of new session
--- opts: { tool, title, group }
function M.launch(path, opts, cb)
  opts = opts or {}
  local args = { "launch", path }
  if opts.tool  then vim.list_extend(args, { "-c", opts.tool  }) end
  if opts.title then vim.list_extend(args, { "-t", opts.title }) end
  if opts.group then vim.list_extend(args, { "-g", opts.group }) end
  table.insert(args, "--json")
  M.run(args, cb)
end

--- group list --json → {groups:[{name,path,session_count,status}]}
function M.group_list(cb)
  M.run({ "group", "list", "--json" }, cb)
end

--- group create <name>
function M.group_create(name, cb)
  run_raw({ "group", "create", name }, cb)
end

--- session set <id> <field> <value>
function M.session_set(id, field, value, cb)
  run_raw({ "session", "set", id, field, value }, cb)
end

--- group move <id> <group>
function M.group_move(id, group, cb)
  run_raw({ "group", "move", id, group }, cb)
end

return M
