# YouTube Transcript MCP server (on the phone)

A remote MCP server (Streamable HTTP) exposing a `get_transcript` tool to claude.ai.
It runs **on the phone**, so there is no hosted runtime to pay for or maintain — the
Cloudflare tunnel in front only relays the *inbound* MCP protocol.

## Why yt-dlp (not the referenced npm package)

Verified 2026-07-20 from an ordinary consumer connection:

| Fetcher | Result |
|---|---|
| `youtube-captions-scraper` (what `@kimtaeyoon83/...` uses) | **0 lines** — regex/format outdated |
| `youtubei.js` (InnerTube) | **HTTP 400** — stale `get_transcript` request |
| **`yt-dlp`** | **✅ works** — real captions returned |

The common Node libraries are simply broken against current YouTube. yt-dlp stays
current, so it's the fetcher.
The referenced package was also missing most of its advertised features (no Shorts,
no language fallback, no timestamps, no ad-stripping) — see the main report.

`server.py` was tested end-to-end (URL parsing incl. Shorts, real fetch, caching,
timestamps, cursor pagination reconstructing a transcript exactly).

## What it does

All tools accept full URLs (watch / Shorts / youtu.be / embed / live) or a bare 11-char ID,
and are fetched on-device.

**Text (zero cost, no extra deps):**
- **`get_transcript(url, lang="en", timestamps=False, cursor="")`** — title + transcript.
  Language fallback (requested → auto-captions → English), disk cache (`~/.cache/yt-transcript-mcp`,
  30-day TTL), and cursor pagination (long transcripts return a page + a `cursor="..."` line to
  continue, staying under claude.ai's ~150k-char tool-result limit).
- **`search_youtube(query, limit=10, sort=relevance|date)`** — search results (title, id, url,
  channel, duration, views, date).
- **`get_video_info(url)`** — curated metadata: description, channel, publish date, duration,
  view/like counts, categories, tags, chapters, available caption tracks, availability. (No
  camera/GPS/recording-date — YouTube strips it; `location`, if present, is a self-reported tag.)

**Visual (needs `ffmpeg` on the phone — `pkg install ffmpeg`):**
- **`get_frames(url, start_s, end_s, interval=30, resolution=low|high, max_frames=20)`** — sampled
  frames returned as MCP **image blocks**, each labeled with its timestamp. yt-dlp picks a low
  stream URL and ffmpeg **fast-seeks single frames over HTTP** (no full download); frames run
  concurrently. Ends with a cost footer (frames + tokens, cumulative per video this session).
- **`estimate_frames(url, start_s, end_s, interval, resolution)`** — **dry run, pulls no images**:
  frame count + token/$ estimate at low and high res, so the model can plan before spending.
- **`get_scene_changes(url, start_s, end_s, threshold=0.4)`** — timestamps of scene cuts in a
  range (no images); pixel-free way to find cuts-to-graphics. Decodes the range, so it's capped
  at `YT_MCP_SCENE_RANGE` (default 900s) per call.

**Hard cost caps (enforced in the tools, env-overridable):** min interval `YT_MCP_MIN_INTERVAL`
(5s), default frames `YT_MCP_MAX_FRAMES` (20), per-call ceiling `YT_MCP_FRAME_CAP` (50), rate
`YT_MCP_FRAME_RATE` (200 frames/min). Resolution tiers: low ~360p (~350 tok/frame, screening) /
high ~720p (~1230 tok/frame, reading text/charts).

**Prompts (`prompts/list` + `prompts/get`) — a growing workflow library:**
- **`analyze_video(url, request)`** — general entry point: loads the cost model + universal
  cheap-first strategy (transcript → coarse low-res screen → confirm → high-res only on hits →
  fan out) + example workflows, then applies judgment. Framed as non-exhaustive: add more prompts
  over time; the principles preamble handles novel requests.
- **`extract_charts(url)`** — transcript-guided recipe: find chart references in the transcript,
  confirm with low-res frames, dedup, read each distinct chart at high res.

## Deploy (run at home, on the LAN — needs to reach the phone)

> First: **investigate the phone empirically and report** before changing anything —
> Python/pkg versions, cloudflared state, storage, battery. Additive changes only.

```bash
# from the Mac, over WiFi SSH (already set up):
# NOTE: server runs on system Termux python + system yt-dlp (no venv in practice).
# Visual tools need ffmpeg:  ssh -p 8022 <phone-ip> 'pkg install -y ffmpeg'
ssh -p 8022 <phone-ip> 'pkg install -y python && python -m venv ~/yt-transcript-mcp/venv'
scp -O -P 8022 server.py requirements.txt <phone-ip>:yt-transcript-mcp/
ssh -p 8022 <phone-ip> '~/yt-transcript-mcp/venv/bin/pip install -r ~/yt-transcript-mcp/requirements.txt'

# 1. VERIFY FETCHING ON THE PHONE FIRST:
ssh -p 8022 <phone-ip> '~/yt-transcript-mcp/venv/bin/yt-dlp --skip-download --write-auto-subs \
    --sub-langs en --sub-format json3 -o /tmp/t "https://youtu.be/jNQXAC9IVRw" && ls /tmp/t*.json3'
#    -> if this returns NO json3 file, STOP: fetching doesn't work even on the phone;
#       the whole design is blocked and we reconsider before going further.

# 2. autostart: cp start-mcp.sh ~/.termux/boot/30-yt-mcp.sh (chmod +x)
# 3. persistent tunnel: cloudflared tunnel login; create + route DNS to your domain;
#    write ~/.cloudflared/config.yml -> service http://localhost:8765
# 4. REBOOT the phone; confirm server + tunnel auto-return and a transcript fetches
#    end-to-end through the tunnel.
# 5. claude.ai: Settings > Connectors > add https://<your-host>/mcp  (see report re: auth)
```

## Auth: the server is its own OAuth authority

We tried Cloudflare Access first. It **doesn't work**: a self-hosted Access app
advertises a DCR endpoint in its OAuth metadata but returns **404** on it, so claude.ai
can't register (*"Couldn't register with … sign-in service"*). Cloudflare's supported
"MCP server portal" is the intended path, but **claude.ai *web* is broken against
Cloudflare Managed OAuth** — Anthropic issue
[#410](https://github.com/anthropics/claude-ai-mcp/issues/410), *closed as not-planned*
(Claude Code works; the web/mobile connector fails at Connect). So relying on
Cloudflare's OAuth is a dead end for the web client.

Instead, **`server.py` speaks OAuth itself** — ~150 lines of stdlib implementing the
slice MCP clients need, so it works for both claude.ai web and Claude Code and doesn't
depend on Cloudflare. Cloudflare Access is **removed**; the tunnel just relays and the
server authenticates.

What it implements:

- **RFC 9728** protected-resource metadata + **RFC 8414** authorization-server metadata
  (`/.well-known/oauth-protected-resource`, `/.well-known/oauth-authorization-server`)
- **RFC 7591** dynamic client registration (`/register`) — clients self-register, no
  manual client-ID/secret
- **Authorization code + PKCE (S256)** (`/authorize`, `/token`), codes single-use
- **Owner-password consent gate** on `/authorize` — approving a client requires the
  owner password, so only you can grant access. *This is the whole perimeter: the
  tunnel is public, so this password is what keeps strangers off your phone.*
  Access tokens last 24 h, refresh tokens 90 d.
- Unauthenticated `/mcp` → `401` with
  `WWW-Authenticate: Bearer resource_metadata="…"` so clients start the flow.

Tokens are **stateless HMAC blobs** (key in `~/.config/yt-mcp/oauth_secret`), so they
survive a server restart. A **static bearer** (`~/.config/yt-mcp/bearer_token`, or
`YT_MCP_TOKEN`) is also accepted on `/mcp` — handy for CLI clients that would rather
pass a header than do interactive OAuth.

Config lives in `~/.config/yt-mcp/` on the phone (auto-generated, `0600`):
`password` (owner consent password — override with `YT_MCP_AUTH_PASSWORD`),
`oauth_secret` (token signing key), `bearer_token` (static CLI bearer).

### Connect a client

- **claude.ai (web):** Settings → Connectors → Add custom connector →
  URL `https://yt-mcp.example.com/mcp` → Connect. It self-registers, then shows the
  server's consent page → enter the **owner password** → connected.
- **Claude Code (OAuth):** `claude mcp add --transport http yt-transcript https://yt-mcp.example.com/mcp`
  then `/mcp` → **yt-transcript** → **Authenticate** (browser consent, owner password).
- **Claude Code (static bearer, no browser):**
  `claude mcp add --transport http yt-transcript https://yt-mcp.example.com/mcp --header "Authorization: Bearer <bearer_token>"`
- **Home LAN shortcut:** the direct URL `http://<phone-ip>:8765/mcp` still needs a
  bearer/OAuth too now (the server always authenticates), but is reachable without the tunnel.

## Footprint

Python **standard library only** + yt-dlp (see `requirements.txt`). The server process
idles at tens of MB; yt-dlp runs as a short-lived subprocess only on cache misses.
Fine for the phone. Fronted on-device by `cloudflared` (named tunnel), autostarted by
Termux:Boot alongside the existing nginx / sshd / battery-monitor services.
