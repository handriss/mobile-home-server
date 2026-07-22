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
from urllib.parse import urlparse, parse_qs
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HOST      = os.environ.get("YT_MCP_HOST", "0.0.0.0")
PORT      = int(os.environ.get("YT_MCP_PORT", "8765"))
CACHE_DIR = os.environ.get("YT_MCP_CACHE", os.path.expanduser("~/.cache/yt-transcript-mcp"))
CACHE_TTL = int(os.environ.get("YT_MCP_TTL", str(30 * 24 * 3600)))
CHUNK     = int(os.environ.get("YT_MCP_CHUNK", "90000"))
YTDLP     = os.environ.get("YT_MCP_YTDLP", "yt-dlp")
RATE_MAX  = int(os.environ.get("YT_MCP_RATE", "20"))
TOKEN     = os.environ.get("YT_MCP_TOKEN", "")     # optional; empty = no local auth (LAN/tunnel gates it)
os.makedirs(CACHE_DIR, exist_ok=True)

VIDEO_ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")
_fetch_lock = threading.Lock()
_recent = collections.deque()

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


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):  # keep it quiet
        pass

    def _authed(self):
        if not TOKEN:
            return True
        return self.headers.get("Authorization", "") == f"Bearer {TOKEN}"

    def _send_json(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

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

    def do_POST(self):
        if not self._authed():
            return self._send_json(401, {"jsonrpc": "2.0", "id": None,
                                         "error": {"code": -32001, "message": "unauthorized"}})
        try:
            body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            msg = json.loads(body)
        except Exception:
            return self._send_json(400, {"jsonrpc": "2.0", "id": None,
                                         "error": {"code": -32700, "message": "parse error"}})
        if isinstance(msg, list):
            out = [r for r in (self._one(m) for m in msg) if r is not None]
            if out:
                self._send_json(200, out)
            else:
                self.send_response(202); self.end_headers()
        else:
            r = self._one(msg)
            if r is None:
                self.send_response(202); self.end_headers()
            else:
                self._send_json(200, r)

    def do_GET(self):
        self.send_response(405); self.send_header("Content-Length", "0"); self.end_headers()


if __name__ == "__main__":
    print(f"youtube-transcript MCP on http://{HOST}:{PORT}/mcp  (auth: {'bearer token' if TOKEN else 'none'})")
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
