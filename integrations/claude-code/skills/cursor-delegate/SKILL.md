---
name: cursor-delegate
description: Delegate a coding or research task to an idle Cursor account via the cursor-agent CLI, so it runs on the Cursor subscription's quota instead of Claude's. Use when the user says "delegate to cursor", "use a cursor seat/account", "offload to cursor-agent", "spend the cursor quota", or wants Claude to drive Cursor as a worker (agent calling), including routing heavy self-contained slices of a larger job to a second agent.
---

# Delegate to Cursor (agent calling)

Claude stays the orchestrator; `cursor-agent` runs a self-contained slice on a Cursor account's quota. Use this to put idle company Cursor seats to work without leaving Claude, or to parallelize independent slices across accounts.

## The one command

Everything routes through one wrapper (the single source of truth):

```bash
~/.claude-deck/bin/cursor-run.sh --account <label> --dry-run "<self-contained task>"
```

Dry-run first (it prints the exact command with the API key redacted), show the user, then drop `--dry-run` to execute. Options: `--model <name|auto>`, `--json`, `--cwd <dir>`, and `-- <flags>` to pass anything straight to cursor-agent.

## Rules that make it work

1. **Self-contained tasks only.** cursor-agent starts with a blank context. Put the file paths, the goal, and the acceptance criteria inside the task string. "Fix the bug we discussed" will fail; "In `src/auth.js`, the `verify()` function returns true for expired tokens because it compares `exp` in seconds to `Date.now()` in ms. Fix it and add a test." will work.
2. **Pick the account.** A label resolves to an API key in `~/.claude-deck/cursor/agent-keys.json` (`{ "label": "key_..." }`, chmod 600) or, if no key, a login slot at `~/CursorProfiles/<label>/cli-home` (created once with `HOME=<that dir> cursor-agent login`). Omit `--account` entirely to use the machine's base `cursor-agent login`. Spread independent slices across several accounts to use more idle quota at once.
3. **Mind the meter.** Cursor's **Auto** model (`--model auto`) is unlimited on paid plans (no quota drawn); named models draw the monthly pool. For cheap/bulk work prefer Auto; for hardest work pick a specific model and say so.
4. **Let it act.** Headless runs do not prompt for approval, so file-editing tasks need cursor-agent's approval flag after `--` (e.g. `-- --force`).
5. **No secrets in the task text.** It leaves this machine for Cursor's servers.

## Multi-account fan-out

For several independent slices, run one delegation per slice, each on a different account, and collect the results:

```bash
~/.claude-deck/bin/cursor-run.sh --account acct1 --model auto "<slice 1>" -- --force &
~/.claude-deck/bin/cursor-run.sh --account acct2 --model auto "<slice 2>" -- --force &
wait
```

## Report back

Show the worker's output, then one line: what ran, which account, which model. If cursor-agent is missing, the key is bad, or quota is exhausted, say so and stop rather than quietly doing the work on Claude's quota.

## Setup (once)

See `integrations/claude-code/README.md` in the claude-deck repo: install `cursor-run.sh`, create `agent-keys.json` with each account's Cursor API key, and install `cursor-agent` (`curl https://cursor.com/install -fsS | bash`).
