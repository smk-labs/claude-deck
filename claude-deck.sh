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
#   ./claude-deck.sh patch [--force] [--verify-launch]  # apply (idempotent)
#   ./claude-deck.sh revert            # restore original Claude.app
#   ./claude-deck.sh status            # show patch state, hashes, backup info
#   ./claude-deck.sh open [name]       # launch/focus a profile (no name = default)
#   ./claude-deck.sh list              # list known profiles
#   ./claude-deck.sh dash [port]       # run the local usage dashboard
#   ./claude-deck.sh doctor            # repair session-index links, check patch freshness
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

# --app <path> (hidden option, also settable via CLAUDE_DECK_APP) redirects
# every APP/RES/ASAR/PLIST path at an alternate .app bundle instead of the
# real /Applications/Claude.app. This exists purely so the patch logic can be
# smoke-tested against a scratch copy of the app without touching the real
# one. It is scanned out of argv here, before dispatch, so every subcommand
# sees the override transparently. When the target is user-writable we also
# skip sudo entirely (see SUDO below) so a scratch copy never prompts.
APP="${CLAUDE_DECK_APP:-/Applications/Claude.app}"
_argv=()
while [ $# -gt 0 ]; do
  case "$1" in
    --app)
      shift
      [ $# -gt 0 ] || { printf "✗ --app requires a path argument\n" >&2; exit 1; }
      APP="$1"
      shift
      ;;
    --app=*)
      APP="${1#--app=}"
      shift
      ;;
    *)
      _argv+=("$1")
      shift
      ;;
  esac
done
if [ ${#_argv[@]} -gt 0 ]; then
  set -- "${_argv[@]}"
else
  set --
fi

RES="$APP/Contents/Resources"
ASAR="$RES/app.asar"
PLIST="$APP/Contents/Info.plist"

# Use plain (non-sudo) file operations when the target bundle is user-writable
# (i.e. a scratch/test copy, never the real /Applications install which is
# root:admin). This lets --app point at a throwaway copy without any sudo
# prompts. SUDO is always assigned exactly one of two literal strings, never
# unset, so `$SUDO cmd` below is safe under `set -u`.
if [ -w "$APP" ] 2>/dev/null; then
  SUDO=""
else
  SUDO="sudo"
fi

STATE_DIR="$HOME/.claude-deck"
# Backups for an alternate --app target live in their own tree so a smoke
# test against a scratch copy can never read from or clobber the real
# Claude.app backup. Everything else (bootstrapped Node, the asar tool,
# captured profile session keys) is shared: those aren't app-bundle state.
BACKUP_DIR="$STATE_DIR/backup"
if [ "$APP" != "/Applications/Claude.app" ]; then
  BACKUP_DIR="$STATE_DIR/backup-alt"
fi
BACKUP_ASAR="$BACKUP_DIR/app.asar.orig"
BACKUP_UNPACKED="$BACKUP_DIR/app.asar.unpacked.orig"
BACKUP_HASH="$BACKUP_DIR/original-hash.txt"
BACKUP_VERSION="$BACKUP_DIR/claude-version.txt"
PROFILES_DIR="$STATE_DIR/profiles"
MARKER="claude-deck.js"      # presence in asar means "patched"
OTHER_MARKER="rtl-fix.js"    # marker used by the sibling claude-rtl patch
PROFILES_USERDATA_ROOT="$HOME/Library/Application Support/Claude Profiles"
SHARED_SESSIONS_DIR="$HOME/Library/Application Support/Claude/claude-code-sessions"

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
  # Never quit/kill the real, running Claude Desktop app as a side effect of
  # patching a --app scratch target: osascript/pkill here are name-based
  # ("Claude"), not path-based, so they'd hit the real app regardless of
  # which bundle we're actually patching. Only act when the target IS the
  # real install.
  if [ "$APP" != "/Applications/Claude.app" ]; then
    c_dim "Skipping quit_claude: target is $APP, not the real Claude.app."
    return 0
  fi
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

# Prints every path in an asar's header marked unpacked:true, one per line,
# sorted. Native modules (*.node), dylibs, and node-pty's spawn-helper are
# stored this way so Electron can dlopen/exec them straight off disk instead
# of from inside the asar archive (which it cannot do). Losing this set on
# repack is exactly what bricks the app: see asar_pack_preserving_unpacked.
asar_unpacked_list() {
  local target="$1"
  ( cd "$TOOL_DIR" && "$NODE_BIN" -e "
    const asar = require('@electron/asar');
    const { header } = asar.getRawHeader(process.argv[1]);
    function walk(node, prefix, out) {
      if (!node.files) return;
      for (const name of Object.keys(node.files)) {
        const entry = node.files[name];
        const p = prefix ? prefix + '/' + name : name;
        if (entry.files) walk(entry, p, out);
        else if (entry.unpacked) out.push(p);
      }
    }
    const out = [];
    walk(header, '', out);
    out.sort();
    process.stdout.write(out.join('\n'));
    if (out.length) process.stdout.write('\n');
  " "$target" )
}

# Repacks $1 (extracted asar tree) into $2 (new asar path), preserving
# whichever files were unpacked:true in the ORIGINAL asar ($3, one path per
# line, sorted). Native modules cannot be dlopen'd from inside an asar, so
# if this set is lost on repack Electron's main process crashes before any
# window opens: this is the exact bug that bricked the app on modern Claude
# Desktop (1.17377.2), which ships 9 unpacked files where the
# previously-tested 1.8555.2 shipped none.
#
# Primary strategy: an exact brace-glob of the original files' BASENAMES,
# e.g. "{foo.node,spawn-helper}". @electron/asar's unpack matcher
# (lib/asar.js, shouldUnpackPath) runs minimatch with {matchBase: true}
# against each file's basename, not its full relative path: a brace-glob
# of full paths silently matches nothing (verified empirically: 0/9 files
# reproduced). Basenames are therefore the correct "exact" primary, and in
# practice unpacked native files have distinctive basenames so this is not
# a meaningfully weaker match than full paths would be.
#
# Fallback: a generic pattern covering every unpacked file *type* we've
# observed in this app (native modules, dylibs, node-pty's extensionless
# spawn-helper). Used only if the exact-basename pack doesn't reproduce the
# original set. Either way, the caller still runs its own post-pack
# equality check: this function's belief that it succeeded is not the gate.
asar_pack_preserving_unpacked() {
  local extract_dir="$1" out_asar="$2" orig_list_file="$3"
  local basenames_file pattern try_list_file

  if [ -s "$orig_list_file" ]; then
    basenames_file="$(mktemp)"
    while IFS= read -r _p; do
      [ -n "$_p" ] || continue
      basename "$_p"
    done < "$orig_list_file" | sort -u > "$basenames_file"

    step "Repacking with exact unpacked-basename list ($(wc -l < "$basenames_file" | tr -d ' ') names)..."
    pattern="{$(paste -s -d, "$basenames_file")}"
    rm -f "$basenames_file"
    ( cd "$TOOL_DIR" && "$NODE_BIN" -e "
      const asar = require('@electron/asar');
      asar.createPackageWithOptions(process.argv[1], process.argv[2], { unpack: process.argv[3] })
        .then(() => process.exit(0))
        .catch((e) => { console.error(String(e && e.stack || e)); process.exit(1); });
    " "$extract_dir" "$out_asar" "$pattern" ) || die "asar pack (exact-basename unpack) failed."

    try_list_file="$(mktemp)"
    asar_unpacked_list "$out_asar" > "$try_list_file"
    if diff -q "$orig_list_file" "$try_list_file" >/dev/null 2>&1; then
      rm -f "$try_list_file"
      return 0
    fi
    rm -f "$try_list_file"
    c_yellow "Exact unpacked-basename match failed to reproduce the original set; falling back to pattern match."
  fi

  step "Repacking with generic unpacked pattern (**/*.node, **/*.dylib, **/spawn-helper)..."
  ( cd "$TOOL_DIR" && "$NODE_BIN" -e "
    const asar = require('@electron/asar');
    asar.createPackageWithOptions(process.argv[1], process.argv[2], { unpack: '{**/*.node,**/*.dylib,**/spawn-helper}' })
      .then(() => process.exit(0))
      .catch((e) => { console.error(String(e && e.stack || e)); process.exit(1); });
  " "$extract_dir" "$out_asar" ) || die "asar pack (fallback pattern unpack) failed."
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

# Restricted entitlement keys that AMFI only allows under a genuine Apple
# team signature. An ad-hoc signature (sign identity "-") can never carry
# these: if they're present, macOS 26's stricter AMFI refuses to launch the
# binary at all ("adhoc signed but contains restricted entitlements"), even
# though `codesign --verify` reports the signature itself as structurally
# valid. They must be stripped before any ad-hoc re-sign.
RESTRICTED_ENTITLEMENT_KEYS="com.apple.application-identifier com.apple.developer.team-identifier keychain-access-groups"

# Dropping the restricted keys above means the ad-hoc-signed outer executable
# can no longer satisfy Library Validation when it loads the still
# genuinely-signed nested Electron Framework (different/no team ID). Adding
# this key (instead of `--deep` ad-hoc-signing every nested helper, which
# reintroduces the keychain-prompt regression) tells the kernel to skip that
# check for this process, so the outer binary can still load Electron's
# nested, genuinely-signed frameworks.
DISABLE_LIB_VALIDATION_KEY="com.apple.security.cs.disable-library-validation"

# Builds an entitlements plist suitable for our ad-hoc re-sign, at $1
# (destination path). Derives it from the TARGET app's own current
# entitlements so it self-adapts if Anthropic adds/removes entitlements in a
# future release, rather than a hardcoded snapshot going stale.
#
# Strategy: dump $APP's live entitlements, delete the restricted keys, add
# disable-library-validation. If the dump is empty (unsigned app, or a
# scratch target with no signature at all), fall back to a minimal hardcoded
# plist with exactly the non-restricted keys this app is known to ship
# (com.apple.security.cs.allow-jit plus the device/personal-information/
# virtualization entitlements) so hardware access (mic, camera, etc.) still
# works after patching.
build_adhoc_entitlements() {
  local out="$1"
  local dump
  dump="$(mktemp)"

  # codesign's `--entitlements <path>` form writes a real plist file
  # directly; older/other codesign builds only support `--entitlements :-`
  # (dash form) which streams to stdout. Try the direct-file form first,
  # fall back to the stdout form if it produced nothing.
  codesign -d --entitlements "$dump" --xml "$APP" >/dev/null 2>&1 || true
  if [ ! -s "$dump" ]; then
    codesign -d --entitlements :- --xml "$APP" > "$dump" 2>/dev/null || true
  fi

  if [ -s "$dump" ]; then
    cp "$dump" "$out"
    local key
    for key in $RESTRICTED_ENTITLEMENT_KEYS; do
      /usr/libexec/PlistBuddy -c "Delete :$key" "$out" >/dev/null 2>&1 || true
    done
    if ! /usr/libexec/PlistBuddy -c "Print :$DISABLE_LIB_VALIDATION_KEY" "$out" >/dev/null 2>&1; then
      /usr/libexec/PlistBuddy -c "Add :$DISABLE_LIB_VALIDATION_KEY bool true" "$out" >/dev/null 2>&1
    else
      /usr/libexec/PlistBuddy -c "Set :$DISABLE_LIB_VALIDATION_KEY true" "$out" >/dev/null 2>&1
    fi
  else
    c_yellow "Could not read existing entitlements from $APP (unsigned target?); using minimal fallback set."
    cat > "$out" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTD/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.cs.allow-jit</key>
	<true/>
	<key>com.apple.security.device.audio-input</key>
	<true/>
	<key>com.apple.security.device.bluetooth</key>
	<true/>
	<key>com.apple.security.device.camera</key>
	<true/>
	<key>com.apple.security.device.print</key>
	<true/>
	<key>com.apple.security.device.usb</key>
	<true/>
	<key>com.apple.security.personal-information.location</key>
	<true/>
	<key>com.apple.security.personal-information.photos-library</key>
	<true/>
	<key>com.apple.security.virtualization</key>
	<true/>
	<key>$DISABLE_LIB_VALIDATION_KEY</key>
	<true/>
</dict>
</plist>
PLIST
  fi
  rm -f "$dump"
}

# Asserts that a just-signed $APP's entitlements are launch-safe: none of the
# restricted keys survived (AMFI would reject them on an ad-hoc signature),
# and disable-library-validation is present and true (needed so the ad-hoc
# outer executable can still load Electron's genuinely-signed nested
# framework). This is a static proxy for "will AMFI actually let this
# launch": codesign --verify alone does not catch a restricted-entitlement
# rejection, since the signature itself is structurally valid, it's AMFI's
# separate policy check that refuses it at launch.
assert_launch_safe_entitlements() {
  local dump
  dump="$(mktemp)"
  codesign -d --entitlements "$dump" --xml "$APP" >/dev/null 2>&1 || true
  if [ ! -s "$dump" ]; then
    codesign -d --entitlements :- --xml "$APP" > "$dump" 2>/dev/null || true
  fi

  if [ ! -s "$dump" ]; then
    rm -f "$dump"
    die "Post-validation failed: could not read back signed entitlements from $APP."
  fi

  local key
  for key in $RESTRICTED_ENTITLEMENT_KEYS; do
    if /usr/libexec/PlistBuddy -c "Print :$key" "$dump" >/dev/null 2>&1; then
      rm -f "$dump"
      die "Post-validation failed: restricted entitlement '$key' is still present on the ad-hoc-signed bundle. AMFI will refuse to launch it. Rolling back."
    fi
  done

  local dlv_value
  dlv_value="$(/usr/libexec/PlistBuddy -c "Print :$DISABLE_LIB_VALIDATION_KEY" "$dump" 2>/dev/null || echo "")"
  rm -f "$dump"
  if [ "$dlv_value" != "true" ]; then
    die "Post-validation failed: $DISABLE_LIB_VALIDATION_KEY is not set to true on the signed bundle. The ad-hoc binary would fail Library Validation when loading Electron's nested framework. Rolling back."
  fi
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
  local verify_launch="no"
  local arg
  for arg in "$@"; do
    case "$arg" in
      --force) force="yes" ;;
      --verify-launch) verify_launch="yes" ;;
    esac
  done

  # --verify-launch spawns the freshly-patched app to confirm it actually
  # stays alive. This is only safe against a throwaway --app target: it must
  # never auto-run (or be allowed to run) against the real, already-running
  # Claude Desktop install.
  if [ "$verify_launch" = "yes" ] && [ "$APP" = "/Applications/Claude.app" ]; then
    die "--verify-launch refuses to run against the real /Applications/Claude.app. Use --app <scratch-copy> to smoke-test a launch."
  fi

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

  # Preflight gate, before touching anything. If Claude's internal layout no
  # longer has the entry point we inject into, we must find out now: not
  # after the original asar has already been overwritten.
  step "Preflight: checking asar layout..."
  if ! asar_run list "$ASAR" 2>/dev/null | grep -q '/\.vite/build/index\.pre\.js$'; then
    die "Entry point .vite/build/index.pre.js not found in $ASAR. Claude's internal app layout has changed; nothing was modified. Please check for a claude-deck update."
  fi

  quit_claude
  _snapshot_backup_if_needed

  # From here on, any failure must leave the installed app exactly as it was
  # (or better: reverted to the known-good backup), never half-patched.
  # ROLLBACK_ARMED is checked by _patch_rollback so a trap firing before the
  # backup exists (or after we've already succeeded) is a no-op.
  ROLLBACK_ARMED="yes"
  trap _patch_rollback EXIT INT TERM

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

  step "Recording which files are unpacked in the ORIGINAL asar..."
  ORIG_UNPACKED_LIST="$(mktemp)"
  asar_unpacked_list "$ASAR" > "$ORIG_UNPACKED_LIST"
  c_dim "  $(wc -l < "$ORIG_UNPACKED_LIST" | tr -d ' ') unpacked file(s) in the original asar."

  # asar.extractAll pulls unpacked files' CONTENT from the sibling
  # Resources/app.asar.unpacked dir (verified: byte-for-byte correct), but it
  # does NOT carry over their executable bit: every extracted file lands as
  # plain 644. node-pty's spawn-helper and the @ant native .node binaries are
  # execve'd/dlopen'd as Mach-O executables (mode 755 in the live install);
  # losing +x here would silently break the pty/native bridge even though
  # the app would still launch. Copy each unpacked file's real mode from the
  # currently-installed app.asar.unpacked onto its extracted counterpart
  # before we repack.
  step "Restoring executable bits on unpacked files..."
  if [ -d "$RES/app.asar.unpacked" ] && [ -s "$ORIG_UNPACKED_LIST" ]; then
    while IFS= read -r _rel; do
      [ -n "$_rel" ] || continue
      _src="$RES/app.asar.unpacked/$_rel"
      _dst="$WORK/$_rel"
      if [ -f "$_src" ] && [ -f "$_dst" ]; then
        _mode="$(stat -f "%Lp" "$_src" 2>/dev/null || echo "")"
        [ -n "$_mode" ] && chmod "$_mode" "$_dst" 2>/dev/null || true
      fi
    done < "$ORIG_UNPACKED_LIST"
  fi

  step "Repacking asar (preserving unpacked native modules)..."
  # Native *.node modules, dylibs, and node-pty's spawn-helper cannot be
  # dlopen'd/exec'd from inside an asar archive. A plain "asar pack" with no
  # --unpack rule marks everything packed, so Electron's main process throws
  # on launch and Claude never opens at all: this is the exact bug that
  # bricked the app before this fix existed. See asar_pack_preserving_unpacked
  # above for the primary (exact-basename) vs fallback (generic pattern)
  # strategy.
  TMP_ASAR="$(mktemp -t claude-deck-asar-XXXXXX).asar"
  asar_pack_preserving_unpacked "$WORK" "$TMP_ASAR" "$ORIG_UNPACKED_LIST"

  step "Verifying the repacked asar's unpacked set matches the original..."
  NEW_UNPACKED_LIST="$(mktemp)"
  asar_unpacked_list "$TMP_ASAR" > "$NEW_UNPACKED_LIST"
  if ! diff -q "$ORIG_UNPACKED_LIST" "$NEW_UNPACKED_LIST" >/dev/null 2>&1; then
    c_red "Original unpacked set:"
    cat "$ORIG_UNPACKED_LIST" >&2
    c_red "New unpacked set:"
    cat "$NEW_UNPACKED_LIST" >&2
    die "Repacked asar's unpacked file set does not match the original. Refusing to install (rollback will restore the app)."
  fi
  rm -f "$NEW_UNPACKED_LIST"

  step "Installing new asar + app.asar.unpacked..."
  $SUDO mv "$TMP_ASAR" "$ASAR"
  # createPackageWithOptions writes its own sibling .unpacked dir next to the
  # asar it just produced (same convention Electron itself uses). Install it
  # wholesale so the native files it contains are the ones actually alongside
  # the new asar. If there were no unpacked entries at all, nothing was
  # generated: leave whatever was already in Resources alone.
  if [ -d "$TMP_ASAR.unpacked" ]; then
    if [ -d "$RES/app.asar.unpacked" ]; then
      $SUDO rm -rf "$RES/app.asar.unpacked"
    fi
    $SUDO mv "$TMP_ASAR.unpacked" "$RES/app.asar.unpacked"
  fi

  step "Updating ElectronAsarIntegrity hash in Info.plist..."
  NEWHASH=$(asar_header_hash)
  $SUDO /usr/libexec/PlistBuddy -c "Set :ElectronAsarIntegrity:Resources/app.asar:hash $NEWHASH" "$PLIST"
  c_dim "  new header hash: $NEWHASH"

  step "Ad-hoc re-signing the bundle..."
  # Do NOT add --deep. --deep re-signs nested helpers (renderer/GPU helpers)
  # ad-hoc too, which invalidates their keychain ACLs and causes a keychain
  # prompt on every single Claude launch afterward. Sign the outer bundle
  # only, preserving identifier/flags/runtime (hardened runtime stays on) but
  # NOT entitlements: an ad-hoc signature can never carry Apple's restricted
  # entitlements (application-identifier, team-identifier,
  # keychain-access-groups), and macOS 26's stricter AMFI refuses to launch a
  # binary that has them anyway ("adhoc signed but contains restricted
  # entitlements"). build_adhoc_entitlements derives a safe replacement set
  # from the app's own current entitlements: see its comment for details.
  ENT_PLIST="$(mktemp)"
  build_adhoc_entitlements "$ENT_PLIST"
  $SUDO codesign --force --sign - --preserve-metadata=identifier,flags,runtime --entitlements "$ENT_PLIST" "$APP"
  $SUDO xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

  rm -rf "$(dirname "$WORK")"

  step "Post-validation..."
  local installed_hash plist_recorded_hash
  installed_hash="$(asar_header_hash)"
  plist_recorded_hash="$(plist_hash)"
  [ "$installed_hash" = "$plist_recorded_hash" ] \
    || die "Post-validation failed: installed asar header hash ($installed_hash) does not match Info.plist ($plist_recorded_hash)."
  is_patched \
    || die "Post-validation failed: marker $MARKER not found in installed asar."
  FINAL_UNPACKED_LIST="$(mktemp)"
  asar_unpacked_list "$ASAR" > "$FINAL_UNPACKED_LIST"
  diff -q "$ORIG_UNPACKED_LIST" "$FINAL_UNPACKED_LIST" >/dev/null 2>&1 \
    || die "Post-validation failed: installed asar's unpacked set no longer matches the original."
  rm -f "$FINAL_UNPACKED_LIST" "$ORIG_UNPACKED_LIST" "$ENT_PLIST"
  codesign --verify "$APP" >/dev/null 2>&1 \
    || die "Post-validation failed: codesign --verify rejected the re-signed bundle."
  # codesign --verify only checks signature structure; it does NOT catch a
  # restricted-entitlement rejection (AMFI's separate, stricter policy check
  # applies only at actual launch). Assert the signed entitlements are
  # launch-safe so this gate would have caught the exact failure mode that
  # slipped past --verify before.
  assert_launch_safe_entitlements

  if [ "$verify_launch" = "yes" ]; then
    _verify_launch_stays_alive
  fi

  # Everything checked out: disarm the rollback trap before printing success.
  # Restore the top-level chown-state-dir-back-to-owner trap rather than
  # clearing traps outright, so a sudo/root invocation still hands
  # $STATE_DIR back to the real user on exit.
  ROLLBACK_ARMED="no"
  trap _chown_state_on_exit EXIT
  trap - INT TERM

  c_green "✓ Patched. Claude now understands --profile=NAME."
  c_dim   "Try: $0 open work   (launches a second, independent instance)"
  c_dim   "Revert anytime with: $0 revert"
}

# Spawns the just-patched $APP with a throwaway, isolated userData profile
# and confirms the process is still alive 8 seconds later. This is the one
# check that would have caught the actual AMFI-rejection failure mode
# end-to-end (static entitlement assertions are a proxy; this is the real
# thing). Guarded by the caller to only ever run for a non-real --app target.
_verify_launch_stays_alive() {
  local bin scratch_profile pid
  bin="$APP/Contents/MacOS/Claude"
  [ -x "$bin" ] || die "--verify-launch: executable not found at $bin"

  scratch_profile="$(mktemp -d)/claude-deck-verify-launch"
  step "Launching $bin --profile=verifylaunch for an 8s liveness check..."
  ( "$bin" --profile=verifylaunch --user-data-dir="$scratch_profile" >/dev/null 2>&1 & echo $! > "$scratch_profile.pid" ) &
  wait
  pid="$(cat "$scratch_profile.pid" 2>/dev/null || echo "")"
  rm -f "$scratch_profile.pid"

  sleep 8

  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    c_green "  Process $pid is still alive after 8s: launch verified."
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -9 "$pid" 2>/dev/null || true
  else
    die "--verify-launch failed: the patched app did not stay running for 8s (likely rejected at launch, e.g. by AMFI). Rolling back."
  fi
  rm -rf "$scratch_profile" 2>/dev/null || true
}

# Runs on EXIT/INT/TERM for the whole duration cmd_patch is mutating the
# installed app. If we get here with ROLLBACK_ARMED=yes, something failed
# (die() calls exit 1, an unhandled command error trips `set -e`, or the user
# hit Ctrl-C) partway through, so we restore the app to the pristine backup
# rather than leave it in a half-patched, possibly-unlaunchable state.
_patch_rollback() {
  local rc=$?
  trap - EXIT INT TERM
  if [ "${ROLLBACK_ARMED:-no}" != "yes" ]; then
    _chown_state_on_exit
    exit "$rc"
  fi
  c_yellow "Patch failed partway through: restoring the app from backup..."
  if [ -f "$BACKUP_ASAR" ]; then
    $SUDO cp "$BACKUP_ASAR" "$ASAR" 2>/dev/null || true
  fi
  if [ -d "$BACKUP_UNPACKED" ]; then
    if [ -d "$RES/app.asar.unpacked" ]; then
      $SUDO rm -rf "$RES/app.asar.unpacked" 2>/dev/null || true
    fi
    $SUDO cp -R "$BACKUP_UNPACKED" "$RES/app.asar.unpacked" 2>/dev/null || true
  elif [ -d "$RES/app.asar.unpacked" ]; then
    $SUDO rm -rf "$RES/app.asar.unpacked" 2>/dev/null || true
  fi
  local restored_hash=""
  if [ -f "$BACKUP_HASH" ] && [ -s "$BACKUP_HASH" ]; then
    restored_hash="$(cat "$BACKUP_HASH")"
    $SUDO /usr/libexec/PlistBuddy -c "Set :ElectronAsarIntegrity:Resources/app.asar:hash $restored_hash" "$PLIST" 2>/dev/null || true
  fi
  ROLLBACK_ENT_PLIST="$(mktemp)"
  build_adhoc_entitlements "$ROLLBACK_ENT_PLIST" 2>/dev/null || true
  $SUDO codesign --force --sign - --preserve-metadata=identifier,flags,runtime --entitlements "$ROLLBACK_ENT_PLIST" "$APP" 2>/dev/null || true
  rm -f "$ROLLBACK_ENT_PLIST"
  $SUDO xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

  # PlistBuddy can exit 0 while silently failing to write (e.g. a read-only
  # Info.plist), which is exactly the kind of failure this trap exists to
  # catch. Verify the restore actually took before declaring victory; if it
  # didn't, say so honestly instead of printing a false all-clear.
  local now_hash
  now_hash="$(plist_hash 2>/dev/null || echo "")"
  if [ -n "$restored_hash" ] && [ "$now_hash" != "$restored_hash" ]; then
    c_red "Rollback could not restore Info.plist's ElectronAsarIntegrity hash"
    c_red "(wanted $restored_hash, found $now_hash). The asar file itself was"
    c_red "restored, but the plist may still be wrong: check file permissions"
    c_red "on $PLIST and re-run '$0 revert' by hand."
  else
    c_yellow "App restored to its pre-patch state (untouched-equivalent). Nothing is broken."
  fi
  _chown_state_on_exit
  exit "$rc"
}

# Snapshot originals into $BACKUP_DIR (only if we don't have a clean backup
# yet, or the installed Claude version has moved on since the last backup,
# in which case the old backup is stale and we refresh it). Also backs up
# app.asar.unpacked when present, so a later revert can restore the exact
# native-module files that shipped with that pristine asar, not whatever
# claude-deck most recently wrote there.
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
      $SUDO cp "$ASAR" "$BACKUP_ASAR"
      _backup_unpacked_dir
      plist_hash > "$BACKUP_HASH"
      claude_version > "$BACKUP_VERSION"
    else
      c_dim "Reusing existing backup at $BACKUP_ASAR"
    fi
    return
  fi
  step "Saving pristine backup → $BACKUP_ASAR"
  $SUDO cp "$ASAR" "$BACKUP_ASAR"
  _backup_unpacked_dir
  plist_hash > "$BACKUP_HASH"
  claude_version > "$BACKUP_VERSION"
}

# Copies the currently-installed Resources/app.asar.unpacked (if any) into
# the backup dir, and removes any stale backup copy if the current install
# has none (e.g. a hypothetical future Claude build ships no native modules).
_backup_unpacked_dir() {
  if [ -d "$RES/app.asar.unpacked" ]; then
    if [ -d "$BACKUP_UNPACKED" ]; then
      $SUDO rm -rf "$BACKUP_UNPACKED"
    fi
    $SUDO cp -R "$RES/app.asar.unpacked" "$BACKUP_UNPACKED"
  else
    if [ -d "$BACKUP_UNPACKED" ]; then
      $SUDO rm -rf "$BACKUP_UNPACKED"
    fi
  fi
}

# Writes the injected main-process module. Kept in its own function (instead
# of inline in cmd_patch) purely so cmd_watchdog_run can reuse it verbatim.
_write_injector() {
  local out="$1"
  cat > "$out" <<'JS'
// Injected by claude-deck: adds --profile=NAME support so multiple
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

// Directory links: junctions on Windows (they work without admin rights or
// Developer Mode, unlike real directory symlinks), plain symlinks elsewhere.
function linkDir(target, linkPath) {
  if (process.platform === 'win32') fs.symlinkSync(target, linkPath, 'junction');
  else fs.symlinkSync(target, linkPath);
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

// 1b) Share one Claude Code session index across every profile. Claude
//     Desktop keeps its Claude Code session list per-userData at
//     <userData>/claude-code-sessions/<account-uuid>/<org-uuid>/local_*.json.
//     Transcripts live in the shared ~/.claude/projects, but the app only
//     lists sessions it finds in this per-profile index, so a second
//     profile of the same account shows "no Code sessions" even though the
//     transcripts are right there. Fix: symlink each profile's index dir at
//     the default app's index dir, migrating any existing per-profile
//     sessions in first so nothing is lost. Silent no-op on any failure:
//     this must never block app launch, and never deletes data.
safeRun(function () {
  if (!PROFILE) return;
  var shared = path.join(app.getPath('appData'), 'Claude', 'claude-code-sessions');
  // Recompute the profile dir here: 'base' in the userData block above is
  // function-scoped to its own safeRun callback and is NOT visible here.
  // Referencing it threw a silent ReferenceError and made this whole block
  // a no-op (real bug, caught in production on 2026-07-06).
  var mine = path.join(app.getPath('appData'), 'Claude Profiles', PROFILE, 'claude-code-sessions');

  safeRun(function () { fs.mkdirSync(shared, { recursive: true }); });

  var mineStat = null;
  safeRun(function () { mineStat = fs.lstatSync(mine); });

  if (mineStat && mineStat.isSymbolicLink()) {
    return; // already linked, nothing to do
  }

  if (mineStat && mineStat.isDirectory()) {
    // Existing per-profile index: migrate its contents into the shared dir
    // additively (never overwrite a file already in shared), then keep the
    // original around as a timestamped backup instead of deleting it.
    safeRun(function () {
      if (typeof fs.cpSync === 'function') {
        try {
          fs.cpSync(mine, shared, { recursive: true, force: false, errorOnExist: false });
        } catch (e) {
          copyRecursiveSkipExisting(mine, shared);
        }
      } else {
        copyRecursiveSkipExisting(mine, shared);
      }
    });
    safeRun(function () {
      fs.renameSync(mine, mine + '.migrated-' + Date.now());
    });
    safeRun(function () {
      linkDir(shared, mine);
    });
    return;
  }

  if (!mineStat) {
    // Nothing at all yet for this profile: just point it at the shared dir.
    safeRun(function () { linkDir(shared, mine); });
  }
});

// Manual recursive copy that skips any file/dir already present at the
// destination. Used only as a fallback when fs.cpSync is unavailable or
// throws, so the shared-index migration above still completes.
function copyRecursiveSkipExisting(srcDir, destDir) {
  safeRun(function () {
    fs.mkdirSync(destDir, { recursive: true });
    var entries = fs.readdirSync(srcDir, { withFileTypes: true });
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i];
      var srcPath = path.join(srcDir, entry.name);
      var destPath = path.join(destDir, entry.name);
      safeRun(function () {
        if (entry.isDirectory()) {
          copyRecursiveSkipExisting(srcPath, destPath);
        } else if (entry.isFile()) {
          if (!fs.existsSync(destPath)) {
            fs.copyFileSync(srcPath, destPath);
          }
        }
      });
    }
  });
}

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
  $SUDO cp "$BACKUP_ASAR" "$ASAR"

  step "Restoring original app.asar.unpacked..."
  if [ -d "$BACKUP_UNPACKED" ]; then
    if [ -d "$RES/app.asar.unpacked" ]; then
      $SUDO rm -rf "$RES/app.asar.unpacked"
    fi
    $SUDO cp -R "$BACKUP_UNPACKED" "$RES/app.asar.unpacked"
  elif [ -d "$RES/app.asar.unpacked" ]; then
    # The pristine backup had no unpacked dir (nothing was unpacked in that
    # build), but the patched install has one: remove it so revert is exact.
    $SUDO rm -rf "$RES/app.asar.unpacked"
  fi

  if [ -f "$BACKUP_HASH" ] && [ -s "$BACKUP_HASH" ]; then
    OLDHASH=$(cat "$BACKUP_HASH")
    step "Restoring ElectronAsarIntegrity hash → $OLDHASH"
    $SUDO /usr/libexec/PlistBuddy -c "Set :ElectronAsarIntegrity:Resources/app.asar:hash $OLDHASH" "$PLIST"
  else
    c_yellow "No saved Info.plist hash; recomputing from restored asar..."
    OLDHASH=$(asar_header_hash)
    $SUDO /usr/libexec/PlistBuddy -c "Set :ElectronAsarIntegrity:Resources/app.asar:hash $OLDHASH" "$PLIST"
  fi

  step "Ad-hoc re-signing to keep Gatekeeper happy..."
  # Same --deep caveat as cmd_patch: never add it here either. The restored
  # asar's ORIGINAL signature was Anthropic-genuine, but we can only ever
  # produce an ad-hoc one, so the same entitlement-stripping applies here:
  # restricted keys dropped, disable-library-validation added. This means
  # revert makes the app content-pristine but still ad-hoc-signed, not a
  # true return to Anthropic's genuine signature (see README).
  REVERT_ENT_PLIST="$(mktemp)"
  build_adhoc_entitlements "$REVERT_ENT_PLIST"
  $SUDO codesign --force --sign - --preserve-metadata=identifier,flags,runtime --entitlements "$REVERT_ENT_PLIST" "$APP"
  rm -f "$REVERT_ENT_PLIST"
  $SUDO xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

  step "Verifying signature is launch-safe..."
  codesign --verify "$APP" >/dev/null 2>&1 \
    || die "Post-revert validation failed: codesign --verify rejected the re-signed bundle."
  assert_launch_safe_entitlements

  c_green "✓ Reverted. Claude is back to its original content, ad-hoc signed."
  c_dim   "Backup retained at $BACKUP_ASAR. Delete $STATE_DIR if you don't need it."
  c_dim   "Note: this is content-pristine but not Anthropic-signed. For a fully"
  c_dim   "genuine signature (e.g. hardware-key/passkey login), reinstall Claude."
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

# Shell twin of the Claude Code session-index symlink that the injected
# claude-deck.js sets up inside the app's main process (see step 4 in
# CLAUDE.md). This exists so linking a profile's session index into the
# shared dir no longer depends on the installed app actually carrying a
# fresh copy of that injected code: a stale patch, a scoping bug in an old
# injected version, or an un-repatched app after a Claude update all used to
# mean "no Code sessions show up." Calling this from the shell, on every
# open/dash, makes the fix self-healing regardless of what's inside the asar.
#
# Never destructive: a real directory found at the link path is migrated
# (additively) and kept as a timestamped backup, never deleted. Every step is
# tolerant of odd pre-existing state (missing dirs, a live profile, etc.)
# rather than tripping `set -e`.
ensure_profile_index_link() {
  local name="$1"
  local profile_dir link shared
  profile_dir="$PROFILES_USERDATA_ROOT/$name"
  link="$profile_dir/claude-code-sessions"
  shared="$SHARED_SESSIONS_DIR"

  mkdir -p "$shared" 2>/dev/null || true
  mkdir -p "$profile_dir" 2>/dev/null || true

  if [ -L "$link" ]; then
    return 0
  fi

  if _profile_is_running "$name" 2>/dev/null; then
    c_dim "Profile '$name' is running: leaving its session index alone for now."
    return 1
  fi

  if [ -d "$link" ]; then
    step "Migrating existing session index for '$name' into the shared index..."
    local copied=0
    local acct_dir org_dir dest_acct_dir dest_org_dir f base
    for acct_dir in "$link"/*/; do
      [ -d "$acct_dir" ] || continue
      acct_dir="${acct_dir%/}"
      for org_dir in "$acct_dir"/*/; do
        [ -d "$org_dir" ] || continue
        org_dir="${org_dir%/}"
        dest_acct_dir="$shared/$(basename "$acct_dir")"
        dest_org_dir="$dest_acct_dir/$(basename "$org_dir")"
        mkdir -p "$dest_org_dir" 2>/dev/null || true
        for f in "$org_dir"/local_*.json; do
          [ -e "$f" ] || continue
          base="$(basename "$f")"
          if [ ! -e "$dest_org_dir/$base" ]; then
            cp "$f" "$dest_org_dir/$base" 2>/dev/null && copied=$((copied + 1)) || true
          fi
        done
      done
    done
    c_dim "  merged $copied session file(s) into $shared"
    mv "$link" "$link.migrated-$(date +%s)" 2>/dev/null || true
    ln -s "$shared" "$link" 2>/dev/null || true
    return 0
  fi

  # Missing (or any other non-symlink, non-dir state): just point it at the
  # shared dir.
  ln -s "$shared" "$link" 2>/dev/null || true
  return 0
}

cmd_open() {
  local name="${1:-}"

  if [ -z "$name" ] || [ "$name" = "default" ]; then
    if _profile_is_running "default"; then
      # Default already running: just bring it forward. Never use -n on a
      # running default, a second instance on the same userData dir would
      # corrupt its LevelDB/session store.
      step "Focusing Claude (default profile)..."
      osascript -e 'tell application "Claude" to activate' 2>/dev/null || true
    else
      # Default NOT running: we must force a brand-new instance with -n.
      # Plain "open -a Claude" would just activate whatever profiled instance
      # is already running (macOS treats them all as the "Claude" app), so
      # the default profile would never actually launch. -n is safe here
      # precisely because default is not running: no two writers on one dir.
      step "Opening Claude (default profile)..."
      open -n -a "Claude"
    fi
    return
  fi

  _validate_profile_name "$name"
  ensure_profile_index_link "$name" || true

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

# Prints every named profile dir under $PROFILES_USERDATA_ROOT, one per line.
# The "default" (no --profile) instance is never included: it has no dir
# under Claude Profiles/ at all, and index-linking never applies to it.
_list_named_profiles() {
  [ -d "$PROFILES_USERDATA_ROOT" ] || return 0
  find "$PROFILES_USERDATA_ROOT" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | while IFS= read -r d; do
    basename "$d"
  done
}

# Repairs the session-index link for every known named profile. When $1 is
# "quiet", only migration output survives (used by cmd_dash, which shouldn't
# spam routine "already-linked" lines on every launch); otherwise prints one
# line per profile with its outcome (used by cmd_doctor).
_repair_all_profiles() {
  local verbosity="${1:-verbose}"
  local names
  names="$(_list_named_profiles)"
  if [ -z "$names" ]; then
    [ "$verbosity" = "quiet" ] || c_dim "No named profiles found under: $PROFILES_USERDATA_ROOT"
    return 0
  fi
  printf '%s\n' "$names" | while IFS= read -r name; do
    [ -n "$name" ] || continue
    local link="$PROFILES_USERDATA_ROOT/$name/claude-code-sessions"
    local was_symlink="no"
    [ -L "$link" ] && was_symlink="yes"
    local was_dir="no"
    [ -d "$link" ] && [ ! -L "$link" ] && was_dir="yes"

    if [ "$was_symlink" = "yes" ]; then
      [ "$verbosity" = "quiet" ] || printf "  %-20s already-linked\n" "$name"
      continue
    fi

    if _profile_is_running "$name" 2>/dev/null; then
      printf "  %-20s skipped-running\n" "$name"
      continue
    fi

    if [ "$was_dir" = "yes" ]; then
      local before_count after_count
      before_count=$(find "$SHARED_SESSIONS_DIR" -name 'local_*.json' -type f 2>/dev/null | wc -l | tr -d ' ')
      ensure_profile_index_link "$name" >/dev/null 2>&1 || true
      after_count=$(find "$SHARED_SESSIONS_DIR" -name 'local_*.json' -type f 2>/dev/null | wc -l | tr -d ' ')
      printf "  %-20s migrated-and-linked (files now in shared index: %s, +%s new)\n" \
        "$name" "$after_count" "$((after_count - before_count))"
      continue
    fi

    ensure_profile_index_link "$name" >/dev/null 2>&1 || true
    [ "$verbosity" = "quiet" ] || printf "  %-20s linked\n" "$name"
  done
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
  _repair_all_profiles quiet
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
# doctor
# ---------------------------------------------------------------------------

# Best-effort: extracts just claude-deck.js from the installed asar into a
# temp file and checks whether it still contains the old buggy reference
# (`join(base, 'claude-code-sessions')`, where `base` was out of scope: see
# CLAUDE.md step 4's "real bug, caught in production" note). Silent no-op
# (prints nothing, never fails doctor) if node/the asar tool aren't
# available or the app/asar can't be read: this check is a bonus, not load
# bearing, since ensure_profile_index_link no longer depends on it.
_doctor_check_injection_freshness() {
  [ -f "$ASAR" ] || return 0
  ( ensure_node && ensure_asar_tool ) >/dev/null 2>&1 || return 0

  local extract_dir
  extract_dir="$(mktemp -d)" || return 0
  # asar's `extract-file` writes to basename(filename) in the CURRENT working
  # directory (not an arbitrary destination), so cd into our scratch dir
  # first rather than relying on asar_run's own cd into $TOOL_DIR.
  if ! ( cd "$extract_dir" && "$NODE_BIN" "$TOOL_DIR/node_modules/@electron/asar/bin/asar.js" extract-file "$ASAR" "$MARKER" ) >/dev/null 2>&1; then
    rm -rf "$extract_dir"
    return 0
  fi

  if [ -f "$extract_dir/$MARKER" ] && grep -q "join(base, 'claude-code-sessions')" "$extract_dir/$MARKER" 2>/dev/null; then
    c_yellow "Warning: the installed app carries an old injection with a known scoping bug"
    c_yellow "(session-index linking silently failed). Recommend: sudo ./claude-deck.sh patch --force"
  fi
  rm -rf "$extract_dir"
}

cmd_doctor() {
  step "Repairing session-index links for every named profile..."
  _repair_all_profiles verbose

  step "Checking installed patch freshness..."
  _doctor_check_injection_freshness

  # Warn when the installed copy (what the 'claude-deck' alias runs) has
  # fallen behind the checkout it was installed from (classic after a
  # git pull without re-running install).
  if [ -f "$STATE_DIR/source-path" ]; then
    local _src
    _src="$(cat "$STATE_DIR/source-path" 2>/dev/null)"
    if [ -n "$_src" ] && [ -f "$_src" ] && [ -f "$CANONICAL_PATH" ] \
       && [ "$_src" != "$CANONICAL_PATH" ] && ! cmp -s "$_src" "$CANONICAL_PATH"; then
      c_yellow "Installed copy differs from your checkout at:"
      c_yellow "  $_src"
      c_yellow "Run '$_src install' to refresh, then 'claude-deck patch --force'."
    fi
  fi

  local sync_script="$HOME/.claude/scripts/claude-sync.sh"
  if [ -f "$sync_script" ]; then
    if pgrep -x "Claude" >/dev/null 2>&1; then
      c_dim "Claude is running: cross-account sync will happen automatically on next app quit (claude-sync watcher)."
    else
      step "Running claude-sync..."
      bash "$sync_script" || c_yellow "claude-sync exited non-zero; see output above."
    fi
  fi

  c_green "✓ Doctor pass complete."
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
    # Remember where we were installed from, so doctor can warn when the
    # installed copy falls behind the checkout after a git pull.
    printf '%s\n' "$SOURCE_PATH" > "$STATE_DIR/source-path" 2>/dev/null || true
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
  $0 patch [--force] [--verify-launch]
                         apply the patch (idempotent; safe to re-run)
                         --verify-launch: smoke-test the launch (only allowed
                         with --app <scratch-copy>, never the real install)
  $0 revert              restore the original Claude.app
  $0 status              show patch state, hashes, backup info, profiles
  $0 open [name]         launch/focus a profile (no name = default profile)
  $0 list                list known profiles (running? key captured?)
  $0 dash [port]         run the local usage dashboard (default port 8965)
  $0 doctor              repair every profile's session-index link, check
                         patch freshness, run claude-sync if idle
  $0 install             add 'claude-deck' shortcut to ~/.zshrc
  $0 uninstall           remove the 'claude-deck' shortcut from ~/.zshrc
  $0 watchdog on|off     (sudo) auto re-patch after Claude updates
  $0 --help              this message

Notes:
  - patch/revert require sudo (writes into /Applications/Claude.app).
  - Backup of the original app.asar is saved in: $BACKUP_DIR
  - Re-signs the bundle ad-hoc (Apple notarization is lost, locally-only
    fine). This strips Apple's restricted entitlements and adds
    disable-library-validation; see README for what that means for
    hardware-key/passkey login.
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
  doctor)         cmd_doctor ;;
  install)        cmd_install ;;
  uninstall)      cmd_uninstall ;;
  watchdog)       cmd_watchdog "$@" ;;
  watchdog-run)   cmd_watchdog_run ;;
  --help|-h|help) cmd_help ;;
  "")             cmd_help ;;
  *)              cmd_help; exit 1 ;;
esac
