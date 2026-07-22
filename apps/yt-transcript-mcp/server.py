#!/usr/bin/env python3
"""
YouTube transcript MCP server (Streamable HTTP transport) for claude.ai.

WHY IT LIVES ON THE PHONE: the outbound YouTube request must originate from the
Oppo's Hungarian residential IP. A Cloudflare tunnel in front only relays the
*inbound* MCP protocol; the yt-dlp fetch below still goes out from this box.

WHY yt-dlp (not youtube-captions-scraper / youtubei.js): both of those were
verified broken against current YouTube on 2026-07-20 from a HU residential IP
(0 lines / HTTP 400). yt-dlp stays current and worked in the same test.

Features: robust URL parsing (Shorts / youtu.be / embed / live / bare ID),
language fallback, optional timestamps, on-disk caching (repeat questions don't
re-hit YouTube — the real rate-limit mitigation), and cursor-based pagination so
long transcripts don't blow past claude.ai's ~150k-char tool-result limit.

Config via env:
  YT_MCP_HOST   (default 127.0.0.1 — cloudflared connects locally)
  YT_MCP_PORT   (default 8765)
  YT_MCP_CACHE  (default ~/.cache/yt-transcript-mcp)
  YT_MCP_TTL    (cache seconds, default 30 days — transcripts don't change)
  YT_MCP_CHUNK  (chars per page, default 90000; keep < ~150000)
  YT_MCP_YTDLP  (yt-dlp binary/command, default "yt-dlp")
"""
import os, re, json, base64, subprocess, tempfile, time, glob
from pathlib import Path
from urllib.parse import urlparse, parse_qs
from mcp.server.fastmcp import FastMCP

HOST      = os.environ.get("YT_MCP_HOST", "127.0.0.1")
PORT      = int(os.environ.get("YT_MCP_PORT", "8765"))
CACHE_DIR = Path(os.environ.get("YT_MCP_CACHE", os.path.expanduser("~/.cache/yt-transcript-mcp")))
CACHE_TTL = int(os.environ.get("YT_MCP_TTL", str(30 * 24 * 3600)))
CHUNK     = int(os.environ.get("YT_MCP_CHUNK", "90000"))
YTDLP     = os.environ.get("YT_MCP_YTDLP", "yt-dlp")
CACHE_DIR.mkdir(parents=True, exist_ok=True)

mcp = FastMCP("youtube-transcript", host=HOST, port=PORT)
VIDEO_ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")


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
    """Fetch caption lines [{start,dur,text}] via yt-dlp. Falls back requested->auto->English->any."""
    with tempfile.TemporaryDirectory() as td:
        out = os.path.join(td, "s")
        langs = f"{lang},{lang}.*,{lang}-orig,en,en.*"
        cmd = [YTDLP, "--skip-download", "--write-subs", "--write-auto-subs",
               "--sub-langs", langs, "--sub-format", "json3", "--no-warnings",
               "-o", out, f"https://www.youtube.com/watch?v={video_id}"]
        proc = subprocess.run(cmd, capture_output=True, timeout=120, check=False)
        files = glob.glob(os.path.join(td, "*.json3"))
        if not files:
            err = (proc.stderr or b"").decode("utf-8", "ignore").strip().splitlines()
            hint = err[-1] if err else "no captions available"
            raise RuntimeError(f"No captions for {video_id} (lang={lang}): {hint}")
        # prefer a file whose name carries the requested language
        files.sort(key=lambda f: 0 if f".{lang}" in os.path.basename(f) else 1)
        data = json.load(open(files[0], encoding="utf-8"))
        lines = []
        for ev in data.get("events", []):
            segs = ev.get("segs") or []
            text = "".join(seg.get("utf8", "") for seg in segs).strip()
            if not text:
                continue
            lines.append({"start": ev.get("tStartMs", 0) / 1000.0,
                          "dur": ev.get("dDurationMs", 0) / 1000.0, "text": text})
        if not lines:
            raise RuntimeError(f"Captions for {video_id} parsed empty.")
        return lines


def _get_lines(video_id: str, lang: str):
    cp = CACHE_DIR / f"{video_id}.{lang}.json"
    if cp.exists() and (time.time() - cp.stat().st_mtime) < CACHE_TTL:
        return json.load(open(cp, encoding="utf-8")), True
    lines = _fetch(video_id, lang)
    json.dump(lines, open(cp, "w", encoding="utf-8"))
    return lines, False


def _format(lines, timestamps: bool) -> str:
    if not timestamps:
        return " ".join(l["text"] for l in lines)
    def mmss(s):
        s = int(s); return f"{s // 60}:{s % 60:02d}"
    return "\n".join(f"[{mmss(l['start'])}] {l['text']}" for l in lines)


def _enc(video_id, lang, ts, offset):
    return base64.urlsafe_b64encode(json.dumps([video_id, lang, ts, offset]).encode()).decode()

def _dec(cur):
    return json.loads(base64.urlsafe_b64decode(cur.encode()).decode())


@mcp.tool()
def get_transcript(url: str = "", lang: str = "en", timestamps: bool = False, cursor: str = "") -> str:
    """Fetch a YouTube video's transcript.

    url: full URL (Shorts, youtu.be, embed, live all supported) or a bare 11-char video ID.
    lang: preferred caption language code (falls back to auto-captions, then English).
    timestamps: if true, prefix each line with mm:ss.
    cursor: leave empty for the first call. If the result ends with a 'cursor="..."' line,
            call again with that cursor to get the next page (long transcripts are paginated).
    """
    if cursor:
        video_id, lang, timestamps, offset = _dec(cursor)
    else:
        video_id, offset = extract_video_id(url), 0
    lines, cached = _get_lines(video_id, lang)
    full = _format(lines, timestamps)
    chunk = full[offset:offset + CHUNK]
    end = offset + len(chunk)
    if end < len(full):                       # break on whitespace so we don't cut mid-word
        sp = chunk.rfind(" ", int(CHUNK * 0.8))
        if sp > 0:
            chunk, end = chunk[:sp], offset + sp
    head = f"# YouTube transcript {video_id} (lang={lang}{', cached' if cached else ''}) — chars {offset}–{end} of {len(full)}\n\n"
    if end < len(full):
        tail = f'\n\n[Truncated — {len(full) - end} chars remain. To continue, call get_transcript with cursor="{_enc(video_id, lang, timestamps, end)}"]'
    else:
        tail = ""
    return head + chunk + tail


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
