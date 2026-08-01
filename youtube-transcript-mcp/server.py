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
from concurrent.futures import ThreadPoolExecutor

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

# ------------------------------- visual-analysis config -------------------------------
# Frame extraction (yt-dlp picks a stream URL; ffmpeg fast-seeks single frames over HTTP —
# no full download). Hard caps live here, in the tool, so cost can't blow up regardless of
# what the model asks for; the MCP prompts teach the model to stay well under them.
FFMPEG        = os.environ.get("YT_MCP_FFMPEG", "ffmpeg")
FFPROBE       = os.environ.get("YT_MCP_FFPROBE", "ffprobe")
MIN_INTERVAL  = int(os.environ.get("YT_MCP_MIN_INTERVAL", "5"))    # smallest seconds between frames
FRAME_DEFAULT = int(os.environ.get("YT_MCP_MAX_FRAMES", "20"))     # default frames per get_frames call
FRAME_HARD_CAP= int(os.environ.get("YT_MCP_FRAME_CAP", "50"))      # absolute per-call ceiling
FRAME_RATE_MAX= int(os.environ.get("YT_MCP_FRAME_RATE", "200"))    # frames/min across all calls
SCENE_RANGE_MAX = int(os.environ.get("YT_MCP_SCENE_RANGE", "900")) # max seconds a scene scan may decode
SEARCH_MAX    = int(os.environ.get("YT_MCP_SEARCH_MAX", "25"))     # max search results per call
META_TTL      = int(os.environ.get("YT_MCP_META_TTL", str(24 * 3600)))
FRAME_WORKERS = int(os.environ.get("YT_MCP_FRAME_WORKERS", "6"))   # concurrent ffmpeg seeks
IN_PRICE_PER_M = 5.0  # rough $/1M input tokens (Opus tier) for cost estimates

# Resolution tiers: ffmpeg output height, approx Claude image tokens/frame ((w*h)/750 @ 16:9),
# and the yt-dlp format selector for the source stream (no "+" merges — single URL to seek).
RES_TIERS = {
    "low":  {"h": 360, "tok": 350,  "fmt": "18/worst[vcodec!=none][acodec!=none]/worst[vcodec!=none]"},
    "high": {"h": 720, "tok": 1230, "fmt": "136/22/247/298/bestvideo[height<=720]/18"},
}

_frame_recent = collections.deque()          # timestamps of recently-served frames (rate limit)
_frame_lock   = threading.Lock()
_cost         = {}                            # video_id -> {"frames": int, "tokens": int} (session totals)
_cost_lock    = threading.Lock()

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


# ------------------------------- visual-analysis core -------------------------------

def _mmss(s):
    s = int(s)
    return f"{s // 60}:{s % 60:02d}"


def _run(cmd, timeout):
    """Run a subprocess, return (returncode, stdout, stderr)."""
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, check=False)
    return p.returncode, p.stdout or "", p.stderr or ""


def _watch_url(video_id):
    return f"https://www.youtube.com/watch?v={video_id}"


def _curate_meta(d):
    """Pull the useful, small fields out of yt-dlp's full JSON dump."""
    chapters = [{"start": c.get("start_time"), "end": c.get("end_time"), "title": c.get("title")}
                for c in (d.get("chapters") or [])]
    return {
        "id": d.get("id"), "title": d.get("title"), "description": d.get("description"),
        "channel": d.get("channel") or d.get("uploader"),
        "channel_id": d.get("channel_id"), "uploader_id": d.get("uploader_id"),
        "channel_follower_count": d.get("channel_follower_count"),
        "duration": d.get("duration"), "duration_string": d.get("duration_string"),
        "upload_date": d.get("upload_date"), "timestamp": d.get("timestamp"),
        "release_date": d.get("release_date"),
        "view_count": d.get("view_count"), "like_count": d.get("like_count"),
        "comment_count": d.get("comment_count"),
        "categories": d.get("categories"), "tags": d.get("tags"),
        "chapters": chapters,
        "width": d.get("width"), "height": d.get("height"),
        "aspect_ratio": d.get("aspect_ratio"),
        "availability": d.get("availability"), "age_limit": d.get("age_limit"),
        "live_status": d.get("live_status"), "was_live": d.get("was_live"),
        "language": d.get("language"), "location": d.get("location"),
        "thumbnail": d.get("thumbnail"),
        "subtitle_langs": sorted((d.get("subtitles") or {}).keys()),
        "auto_caption_count": len(d.get("automatic_captions") or {}),
        "webpage_url": d.get("webpage_url"),
    }


def _get_meta(video_id):
    """Curated metadata dict, cached to disk (serves get_video_info, estimate_frames, get_frames)."""
    cp = os.path.join(CACHE_DIR, f"{video_id}.meta.json")
    if os.path.exists(cp) and (time.time() - os.path.getmtime(cp)) < META_TTL:
        return json.load(open(cp, encoding="utf-8"))
    with _fetch_lock:
        _rate_gate()
    cmd = [YTDLP, "--dump-single-json", "--skip-download", "--no-warnings", _watch_url(video_id)]
    rc, out, err = _run(cmd, timeout=120)
    if rc != 0 or not out.strip():
        tail = (err or "").strip().splitlines()
        raise RuntimeError(f"metadata fetch failed for {video_id}: {tail[-1] if tail else 'no output'}")
    meta = _curate_meta(json.loads(out))
    json.dump(meta, open(cp, "w", encoding="utf-8"))
    return meta


def _media_url(video_id, resolution):
    """Fresh direct stream URL for a resolution tier (URLs expire, so never cached)."""
    fmt = RES_TIERS.get(resolution, RES_TIERS["low"])["fmt"]
    with _fetch_lock:
        _rate_gate()
    cmd = [YTDLP, "-f", fmt, "--get-url", "--no-warnings", _watch_url(video_id)]
    rc, out, err = _run(cmd, timeout=90)
    url = next((l.strip() for l in out.splitlines() if l.strip().startswith("http")), "")
    if not url:
        tail = (err or "").strip().splitlines()
        raise RuntimeError(f"no stream URL for {video_id} ({resolution}): {tail[-1] if tail else 'none'}")
    return url


def _frame_gate(n):
    now = time.time()
    with _frame_lock:
        while _frame_recent and now - _frame_recent[0] > 60:
            _frame_recent.popleft()
        if len(_frame_recent) + n > FRAME_RATE_MAX:
            raise RuntimeError(f"Frame rate limit: >{FRAME_RATE_MAX} frames/min. Wait a moment.")
        for _ in range(n):
            _frame_recent.append(now)


def _add_cost(video_id, frames, tokens):
    with _cost_lock:
        c = _cost.setdefault(video_id, {"frames": 0, "tokens": 0})
        c["frames"] += frames
        c["tokens"] += tokens
        return dict(c)


def _timestamps(start, end, interval, max_frames):
    ts, t = [], float(start)
    while t < end and len(ts) < max_frames:
        ts.append(round(t, 2))
        t += interval
    return ts


def _extract_frame(media_url, t, scale_h, q, outpath):
    """Fast input-seek extraction of a single frame (decodes ~1 keyframe, not the whole stream)."""
    cmd = [FFMPEG, "-nostdin", "-loglevel", "error", "-ss", f"{t}", "-i", media_url,
           "-frames:v", "1", "-vf", f"scale=-2:{scale_h}", "-q:v", str(q), outpath, "-y"]
    try:
        rc, _, _ = _run(cmd, timeout=60)
    except subprocess.TimeoutExpired:
        return False
    return rc == 0 and os.path.exists(outpath) and os.path.getsize(outpath) > 0


def search_youtube(query="", limit=10, sort="relevance"):
    query = (query or "").strip()
    if not query:
        raise ValueError("query is required")
    limit = max(1, min(int(limit), SEARCH_MAX))
    prefix = "ytsearchdate" if sort == "date" else "ytsearch"
    with _fetch_lock:
        _rate_gate()
    cmd = [YTDLP, f"{prefix}{limit}:{query}", "--dump-json", "--flat-playlist", "--no-warnings"]
    rc, out, err = _run(cmd, timeout=90)
    rows = []
    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except Exception:
            continue
        vid = d.get("id", "")
        rows.append({
            "title": d.get("title", ""), "id": vid, "url": f"https://youtu.be/{vid}",
            "channel": d.get("channel") or d.get("uploader") or "",
            "duration": d.get("duration"), "view_count": d.get("view_count"),
            "upload_date": d.get("upload_date"),
        })
    if not rows:
        tail = (err or "").strip().splitlines()
        raise RuntimeError(f"no results for {query!r}: {tail[-1] if tail else 'none'}")
    lines = [f"# YouTube search: {query}  ({len(rows)} results, sort={sort})\n"]
    for i, r in enumerate(rows, 1):
        dur = _mmss(r["duration"]) if r["duration"] else "?"
        vc = f"{r['view_count']:,} views" if r["view_count"] else ""
        meta = " · ".join(x for x in (r["channel"], dur, vc, r["upload_date"] or "") if x)
        lines.append(f"{i}. {r['title']}\n   {r['url']}  ·  {meta}")
    return "\n".join(lines)


def get_video_info(url=""):
    vid = extract_video_id(url)
    m = _get_meta(vid)
    L = [f"# {m.get('title') or vid}", f"video: https://youtu.be/{vid}", ""]
    def add(label, val):
        if val not in (None, "", [], {}):
            L.append(f"- **{label}:** {val}")
    add("channel", m.get("channel"))
    add("uploader_id", m.get("uploader_id"))
    add("subscribers", m.get("channel_follower_count"))
    add("duration", f"{m.get('duration_string') or m.get('duration')} ({m.get('duration')}s)")
    add("upload_date", m.get("upload_date"))
    add("release_date", m.get("release_date"))
    add("views", f"{m['view_count']:,}" if m.get("view_count") else None)
    add("likes", f"{m['like_count']:,}" if m.get("like_count") else None)
    add("comments", f"{m['comment_count']:,}" if m.get("comment_count") else None)
    add("categories", ", ".join(m.get("categories") or []) or None)
    add("availability", m.get("availability"))
    add("live_status", m.get("live_status"))
    add("age_limit", m.get("age_limit"))
    add("resolution", f"{m.get('width')}x{m.get('height')}" if m.get("width") else None)
    add("language", m.get("language"))
    add("location (self-reported tag, NOT GPS)", m.get("location"))
    subs = m.get("subtitle_langs") or []
    add("uploaded caption tracks", ", ".join(subs) if subs else "none")
    add("auto-caption languages", m.get("auto_caption_count"))
    tags = m.get("tags") or []
    if tags:
        add("tags", ", ".join(tags[:20]) + (" …" if len(tags) > 20 else ""))
    chapters = m.get("chapters") or []
    if chapters:
        L.append(f"\n## Chapters ({len(chapters)})")
        for c in chapters:
            st = _mmss(c["start"]) if c.get("start") is not None else "?"
            L.append(f"- [{st}] {c.get('title') or ''}")
    desc = (m.get("description") or "").strip()
    if desc:
        L.append("\n## Description\n" + (desc[:1500] + (" …[truncated]" if len(desc) > 1500 else "")))
    return "\n".join(L)


def estimate_frames(url="", start_s=0, end_s=None, interval=30, resolution="low"):
    """Dry run: how many frames + token/cost estimate for a get_frames call. Pulls NO images."""
    vid = extract_video_id(url)
    m = _get_meta(vid)
    dur = float(m.get("duration") or 0)
    interval_eff = max(int(interval), MIN_INTERVAL)
    start = max(0.0, float(start_s))
    end = float(end_s) if end_s is not None else dur
    if dur:
        end = min(end, dur)
    span = max(0.0, end - start)
    n_raw = len(_timestamps(start, end if end > start else start + interval_eff, interval_eff, 10 ** 9))
    n_capped = min(n_raw, FRAME_HARD_CAP)
    tier = RES_TIERS.get(resolution, RES_TIERS["low"])
    tok = n_capped * tier["tok"]
    dollars = tok / 1e6 * IN_PRICE_PER_M
    lo = n_capped * RES_TIERS["low"]["tok"]
    hi = n_capped * RES_TIERS["high"]["tok"]
    out = [
        f"# Frame estimate — {m.get('title') or vid}",
        f"video length: {_mmss(dur)} ({dur:.0f}s)" if dur else "video length: unknown",
        f"range: {_mmss(start)}–{_mmss(end)}  ·  interval: {interval_eff}s"
        + (f" (raised from {interval}s; min is {MIN_INTERVAL}s)" if interval_eff != int(interval) else ""),
        "",
        f"frames at this interval: **{n_raw}**"
        + (f"  →  capped to **{n_capped}** per call (max {FRAME_HARD_CAP}); "
           f"you'd need {-(-n_raw // FRAME_HARD_CAP)} calls to cover the whole range"
           if n_raw > n_capped else ""),
        "",
        f"cost for {n_capped} frames:",
        f"- low res  (~{RES_TIERS['low']['tok']} tok/frame): ~{lo:,} tokens  ≈ ${lo/1e6*IN_PRICE_PER_M:.2f}",
        f"- high res (~{RES_TIERS['high']['tok']} tok/frame): ~{hi:,} tokens  ≈ ${hi/1e6*IN_PRICE_PER_M:.2f}",
        "",
        f"(dry run — no frames pulled. Selected tier `{resolution}` ≈ {tok:,} tokens ≈ ${dollars:.2f}.)",
    ]
    return "\n".join(out)


def get_frames(url="", start_s=0, end_s=None, interval=30, resolution="low", max_frames=FRAME_DEFAULT):
    """Return sampled frames as image blocks. Caps: interval>=MIN_INTERVAL, <=FRAME_HARD_CAP frames/call."""
    vid = extract_video_id(url)
    resolution = resolution if resolution in RES_TIERS else "low"
    tier = RES_TIERS[resolution]
    interval = max(int(interval), MIN_INTERVAL)                 # hard cap: min interval
    max_frames = max(1, min(int(max_frames), FRAME_HARD_CAP))   # hard cap: frames/call
    m = _get_meta(vid)
    dur = float(m.get("duration") or 0)
    start = max(0.0, float(start_s))
    end = float(end_s) if end_s is not None else (dur or start + interval * max_frames)
    if dur:
        end = min(end, dur)
    if end <= start:
        end = start + interval
    ts = _timestamps(start, end, interval, max_frames)
    if not ts:
        raise ValueError("empty time range")
    _frame_gate(len(ts))
    media = _media_url(vid, resolution)
    q = 5 if resolution == "low" else 3
    blocks = [{"type": "text", "text":
               f"# Frames — {m.get('title') or vid}\n"
               f"video: https://youtu.be/{vid} · {resolution} res · {len(ts)} frames "
               f"@ {interval}s over {_mmss(start)}–{_mmss(ts[-1])}\n"}]
    with tempfile.TemporaryDirectory() as td:
        def job(it):
            i, t = it
            p = os.path.join(td, f"f{i:04d}.jpg")
            return (t, p if _extract_frame(media, t, tier["h"], q, p) else None)
        with ThreadPoolExecutor(max_workers=FRAME_WORKERS) as ex:
            results = list(ex.map(job, enumerate(ts)))
        got = 0
        for t, p in results:
            if not p:
                continue
            with open(p, "rb") as f:
                b64 = base64.b64encode(f.read()).decode()
            blocks.append({"type": "text", "text": f"[frame @ {_mmss(t)}  ({t:.0f}s)]"})
            blocks.append({"type": "image", "data": b64, "mimeType": "image/jpeg"})
            got += 1
    tokens = got * tier["tok"]
    cum = _add_cost(vid, got, tokens)
    blocks.append({"type": "text", "text":
                   f"\nReturned {got}/{len(ts)} frames (~{tokens // 1000}k tokens, {resolution} res). "
                   f"Cumulative this video this session: {cum['frames']} frames "
                   f"(~{cum['tokens'] // 1000}k tokens ≈ ${cum['tokens']/1e6*IN_PRICE_PER_M:.2f}). "
                   f"[caps: interval ≥ {MIN_INTERVAL}s, ≤ {FRAME_HARD_CAP} frames/call]"})
    return blocks


def get_scene_changes(url="", start_s=0, end_s=None, threshold=0.4):
    """List timestamps of scene cuts in a range (no images). Decodes the range, so keep it bounded."""
    vid = extract_video_id(url)
    m = _get_meta(vid)
    dur = float(m.get("duration") or 0)
    start = max(0.0, float(start_s))
    end = float(end_s) if end_s is not None else (min(dur, start + SCENE_RANGE_MAX) if dur else start + SCENE_RANGE_MAX)
    if end <= start:
        raise ValueError("end_s must be greater than start_s")
    if end - start > SCENE_RANGE_MAX:
        raise ValueError(f"scene scan range is capped at {SCENE_RANGE_MAX}s "
                         f"(you asked for {end - start:.0f}s); narrow start_s/end_s.")
    media = _media_url(vid, "low")
    # -ss before -i => input seek; -t bounds decode; showinfo prints pts_time per selected frame.
    cmd = [FFMPEG, "-nostdin", "-loglevel", "info", "-ss", f"{start}", "-t", f"{end - start}",
           "-i", media, "-vf", f"select='gt(scene,{float(threshold)})',showinfo", "-f", "null", "-"]
    rc, out, err = _run(cmd, timeout=180)
    cuts = []
    for mt in re.finditer(r"pts_time:([0-9.]+)", err):
        cuts.append(round(start + float(mt.group(1)), 1))  # input-seek pts is relative to start
    cuts = sorted(set(cuts))
    head = (f"# Scene cuts — {m.get('title') or vid}\n"
            f"range {_mmss(start)}–{_mmss(end)} · threshold {threshold} · {len(cuts)} cuts\n")
    if not cuts:
        return head + "\n(no cuts detected — try a lower threshold, or the range is a single continuous shot)"
    return head + "\n" + "\n".join(f"- {_mmss(c)}  ({c:.0f}s)" for c in cuts)


# ------------------------------- MCP protocol -------------------------------

TOOLS = [
    {
        "name": "get_transcript",
        "description": "Fetch a YouTube video's title and transcript. Accepts a full URL "
                       "(watch/Shorts/youtu.be/embed/live) or a bare 11-char video ID. Long "
                       "transcripts paginate: if the result ends with a cursor=\"...\" line, call "
                       "again passing that cursor to get the next page. Cheap (text) — do this first.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "url": {"type": "string", "description": "YouTube URL or 11-char video ID"},
                "lang": {"type": "string", "description": "Preferred caption language code (falls back to auto-captions, then English)", "default": "en"},
                "timestamps": {"type": "boolean", "description": "Prefix each line with mm:ss", "default": False},
                "cursor": {"type": "string", "description": "Pagination cursor from a previous truncated result"},
            },
        },
    },
    {
        "name": "search_youtube",
        "description": "Search YouTube and return a list of matching videos (title, id, url, channel, "
                       "duration, views, upload date). No auth needed.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string", "description": "Search query"},
                "limit": {"type": "integer", "description": f"Max results (1-{SEARCH_MAX})", "default": 10},
                "sort": {"type": "string", "enum": ["relevance", "date"], "description": "Ranking", "default": "relevance"},
            },
            "required": ["query"],
        },
    },
    {
        "name": "get_video_info",
        "description": "Rich metadata for a video: title, description, channel, publish date, duration, "
                       "view/like counts, categories, tags, chapters, available caption tracks, availability. "
                       "Note: no camera/GPS/recording-date data — YouTube strips it; 'location' if present is a "
                       "self-reported tag, not GPS.",
        "inputSchema": {
            "type": "object",
            "properties": {"url": {"type": "string", "description": "YouTube URL or 11-char video ID"}},
            "required": ["url"],
        },
    },
    {
        "name": "estimate_frames",
        "description": "DRY RUN — pulls NO images. Returns how many frames a get_frames call would produce "
                       "for a range/interval, plus token and dollar cost estimates at low and high res. Call "
                       "this to plan before spending on frames.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "url": {"type": "string", "description": "YouTube URL or 11-char video ID"},
                "start_s": {"type": "number", "description": "Range start (seconds)", "default": 0},
                "end_s": {"type": "number", "description": "Range end (seconds); default = end of video"},
                "interval": {"type": "number", "description": f"Seconds between frames (min {MIN_INTERVAL})", "default": 30},
                "resolution": {"type": "string", "enum": ["low", "high"], "default": "low"},
            },
            "required": ["url"],
        },
    },
    {
        "name": "get_frames",
        "description": "Extract sampled video frames as images for visual analysis. Returns image blocks "
                       "labeled with timestamps. Frames cost tokens — prefer low res + coarse intervals for "
                       f"screening, high res only on confirmed hits. Hard caps: interval >= {MIN_INTERVAL}s, "
                       f"<= {FRAME_HARD_CAP} frames/call (default {FRAME_DEFAULT}). Call estimate_frames first "
                       "if unsure of the cost.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "url": {"type": "string", "description": "YouTube URL or 11-char video ID"},
                "start_s": {"type": "number", "description": "Range start (seconds)", "default": 0},
                "end_s": {"type": "number", "description": "Range end (seconds); default = end of video"},
                "interval": {"type": "number", "description": f"Seconds between frames (clamped to >= {MIN_INTERVAL})", "default": 30},
                "resolution": {"type": "string", "enum": ["low", "high"], "description": "low ~360p (cheap screening) / high ~720p (read text/charts)", "default": "low"},
                "max_frames": {"type": "integer", "description": f"Cap on frames returned (<= {FRAME_HARD_CAP})", "default": FRAME_DEFAULT},
            },
            "required": ["url"],
        },
    },
    {
        "name": "get_scene_changes",
        "description": "List timestamps of scene cuts within a range (no images pulled). Useful to find where "
                       "the video cuts to a graphic/slide before extracting frames. Decodes the range, so keep "
                       f"it bounded (<= {SCENE_RANGE_MAX}s per call).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "url": {"type": "string", "description": "YouTube URL or 11-char video ID"},
                "start_s": {"type": "number", "description": "Range start (seconds)", "default": 0},
                "end_s": {"type": "number", "description": f"Range end (seconds); default start+{SCENE_RANGE_MAX}"},
                "threshold": {"type": "number", "description": "Scene sensitivity 0-1 (lower = more cuts)", "default": 0.4},
            },
            "required": ["url"],
        },
    },
]

HANDLERS = {
    "get_transcript":    (get_transcript,    ("url", "lang", "timestamps", "cursor")),
    "search_youtube":    (search_youtube,    ("query", "limit", "sort")),
    "get_video_info":    (get_video_info,    ("url",)),
    "estimate_frames":   (estimate_frames,   ("url", "start_s", "end_s", "interval", "resolution")),
    "get_frames":        (get_frames,        ("url", "start_s", "end_s", "interval", "resolution", "max_frames")),
    "get_scene_changes": (get_scene_changes, ("url", "start_s", "end_s", "threshold")),
}

# ------------------------------- workflow prompts -------------------------------
# Constitution (principles that always apply) + precedent (example workflows) + an explicit
# freedom clause. This is a GROWING library — add more named prompts over time; the principles
# preamble means novel requests are handled sensibly even before a specific recipe exists.
PRINCIPLES = f"""You have YouTube tools on this MCP server: get_transcript, search_youtube,
get_video_info, estimate_frames, get_frames, get_scene_changes.

COST MODEL (internalize this — it drives every decision):
- Text is nearly free. The transcript and get_scene_changes are pixel-free reconnaissance — use
  them to decide WHERE to look before spending on pixels.
- Frames are the expensive part. Each frame costs image tokens (low res ~350, high res ~1230).
  Cost = frames x tokens/frame, and it is strictly linear — 10x the frames is 10x the cost.
- Hard caps are enforced by the tools: interval >= {MIN_INTERVAL}s, <= {FRAME_HARD_CAP} frames per
  call. Stay well under them; they are a backstop, not a target.

UNIVERSAL STRATEGY (apply to any visual request):
1. Transcript first. It is cheap and usually tells you where the interesting moments are.
2. Coarse before fine. Screen with wide intervals + LOW resolution; never scan at high res.
3. Confirm, then escalate. Only pull ONE high-res frame once you've confirmed (from a low-res
   frame) that the thing you want is actually on screen at that timestamp.
4. Plan before spending. If a range might be large, call estimate_frames first.
5. Watch the cost footer. get_frames reports cumulative frames/tokens for the video — keep an eye on it.
6. Fan out when you can. Each frame is independent — if you have sub-agents, have each analyze its
   own small batch and return only a short text verdict, so images never pile up in one context.

FREEDOM: The workflows below are a NON-EXHAUSTIVE, growing library of example strategies, not a
mandate. If the request matches one, adapt it. If it doesn't, or a better approach is obvious, work
from the principles above — the tools are general-purpose. You may blend workflows for hybrid requests.
"""

EXAMPLE_WORKFLOWS = """
EXAMPLE WORKFLOWS
- Extract charts/graphs from a talky video (e.g. a podcast): see the `extract_charts` prompt.
- Find a person/object ("the guy in the pink shirt") and timestamp it: screen the whole video at a
  coarse interval (e.g. 20-30s) in LOW res; for any frame that might match, sample +/- a few frames
  densely around it to pin the moment; confirm with one high-res frame. Report the timestamp.
- Summarize what's shown on screen: transcript for what's SAID; coarse low-res frame sweep for what's
  SHOWN; combine. Only go high res on frames that carry unreadable detail.
"""

CHARTS_WORKFLOW = """Goal: find every DISTINCT chart/graph/diagram in the video and explain each,
cheaply.

Strategy (cheap -> expensive, coarse -> fine):
1. get_transcript (with timestamps). Scan it for chart references: "as this chart shows", "the graph",
   "these numbers", "look at this", "on the y-axis", etc. Collect candidate timestamps.
2. PRIMARY PATH: for each candidate, get_frames at LOW res, a few frames around that timestamp
   (interval ~5-10s, small max_frames), to confirm a chart is actually on screen — the words and the
   visual don't always line up.
3. FALLBACK PATH: if the transcript is unhelpful (few/no references, or it's a screen-share with
   little narration), use get_scene_changes over bounded ranges to find cuts-to-graphics, or a coarse
   low-res sweep of the whole video. Don't rely on the words alone.
4. DEDUP: the same chart is often referenced more than once. Collapse to DISTINCT charts before
   spending on high res.
5. For each confirmed, distinct chart, get_frames ONE high-res frame at the cleanest timestamp and
   read it carefully.
6. Return each chart with its timestamp and an explanation of what it shows.

Be conservative with frames — a handful of charts should cost a few dozen low-res screening frames
plus a handful of high-res reads, not hundreds. Use estimate_frames if a range looks large.
"""

PROMPTS = [
    {
        "name": "analyze_video",
        "description": "General entry point for analyzing a YouTube video (visual or otherwise). "
                       "Loads the cost model, the universal cheap-first strategy, and the example "
                       "workflow library, then applies judgment to your request.",
        "arguments": [
            {"name": "url", "description": "YouTube URL or video ID", "required": True},
            {"name": "request", "description": "What you want (e.g. 'extract the charts', 'find the pink shirt')", "required": False},
        ],
    },
    {
        "name": "extract_charts",
        "description": "Transcript-guided workflow to find and explain every distinct chart/graph in a "
                       "video, cheaply (coarse low-res screening, high-res only on confirmed hits).",
        "arguments": [
            {"name": "url", "description": "YouTube URL or video ID", "required": True},
        ],
    },
]


def _prompt_text(name, args):
    url = args.get("url", "").strip()
    target = f"\n\nTarget video: {url}" if url else ""
    if name == "analyze_video":
        req = args.get("request", "").strip()
        req_line = f"\n\nRequest: {req}" if req else "\n\nRequest: (ask the user what they want if unclear)"
        return PRINCIPLES + "\n" + EXAMPLE_WORKFLOWS + req_line + target
    if name == "extract_charts":
        return PRINCIPLES + "\n" + CHARTS_WORKFLOW + target
    raise KeyError(name)


PROTOCOL_VERSIONS = {"2025-11-25", "2025-06-18", "2025-03-26"}


def dispatch(method, params):
    if method == "initialize":
        pv = params.get("protocolVersion")
        return {
            "protocolVersion": pv if pv in PROTOCOL_VERSIONS else "2025-06-18",
            "capabilities": {"tools": {"listChanged": False}, "prompts": {"listChanged": False}},
            "serverInfo": {"name": "youtube-transcript", "version": "2.0.1"},
        }
    if method == "tools/list":
        return {"tools": TOOLS}
    if method == "prompts/list":
        return {"prompts": PROMPTS}
    if method == "prompts/get":
        name = params.get("name")
        args = params.get("arguments") or {}
        try:
            text = _prompt_text(name, args)
        except KeyError:
            raise KeyError(f"prompts/get: unknown prompt {name}")
        pd = next((p for p in PROMPTS if p["name"] == name), None)
        return {
            "description": pd["description"] if pd else "",
            "messages": [{"role": "user", "content": {"type": "text", "text": text}}],
        }
    if method == "ping":
        return {}
    if method == "tools/call":
        name = params.get("name")
        args = params.get("arguments") or {}
        entry = HANDLERS.get(name)
        if not entry:
            return {"content": [{"type": "text", "text": f"Unknown tool: {name}"}], "isError": True}
        fn, keys = entry
        try:
            kw = {k: args[k] for k in keys if k in args}
            result = fn(**kw)
            content = result if isinstance(result, list) else [{"type": "text", "text": result}]
            return {"content": content, "isError": False}
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
    print(f"  tools: {', '.join(t['name'] for t in TOOLS)}")
    print(f"  prompts: {', '.join(p['name'] for p in PROMPTS)}")
    print(f"  OAuth issuer + static bearer auth enabled. Owner password in {CONF_DIR}/password")
    ThreadingHTTPServer((HOST, PORT), Handler).serve_forever()
