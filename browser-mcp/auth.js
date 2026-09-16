'use strict';
//
// auth.js — the gateway's own OAuth 2.1 authority + static bearer.
//
// A direct port of the scheme already proven on this phone by youtube-transcript-mcp's
// server.py. Cloudflare Access is deliberately NOT used: its DCR endpoint 404s, and
// claude.ai web is broken against CF Managed OAuth (see youtube-transcript-mcp/README).
// So the server is its own authorization server — just enough OAuth 2.1 (PKCE + RFC 7591
// dynamic client registration) for claude.ai and Claude Code to self-register, gated by
// an owner password. The tunnel is public, so that password is the whole perimeter.
//
// A static bearer is also accepted, for CLI clients that cannot do a browser flow.
//
// Tokens are stateless HMAC blobs: "<base64url(json)>.<base64url(hmac)>". The signing key
// is persisted, so tokens survive a gateway restart and you authorize once, not every time.
//
// Node stdlib only, to match gateway.js.

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { URL, URLSearchParams } = require('node:url');

const CONF_DIR = process.env.BROWSER_MCP_CONF ||
  path.join(process.env.HOME || '/tmp', '.config', 'browser-mcp');

/** Read a secret from CONF_DIR/name, else generate + persist it (0600). */
function persisted(name, gen) {
  const p = path.join(CONF_DIR, name);
  try { return fs.readFileSync(p, 'utf8').trim(); } catch { /* not yet created */ }
  const v = gen();
  fs.mkdirSync(CONF_DIR, { recursive: true, mode: 0o700 });
  fs.writeFileSync(p, v, { mode: 0o600 });
  return v;
}

const SECRET = Buffer.from(
  process.env.BROWSER_MCP_SECRET || persisted('oauth_secret', () => crypto.randomBytes(32).toString('hex')));
const AUTH_PASSWORD =
  process.env.BROWSER_MCP_PASSWORD || persisted('password', () => crypto.randomBytes(9).toString('base64url'));
const STATIC_TOKEN =
  process.env.BROWSER_MCP_TOKEN || persisted('bearer_token', () => crypto.randomBytes(18).toString('base64url'));

const AT_TTL = 24 * 3600;            // access token
const RT_TTL = 90 * 24 * 3600;       // refresh token
const CODE_TTL = 600;                // authorization code

// ------------------------------------------------------------------ token crypto

const b64u = (b) => Buffer.from(b).toString('base64url');

function sign(payload) {
  // sorted keys so the same payload always serializes identically
  const body = b64u(JSON.stringify(payload, Object.keys(payload).sort()));
  const sig = b64u(crypto.createHmac('sha256', SECRET).update(body).digest());
  return `${body}.${sig}`;
}

/** Return the payload if signature + type + expiry all check out, else null. */
function verify(tok, typ) {
  try {
    const i = tok.indexOf('.');
    if (i < 0) return null;
    const body = tok.slice(0, i), sig = tok.slice(i + 1);
    const good = b64u(crypto.createHmac('sha256', SECRET).update(body).digest());
    const a = Buffer.from(sig), b = Buffer.from(good);
    if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return null;
    const p = JSON.parse(Buffer.from(body, 'base64url').toString('utf8'));
    if (p.t !== typ) return null;
    if (p.exp && Date.now() / 1000 > p.exp) return null;
    return p;
  } catch { return null; }
}

const safeEqual = (a, b) => {
  const x = Buffer.from(String(a)), y = Buffer.from(String(b));
  return x.length === y.length && crypto.timingSafeEqual(x, y);
};

// Authorization codes are single-use. jti -> expiry.
const usedCodes = new Map();
function consumeCode(jti, exp) {
  const now = Date.now() / 1000;
  for (const [k, e] of usedCodes) if (e < now) usedCodes.delete(k);
  if (!jti || usedCodes.has(jti)) return false;
  usedCodes.set(jti, exp);
  return true;
}

// ------------------------------------------------------------------ http helpers

const CORS = { 'Access-Control-Allow-Origin': '*' };

function send(res, code, body, type, extra = {}) {
  const buf = Buffer.isBuffer(body) ? body : Buffer.from(body ?? '');
  const headers = { 'Content-Length': buf.length, ...extra };
  if (type) headers['Content-Type'] = type;
  res.writeHead(code, headers);
  res.end(buf);
}
const json = (res, code, obj, extra = {}) =>
  send(res, code, JSON.stringify(obj), 'application/json', extra);

// When set, this is the authoritative public origin and the Host header is ignored.
// Behind a tunnel this MUST be set: OAuth discovery documents advertise the issuer and
// endpoints, so a spoofed Host would point a client's whole auth flow at an attacker.
const PUBLIC_URL = (process.env.BROWSER_MCP_PUBLIC_URL || '').replace(/\/$/, '');

/** Public base URL. Behind cloudflared the proto is only in X-Forwarded-Proto. */
function baseUrl(req) {
  if (PUBLIC_URL) return PUBLIC_URL;
  const host = req.headers['x-forwarded-host'] || req.headers.host || 'localhost';
  const proto = req.headers['x-forwarded-proto'] ||
    (/^(localhost|127\.0\.0\.1)(:|$)/.test(host) ? 'http' : 'https');
  return `${proto}://${host}`;
}

const esc = (s) => String(s).replace(/[&<>"']/g,
  (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const CONSENT_HTML = (client, err, hidden) => `<!doctype html><html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>Authorize · Phone browser MCP</title>
<style>body{font:16px/1.5 system-ui,sans-serif;max-width:26rem;margin:12vh auto;padding:0 1.2rem;color:#1a1a1a;background:#fafafa}
h1{font-size:1.2rem}.c{background:#fff;border:1px solid #e3e3e3;border-radius:12px;padding:1.4rem}
code{background:#f0f0f0;padding:.1em .35em;border-radius:5px;font-size:.85em}
input{width:100%;box-sizing:border-box;padding:.7rem;font-size:1rem;border:1px solid #ccc;border-radius:8px;margin:.5rem 0}
button{width:100%;padding:.75rem;font-size:1rem;border:0;border-radius:8px;background:#111;color:#fff;cursor:pointer}
.e{color:#b00020;font-size:.9em}.m{color:#666;font-size:.85em}
@media(prefers-color-scheme:dark){body{background:#151515;color:#eee}.c{background:#1e1e1e;border-color:#333}
input{background:#111;color:#eee;border-color:#444}code{background:#2a2a2a}}</style></head>
<body><div class=c><h1>Authorize <b>${esc(client)}</b></h1>
<p class=m>This grants full control of the <b>real Chromium browser</b> running on your phone —
including any sites already logged in within its profile. Enter the owner password to approve.</p>
${err}<form method=post action="/authorize">${hidden}
<input type=password name=password placeholder="Owner password" autofocus autocomplete=current-password>
<button type=submit>Approve access</button></form></div></body></html>`;

// ------------------------------------------------------------------ auth checks

/** True if the request carries a valid static bearer or OAuth access token. */
function isAuthed(req) {
  const h = req.headers.authorization || '';
  if (!h.startsWith('Bearer ')) return false;
  const tok = h.slice(7);
  if (safeEqual(tok, STATIC_TOKEN)) return true;
  return verify(tok, 'at') !== null;
}

function unauthorized(req, res) {
  json(res, 401,
    { jsonrpc: '2.0', id: null, error: { code: -32001, message: 'unauthorized' } },
    { 'WWW-Authenticate': `Bearer resource_metadata="${baseUrl(req)}/.well-known/oauth-protected-resource"` });
}

// ------------------------------------------------------------------ oauth endpoints

function metaProtectedResource(req, res) {
  const b = baseUrl(req);
  json(res, 200, {
    resource: `${b}/mcp`,
    authorization_servers: [b],
    bearer_methods_supported: ['header'],
    scopes_supported: ['mcp'],
  }, CORS);
}

function metaAuthServer(req, res) {
  const b = baseUrl(req);
  json(res, 200, {
    issuer: b,
    authorization_endpoint: `${b}/authorize`,
    token_endpoint: `${b}/token`,
    registration_endpoint: `${b}/register`,
    response_types_supported: ['code'],
    grant_types_supported: ['authorization_code', 'refresh_token'],
    code_challenge_methods_supported: ['S256'],
    token_endpoint_auth_methods_supported: ['none'],
    scopes_supported: ['mcp'],
  }, CORS);
}

function register(res, raw) {
  let req0;
  try { req0 = JSON.parse(raw || '{}'); }
  catch { return json(res, 400, { error: 'invalid_client_metadata' }, CORS); }
  const ru = req0.redirect_uris || [];
  if (!Array.isArray(ru) || !ru.every((u) => typeof u === 'string')) {
    return json(res, 400, { error: 'invalid_redirect_uri' }, CORS);
  }
  const now = Math.floor(Date.now() / 1000);
  json(res, 201, {
    client_id: sign({ t: 'client', ru, iat: now }),
    client_id_issued_at: now,
    redirect_uris: ru,
    token_endpoint_auth_method: 'none',
    grant_types: ['authorization_code', 'refresh_token'],
    response_types: ['code'],
    client_name: req0.client_name || '',
  }, CORS);
}

/** Validate shared /authorize params -> {client, ru, err}. */
function authorizeParams(p) {
  const client = verify(p.client_id || '', 'client');
  if (!client) return { client: null, ru: null, err: 'unknown or invalid client_id' };
  const ru = p.redirect_uri || '';
  if (!client.ru.includes(ru)) return { client: null, ru: null, err: 'redirect_uri not registered for this client' };
  if (p.response_type !== 'code') return { client, ru, err: "response_type must be 'code'" };
  if (p.code_challenge_method !== 'S256' || !p.code_challenge) return { client, ru, err: 'PKCE S256 required' };
  return { client, ru, err: null };
}

const CARRY = ['client_id', 'redirect_uri', 'response_type', 'state', 'scope',
  'code_challenge', 'code_challenge_method'];

function authorizeGet(res, p, bad) {
  const { ru, err } = authorizeParams(p);
  if (err && ru === null) return send(res, 400, `invalid authorization request: ${err}`, 'text/plain');
  // Don't prompt for the owner password on a request that cannot succeed -- /authorize
  // POST re-validates these params before checking the password, so the form would
  // always fail. Say what is wrong instead of harvesting a keystroke for nothing.
  if (err) return send(res, 400, `invalid authorization request: ${err}`, 'text/plain');
  const hidden = CARRY.filter((k) => p[k])
    .map((k) => `<input type=hidden name="${esc(k)}" value="${esc(p[k])}">`).join('');
  send(res, 200,
    CONSENT_HTML('the MCP client', bad ? '<p class=e>Wrong password — try again.</p>' : '', hidden),
    'text/html; charset=utf-8');
}

function redirect(res, location) { send(res, 302, '', null, { Location: location }); }
function redirectErr(res, ru, state, code, desc) {
  const qs = new URLSearchParams({ error: code, error_description: desc, ...(state ? { state } : {}) });
  redirect(res, `${ru}${ru.includes('?') ? '&' : '?'}${qs}`);
}

function authorizePost(res, form) {
  const { ru, err } = authorizeParams(form);
  if (err) {
    if (ru === null) return send(res, 400, `invalid request: ${err}`, 'text/plain');
    return redirectErr(res, ru, form.state || '', 'invalid_request', err);
  }
  if (!safeEqual(form.password || '', AUTH_PASSWORD)) return authorizeGet(res, form, true);
  const code = sign({
    t: 'code', ru, cc: form.code_challenge,
    jti: crypto.randomBytes(9).toString('base64url'),
    exp: Math.floor(Date.now() / 1000) + CODE_TTL,
  });
  const qs = new URLSearchParams({ code, ...(form.state ? { state: form.state } : {}) });
  redirect(res, `${ru}${ru.includes('?') ? '&' : '?'}${qs}`);
}

function token(res, form) {
  const bad = (desc) => json(res, 400,
    { error: 'invalid_grant', ...(desc ? { error_description: desc } : {}) }, CORS);

  if (form.grant_type === 'authorization_code') {
    const code = verify(form.code || '', 'code');
    if (!code) return bad();
    if (code.ru !== (form.redirect_uri || '')) return bad('redirect_uri mismatch');
    const verifier = form.code_verifier || '';
    const challenge = b64u(crypto.createHash('sha256').update(verifier).digest());
    if (!verifier || !safeEqual(challenge, code.cc)) return bad('PKCE failed');
    // Only burn the code once the exchange is otherwise valid.
    if (!consumeCode(code.jti, code.exp)) return bad('code already used');
  } else if (form.grant_type === 'refresh_token') {
    if (!verify(form.refresh_token || '', 'rt')) return bad();
  } else {
    return json(res, 400, { error: 'unsupported_grant_type' }, CORS);
  }
  const now = Math.floor(Date.now() / 1000);
  json(res, 200, {
    access_token: sign({ t: 'at', exp: now + AT_TTL }),
    token_type: 'Bearer',
    expires_in: AT_TTL,
    refresh_token: sign({ t: 'rt', exp: now + RT_TTL }),
    scope: 'mcp',
  }, { 'Cache-Control': 'no-store', ...CORS });
}

// ------------------------------------------------------------------ dispatch

/**
 * Handle any OAuth/discovery route. Returns true if the request was fully handled.
 *
 * `raw` is the already-drained request body. gateway.js MUST drain the body on every
 * POST path before calling this -- including 401s and 404s. HTTP/1.1 keep-alive
 * (cloudflared reuses origin connections) desynchronizes if a branch returns without
 * consuming the body: the leftover bytes get parsed as the next request line.
 */
function handleAuthRoutes(req, res, raw) {
  const u = new URL(req.url, 'http://x');
  const p = u.pathname;

  if (req.method === 'OPTIONS') {
    send(res, 204, '', null, {
      ...CORS,
      'Access-Control-Allow-Methods': 'GET, POST, DELETE, OPTIONS',
      'Access-Control-Allow-Headers': 'Authorization, Content-Type, mcp-session-id, mcp-protocol-version',
      'Access-Control-Max-Age': '86400',
    });
    return true;
  }

  if (req.method === 'GET') {
    if (p.replace(/\/$/, '') === '/.well-known/oauth-protected-resource' ||
        p === '/.well-known/oauth-protected-resource/mcp') { metaProtectedResource(req, res); return true; }
    if (p === '/.well-known/oauth-authorization-server' ||
        p === '/.well-known/openid-configuration') { metaAuthServer(req, res); return true; }
    if (p === '/authorize') { authorizeGet(res, Object.fromEntries(u.searchParams), false); return true; }
    return false;
  }

  if (req.method === 'POST') {
    const form = () => Object.fromEntries(new URLSearchParams(raw || ''));
    if (p === '/register') { register(res, raw); return true; }
    if (p === '/authorize') { authorizePost(res, form()); return true; }
    if (p === '/token') { token(res, form()); return true; }
    return false;
  }
  return false;
}

module.exports = {
  CONF_DIR, AUTH_PASSWORD, STATIC_TOKEN,
  isAuthed, unauthorized, handleAuthRoutes, baseUrl,
};
