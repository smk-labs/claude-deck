// Chromium v10 cookie crypto for one specific job: splice a different org
// UUID into a claude-deck profile's own `lastActiveOrg` cookie so opening it
// lands on that org, instead of whatever was last active. No asar, no app
// bundle, no patch: this only ever touches a profile's own Cookies sqlite
// file under "~/Library/Application Support/Claude Profiles/<name>/".
//
// Format (verified against a live Cookies row): 3-byte "v10" prefix + AES-
// 128-CBC ciphertext, key = PBKDF2-SHA1(keychain password, "saltysalt", 1003
// iters, 16 bytes), fixed IV of 16 spaces. This matches stock Chromium's
// macOS cookie encryption. The keychain password (service "Claude Safe
// Storage", account "Claude Key") is one keychain item for the whole app,
// shared by every profile's userData dir, not per-profile.
//
// One deviation from the textbook v10 format, confirmed by decrypting real
// rows from two different profiles: the plaintext isn't just the cookie
// value, it's [N constant bytes][36-byte org UUID] for some fixed N (34
// observed on this install). We never assume or fabricate those leading
// bytes — we derive N by subtracting the known 36-byte UUID length from
// whatever the existing row decrypts to, and splice the new UUID in after
// them. That means seeding only works on a profile that already has a
// lastActiveOrg row (i.e. has had some org active at least once); a profile
// that has never opened claude.ai has nothing to copy those bytes from.
'use strict';

const crypto = require('crypto');
const { execFileSync } = require('child_process');

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const UUID_BYTE_LEN = 36;
const FIXED_IV = Buffer.alloc(16, ' ');

function deriveKey() {
  const password = execFileSync(
    'security',
    ['find-generic-password', '-s', 'Claude Safe Storage', '-w'],
    { encoding: 'utf8' }
  ).replace(/\n$/, '');
  return crypto.pbkdf2Sync(password, 'saltysalt', 1003, 16, 'sha1');
}

function decryptV10(key, blob) {
  if (!blob || blob.length < 4 || blob.slice(0, 3).toString('latin1') !== 'v10') return null;
  try {
    const decipher = crypto.createDecipheriv('aes-128-cbc', key, FIXED_IV);
    decipher.setAutoPadding(false);
    const out = Buffer.concat([decipher.update(blob.slice(3)), decipher.final()]);
    const padLen = out[out.length - 1];
    if (!(padLen >= 1 && padLen <= 16) || padLen > out.length) return null;
    return out.slice(0, out.length - padLen);
  } catch (e) {
    return null;
  }
}

function encryptV10(key, plain) {
  const padLen = 16 - (plain.length % 16);
  const padded = Buffer.concat([plain, Buffer.alloc(padLen, padLen)]);
  const cipher = crypto.createCipheriv('aes-128-cbc', key, FIXED_IV);
  cipher.setAutoPadding(false);
  return Buffer.concat([Buffer.from('v10'), cipher.update(padded), cipher.final()]);
}

function readEncryptedLastActiveOrg(cookiesDb) {
  // immutable=1: a plain read never contends with a running Claude's WAL lock.
  const uri = 'file:' + cookiesDb + '?immutable=1';
  const sql =
    "SELECT hex(encrypted_value) AS hex FROM cookies WHERE host_key='.claude.ai' AND name='lastActiveOrg';";
  const out = execFileSync('sqlite3', ['-json', uri, sql], { encoding: 'utf8' });
  const rows = JSON.parse(out || '[]');
  return rows.length && rows[0].hex ? Buffer.from(rows[0].hex, 'hex') : null;
}

function writeEncryptedLastActiveOrg(cookiesDb, blob) {
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
// Returns { ok: true } or { ok: false, reason: 'bad-uuid' | 'no-cookie' | 'bad-format' }.
function seedOrg(cookiesDb, orgUuid) {
  if (!UUID_RE.test(orgUuid)) return { ok: false, reason: 'bad-uuid' };

  let current;
  try {
    current = readEncryptedLastActiveOrg(cookiesDb);
  } catch (e) {
    return { ok: false, reason: 'no-cookie' };
  }
  if (!current) return { ok: false, reason: 'no-cookie' };

  const key = deriveKey();
  const plain = decryptV10(key, current);
  if (!plain || plain.length <= UUID_BYTE_LEN) return { ok: false, reason: 'bad-format' };

  const prefix = plain.slice(0, plain.length - UUID_BYTE_LEN);
  const newPlain = Buffer.concat([prefix, Buffer.from(orgUuid, 'utf8')]);
  writeEncryptedLastActiveOrg(cookiesDb, encryptV10(key, newPlain));
  return { ok: true };
}

module.exports = { seedOrg, decryptV10, encryptV10, deriveKey, UUID_RE };

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
  process.exit(result.reason === 'no-cookie' ? 2 : 1);
}
