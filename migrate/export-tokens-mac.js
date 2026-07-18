#!/usr/bin/env node
'use strict';
// RUN THIS ON THE MAC. Half one of moving working profiles to another machine.
//
// Copying a profile's cookies does NOT move a working login: since ~2026-07-08
// claude.ai refuses to mint the elevated Claude Code token for a session it
// considers stale ("Session is not fresh enough to grant elevated access",
// error_code session_stale_relogin), and a session copied from another machine
// is always stale. The app then latches that failure, so re-signing-in in the
// app never clears it. What DOES work is the refresh token: refreshing never
// touches the freshness gate, so a profile that owns a valid refresh token
// just works. Those tokens live per-profile in config.json under
// "oauth:tokenCacheV2", encrypted with the OS key, which is why they cannot
// simply be copied across machines -- they have to be decrypted here and
// re-encrypted there (see import-tokens-win.js).
//
// This writes ~/claude-deck-tokens.json: for every profile, that account's OWN
// tokens, so each profile keeps its own identity and quota on the far side.
//
// SECURITY: the output holds real account credentials. It is written mode 600.
// Move it privately (AirDrop/USB/scp), import it, then delete it on BOTH
// machines. Never email it or drop it in cloud sync.
//
//   node export-tokens-mac.js
//
const fs = require('fs');
const path = require('path');
const os = require('os');
const crypto = require('crypto');
const { execFileSync } = require('child_process');

// macOS "Claude Safe Storage" key (may raise a Keychain prompt: click Allow).
let pw;
try {
  pw = execFileSync('security', ['find-generic-password', '-s', 'Claude Safe Storage', '-w'], { encoding: 'utf8' }).replace(/\n$/, '');
} catch (e) {
  console.error('Could not read the Claude Safe Storage key from Keychain. Approve the prompt and retry.');
  process.exit(1);
}
const key = crypto.pbkdf2Sync(pw, 'saltysalt', 1003, 16, 'sha1');
const IV = Buffer.alloc(16, ' ');

function decryptV10(blob) {
  if (!blob || blob.slice(0, 3).toString('latin1') !== 'v10') return null;
  try {
    const d = crypto.createDecipheriv('aes-128-cbc', key, IV);
    d.setAutoPadding(false);
    const out = Buffer.concat([d.update(blob.slice(3)), d.final()]);
    const pad = out[out.length - 1];
    if (!(pad >= 1 && pad <= 16) || pad > out.length) return null;
    return out.slice(0, out.length - pad);
  } catch (e) { return null; }
}

const base = path.join(os.homedir(), 'Library', 'Application Support');
const profilesRoot = path.join(base, 'Claude Profiles');
const targets = [['(default)', path.join(base, 'Claude')]];
if (fs.existsSync(profilesRoot)) {
  for (const n of fs.readdirSync(profilesRoot)) {
    const d = path.join(profilesRoot, n);
    try { if (fs.statSync(d).isDirectory()) targets.push([n, d]); } catch (e) {}
  }
}

const out = {};
for (const [name, ud] of targets) {
  const cfgP = path.join(ud, 'config.json');
  if (!fs.existsSync(cfgP)) continue;
  let cfg;
  try { cfg = JSON.parse(fs.readFileSync(cfgP, 'utf8')); } catch (e) { console.error('skip ' + name + ' (bad config.json)'); continue; }
  const b64 = cfg['oauth:tokenCacheV2'];
  if (!b64) { console.error('skip ' + name + ' (no token cache -- never used Claude Code?)'); continue; }
  const plain = decryptV10(Buffer.from(b64, 'base64'));
  if (!plain) { console.error('WARN ' + name + ': could not decrypt token cache'); continue; }
  let cache;
  try { cache = JSON.parse(plain.toString('utf8')); } catch (e) { console.error('WARN ' + name + ': token cache not JSON'); continue; }
  out[name] = { account: cfg.lastKnownAccountUuid || null, cache };
  console.error('exported ' + name + '  account=' + (cfg.lastKnownAccountUuid || '?') + '  entries=' + Object.keys(cache).length);
}

const dest = path.join(os.homedir(), 'claude-deck-tokens.json');
fs.writeFileSync(dest, JSON.stringify(out, null, 2), { mode: 0o600 });
console.error('\nWrote ' + dest + '  (' + Object.keys(out).length + ' profiles).');
console.error('Move it to the target machine, run import-tokens-win.js, then delete it on both.');
