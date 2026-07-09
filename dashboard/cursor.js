'use strict';
// Cursor account adapter for the Claude Deck dashboard. Node >=18, stdlib only.
//
// Why this exists: the same company that runs several Claude logins also has a
// few Cursor (cursor.com) seats sitting idle. This module surfaces each Cursor
// account's plan and usage next to the Claude profiles, using the SAME
// philosophy the rest of claude-deck already follows for Claude: read a token
// that the vendor's own app already wrote to disk, never store or mint one
// ourselves.
//
// The hard difference from the Claude side: we cannot inject into Cursor (there
// is no patch), so instead of a clean profiles/<name>.json we read Cursor's own
// SQLite state store (state.vscdb, key `cursorAuth/accessToken`). Two facts,
// both verified against a live install, shape every choice below:
//
//   1. state.vscdb is a live, WAL-mode, ~300MB SQLite file held open by the
//      running Cursor. A plain read fails (SQLITE_CANTOPEN). Opening it through
//      the immutable URI (`file:...?immutable=1`) skips all locking and the WAL
//      entirely, reads only the main file, and returns in ~4ms with no copy.
//      macOS ships /usr/bin/sqlite3 (3.51, supports -json), so this needs no
//      dependency. Windows has no bundled sqlite3: token reads degrade to a
//      clean "can't read token" state there (documented), which is fine since
//      the primary target is macOS.
//
//   2. Cursor's stored accessToken is a session JWT with a ~60-day life, and
//      the "refreshToken" is the SAME expired JWT stored twice, not a separate
//      long-lived credential. So there is no safe way for us to mint a fresh
//      token; only Cursor itself can, when the app runs. An expired token is
//      therefore treated exactly like an expired Claude session key: the card
//      says "open Cursor for this account once to refresh". We never POST the
//      refresh token anywhere, so we can never log the account out of Cursor.
//
// Everything an idle account needs to be useful in the dashboard (label, email,
// plan tier, whether the login is still alive and until when) comes straight
// from disk and is 100% reliable. The live usage percentage is a best-effort
// extra layered on top: if the undocumented usage endpoint answers and parses,
// bars render; if not, the card still stands on its disk data. Cursor has moved
// these internal endpoints more than once, so live usage must never be the
// reason a card fails to render.

const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFile } = require('child_process');

const IS_WIN = process.platform === 'win32';
const IS_MAC = process.platform === 'darwin';

const CURSOR_DIR = path.join(os.homedir(), '.claude-deck', 'cursor');
const ACCOUNTS_FILE = path.join(CURSOR_DIR, 'accounts.json');

const CHROME_UA =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

// Included-usage dollar pools per plan (mid-2026 pricing). Only used to turn a
// spend figure into a percent when the live endpoint gives us dollars and we
// know the plan; absent either, we simply don't show a derived percent.
const CURSOR_POOL_USD = { pro: 20, 'pro+': 70, ultra: 400 };

const CURSOR_PLAN_LABELS = {
  free: 'Free',
  free_trial: 'Pro (trial)',
  trial: 'Pro (trial)',
  pro: 'Pro',
  pro_plus: 'Pro+',
  'pro-plus': 'Pro+',
  proplus: 'Pro+',
  ultra: 'Ultra',
  business: 'Business',
  team: 'Team',
  enterprise: 'Enterprise',
};

// ---------- small helpers ----------

function titleCase(s) {
  return String(s)
    .split(/[_\s-]+/)
    .filter(Boolean)
    .map((w) => w.charAt(0).toUpperCase() + w.slice(1))
    .join(' ');
}

function readJsonSafe(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch (e) {
    return null;
  }
}

function expandHome(p) {
  if (typeof p !== 'string') return p;
  if (p === '~') return os.homedir();
  if (p.slice(0, 2) === '~/' || p.slice(0, 2) === '~\\') return path.join(os.homedir(), p.slice(2));
  return p;
}

// Labels are shown in the UI and used as map keys; keep them to the same safe
// alphabet claude-deck uses for profile names.
function validLabel(name) {
  return typeof name === 'string' && /^[A-Za-z0-9_-]{1,32}$/.test(name);
}

function num(v) {
  return typeof v === 'number' && isFinite(v) ? v : null;
}

// Default per-platform Cursor userData directory (the parent of
// User/globalStorage/state.vscdb).
function defaultCursorUserData() {
  if (IS_WIN) return path.join(process.env.APPDATA || path.join(os.homedir(), 'AppData', 'Roaming'), 'Cursor');
  if (IS_MAC) return path.join(os.homedir(), 'Library', 'Application Support', 'Cursor');
  return path.join(os.homedir(), '.config', 'Cursor');
}

function stateDbFor(userDataDir) {
  return path.join(userDataDir, 'User', 'globalStorage', 'state.vscdb');
}

function planLabel(membership) {
  if (!membership) return null;
  const key = String(membership).toLowerCase();
  return CURSOR_PLAN_LABELS[key] || titleCase(key);
}

// ---------- account configuration ----------

// Reads ~/.claude-deck/cursor/accounts.json. Two shapes accepted: a bare array
// of accounts, or { "accounts": [...] }. Each account is one of:
//   { "label": "x", "stateDb": "/abs/path/to/state.vscdb" }   // explicit db
//   { "label": "x", "userDataDir": "~/CursorProfiles/x" }      // db derived
//   { "label": "team", "adminApiKey": "key_..." }              // Enterprise API
// If no config file exists (or it lists nothing), we auto-discover the default
// Cursor install as a single account so first run needs zero setup.
function readAccountsConfig() {
  const data = readJsonSafe(ACCOUNTS_FILE);
  let raw = [];
  if (data && Array.isArray(data.accounts)) raw = data.accounts;
  else if (Array.isArray(data)) raw = data;

  const out = [];
  const seen = {};
  raw.forEach((a, i) => {
    const acct = normalizeAccountConfig(a, i);
    if (acct && !seen[acct.label]) {
      seen[acct.label] = 1;
      out.push(acct);
    }
  });

  if (out.length === 0) {
    const def = stateDbFor(defaultCursorUserData());
    if (fs.existsSync(def)) out.push({ label: 'cursor', mode: 'token', stateDb: def });
  }
  return out;
}

function normalizeAccountConfig(a, i) {
  if (!a || typeof a !== 'object') return null;
  const label = validLabel(a.label) ? a.label : 'cursor-' + (i + 1);
  if (a.adminApiKey) {
    return { label: label, mode: 'admin', adminApiKey: String(a.adminApiKey), teamId: a.teamId || null };
  }
  let userDataDir;
  if (a.userDataDir) userDataDir = expandHome(a.userDataDir);
  else if (a.stateDb) userDataDir = path.resolve(expandHome(a.stateDb), '..', '..', '..');
  else userDataDir = defaultCursorUserData();
  return { label: label, mode: 'token', userDataDir: userDataDir, stateDb: a.stateDb ? expandHome(a.stateDb) : stateDbFor(userDataDir) };
}

// Which Cursor instances are running, keyed by their userData dir. A profiled
// instance carries `--user-data-dir <path>` on its main process argv; the
// default instance carries no flag and is represented by the default dir.
// Main process only: helper processes have a different binary path.
function getRunningCursorDirs() {
  return new Promise((resolve) => {
    if (IS_WIN) return resolve(new Set());
    execFile('ps', ['ax', '-o', 'command'], { maxBuffer: 4 * 1024 * 1024 }, (err, stdout) => {
      if (err || !stdout) return resolve(new Set());
      const running = new Set();
      for (const line of stdout.split('\n')) {
        if (!line.includes('Cursor.app/Contents/MacOS/Cursor')) continue;
        if (line.includes('Helper')) continue;
        const m = line.match(/--user-data-dir[= ]("[^"]+"|[^ ]+)/);
        if (m) running.add(path.resolve(m[1].replace(/^"|"$/g, '')));
        else running.add(path.resolve(defaultCursorUserData()));
      }
      resolve(running);
    });
  });
}

// ---------- reading the token out of state.vscdb ----------

const AUTH_KEYS = [
  'cursorAuth/accessToken',
  'cursorAuth/cachedEmail',
  'cursorAuth/stripeMembershipType',
  'cursorAuth/stripeSubscriptionStatus',
];

// Returns a { key: value } map for the auth keys, or null if the db can't be
// read (missing file, no sqlite3 on PATH, locked in a way immutable can't
// bypass, unparseable output). Never throws.
function readAuthFromDb(stateDb) {
  return new Promise((resolve) => {
    try {
      if (!stateDb || !fs.existsSync(stateDb)) return resolve(null);
    } catch (e) {
      return resolve(null);
    }
    const inList = AUTH_KEYS.map((k) => "'" + k + "'").join(',');
    const sql = 'SELECT key, value FROM ItemTable WHERE key IN (' + inList + ');';
    // immutable=1: read the main db file only, no lock, no WAL, no 300MB copy.
    const uri = 'file:' + stateDb + '?immutable=1';
    execFile(
      'sqlite3',
      ['-json', uri, sql],
      { maxBuffer: 8 * 1024 * 1024, windowsHide: true },
      (err, stdout) => {
        if (err || !stdout || !stdout.trim()) return resolve(null);
        let rows;
        try {
          rows = JSON.parse(stdout);
        } catch (e) {
          return resolve(null);
        }
        if (!Array.isArray(rows)) return resolve(null);
        const map = {};
        for (const r of rows) if (r && r.key) map[r.key] = r.value;
        resolve(map);
      }
    );
  });
}

// Decode a JWT payload without verifying (we only read claims Cursor put there,
// never trust them for auth). Returns the payload object or null.
function decodeJwt(token) {
  try {
    const parts = String(token).split('.');
    if (parts.length < 2) return null;
    return JSON.parse(Buffer.from(parts[1], 'base64url').toString('utf8'));
  } catch (e) {
    return null;
  }
}

// Cursor's session `sub` looks like "auth0|user_01ABC..."; the id used in the
// WorkosCursorSessionToken cookie is the part after the pipe.
function userIdFromSub(sub) {
  if (typeof sub !== 'string' || !sub) return null;
  return sub.indexOf('|') !== -1 ? sub.split('|').pop() : sub;
}

// ---------- live usage (best effort) ----------

function fetchCursorJson(url, cookie, postBody) {
  return fetch(url, {
    method: postBody !== undefined ? 'POST' : 'GET',
    body: postBody,
    headers: {
      Cookie: cookie,
      'User-Agent': CHROME_UA,
      Accept: 'application/json',
      'Content-Type': 'application/json',
      Referer: 'https://cursor.com/dashboard',
      Origin: 'https://cursor.com',
    },
  }).then(async (res) => {
    const text = await res.text();
    if (!res.ok) {
      const e = new Error('usage endpoint returned ' + res.status);
      e.status = res.status;
      throw e;
    }
    try {
      return JSON.parse(text);
    } catch (e) {
      throw new Error('usage endpoint returned non-JSON');
    }
  });
}

// Primary payload: cursor.com/api/dashboard/get-current-period-usage, the same
// call Cursor's own dashboard "Included in <plan>" panel renders. Shape:
//   { billingCycleStart, billingCycleEnd,            // epoch-ms strings
//     planUsage: { remaining, limit,                 // cents
//                  autoPercentUsed, apiPercentUsed, totalPercentUsed } }
// Maps to one "Included usage" window: percent = totalPercentUsed, dollars =
// (limit - remaining)/100 of limit/100, reset = billingCycleEnd, plus two
// indented sub-rows ("First-party models" and "API") mirroring Cursor's own
// expanded breakdown. Sub-rows carry sub:true and no resetsAt, so the
// dashboard renders them smaller and the Up-next pace math (which requires
// resetsAt) never counts them.
function normalizeCurrentPeriodUsage(raw) {
  if (!raw || typeof raw !== 'object' || !raw.planUsage || typeof raw.planUsage !== 'object') return [];
  const p = raw.planUsage;
  const total = num(p.totalPercentUsed);
  if (total == null) return [];
  const limit = num(Number(p.limit));
  const remaining = num(Number(p.remaining));
  const cycleEnd = Number(raw.billingCycleEnd);
  const auto = num(p.autoPercentUsed);
  const api = num(p.apiPercentUsed);
  const win = {
    id: 'included',
    label: 'Included usage',
    group: 'weekly',
    utilization: Math.round(total),
    resetsAt: isFinite(cycleEnd) && cycleEnd > 0 ? new Date(cycleEnd).toISOString() : null,
  };
  if (limit != null && limit > 0) {
    win.poolDollars = Math.round(limit) / 100;
    if (remaining != null) win.usedDollars = Math.round(limit - remaining) / 100;
  }
  const out = [win];
  if (auto != null) out.push({ id: 'first-party', label: 'First-party models', group: 'weekly', sub: true, utilization: Math.round(auto) });
  if (api != null) out.push({ id: 'api', label: 'API', group: 'weekly', sub: true, utilization: Math.round(api) });
  return out;
}

// Legacy fallback: turn whatever the old (undocumented, version-dependent)
// usage payload gives us into the same window shape. Defensive by design:
// unknown shapes yield [] rather than throwing, so the card falls back to its
// disk-only state.
function normalizeCursorUsage(raw, plan) {
  const windows = [];
  if (!raw || typeof raw !== 'object') return windows;

  // Monthly cycle reset, if present, applies to every window.
  const startOfMonth = raw.startOfMonth || raw.start_of_month || null;
  let resetsAt = null;
  if (startOfMonth) {
    const d = new Date(startOfMonth);
    if (!isNaN(d.getTime())) {
      // UTC methods, not local: startOfMonth is a UTC instant, and local
      // getMonth/setMonth would shift the rollover by a day in any non-UTC zone.
      d.setUTCMonth(d.getUTCMonth() + 1);
      resetsAt = d.toISOString();
    }
  }

  // Shape A (legacy request-based): top-level keys are model names mapping to
  // { numRequests, maxRequestUsage }. Percent = used / max when max is known.
  for (const key of Object.keys(raw)) {
    const v = raw[key];
    if (!v || typeof v !== 'object') continue;
    const used = num(v.numRequests) != null ? num(v.numRequests) : num(v.numRequestsTotal);
    if (used == null) continue;
    const max = num(v.maxRequestUsage);
    // No cap known and nothing used = an empty "gpt-4 / resets ..." row that
    // tells the user nothing. Skip it; the card's disk data still renders.
    if ((max == null || max <= 0) && used === 0) continue;
    const utilization = max && max > 0 ? Math.round((used / max) * 100) : null;
    windows.push({
      id: key,
      label: key,
      group: 'weekly',
      utilization: utilization,
      used: used,
      max: max,
      resetsAt: resetsAt,
    });
  }
  if (windows.length) return windows;

  // Shape B (credit-based): a spend figure against the plan's dollar pool.
  // We look for a few plausible field names; whichever exists wins.
  const spendCents =
    num(raw.spendCents) != null ? num(raw.spendCents) :
    num(raw.usageBasedSpendCents) != null ? num(raw.usageBasedSpendCents) : null;
  const spendDollars =
    spendCents != null ? spendCents / 100 :
    num(raw.spendDollars) != null ? num(raw.spendDollars) : null;
  if (spendDollars != null) {
    const poolFromPayload = num(raw.includedDollars) != null ? num(raw.includedDollars) : num(raw.hardLimitDollars);
    const pool = poolFromPayload != null && poolFromPayload > 0
      ? poolFromPayload
      : (plan ? CURSOR_POOL_USD[String(plan).toLowerCase()] : null);
    const utilization = pool && pool > 0 ? Math.round((spendDollars / pool) * 100) : null;
    windows.push({
      id: 'included',
      label: 'Included usage',
      group: 'weekly',
      utilization: utilization,
      usedDollars: Math.round(spendDollars * 100) / 100,
      poolDollars: pool || null,
      resetsAt: raw.billingCycleEnd || raw.resetsAt || resetsAt,
    });
  }
  return windows;
}

// ---------- Enterprise Admin API (lean, opt-in) ----------
//
// Only reachable for Cursor Enterprise teams, which the idle individual seats
// this feature targets almost never are. Implemented minimally: confirm the key
// works and report seat count, with detailed per-user usage left to the
// documented /teams/daily-usage-data endpoint the user can enable later. Basic
// auth = API key as username, blank password.
async function fetchAdminAccount(acct) {
  const auth = 'Basic ' + Buffer.from(acct.adminApiKey + ':').toString('base64');
  try {
    const res = await fetch('https://api.cursor.com/teams/members', {
      headers: { Authorization: auth, Accept: 'application/json', 'User-Agent': CHROME_UA },
    });
    if (!res.ok) {
      return baseAccount(acct, { ok: false, error: 'Admin API returned ' + res.status + ' (Enterprise plan + admin key required)' });
    }
    const body = await res.json().catch(() => null);
    const members = Array.isArray(body) ? body : body && Array.isArray(body.teamMembers) ? body.teamMembers : [];
    return baseAccount(acct, {
      ok: true,
      plan: 'Enterprise',
      note: members.length + ' seat' + (members.length === 1 ? '' : 's') + ' (Admin API connected)',
      windows: [],
    });
  } catch (e) {
    return baseAccount(acct, { ok: false, error: 'Admin API unreachable: ' + (e && e.message) });
  }
}

// ---------- per-account resolution ----------

function baseAccount(acct, extra) {
  return Object.assign(
    { label: acct.label, mode: acct.mode, userDataDir: acct.userDataDir || null, email: null, plan: null, ok: false, windows: [] },
    extra || {}
  );
}

async function fetchTokenAccount(acct) {
  const auth = await readAuthFromDb(acct.stateDb);
  if (!auth) {
    return baseAccount(acct, {
      ok: false,
      pending: true,
      error: IS_WIN
        ? "can't read Cursor token (sqlite3 not found on PATH)"
        : 'not signed in yet: click Open and log in to Cursor once',
    });
  }

  const email = auth['cursorAuth/cachedEmail'] || null;
  const membership = auth['cursorAuth/stripeMembershipType'] || null;
  const plan = planLabel(membership);
  const token = auth['cursorAuth/accessToken'];

  if (!token) {
    return baseAccount(acct, { email: email, plan: plan, ok: false, error: 'not logged in to Cursor in this profile' });
  }

  const claims = decodeJwt(token);
  const exp = claims && typeof claims.exp === 'number' ? claims.exp : null;
  const tokenExpiresAt = exp ? new Date(exp * 1000).toISOString() : null;
  const expired = exp ? exp * 1000 < Date.now() : false;

  if (expired) {
    return baseAccount(acct, {
      email: email,
      plan: plan,
      ok: false,
      expired: true,
      tokenExpiresAt: tokenExpiresAt,
      error: 'Cursor login expired: open Cursor for this account once and it refreshes automatically',
    });
  }

  const userId = userIdFromSub(claims && claims.sub);
  if (!userId) {
    return baseAccount(acct, { email: email, plan: plan, ok: true, tokenExpiresAt: tokenExpiresAt, windows: [], note: 'connected (no user id in token)' });
  }

  // Live usage is best-effort. Any failure leaves a valid, connected card.
  // Primary: the same endpoint Cursor's own dashboard renders (percent of the
  // included pool + Auto/API split). Fallback: the legacy per-model endpoint.
  const cookie = 'WorkosCursorSessionToken=' + encodeURIComponent(userId + '::' + token);
  try {
    let windows = [];
    try {
      const period = await fetchCursorJson('https://cursor.com/api/dashboard/get-current-period-usage', cookie, '{}');
      windows = normalizeCurrentPeriodUsage(period);
    } catch (e) {
      // fall through to legacy
    }
    if (!windows.length) {
      const raw = await fetchCursorJson('https://cursor.com/api/usage?user=' + encodeURIComponent(userId), cookie);
      windows = normalizeCursorUsage(raw, membership);
    }
    return baseAccount(acct, {
      email: email,
      plan: plan,
      ok: true,
      tokenExpiresAt: tokenExpiresAt,
      windows: windows,
      note: windows.length ? null : 'connected (usage shape not recognized yet)',
    });
  } catch (e) {
    return baseAccount(acct, {
      email: email,
      plan: plan,
      ok: true,
      tokenExpiresAt: tokenExpiresAt,
      windows: [],
      note: 'connected (usage unavailable: ' + (e && e.message ? e.message : 'unknown') + ')',
    });
  }
}

function fetchCursorAccount(acct) {
  return acct.mode === 'admin' ? fetchAdminAccount(acct) : fetchTokenAccount(acct);
}

// Public entry point used by the server. Never rejects: individual account
// failures are captured per-account.
async function fetchCursorAccounts() {
  const accounts = readAccountsConfig();
  if (!accounts.length) return [];
  const [settled, runningDirs] = await Promise.all([
    Promise.allSettled(accounts.map(fetchCursorAccount)),
    getRunningCursorDirs(),
  ]);
  return settled.map((r, i) => {
    const acct = accounts[i];
    const out = r.status === 'fulfilled'
      ? r.value
      : baseAccount(acct, { ok: false, error: String((r.reason && r.reason.message) || r.reason || 'unknown error') });
    out.running = Boolean(acct.userDataDir && runningDirs.has(path.resolve(acct.userDataDir)));
    return out;
  });
}

// ---------- mock fixtures (CLAUDE_DECK_MOCK=1) ----------

function mockCursorAccounts() {
  const hrs = (h) => new Date(Date.now() + h * 3600 * 1000).toISOString();
  return [
    {
      label: 'tech-c',
      mode: 'token',
      running: true,
      email: 'tech-c@partnerz.io',
      plan: 'Ultra',
      ok: true,
      tokenExpiresAt: hrs(24 * 40),
      windows: [
        { id: 'included', label: 'Included usage', group: 'weekly', utilization: 12, usedDollars: 48, poolDollars: 400, resetsAt: hrs(24 * 18) },
        { id: 'first-party', label: 'First-party models', group: 'weekly', sub: true, utilization: 9 },
        { id: 'api', label: 'API', group: 'weekly', sub: true, utilization: 3 },
      ],
    },
    {
      label: 'tech-nm',
      mode: 'token',
      running: false,
      email: 'tech-nm@partnerz.io',
      plan: 'Pro',
      ok: true,
      tokenExpiresAt: hrs(24 * 55),
      windows: [
        { id: 'included', label: 'Included usage', group: 'weekly', utilization: 83, usedDollars: 16.6, poolDollars: 20, resetsAt: hrs(24 * 3) },
      ],
    },
    {
      label: 'tech-dis',
      mode: 'token',
      running: false,
      email: 'tech-dis@partnerz.io',
      plan: 'Pro+',
      ok: false,
      expired: true,
      tokenExpiresAt: hrs(-24 * 5),
      error: 'Cursor login expired: open Cursor for this account once and it refreshes automatically',
      windows: [],
    },
    {
      label: 'tech-sub',
      mode: 'token',
      running: false,
      email: null,
      plan: null,
      ok: false,
      pending: true,
      error: 'not signed in yet: click Open and log in to Cursor once',
      windows: [],
    },
  ];
}

module.exports = {
  fetchCursorAccounts,
  mockCursorAccounts,
  readAccountsConfig,
  defaultCursorUserData,
  // exported for tests
  _internal: { normalizeCursorUsage, normalizeCurrentPeriodUsage, decodeJwt, userIdFromSub, planLabel, readAuthFromDb, normalizeAccountConfig },
};
