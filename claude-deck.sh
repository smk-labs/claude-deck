#!/bin/bash
# claude-deck: run many Claude Desktop accounts side by side on one Mac.
#
# Teaches the macOS Claude Desktop app a --profile=NAME argument. Each
# profile gets its own Electron userData dir, so you can be logged into
# several accounts at once (each in its own window), plus a local usage
# dashboard that shows every account's 5-hour / weekly / Opus limits with
# one-click open/focus per profile.
#
# Universal: works on stock macOS Bash 3.2 (no Homebrew needed) and
# auto-installs a local Node if you don't have one. Uses only macOS-
# native tools (curl, tar, shasum, codesign, PlistBuddy, osascript).
#
# Usage:
#   ./claude-deck.sh patch [--force]   # apply (idempotent)
#   ./claude-deck.sh revert            # restore original Claude.app
#   ./claude-deck.sh status            # show patch state, hashes, backup info
#   ./claude-deck.sh open [name]       # launch/focus a profile (no name = default)
#   ./claude-deck.sh list              # list known profiles
#   ./claude-deck.sh dash [port]       # run the local usage dashboard
#   ./claude-deck.sh install           # copy to ~/.claude-deck/bin + zsh alias
#   ./claude-deck.sh uninstall         # remove the alias only
#   ./claude-deck.sh watchdog on|off   # (sudo) auto re-patch after app updates
#   ./claude-deck.sh --help

set -eu
set -o pipefail

# When the watchdog LaunchDaemon fires this script as root, HOME is /var/root
# and SUDO_USER is unset (launchd, unlike sudo, never sets it). Re-anchor
# HOME/USER to the invoking (owning) user so $STATE_DIR resolves to the real
# user's home, not root's. watchdog-run always runs as root (that's the point
# of the daemon), so this matters on every daemon invocation. CLAUDE_DECK_USER
# is baked into the LaunchDaemon plist's EnvironmentVariables by
# cmd_watchdog_on, since launchd gives us no other way to learn who owns it.
_TARGET_USER="${SUDO_USER:-${CLAUDE_DECK_USER:-}}"
if [ "$(id -u)" = "0" ] && [ -n "$_TARGET_USER" ]; then
  _REAL_HOME=$(eval echo "~$_TARGET_USER")
  if [ -d "$_REAL_HOME" ]; then
    export HOME="$_REAL_HOME"
    export USER="$_TARGET_USER"
  fi
fi

APP="/Applications/Claude.app"
RES="$APP/Contents/Resources"
ASAR="$RES/app.asar"
PLIST="$APP/Contents/Info.plist"
STATE_DIR="$HOME/.claude-deck"
BACKUP_DIR="$STATE_DIR/backup"
BACKUP_ASAR="$BACKUP_DIR/app.asar.orig"
BACKUP_HASH="$BACKUP_DIR/original-hash.txt"
BACKUP_VERSION="$BACKUP_DIR/claude-version.txt"
PROFILES_DIR="$STATE_DIR/profiles"
MARKER="claude-deck.js"      # presence in asar means "patched"
OTHER_MARKER="rtl-fix.js"    # marker used by the sibling claude-rtl patch
PROFILES_USERDATA_ROOT="$HOME/Library/Application Support/Claude Profiles"

# Watchdog (root-owned copy + LaunchDaemon).
WD_LABEL="com.smklabs.claude-deck"
WD_ROOT_DIR="/usr/local/lib/claude-deck"
WD_ROOT_SCRIPT="$WD_ROOT_DIR/claude-deck.sh"
WD_PLIST="/Library/LaunchDaemons/$WD_LABEL.plist"
WD_LOG="/var/log/claude-deck.log"

# If we ran as root (via sudo, or via the watchdog LaunchDaemon), hand the
# state dir back to the owning user on exit so subsequent direct (non-sudo)
# invocations can still write into it.
_chown_state_on_exit() {
  if [ "$(id -u)" = "0" ] && [ -n "$_TARGET_USER" ] && [ -d "$STATE_DIR" ]; then
    chown -R "$_TARGET_USER:staff" "$STATE_DIR" 2>/dev/null || true
  fi
}
trap _chown_state_on_exit EXIT

c_red()    { printf "\033[31m%s\033[0m\n" "$*"; }
c_green()  { printf "\033[32m%s\033[0m\n" "$*"; }
c_yellow() { printf "\033[33m%s\033[0m\n" "$*"; }
c_dim()    { printf "\033[2m%s\033[0m\n" "$*"; }
step()     { printf "→ %s\n" "$*"; }
die()      { c_red "✗ $*"; exit 1; }

require_macos() {
  [ "$(uname -s)" = "Darwin" ] || die "claude-deck only runs on macOS."
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

ensure_prereqs() {
  require_macos
  require_cmd curl
  require_cmd tar
  require_cmd shasum
  require_cmd codesign
  require_cmd /usr/libexec/PlistBuddy
  [ -d "$APP" ] || die "Claude.app not found at $APP"
  ensure_node
  ensure_asar_tool
}

# Pinned local Node (LTS). Only downloaded if the user has no usable node.
LOCAL_NODE_VERSION="20.18.0"

ensure_node() {
  # Prefer system Node if it's 18+
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    local v
    v=$(node -p 'parseInt(process.versions.node)' 2>/dev/null || echo 0)
    if [ "${v:-0}" -ge 18 ] 2>/dev/null; then
      NODE_BIN="$(command -v node)"
      NPM_BIN="$(command -v npm)"
      return
    fi
  fi
  # Otherwise bootstrap a local Node into $STATE_DIR/node (one-time, ~30MB).
  local arch_id
  case "$(uname -m)" in
    arm64)  arch_id="darwin-arm64" ;;
    x86_64) arch_id="darwin-x64" ;;
    *) die "Unsupported macOS architecture: $(uname -m)" ;;
  esac
  local node_root="$STATE_DIR/node"
  local node_dir="$node_root/node-v$LOCAL_NODE_VERSION-$arch_id"
  if [ ! -x "$node_dir/bin/node" ]; then
    step "No usable Node found. Bootstrapping local Node $LOCAL_NODE_VERSION (~30 MB, one-time)..."
    mkdir -p "$node_root"
    local url="https://nodejs.org/dist/v$LOCAL_NODE_VERSION/node-v$LOCAL_NODE_VERSION-$arch_id.tar.gz"
    curl -fsSL "$url" | tar -xz -C "$node_root" \
      || die "Failed to download Node from $url (check your network)."
  fi
  NODE_BIN="$node_dir/bin/node"
  NPM_BIN="$node_dir/bin/npm"
}

# Install @electron/asar locally once so we can call it fast on every run.
# Pinned to ^3: v4+ went ESM-only and renamed the bin to asar.mjs, which
# breaks both `node bin/asar.js` and the inline `require('@electron/asar')`
# call in asar_header_hash.
#
# Installer preference: bun → pnpm → npm. The first one already on PATH wins;
# bootstrapped Node ships with npm as the guaranteed fallback.
ensure_asar_tool() {
  TOOL_DIR="$STATE_DIR/tool"
  if [ -f "$TOOL_DIR/node_modules/@electron/asar/bin/asar.js" ]; then
    return
  fi
  rm -rf "$TOOL_DIR"
  mkdir -p "$TOOL_DIR"
  printf '{"name":"claude-deck-tool","private":true}\n' > "$TOOL_DIR/package.json"

  local installer_name installer_cmd
  if command -v bun >/dev/null 2>&1; then
    installer_name="bun";  installer_cmd="bun add"
  elif command -v pnpm >/dev/null 2>&1; then
    installer_name="pnpm"; installer_cmd="pnpm add"
  else
    installer_name="npm";  installer_cmd="$NPM_BIN i"
  fi

  step "Installing @electron/asar via ${installer_name}..."
  # shellcheck disable=SC2086
  ( cd "$TOOL_DIR" && $installer_cmd '@electron/asar@^3' >/dev/null 2>&1 ) \
    || die "Failed to install @electron/asar into ${TOOL_DIR} (using ${installer_name})"
}

asar_run() {
  # $1 = "extract" | "pack" | "list"  ; $2..$N = args
  ( cd "$TOOL_DIR" && "$NODE_BIN" node_modules/@electron/asar/bin/asar.js "$@" )
}

quit_claude() {
  # Don't issue `tell app to quit` if Claude isn't running: AppleScript
  # would launch it just to quit it (matters during watchdog runs).
  if ! pgrep -x "Claude" >/dev/null 2>&1; then
    return 0
  fi
  step "Quitting Claude..."
  osascript -e 'tell application "Claude" to quit' 2>/dev/null || true
  for _ in 1 2 3 4 5; do
    pgrep -x "Claude" >/dev/null || break
    sleep 1
  done
  pkill -x "Claude" 2>/dev/null || true
  sleep 1
}

# Electron's ElectronAsarIntegrity is SHA-256 of the asar HEADER JSON,
# NOT of the whole file. Compute it the same way Electron does.
asar_header_hash() {
  local target="${1:-$ASAR}"
  ( cd "$TOOL_DIR" && "$NODE_BIN" -e "
    const asar = require('@electron/asar');
    const crypto = require('crypto');
    const { headerString } = asar.getRawHeader(process.argv[1]);
    process.stdout.write(crypto.createHash('sha256').update(headerString).digest('hex'));
  " "$target" )
}

plist_hash() {
  /usr/libexec/PlistBuddy -c "Print :ElectronAsarIntegrity:Resources/app.asar:hash" "$PLIST" 2>/dev/null || echo ""
}

is_patched() {
  # "patched" = our marker file present inside the asar
  asar_run list "$ASAR" 2>/dev/null | grep -q "/$MARKER$"
}

has_other_patch() {
  # True if the sibling claude-rtl patch's marker is present in the asar.
  asar_run list "$ASAR" 2>/dev/null | grep -q "/$OTHER_MARKER$"
}

claude_version() {
  /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST" 2>/dev/null || echo "?"
}

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------

cmd_status() {
  ensure_prereqs
  c_dim "Claude version:    $(claude_version)"
  c_dim "asar header hash:  $(asar_header_hash)"
  c_dim "Info.plist hash:   $(plist_hash)"
  if is_patched; then
    c_green "● PATCHED (--profile support active)"
  else
    c_yellow "○ not patched"
  fi
  if has_other_patch; then
    c_yellow "  note: claude-rtl patch is also present in this asar."
  fi
  if [ -f "$BACKUP_ASAR" ]; then
    c_dim "Backup present: $BACKUP_ASAR"
    c_dim "Backup header hash: $(asar_header_hash "$BACKUP_ASAR")"
    [ -f "$BACKUP_VERSION" ] && c_dim "Backup taken from Claude version: $(cat "$BACKUP_VERSION")"
  else
    c_dim "No backup recorded."
  fi

  local n_profiles=0
  if [ -d "$PROFILES_DIR" ]; then
    n_profiles=$(find "$PROFILES_DIR" -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')
  fi
  c_dim "Known profiles (captured session keys): $n_profiles"

  if [ -f "$WD_PLIST" ]; then
    c_green "● watchdog installed ($WD_PLIST)"
  else
    c_dim "watchdog not installed"
  fi
}

# ---------------------------------------------------------------------------
# patch (apply)
# ---------------------------------------------------------------------------

cmd_patch() {
  local force="no"
  local arg
  for arg in "$@"; do
    case "$arg" in
      --force) force="yes" ;;
    esac
  done

  ensure_prereqs

  if is_patched && [ "$force" != "yes" ]; then
    c_green "Already patched. Nothing to do."
    c_dim "Run with 'revert' to undo, 'status' to inspect, or '--force' to re-apply."
    exit 0
  fi

  if has_other_patch; then
    c_yellow "Warning: the claude-rtl patch is already applied to this app.asar."
    c_yellow "Patching on top means the backup this script takes will include"
    c_yellow "that patch too: reverting claude-deck later will NOT bring back"
    c_yellow "a pristine (unpatched) app, only the claude-rtl-patched one."
    c_yellow "Recommended: revert claude-rtl first (claude-rtl --revert), then"
    c_yellow "run claude-deck patch, then re-apply claude-rtl if you still want it."
    if [ "$force" != "yes" ]; then
      printf "Continue anyway? [y/N] "
      read -r _reply || _reply=""
      case "$_reply" in
        y|Y|yes|YES) : ;;
        *) die "Aborted. Re-run with --force to skip this prompt." ;;
      esac
    else
      c_dim "--force given, continuing despite claude-rtl patch being present."
    fi
  fi

  quit_claude
  _snapshot_backup_if_needed

  WORK="$(mktemp -d)/claude-deck-asar"
  step "Extracting asar → $WORK"
  asar_run extract "$ASAR" "$WORK"

  step "Writing claude-deck injector module..."
  _write_injector "$WORK/$MARKER"

  step "Wiring injector into entry point..."
  ENTRY="$WORK/.vite/build/index.pre.js"
  [ -f "$ENTRY" ] || die "Entry point not found: $ENTRY (Claude internal layout changed?)"
  if ! grep -q "$MARKER" "$ENTRY"; then
    {
      printf "try { require('../../%s'); } catch (e) { console.error('claude-deck load failed:', e); }\n" "$MARKER"
      cat "$ENTRY"
    } > "$ENTRY.tmp" && mv "$ENTRY.tmp" "$ENTRY"
  fi

  step "Repacking asar..."
  TMP_ASAR="$(mktemp -t claude-deck-asar-XXXXXX).asar"
  # Preserve files Electron loads from disk (native *.node modules + node-pty's
  # spawn-helper). Without --unpack they get packed INTO the asar, where Electron
  # cannot dlopen them, so the main process throws on launch and Claude never opens.
  asar_run pack "$WORK" "$TMP_ASAR" --unpack "{*.node,spawn-helper}"
  sudo mv "$TMP_ASAR" "$ASAR"

  step "Updating ElectronAsarIntegrity hash in Info.plist..."
  NEWHASH=$(asar_header_hash)
  sudo /usr/libexec/PlistBuddy -c "Set :ElectronAsarIntegrity:Resources/app.asar:hash $NEWHASH" "$PLIST"
  c_dim "  new header hash: $NEWHASH"

  step "Ad-hoc re-signing the bundle..."
  # Do NOT add --deep. --deep re-signs nested helpers (renderer/GPU helpers)
  # ad-hoc too, which invalidates their keychain ACLs and causes a keychain
  # prompt on every single Claude launch afterward. Sign the outer bundle only,
  # preserving identifier/entitlements/flags/runtime so Gatekeeper stays calm.
  sudo codesign --force --sign - --preserve-metadata=identifier,entitlements,flags,runtime "$APP"
  sudo xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

  rm -rf "$(dirname "$WORK")"

  c_green "✓ Patched. Claude now understands --profile=NAME."
  c_dim   "Try: $0 open work   (launches a second, independent instance)"
  c_dim   "Revert anytime with: $0 revert"
}

# Snapshot originals into $BACKUP_DIR (only if we don't have a clean backup
# yet, or the installed Claude version has moved on since the last backup,
# in which case the old backup is stale and we refresh it).
_snapshot_backup_if_needed() {
  mkdir -p "$BACKUP_DIR"
  if [ -f "$BACKUP_ASAR" ] && [ -f "$BACKUP_VERSION" ]; then
    local backed_up_version installed_version
    backed_up_version="$(cat "$BACKUP_VERSION" 2>/dev/null || echo "")"
    installed_version="$(claude_version)"
    if [ "$backed_up_version" != "$installed_version" ]; then
      c_yellow "Backup was taken from Claude $backed_up_version, but $installed_version is installed."
      c_yellow "Refreshing backup (the currently installed asar is assumed pristine right now,"
      c_yellow "i.e. this is a fresh, unpatched install after an app update)."
      step "Refreshing pristine backup → $BACKUP_ASAR"
      sudo cp "$ASAR" "$BACKUP_ASAR"
      plist_hash > "$BACKUP_HASH"
      claude_version > "$BACKUP_VERSION"
    else
      c_dim "Reusing existing backup at $BACKUP_ASAR"
    fi
    return
  fi
  step "Saving pristine backup → $BACKUP_ASAR"
  sudo cp "$ASAR" "$BACKUP_ASAR"
  plist_hash > "$BACKUP_HASH"
  claude_version > "$BACKUP_VERSION"
}

# Writes the injected main-process module. Kept in its own function (instead
# of inline in cmd_patch) purely so cmd_watchdog_run can reuse it verbatim.
_write_injector() {
  local out="$1"
  cat > "$out" <<'JS'
// Injected by claude-deck.sh: adds --profile=NAME support so multiple
// Claude accounts can run simultaneously, each with its own userData dir,
// and reports each profile's session key locally for the usage dashboard.
// Everything here is wrapped defensively: this module must never be able
// to crash the app, even if Claude's internals change under us.
const { app, session } = require('electron');
const fs = require('fs');
const path = require('path');
const os = require('os');

function safeRun(fn) {
  try { fn(); } catch (e) { /* never let injected code crash the app */ }
}

function getProfileArg() {
  var argv = process.argv || [];
  for (var i = 0; i < argv.length; i++) {
    var a = argv[i];
    if (typeof a === 'string' && a.indexOf('--profile=') === 0) {
      var raw = a.slice('--profile='.length);
      var clean = raw.replace(/[^A-Za-z0-9_-]/g, '');
      if (clean.length > 32) clean = clean.slice(0, 32);
      return clean.length > 0 ? clean : null;
    }
  }
  return null;
}

var PROFILE = null;
safeRun(function () { PROFILE = getProfileArg(); });
var LABEL = PROFILE || 'default';

// 1) Separate userData (and best-effort sessionData) per profile, so each
//    profile is a fully independent Electron app instance: separate cookies,
//    separate localStorage, separate login.
safeRun(function () {
  if (PROFILE) {
    var base = path.join(app.getPath('appData'), 'Claude Profiles', PROFILE);
    app.setPath('userData', base);
    safeRun(function () { app.setPath('sessionData', base); });
  }
});

// 2) Tag window titles with the profile name so Mission Control, Cmd+Tab,
//    and launchers like Raycast can tell instances apart at a glance.
safeRun(function () {
  app.on('browser-window-created', function (_evt, win) {
    safeRun(function () {
      if (!PROFILE || !win || !win.webContents) return;
      win.webContents.on('page-title-updated', function (evt, title) {
        safeRun(function () {
          evt.preventDefault();
          win.setTitle('[' + PROFILE + '] ' + title);
        });
      });
    });
  });
});

// 3) Session-key reporter: writes ~/.claude-deck/profiles/<label>.json so the
//    local dashboard can read usage without the app doing any network calls
//    itself. Merges into any existing file so a cached orgId survives.
var STATE_DIR = path.join(os.homedir(), '.claude-deck');
var PROFILES_DIR = path.join(STATE_DIR, 'profiles');

function readExistingProfile(file) {
  var result = {};
  safeRun(function () {
    if (fs.existsSync(file)) {
      var raw = fs.readFileSync(file, 'utf8');
      var parsed = JSON.parse(raw);
      if (parsed && typeof parsed === 'object') result = parsed;
    }
  });
  return result;
}

function writeProfileFile(sessionKey) {
  safeRun(function () {
    if (!sessionKey) return;
    fs.mkdirSync(STATE_DIR, { recursive: true, mode: 0o700 });
    fs.mkdirSync(PROFILES_DIR, { recursive: true, mode: 0o700 });
    var file = path.join(PROFILES_DIR, LABEL + '.json');
    var existing = readExistingProfile(file);
    existing.name = LABEL;
    existing.sessionKey = sessionKey;
    existing.updatedAt = new Date().toISOString();
    // existing.orgId (if any) is preserved as-is: the dashboard caches it.
    fs.writeFileSync(file, JSON.stringify(existing), { mode: 0o600 });
    safeRun(function () { fs.chmodSync(file, 0o600); });
  });
}

function pullSessionKey(ses) {
  safeRun(function () {
    ses.cookies.get({ url: 'https://claude.ai', name: 'sessionKey' })
      .then(function (cookies) {
        safeRun(function () {
          if (cookies && cookies.length > 0 && cookies[0].value) {
            writeProfileFile(cookies[0].value);
          }
        });
      })
      .catch(function () {});
  });
}

safeRun(function () {
  app.whenReady().then(function () {
    safeRun(function () {
      var ses = (PROFILE ? session.defaultSession : session.defaultSession);
      pullSessionKey(ses);
      // Re-pull periodically in case the cookie change event is missed
      // (e.g. token silently refreshed without a 'changed' event).
      setInterval(function () { pullSessionKey(ses); }, 30 * 60 * 1000);
      safeRun(function () {
        ses.cookies.on('changed', function (_evt, cookie, _cause, removed) {
          safeRun(function () {
            if (removed) return;
            if (cookie && cookie.name === 'sessionKey' && cookie.domain && cookie.domain.indexOf('claude.ai') !== -1) {
              writeProfileFile(cookie.value);
            }
          });
        });
      });
    });
  }).catch(function () {});
});
JS
}

# ---------------------------------------------------------------------------
# revert
# ---------------------------------------------------------------------------

cmd_revert() {
  ensure_prereqs
  [ -f "$BACKUP_ASAR" ] || die "No backup found at $BACKUP_ASAR: nothing to revert."

  quit_claude

  step "Restoring original app.asar from $BACKUP_ASAR..."
  sudo cp "$BACKUP_ASAR" "$ASAR"

  if [ -f "$BACKUP_HASH" ] && [ -s "$BACKUP_HASH" ]; then
    OLDHASH=$(cat "$BACKUP_HASH")
    step "Restoring ElectronAsarIntegrity hash → $OLDHASH"
    sudo /usr/libexec/PlistBuddy -c "Set :ElectronAsarIntegrity:Resources/app.asar:hash $OLDHASH" "$PLIST"
  else
    c_yellow "No saved Info.plist hash; recomputing from restored asar..."
    OLDHASH=$(asar_header_hash)
    sudo /usr/libexec/PlistBuddy -c "Set :ElectronAsarIntegrity:Resources/app.asar:hash $OLDHASH" "$PLIST"
  fi

  step "Ad-hoc re-signing to keep Gatekeeper happy..."
  # Same --deep caveat as cmd_patch: never add it here either.
  sudo codesign --force --sign - --preserve-metadata=identifier,entitlements,flags,runtime "$APP"
  sudo xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

  c_green "✓ Reverted. Claude is back to its original state."
  c_dim   "Backup retained at $BACKUP_ASAR. Delete $STATE_DIR if you don't need it."
}

# ---------------------------------------------------------------------------
# open / list
# ---------------------------------------------------------------------------

_validate_profile_name() {
  local name="$1"
  case "$name" in
    "") die "Profile name cannot be empty." ;;
  esac
  local len=${#name}
  [ "$len" -le 32 ] || die "Profile name too long (max 32 chars): $name"
  case "$name" in
    *[!A-Za-z0-9_-]*) die "Profile name must match [A-Za-z0-9_-]: $name" ;;
  esac
}

_profile_is_running() {
  # True if a Claude process is running for <name>. The real default instance
  # never carries --profile= at all (mirrors server.js getRunningProfiles),
  # so "default" means "a Claude process with no --profile= flag"; any other
  # name means "a Claude process with --profile=<name>".
  local name="$1"
  if [ "$name" = "default" ]; then
    ps ax -o command 2>/dev/null \
      | grep -F "Claude.app/Contents/MacOS/Claude" \
      | grep -v grep | grep -v -- "--profile=" >/dev/null 2>&1
  else
    ps ax -o command 2>/dev/null | grep -F -- "--profile=$name" | grep -v grep >/dev/null 2>&1
  fi
}

cmd_open() {
  local name="${1:-}"

  if [ -z "$name" ] || [ "$name" = "default" ]; then
    # Default profile: never use -n here. A second instance on the default
    # profile's userData dir would corrupt it (two processes writing the
    # same LevelDB/session store).
    step "Opening Claude (default profile)..."
    open -a "Claude"
    return
  fi

  _validate_profile_name "$name"

  if _profile_is_running "$name"; then
    step "Profile '$name' already running: focusing its window..."
    osascript -e 'tell application "Claude" to activate' 2>/dev/null || true
    # Best-effort: raise the specific window whose title carries our tag.
    # This needs Accessibility permission for System Events; if it's not
    # granted, we silently fall back to just having activated the app above.
    osascript <<OSA 2>/dev/null || true
tell application "System Events"
  tell process "Claude"
    repeat with w in windows
      if name of w contains "[$name]" then
        perform action "AXRaise" of w
        exit repeat
      end if
    end repeat
  end tell
end tell
OSA
  else
    step "Launching new Claude instance for profile '$name'..."
    open -n -a "Claude" --args --profile="$name"
  fi
}

cmd_list() {
  local seen_file
  seen_file="$(mktemp)"

  if [ -d "$PROFILES_DIR" ]; then
    find "$PROFILES_DIR" -maxdepth 1 -name '*.json' -type f 2>/dev/null | while IFS= read -r f; do
      basename "$f" .json
    done >> "$seen_file"
  fi
  if [ -d "$PROFILES_USERDATA_ROOT" ]; then
    find "$PROFILES_USERDATA_ROOT" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | while IFS= read -r d; do
      basename "$d"
    done >> "$seen_file"
  fi

  if [ ! -s "$seen_file" ]; then
    c_dim "No profiles found yet. Use: $0 open <name>"
    rm -f "$seen_file"
    return
  fi

  sort -u "$seen_file" | while IFS= read -r name; do
    [ -n "$name" ] || continue
    local running="no" has_key="no"
    _profile_is_running "$name" && running="yes"
    [ -f "$PROFILES_DIR/$name.json" ] && has_key="yes"
    printf "%-20s running=%-4s key=%-4s\n" "$name" "$running" "$has_key"
  done
  rm -f "$seen_file"
}

# ---------------------------------------------------------------------------
# dash
# ---------------------------------------------------------------------------

_resolve_node_for_dash() {
  if command -v node >/dev/null 2>&1; then
    local v
    v=$(node -p 'parseInt(process.versions.node)' 2>/dev/null || echo 0)
    if [ "${v:-0}" -ge 18 ] 2>/dev/null; then
      DASH_NODE="$(command -v node)"
      return
    fi
  fi
  ensure_node
  DASH_NODE="$NODE_BIN"
}

cmd_dash() {
  local port="${1:-8965}"
  _resolve_node_for_dash

  local script_dir
  script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
  local server_js="$script_dir/dashboard/server.js"
  [ -f "$server_js" ] || die "dashboard/server.js not found next to this script ($script_dir)."

  step "Starting dashboard on http://127.0.0.1:$port ..."
  ( sleep 1; open "http://127.0.0.1:$port" >/dev/null 2>&1 || true ) &
  CLAUDE_DECK_PORT="$port" exec "$DASH_NODE" "$server_js"
}

# ---------------------------------------------------------------------------
# install / uninstall
# ---------------------------------------------------------------------------

RC_FILE="${ZDOTDIR:-$HOME}/.zshrc"
RC_BEGIN="# >>> claude-deck shortcut >>>"
RC_END="# <<< claude-deck shortcut <<<"
CANONICAL_DIR="$STATE_DIR/bin"
CANONICAL_PATH="$CANONICAL_DIR/claude-deck.sh"
SOURCE_PATH="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/$(basename "${BASH_SOURCE[0]:-$0}")"
SOURCE_DIR="$(dirname "$SOURCE_PATH")"

cmd_install() {
  # 1) Copy ourselves (+ dashboard/) to the canonical home so the user can
  #    delete the original checkout without breaking the alias.
  mkdir -p "$CANONICAL_DIR"
  if [ "$SOURCE_PATH" = "$CANONICAL_PATH" ]; then
    c_dim "Running from canonical location: script already in place."
  else
    step "Installing script → $CANONICAL_PATH"
    cp -f "$SOURCE_PATH" "$CANONICAL_PATH"
    chmod 755 "$CANONICAL_PATH"
    if [ -d "$SOURCE_DIR/dashboard" ]; then
      step "Copying dashboard/ → $CANONICAL_DIR/dashboard"
      rm -rf "$CANONICAL_DIR/dashboard"
      cp -R "$SOURCE_DIR/dashboard" "$CANONICAL_DIR/dashboard"
    fi
  fi

  # 2) Wire up the zshrc alias (pointing at the canonical copy).
  [ -e "$RC_FILE" ] || touch "$RC_FILE"
  if grep -q "$RC_BEGIN" "$RC_FILE"; then
    c_yellow "Alias already present in $RC_FILE: leaving it alone."
    c_dim    "(Script at $CANONICAL_PATH was refreshed.)"
  else
    step "Adding 'claude-deck' alias to $RC_FILE"
    {
      printf "\n%s\n" "$RC_BEGIN"
      printf "alias claude-deck=%q\n" "$CANONICAL_PATH"
      printf "%s\n" "$RC_END"
    } >> "$RC_FILE"
  fi

  c_green "✓ Installed."
  c_dim   "Script is safe at: $CANONICAL_PATH (original checkout can be removed)"
  c_dim   "Open a new terminal (or: source $RC_FILE), then use:"
  c_dim   "  claude-deck patch       # apply"
  c_dim   "  claude-deck open work   # launch/focus a profile"
  c_dim   "  claude-deck dash        # usage dashboard"
}

cmd_uninstall() {
  if [ ! -f "$RC_FILE" ] || ! grep -q "$RC_BEGIN" "$RC_FILE"; then
    c_yellow "No shortcut block found in $RC_FILE: nothing to remove."
    exit 0
  fi
  step "Removing 'claude-deck' alias from $RC_FILE"
  # Strip the sentinel block (BSD awk compatible; BSD sed -i semantics differ
  # from GNU so we intentionally use awk here, not sed).
  cp "$RC_FILE" "$RC_FILE.bak.$(date +%s)"
  awk -v b="$RC_BEGIN" -v e="$RC_END" '
    $0 ~ b {skip=1; next}
    $0 ~ e {skip=0; next}
    !skip
  ' "$RC_FILE" > "$RC_FILE.tmp" && mv "$RC_FILE.tmp" "$RC_FILE"
  c_green "✓ Removed. Open a new terminal for it to take effect."
}

# ---------------------------------------------------------------------------
# watchdog
# ---------------------------------------------------------------------------

cmd_watchdog() {
  local mode="${1:-}"
  case "$mode" in
    on)  cmd_watchdog_on ;;
    off) cmd_watchdog_off ;;
    *)   die "Usage: $0 watchdog on|off" ;;
  esac
}

cmd_watchdog_on() {
  # Capture the owning user now, while we're still running as them (this
  # command uses `sudo` per-step below, it doesn't re-exec the whole script
  # as root). launchd never sets SUDO_USER for the daemon it fires later, so
  # we bake the name into the plist's EnvironmentVariables: it's the only
  # way watchdog-run can later learn whose ~/.claude-deck to use.
  local wd_user="${SUDO_USER:-$USER}"

  step "Installing root-owned copy → $WD_ROOT_SCRIPT"
  # A user-writable script must never run as root: root-own both the dir
  # and the file so a compromised user account can't hijack the daemon.
  sudo mkdir -p "$WD_ROOT_DIR"
  sudo cp "$SOURCE_PATH" "$WD_ROOT_SCRIPT"
  if [ -d "$SOURCE_DIR/dashboard" ]; then
    sudo rm -rf "$WD_ROOT_DIR/dashboard"
    sudo cp -R "$SOURCE_DIR/dashboard" "$WD_ROOT_DIR/dashboard"
  fi
  sudo chown -R root:wheel "$WD_ROOT_DIR"
  sudo chmod 755 "$WD_ROOT_DIR"
  sudo chmod 755 "$WD_ROOT_SCRIPT"

  step "Writing LaunchDaemon → $WD_PLIST"
  local tmp_plist
  tmp_plist="$(mktemp)"
  cat > "$tmp_plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTD/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$WD_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$WD_ROOT_SCRIPT</string>
    <string>watchdog-run</string>
  </array>
  <key>WatchPaths</key>
  <array><string>$PLIST</string></array>
  <key>RunAtLoad</key><false/>
  <key>EnvironmentVariables</key>
  <dict>
    <key>CLAUDE_DECK_USER</key><string>$wd_user</string>
  </dict>
  <key>StandardOutPath</key><string>$WD_LOG</string>
  <key>StandardErrorPath</key><string>$WD_LOG</string>
</dict>
</plist>
EOF
  sudo cp "$tmp_plist" "$WD_PLIST"
  rm -f "$tmp_plist"
  sudo chown root:wheel "$WD_PLIST"
  sudo chmod 644 "$WD_PLIST"

  step "Loading LaunchDaemon..."
  sudo launchctl bootout system "$WD_PLIST" 2>/dev/null || true
  if ! sudo launchctl bootstrap system "$WD_PLIST" 2>/dev/null; then
    c_yellow "bootstrap failed, falling back to 'launchctl load -w'..."
    sudo launchctl load -w "$WD_PLIST" \
      || die "Failed to load the watchdog LaunchDaemon."
  fi

  c_green "✓ Watchdog enabled."
  c_dim "Whenever Claude's auto-updater replaces Info.plist, claude-deck re-patches automatically."
  c_dim "Log: $WD_LOG  (tail with: sudo tail -f $WD_LOG)"
  c_dim "Disable with: $0 watchdog off"
}

cmd_watchdog_off() {
  step "Unloading LaunchDaemon..."
  sudo launchctl bootout system "$WD_PLIST" 2>/dev/null || true
  sudo launchctl unload -w "$WD_PLIST" 2>/dev/null || true
  [ -f "$WD_PLIST" ] && sudo rm -f "$WD_PLIST"

  if [ -d "$WD_ROOT_DIR" ]; then
    step "Removing root-owned copy → $WD_ROOT_DIR"
    sudo rm -rf "$WD_ROOT_DIR"
  fi

  c_green "✓ Watchdog disabled."
  c_dim "Patch state unchanged. Run 'revert' if you also want to undo the patch itself."
}

# Internal entry point invoked by the LaunchDaemon as root. Non-interactive:
# no osascript quit prompts, no y/N prompts: behaves like patch --force but
# also skips work entirely (instead of erroring) when there's nothing to do.
cmd_watchdog_run() {
  sleep 15   # the app's auto-updater may still be writing files when we fire

  if [ ! -d "$APP" ]; then
    echo "$(date): skip: Claude.app not found" >> "$WD_LOG" 2>/dev/null || true
    exit 0
  fi

  ensure_prereqs

  if is_patched; then
    echo "$(date): skip: already patched" >> "$WD_LOG" 2>/dev/null || true
    exit 0
  fi

  if pgrep -x "Claude" >/dev/null 2>&1; then
    echo "$(date): skip: app running" >> "$WD_LOG" 2>/dev/null || true
    exit 0
  fi

  echo "$(date): applying patch (non-interactive)" >> "$WD_LOG" 2>/dev/null || true
  cmd_patch --force
}

# ---------------------------------------------------------------------------
# help
# ---------------------------------------------------------------------------

cmd_help() {
  cat <<EOF
claude-deck: run many Claude Desktop accounts side by side on one Mac (macOS)

Teaches Claude.app a --profile=NAME argument (separate Electron userData per
profile = separate simultaneous logins), plus a local usage dashboard.

Usage:
  $0 patch [--force]     apply the patch (idempotent; safe to re-run)
  $0 revert              restore the original Claude.app
  $0 status              show patch state, hashes, backup info, profiles
  $0 open [name]         launch/focus a profile (no name = default profile)
  $0 list                list known profiles (running? key captured?)
  $0 dash [port]         run the local usage dashboard (default port 8965)
  $0 install             add 'claude-deck' shortcut to ~/.zshrc
  $0 uninstall           remove the 'claude-deck' shortcut from ~/.zshrc
  $0 watchdog on|off     (sudo) auto re-patch after Claude updates
  $0 --help              this message

Notes:
  - patch/revert require sudo (writes into /Applications/Claude.app).
  - Backup of the original app.asar is saved in: $BACKUP_DIR
  - Re-signs the bundle ad-hoc (Apple notarization is lost, locally-only fine).
  - Profile session keys are cached in: $PROFILES_DIR (mode 600)
EOF
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------

SUBCOMMAND="${1:-}"
[ $# -gt 0 ] && shift || true

case "$SUBCOMMAND" in
  patch)          cmd_patch "$@" ;;
  revert)         cmd_revert ;;
  status)         cmd_status ;;
  open)           cmd_open "$@" ;;
  list)           cmd_list ;;
  dash)           cmd_dash "$@" ;;
  install)        cmd_install ;;
  uninstall)      cmd_uninstall ;;
  watchdog)       cmd_watchdog "$@" ;;
  watchdog-run)   cmd_watchdog_run ;;
  --help|-h|help) cmd_help ;;
  "")             cmd_help ;;
  *)              cmd_help; exit 1 ;;
esac
