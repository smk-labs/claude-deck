'use strict';
// RUN THIS ON WINDOWS, after moving claude-deck-tokens.json over from the Mac
// (see export-tokens-mac.js for why copying cookies is not enough).
//
// For each profile it re-encrypts that account's OWN tokens with the Windows
// profile's own key and writes them into its config.json, so every profile
// keeps its own identity and quota -- no per-account login needed. The profile
// still needs its (stale) session cookie for the web identity; the imported
// refresh token is what makes sending messages work again.
//
// Identity-safe: a profile is only written when its Windows account matches
// the Mac account of the same name. Skips profiles that were never launched on
// Windows (no config.json / Local State yet -- launch them once first) and
// backs up every config.json it touches.
//
//   node import-tokens-win.js <path-to-claude-deck-tokens.json> [profileName]
//   (profileName imports just one; omit it to do all)
//
// The Mac's flag-less instance is exported as "(default)" and lands on the
// profile named `default`. A bulk run always skips it, so importing it is a
// deliberate act:  node import-tokens-win.js <file> default
//
const fs = require('fs');
const path = require('path');
const { deriveKey, encryptV10 } = require(path.join(__dirname, '..', 'dashboard', 'cookie-crypto.js'));

const transferFile = process.argv[2];
const only = process.argv[3];
if (!transferFile || !fs.existsSync(transferFile)) {
  console.error('usage: node import-tokens-win.js <claude-deck-tokens.json> [profileName]');
  process.exit(1);
}
const data = JSON.parse(fs.readFileSync(transferFile, 'utf8'));
const stamp = new Date().toISOString().replace(/[:.]/g, '-');

// Data dirs live outside the MSIX-virtualized known folders at
// ~\ClaudeProfiles\<name>; fall back to the legacy AppData layout on machines
// that have not run the one-time migration yet. Same resolve-order as
// claude-deck.ps1 and server.js.
const ESCAPED_ROOT = path.join(process.env.USERPROFILE || '', 'ClaudeProfiles');
const LEGACY_ROOT = path.join(process.env.APPDATA || '', 'Claude Profiles');
function profileDir(name) {
  const escaped = path.join(ESCAPED_ROOT, name);
  if (fs.existsSync(escaped)) return escaped;
  return path.join(LEGACY_ROOT, name);
}

// The Mac exporter labels the flag-less instance "(default)"; on Windows that
// is the profile dir ~\ClaudeProfiles\default, launched with
// CLAUDE_USER_DATA_DIR like every other one. It stays out of the all-profiles
// sweep so a bulk import can never overwrite a working default by accident,
// but importing it IS what replicating a Mac means, so naming it explicitly
// (`import-tokens-win.js <file> default`) does it.
for (const label of Object.keys(data)) {
  const name = label === '(default)' ? 'default' : label;
  if (label === '(default)' && only !== 'default') {
    console.log('SKIP default: not imported in a bulk run -- name it explicitly to import it');
    continue;
  }
  if (only && name !== only) continue;
  const macAccount = data[label].account;
  const macCache = data[label].cache;
  // Only the escaped layout has a real ~\ClaudeProfiles\default. On a machine
  // that has not run the one-time migration, the flag-less instance still
  // lives in %APPDATA%\Claude, which profileDir() does NOT resolve to, so
  // importing there would write into a dir the app never reads.
  if (name === 'default' && !fs.existsSync(path.join(ESCAPED_ROOT, 'default'))) {
    console.log('SKIP default: ' + path.join(ESCAPED_ROOT, 'default') + ' does not exist -- run the profile migration first, then launch default once');
    continue;
  }
  const ud = profileDir(name);
  const cfgP = path.join(ud, 'config.json');
  const lsP = path.join(ud, 'Local State');
  const ckP = path.join(ud, 'Network', 'Cookies');

  if (!fs.existsSync(cfgP) || !fs.existsSync(lsP)) {
    console.log('SKIP ' + name + ': never launched on Windows (no config/Local State) -- launch it once first');
    continue;
  }
  let cfg;
  try { cfg = JSON.parse(fs.readFileSync(cfgP, 'utf8')); } catch (e) { console.log('SKIP ' + name + ': bad Windows config.json'); continue; }
  const winAccount = cfg.lastKnownAccountUuid || null;
  if (winAccount && macAccount && winAccount !== macAccount) {
    console.log('SKIP ' + name + ': account mismatch (win=' + winAccount + ' mac=' + macAccount + ') -- not the same identity, refusing');
    continue;
  }
  let key;
  try { key = deriveKey(ckP); } catch (e) { console.log('SKIP ' + name + ': cannot derive Windows key (' + e.message + ')'); continue; }

  fs.copyFileSync(cfgP, cfgP + '.bak-' + stamp);
  cfg['oauth:tokenCacheV2'] = encryptV10(key, Buffer.from(JSON.stringify(macCache), 'utf8')).toString('base64');
  fs.writeFileSync(cfgP, JSON.stringify(cfg, null, '\t'));
  console.log('IMPORTED ' + name + '  account=' + (macAccount || '?') + '  entries=' + Object.keys(macCache).length + '  (backup config.json.bak-' + stamp + ')');
}
console.log('\nDone. Open each imported profile (no login):  claude-deck open <name>');
