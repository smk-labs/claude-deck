#!/usr/bin/env node
// Claude Deck dashboard server. Node >=18, stdlib only. Binds 127.0.0.1 only.
'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFile } = require('child_process');

const PORT = Number(process.env.CLAUDE_DECK_PORT) || Number(process.argv[2]) || 8965;
const MOCK = process.env.CLAUDE_DECK_MOCK === '1';
const PROFILES_DIR = path.join(os.homedir(), '.claude-deck', 'profiles');
const INDEX_HTML = path.join(__dirname, 'index.html');

const USAGE_CACHE = new Map(); // name -> { at, data }
const CACHE_MS = 120 * 1000;

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

function getRunningProfiles() {
  return new Promise((resolve) => {
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

async function ensureOrgId(name, profile) {
  if (profile.orgId) return { orgId: profile.orgId, plan: profile.plan || null };
  const orgs = await fetchJson('https://claude.ai/api/organizations', profile.sessionKey);
  const list = Array.isArray(orgs) ? orgs : [];
  const chosen =
    list.find((o) => Array.isArray(o.capabilities) && o.capabilities.includes('chat')) || list[0];
  if (!chosen || !chosen.uuid) throw new Error('no organization found for this account');
  const orgId = chosen.uuid;
  const plan = planFor(chosen);
  // Re-read from disk right before writing: the injected app process may have
  // refreshed sessionKey concurrently, and merging into the stale `profile`
  // we read earlier would clobber that fresh key with the old one.
  const filePath = path.join(PROFILES_DIR, name + '.json');
  const current = readJsonSafe(filePath) || profile;
  const merged = Object.assign({}, current, { orgId, plan });
  writeProfileJson(name, merged);
  return { orgId, plan };
}

// Scans one level of an object for { utilization: number } entries and turns
// them into windows. Order follows Object.keys insertion order (payload order).
function scanWindows(container) {
  const windows = [];
  if (!container || typeof container !== 'object') return windows;
  for (const key of Object.keys(container)) {
    const val = container[key];
    if (!val || typeof val !== 'object') continue;
    if (typeof val.utilization !== 'number') continue;
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
  let windows = scanWindows(raw);
  // Nothing at top level: fall back to a plausible nested container.
  if (windows.length === 0 && raw && typeof raw === 'object' && raw.usage) {
    windows = scanWindows(raw.usage);
  }
  // Stable sort: session first, then weekly (payload order), then others
  // (payload order). Array.prototype.sort is stable in Node >=18.
  const orderOf = (g) => (Object.prototype.hasOwnProperty.call(GROUP_ORDER, g) ? GROUP_ORDER[g] : 2);
  windows.sort((a, b) => orderOf(a.group) - orderOf(b.group));
  return windows;
}

async function fetchUsageForProfile(name, profile) {
  const { orgId, plan } = await ensureOrgId(name, profile);
  const raw = await fetchJson(
    'https://claude.ai/api/organizations/' + orgId + '/usage',
    profile.sessionKey
  );
  const windows = normalizeUsage(raw);
  return { name, running: false, ok: true, plan, windows, raw };
}

// ---------- mock data ----------
// Believable fake fixtures for local dev / README screenshot (CLAUDE_DECK_MOCK=1).

// Each fixture's `raw` mimics the shape the real /usage endpoint returns:
// a flat object of window-key -> { utilization, resets_at }. This is what
// exercises the dynamic scan in normalizeUsage (fable + a novel future key
// prove unknown buckets render without any code change).
const MOCK_FIXTURES = [
  {
    name: 'default',
    running: true,
    plan: 'Max (20x)',
    raw: {
      five_hour: { utilization: 45, resets_hrs: 2.02 },
      seven_day: { utilization: 15, resets_hrs: 96 },
      seven_day_fable: { utilization: 17, resets_hrs: 96 },
    },
  },
  {
    name: 'work',
    running: true,
    plan: 'Max (20x)',
    raw: {
      five_hour: { utilization: 93, resets_hrs: 0.68 },
      seven_day: { utilization: 81, resets_hrs: 40 },
      seven_day_opus: { utilization: 76, resets_hrs: 40 },
      // Novel, not-yet-announced bucket: proves unknown keys still render.
      seven_day_haiku: { utilization: 9, resets_hrs: 40 },
    },
  },
  {
    name: 'research',
    running: false,
    plan: 'Pro',
    raw: {
      five_hour: { utilization: 12, resets_hrs: 4.5 },
      seven_day: { utilization: 22, resets_hrs: 150 },
    },
  },
  {
    name: 'client-a',
    running: false,
    plan: null,
    raw: {
      five_hour: { utilization: 5, resets_hrs: 1.1 },
      seven_day: { utilization: 15, resets_hrs: 20 },
      seven_day_sonnet: { utilization: 15, resets_hrs: 20 },
      // A wholly new, unrecognized top-level bucket outside the seven_day_* family.
      monthly_extra: { utilization: 3, resets_hrs: 400 },
    },
  },
  {
    name: 'client-b',
    running: false,
    plan: 'Team',
    raw: {
      five_hour: { utilization: 68, resets_hrs: 3.25 },
      seven_day: { utilization: 70, resets_hrs: 60 },
    },
  },
  { name: 'expired', running: false, plan: null, raw: null },
];

function mockProfiles() {
  const now = new Date().toISOString();
  return MOCK_FIXTURES.map((f) => ({ name: f.name, hasKey: true, updatedAt: now, running: f.running }));
}

function mockUsage() {
  const hrs = (h) => new Date(Date.now() + h * 3600 * 1000).toISOString();
  const profiles = MOCK_FIXTURES.map((f) => {
    if (!f.raw) {
      return { name: f.name, running: f.running, ok: false, error: 'session key expired: open this profile once and it refreshes automatically' };
    }
    const rawWithTimestamps = {};
    for (const key of Object.keys(f.raw)) {
      const w = f.raw[key];
      rawWithTimestamps[key] = { utilization: w.utilization, resets_at: hrs(w.resets_hrs) };
    }
    const windows = normalizeUsage(rawWithTimestamps);
    return { name: f.name, running: f.running, ok: true, plan: f.plan, windows };
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
      // Already running: best-effort activate instead of spawning a duplicate.
      execFile('osascript', ['-e', 'tell application "Claude" to activate'], () => {
        sendJson(res, 200, { ok: true, activated: true });
      });
      return;
    }

    const args =
      name === 'default' ? ['-a', 'Claude'] : ['-n', '-a', 'Claude', '--args', '--profile=' + name];
    execFile('open', args, (err) => {
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
