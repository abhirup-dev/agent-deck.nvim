# agent-deck.nvim

A Neovim plugin that integrates [agent-deck](https://github.com/asheshgoplani/agent-deck) into Neovide — manage AI coding sessions (Claude, Codex, OpenCode) without leaving your editor.

## Features

- **Session picker** — fuzzy-find all agent-deck sessions with tier-based sorting (live buffer → project group → other)
- **Native terminals** — sessions open as `vim.fn.termopen()` windows instead of tmux, so Nerd Font glyphs and colours render correctly in Neovide
- **Buffer caching** — terminal processes survive window close (`bufhidden=hide`); reopening is instant
- **Parallel layouts** — open 2–3 sessions side-by-side as horizontal splits or floating tiles
- **Persistence** — last picker selection is saved to disk; `<leader>Dal` restores it after a Neovide restart
- **Project groups** — attach an existing agent-deck group or create a new one; cwd→slug mapping survives `DirChanged`
- **Send to session** — send visual selection or a composed prompt to the primary session
- **Statusline component** — lualine-compatible component showing live session counts
- **Structured logging** — all decisions written to `~/.local/share/nvim/agent-deck/debug.log`

## Requirements

- Neovim ≥ 0.10
- [agent-deck](https://github.com/nnishant/agent-deck) binary in `$PATH` (or `~/.local/bin/agent-deck`)
- [snacks.nvim](https://github.com/folke/snacks.nvim) (for the picker and terminal UI)
- Neovide (recommended for full glyph rendering)

## Installation

### lazy.nvim

```lua
{
  "abhirup-dev/agent-deck.nvim",
  event = "VeryLazy",
  keys = {
    { "<leader>Dap", function() require("agent-deck.ui.picker").pick() end,         desc = "Agent: session picker" },
    { "<leader>Dal", function() require("agent-deck.ui.parallel").load_last() end,  desc = "Agent: reload last layout" },
    { "<leader>DaX", function() require("agent-deck.ui.parallel").close_all() end,  desc = "Agent: close parallel windows" },
    { "<leader>Dan", function() require("agent-deck.ui.picker").new_session() end,  desc = "Agent: new session" },
    { "<leader>Dag", function() require("agent-deck").set_group() end,              desc = "Agent: set/attach group" },
    { "<leader>Dar", function() require("agent-deck").refresh() end,                desc = "Agent: restart sessions (external)" },
    { "<leader>DaR", function() require("agent-deck.ui.parallel").refresh() end,    desc = "Agent: respawn Neovide buffers" },
    { "<leader>Dak", function() require("agent-deck").kill_all() end,               desc = "Agent: stop all project sessions" },
    { "<leader>DaI", function() require("agent-deck").import_sessions() end,        desc = "Agent: import sessions" },
    { "<leader>Das", function() require("agent-deck.ui.send").send_selection() end, desc = "Agent: send selection", mode = "v" },
    { "<leader>DaS", function() require("agent-deck.ui.send").compose() end,        desc = "Agent: compose prompt" },
    { "<leader>Dao", function() require("agent-deck.ui.output").show() end,         desc = "Agent: view last response" },
  },
  config = function()
    require("agent-deck").setup()
  end,
}
```

## Commands

| Command | Description |
|---------|-------------|
| `:AgentDeckInfo` | Show debug info (project, live buffers, sessions, persist path) |
| `:AgentDeckLog` | Open the debug log in a split |
| `:AgentDeckLogClear` | Truncate the debug log |

## Statusline

```lua
-- lualine example
require("lualine").setup({
  sections = {
    lualine_x = {
      { require("agent-deck.statusline").component },
    },
  },
})
```

Shows `AD ● 2  ◐ 1` when sessions are active for the current project.

## Architecture

### Buffer caching

Terminal processes are spawned with `vim.fn.termopen()` and their buffers are kept alive with `bufhidden=hide`. Closing a window does **not** kill the process — reopening the same session from the picker is instant (no re-spawn, conversation context preserved).

### Session identity — CLI / Neovide sync contract

The agent-deck CLI daemon and the Neovim plugin share a single source of truth for every session: the `claude_session_id` stored in agent-deck's database and mirrored on disk as a `.jsonl` conversation file under `~/.claude/projects/`.

**Lifecycle of a new Claude session (`<leader>Dan`):**

1. `agent-deck launch` — agent-deck pre-generates a UUID as `claude_session_id` and immediately starts claude in a tmux pane with `claude --session-id <uuid>`. No `.jsonl` file exists yet.
2. The nvim plugin detects the missing file (`claude_conv_exists()`) and opens its native terminal with the **same** `claude --session-id <uuid>`.
3. Once the user sends the first message, claude writes `~/.claude/projects/<path>/<uuid>.jsonl`.
4. From this point, `claude --resume <uuid>` works from **any** terminal — Neovide, the agent-deck tmux pane, or an external shell.

**Why `--session-id` for new sessions, `--resume` for existing:**

- `--resume <id>` requires the `.jsonl` file to already exist. Using it before the first message fails with _"No conversation found"_.
- `--session-id <id>` creates the session with a specific UUID if the file is absent, or attaches to it if present. This matches exactly what agent-deck does internally.
- Plain `claude` (no flag) would create a **new** UUID diverging from agent-deck's record, breaking external resume and the `<leader>Dar` save/restore flow.

**Parallel sessions (`open_split` / `open_float`):**

Sessions opened via the parallel layout are always pre-existing (selected from the picker or restored via `<leader>Dal`). Their `.jsonl` files are guaranteed to exist, so `build_cmd` in `parallel.lua` always uses `--resume`. No file-existence check is needed there.

**`<leader>Dar` (external daemon restart):**

Restarting sessions via agent-deck would reassign each session to the "last conversation in its working directory" — clobbering distinct sessions that share a cwd. `refresh()` in `init.lua` saves each session's `claude_session_id` before restarting and restores it via `session set` afterward, keeping every session pinned to its own conversation.

### Two refresh types

- `<leader>Dar` — restarts sessions in the **external agent-deck daemon** (`session restart`). Saves and restores each session's `claude_session_id` to prevent two sessions in the same directory from clobbering each other's conversation.
- `<leader>DaR` — kills and respawns the **Neovide terminal buffers**. Use after an agent-deck daemon restart to reload conversation state in-editor.

### Project persistence

Session membership and last layout are stored at `~/.local/share/nvim/agent-deck/map.json`. The cwd→project-slug mapping (`_cwd_projects`) survives `DirChanged` and Neovide restarts so `<leader>Dal` always resolves to the right group.

## License

MIT
