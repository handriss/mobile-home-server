'use strict';
//
// profiles.js — a pool of @playwright/mcp upstreams, one per named profile.
//
// Ticket #5: an agent asks for profile "linkedin" and gets the cookies and logins that
// belong to it, surviving restarts, fully isolated from every other profile.
//
// @playwright/mcp allows exactly one browser per --user-data-dir, so isolation is not
// something the gateway can fake on top of a single upstream: each profile needs its own
// upstream process with its own --user-data-dir. This module owns those processes —
// spawning on first use, health-checking, and tearing them down when idle so a phone
// does not end up holding six Chromiums for profiles nobody is using.
//
// Selection is by URL path: POST /mcp/linkedin. Bare /mcp means DEFAULT_PROFILE, so
// every existing client keeps working unchanged.
//
// Node stdlib only.

const { spawn } = require('node:child_process');
const fs = require('node:fs');
const net = require('node:net');
const path = require('node:path');

const LAB = process.env.LAB || path.join(process.env.HOME || '/tmp', 'job-search-pipeline-data');
const PROFILES_DIR = process.env.GW_PROFILES_DIR || path.join(LAB, 'profiles');
const DEFAULT_PROFILE = process.env.GW_DEFAULT_PROFILE || 'default';

// Upstreams get ports from this base upward. The statically-started upstream from
// start.sh keeps its own port and is adopted as the default profile (see adoptStatic).
const PORT_BASE = Number(process.env.GW_PROFILE_PORT_BASE || 8940);
// Hard ceiling on simultaneously *running* browsers. This is a phone.
const MAX_LIVE = Number(process.env.GW_MAX_LIVE_PROFILES || 2);
// Tear down a profile's browser after this long with no calls.
const IDLE_MS = Number(process.env.GW_PROFILE_IDLE_MS || 10 * 60 * 1000);
const SPAWN_TIMEOUT_MS = Number(process.env.GW_PROFILE_SPAWN_TIMEOUT_MS || 45_000);

// How to launch an upstream. Defaults match start.sh on the phone.
const NODE_BIN = process.env.GW_NODE_BIN || process.execPath;
const MCP_CLI = process.env.GW_MCP_CLI || path.join(LAB, 'node_modules', '@playwright', 'mcp', 'cli.js');
const SHIM = process.env.GW_SHIM || path.join(LAB, 'shim.cjs');
const CHROME = process.env.GW_CHROME || `${process.env.PREFIX || ''}/lib/chromium/chrome`;
const VIEWPORT = process.env.GW_VIEWPORT || '1280,900';
const EXTRA_ARGS = (process.env.GW_MCP_EXTRA_ARGS || '').split(' ').filter(Boolean);

// Profile names become directory names and appear in URLs: keep them boring.
const VALID_NAME = /^[a-z0-9][a-z0-9_-]{0,31}$/i;

const log = (evt, fields = {}) =>
  console.log(JSON.stringify({ ts: new Date().toISOString(), evt, ...fields }));

/** name -> { name, port, proc, dir, lastUsed, startedAt, static } */
const live = new Map();
// Profiles pinned open by a human. A pinned profile is never idle-reaped and never
// evicted, so a hand-login session cannot be torn down mid-typing (#5).
const pinned = new Set();
let nextPort = PORT_BASE;

function isValidName(n) { return typeof n === 'string' && VALID_NAME.test(n); }

/**
 * Split a request path into { profile, upstreamPath }.
 *   /mcp            -> { default,  /mcp }
 *   /mcp/linkedin   -> { linkedin, /mcp }
 * Returns null if the path is not an /mcp route; { error } if the name is malformed.
 */
function routeOf(urlPath) {
  const [bare] = urlPath.split('?');
  if (bare === '/mcp' || bare === '/mcp/') return { profile: DEFAULT_PROFILE, upstreamPath: '/mcp' };
  const m = /^\/mcp\/([^/]+)\/?$/.exec(bare);
  if (!m) return null;
  const name = decodeURIComponent(m[1]);
  if (!isValidName(name)) return { error: `invalid profile name "${name}" (use letters, digits, - and _, max 32)` };
  return { profile: name, upstreamPath: '/mcp' };
}

const portFree = (port) => new Promise((resolve) => {
  const s = net.connect({ host: '127.0.0.1', port });
  const done = (v) => { s.destroy(); resolve(v); };
  s.setTimeout(700);
  s.on('connect', () => done(false));
  s.on('error', () => done(true));
  s.on('timeout', () => done(true));
});

const portListening = (port) => portFree(port).then((free) => !free);

async function allocPort() {
  for (let i = 0; i < 200; i++) {
    const p = nextPort++;
    if (nextPort > PORT_BASE + 400) nextPort = PORT_BASE;
    if ([...live.values()].some((u) => u.port === p)) continue;
    if (await portFree(p)) return p;
  }
  throw new Error('no free port for a profile upstream');
}

/**
 * Adopt the upstream that start.sh already launched, so the default profile does not
 * get a second browser spawned on top of it. Called once at gateway startup.
 */
function adoptStatic(port, dir) {
  live.set(DEFAULT_PROFILE, {
    name: DEFAULT_PROFILE, port, proc: null, dir, static: true,
    lastUsed: Date.now(), startedAt: Date.now(),
  });
  log('profile_adopted', { profile: DEFAULT_PROFILE, port, dir, managed_by: 'start.sh' });
}

/** Stop the least-recently-used non-static profile to stay under MAX_LIVE. */
async function evictIfNeeded(keep) {
  const candidates = [...live.values()]
    .filter((u) => !u.static && u.name !== keep && !pinned.has(u.name))
    .sort((a, b) => a.lastUsed - b.lastUsed);
  while (live.size >= MAX_LIVE && candidates.length) {
    const victim = candidates.shift();
    log('profile_evicted', { profile: victim.name, idle_s: Math.round((Date.now() - victim.lastUsed) / 1000),
                             reason: 'max_live_profiles' });
    await stop(victim.name);
  }
}

function spawnUpstream(name, port, dir) {
  fs.mkdirSync(dir, { recursive: true });
  const args = [];
  if (fs.existsSync(SHIM)) args.push('--require', SHIM);
  args.push(MCP_CLI,
    '--port', String(port), '--host', '127.0.0.1',
    '--browser', 'chromium',
    '--user-data-dir', dir,
    '--viewport-size', VIEWPORT,
    ...EXTRA_ARGS);
  if (fs.existsSync(CHROME)) args.push('--executable-path', CHROME, '--no-sandbox');

  const out = fs.openSync(path.join(LAB, `mcp-${name}.log`), 'a');
  const proc = spawn(NODE_BIN, args, {
    detached: true, stdio: ['ignore', out, out],
    env: { ...process.env },      // DISPLAY matters: the phone runs headed on Xvnc
  });
  proc.unref();
  return proc;
}

/**
 * Ensure profile `name` has a live upstream; return it. Concurrent callers share one
 * in-flight spawn rather than racing two browsers onto the same --user-data-dir.
 */
const pending = new Map();
function ensure(name) {
  const existing = live.get(name);
  if (existing) { existing.lastUsed = Date.now(); return Promise.resolve(existing); }
  if (pending.has(name)) return pending.get(name);

  const p = (async () => {
    await evictIfNeeded(name);
    const dir = path.join(PROFILES_DIR, name);
    const port = await allocPort();
    log('profile_starting', { profile: name, port, dir });
    const proc = spawnUpstream(name, port, dir);

    const deadline = Date.now() + SPAWN_TIMEOUT_MS;
    while (Date.now() < deadline) {
      if (await portListening(port)) {
        const u = { name, port, proc, dir, static: false, lastUsed: Date.now(), startedAt: Date.now() };
        live.set(name, u);
        log('profile_ready', { profile: name, port, ms: Date.now() - (deadline - SPAWN_TIMEOUT_MS) });
        return u;
      }
      if (proc.exitCode !== null) {
        throw new Error(`profile "${name}" upstream exited immediately (code ${proc.exitCode}) — see ${LAB}/mcp-${name}.log`);
      }
      await new Promise((r) => setTimeout(r, 400));
    }
    try { process.kill(-proc.pid, 'SIGKILL'); } catch { /* already gone */ }
    throw new Error(`profile "${name}" upstream did not start within ${SPAWN_TIMEOUT_MS / 1000}s`);
  })().finally(() => pending.delete(name));

  pending.set(name, p);
  return p;
}

async function stop(name) {
  const u = live.get(name);
  if (!u) return false;
  live.delete(name);
  if (u.static || !u.proc) { log('profile_stop_skipped', { profile: name, reason: 'managed by start.sh' }); return false; }
  try { process.kill(-u.proc.pid, 'SIGTERM'); } catch { /* gone */ }
  await new Promise((r) => setTimeout(r, 1200));
  try { process.kill(-u.proc.pid, 'SIGKILL'); } catch { /* gone */ }
  log('profile_stopped', { profile: name, port: u.port });
  return true;
}

function touch(name) { const u = live.get(name); if (u) u.lastUsed = Date.now(); }

/** Hold a profile's browser open for a hand-login. Returns the upstream. */
async function pin(name) {
  const u = await ensure(name);
  pinned.add(name);
  log('profile_pinned', { profile: name, port: u.port });
  return u;
}
function unpin(name) {
  const had = pinned.delete(name);
  if (had) log('profile_unpinned', { profile: name });
  touch(name);                       // restart the idle clock from now
  return had;
}

/** Profiles that exist on disk, whether or not a browser is currently running. */
function known() {
  try {
    return fs.readdirSync(PROFILES_DIR, { withFileTypes: true })
      .filter((d) => d.isDirectory() && isValidName(d.name))
      .map((d) => d.name).sort();
  } catch { return []; }
}

function status() {
  return {
    default: DEFAULT_PROFILE,
    known: known(),
    max_live: MAX_LIVE,
    idle_teardown_ms: IDLE_MS,
    pinned: [...pinned],
    live: [...live.values()].map((u) => ({
      profile: u.name, port: u.port, static: !!u.static, pinned: pinned.has(u.name),
      up_s: Math.round((Date.now() - u.startedAt) / 1000),
      idle_s: Math.round((Date.now() - u.lastUsed) / 1000),
    })),
  };
}

// Idle teardown. Never reaps the static upstream — start.sh owns that one.
const sweeper = setInterval(() => {
  for (const u of [...live.values()]) {
    if (u.static || pinned.has(u.name)) continue;
    if (Date.now() - u.lastUsed > IDLE_MS) {
      log('profile_idle_teardown', { profile: u.name, idle_s: Math.round((Date.now() - u.lastUsed) / 1000) });
      stop(u.name);
    }
  }
}, 30_000);
sweeper.unref();

async function stopAll() { await Promise.all([...live.keys()].map(stop)); }

module.exports = {
  DEFAULT_PROFILE, PROFILES_DIR, MAX_LIVE,
  routeOf, ensure, stop, stopAll, touch, known, status, adoptStatic, isValidName,
  pin, unpin,
};
