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
const APPDATA = process.env.APPDATA;
const stamp = new Date().toISOString().replace(/[:.]/g, '-');

for (const name of Object.keys(data)) {
  if (name === '(default)') continue;             // never overwrite the working default
  if (only && name !== only) continue;
  const macAccount = data[name].account;
  const macCache = data[name].cache;
  const ud = path.join(APPDATA, 'Claude Profiles', name);
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
