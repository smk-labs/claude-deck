# Cursor delegation for Claude Code

Drive idle Cursor seats as worker agents from inside Claude Code (terminal CLI **or** the Claude Desktop Code tab, which loads the same `~/.claude` config). Claude stays the orchestrator and holds the context; `cursor-agent` runs a self-contained slice on the Cursor subscription's quota instead of Claude's. This is agent calling: one agent invoking another.

It does **not** swap Claude Code's model backend to Cursor (that is impossible: Cursor sells no Anthropic-shaped API for its subscription, and the desktop Code tab always uses your claude.ai account). It runs Cursor *alongside* Claude as a delegate.

## What's here

| File | Role |
|------|------|
| `cursor-run.sh` | The one primitive. Resolves an account's API key and invokes `cursor-agent -p`. Everything else calls this. |
| `skills/cursor-delegate/SKILL.md` | Teaches Claude when and how to delegate. Triggers on "delegate to cursor", "use a cursor seat", etc. |
| `agents/cursor-worker.md` | A subagent that owns one delegation and reports back. |
| `mcp/cursor-mcp.js` | Optional. Exposes a typed `cursor_run` tool over MCP (stdlib, zero deps) for clients that prefer a tool call over Bash. |
| `install.sh` | Copies the above into place. Opt-in; nothing is installed until you run it. |

Pick **one** surface (skill, subagent, or MCP) or install all three; they share `cursor-run.sh`, so behavior is identical.

## Setup

1. **Install cursor-agent** (the Cursor CLI):
   ```bash
   curl https://cursor.com/install -fsS | bash
   ```
   Restart your shell, then confirm: `cursor-agent --version`.

2. **Give each account credentials**, either way (or mix):
   - **Login slot (no keys, browser sign-in).** cursor-agent keeps its credential in `$HOME/.cursor/cli-config.json`, so a per-account `HOME` gives each account its own login (verified: `CURSOR_CONFIG_DIR` does *not* move the credential, `HOME` does):
     ```bash
     HOME="$HOME/CursorProfiles/work2/cli-home" cursor-agent login
     ```
     `--account work2` then finds that slot automatically. The base account needs nothing beyond a plain `cursor-agent login`.
   - **API key.** Cursor dashboard → Integrations / API Keys → create key, then store it in `~/.claude-deck/cursor/agent-keys.json` (chmod 600):
     ```json
     { "tech-sub": "key_...", "design": "key_..." }
     ```
   For `--account <label>`, a key wins over a slot if both exist.

4. **Install the integration:**
   ```bash
   ./install.sh
   ```
   This copies `cursor-run.sh` to `~/.claude-deck/bin/`, the skill to `~/.claude/skills/`, and the subagent to `~/.claude/agents/`. It prints the MCP snippet to add if you want the `cursor_run` tool too.

## Use it

Just ask Claude, e.g. "delegate writing the parser tests to the tech-sub Cursor account." Or drive the wrapper directly:

```bash
# dry-run prints the exact command with the key redacted
~/.claude-deck/bin/cursor-run.sh --account tech-sub --model auto --dry-run \
  "In src/parser.js, add table-driven tests covering the empty-input and unicode cases. Run them."

# drop --dry-run to execute; -- passes flags straight to cursor-agent
~/.claude-deck/bin/cursor-run.sh --account tech-sub --model auto \
  "…self-contained task…" -- --force
```

### The `cursor_run` MCP tool (optional)

Add to `~/.claude.json` (global) or a project `.mcp.json`:

```json
{
  "mcpServers": {
    "cursor": {
      "command": "node",
      "args": ["~/.claude-deck/bin/cursor-mcp.js"]
    }
  }
}
```

## Rules that keep it working

- **Self-contained tasks only.** `cursor-agent` starts with a blank context: put file paths, the goal, and acceptance criteria inside the task text.
- **Mind the meter.** Cursor **Auto** (`--model auto`) is unlimited on paid plans; named models draw the monthly usage pool.
- **Let it act.** Headless runs don't prompt, so file-editing needs cursor-agent's approval flag after `--` (e.g. `-- --force`).
- **No secrets in the task text.** It leaves this machine for Cursor's servers.
