// Chromium v10 cookie crypto for two jobs, both against a profile's own
// Cookies sqlite file (macOS: "~/Library/Application Support/Claude
// Profiles/<name>/Cookies"; Windows: "<profile dir>\Network\Cookies"). No
// asar, no app bundle, no patch:
//   seedOrg        splices a different org UUID into the `lastActiveOrg`
//                  cookie, so opening the profile lands on that org.
//   readSessionKey reads the claude.ai `sessionKey` cookie, which is what
//                  the dashboard authenticates with.
//
// The plaintext of the lastActiveOrg cookie is [N leading bytes][36-byte org
// UUID]. seedOrg never assumes/fabricates the leading bytes: it decrypts the
// profile's own existing row, keeps everything before the trailing 36 bytes,
// and splices the new UUID in after them. A profile that has never had an org
// active (no existing row) can't be seeded and falls through to a normal
// launch. The N bytes differ by platform (macOS: a constant ~34; Windows: the
// 32-byte SHA-256 of the host_key that Chromium prepends), which is exactly
// why we copy them rather than compute them.
//
// The encryption itself is platform-specific:
//   macOS   v10 = 'v10' + AES-128-CBC, key = PBKDF2-SHA1(keychain pw,
//           "saltysalt", 1003, 16), fixed IV of 16 spaces; sqlite via the
//           system `sqlite3` CLI.
//   Windows v10 = 'v10' + nonce(12) + AES-256-GCM + tag(16), key = DPAPI-
//           unprotect of Local State os_crypt.encrypted_key (per profile);
//           sqlite via node:sqlite (node >= 22.5). If node has no node:sqlite,
//           seedOrg returns { ok:false, reason:'no-sqlite' } and the caller
//           just launches normally.
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const IS_WIN = process.platform === 'win32';
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const UUID_BYTE_LEN = 36;
const FIXED_IV = Buffer.alloc(16, ' ');

// ---- key derivation ----

// One derivation per process: on macOS this shells out to the keychain, on
// Windows to DPAPI, and readSessionKey can be called for several profiles on
// every dashboard poll. Cached per db path because the Windows key is
// per-profile while the macOS one is a single shared keychain item.
const KEY_CACHE = new Map();

function deriveKey(cookiesDb) {
  const cacheKey = IS_WIN ? cookiesDb : 'mac';
  const cached = KEY_CACHE.get(cacheKey);
  if (cached) return cached;
  const key = deriveKeyUncached(cookiesDb);
  KEY_CACHE.set(cacheKey, key);
  return key;
}

function deriveKeyUncached(cookiesDb) {
  if (IS_WIN) {
    // Per-profile AES key: DPAPI-unprotect Local State os_crypt.encrypted_key.
    // node has no DPAPI, so unprotect via a one-shot PowerShell call. Cookies
    // lives at <userData>\Network\Cookies, so userData is two dirs up.
    const userData = path.dirname(path.dirname(cookiesDb));
    const ls = JSON.parse(fs.readFileSync(path.join(userData, 'Local State'), 'utf8'));
    const b64 = ls.os_crypt.encrypted_key; // base64, prefixed with 'DPAPI'
    const ps =
      "Add-Type -AssemblyName System.Security;" +
      "$b=[Convert]::FromBase64String('" + b64 + "');" +
      "$k=[System.Security.Cryptography.ProtectedData]::Unprotect(" +
      "$b[5..($b.Length-1)],$null,'CurrentUser');[Convert]::ToBase64String($k)";
    const out = execFileSync('powershell', ['-NoProfile', '-Command', ps], { encoding: 'utf8' });
    return Buffer.from(out.trim(), 'base64');
  }
  const password = execFileSync(
    'security',
    ['find-generic-password', '-s', 'Claude Safe Storage', '-w'],
    { encoding: 'utf8' }
  ).replace(/\n$/, '');
  return crypto.pbkdf2Sync(password, 'saltysalt', 1003, 16, 'sha1');
}

// ---- v10 encrypt / decrypt ----

function decryptV10(key, blob) {
  if (!blob || blob.slice(0, 3).toString('latin1') !== 'v10') return null;
  try {
    if (IS_WIN) {
      if (blob.length < 3 + 12 + 16) return null;
      const nonce = blob.slice(3, 15);
      const tag = blob.slice(blob.length - 16);
      const ct = blob.slice(15, blob.length - 16);
      const d = crypto.createDecipheriv('aes-256-gcm', key, nonce);
      d.setAuthTag(tag);
      return Buffer.concat([d.update(ct), d.final()]);
    }
    const d = crypto.createDecipheriv('aes-128-cbc', key, FIXED_IV);
    d.setAutoPadding(false);
    const out = Buffer.concat([d.update(blob.slice(3)), d.final()]);
    const padLen = out[out.length - 1];
    if (!(padLen >= 1 && padLen <= 16) || padLen > out.length) return null;
    return out.slice(0, out.length - padLen);
  } catch (e) {
    return null;
  }
}

function encryptV10(key, plain) {
  if (IS_WIN) {
    const nonce = crypto.randomBytes(12);
    const c = crypto.createCipheriv('aes-256-gcm', key, nonce);
    const ct = Buffer.concat([c.update(plain), c.final()]);
    return Buffer.concat([Buffer.from('v10'), nonce, ct, c.getAuthTag()]);
  }
  const padLen = 16 - (plain.length % 16);
  const padded = Buffer.concat([plain, Buffer.alloc(padLen, padLen)]);
  const c = crypto.createCipheriv('aes-128-cbc', key, FIXED_IV);
  c.setAutoPadding(false);
  return Buffer.concat([Buffer.from('v10'), c.update(padded), c.final()]);
}

// ---- sqlite read / write of the lastActiveOrg row ----

// node:sqlite is stable-experimental (node >= 22.5). Load it lazily and
// silence its one-time ExperimentalWarning; return null if unavailable so the
// Windows path can degrade to a normal launch instead of throwing.
function getNodeSqlite() {
  const prev = process.emitWarning;
  process.emitWarning = () => {};
  try {
    return require('node:sqlite');
  } catch (e) {
    return null;
  } finally {
    process.emitWarning = prev;
  }
}

const SQL_UPDATE =
  "UPDATE cookies SET encrypted_value = ? WHERE host_key='.claude.ai' AND name='lastActiveOrg'";

// Cookie names are always literals from this file's own callers, never user
// input, and the letters-only assertion keeps that structurally true: the
// macOS path builds SQL text for the sqlite3 CLI, which takes no parameters.
function selectSql(cookieName) {
  if (!/^[A-Za-z]+$/.test(cookieName)) throw new Error('bad-cookie-name');
  return (
    "SELECT hex(encrypted_value) AS hex FROM cookies WHERE host_key='.claude.ai' AND name='" +
    cookieName +
    "'"
  );
}

function readEncryptedCookie(cookiesDb, cookieName) {
  const sql = selectSql(cookieName);
  if (IS_WIN) {
    const sqlite = getNodeSqlite();
    if (!sqlite) throw new Error('no-sqlite');
    const db = new sqlite.DatabaseSync(cookiesDb);
    try {
      const row = db.prepare(sql).get();
      return row && row.hex ? Buffer.from(row.hex, 'hex') : null;
    } finally {
      db.close();
    }
  }
  // immutable=1: a plain read never contends with a running Claude's WAL lock.
  const uri = 'file:' + cookiesDb + '?immutable=1';
  // stderr ignored: "unable to open database" is the normal answer for a
  // profile that has never been launched, and the dashboard polls this.
  const out = execFileSync('sqlite3', ['-json', uri, sql + ';'], {
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'ignore'],
  });
  const rows = JSON.parse(out || '[]');
  return rows.length && rows[0].hex ? Buffer.from(rows[0].hex, 'hex') : null;
}

function writeEncryptedLastActiveOrg(cookiesDb, blob) {
  if (IS_WIN) {
    const sqlite = getNodeSqlite();
    if (!sqlite) throw new Error('no-sqlite');
    const db = new sqlite.DatabaseSync(cookiesDb);
    try {
      db.prepare(SQL_UPDATE).run(blob);
    } finally {
      db.close();
    }
    return;
  }
  const sql =
    "UPDATE cookies SET encrypted_value = X'" +
    blob.toString('hex') +
    "' WHERE host_key='.claude.ai' AND name='lastActiveOrg';";
  execFileSync('sqlite3', [cookiesDb, sql]);
}

// Splices orgUuid into cookiesDb's existing lastActiveOrg row.
//
// Caller MUST guarantee the profile is not currently running. Writing to a
// live Cookies WAL file from outside is externally silent (no crash, no lock
// error) but the running app can later overwrite or ignore it, so the
// not-running check has to gate this call through real control flow, not
// just run beforehand.
//
// Returns { ok: true } or { ok: false, reason: 'bad-uuid' | 'no-cookie' | 'bad-format' | 'no-sqlite' }.
function seedOrg(cookiesDb, orgUuid) {
  if (!UUID_RE.test(orgUuid)) return { ok: false, reason: 'bad-uuid' };

  let current;
  try {
    current = readEncryptedCookie(cookiesDb, 'lastActiveOrg');
  } catch (e) {
    if (e && e.message === 'no-sqlite') return { ok: false, reason: 'no-sqlite' };
    return { ok: false, reason: 'no-cookie' };
  }
  if (!current) return { ok: false, reason: 'no-cookie' };

  const key = deriveKey(cookiesDb);
  const plain = decryptV10(key, current);
  if (!plain || plain.length <= UUID_BYTE_LEN) return { ok: false, reason: 'bad-format' };

  const prefix = plain.slice(0, plain.length - UUID_BYTE_LEN);
  const newPlain = Buffer.concat([prefix, Buffer.from(orgUuid, 'utf8')]);
  writeEncryptedLastActiveOrg(cookiesDb, encryptV10(key, newPlain));
  return { ok: true };
}

// ---- reading a profile's session key ----

function cookiesDbFor(userDataDir) {
  return IS_WIN
    ? path.join(userDataDir, 'Network', 'Cookies')
    : path.join(userDataDir, 'Cookies');
}

// Reads a profile's own claude.ai sessionKey out of its cookie store, read
// only, with no patch involved. This is the dashboard's fallback source for
// the key: while the app is patched the injected exporter keeps
// ~/.claude-deck/profiles/<name>.json up to date, but a Claude update
// silently reverts the patch (and Windows MSIX retired it entirely), and a
// profile whose key was never exported used to be invisible in the dashboard
// even after a real login.
//
// Chromium prefixes the cookie plaintext with the 32-byte SHA-256 of the
// host_key (verified live: sha256('.claude.ai') is byte-for-byte the leading
// 32 bytes of a decrypted claude.ai cookie). The 'sk-ant-' marker is
// preferred over a blind 32-byte cut so a future prefix change can't silently
// corrupt the key; the cut is the fallback if the token prefix ever changes.
// Returns null on every failure path: no keychain access, no cookie row, an
// undecryptable blob (a profile copied from another machine), or a value that
// does not look like a bearer token.
const HOST_HASH_LEN = 32;

function readSessionKey(userDataDir) {
  const cookiesDb = cookiesDbFor(userDataDir);
  try {
    // Checked, not just attempted: the sqlite3 CLI creates an empty database
    // file when asked to open a path that does not exist, and a read has no
    // business leaving anything behind in a profile that was never launched.
    if (!fs.existsSync(cookiesDb)) return null;
    const blob = readEncryptedCookie(cookiesDb, 'sessionKey');
    if (!blob) return null;
    const plain = decryptV10(deriveKey(cookiesDb), blob);
    if (!plain) return null;
    const at = plain.indexOf('sk-ant-', 0, 'utf8');
    const raw = at >= 0 ? plain.slice(at) : plain.slice(HOST_HASH_LEN);
    const value = raw.toString('utf8').trim();
    return /^[\x21-\x7e]{20,}$/.test(value) ? value : null;
  } catch (e) {
    return null;
  }
}

module.exports = { seedOrg, readSessionKey, cookiesDbFor, decryptV10, encryptV10, deriveKey, UUID_RE };

if (require.main === module) {
  const [, , cmd, cookiesDb, orgUuid] = process.argv;
  if (cmd !== 'seed-org' || !cookiesDb || !orgUuid) {
    console.error('usage: node cookie-crypto.js seed-org <cookiesDbPath> <orgUuid>');
    process.exit(1);
  }
  let result;
  try {
    result = seedOrg(cookiesDb, orgUuid);
  } catch (e) {
    console.error(String((e && e.message) || e));
    process.exit(1);
  }
  if (result.ok) process.exit(0);
  console.error('cookie-crypto: ' + result.reason);
  process.exit(result.reason === 'no-cookie' || result.reason === 'no-sqlite' ? 2 : 1);
}
