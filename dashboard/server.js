#!/usr/bin/env node
// Claude Deck dashboard server. Node >=18, stdlib only. Binds 127.0.0.1 only.
'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFile, spawn } = require('child_process');
const cursor = require('./cursor.js');

const IS_WIN = process.platform === 'win32';
// Port precedence: explicit CLAUDE_DECK_PORT, then a positional arg, then the
// conventional PORT env (honored by PaaS hosts and preview harnesses), then the
// 8965 default. PORT sits last so it never overrides an explicit choice.
const PORT =
  Number(process.env.CLAUDE_DECK_PORT) || Number(process.argv[2]) || Number(process.env.PORT) || 8965;
const MOCK = process.env.CLAUDE_DECK_MOCK === '1';
const PROFILES_DIR = path.join(os.homedir(), '.claude-deck', 'profiles');
const INDEX_HTML = path.join(__dirname, 'index.html');

const USAGE_CACHE = new Map(); // name -> { at, data }
const CACHE_MS = 120 * 1000;

let CURSOR_CACHE = null; // { at, data } for the /api/cursor response

const CHROME_UA =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 ' +
  '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

const PLAN_RULES = [
  ['20x', 'Max (20x)'],
  ['5x', 'Max (5x)'],
  ['pro', 'Pro'],
  ['team', 'Team'],
  ['enterprise', 'Enterprise'],
  ['free', 'Free'],
];

// ---------- dynamic window labeling ----------

function titleCase(s) {
  return s
    .split('_')
    .filter(Boolean)
    .map((w) => w.charAt(0).toUpperCase() + w.slice(1))
    .join(' ');
}

function labelFor(key) {
  if (key === 'five_hour') return 'Current session';
  if (key === 'seven_day') return 'All models';
  if (key.indexOf('seven_day_') === 0) return titleCase(key.slice('seven_day_'.length));
  return titleCase(key);
}

function groupFor(key) {
  if (key === 'five_hour') return 'session';
  if (key.indexOf('seven_day') === 0) return 'weekly';
  return 'other';
}

// Team orgs all report the same tier string, so the seat tier (from
// bootstrap) is what tells a premium seat from a standard one.
function planLabelFor(org, seatTier) {
  if (seatTier === 'team_tier_1') return 'Team premium';
  if (seatTier === 'team_standard') return 'Team standard';
  return planFor(org);
}

function planFor(org) {
  if (!org || typeof org !== 'object') return null;
  const fields = ['rate_limit_tier', 'billing_tier', 'plan', 'subscription'];
  for (const f of fields) {
    const v = org[f];
    if (typeof v === 'string' && v) {
      const lower = v.toLowerCase();
      for (const [needle, label] of PLAN_RULES) {
        if (lower.indexOf(needle) !== -1) return label;
      }
    }
  }
  return null;
}

// ---------- helpers ----------

function readJsonSafe(filePath) {
  try {
    return JSON.parse(fs.readFileSync(filePath, 'utf8'));
  } catch (e) {
    return null;
  }
}

function writeProfileJson(name, data) {
  try {
    fs.mkdirSync(PROFILES_DIR, { recursive: true, mode: 0o700 });
    const filePath = path.join(PROFILES_DIR, name + '.json');
    fs.writeFileSync(filePath, JSON.stringify(data, null, 2), { mode: 0o600 });
    // { mode } only applies when writeFileSync creates the file, so re-assert
    // it explicitly in case the file already existed with looser permissions.
    fs.chmodSync(filePath, 0o600);
  } catch (e) {
    // best effort, ignore
  }
}

function listProfileFiles() {
  try {
    return fs
      .readdirSync(PROFILES_DIR)
      .filter((f) => f.endsWith('.json'))
      .map((f) => path.join(PROFILES_DIR, f));
  } catch (e) {
    return [];
  }
}

function validName(name) {
  return typeof name === 'string' && /^[A-Za-z0-9_-]{1,32}$/.test(name);
}

// Pins live server-side (~/.claude-deck/pins.json) rather than in the
// browser's localStorage, which is keyed per origin: running the dashboard on
// a different port (e.g. when 8965 is busy) would otherwise silently drop the
// user's pins. A single file on the machine is the source of truth.
const PINS_FILE = path.join(os.homedir(), '.claude-deck', 'pins.json');
let MOCK_PINS = []; // in-memory pins for MOCK mode, so tests never touch real state

function readPins() {
  if (MOCK) return MOCK_PINS.slice();
  var data = readJsonSafe(PINS_FILE);
  var list = Array.isArray(data) ? data : data && Array.isArray(data.pins) ? data.pins : [];
  return list.filter(validName);
}

function writePins(list) {
  var clean = (Array.isArray(list) ? list : []).filter(validName);
  // De-dupe, preserve order.
  var seen = {};
  var out = [];
  clean.forEach(function (n) { if (!seen[n]) { seen[n] = 1; out.push(n); } });
  if (MOCK) { MOCK_PINS = out; return out; }
  try {
    fs.mkdirSync(path.dirname(PINS_FILE), { recursive: true });
    fs.writeFileSync(PINS_FILE, JSON.stringify({ pins: out }, null, 2));
  } catch (e) {
    // best effort
  }
  return out;
}

// Locates the claude-deck script so handleOpen can shell out to `open
// <name>` and pick up its self-healing session-index link instead of only
// ever launching the app directly. Checked in priority order: the canonical
// installed copy first, then the repo copy that sits next to this
// dashboard/ directory (covers running the dashboard straight from a git
// checkout, without `claude-deck install`). Returns null if neither exists,
// so the caller can fall back to the direct-launch path. On Windows the
// script is claude-deck.ps1; on macOS it is claude-deck.sh.
let _cachedScriptPath;
function findClaudeDeckScript() {
  if (_cachedScriptPath !== undefined) return _cachedScriptPath;
  const scriptName = IS_WIN ? 'claude-deck.ps1' : 'claude-deck.sh';
  const candidates = [
    path.join(os.homedir(), '.claude-deck', 'bin', scriptName),
    path.join(__dirname, '..', scriptName),
  ];
  for (const candidate of candidates) {
    try {
      if (fs.existsSync(candidate)) {
        _cachedScriptPath = candidate;
        return candidate;
      }
    } catch (e) {
      // keep checking remaining candidates
    }
  }
  _cachedScriptPath = null;
  return null;
}

function getRunningProfiles() {
  return new Promise((resolve) => {
    if (IS_WIN) {
      // Every Electron child process is also claude.exe on Windows, but
      // children always carry --type=<something> and never --profile=, so
      // filtering out --type= leaves one main process per running instance.
      execFile(
        'powershell.exe',
        [
          '-NoProfile',
          '-Command',
          "Get-CimInstance Win32_Process -Filter \"Name='claude.exe'\" | ForEach-Object { $_.CommandLine }",
        ],
        { maxBuffer: 4 * 1024 * 1024, windowsHide: true },
        (err, stdout) => {
          if (err || !stdout) return resolve(new Set());
          const running = new Set();
          for (const line of stdout.split(/\r?\n/)) {
            if (!/claude\.exe/i.test(line)) continue;
            if (line.includes('--type=')) continue;
            const match = line.match(/--profile=([A-Za-z0-9_-]{1,32})/);
            running.add(match ? match[1] : 'default');
          }
          resolve(running);
        }
      );
      return;
    }
    execFile('ps', ['ax', '-o', 'command'], { maxBuffer: 4 * 1024 * 1024 }, (err, stdout) => {
      if (err || !stdout) return resolve(new Set());
      const running = new Set();
      const lines = stdout.split('\n');
      for (const line of lines) {
        if (!line.includes('Claude.app/Contents/MacOS/Claude')) continue;
        const match = line.match(/--profile=([A-Za-z0-9_-]{1,32})/);
        if (match) {
          running.add(match[1]);
        } else {
          running.add('default');
        }
      }
      resolve(running);
    });
  });
}

// Newest Windows Claude install dir (%LOCALAPPDATA%\AnthropicClaude\app-*),
// used only as the direct-launch fallback when no claude-deck.ps1 is found.
function findClaudeExeWin() {
  try {
    const root = path.join(process.env.LOCALAPPDATA || '', 'AnthropicClaude');
    const dirs = fs
      .readdirSync(root)
      .filter((d) => d.startsWith('app-'))
      .sort((a, b) => {
        const pa = a.slice(4).split('.').map(Number);
        const pb = b.slice(4).split('.').map(Number);
        for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
          const diff = (pa[i] || 0) - (pb[i] || 0);
          if (diff) return diff;
        }
        return 0;
      });
    for (let i = dirs.length - 1; i >= 0; i--) {
      const exe = path.join(root, dirs[i], 'claude.exe');
      if (fs.existsSync(exe)) return exe;
    }
    return null;
  } catch (e) {
    return null;
  }
}

function fetchJson(url, cookie) {
  return fetch(url, {
    headers: {
      Cookie: 'sessionKey=' + cookie,
      'User-Agent': CHROME_UA,
      Accept: 'application/json',
      Referer: 'https://claude.ai/',
    },
  }).then(async (res) => {
    if (res.status === 401 || res.status === 403) {
      const e = new Error('session key expired: open this profile once and it refreshes automatically');
      e.authError = true;
      throw e;
    }
    if (!res.ok) {
      throw new Error('request failed with status ' + res.status);
    }
    return res.json();
  });
}

const ORGS_MAX_AGE_MS = 24 * 60 * 60 * 1000;

// Best-effort walk of the bootstrap payload looking for the account's email.
// Defensive because the bootstrap shape isn't documented and can change:
// null on any failure rather than throwing, since email is cosmetic (UI only).
function findEmail(node, depth) {
  if (!node || typeof node !== 'object' || depth > 6) return null;
  for (const key of Object.keys(node)) {
    const val = node[key];
    if (typeof val === 'string' && /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(val)) {
      if (/email/i.test(key)) return val;
    }
  }
  for (const key of Object.keys(node)) {
    const val = node[key];
    if (val && typeof val === 'object' && /account|user/i.test(key)) {
      const found = findEmail(val, depth + 1);
      if (found) return found;
    }
  }
  for (const key of Object.keys(node)) {
    const val = node[key];
    if (val && typeof val === 'object') {
      const found = findEmail(val, depth + 1);
      if (found) return found;
    }
  }
  return null;
}

// Bootstrap is the only place a Team org's seat tier lives: the org object
// itself reports the same rate_limit_tier ("default_raven") for every seat,
// but account.memberships[].seat_tier distinguishes team_tier_1 (premium)
// from team_standard. Verified against the live API.
async function fetchBootstrapInfo(sessionKey) {
  try {
    const bootstrap = await fetchJson('https://claude.ai/api/bootstrap', sessionKey);
    const seatTiers = {};
    const memberships =
      bootstrap && bootstrap.account && Array.isArray(bootstrap.account.memberships)
        ? bootstrap.account.memberships
        : [];
    for (const m of memberships) {
      if (m && m.organization && m.organization.uuid && m.seat_tier) {
        seatTiers[m.organization.uuid] = m.seat_tier;
      }
    }
    return { email: findEmail(bootstrap, 0), seatTiers };
  } catch (e) {
    return { email: null, seatTiers: {} };
  }
}

// Weekly-capacity multiplier relative to Pro (1x). Free is 0 so the client
// can drop those orgs from up-next. null = unknown tier (client treats as 1x
// and never filters it out).
function multiplierFor(org, seatTier) {
  const tier = String((org && org.rate_limit_tier) || '').toLowerCase();
  if (tier.indexOf('max_20x') !== -1) return 20;
  if (tier.indexOf('max_5x') !== -1) return 5;
  if (tier === 'default_raven' || (org && org.raven_type === 'team')) {
    if (seatTier === 'team_tier_1') return 6.25;
    if (seatTier === 'team_standard') return 1.25;
    return 1.25;
  }
  if (tier.indexOf('pro') !== -1) return 1;
  if (tier === 'default_claude_ai') return 0;
  return null;
}

// Replaces the old single-org ensureOrgId: a single login can belong to
// several organizations (e.g. two Team orgs + a personal Max org), each with
// its own independent usage pool, so every chat-capable org is kept.
async function ensureAccount(name, profile) {
  const cachedOrgs = Array.isArray(profile.orgs) ? profile.orgs : null;
  const fetchedAt = profile.orgsFetchedAt ? new Date(profile.orgsFetchedAt).getTime() : 0;
  const isFresh =
    cachedOrgs &&
    cachedOrgs.length > 0 &&
    Date.now() - fetchedAt < ORGS_MAX_AGE_MS &&
    // Cache written before multiplier existed: refetch so it gets one.
    cachedOrgs.every((o) => o.multiplier !== undefined);

  if (isFresh) {
    return { orgs: cachedOrgs, email: profile.email || null };
  }

  let orgs = cachedOrgs;
  let email = profile.email || null;
  try {
    const rawOrgs = await fetchJson('https://claude.ai/api/organizations', profile.sessionKey);
    const list = Array.isArray(rawOrgs) ? rawOrgs : [];
    const chatCapable = list.filter(
      (o) => !Array.isArray(o.capabilities) || o.capabilities.includes('chat')
    );
    const kept = chatCapable.length ? chatCapable : list;
    const boot = await fetchBootstrapInfo(profile.sessionKey);
    orgs = kept
      .filter((o) => o && o.uuid)
      .map((o) => {
        const seatTier = boot.seatTiers[o.uuid] || null;
        return {
          id: o.uuid,
          name: o.name || o.uuid,
          plan: planLabelFor(o, seatTier),
          multiplier: multiplierFor(o, seatTier),
        };
      });
    if (!orgs.length) throw new Error('no organization found for this account');
    email = boot.email;
  } catch (e) {
    // A failed refetch must not wipe a cached list: fall back to it if present.
    if (cachedOrgs && cachedOrgs.length) {
      return { orgs: cachedOrgs, email: profile.email || null };
    }
    throw e;
  }

  // Re-read from disk right before writing: the injected app process may have
  // refreshed sessionKey concurrently, and merging into the stale `profile`
  // we read earlier would clobber that fresh key with the old one.
  const filePath = path.join(PROFILES_DIR, name + '.json');
  const current = readJsonSafe(filePath) || profile;
  const merged = Object.assign({}, current, {
    orgs,
    email,
    orgsFetchedAt: new Date().toISOString(),
  });
  writeProfileJson(name, merged);
  return { orgs, email };
}

// The modern /usage payload carries a canonical `limits` array: exactly the
// rows the Claude app itself renders. Each entry:
//   { kind, group, percent, severity, resets_at, is_active,
//     scope: { model: { display_name }, surface } }
// We prefer it verbatim. It is the ground truth (confirmed against the live
// API): a scoped per-model weekly limit like "Fable" appears ONLY here, as
// kind "weekly_scoped" with scope.model.display_name, never as a flat key.
function windowsFromLimits(limits) {
  const out = [];
  for (const lim of limits) {
    if (!lim || typeof lim !== 'object') continue;
    if (typeof lim.percent !== 'number') continue;
    out.push({
      id: lim.kind || 'limit',
      label: labelForLimit(lim),
      group: lim.group === 'session' || lim.group === 'weekly' ? lim.group : 'other',
      utilization: lim.percent,
      resetsAt: lim.resets_at || lim.resetsAt || null,
    });
  }
  return out;
}

function labelForLimit(lim) {
  if (lim.kind === 'session') return 'Current session';
  if (lim.kind === 'weekly_all') return 'All models';
  if (lim.kind === 'weekly_scoped') {
    const model = lim.scope && lim.scope.model && lim.scope.model.display_name;
    if (model) return model;
    const surface = lim.scope && lim.scope.surface;
    if (surface) return titleCase(String(surface));
    return 'Weekly (scoped)';
  }
  return titleCase(String(lim.kind || 'limit'));
}

// Legacy fallback for older payloads that lack `limits`. Scans flat top-level
// keys for real quota objects. Skips dollar-denominated caps (extra-usage /
// credit pools like `amber_ladder`, which carry limit_dollars and are NOT the
// plan quotas the app shows) and null placeholder codename keys.
function scanWindows(container) {
  const windows = [];
  if (!container || typeof container !== 'object') return windows;
  for (const key of Object.keys(container)) {
    const val = container[key];
    if (!val || typeof val !== 'object') continue;
    if (typeof val.utilization !== 'number') continue;
    if (val.limit_dollars != null || val.used_dollars != null) continue;
    windows.push({
      id: key,
      label: labelFor(key),
      group: groupFor(key),
      utilization: val.utilization,
      resetsAt: val.resets_at || val.resetsAt || null,
    });
  }
  return windows;
}

const GROUP_ORDER = { session: 0, weekly: 1, other: 2 };

function normalizeUsage(raw) {
  let windows = [];
  // Preferred: the canonical limits array the app renders.
  if (raw && typeof raw === 'object' && Array.isArray(raw.limits) && raw.limits.length > 0) {
    windows = windowsFromLimits(raw.limits);
  }
  // Fallback: legacy flat keys (older app/API without `limits`).
  if (windows.length === 0) {
    windows = scanWindows(raw);
    if (windows.length === 0 && raw && typeof raw === 'object' && raw.usage) {
      windows = scanWindows(raw.usage);
    }
  }
  // Stable sort: session first, then weekly (payload order), then others
  // (payload order). Array.prototype.sort is stable in Node >=18.
  const orderOf = (g) => (Object.prototype.hasOwnProperty.call(GROUP_ORDER, g) ? GROUP_ORDER[g] : 2);
  windows.sort((a, b) => orderOf(a.group) - orderOf(b.group));
  return windows;
}

async function fetchUsageForOrg(org, sessionKey) {
  try {
    const raw = await fetchJson(
      'https://claude.ai/api/organizations/' + org.id + '/usage',
      sessionKey
    );
    const windows = normalizeUsage(raw);
    return { id: org.id, name: org.name, plan: org.plan, multiplier: org.multiplier !== undefined ? org.multiplier : null, ok: true, windows };
  } catch (e) {
    return { id: org.id, name: org.name, plan: org.plan, multiplier: org.multiplier !== undefined ? org.multiplier : null, ok: false, error: e.message };
  }
}

async function fetchUsageForProfile(name, profile) {
  const { orgs, email } = await ensureAccount(name, profile);
  const results = await Promise.allSettled(
    orgs.map((org) => fetchUsageForOrg(org, profile.sessionKey))
  );
  const orgResults = results.map((r, i) => {
    if (r.status === 'fulfilled') return r.value;
    const org = orgs[i];
    return { id: org.id, name: org.name, plan: org.plan, multiplier: org.multiplier !== undefined ? org.multiplier : null, ok: false, error: String((r.reason && r.reason.message) || r.reason || 'unknown error') };
  });
  return { name, email, running: false, ok: true, orgs: orgResults };
}

// ---------- mock data ----------
// Believable fake fixtures for local dev / README screenshot (CLAUDE_DECK_MOCK=1).

// Each org's `raw` mimics the shape the real /usage endpoint returns:
// a flat object of window-key -> { utilization, resets_at }. This is what
// exercises the dynamic scan in normalizeUsage (fable + a novel future key
// prove unknown buckets render without any code change).
const MOCK_FIXTURES = [
  {
    name: 'default',
    running: true,
    email: 'claude.convi@partnerz.io',
    orgs: [
      {
        id: 'org-partnerz',
        name: 'Partnerz',
        plan: 'Team premium',
        multiplier: 6.25,
        raw: {
          five_hour: { utilization: 45, resets_hrs: 2.02 },
          seven_day: { utilization: 15, resets_hrs: 96 },
          seven_day_fable: { utilization: 17, resets_hrs: 96 },
        },
      },
      {
        id: 'org-partnerz-2',
        name: 'Partnerz-2',
        plan: 'Team standard',
        multiplier: 1.25,
        // Headroom trap: session is wide open (8%) and "All models" is fine
        // (30%), but the scoped Fable limit is maxed at 100%. Proves the
        // headroom predicate looks at EVERY weekly bucket, not just the
        // all-models one. Amber tier fixture: weekly reset ~9h out.
        raw: {
          five_hour: { utilization: 8, resets_hrs: 4.4 },
          seven_day: { utilization: 30, resets_hrs: 9 },
          seven_day_fable: { utilization: 100, resets_hrs: 9 },
        },
      },
      {
        id: 'org-personal',
        name: 'Personal',
        plan: 'Max (20x)',
        multiplier: 20,
        raw: {
          five_hour: { utilization: 93, resets_hrs: 0.68 },
          seven_day: { utilization: 81, resets_hrs: 40 },
          seven_day_opus: { utilization: 76, resets_hrs: 40 },
          // Novel, not-yet-announced bucket: proves unknown keys still render.
          seven_day_haiku: { utilization: 9, resets_hrs: 40 },
        },
      },
    ],
  },
  {
    name: 'research',
    running: false,
    email: 'research@example.com',
    orgs: [
      {
        id: 'org-research',
        name: 'Research Co',
        plan: 'Pro',
        multiplier: 1,
        raw: {
          five_hour: { utilization: 12, resets_hrs: 4.5 },
          // Default (neutral) tier fixture: weekly reset ~2d out (48h+).
          seven_day: { utilization: 22, resets_hrs: 48 },
        },
      },
    ],
  },
  {
    name: 'client-a',
    running: false,
    email: 'client-a@example.com',
    orgs: [
      {
        id: 'org-client-a',
        name: 'Client A',
        plan: null,
        multiplier: null,
        raw: {
          five_hour: { utilization: 5, resets_hrs: 1.1 },
          // Red tier fixture: weekly reset ~3h out (under 4h, use-it-or-lose-it).
          seven_day: { utilization: 15, resets_hrs: 3 },
          seven_day_sonnet: { utilization: 15, resets_hrs: 3 },
          // A wholly new, unrecognized top-level bucket outside the seven_day_* family.
          monthly_extra: { utilization: 3, resets_hrs: 400 },
        },
      },
    ],
  },
  {
    name: 'client-b',
    running: false,
    email: 'client-b@example.com',
    // Multi-org profile where one org errors while the other still works:
    // proves per-org error isolation (profile.ok stays true).
    orgs: [
      {
        id: 'org-client-b-main',
        name: 'Client B',
        plan: 'Team',
        raw: {
          five_hour: { utilization: 68, resets_hrs: 3.25 },
          seven_day: { utilization: 70, resets_hrs: 60 },
        },
      },
      {
        id: 'org-client-b-sandbox',
        name: 'Client B Sandbox',
        plan: 'Pro',
        error: 'request failed with status 500',
      },
    ],
  },
  { name: 'expired', running: false, email: null, orgs: null },
];

function mockProfiles() {
  const now = new Date().toISOString();
  return MOCK_FIXTURES.map((f) => ({ name: f.name, hasKey: true, updatedAt: now, running: f.running }));
}

function mockUsage() {
  const hrs = (h) => new Date(Date.now() + h * 3600 * 1000).toISOString();
  const profiles = MOCK_FIXTURES.map((f) => {
    if (!f.orgs) {
      return { name: f.name, email: f.email, running: f.running, ok: false, error: 'session key expired: open this profile once and it refreshes automatically' };
    }
    const orgs = f.orgs.map((org) => {
      if (org.error) {
        return { id: org.id, name: org.name, plan: org.plan, multiplier: org.multiplier !== undefined ? org.multiplier : null, ok: false, error: org.error };
      }
      // Build the real dual shape: legacy flat keys AND the canonical `limits`
      // array the live API returns (and the app renders). normalizeUsage
      // prefers `limits`, so this exercises the primary path.
      const rawWithTimestamps = {};
      const limits = [];
      for (const key of Object.keys(org.raw)) {
        const w = org.raw[key];
        const resets_at = hrs(w.resets_hrs);
        rawWithTimestamps[key] = { utilization: w.utilization, resets_at: resets_at };
        if (key === 'five_hour') {
          limits.push({ kind: 'session', group: 'session', percent: w.utilization, resets_at: resets_at });
        } else if (key === 'seven_day') {
          limits.push({ kind: 'weekly_all', group: 'weekly', percent: w.utilization, resets_at: resets_at });
        } else if (key.indexOf('seven_day_') === 0) {
          limits.push({ kind: 'weekly_scoped', group: 'weekly', percent: w.utilization, resets_at: resets_at, scope: { model: { display_name: titleCase(key.slice('seven_day_'.length)) } } });
        } else {
          limits.push({ kind: key, group: 'other', percent: w.utilization, resets_at: resets_at });
        }
      }
      rawWithTimestamps.limits = limits;
      const windows = normalizeUsage(rawWithTimestamps);
      return { id: org.id, name: org.name, plan: org.plan, multiplier: org.multiplier !== undefined ? org.multiplier : null, ok: true, windows };
    });
    return { name: f.name, email: f.email, running: f.running, ok: true, orgs: orgs };
  });
  return { fetchedAt: new Date().toISOString(), profiles };
}

// ---------- route handlers ----------

async function handleProfiles(req, res) {
  if (MOCK) return sendJson(res, 200, mockProfiles());
  const running = await getRunningProfiles();
  const files = listProfileFiles();
  const profiles = files.map((filePath) => {
    const data = readJsonSafe(filePath) || {};
    const name = path.basename(filePath, '.json');
    return {
      name,
      hasKey: Boolean(data.sessionKey),
      updatedAt: data.updatedAt || null,
      running: running.has(name),
    };
  });
  sendJson(res, 200, profiles);
}

async function handleUsage(req, res, query) {
  if (MOCK) return sendJson(res, 200, mockUsage());

  const fresh = query.get('fresh') === '1';
  const running = await getRunningProfiles();
  const files = listProfileFiles();

  const results = await Promise.allSettled(
    files.map(async (filePath) => {
      const name = path.basename(filePath, '.json');
      const profile = readJsonSafe(filePath);
      const isRunning = running.has(name);
      if (!profile || !profile.sessionKey) {
        return { name, running: isRunning, ok: false, error: 'no session key on file yet' };
      }

      const cached = USAGE_CACHE.get(name);
      if (!fresh && cached && Date.now() - cached.at < CACHE_MS) {
        return Object.assign({}, cached.data, { running: isRunning });
      }

      try {
        const data = await fetchUsageForProfile(name, profile);
        data.running = isRunning;
        USAGE_CACHE.set(name, { at: Date.now(), data });
        return data;
      } catch (e) {
        const errData = { name, running: isRunning, ok: false, error: e.message };
        USAGE_CACHE.set(name, { at: Date.now(), data: errData });
        return errData;
      }
    })
  );

  const profiles = results.map((r, i) => {
    if (r.status === 'fulfilled') return r.value;
    const name = path.basename(files[i], '.json');
    return { name, running: false, ok: false, error: r.reason ? String(r.reason.message || r.reason) : 'unknown error' };
  });

  sendJson(res, 200, { fetchedAt: new Date().toISOString(), profiles });
}

// Cursor accounts are a separate resource from Claude profiles (different
// vendor, different auth, no launch/pin semantics), so they get their own
// route and their own dashboard section rather than being folded into the
// Claude profile list. Cached like usage, and cheap-first: an empty account
// list (nobody configured any, no Cursor install) returns [] so the UI can
// simply hide the section.
async function handleCursor(req, res, query) {
  if (MOCK) return sendJson(res, 200, { fetchedAt: new Date().toISOString(), accounts: cursor.mockCursorAccounts() });

  const fresh = query.get('fresh') === '1';
  if (!fresh && CURSOR_CACHE && Date.now() - CURSOR_CACHE.at < CACHE_MS) {
    return sendJson(res, 200, CURSOR_CACHE.data);
  }
  const accounts = await cursor.fetchCursorAccounts();
  const data = { fetchedAt: new Date().toISOString(), accounts };
  CURSOR_CACHE = { at: Date.now(), data };
  sendJson(res, 200, data);
}

// Open (or focus) a Cursor account's window. Mirrors handleOpen for Claude
// profiles: named accounts launch with their --user-data-dir, the default
// install launches plain. `open -na` on an already-running profile hands off
// to that instance's lock and focuses it, so one code path covers both.
function handleCursorOpen(req, res) {
  let body = '';
  let tooLarge = false;
  req.on('data', (chunk) => {
    body += chunk;
    if (body.length > 1024) { tooLarge = true; req.destroy(); }
  });
  req.on('end', () => {
    if (tooLarge) return sendJson(res, 413, { ok: false, error: 'body too large' });
    if (MOCK) return sendJson(res, 200, { ok: true });
    if (IS_WIN) return sendJson(res, 501, { ok: false, error: 'not supported on Windows yet' });

    let parsed;
    try { parsed = JSON.parse(body || '{}'); } catch (e) {
      return sendJson(res, 400, { ok: false, error: 'invalid JSON' });
    }
    const label = parsed.label;
    if (!validName(label)) return sendJson(res, 400, { ok: false, error: 'invalid account label' });

    const acct = cursor.readAccountsConfig().find((a) => a.label === label && a.mode === 'token');
    if (!acct || !acct.userDataDir) return sendJson(res, 404, { ok: false, error: 'unknown Cursor account' });

    const isDefaultDir = path.resolve(acct.userDataDir) === path.resolve(cursor.defaultCursorUserData());
    const args = isDefaultDir
      ? ['-a', 'Cursor']
      : ['-na', 'Cursor', '--args', '--user-data-dir', acct.userDataDir];
    execFile('open', args, (err) => {
      if (err) return sendJson(res, 500, { ok: false, error: 'failed to launch Cursor' });
      sendJson(res, 200, { ok: true });
    });
  });
}

function handleOpen(req, res) {
  let body = '';
  let tooLarge = false;
  req.on('data', (chunk) => {
    body += chunk;
    if (body.length > 1024) {
      tooLarge = true;
      req.destroy();
    }
  });
  req.on('end', async () => {
    if (tooLarge) return sendJson(res, 413, { ok: false, error: 'body too large' });
    if (MOCK) return sendJson(res, 200, { ok: true });

    let parsed;
    try {
      parsed = JSON.parse(body || '{}');
    } catch (e) {
      return sendJson(res, 400, { ok: false, error: 'invalid JSON' });
    }

    const name = parsed.name;
    if (!validName(name)) {
      return sendJson(res, 400, { ok: false, error: 'invalid profile name' });
    }

    const running = await getRunningProfiles();
    if (running.has(name)) {
      // Already running: never spawn a duplicate on the same userData dir.
      if (IS_WIN) {
        // No reliable cross-window activate on Windows without extra deps.
        return sendJson(res, 200, { ok: true, activated: true });
      }
      execFile('osascript', ['-e', 'tell application "Claude" to activate'], () => {
        sendJson(res, 200, { ok: true, activated: true });
      });
      return;
    }

    // Prefer routing through the claude-deck script's own `open` subcommand
    // (for BOTH named profiles and default), so a dashboard-initiated launch
    // reuses the exact CLI logic: self-heals the session-index link for
    // named profiles, and forces a fresh instance for a not-running default.
    // Falls back to a direct launch if no installed script is found.
    const script = findClaudeDeckScript();
    if (script) {
      const cmd = IS_WIN ? 'powershell.exe' : '/bin/bash';
      const cmdArgs = IS_WIN
        ? ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script, 'open', name]
        : [script, 'open', name];
      return execFile(cmd, cmdArgs, { windowsHide: true }, (err) => {
        if (err) return sendJson(res, 500, { ok: false, error: 'failed to launch Claude' });
        sendJson(res, 200, { ok: true });
      });
    }

    if (IS_WIN) {
      // Fallback (no script): launch the newest installed claude.exe
      // directly, detached (waiting for the app to exit would hang this
      // response forever).
      const exe = findClaudeExeWin();
      if (!exe) return sendJson(res, 500, { ok: false, error: 'Claude install not found' });
      const exeArgs = name === 'default' ? [] : ['--profile=' + name];
      try {
        const child = spawn(exe, exeArgs, { detached: true, stdio: 'ignore' });
        child.unref();
        return sendJson(res, 200, { ok: true });
      } catch (e) {
        return sendJson(res, 500, { ok: false, error: 'failed to launch Claude' });
      }
    }

    // Fallback (no script, macOS): reached only when the profile is NOT
    // running (the running check above returned early). A not-running
    // default still needs -n to force a new instance, otherwise `open -a
    // Claude` just focuses whatever profiled instance is already up and
    // default never launches. Named profiles launch through Claude's
    // built-in CLAUDE_USER_DATA_DIR hook (mirrors cmd_open: works on a
    // patched and an unpatched app; `open` forwards the environment, and
    // the --profile flag stays for getRunningProfiles and, while patched,
    // the injected title/exporter label).
    const args =
      name === 'default'
        ? ['-n', '-a', 'Claude']
        : ['-n', '-a', 'Claude', '--args', '--profile=' + name];
    const opts =
      name === 'default'
        ? {}
        : {
            env: {
              ...process.env,
              CLAUDE_USER_DATA_DIR: path.join(
                os.homedir(),
                'Library',
                'Application Support',
                'Claude Profiles',
                name
              ),
            },
          };
    execFile('open', args, opts, (err) => {
      if (err) return sendJson(res, 500, { ok: false, error: 'failed to launch Claude' });
      sendJson(res, 200, { ok: true });
    });
  });
}

// ---------- plumbing ----------

function sendJson(res, status, data) {
  const body = JSON.stringify(data);
  res.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
  });
  res.end(body);
}

function serveIndex(res) {
  fs.readFile(INDEX_HTML, (err, data) => {
    if (err) {
      res.writeHead(500, { 'Content-Type': 'text/plain' });
      return res.end('index.html not found');
    }
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(data);
  });
}

const ALLOWED_HOST_RE = /^(127\.0\.0\.1|localhost)(:\d+)?$/;

const server = http.createServer((req, res) => {
  // Reject cross-origin/DNS-rebinding requests: a page on some other host
  // can still point a browser at 127.0.0.1, but it can't forge the Host
  // header the browser sends, so this blocks drive-by requests from other
  // origins while leaving normal same-machine use untouched.
  const host = req.headers.host || '';
  if (!ALLOWED_HOST_RE.test(host)) {
    return sendJson(res, 403, { error: 'forbidden host' });
  }

  const url = new URL(req.url, 'http://127.0.0.1');

  if (req.method === 'GET' && url.pathname === '/') {
    return serveIndex(res);
  }
  if (req.method === 'GET' && url.pathname === '/api/profiles') {
    return handleProfiles(req, res).catch((e) => sendJson(res, 500, { error: String(e.message || e) }));
  }
  if (req.method === 'GET' && url.pathname === '/api/usage') {
    return handleUsage(req, res, url.searchParams).catch((e) =>
      sendJson(res, 500, { error: String(e.message || e) })
    );
  }
  if (req.method === 'GET' && url.pathname === '/api/cursor') {
    return handleCursor(req, res, url.searchParams).catch((e) =>
      sendJson(res, 500, { error: String(e.message || e) })
    );
  }
  if (req.method === 'GET' && url.pathname === '/api/pins') {
    return sendJson(res, 200, { pins: readPins() });
  }
  if (req.method === 'POST' && url.pathname === '/api/pins') {
    if (req.headers['x-claude-deck'] !== '1') {
      return sendJson(res, 403, { ok: false, error: 'forbidden' });
    }
    let body = '';
    let tooLarge = false;
    req.on('data', (chunk) => {
      body += chunk;
      if (body.length > 8192) { tooLarge = true; req.destroy(); }
    });
    req.on('end', () => {
      if (tooLarge) return sendJson(res, 413, { ok: false, error: 'body too large' });
      let parsed;
      try { parsed = JSON.parse(body || '{}'); } catch (e) {
        return sendJson(res, 400, { ok: false, error: 'invalid JSON' });
      }
      const pins = writePins(parsed && parsed.pins);
      sendJson(res, 200, { ok: true, pins });
    });
    return;
  }
  if (req.method === 'POST' && url.pathname === '/api/cursor/open') {
    if (req.headers['x-claude-deck'] !== '1') {
      return sendJson(res, 403, { ok: false, error: 'forbidden' });
    }
    return handleCursorOpen(req, res);
  }
  if (req.method === 'POST' && url.pathname === '/api/open') {
    // State-changing route: also require a custom header the dashboard page
    // sets. A cross-site "no-cors" request (the only kind a random website
    // can fire at 127.0.0.1) cannot set custom headers, so this blocks CSRF
    // even from a page that gets the Host check right via DNS rebinding.
    if (req.headers['x-claude-deck'] !== '1') {
      return sendJson(res, 403, { ok: false, error: 'forbidden' });
    }
    return handleOpen(req, res);
  }

  sendJson(res, 404, { error: 'not found' });
});

server.listen(PORT, '127.0.0.1', () => {
  console.log('Claude Deck dashboard listening on http://127.0.0.1:' + PORT + (MOCK ? ' (mock mode)' : ''));
});
