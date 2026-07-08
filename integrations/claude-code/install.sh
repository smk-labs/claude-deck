#!/bin/bash
# Installs the Cursor delegation integration for Claude Code. Opt-in: run it
# when you want the skill / subagent / MCP live. Idempotent, user-scoped, no
# sudo. Nothing here touches Claude.app or the dashboard.
set -eu

SRC="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/.claude-deck/bin"
SKILLS="$HOME/.claude/skills"
AGENTS="$HOME/.claude/agents"
CURSOR_DIR="$HOME/.claude-deck/cursor"
KEYS="$CURSOR_DIR/agent-keys.json"

echo "Installing Cursor delegation for Claude Code..."

mkdir -p "$BIN" "$SKILLS" "$AGENTS" "$CURSOR_DIR"

install -m 0755 "$SRC/cursor-run.sh" "$BIN/cursor-run.sh"
install -m 0644 "$SRC/mcp/cursor-mcp.js" "$BIN/cursor-mcp.js"
echo "  installed $BIN/cursor-run.sh"
echo "  installed $BIN/cursor-mcp.js"

mkdir -p "$SKILLS/cursor-delegate"
install -m 0644 "$SRC/skills/cursor-delegate/SKILL.md" "$SKILLS/cursor-delegate/SKILL.md"
echo "  installed $SKILLS/cursor-delegate/SKILL.md"

install -m 0644 "$SRC/agents/cursor-worker.md" "$AGENTS/cursor-worker.md"
echo "  installed $AGENTS/cursor-worker.md"

# Seed a template key file only if the user has none yet (never clobber real keys).
if [ ! -f "$KEYS" ]; then
  umask 077
  printf '{\n  "example": "key_replace_me"\n}\n' > "$KEYS"
  chmod 600 "$KEYS"
  echo "  created template $KEYS (chmod 600) - put your real Cursor API keys here"
else
  echo "  kept existing $KEYS"
fi

cat <<EOF

Done. Next:
  1. cursor-agent installed?   curl https://cursor.com/install -fsS | bash
  2. Put real keys in          $KEYS
  3. Try it:                   $BIN/cursor-run.sh --account <label> --dry-run "hello"

Optional MCP tool (cursor_run) - add to ~/.claude.json or a project .mcp.json:
  { "mcpServers": { "cursor": { "command": "node", "args": ["$BIN/cursor-mcp.js"] } } }
EOF
