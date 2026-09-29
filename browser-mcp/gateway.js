#!/usr/bin/env node
//
// gateway.js — a queuing front-end for @playwright/mcp.
//
// @playwright/mcp allows exactly one browser per --user-data-dir. A second MCP
// session that touches a browser tool gets a hard error:
//     "Browser is already in use for <dir>, use --isolated to run multiple instances"
// which pushes the retry burden onto every client.
//
// This gateway sits in front of it and turns that error into a wait. Browser tool
// calls take a FIFO lock keyed by session; a call that arrives while another session
// holds the browser is parked until the holder releases it, rather than failing.
// Sessions that go quiet lose the browser to the next waiter so one abandoned client
// cannot park the device forever.
//
// Non-browser traffic (initialize, tools/list, ping) is never serialized.
//
//   GET /status  -> queue depth, current holder, wait times, browser process count
//   POST /mcp    -> proxied, with the lock applied to browser_* tool calls
//   GET  /mcp    -> proxied and streamed (notification channel; never buffered)
//
// No dependencies; Node stdlib only.

'use strict';
const http = require('node:http');
const fs = require('node:fs');
const net = require('node:net');
const { execFileSync, execFile } = require('node:child_process');
const auth = require('./auth.js');
const profiles = require('./profiles.js');

const LISTEN_HOST = process.env.GW_HOST || '127.0.0.1';
const LISTEN_PORT = Number(process.env.GW_PORT || 8930);
const UP_HOST = process.env.GW_UPSTREAM_HOST || '127.0.0.1';
const UP_PORT = Number(process.env.GW_UPSTREAM_PORT || 8931);

// A session that holds the browser but stops issuing browser calls for this long
// is considered abandoned and loses it to the next waiter.
const IDLE_RELEASE_MS = Number(process.env.GW_IDLE_RELEASE_MS || 120_000);
// A holder that is idle *while someone is waiting* loses the browser far sooner. 120s of
// grace is meant for an agent thinking between calls, but it is longer than an MCP client
// will wait for a single tool call -- so a waiter behind an idle holder always timed out,
// which is what made the browser look unreachable.
const IDLE_RELEASE_WAITING_MS = Number(process.env.GW_IDLE_RELEASE_WAITING_MS || 20_000);
// How long a queued call waits before giving up with a descriptive error.
const MAX_WAIT_MS = Number(process.env.GW_MAX_WAIT_MS || 300_000);
// Hard ceiling on parked callers; beyond this we shed load instead of thrashing.
const MAX_QUEUE = Number(process.env.GW_MAX_QUEUE || 8);
// Refuse browser_snapshot responses larger than this, pointing the caller at the far
// cheaper browser_find / browser_evaluate. 0 disables the cap (sizes are still logged).
// Default off: visibility first, enforcement once you know your own page mix.
const MAX_SNAPSHOT_BYTES = Number(process.env.GW_MAX_SNAPSHOT_BYTES || 0);

const startedAt = Date.now();
const log = (evt, fields = {}) =>
  console.log(JSON.stringify({ ts: new Date().toISOString(), evt, ...fields }));

// Sessions are opaque UUIDs; log a short prefix so traces correlate without
// putting a usable session token in the logfile.
const shortSid = (s) => (s ? String(s).slice(0, 8) : null);

// ---------------------------------------------------------------- browser lock

const lock = {
  owner: null,        // mcp-session-id currently entitled to the browser
  since: 0,
  lastActivity: 0,
  inFlight: 0,        // proxied browser calls still awaiting a response
  waiters: [],        // FIFO
};

const stats = { granted: 0, queued: 0, timedOut: 0, idleReleases: 0, shed: 0, peakQueue: 0, reconciles: 0, upstreamRestarts: 0 };

function grantTo(sid) {
  lock.owner = sid;
  lock.since = Date.now();
  lock.lastActivity = Date.now();
}

/** Take the browser lock for `sid`, waiting in FIFO order if another session holds it. */
function acquire(sid) {
  if (lock.owner === null || lock.owner === sid) {
    grantTo(sid);
    stats.granted++;
    return Promise.resolve({ waitedMs: 0, queued: false });
  }
  if (lock.waiters.length >= MAX_QUEUE) {
    stats.shed++;
    return Promise.reject(Object.assign(new Error('queue_full'), { kind: 'queue_full' }));
  }
  return new Promise((resolve, reject) => {
    const w = { sid, at: Date.now(), resolve, reject, timer: null };
    w.timer = setTimeout(() => {
      const i = lock.waiters.indexOf(w);
      if (i >= 0) lock.waiters.splice(i, 1);
      stats.timedOut++;
      log('queue_timeout', { sid: shortSid(sid), waitedMs: Date.now() - w.at });
      reject(Object.assign(new Error('queue_timeout'), { kind: 'queue_timeout', waitedMs: Date.now() - w.at }));
    }, MAX_WAIT_MS);
    lock.waiters.push(w);
    stats.queued++;
    stats.peakQueue = Math.max(stats.peakQueue, lock.waiters.length);
    log('queued', { sid: shortSid(sid), depth: lock.waiters.length, holder: shortSid(lock.owner) });
  });
}

/** Drop a queued waiter whose client has gone away, so it never becomes a phantom holder. */
function cancelWaiter(sid) {
  const i = lock.waiters.findIndex((w) => w.sid === sid);
  if (i < 0) return false;
  const [w] = lock.waiters.splice(i, 1);
  clearTimeout(w.timer);
  log('waiter_abandoned', { sid: shortSid(sid), waitedMs: Date.now() - w.at, depth: lock.waiters.length });
  w.reject(Object.assign(new Error('client_gone'), { kind: 'client_gone' }));
  return true;
}

function release(reason) {
  const prev = lock.owner;
  lock.owner = null;
  const next = lock.waiters.shift();
  if (next) {
    clearTimeout(next.timer);
    grantTo(next.sid);
    const waitedMs = Date.now() - next.at;
    log('lock_handoff', { from: shortSid(prev), to: shortSid(next.sid), reason, waitedMs, depth: lock.waiters.length });
    next.resolve({ waitedMs, queued: true });
  } else if (prev) {
    log('lock_released', { sid: shortSid(prev), reason });
  }
}

// Every upstream session the gateway has opened. The gateway's lock and the
// upstream browser can drift apart -- a session that is never DELETEd (client
// crash, gateway restart) keeps holding Playwright's browser while the gateway
// believes it is free. Tracking them lets us clean that up instead of wedging.
// sid -> { port, lastSeen }. The port matters: under GW_NO_STATIC_UPSTREAM every session
// lives on a per-profile upstream (8940+), not on UP_PORT. Cleanup that assumed UP_PORT
// silently did nothing, which is how a five-day-old session kept holding the browser.
const upstreamSessions = new Map();

// Persisted so a gateway restart can still clean up sessions it opened earlier.
// Without this, a restarted gateway has no idea who is holding the browser and
// has to fall back to bouncing the whole upstream.
const SESSION_FILE = process.env.GW_SESSION_FILE || `${process.env.HOME}/job-search-pipeline-data/gateway-sessions.json`;

function saveSessions() {
  const rows = [...upstreamSessions.entries()]
    .map(([sid, v]) => [sid, v.port ?? null, v.profile ?? null, v.initBody ?? null]);
  try { fs.writeFileSync(SESSION_FILE, JSON.stringify(rows)); }
  catch (e) { log('session_persist_failed', { err: e.message }); }
}
function loadSessions() {
  try {
    const raw = JSON.parse(fs.readFileSync(SESSION_FILE, 'utf8'));
    for (const row of raw) {
      // Older files are a bare array of sids, with no port recorded.
      const [sid, port, profile, initBody] = Array.isArray(row) ? row : [row, null, null, null];
      // A recovered session is unbound: its upstream did not survive the restart. Keeping
      // initBody lets the next call re-establish it instead of failing the client.
      upstreamSessions.set(sid, { port: null, upSid: null, profile: profile ?? null,
                                  initBody: initBody ?? null, lastSeen: 0, recovered: true,
                                  hadPort: port ?? null });
    }
    if (upstreamSessions.size) log('sessions_recovered', { count: upstreamSessions.size });
  } catch { /* first run, or unreadable -- not an error */ }
}

function noteSession(sid, port, extra = {}) {
  if (!sid) return;
  const prev = upstreamSessions.get(sid) || {};
  upstreamSessions.set(sid, { ...prev, ...extra, port, lastSeen: Date.now() });
  saveSessions();
}

// A session whose upstream was torn down under it (MAX_LIVE eviction, idle teardown,
// crash) is not dead -- only its upstream is. Re-create an upstream session for it and
// keep serving the client's original id, so one browser can back several connected
// clients instead of the newest connection breaking the previous one.
const SESSION_LOST = /Server not initialized|Bad Request:.*[Ss]ession|session not found|No valid session/i;

async function rebind(clientSid, profile) {
  const rec = upstreamSessions.get(clientSid);
  if (!rec?.initBody) return null;
  let u = await profiles.ensure(profile);

  // @playwright/mcp binds its browser to one MCP session per --user-data-dir. Adding a
  // second session to a live upstream therefore does not get a browser: the call blocks
  // until the first session goes away, which reads to the client as a hang. If anything
  // else is already bound to this upstream, take a fresh one.
  const squatters = [...upstreamSessions.entries()]
    .filter(([s2, v]) => s2 !== clientSid && v.port === u.port && v.upSid);
  if (squatters.length) {
    log('rebind_needs_clean_upstream', { profile, port: u.port, squatters: squatters.length });
    await profiles.stop(profile);
    u = await profiles.ensure(profile);
  }

  const upSid = await handshake(u.port, stripClientCaps(Buffer.from(rec.initBody)));
  if (!upSid) { log('rebind_failed', { sid: shortSid(clientSid), profile, port: u.port }); return null; }
  noteSession(clientSid, u.port, { upSid, profile });
  log('session_rebound', { sid: shortSid(clientSid), profile, port: u.port, up_sid: shortSid(upSid) });
  return u;
}

// Capabilities that commit the client to answering server-initiated requests. The gateway
// buffers each POST and owns the upstream session, so a server->client request (roots/list,
// an elicitation) has no path back to the real client: @playwright/mcp asks, nobody
// answers, and the client's own tool call hangs until it times out. Measured on this
// device: a client declaring roots+elicitation took 88s for its first browser call, the
// same client declaring none took 2s.
//
// Nothing here needs them -- the browser runs on the phone, so the client's filesystem
// roots are meaningless and there is no human to elicit from. Strip them on the way
// through. Set GW_KEEP_CLIENT_CAPS=1 to stop doing this.
const STRIP_CLIENT_CAPS = process.env.GW_KEEP_CLIENT_CAPS !== '1';
const CLIENT_CALLBACK_CAPS = ['roots', 'sampling', 'elicitation'];

/** Remove callback capabilities from an `initialize` body. Returns the body unchanged if
 *  there is nothing to strip, so non-initialize traffic is never touched. */
function stripClientCaps(bodyBuf) {
  if (!STRIP_CLIENT_CAPS) return bodyBuf;
  let d;
  try { d = JSON.parse(bodyBuf.toString('utf8')); } catch { return bodyBuf; }
  if (d?.method !== 'initialize') return bodyBuf;
  const caps = d?.params?.capabilities;
  if (!caps) return bodyBuf;
  const dropped = CLIENT_CALLBACK_CAPS.filter((k) => k in caps);
  if (!dropped.length) return bodyBuf;
  for (const k of dropped) delete caps[k];
  log('client_caps_stripped', { dropped, client: d?.params?.clientInfo?.name ?? null });
  return Buffer.from(JSON.stringify(d), 'utf8');
}

/** Replay a stored `initialize` against an upstream; returns the session id it issues. */
function handshake(port, initBody) {
  return new Promise((resolve) => {
    const r = http.request({ host: UP_HOST, port, path: '/mcp', method: 'POST',
      headers: { host: `localhost:${port}`, 'content-type': 'application/json',
                 accept: 'application/json, text/event-stream',
                 'content-length': Buffer.byteLength(initBody) } },
      (ur) => {
        const sid = ur.headers['mcp-session-id'] || null;
        ur.resume();
        ur.on('end', () => {
          if (!sid) return resolve(null);
          // @playwright/mcp expects the initialized notification before real calls.
          const n = Buffer.from(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }));
          const r2 = http.request({ host: UP_HOST, port, path: '/mcp', method: 'POST',
            headers: { host: `localhost:${port}`, 'content-type': 'application/json',
                       accept: 'application/json, text/event-stream',
                       'mcp-session-id': sid, 'content-length': n.length } },
            (ur2) => { ur2.resume(); ur2.on('end', () => resolve(sid)); });
          r2.on('error', () => resolve(sid));
          r2.end(n);
        });
      });
    r.setTimeout(20000, () => { r.destroy(); resolve(null); });
    r.on('error', () => resolve(null));
    r.end(initBody);
  });
}

/**
 * An upstream on `port` is gone. Unbind its sessions rather than forgetting them: the
 * client is still there and still holds a valid id, so keep whatever is needed to
 * re-establish it (see rebind) and only drop records we could never restore.
 */
/**
 * Release a session's upstream so Playwright frees the browser, but keep the record so the
 * client can be re-bound if it comes back. Used when a client hangs up mid-call.
 */
async function unbindSession(sid) {
  const rec = upstreamSessions.get(sid);
  if (!rec) return;
  if (rec.upSid && rec.port) await deleteOne(rec.upSid, rec.port);
  if (rec.initBody) upstreamSessions.set(sid, { ...rec, port: null, upSid: null });
  else upstreamSessions.delete(sid);
  saveSessions();
  log('session_unbound_client_gone', { sid: shortSid(sid) });
}

function forgetSessionsOnPort(port, reason) {
  const gone = [...upstreamSessions.entries()].filter(([, v]) => v.port === port).map(([sid]) => sid);
  for (const sid of gone) {
    const rec = upstreamSessions.get(sid);
    if (rec?.initBody) upstreamSessions.set(sid, { ...rec, port: null, upSid: null });
    else upstreamSessions.delete(sid);
  }
  if (gone.length) { saveSessions(); log('sessions_unbound', { port, count: gone.length, reason }); }
  if (lock.owner && gone.includes(lock.owner)) {
    log('lock_owner_upstream_gone', { sid: shortSid(lock.owner), port, reason });
    release('upstream_gone');
  }
}

function deleteOne(sid, port) {
  return new Promise((resolve) => {
    const r = http.request(
      { host: UP_HOST, port, path: '/mcp', method: 'DELETE',
        headers: { 'mcp-session-id': sid, host: `localhost:${port}` } },
      (res) => {
        res.resume();
        res.on('end', () => {
          if (res.statusCode >= 400) log('upstream_delete_rejected', { sid: shortSid(sid), port, status: res.statusCode });
          resolve(res.statusCode < 400);
        });
      });
    r.setTimeout(4000, () => { r.destroy(); resolve(false); });
    r.on('error', (e) => { log('upstream_delete_failed', { sid: shortSid(sid), port, err: e.message }); resolve(false); });
    r.end();
  });
}

/**
 * Ask upstream to drop a session, so Playwright actually closes its browser.
 * Sessions recovered from disk may have no recorded port; try every live upstream
 * rather than guessing UP_PORT, which no longer exists on this device.
 */
async function deleteUpstreamSession(sid) {
  if (!sid) return;
  const known = upstreamSessions.get(sid);
  upstreamSessions.delete(sid);
  // Rebound sessions live upstream under a different id than the client's.
  const target = known?.upSid || sid;
  const ports = known?.port ? [known.port] : profiles.livePorts();
  for (const port of ports) if (await deleteOne(target, port)) break;
}

/**
 * Upstream says the browser is in use but we think it is free: some session is
 * holding it that we are no longer tracking as the owner. Drop every upstream
 * session except the caller's, so the browser comes back.
 */
async function reconcileUpstream(keepSid) {
  const stale = [...upstreamSessions.keys()].filter((s) => s !== keepSid);
  log('reconcile', { keep: shortSid(keepSid), dropping: stale.length });
  await Promise.all(stale.map(deleteUpstreamSession));
  saveSessions();
  // Give Playwright a moment to actually tear the browser down.
  await new Promise((r) => setTimeout(r, 1500));
  return stale.length;
}

/**
 * Is the current lock holder still capable of using the browser? A holder whose upstream
 * has gone away (client vanished, profile evicted, gateway restarted) can never release
 * the lock itself, and queueing behind it just burns the caller's timeout. Checked before
 * anyone is made to wait.
 */
function holderIsDead() {
  if (!lock.owner) return false;
  const rec = upstreamSessions.get(lock.owner);
  if (!rec) return true;                                     // we are not tracking it at all
  if (!rec.port) return true;                                // recovered from disk, port unknown
  return !profiles.livePorts().includes(rec.port);           // its upstream is no longer live
}

function dropDeadHolder() {
  if (!holderIsDead()) return false;
  log('dead_holder_evicted', { sid: shortSid(lock.owner), held_s: Math.round((Date.now() - lock.since) / 1000) });
  const victim = lock.owner;
  release('holder_dead');
  deleteUpstreamSession(victim);
  return true;
}

const upReachable = (port = UP_PORT) => new Promise((resolve) => {
  const s = net.connect({ host: UP_HOST, port });
  const done = (v) => { s.destroy(); resolve(v); };
  s.setTimeout(1500);
  s.on('connect', () => done(true));
  s.on('error', () => done(false));
  s.on('timeout', () => done(false));
});

/**
 * Last resort when the browser is wedged and we have no session to drop: bounce
 * the upstream MCP server. supervise.sh notices it is gone and restarts it
 * (along with the browser) within its poll interval, so we just wait for the
 * port to come back.
 */
async function restartUpstream(profile) {
  stats.upstreamRestarts++;
  log('upstream_restart', { reason: 'wedged_browser', profile });
  // Restart just this profile. The old version pkill'd every @playwright/mcp and then
  // waited for UP_PORT to come back -- which never happens under GW_NO_STATIC_UPSTREAM,
  // so it always reported failure after killing every other profile's browser too.
  try {
    await profiles.stop(profile);
    const u = await profiles.ensure(profile);
    log('upstream_back', { profile, port: u.port });
    return true;
  } catch (e) {
    log('upstream_restart_failed', { profile, err: e.message });
    return false;
  }
}

// Reclaim the browser from sessions that stopped talking.
//
// This used to require lock.waiters.length > 0, so an abandoned holder kept the browser
// indefinitely and the *next* caller paid the full IDLE_RELEASE_MS in the queue before it
// could start -- longer than any normal MCP client timeout, so the first call after an
// idle period always failed. Reclaim unconditionally: an idle holder that comes back
// simply re-acquires a free lock.
let reclaiming = false;
setInterval(async () => {
  if (reclaiming) return;
  // inFlight guards against reclaiming a holder in the middle of a slow call: a page load
  // on this phone can outlast IDLE_RELEASE_MS, and it is still legitimately using the browser.
  const grace = lock.waiters.length > 0 ? IDLE_RELEASE_WAITING_MS : IDLE_RELEASE_MS;
  if (lock.owner && lock.inFlight === 0 && Date.now() - lock.lastActivity > grace) {
    const victim = lock.owner;
    reclaiming = true;
    stats.idleReleases++;
    log('idle_reclaim', { sid: shortSid(victim), idleMs: Date.now() - lock.lastActivity,
                          waiting: lock.waiters.length, grace_ms: grace });
    // Await the upstream teardown before handing the browser on. Releasing first let the
    // next caller in while Playwright still had the browser bound to the old session: it
    // blocked *inside* the upstream for ~20s with nothing to show for it, instead of
    // waiting visibly in this queue.
    // Unbind rather than forget: the reclaimed client is usually still alive and will call
    // again, and keeping its record lets that call transparently re-establish the session
    // instead of coming back as "session not found".
    try { await unbindSession(victim); }
    finally { release('idle'); reclaiming = false; }
  }
}, 2_000).unref();

// ------------------------------------------------------------------- utilities

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

/**
 * Re-send a fully buffered upstream response.
 *
 * The upstream answers with Transfer-Encoding: chunked. Once we have buffered the body we
 * are sending a fixed-length response, so that header must go -- forwarding it alongside a
 * Content-Length is invalid HTTP. curl tolerates the contradiction, which is why the
 * on-device soak never caught this, but undici (Node fetch, and therefore Claude Code and
 * claude.ai) rejects the response with UND_ERR_HTTP_PARSER. Hop-by-hop headers must not be
 * forwarded by a proxy either (RFC 9110 7.6.1).
 */
const HOP_BY_HOP = ['transfer-encoding', 'connection', 'keep-alive', 'upgrade',
                    'proxy-authenticate', 'proxy-authorization', 'te', 'trailer'];
function sendBuffered(res, status, headers, bodyBuf) {
  if (res.headersSent) return;
  const h = { ...headers };
  for (const k of Object.keys(h)) {
    if (HOP_BY_HOP.includes(k.toLowerCase())) delete h[k];
  }
  delete h['content-length'];
  h['content-length'] = Buffer.byteLength(bodyBuf);
  res.writeHead(status, h);
  res.end(bodyBuf);
}

function jsonRpcError(res, id, code, message, data, status = 200) {
  const payload = JSON.stringify({ jsonrpc: '2.0', id: id ?? null, error: { code, message, data } });
  res.writeHead(status, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(payload) });
  res.end(payload);
}

function chromeProcCount() {
  try {
    return execFileSync('pgrep', ['-fc', 'lib/chromium/chrome'], { encoding: 'utf8' }).trim();
  } catch { return '0'; }
}

/**
 * Distinct browsers, not processes. One Chromium is ~8 processes (zygote, gpu, renderers),
 * so the raw count says "8" for a healthy single browser and tells you nothing about the
 * one condition that actually matters on this device: two browsers at once.
 */
function browserCount() {
  const dirs = new Set();
  let pids = [];
  try { pids = fs.readdirSync('/proc').filter((d) => /^\d+$/.test(d)); } catch { return null; }
  for (const pid of pids) {
    let cmd;
    try { cmd = fs.readFileSync(`/proc/${pid}/cmdline`).toString().split('\0'); } catch { continue; }
    if (!cmd[0] || !cmd[0].includes('chromium/chrome')) continue;
    const arg = cmd.find((a) => a.startsWith('--user-data-dir='));
    if (arg) dirs.add(arg.slice('--user-data-dir='.length));   // helpers share the parent's dir
  }
  return dirs.size;
}

/**
 * Proxy one request upstream.
 * `buffer`: collect the whole response so we can inspect/rewrite it (POST tool calls).
 * Streaming is used for GET /mcp, which is a long-lived notification channel.
 */
function proxy(req, res, body, { buffer, port = UP_PORT, upstreamPath = null, upSid = null, clientSid = null, rpcId = null }) {
  return new Promise((resolve) => {
    // @playwright/mcp rejects any request whose Host is not what it bound to, so the
    // Host must name the *target* port, not the gateway's. Profile routes also have to
    // be rewritten: the client says /mcp/linkedin, the upstream only knows /mcp.
    const headers = { ...req.headers, host: `localhost:${port}` };
    // The client's session id is the gateway's own handle. Upstreams get re-created under
    // it (see rebind), so the id they know may differ -- translate on the way out.
    if (upSid) headers['mcp-session-id'] = upSid;
    delete headers['content-length'];
    if (body && body.length) headers['content-length'] = Buffer.byteLength(body);
    const target = upstreamPath || req.url;

    let settled = false;
    const finish = (v) => { if (settled) return; settled = true; res.off('close', onClientGone); resolve(v); };
    // An MCP client that times out simply drops the connection. Without this the gateway
    // kept waiting, kept the browser lock held and left Playwright's browser bound to a
    // session nobody would ever use again -- the browser stayed wedged until a restart.
    function onClientGone() {
      if (settled) return;
      log('client_disconnected', { port, path: target });
      try { up.destroy(); } catch { /* already gone */ }
      settled = true;
      resolve({ aborted: true });
    }
    res.on('close', onClientGone);

    const up = http.request({ host: UP_HOST, port, path: target, method: req.method, headers }, (ur) => {
      const h = { ...ur.headers };
      // ...and back, so the client never sees the id change under it.
      if (clientSid && h['mcp-session-id']) h['mcp-session-id'] = clientSid;
      if (!buffer) {
        res.writeHead(ur.statusCode, h);
        ur.pipe(res);
        ur.on('end', () => finish());
        return;
      }
      const chunks = [];
      ur.on('data', (c) => chunks.push(c));
      ur.on('end', () => finish({ status: ur.statusCode, headers: h, body: Buffer.concat(chunks) }));
    });
    up.on('error', (e) => {
      if (settled) return;
      log('upstream_error', { err: e.message, port });
      if (!res.headersSent) {
        jsonRpcError(res, rpcId, -32001,
          `Browser backend unreachable on ${UP_HOST}:${port}. The MCP server may be restarting; retry in a few seconds.`);
      } else { res.end(); }
      finish(null);
    });
    if (body && body.length) up.write(body);
    up.end();
  });
}

// --------------------------------------------------------------------- routing

const BROWSER_IN_USE = /Browser is already in use/i;

/** A proxy result with a body: not null, and not a client-hangup. */
const gotBody = (r) => !!(r && !r.aborted && r.body);

const server = http.createServer(async (req, res) => {
  // Always drain the request body, on every path. A half-read body poisons
  // HTTP keep-alive behind cloudflared -- the same failure this repo already
  // hit once with the transcript MCP server.
  let body = req.method === 'POST' || req.method === 'PUT' ? await readBody(req) : Buffer.alloc(0);

  // Requests arriving through cloudflared also originate from 127.0.0.1, so the socket
  // address alone cannot distinguish them. cloudflared always stamps forwarding headers;
  // their absence on a loopback socket means a genuinely on-device caller (soak.sh,
  // start.sh). Those keep working without a token; everything off-device must authenticate.
  const viaTunnel = !!(req.headers['x-forwarded-for'] || req.headers['cf-connecting-ip'] ||
                       req.headers['cf-ray'] || req.headers['x-forwarded-proto']);
  const sock = req.socket.remoteAddress || '';
  const trustedLocal = !viaTunnel && (sock === '127.0.0.1' || sock === '::1' || sock === '::ffff:127.0.0.1');

  // OAuth discovery / registration / consent / token. Must come before the auth gate:
  // these are how a client *obtains* a token, so they cannot require one.
  if (auth.handleAuthRoutes(req, res, body.toString('utf8'))) return;

  // Ticket #4: no unauthenticated path, ever -- including health checks that leak anything.
  // /status exposes queue state and process counts, so it is gated too.
  if (!trustedLocal && !auth.isAuthed(req)) {
    log('unauthorized', { path: req.url, method: req.method, via_tunnel: viaTunnel });
    return auth.unauthorized(req, res);
  }

  if (req.method === 'GET' && req.url === '/status') {
    const payload = JSON.stringify({
      ok: true,
      uptime_s: Math.round((Date.now() - startedAt) / 1000),
      browser: {
        busy: lock.owner !== null,
        holder: shortSid(lock.owner),
        held_for_s: lock.owner ? Math.round((Date.now() - lock.since) / 1000) : 0,
        idle_for_s: lock.owner ? Math.round((Date.now() - lock.lastActivity) / 1000) : 0,
        holder_alive: lock.owner ? !holderIsDead() : null,
        in_flight: lock.inFlight,
      },
      queue: {
        depth: lock.waiters.length,
        max: MAX_QUEUE,
        waiting_s: lock.waiters.map((w) => Math.round((Date.now() - w.at) / 1000)),
      },
      limits: { idle_release_ms: IDLE_RELEASE_MS, idle_release_waiting_ms: IDLE_RELEASE_WAITING_MS,
                max_wait_ms: MAX_WAIT_MS },
      stats,
      profiles: profiles.status(),
      browsers: browserCount(),
      chrome_processes: Number(chromeProcCount()),
    }, null, 2);
    res.writeHead(200, { 'content-type': 'application/json' });
    return res.end(payload);
  }

  // ---- profile management (#5 hand-login). Authenticated like everything else.
  //   GET  /profiles              list known + live profiles
  //   POST /profiles/<name>/pin   spawn it and hold it open for a hand-login
  //   POST /profiles/<name>/unpin release it back to normal idle teardown
  {
    const mgmt = /^\/profiles(?:\/([^/]+)\/(pin|unpin))?\/?$/.exec(req.url.split('?')[0]);
    if (mgmt) {
      if (req.method === 'GET' && !mgmt[1]) {
        const payload = JSON.stringify(profiles.status(), null, 2);
        res.writeHead(200, { 'content-type': 'application/json' });
        return res.end(payload);
      }
      if (req.method === 'POST' && mgmt[1]) {
        const name = decodeURIComponent(mgmt[1]);
        if (!profiles.isValidName(name)) {
          res.writeHead(400, { 'content-type': 'application/json' });
          return res.end(JSON.stringify({ error: `invalid profile name "${name}"` }));
        }
        try {
          if (mgmt[2] === 'pin') {
            const u = await profiles.pin(name);
            res.writeHead(200, { 'content-type': 'application/json' });
            return res.end(JSON.stringify({
              profile: name, port: u.port, pinned: true,
              note: 'Browser is open on the X display and will not be torn down. Unpin when done.',
            }, null, 2));
          }
          const had = profiles.unpin(name);
          res.writeHead(200, { 'content-type': 'application/json' });
          return res.end(JSON.stringify({ profile: name, pinned: false, was_pinned: had }, null, 2));
        } catch (e) {
          log('profile_mgmt_failed', { profile: name, op: mgmt[2], err: e.message });
          res.writeHead(500, { 'content-type': 'application/json' });
          return res.end(JSON.stringify({ error: e.message }));
        }
      }
      res.writeHead(405, { 'content-type': 'application/json' });
      return res.end('{"error":"method not allowed"}');
    }
  }

  // Named profiles (#5). /mcp is the default profile; /mcp/<name> selects another,
  // each backed by its own upstream with its own --user-data-dir, so cookies and
  // logins are isolated and survive restarts.
  const route = profiles.routeOf(req.url);
  if (!route) {
    res.writeHead(404, { 'content-type': 'application/json' });
    return res.end('{"error":"not found"}');
  }
  if (route.error) {
    res.writeHead(400, { 'content-type': 'application/json' });
    return res.end(JSON.stringify({ error: route.error }));
  }

  let rpc = null;
  try { rpc = JSON.parse(body.toString('utf8')); } catch { /* forward opaquely */ }
  if (rpc?.method === 'initialize') body = stripClientCaps(body);

  let upstream;
  try {
    upstream = await profiles.ensure(route.profile);
  } catch (e) {
    log('profile_unavailable', { profile: route.profile, err: e.message });
    return jsonRpcError(res, rpc?.id, -32006,
      `Could not start a browser for profile "${route.profile}": ${e.message}`,
      { profile: route.profile, retry_after_s: 30 });
  }
  const sid = req.headers['mcp-session-id'] || null;

  // A known session whose upstream is no longer the live one for this profile gets a new
  // upstream session transparently, under its original id.
  if (sid) {
    const rec = upstreamSessions.get(sid);
    if (rec?.initBody && rec.port !== upstream.port) {   // includes port === null (unbound)
      const re = await rebind(sid, route.profile);
      if (re) upstream = re;
    }
  }
  const rec = sid ? upstreamSessions.get(sid) : null;
  const P = { port: upstream.port, upstreamPath: route.upstreamPath,
              upSid: rec?.upSid && rec.upSid !== sid ? rec.upSid : null, clientSid: sid };

  // Held only for the duration of one proxied request -- never across a queue wait, or a
  // waiting caller would block the pool for everyone.
  const held = async (opts) => {
    profiles.hold(route.profile);
    try { return await proxy(req, res, body, { rpcId: rpc?.id ?? null, ...opts }); }
    finally { profiles.unhold(route.profile); }
  };

  // Session teardown: let it through, then hand the browser to whoever is next.
  if (req.method === 'DELETE') {
    await proxy(req, res, body, { buffer: false, ...P });
    if (sid) { upstreamSessions.delete(sid); saveSessions(); }
    if (sid && lock.owner === sid) release('session_closed');
    return;
  }

  // GET /mcp is the SSE notification channel -- stream it, never buffer.
  if (req.method === 'GET') return void (await proxy(req, res, body, { buffer: false, ...P }));

  const toolName = rpc?.method === 'tools/call' ? rpc?.params?.name : null;
  const needsBrowser = typeof toolName === 'string' && toolName.startsWith('browser_');

  if (!needsBrowser) {
    let r = await held({ buffer: true, ...P });
    // Learn the session id handed out by initialize, so we can clean it up later. Keep the
    // request body too: it is what gets replayed to re-establish the session upstream.
    const newSid = r?.headers?.['mcp-session-id'];
    if (newSid) {
      const isInit = rpc?.method === 'initialize';
      noteSession(newSid, P.port, { profile: route.profile, upSid: newSid,
                                    ...(isInit ? { initBody: body.toString('utf8') } : {}) });
      log('session_opened', { sid: shortSid(newSid), profile: route.profile, port: P.port });
    }
    if (rpc?.method === 'initialize' && !r?.headers?.['mcp-session-id']) {
      log('initialize_retry', { profile: route.profile, reason: 'upstream replaced mid-handshake' });
      try {
        const u2 = await profiles.ensure(route.profile);
        r = await held({ buffer: true, port: u2.port, upstreamPath: route.upstreamPath });
        const s2 = r?.headers?.['mcp-session-id'];
        if (s2) noteSession(s2, u2.port, { profile: route.profile, upSid: s2, initBody: body.toString('utf8') });
      } catch (e) { log('initialize_retry_failed', { profile: route.profile, err: e.message }); }
    }
    if (r?.aborted) { if (sid) await unbindSession(sid); return; }
    if (gotBody(r) && sid && SESSION_LOST.test(r.body.toString('utf8'))) {
      const re = await rebind(sid, route.profile);
      if (re) {
        const rec2 = upstreamSessions.get(sid);
        r = await held({ buffer: true, port: re.port,
          upstreamPath: route.upstreamPath, upSid: rec2?.upSid, clientSid: sid });
      }
    }
    if (gotBody(r)) sendBuffered(res, r.status, r.headers, r.body);
    return;
  }

  // ---- this call wants the browser
  // No session id: acquire(null) would set lock.owner = null, which reads as "free" to
  // every other caller -- the lock silently stops serializing. MCP requires a session id
  // after initialize anyway, so refuse instead.
  if (!sid) {
    log('browser_call_without_session', { tool: toolName, profile: route.profile });
    return jsonRpcError(res, rpc?.id, -32600,
      'Missing Mcp-Session-Id. Initialize the MCP session first, then send the session id with every call.',
      { reconnect_required: true }, 400);
  }
  if (!upstreamSessions.has(sid)) {
    // A session this gateway never issued (client outlived a restart, or its record was
    // dropped). It can never work, so refuse it up front instead of letting it take the
    // lock and strand everyone behind it -- which is exactly how the browser wedged.
    log('unknown_session', { sid: shortSid(sid), tool: toolName, profile: route.profile });
    return jsonRpcError(res, rpc?.id, -32600,
      'Session not found: this session id predates the current gateway. Re-initialize and retry.',
      { reconnect_required: true, retry_after_s: 1 }, 404);
  }
  if (sid) noteSession(sid, P.port);
  dropDeadHolder();

  // A client that gives up while queued must leave the queue; otherwise it is handed the
  // browser later, with nobody there to use or release it.
  let clientGone = false;
  const onQueueAbandoned = () => { clientGone = true; if (sid) cancelWaiter(sid); };
  res.on('close', onQueueAbandoned);

  let ticket;
  try {
    ticket = await acquire(sid);
  } catch (e) {
    res.off('close', onQueueAbandoned);
    if (e.kind === 'client_gone') return;
    if (e.kind === 'queue_full') {
      log('shed', { sid: shortSid(sid), tool: toolName });
      return jsonRpcError(res, rpc?.id, -32002,
        `Browser busy and the wait queue is full (${MAX_QUEUE} waiting). This device runs one browser at a time. Retry in a minute.`,
        { retry_after_s: 60, queue_depth: lock.waiters.length });
    }
    return jsonRpcError(res, rpc?.id, -32003,
      `Timed out after ${Math.round(e.waitedMs / 1000)}s waiting for the browser. Another session is holding it. ` +
      `Check GET /status for the current holder, then retry.`,
      { retry_after_s: 60, waited_s: Math.round(e.waitedMs / 1000) });
  }

  res.off('close', onQueueAbandoned);
  // Granted the browser just as the client hung up: hand it straight on.
  if (clientGone) {
    log('granted_to_absent_client', { sid: shortSid(sid), tool: toolName });
    if (lock.owner === sid) release('client_disconnected');
    return;
  }

  profiles.touch(route.profile);
  if (ticket.queued) log('lock_acquired_after_wait', { sid: shortSid(sid), tool: toolName, waitedMs: ticket.waitedMs });
  lock.lastActivity = Date.now();

  lock.inFlight++;
  let r;
  const callStarted = Date.now();
  log('browser_call', { sid: shortSid(sid), tool: toolName, profile: route.profile,
                        port: P.port, up_sid: shortSid(P.upSid), rebound: !!P.upSid });
  try {
    r = await held({ buffer: true, ...P });
    log('browser_call_done', { sid: shortSid(sid), tool: toolName, ms: Date.now() - callStarted,
                               status: r?.status ?? null, aborted: !!r?.aborted });
    // The upstream can have been replaced between acquiring the lock and this call.
    if (gotBody(r) && sid && SESSION_LOST.test(r.body.toString('utf8'))) {
      const re = await rebind(sid, route.profile);
      if (re) {
        const rec2 = upstreamSessions.get(sid);
        P.port = re.port; P.upSid = rec2?.upSid;
        log('retry_after_rebind', { sid: shortSid(sid), tool: toolName, port: re.port });
        r = await held({ buffer: true, ...P });
      } else {
        log('session_unrecoverable', { sid: shortSid(sid), tool: toolName });
        upstreamSessions.delete(sid); saveSessions();
        release('session_unrecoverable');
        return jsonRpcError(res, rpc?.id, -32600,
          'Session not found: it no longer exists upstream and could not be re-established. ' +
          'Re-initialize and retry.',
          { reconnect_required: true, retry_after_s: 1 }, 404);
      }
    }
  } finally { lock.inFlight--; lock.lastActivity = Date.now(); }

  // Client gone: give the browser back at once instead of holding it for the idle grace.
  if (r?.aborted) {
    if (sid) await unbindSession(sid);
    if (lock.owner === sid) release('client_disconnected');
    return;
  }

  // We hold the lock, so an in-use error means an untracked upstream session is
  // squatting on the browser. Clear it and try once more before giving up.
  if (gotBody(r) && BROWSER_IN_USE.test(r.body.toString('utf8'))) {
    stats.reconciles++;
    log('upstream_in_use', { sid: shortSid(sid), tool: toolName, action: 'reconciling' });
    const dropped = await reconcileUpstream(sid);
    if (dropped > 0) {
      r = await held({ buffer: true, ...P });
      lock.lastActivity = Date.now();
      log('retry_after_reconcile', { sid: shortSid(sid), tool: toolName,
        ok: gotBody(r) ? !BROWSER_IN_USE.test(r.body.toString('utf8')) : false });
    }
    // Nothing to drop, or dropping did not help: bounce the upstream. The
    // caller's own session dies with it, so tell them to reconnect rather than
    // silently handing back a response from a different browser.
    if (gotBody(r) && BROWSER_IN_USE.test(r.body.toString('utf8'))) {
      const back = await restartUpstream(route.profile);
      release('upstream_restarted');
      return jsonRpcError(res, rpc?.id, -32004,
        back
          ? 'The browser was wedged by an untracked session and has been restarted. Your session is gone — reconnect (re-initialize) and retry; it should work immediately.'
          : 'The browser was wedged and the backend did not come back. Check supervise.sh status on the device.',
        { retry_after_s: back ? 2 : 60, reconnect_required: true });
    }
  }

  if (gotBody(r)) {
    let out = r.body;

    // Snapshot cost guard. A full aria snapshot of a big page is enormous -- measured
    // on this device, Wikipedia's "Android" article is 1,302,514 bytes (~326k tokens,
    // about $1.63 of Opus 5 input on a single call, and a third of a 1M context window).
    // It also gets re-sent on every subsequent turn of an agent loop. browser_find and
    // browser_evaluate answer the same questions for a fraction of that: the same page
    // costs ~5.9k tokens via find and ~150 via evaluate.
    //
    // Always log the size so the cost is visible. Refuse only if a hard cap is set,
    // because a refusal is better than a surprise bill but worse than a working agent.
    if (toolName === 'browser_snapshot') {
      const bytes = Buffer.byteLength(out);
      log('snapshot_size', { sid: shortSid(sid), bytes, approx_tokens: Math.round(bytes / 4) });
      if (MAX_SNAPSHOT_BYTES > 0 && bytes > MAX_SNAPSHOT_BYTES) {
        log('snapshot_refused', { sid: shortSid(sid), bytes, cap: MAX_SNAPSHOT_BYTES });
        release('snapshot_refused');
        return jsonRpcError(res, rpc?.id, -32005,
          `This page's accessibility snapshot is ${Math.round(bytes / 1024)} kB (~${Math.round(bytes / 4000)}k tokens), ` +
          `over the ${Math.round(MAX_SNAPSHOT_BYTES / 1024)} kB cap. Use browser_find ({"text": "..."} or {"regex": "..."}) ` +
          `to locate an element and get its ref, or browser_evaluate to extract just the text you need — ` +
          `both are orders of magnitude cheaper. Raise GW_MAX_SNAPSHOT_BYTES if you really do need the whole tree.`,
          { snapshot_bytes: bytes, cap_bytes: MAX_SNAPSHOT_BYTES, cheaper_tools: ['browser_find', 'browser_evaluate'] });
      }
    }

    // Still wedged after reconciling: replace the bare Playwright string with
    // something the operator can actually act on.
    if (BROWSER_IN_USE.test(out.toString('utf8'))) {
      const text = out.toString('utf8').replace(BROWSER_IN_USE,
        'Browser is wedged: an untracked session holds it and could not be cleared. ' +
        'Run "job-search-pipeline/start.sh restart" on the device. Original error');
      out = Buffer.from(text, 'utf8');
    }
    sendBuffered(res, r.status, r.headers, out);
  }

  // browser_close ends the browser session; release immediately rather than
  // waiting for the idle sweeper.
  if (toolName === 'browser_close' && lock.owner === sid) release('browser_close');
});

loadSessions();
// When a profile's upstream is torn down (eviction, idle teardown), every MCP session on
// it is dead. Forget them, and hand the browser lock on if the holder was one of them.
profiles.setOnStop((profile, port) => forgetSessionsOnPort(port, `profile_stopped:${profile}`));
// start.sh launches one upstream itself; adopt it as the default profile so we never
// spawn a second browser onto the same --user-data-dir.
// Adopt start.sh's upstream only if it actually exists. When GW_NO_STATIC_UPSTREAM=1
// nothing is listening, and `default` becomes an ordinary on-demand profile -- which is
// what makes GW_MAX_LIVE_PROFILES enforceable.
// Clear out upstreams orphaned by a previous gateway process before deciding what is
// live -- otherwise we spawn duplicates onto directories they still hold.
profiles.reapOrphans();

upReachable().then((live) => {
  if (live) return profiles.adoptStatic(UP_PORT, process.env.PROFILE || null);
  log('no_static_upstream', { port: UP_PORT, note: 'default will be spawned on demand' });
  // No static upstream and every orphan reaped: sessions recovered from disk cannot
  // belong to anything running, so they are dead weight. Keeping them let a stale sid
  // hold the browser lock across restarts for days.
  const dead = [...upstreamSessions.keys()].filter((sid) => !upstreamSessions.get(sid)?.initBody);
  if (dead.length) {
    for (const sid of dead) upstreamSessions.delete(sid);
    saveSessions();
    log('stale_sessions_pruned', { count: dead.length });
  }
});

server.listen(LISTEN_PORT, LISTEN_HOST, () => {
  log('listening', { host: LISTEN_HOST, port: LISTEN_PORT, upstream: `${UP_HOST}:${UP_PORT}`,
                     idle_release_ms: IDLE_RELEASE_MS, idle_release_waiting_ms: IDLE_RELEASE_WAITING_MS,
                     max_wait_ms: MAX_WAIT_MS, max_queue: MAX_QUEUE,
                     max_snapshot_bytes: MAX_SNAPSHOT_BYTES || 'off',
                     auth: 'oauth2.1 + static bearer', secrets_dir: auth.CONF_DIR });
});

// server.close() waits for open connections to drain, and cloudflared holds keep-alive
// sockets open indefinitely -- so the process survived SIGTERM with its port already
// closed. start.sh then saw "a gateway is running" and skipped starting a new one, leaving
// the tunnel answering 502 with nothing listening. Drop the connections and hard-exit.
let shuttingDown = false;
for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => {
    if (shuttingDown) process.exit(0);
    shuttingDown = true;
    log('shutdown', { sig });
    server.close(() => process.exit(0));
    server.closeAllConnections?.();
    setTimeout(() => { log('shutdown_forced', { sig }); process.exit(0); }, 3000).unref();
  });
}
