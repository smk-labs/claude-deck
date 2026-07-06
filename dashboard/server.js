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

const WINDOW_LABELS = {
  five_hour: 'Session (5h)',
  seven_day: 'Week (all models)',
  seven_day_opus: 'Week (Opus)',
  seven_day_sonnet: 'Week (Sonnet)',
};

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
  if (profile.orgId) return profile.orgId;
  const orgs = await fetchJson('https://claude.ai/api/organizations', profile.sessionKey);
  const list = Array.isArray(orgs) ? orgs : [];
  const chosen =
    list.find((o) => Array.isArray(o.capabilities) && o.capabilities.includes('chat')) || list[0];
  if (!chosen || !chosen.uuid) throw new Error('no organization found for this account');
  const orgId = chosen.uuid;
  // Re-read from disk right before writing: the injected app process may have
  // refreshed sessionKey concurrently, and merging into the stale `profile`
  // we read earlier would clobber that fresh key with the old one.
  const filePath = path.join(PROFILES_DIR, name + '.json');
  const current = readJsonSafe(filePath) || profile;
  const merged = Object.assign({}, current, { orgId });
  writeProfileJson(name, merged);
  return orgId;
}

function normalizeUsage(raw) {
  const windows = [];
  if (raw && typeof raw === 'object') {
    for (const id of Object.keys(WINDOW_LABELS)) {
      const w = raw[id];
      if (w == null) continue;
      const utilization = typeof w.utilization === 'number' ? w.utilization : null;
      const resetsAt = w.resets_at || w.resetsAt || null;
      if (utilization == null) continue;
      windows.push({ id, label: WINDOW_LABELS[id], utilization, resetsAt });
    }
  }
  return windows;
}

async function fetchUsageForProfile(name, profile) {
  const orgId = await ensureOrgId(name, profile);
  const raw = await fetchJson(
    'https://claude.ai/api/organizations/' + orgId + '/usage',
    profile.sessionKey
  );
  const windows = normalizeUsage(raw);
  return { name, running: false, ok: true, windows, raw };
}

// ---------- mock data ----------
// Believable fake fixtures for local dev / README screenshot (CLAUDE_DECK_MOCK=1).

const MOCK_FIXTURES = [
  { name: 'default', running: true, windows: [42, 58, 31, null] },
  { name: 'work', running: true, windows: [93, 81, 76, 64] },
  { name: 'research', running: false, windows: [12, 22, null, null] },
  { name: 'client-a', running: false, windows: [5, 15, null, 15] },
  { name: 'client-b', running: false, windows: [68, 70, null, null] },
  { name: 'expired', running: false, windows: null },
];

function mockProfiles() {
  const now = new Date().toISOString();
  return MOCK_FIXTURES.map((f) => ({ name: f.name, hasKey: true, updatedAt: now, running: f.running }));
}

function mockUsage() {
  const hrs = (h) => new Date(Date.now() + h * 3600 * 1000).toISOString();
  const resetOffsets = { five_hour: 2.5, seven_day: 96, seven_day_opus: 96, seven_day_sonnet: 96 };
  const ids = Object.keys(WINDOW_LABELS);
  const profiles = MOCK_FIXTURES.map((f) => {
    if (!f.windows) {
      return { name: f.name, running: f.running, ok: false, error: 'session key expired: open this profile once and it refreshes automatically' };
    }
    const windows = ids
      .map((id, i) => (f.windows[i] == null ? null : { id, label: WINDOW_LABELS[id], utilization: f.windows[i], resetsAt: hrs(resetOffsets[id]) }))
      .filter(Boolean);
    return { name: f.name, running: f.running, ok: true, windows };
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
