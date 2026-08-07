#!/bin/bash
# RUN THIS ON THE MAC, once every profile has been logged in by hand.
#
# One bundle instead of two half-migrations. Moving a login to another machine
# needs BOTH halves and they live in different places:
#   - the session cookie, which is the web identity  -> profiles/<name>.json
#   - the OAuth refresh token, which is what actually lets the app send
#     messages                                        -> config.json, OS-encrypted
# Copying a profile folder carries neither usefully: cookies are encrypted with
# an OS-bound key (macOS Keychain), so they are undecryptable on the far side.
#
# Writes ~/claude-deck-transfer/ holding:
#   profiles/<name>.json     the session keys, exactly as the dashboard stores them
#   claude-deck-tokens.json  every profile's own decrypted OAuth token cache
#   MANIFEST.txt             what is inside, and the order to import it
#
# SECURITY: this directory is every account's credentials in the clear. It is
# written mode 700 / 600. Move it privately (AirDrop, USB, scp), import it, then
# delete it on BOTH machines. Never email it, never put it in cloud sync, never
# commit it.
#
#   ./migrate/export-all-mac.sh
#
set -eu

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
OUT="$HOME/claude-deck-transfer"
PROFILES="$HOME/.claude-deck/profiles"

command -v node >/dev/null 2>&1 || { printf '✗ node not found on PATH.\n' >&2; exit 1; }
[ -d "$PROFILES" ] || { printf '✗ No profiles at %s\n' "$PROFILES" >&2; exit 1; }

rm -rf "$OUT"
mkdir -p "$OUT/profiles"
chmod 700 "$OUT" "$OUT/profiles"

# --- half one: session keys -------------------------------------------------
# Only profiles that actually hold a key travel. A profile exported without one
# lands on the far side as a login screen, which is exactly the confusion this
# whole exercise exists to end, so it is called out here instead.
missing=""
count=0
for f in "$PROFILES"/*.json; do
  [ -e "$f" ] || continue
  name="$(basename "$f" .json)"
  if node -e 'process.exit(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).sessionKey ? 0 : 1)' "$f" 2>/dev/null; then
    cp "$f" "$OUT/profiles/$name.json"
    chmod 600 "$OUT/profiles/$name.json"
    count=$((count + 1))
  else
    missing="$missing $name"
  fi
done

# --- half two: OAuth tokens -------------------------------------------------
( cd "$OUT" && node "$HERE/export-tokens-mac.js" ) 2>&1 | sed 's/^/  /'
if [ -f "$HOME/claude-deck-tokens.json" ]; then
  mv "$HOME/claude-deck-tokens.json" "$OUT/claude-deck-tokens.json"
  chmod 600 "$OUT/claude-deck-tokens.json"
fi

tokens=0
[ -f "$OUT/claude-deck-tokens.json" ] && tokens=$(node -e 'console.log(Object.keys(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))).length)' "$OUT/claude-deck-tokens.json")

{
  printf 'claude-deck transfer bundle\n'
  printf 'made on the Mac, %s\n\n' "$(date -u '+%Y-%m-%d %H:%M UTC')"
  printf 'profiles/          %s session key file(s)\n' "$count"
  printf 'claude-deck-tokens.json  %s profile(s) with OAuth tokens\n\n' "$tokens"
  printf 'Import order on Windows, per profile, with the profile CLOSED:\n'
  printf '  1. copy profiles\\<name>.json into %%USERPROFILE%%\\.claude-deck\\profiles\\\n'
  printf '  2. claude-deck open <name>   (materializes the dir; it opens LOGGED OUT, do NOT log in)\n'
  printf '  3. close it\n'
  printf '  4. node dashboard\\cookie-crypto.js seed-session <profiledir>\\Network\\Cookies <sessionKey>\n'
  printf '  5. node migrate\\import-tokens-win.js claude-deck-tokens.json <name>\n'
  printf '  6. claude-deck open <name>   (should come up logged in and able to send)\n\n'
  printf 'Proof of success, in <profiledir>\\Logs\\main.log:\n'
  printf '  "[oauth-v2] using cached token" with client 9d1c250a, and ZERO session_stale_relogin\n\n'
  printf 'DELETE this whole directory on both machines when done.\n'
  if [ -n "$missing" ]; then
    printf '\nNOT exported (no session key, never logged in here):%s\n' "$missing"
  fi
} > "$OUT/MANIFEST.txt"
chmod 600 "$OUT/MANIFEST.txt"

printf '\n✓ Bundle ready: %s\n' "$OUT"
printf '  %s session key(s), %s token set(s)\n' "$count" "$tokens"
[ -n "$missing" ] && printf '  ⚠ skipped (no key, log them in first):%s\n' "$missing"
printf '  Move it privately, import it, then delete it on both machines.\n'
