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
const upstreamSessions = new Map(); // sid -> lastSeen ms

// Persisted so a gateway restart can still clean up sessions it opened earlier.
// Without this, a restarted gateway has no idea who is holding the browser and
// has to fall back to bouncing the whole upstream.
const SESSION_FILE = process.env.GW_SESSION_FILE || `${process.env.HOME}/job-search-pipeline-data/gateway-sessions.json`;

function saveSessions() {
  try { fs.writeFileSync(SESSION_FILE, JSON.stringify([...upstreamSessions.keys()])); }
  catch (e) { log('session_persist_failed', { err: e.message }); }
}
function loadSessions() {
  try {
    for (const sid of JSON.parse(fs.readFileSync(SESSION_FILE, 'utf8'))) upstreamSessions.set(sid, 0);
    if (upstreamSessions.size) log('sessions_recovered', { count: upstreamSessions.size });
  } catch { /* first run, or unreadable -- not an error */ }
}

/** Ask upstream to drop a session, so Playwright actually closes its browser. */
function deleteUpstreamSession(sid) {
  if (!sid) return Promise.resolve();
  upstreamSessions.delete(sid);
  return new Promise((resolve) => {
    const r = http.request(
      { host: UP_HOST, port: UP_PORT, path: '/mcp', method: 'DELETE',
        headers: { 'mcp-session-id': sid, host: `localhost:${UP_PORT}` } },
      (res) => { res.resume(); res.on('end', resolve); });
    r.on('error', (e) => { log('upstream_delete_failed', { sid: shortSid(sid), err: e.message }); resolve(); });
    r.end();
  });
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

const upReachable = () => new Promise((resolve) => {
  const s = net.connect({ host: UP_HOST, port: UP_PORT });
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
async function restartUpstream() {
  stats.upstreamRestarts++;
  log('upstream_restart', { reason: 'wedged_browser' });
  execFile('pkill', ['-f', '@playwright/mcp'], () => {});
  await new Promise((r) => setTimeout(r, 3000));
  upstreamSessions.clear();
  saveSessions();
  for (let i = 0; i < 40; i++) {                    // up to ~40s for the supervisor
    if (await upReachable()) {
      await new Promise((r) => setTimeout(r, 2000)); // let it finish binding
      log('upstream_back', { waited_s: i + 3 });
      return true;
    }
    await new Promise((r) => setTimeout(r, 1000));
  }
  log('upstream_restart_failed', {});
  return false;
}

// Reclaim the browser from sessions that stopped talking.
setInterval(() => {
  if (lock.owner && Date.now() - lock.lastActivity > IDLE_RELEASE_MS && lock.waiters.length > 0) {
    const victim = lock.owner;
    stats.idleReleases++;
    log('idle_reclaim', { sid: shortSid(victim), idleMs: Date.now() - lock.lastActivity, waiting: lock.waiters.length });
    deleteUpstreamSession(victim);
    release('idle');
  }
}, 5_000).unref();

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

function jsonRpcError(res, id, code, message, data) {
  const payload = JSON.stringify({ jsonrpc: '2.0', id: id ?? null, error: { code, message, data } });
  res.writeHead(200, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(payload) });
  res.end(payload);
}

function chromeProcCount() {
  try {
    return execFileSync('pgrep', ['-fc', 'lib/chromium/chrome'], { encoding: 'utf8' }).trim();
  } catch { return '0'; }
}

/**
 * Proxy one request upstream.
 * `buffer`: collect the whole response so we can inspect/rewrite it (POST tool calls).
 * Streaming is used for GET /mcp, which is a long-lived notification channel.
 */
function proxy(req, res, body, { buffer, port = UP_PORT, upstreamPath = null }) {
  return new Promise((resolve) => {
    // @playwright/mcp rejects any request whose Host is not what it bound to, so the
    // Host must name the *target* port, not the gateway's. Profile routes also have to
    // be rewritten: the client says /mcp/linkedin, the upstream only knows /mcp.
    const headers = { ...req.headers, host: `localhost:${port}` };
    delete headers['content-length'];
    if (body && body.length) headers['content-length'] = Buffer.byteLength(body);
    const target = upstreamPath || req.url;

    const up = http.request({ host: UP_HOST, port, path: target, method: req.method, headers }, (ur) => {
      if (!buffer) {
        res.writeHead(ur.statusCode, ur.headers);
        ur.pipe(res);
        ur.on('end', resolve);
        return;
      }
      const chunks = [];
      ur.on('data', (c) => chunks.push(c));
      ur.on('end', () => resolve({ status: ur.statusCode, headers: ur.headers, body: Buffer.concat(chunks) }));
    });
    up.on('error', (e) => {
      log('upstream_error', { err: e.message, port });
      if (!res.headersSent) {
        jsonRpcError(res, null, -32001,
          `Browser backend unreachable on ${UP_HOST}:${port}. The MCP server may be restarting; retry in a few seconds.`);
      } else { res.end(); }
      resolve(null);
    });
    if (body && body.length) up.write(body);
    up.end();
  });
}

// --------------------------------------------------------------------- routing

const BROWSER_IN_USE = /Browser is already in use/i;

const server = http.createServer(async (req, res) => {
  // Always drain the request body, on every path. A half-read body poisons
  // HTTP keep-alive behind cloudflared -- the same failure this repo already
  // hit once with the transcript MCP server.
  const body = req.method === 'POST' || req.method === 'PUT' ? await readBody(req) : Buffer.alloc(0);

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
      },
      queue: {
        depth: lock.waiters.length,
        max: MAX_QUEUE,
        waiting_s: lock.waiters.map((w) => Math.round((Date.now() - w.at) / 1000)),
      },
      limits: { idle_release_ms: IDLE_RELEASE_MS, max_wait_ms: MAX_WAIT_MS },
      stats,
      profiles: profiles.status(),
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

  let upstream;
  try {
    upstream = await profiles.ensure(route.profile);
  } catch (e) {
    log('profile_unavailable', { profile: route.profile, err: e.message });
    return jsonRpcError(res, null, -32006,
      `Could not start a browser for profile "${route.profile}": ${e.message}`,
      { profile: route.profile, retry_after_s: 30 });
  }
  const P = { port: upstream.port, upstreamPath: route.upstreamPath };

  const sid = req.headers['mcp-session-id'] || null;

  // Session teardown: let it through, then hand the browser to whoever is next.
  if (req.method === 'DELETE') {
    await proxy(req, res, body, { buffer: false, ...P });
    if (sid) { upstreamSessions.delete(sid); saveSessions(); }
    if (sid && lock.owner === sid) release('session_closed');
    return;
  }

  // GET /mcp is the SSE notification channel -- stream it, never buffer.
  if (req.method === 'GET') return void (await proxy(req, res, body, { buffer: false, ...P }));

  let rpc = null;
  try { rpc = JSON.parse(body.toString('utf8')); } catch { /* forward opaquely */ }

  const toolName = rpc?.method === 'tools/call' ? rpc?.params?.name : null;
  const needsBrowser = typeof toolName === 'string' && toolName.startsWith('browser_');

  if (!needsBrowser) {
    const r = await proxy(req, res, body, { buffer: true, ...P });
    // Learn the session id handed out by initialize, so we can clean it up later.
    const newSid = r?.headers?.['mcp-session-id'];
    if (newSid) { upstreamSessions.set(newSid, Date.now()); saveSessions(); log('session_opened', { sid: shortSid(newSid) }); }
    if (r) sendBuffered(res, r.status, r.headers, r.body);
    return;
  }

  // ---- this call wants the browser
  let ticket;
  try {
    ticket = await acquire(sid);
  } catch (e) {
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

  profiles.touch(route.profile);
  if (ticket.queued) log('lock_acquired_after_wait', { sid: shortSid(sid), tool: toolName, waitedMs: ticket.waitedMs });
  lock.lastActivity = Date.now();

  let r = await proxy(req, res, body, { buffer: true, ...P });
  lock.lastActivity = Date.now();

  // We hold the lock, so an in-use error means an untracked upstream session is
  // squatting on the browser. Clear it and try once more before giving up.
  if (r && BROWSER_IN_USE.test(r.body.toString('utf8'))) {
    stats.reconciles++;
    log('upstream_in_use', { sid: shortSid(sid), tool: toolName, action: 'reconciling' });
    const dropped = await reconcileUpstream(sid);
    if (dropped > 0) {
      r = await proxy(req, res, body, { buffer: true, ...P });
      lock.lastActivity = Date.now();
      log('retry_after_reconcile', { sid: shortSid(sid), tool: toolName,
        ok: r ? !BROWSER_IN_USE.test(r.body.toString('utf8')) : false });
    }
    // Nothing to drop, or dropping did not help: bounce the upstream. The
    // caller's own session dies with it, so tell them to reconnect rather than
    // silently handing back a response from a different browser.
    if (r && BROWSER_IN_USE.test(r.body.toString('utf8'))) {
      const back = await restartUpstream();
      release('upstream_restarted');
      return jsonRpcError(res, rpc?.id, -32004,
        back
          ? 'The browser was wedged by an untracked session and has been restarted. Your session is gone — reconnect (re-initialize) and retry; it should work immediately.'
          : 'The browser was wedged and the backend did not come back. Check supervise.sh status on the device.',
        { retry_after_s: back ? 2 : 60, reconnect_required: true });
    }
  }

  if (r) {
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
// start.sh launches one upstream itself; adopt it as the default profile so we never
// spawn a second browser onto the same --user-data-dir.
// Adopt start.sh's upstream only if it actually exists. When GW_NO_STATIC_UPSTREAM=1
// nothing is listening, and `default` becomes an ordinary on-demand profile -- which is
// what makes GW_MAX_LIVE_PROFILES enforceable.
// Clear out upstreams orphaned by a previous gateway process before deciding what is
// live -- otherwise we spawn duplicates onto directories they still hold.
profiles.reapOrphans();

upReachable().then((live) => {
  if (live) profiles.adoptStatic(UP_PORT, process.env.PROFILE || null);
  else log('no_static_upstream', { port: UP_PORT, note: 'default will be spawned on demand' });
});

server.listen(LISTEN_PORT, LISTEN_HOST, () => {
  log('listening', { host: LISTEN_HOST, port: LISTEN_PORT, upstream: `${UP_HOST}:${UP_PORT}`,
                     idle_release_ms: IDLE_RELEASE_MS, max_wait_ms: MAX_WAIT_MS, max_queue: MAX_QUEUE,
                     max_snapshot_bytes: MAX_SNAPSHOT_BYTES || 'off',
                     auth: 'oauth2.1 + static bearer', secrets_dir: auth.CONF_DIR });
});

for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => { log('shutdown', { sig }); server.close(() => process.exit(0)); });
}
