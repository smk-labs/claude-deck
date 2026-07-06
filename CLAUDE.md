# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Never run the patch without asking

**Do not run `claude-deck patch`, `claude-deck revert`, or anything that touches `/Applications/Claude.app` unless the user explicitly asks for it in this session, and only after confirming Claude Desktop is quit.** Smoke-testing the patch quits the running app: `patch` and `revert` both need Claude closed to rewrite `app.asar`, and the script will try to quit it via `osascript`. If Claude is open with unsaved context (an in-progress chat, a login flow), killing it is disruptive. Ask first, every time. `status` and `list` are read-only and always safe to run.

## What this repo is

A single Bash script (`claude-deck.sh`) plus a small local dashboard (`dashboard/`). The script patches the macOS Claude Desktop app to accept a `--profile=NAME` launch argument, so each profile gets its own Electron `userData` directory, its own login session, and can run side by side with the others. The dashboard is a zero-dependency Node HTTP server that reads each profile's session key and shows its usage limits. There is no build system, no package manager, no tests: the script and the two dashboard files *are* the product.

## Running it

```bash
./claude-deck.sh patch              # apply (idempotent)
./claude-deck.sh patch --force      # re-apply even if already patched
./claude-deck.sh revert             # restore original Claude.app from backup
./claude-deck.sh status             # show patch state, hashes, backup info, known profiles
./claude-deck.sh open <name>         # launch (or focus) Claude with --profile=<name>
./claude-deck.sh list                # list known profiles and their cached usage
./claude-deck.sh dash [port]         # start the local dashboard (default port 8965)
./claude-deck.sh install             # copy to ~/.claude-deck/ + add zsh alias
./claude-deck.sh uninstall           # remove the alias only
./claude-deck.sh watchdog on|off     # install/remove the LaunchDaemon that re-patches on update (needs sudo)
```

`patch` and `revert` need `sudo` (writes into `/Applications/Claude.app`) and need Claude quit first. `open`, `list`, `dash`, and `status` never touch the app bundle and never need sudo.

To smoke-test a change: confirm with the user, then edit the script, run `./claude-deck.sh revert` (if previously applied), then `./claude-deck.sh patch`, then `./claude-deck.sh open work` and verify the window title shows `[work]` and the profile gets its own login. `status` is the fastest sanity check between iterations.

## Architecture / how the patch works

The five things that make this work as a self-contained script: touch any of them and you can break the whole flow:

1. **Asar extract → inject → repack.** The Electron app's code lives in `/Applications/Claude.app/Contents/Resources/app.asar`. The script uses `@electron/asar` (installed locally into `~/.claude-deck/tool/`, **pinned to ^3**: v4+ is ESM-only and breaks both the CLI invocation and the inline `require()` in the header-hash step) to extract, write `claude-deck.js` at the asar root, prepend `try { require('../../claude-deck.js') } catch (e) {}` to `.vite/build/index.pre.js` (the Electron main-process entry point), then repack.

2. **ElectronAsarIntegrity hash.** Electron refuses to load the asar if the SHA-256 in `Info.plist` (`:ElectronAsarIntegrity:Resources/app.asar:hash`) doesn't match. The hash is computed over the asar **header JSON**, not the whole file. After repack, the script recomputes it and updates the plist via `PlistBuddy`.

3. **Ad-hoc re-sign, never `--deep`.** `codesign --force --sign - --preserve-metadata=identifier,entitlements,flags,runtime` on the outer bundle only. **Do not add `--deep`**: it re-signs nested helpers as ad-hoc, which invalidates their keychain ACLs and causes repeated keychain prompts on every Claude launch. This is the single most important constraint in this repo; it was a real prior bug in the sibling `claude-rtl` project and the fix carries over verbatim.

4. **The injection itself** (`claude-deck.js`, written at patch time). Runs in the main process before `app.ready`, wrapped so nothing inside it can crash the app:
   - Reads `--profile=` from `process.argv`, sanitizes to `[A-Za-z0-9_-]`, caps at 32 chars.
   - If a profile is set, calls `app.setPath('userData', ...)` (and best-effort `app.setPath('sessionData', ...)` in its own try/catch) pointing at `~/Library/Application Support/Claude Profiles/<name>`.
   - On `app.on('browser-window-created')`, listens for `page-title-updated`, calls `preventDefault()`, and sets the title to `[<profile>] <original title>` so Mission Control, Cmd-backtick, and Raycast can tell windows apart.
   - After `app.whenReady()`, reads the `sessionKey` cookie for `https://claude.ai` and writes it to `~/.claude-deck/profiles/<label>.json` (mode 600), merging into any existing file so a cached `orgId` survives. Re-pulls every 30 minutes and on `ses.cookies.on('changed')` for `sessionKey`. Every failure path is silent: this code must never be the reason Claude fails to launch.

5. **Backup + idempotency.** First patch copies the pristine asar to `~/.claude-deck/backup/app.asar.orig` and stashes the original Info.plist hash + Claude version. The marker `claude-deck.js` inside the asar is the "is patched" signal. `revert` restores both the asar and the hash, then re-signs. `patch --force` re-applies even when the marker is already present (useful after editing the injected script).

## Portability constraints: don't break these

- **macOS Bash 3.2 only.** Default `/bin/bash` is 3.2 (no associative arrays, no `mapfile`, no `${var^^}`). Shebang is pinned to `/bin/bash`. `set -eu` + `set -o pipefail`.
- **macOS-native tools only** in the hot path: `curl`, `tar`, `shasum`, `codesign`, `osascript`, `PlistBuddy`, `xattr`, `launchctl`. No Homebrew. No GNU coreutils flags.
- **Node bootstrap.** If `node` is missing or <18, the script downloads Node 20 LTS (Apple Silicon or Intel, detected via `uname -m`) into `~/.claude-deck/`, never system-wide. Installer preference for `@electron/asar`: `bun` → `pnpm` → bootstrapped `npm`. The dashboard itself is stdlib-only Node (>=18, uses global `fetch`): no dependency to install to run it.
- **BSD sed/awk.** Sentinel-bounded removal (zshrc alias, uninstall) uses `awk`, because BSD `sed -i` semantics differ from GNU.

## State that lives outside the repo

- `~/.claude-deck/bin/claude-deck.sh`: canonical install location (the `install` target). The `claude-deck` alias in `~/.zshrc` points here.
- `~/.claude-deck/backup/`: `app.asar.orig`, `original-hash.txt`, `claude-version.txt`.
- `~/.claude-deck/profiles/<name>.json`: one file per profile, written by the injected code: `{ name, sessionKey, orgId?, updatedAt }`, file mode 600, dir mode 700. The dashboard reads these; it never writes a session key itself.
- `~/.claude-deck/tool/`: local `@electron/asar` install.
- `~/.claude-deck/node/`: bootstrapped Node 20, only if system Node was missing or too old.
- `~/Library/Application Support/Claude Profiles/<name>/`: per-profile Electron `userData`. The default (no `--profile`) instance is untouched and reports as profile name `default`. `claude-deck open default` and the dashboard's Open button both special-case the literal name `default` to mean "launch/focus the flag-less instance": neither ever spawns `--profile=default`.
- `~/.zshrc`: sentinel-wrapped alias block (`# >>> claude-deck shortcut >>>` … `<<<`). `uninstall` removes exactly that block and saves a `.bak.<timestamp>` first.
- `/usr/local/lib/claude-deck/`: root-owned copy of the watchdog script, installed by `watchdog on`. A user-writable script must never run as root, so `watchdog on` copies the script here (root:wheel) before wiring up the LaunchDaemon; it never points the daemon at a path the current user can edit.
- `/Library/LaunchDaemons/com.smklabs.claude-deck.plist`: installed by `watchdog on`, removed by `watchdog off`. Watches `Info.plist` for changes, skips while Claude is running, logs to `/var/log/claude-deck.log`. launchd never sets `SUDO_USER`, so `watchdog on` bakes the invoking user's name into the plist's `EnvironmentVariables` as `CLAUDE_DECK_USER`; the script re-anchors `HOME`/`USER` from that variable when it fires as root, so the daemon reads and writes the real user's `~/.claude-deck` (not root's).

## Shared account data, separate accounts

Every profile launches the same patched app copy and points at the same `~/.claude`, so Claude Code sessions, config, and settings are identical across every logged-in account. Only the Electron `userData` (chat history, cookies, local storage: the account login itself) is per-profile. This is the entire point: one 700MB app bundle, unlimited simultaneous logins, no duplicated installs.
