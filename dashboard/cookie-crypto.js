// Chromium v10 cookie crypto for one specific job: splice a different org
// UUID into a claude-deck profile's own `lastActiveOrg` cookie so opening it
// lands on that org, instead of whatever was last active. No asar, no app
// bundle, no patch: this only ever touches a profile's own Cookies sqlite
// file (macOS: "~/Library/Application Support/Claude Profiles/<name>/Cookies";
// Windows: "%APPDATA%\Claude Profiles\<name>\Network\Cookies").
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

function deriveKey(cookiesDb) {
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

const SQL_SELECT =
  "SELECT hex(encrypted_value) AS hex FROM cookies WHERE host_key='.claude.ai' AND name='lastActiveOrg'";
const SQL_UPDATE =
  "UPDATE cookies SET encrypted_value = ? WHERE host_key='.claude.ai' AND name='lastActiveOrg'";

function readEncryptedLastActiveOrg(cookiesDb) {
  if (IS_WIN) {
    const sqlite = getNodeSqlite();
    if (!sqlite) throw new Error('no-sqlite');
    const db = new sqlite.DatabaseSync(cookiesDb);
    try {
      const row = db.prepare(SQL_SELECT).get();
      return row && row.hex ? Buffer.from(row.hex, 'hex') : null;
    } finally {
      db.close();
    }
  }
  // immutable=1: a plain read never contends with a running Claude's WAL lock.
  const uri = 'file:' + cookiesDb + '?immutable=1';
  const out = execFileSync('sqlite3', ['-json', uri, SQL_SELECT + ';'], { encoding: 'utf8' });
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
    current = readEncryptedLastActiveOrg(cookiesDb);
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

// ---- session seeding (Windows only) ----

// Plants a profile JSON's sessionKey as the claude.ai cookie, so a migrated
// profile opens logged in without a login. On macOS the injected code already
// does this at app.whenReady(); on Windows MSIX there is no injection at all,
// so nothing else can. Windows-only for exactly that reason.
//
// Unlike seedOrg there IS no existing row to copy leading bytes from, but the
// Windows format is fully known: plaintext = SHA-256(host_key) + value,
// verified live against a real profile. The rest of the sqlite row is cloned
// from one of the profile's own claude.ai cookies, so the column set always
// matches whatever Chromium schema that profile is on.
//
// Caller MUST guarantee the profile is not running (same reason as seedOrg).
//
// Returns { ok:true, hosts:[...] } or { ok:false, reason: 'win-only' |
// 'no-sqlite' | 'bad-key' | 'no-template' }.
const SESSION_HOSTS = ['claude.ai', '.claude.ai'];
const SESSION_TTL_DAYS = 60;
const CHROME_EPOCH_OFFSET_MS = 11644473600000; // 1601-01-01 -> 1970-01-01

// Chromium stores these as microseconds since 1601, which overflows a JS
// number, so they are read and written as BigInt throughout.
function toChromeTime(ms) {
  return BigInt(ms + CHROME_EPOCH_OFFSET_MS) * 1000n;
}

function seedSession(cookiesDb, sessionKey) {
  if (!IS_WIN) return { ok: false, reason: 'win-only' };
  if (!sessionKey || !/^sk-ant-sid\S+$/.test(sessionKey)) return { ok: false, reason: 'bad-key' };

  const sqlite = getNodeSqlite();
  if (!sqlite) return { ok: false, reason: 'no-sqlite' };

  const db = new sqlite.DatabaseSync(cookiesDb);
  try {
    // A row of the profile's own, purely as a column-shape template.
    const templateStmt = db.prepare("SELECT * FROM cookies WHERE host_key LIKE '%claude.ai' LIMIT 1");
    templateStmt.setReadBigInts(true);
    const template = templateStmt.get();
    if (!template) return { ok: false, reason: 'no-template' };

    const key = deriveKey(cookiesDb);
    const nowMs = Date.now();
    const expires = toChromeTime(nowMs + SESSION_TTL_DAYS * 86400000);
    const del = db.prepare('DELETE FROM cookies WHERE host_key = ? AND name = ?');

    SESSION_HOSTS.forEach((host, i) => {
      const plain = Buffer.concat([
        crypto.createHash('sha256').update(host).digest(),
        Buffer.from(sessionKey, 'utf8'),
      ]);
      const overrides = {
        creation_utc: toChromeTime(nowMs) + BigInt(i), // part of the primary key
        host_key: host,
        name: 'sessionKey',
        value: '',
        encrypted_value: encryptV10(key, plain),
        path: '/',
        expires_utc: expires,
        is_secure: 1,
        is_httponly: 1,
        last_access_utc: toChromeTime(nowMs),
        has_expires: 1,
        is_persistent: 1,
        samesite: 1, // lax
        source_scheme: 2, // secure
        source_port: 443,
        last_update_utc: toChromeTime(nowMs),
      };
      // Unknown / future columns keep the template's own value.
      const cols = Object.keys(template);
      const row = cols.map((c) => (c in overrides ? overrides[c] : template[c]));
      del.run(host, 'sessionKey');
      db.prepare(
        'INSERT INTO cookies (' + cols.join(',') + ') VALUES (' + cols.map(() => '?').join(',') + ')'
      ).run(...row);
    });
  } finally {
    db.close();
  }
  return { ok: true, hosts: SESSION_HOSTS };
}

module.exports = { seedOrg, seedSession, decryptV10, encryptV10, deriveKey, UUID_RE };

if (require.main === module) {
  const [, , cmd, cookiesDb, arg] = process.argv;
  if ((cmd !== 'seed-org' && cmd !== 'seed-session') || !cookiesDb || !arg) {
    console.error('usage: node cookie-crypto.js seed-org <cookiesDbPath> <orgUuid>');
    console.error('       node cookie-crypto.js seed-session <cookiesDbPath> <sessionKey>');
    process.exit(1);
  }
  let result;
  try {
    result = cmd === 'seed-org' ? seedOrg(cookiesDb, arg) : seedSession(cookiesDb, arg);
  } catch (e) {
    console.error(String((e && e.message) || e));
    process.exit(1);
  }
  if (result.ok) process.exit(0);
  console.error('cookie-crypto: ' + result.reason);
  process.exit(result.reason === 'no-cookie' || result.reason === 'no-sqlite' ? 2 : 1);
}
