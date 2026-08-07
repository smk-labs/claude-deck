// Proxy-aware fetch for the dashboard. Node >=18, stdlib only.
//
// Why this file exists: Node's global fetch (undici) ignores HTTP_PROXY /
// HTTPS_PROXY and knows nothing about the macOS system proxy. On a machine that
// can only reach claude.ai through a local proxy, every dashboard request dies
// as a bare "fetch failed" (a connect timeout, not an auth error) while Claude
// Desktop itself works fine, because Chromium does honor the system proxy. The
// symptom is a dashboard where every profile and every org is empty and nothing
// says why. Confirmed live: curl (honors the env vars) reached claude.ai while
// node's fetch timed out against the same host in the same shell.
//
// Adding a proxy-agent package for this would be a permanent supply-chain and
// maintenance cost for ~90 lines of CONNECT, so it is written out here instead.
// Scope is deliberately small: HTTP(S) proxies via CONNECT, which is what every
// local proxy on this path speaks. SOCKS-only setups fall through to the plain
// path and fail the same way they do today.
'use strict';

const http = require('http');
const https = require('https');
const net = require('net');
const tls = require('tls');
const { execFileSync } = require('child_process');

// ---------- proxy resolution ----------

let SYSTEM_PROXY = undefined; // undefined = not looked up yet, null = none

// Neither OS keeps the system proxy in the environment, so a dashboard launched
// from anything but a configured shell sees no env vars at all. These read the
// same sources the browser engine reads: the macOS dynamic store, and the
// Windows WinINET settings the Internet Options dialog writes.
function systemProxyMac() {
  const out = execFileSync('scutil', ['--proxy'], { encoding: 'utf8', timeout: 5000 });
  const field = (key) => {
    const m = out.match(new RegExp('^\\s*' + key + '\\s*:\\s*(\\S+)\\s*$', 'm'));
    return m ? m[1] : null;
  };
  // HTTPS first: every host this dashboard talks to is https.
  if (field('HTTPSEnable') === '1' && field('HTTPSProxy')) {
    return 'http://' + field('HTTPSProxy') + ':' + (field('HTTPSPort') || '80');
  }
  if (field('HTTPEnable') === '1' && field('HTTPProxy')) {
    return 'http://' + field('HTTPProxy') + ':' + (field('HTTPPort') || '80');
  }
  return null;
}

function systemProxyWin() {
  const out = execFileSync(
    'reg',
    ['query', 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings'],
    { encoding: 'utf8', timeout: 5000 }
  );
  // ProxyEnable is a REG_DWORD printed as 0x0/0x1; anything but 0 means on.
  const en = out.match(/ProxyEnable\s+REG_DWORD\s+(\S+)/i);
  if (!en || Number(en[1]) === 0) return null;
  const srv = out.match(/ProxyServer\s+REG_SZ\s+(.+?)\s*$/im);
  if (!srv) return null;
  // Either a bare host:port for all protocols, or a per-scheme list like
  // "http=host:8080;https=host:8443;ftp=...". Prefer the https entry.
  const value = srv[1].trim();
  if (value.indexOf('=') === -1) return 'http://' + value;
  const parts = {};
  value.split(';').forEach((pair) => {
    const i = pair.indexOf('=');
    if (i > 0) parts[pair.slice(0, i).trim().toLowerCase()] = pair.slice(i + 1).trim();
  });
  const pick = parts.https || parts.http;
  return pick ? 'http://' + pick : null;
}

function systemProxy() {
  if (SYSTEM_PROXY !== undefined) return SYSTEM_PROXY;
  SYSTEM_PROXY = null;
  try {
    if (process.platform === 'darwin') SYSTEM_PROXY = systemProxyMac();
    else if (process.platform === 'win32') SYSTEM_PROXY = systemProxyWin();
  } catch (e) {
    SYSTEM_PROXY = null;
  }
  return SYSTEM_PROXY;
}

function envVar(name) {
  return process.env[name] || process.env[name.toLowerCase()] || '';
}

// NO_PROXY entries match a host exactly or as a domain suffix; a bare "*"
// disables proxying entirely. Same rules curl and the runtimes use.
function bypassed(hostname) {
  const raw = envVar('NO_PROXY').trim();
  if (!raw) return false;
  if (raw === '*') return true;
  const host = hostname.toLowerCase();
  return raw
    .split(',')
    .map((s) => s.trim().toLowerCase().replace(/^\./, ''))
    .filter(Boolean)
    .some((entry) => host === entry || host.endsWith('.' + entry));
}

// Returns a proxy URL string, or null to use the direct path.
function resolveProxy(target) {
  if (bypassed(target.hostname)) return null;
  const fromEnv =
    (target.protocol === 'https:' ? envVar('HTTPS_PROXY') : envVar('HTTP_PROXY')) ||
    envVar('ALL_PROXY');
  const proxy = (fromEnv || systemProxy() || '').trim();
  if (!proxy) return null;
  // CONNECT only. A socks5:// proxy is not something this speaks, and pointing
  // an http agent at one would fail in a far more confusing way than not trying.
  if (/^socks/i.test(proxy)) return null;
  return /^https?:\/\//i.test(proxy) ? proxy : 'http://' + proxy;
}

// ---------- CONNECT tunnel ----------

const AGENTS = new Map(); // proxy url -> https.Agent

// An https.Agent whose sockets are TLS sessions riding inside a CONNECT tunnel.
// createConnection must hand the socket back through the callback, because the
// TLS socket does not exist until the proxy has answered 200.
function tunnelAgent(proxyUrl) {
  const cached = AGENTS.get(proxyUrl);
  if (cached) return cached;
  const p = new URL(proxyUrl);
  const auth = p.username
    ? Buffer.from(decodeURIComponent(p.username) + ':' + decodeURIComponent(p.password || '')).toString('base64')
    : null;
  const agent = new https.Agent({ keepAlive: true, timeout: 30000 });
  agent.createConnection = function (options, cb) {
    const socket = net.connect({
      host: p.hostname,
      port: Number(p.port) || (p.protocol === 'https:' ? 443 : 80),
    });
    let settled = false;
    const fail = (err) => {
      if (settled) return;
      settled = true;
      socket.destroy();
      cb(err);
    };
    socket.once('error', fail);
    socket.setTimeout(30000, () => fail(new Error('proxy connection timed out')));
    const hostPort = options.host + ':' + (options.port || 443);
    socket.once('connect', () => {
      socket.setTimeout(0);
      socket.write(
        'CONNECT ' + hostPort + ' HTTP/1.1\r\n' +
          'Host: ' + hostPort + '\r\n' +
          (auth ? 'Proxy-Authorization: Basic ' + auth + '\r\n' : '') +
          'Connection: keep-alive\r\n\r\n'
      );
    });
    let head = '';
    const onData = (chunk) => {
      head += chunk.toString('latin1');
      if (head.indexOf('\r\n\r\n') === -1) return;
      socket.removeListener('data', onData);
      const status = Number(head.split(' ')[1]) || 0;
      if (status !== 200) return fail(new Error('proxy refused CONNECT with status ' + status));
      settled = true;
      socket.removeListener('error', fail);
      cb(
        null,
        tls.connect({ socket, servername: options.servername || options.host })
      );
    };
    socket.on('data', onData);
  };
  AGENTS.set(proxyUrl, agent);
  return agent;
}

// ---------- fetch-compatible surface ----------

// Only the members the dashboard actually uses. Kept deliberately small: this
// shim exists to carry a proxied request, not to reimplement fetch.
function toResponse(res, body) {
  const text = body.toString('utf8');
  return {
    ok: res.statusCode >= 200 && res.statusCode < 300,
    status: res.statusCode,
    statusText: res.statusMessage || '',
    headers: { get: (name) => res.headers[String(name).toLowerCase()] || null },
    text: () => Promise.resolve(text),
    json: () => Promise.resolve(JSON.parse(text)),
  };
}

function proxiedRequest(target, proxyUrl, opts) {
  return new Promise((resolve, reject) => {
    const isHttps = target.protocol === 'https:';
    const p = new URL(proxyUrl);
    // https tunnels through CONNECT; plain http goes to the proxy as an
    // absolute-URI request, which is the other half of the same convention.
    const reqOpts = isHttps
      ? {
          method: opts.method || 'GET',
          host: target.hostname,
          port: target.port || 443,
          path: target.pathname + target.search,
          headers: Object.assign({ Host: target.host }, opts.headers),
          agent: tunnelAgent(proxyUrl),
        }
      : {
          method: opts.method || 'GET',
          host: p.hostname,
          port: Number(p.port) || 80,
          path: target.toString(),
          headers: Object.assign({ Host: target.host }, opts.headers),
        };
    const req = (isHttps ? https : http).request(reqOpts, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve(toResponse(res, Buffer.concat(chunks))));
      res.on('error', reject);
    });
    req.setTimeout(30000, () => req.destroy(new Error('request timed out via proxy ' + p.host)));
    req.on('error', (e) =>
      reject(new Error('proxy ' + p.host + ': ' + (e && e.message ? e.message : String(e))))
    );
    if (opts.body !== undefined && opts.body !== null) req.write(opts.body);
    req.end();
  });
}

// Drop-in for global fetch, for the subset of it this dashboard uses. With no
// proxy configured it IS global fetch, so the common case keeps the exact
// behavior it has today and only a proxied machine takes the new path.
function proxyFetch(url, opts) {
  const options = opts || {};
  let target;
  try {
    target = new URL(url);
  } catch (e) {
    return Promise.reject(e);
  }
  const proxy = resolveProxy(target);
  if (!proxy) return fetch(url, options);
  return proxiedRequest(target, proxy, options);
}

// Logged at startup and named in transport errors, so a machine that cannot
// reach claude.ai says which route it tried instead of leaving a bare
// "fetch failed" to be guessed at.
function activeProxy(sampleUrl) {
  try {
    return resolveProxy(new URL(sampleUrl || 'https://claude.ai/'));
  } catch (e) {
    return null;
  }
}

module.exports = { proxyFetch, activeProxy, resolveProxy };
