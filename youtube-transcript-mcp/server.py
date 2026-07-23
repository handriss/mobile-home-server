#!/usr/bin/env python3
"""
YouTube transcript MCP server — Streamable HTTP transport, PURE PYTHON STDLIB.

No third-party MCP SDK: the official `mcp` package needs pydantic-core (Rust), which
won't build on Termux/Android. This hand-rolls the small slice of the MCP Streamable
HTTP protocol we need (initialize / tools.list / tools.call / ping) so it runs on the
phone with only the standard library + yt-dlp. Protocol-verified against Claude Code.

WHY ON THE PHONE: the yt-dlp fetch must go out from the Oppo's Hungarian residential
IP. A Cloudflare tunnel in front only relays inbound MCP; the fetch still leaves here.
WHY yt-dlp: youtube-captions-scraper / youtubei.js are broken vs current YouTube (2026-07);
yt-dlp works — verified on the phone (title + transcript, EN/ES, short/long).

Tool: get_transcript(url, lang="en", timestamps=False, cursor="")  -> title + transcript,
language fallback, disk cache, cursor pagination, and a rate limiter on uncached fetches.

Env: YT_MCP_HOST (0.0.0.0), YT_MCP_PORT (8765), YT_MCP_CACHE, YT_MCP_TTL, YT_MCP_CHUNK
     (90000), YT_MCP_YTDLP (yt-dlp), YT_MCP_RATE (uncached fetches/min, 20),
     YT_MCP_TOKEN (optional shared secret required as 'Authorization: Bearer ...').
"""
import os, re, json, base64, subprocess, tempfile, time, glob, threading, collections
import hmac, hashlib, secrets, html
from urllib.parse import urlparse, parse_qs, urlencode
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST      = os.environ.get("YT_MCP_HOST", "0.0.0.0")
PORT      = int(os.environ.get("YT_MCP_PORT", "8765"))
CACHE_DIR = os.environ.get("YT_MCP_CACHE", os.path.expanduser("~/.cache/yt-transcript-mcp"))
CACHE_TTL = int(os.environ.get("YT_MCP_TTL", str(30 * 24 * 3600)))
CHUNK     = int(os.environ.get("YT_MCP_CHUNK", "90000"))
YTDLP     = os.environ.get("YT_MCP_YTDLP", "yt-dlp")
RATE_MAX  = int(os.environ.get("YT_MCP_RATE", "20"))
os.makedirs(CACHE_DIR, exist_ok=True)

VIDEO_ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")
_fetch_lock = threading.Lock()
_recent = collections.deque()

# ------------------------------- auth config & crypto -------------------------------
# server.py is the auth authority (Cloudflare Access's DCR endpoint 404s, and claude.ai
# web is broken against CF Managed OAuth — see README). We speak just enough OAuth 2.1
# (PKCE + RFC 7591 DCR) for claude.ai + Claude Code to self-register and get a token,
# gated by an owner password so only you can approve — that's what protects the phone's
# residential IP. A static bearer (YT_MCP_TOKEN) is also accepted for CLI convenience.
CONF_DIR = os.environ.get("YT_MCP_CONF", os.path.expanduser("~/.config/yt-mcp"))
os.makedirs(CONF_DIR, exist_ok=True)

def _persisted(name, gen):
    """Read a secret from CONF_DIR/name, else generate+persist it (survives restarts)."""
    p = os.path.join(CONF_DIR, name)
    if os.path.exists(p):
        return open(p, encoding="utf-8").read().strip()
    v = gen()
    fd = os.open(p, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(v)
    return v

# HMAC key for stateless tokens; owner consent password; static CLI bearer. Env overrides file.
SECRET        = _persisted("oauth_secret", lambda: secrets.token_hex(32)).encode()
AUTH_PASSWORD = os.environ.get("YT_MCP_AUTH_PASSWORD") or _persisted("password", lambda: secrets.token_urlsafe(12))
TOKEN         = os.environ.get("YT_MCP_TOKEN") or _persisted("bearer_token", lambda: secrets.token_urlsafe(24))

AT_TTL = 24 * 3600            # access token
RT_TTL = 90 * 24 * 3600       # refresh token
CODE_TTL = 600               # authorization code

_used_codes = {}                 # jti -> expiry, to make authorization codes single-use
_codes_lock = threading.Lock()

def _consume_code(jti, exp):
    """Return True the first time a code's jti is seen; False on replay."""
    now = time.time()
    with _codes_lock:
        for k, e in list(_used_codes.items()):
            if e < now:
                del _used_codes[k]
        if jti in _used_codes:
            return False
        _used_codes[jti] = exp
        return True

def _b64u(b):     return base64.urlsafe_b64encode(b).rstrip(b"=").decode()
def _b64u_dec(s): return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))

def _sign(payload: dict) -> str:
    body = _b64u(json.dumps(payload, separators=(",", ":"), sort_keys=True).encode())
    sig = _b64u(hmac.new(SECRET, body.encode(), hashlib.sha256).digest())
    return f"{body}.{sig}"

def _verify(tok: str, typ: str):
    """Return the payload dict if signature + type + expiry are valid, else None."""
    try:
        body, sig = tok.split(".", 1)
        good = _b64u(hmac.new(SECRET, body.encode(), hashlib.sha256).digest())
        if not hmac.compare_digest(sig, good):
            return None
        p = json.loads(_b64u_dec(body))
        if p.get("t") != typ:
            return None
        if p.get("exp") and time.time() > p["exp"]:
            return None
        return p
    except Exception:
        return None

# ------------------------------- transcript core -------------------------------

def _rate_gate():
    now = time.time()
    while _recent and now - _recent[0] > 60:
        _recent.popleft()
    if len(_recent) >= RATE_MAX:
        raise RuntimeError(f"Rate limit: >{RATE_MAX} new videos/min. Wait a moment (cached videos are fine).")
    _recent.append(now)


def extract_video_id(s: str) -> str:
    s = (s or "").strip()
    if VIDEO_ID_RE.match(s):
        return s
    u = urlparse(s if "//" in s else "https://" + s)
    host = (u.hostname or "").lower()
    if host.startswith("www."):
        host = host[4:]
    vid = ""
    if host == "youtu.be":
        vid = u.path.lstrip("/").split("/")[0]
    elif host.endswith("youtube.com"):
        parts = [p for p in u.path.split("/") if p]
        if parts and parts[0] in ("shorts", "embed", "live", "v"):
            vid = parts[1] if len(parts) > 1 else ""
        else:
            vid = parse_qs(u.query).get("v", [""])[0]
    if VIDEO_ID_RE.match(vid):
        return vid
    raise ValueError(f"Could not extract a YouTube video ID from: {s!r}")


def _fetch(video_id: str, lang: str):
    with _fetch_lock:
        _rate_gate()
        with tempfile.TemporaryDirectory() as td:
            out = os.path.join(td, "s")
            langs = f"{lang},{lang}.*,{lang}-orig,en,en.*"
            cmd = [YTDLP, "--no-simulate", "--skip-download", "--write-subs", "--write-auto-subs",
                   "--sub-langs", langs, "--sub-format", "json3", "--no-warnings",
                   "--print", "%(title)s", "-o", out,
                   f"https://www.youtube.com/watch?v={video_id}"]
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=120, check=False)
            title = next((l.strip() for l in (proc.stdout or "").splitlines() if l.strip()), "")
            files = glob.glob(os.path.join(td, "*.json3"))
            if not files:
                err = (proc.stderr or "").strip().splitlines()
                raise RuntimeError(f"No captions for {video_id} (lang={lang}): {err[-1] if err else 'none available'}")
            files.sort(key=lambda f: 0 if f".{lang}" in os.path.basename(f) else 1)
            data = json.load(open(files[0], encoding="utf-8"))
            lines = []
            for ev in data.get("events", []):
                text = "".join(seg.get("utf8", "") for seg in (ev.get("segs") or [])).strip()
                if text:
                    lines.append({"start": ev.get("tStartMs", 0) / 1000.0, "text": text})
            if not lines:
                raise RuntimeError(f"Captions for {video_id} parsed empty.")
            return title, lines


def _get(video_id: str, lang: str):
    cp = os.path.join(CACHE_DIR, f"{video_id}.{lang}.json")
    if os.path.exists(cp) and (time.time() - os.path.getmtime(cp)) < CACHE_TTL:
        d = json.load(open(cp, encoding="utf-8"))
        return d.get("title", ""), d["lines"], True
    title, lines = _fetch(video_id, lang)
    json.dump({"title": title, "lines": lines}, open(cp, "w", encoding="utf-8"))
    return title, lines, False


def _format(lines, timestamps):
    if not timestamps:
        return " ".join(l["text"] for l in lines)
    return "\n".join(f"[{int(l['start'])//60}:{int(l['start'])%60:02d}] {l['text']}" for l in lines)


def _enc(v, l, t, o):  return base64.urlsafe_b64encode(json.dumps([v, l, t, o]).encode()).decode()
def _dec(c):           return json.loads(base64.urlsafe_b64decode(c.encode()).decode())


def get_transcript(url="", lang="en", timestamps=False, cursor=""):
    if cursor:
        video_id, lang, timestamps, offset = _dec(cursor)
    else:
        video_id, offset = extract_video_id(url), 0
    title, lines, cached = _get(video_id, lang)
    full = _format(lines, timestamps)
    chunk = full[offset:offset + CHUNK]
    end = offset + len(chunk)
    if end < len(full):
        sp = chunk.rfind(" ", int(CHUNK * 0.8))
        if sp > 0:
            chunk, end = chunk[:sp], offset + sp
    head = (f"# {title or video_id}\n"
            f"video: https://youtu.be/{video_id}  ·  lang={lang}{', cached' if cached else ''}"
            f"  ·  chars {offset}-{end} of {len(full)}\n\n")
    tail = (f'\n\n[Truncated - {len(full)-end} chars remain. Continue with cursor="{_enc(video_id, lang, timestamps, end)}"]'
            if end < len(full) else "")
    return head + chunk + tail


# ------------------------------- MCP protocol -------------------------------

TOOL = {
    "name": "get_transcript",
    "description": "Fetch a YouTube video's title and transcript. Accepts a full URL "
                   "(watch/Shorts/youtu.be/embed/live) or a bare 11-char video ID. Long "
                   "transcripts paginate: if the result ends with a cursor=\"...\" line, call "
                   "again passing that cursor to get the next page.",
    "inputSchema": {
        "type": "object",
        "properties": {
            "url": {"type": "string", "description": "YouTube URL or 11-char video ID"},
            "lang": {"type": "string", "description": "Preferred caption language code (falls back to auto-captions, then English)", "default": "en"},
            "timestamps": {"type": "boolean", "description": "Prefix each line with mm:ss", "default": False},
            "cursor": {"type": "string", "description": "Pagination cursor from a previous truncated result"},
        },
    },
}
PROTOCOL_VERSIONS = {"2025-11-25", "2025-06-18", "2025-03-26"}


def dispatch(method, params):
    if method == "initialize":
        pv = params.get("protocolVersion")
        return {
            "protocolVersion": pv if pv in PROTOCOL_VERSIONS else "2025-06-18",
            "capabilities": {"tools": {"listChanged": False}},
            "serverInfo": {"name": "youtube-transcript", "version": "1.0.0"},
        }
    if method == "tools/list":
        return {"tools": [TOOL]}
    if method == "ping":
        return {}
    if method == "tools/call":
        name = params.get("name")
        args = params.get("arguments") or {}
        if name != "get_transcript":
            return {"content": [{"type": "text", "text": f"Unknown tool: {name}"}], "isError": True}
        try:
            kw = {k: args[k] for k in ("url", "lang", "timestamps", "cursor") if k in args}
            return {"content": [{"type": "text", "text": get_transcript(**kw)}], "isError": False}
        except Exception as e:
            return {"content": [{"type": "text", "text": f"Error: {e}"}], "isError": True}
    raise KeyError(method)


CONSENT_HTML = """<!doctype html><html><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>Authorize · YouTube transcript MCP</title>
<style>body{{font:16px/1.5 system-ui,sans-serif;max-width:26rem;margin:12vh auto;padding:0 1.2rem;color:#1a1a1a;background:#fafafa}}
h1{{font-size:1.2rem}}.c{{background:#fff;border:1px solid #e3e3e3;border-radius:12px;padding:1.4rem}}
code{{background:#f0f0f0;padding:.1em .35em;border-radius:5px;font-size:.85em}}
input{{width:100%;box-sizing:border-box;padding:.7rem;font-size:1rem;border:1px solid #ccc;border-radius:8px;margin:.5rem 0}}
button{{width:100%;padding:.75rem;font-size:1rem;border:0;border-radius:8px;background:#111;color:#fff;cursor:pointer}}
.e{{color:#b00020;font-size:.9em}}.m{{color:#666;font-size:.85em}}</style></head>
<body><div class=c><h1>Authorize <b>{client}</b></h1>
<p class=m>This grants access to the <code>get_transcript</code> tool running on your phone. Enter the owner password to approve.</p>
{err}<form method=post action="/authorize">{hidden}
<input type=password name=password placeholder="Owner password" autofocus autocomplete=current-password>
<button type=submit>Approve access</button></form></div></body></html>"""


def _cors(handler):
    handler.send_header("Access-Control-Allow-Origin", "*")
    handler.send_header("Access-Control-Allow-Headers", "Authorization, Content-Type")
    handler.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):  # keep it quiet
        pass

    # ---- helpers ----
    def _base(self):
        proto = self.headers.get("X-Forwarded-Proto") or "https"
        host = self.headers.get("Host") or f"{HOST}:{PORT}"
        return f"{proto}://{host}"

    def _body(self):
        return getattr(self, "_raw", b"")

    def _form(self):
        return {k: v[0] for k, v in parse_qs(self._body().decode("utf-8", "replace")).items()}

    def _send(self, code, data=b"", ctype="application/json", extra=None):
        if isinstance(data, str):
            data = data.encode()
        self.send_response(code)
        if ctype:
            self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if data:
            self.wfile.write(data)

    def _json(self, code, obj, extra=None):
        self._send(code, json.dumps(obj), "application/json", extra)

    # ---- MCP auth ----
    def _bearer(self):
        h = self.headers.get("Authorization", "")
        return h[7:] if h.startswith("Bearer ") else ""

    def _authed(self):
        tok = self._bearer()
        if not tok:
            return False
        if hmac.compare_digest(tok, TOKEN):        # static CLI bearer
            return True
        return _verify(tok, "at") is not None      # OAuth access token

    def _unauthorized(self):
        wa = f'Bearer resource_metadata="{self._base()}/.well-known/oauth-protected-resource"'
        self._json(401, {"jsonrpc": "2.0", "id": None,
                         "error": {"code": -32001, "message": "unauthorized"}},
                   extra={"WWW-Authenticate": wa})

    # ---- OAuth discovery ----
    def _meta_protected_resource(self):
        b = self._base()
        self._json(200, {
            "resource": f"{b}/mcp",
            "authorization_servers": [b],
            "bearer_methods_supported": ["header"],
            "scopes_supported": ["mcp"],
        }, extra={"Access-Control-Allow-Origin": "*"})

    def _meta_auth_server(self):
        b = self._base()
        self._json(200, {
            "issuer": b,
            "authorization_endpoint": f"{b}/authorize",
            "token_endpoint": f"{b}/token",
            "registration_endpoint": f"{b}/register",
            "response_types_supported": ["code"],
            "grant_types_supported": ["authorization_code", "refresh_token"],
            "code_challenge_methods_supported": ["S256"],
            "token_endpoint_auth_methods_supported": ["none"],
            "scopes_supported": ["mcp"],
        }, extra={"Access-Control-Allow-Origin": "*"})

    # ---- OAuth: dynamic client registration (RFC 7591) ----
    def _register(self):
        try:
            req = json.loads(self._body() or b"{}")
        except Exception:
            return self._json(400, {"error": "invalid_client_metadata"})
        ru = req.get("redirect_uris") or []
        if not isinstance(ru, list) or not all(isinstance(u, str) for u in ru):
            return self._json(400, {"error": "invalid_redirect_uri"})
        client_id = _sign({"t": "client", "ru": ru, "iat": int(time.time())})
        self._json(201, {
            "client_id": client_id,
            "client_id_issued_at": int(time.time()),
            "redirect_uris": ru,
            "token_endpoint_auth_method": "none",
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "client_name": req.get("client_name", ""),
        }, extra={"Access-Control-Allow-Origin": "*"})

    # ---- OAuth: authorization endpoint ----
    def _authorize_params(self, p):
        """Validate shared /authorize params. Returns (client, redirect_uri, err_or_None)."""
        client = _verify(p.get("client_id", ""), "client")
        if not client:
            return None, None, "unknown or invalid client_id"
        ru = p.get("redirect_uri", "")
        if ru not in client["ru"]:
            return None, None, "redirect_uri not registered for this client"
        if p.get("response_type") != "code":
            return client, ru, "response_type must be 'code'"
        if p.get("code_challenge_method") != "S256" or not p.get("code_challenge"):
            return client, ru, "PKCE S256 required"
        return client, ru, None

    def _authorize_get(self, q):
        p = {k: v[0] for k, v in q.items()}
        client, ru, err = self._authorize_params(p)
        if err and ru is None:                      # cannot safely redirect — show the error
            return self._send(400, f"invalid authorization request: {html.escape(err)}", "text/plain")
        carry = {k: p.get(k, "") for k in
                 ("client_id", "redirect_uri", "response_type", "state", "scope",
                  "code_challenge", "code_challenge_method")}
        hidden = "".join(f'<input type=hidden name="{html.escape(k)}" value="{html.escape(v)}">'
                         for k, v in carry.items() if v)
        page = CONSENT_HTML.format(
            client="the MCP client",
            err='<p class=e>Wrong password — try again.</p>' if p.get("_bad") else "",
            hidden=hidden)
        self._send(200, page, "text/html; charset=utf-8")

    def _authorize_post(self, form):
        client, ru, err = self._authorize_params(form)
        if err:
            if ru is None:
                return self._send(400, f"invalid request: {html.escape(err)}", "text/plain")
            return self._redirect_err(ru, form.get("state", ""), "invalid_request", err)
        if not hmac.compare_digest(form.get("password", ""), AUTH_PASSWORD):
            form["_bad"] = "1"                       # re-render the form with an error
            return self._authorize_get({k: [v] for k, v in form.items()})
        code = _sign({"t": "code", "ru": ru, "cc": form["code_challenge"],
                      "jti": secrets.token_urlsafe(9), "exp": int(time.time()) + CODE_TTL})
        qs = urlencode({"code": code, **({"state": form["state"]} if form.get("state") else {})})
        self._redirect(f"{ru}{'&' if '?' in ru else '?'}{qs}")

    def _redirect(self, location):
        self._send(302, b"", None, extra={"Location": location})

    def _redirect_err(self, ru, state, code, desc):
        qs = urlencode({"error": code, "error_description": desc, **({"state": state} if state else {})})
        self._redirect(f"{ru}{'&' if '?' in ru else '?'}{qs}")

    # ---- OAuth: token endpoint ----
    def _token(self, form):
        grant = form.get("grant_type")
        if grant == "authorization_code":
            code = _verify(form.get("code", ""), "code")
            if not code:
                return self._json(400, {"error": "invalid_grant"}, extra={"Access-Control-Allow-Origin": "*"})
            if code["ru"] != form.get("redirect_uri", ""):
                return self._json(400, {"error": "invalid_grant", "error_description": "redirect_uri mismatch"},
                                  extra={"Access-Control-Allow-Origin": "*"})
            verifier = form.get("code_verifier", "")
            challenge = _b64u(hashlib.sha256(verifier.encode()).digest())
            if not verifier or not hmac.compare_digest(challenge, code["cc"]):
                return self._json(400, {"error": "invalid_grant", "error_description": "PKCE failed"},
                                  extra={"Access-Control-Allow-Origin": "*"})
            if not _consume_code(code.get("jti", ""), code.get("exp", 0)):   # single-use, only after a valid exchange
                return self._json(400, {"error": "invalid_grant", "error_description": "code already used"},
                                  extra={"Access-Control-Allow-Origin": "*"})
        elif grant == "refresh_token":
            if not _verify(form.get("refresh_token", ""), "rt"):
                return self._json(400, {"error": "invalid_grant"}, extra={"Access-Control-Allow-Origin": "*"})
        else:
            return self._json(400, {"error": "unsupported_grant_type"}, extra={"Access-Control-Allow-Origin": "*"})
        now = int(time.time())
        self._json(200, {
            "access_token": _sign({"t": "at", "exp": now + AT_TTL}),
            "token_type": "Bearer",
            "expires_in": AT_TTL,
            "refresh_token": _sign({"t": "rt", "exp": now + RT_TTL}),
            "scope": "mcp",
        }, extra={"Cache-Control": "no-store", "Access-Control-Allow-Origin": "*"})

    # ---- MCP JSON-RPC ----
    def _one(self, m):
        if not isinstance(m, dict) or m.get("method") is None:
            return None                                   # a response/ack — ignore
        mid = m.get("id")
        method = m["method"]
        if method.startswith("notifications/"):
            return None                                   # notifications get no reply
        try:
            return {"jsonrpc": "2.0", "id": mid, "result": dispatch(method, m.get("params") or {})}
        except KeyError:
            return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": f"Method not found: {method}"}}
        except Exception as e:
            return {"jsonrpc": "2.0", "id": mid, "error": {"code": -32603, "message": str(e)}}

    def _mcp(self):
        if not self._authed():
            return self._unauthorized()
        try:
            msg = json.loads(self._body())
        except Exception:
            return self._json(400, {"jsonrpc": "2.0", "id": None,
                                    "error": {"code": -32700, "message": "parse error"}})
        if isinstance(msg, list):
            out = [r for r in (self._one(m) for m in msg) if r is not None]
            if out:
                self._json(200, out)
            else:
                self._send(202)
        else:
            r = self._one(msg)
            self._json(200, r) if r is not None else self._send(202)

    # ---- routing ----
    def do_OPTIONS(self):
        self.send_response(204)
        _cors(self)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        path = urlparse(self.path).path
        if path.rstrip("/") == "/.well-known/oauth-protected-resource" or \
           path == "/.well-known/oauth-protected-resource/mcp":
            return self._meta_protected_resource()
        if path == "/.well-known/oauth-authorization-server":
            return self._meta_auth_server()
        if path == "/authorize":
            return self._authorize_get(parse_qs(urlparse(self.path).query))
        self._send(404, b"", None)

    def do_POST(self):
        # Drain the whole request body up front, on EVERY path. HTTP/1.1 keep-alive
        # (cloudflared reuses origin connections) breaks if any branch — 401, error,
        # 404 — returns without consuming the body: the leftover bytes get parsed as
        # the next request line ("Unsupported method '{...}POST'").
        n = int(self.headers.get("Content-Length", 0) or 0)
        self._raw = self.rfile.read(n) if n else b""
        path = urlparse(self.path).path
        if path == "/register":
            return self._register()
        if path == "/authorize":
            return self._authorize_post(self._form())
        if path == "/token":
            return self._token(self._form())
        if path == "/mcp" or path == "/":
            return self._mcp()
        self._send(404, b"", None)


if __name__ == "__main__":
    print(f"youtube-transcript MCP on http://{HOST}:{PORT}/mcp")
    print(f"  OAuth issuer + static bearer auth enabled. Owner password in {CONF_DIR}/password")
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
