# YouTube Transcript MCP server (on the phone)

A remote MCP server (Streamable HTTP) exposing a `get_transcript` tool to claude.ai.
It **runs on the Oppo phone on purpose** so the YouTube request goes out from the
phone's Hungarian residential IP. A Cloudflare tunnel in front only relays the
*inbound* MCP protocol; the outbound fetch still originates on the phone.

## Why yt-dlp (not the referenced npm package)

Verified 2026-07-20 from a **Hungarian residential IP** (Yettel mobile, same class
as the phone):

| Fetcher | Result |
|---|---|
| `youtube-captions-scraper` (what `@kimtaeyoon83/...` uses) | **0 lines** — regex/format outdated |
| `youtubei.js` (InnerTube) | **HTTP 400** — stale `get_transcript` request |
| **`yt-dlp`** | **✅ works** — real captions returned |

So the blocker isn't only datacenter IPs — the common Node libraries are broken
against current YouTube regardless of IP. yt-dlp stays current, so it's the fetcher.
The referenced package was also missing most of its advertised features (no Shorts,
no language fallback, no timestamps, no ad-stripping) — see the main report.

`server.py` was tested end-to-end (URL parsing incl. Shorts, real fetch, caching,
timestamps, cursor pagination reconstructing a transcript exactly).

## What it does

- **Tool `get_transcript(url, lang="en", timestamps=False, cursor="")`**
- Accepts full URLs (watch / Shorts / youtu.be / embed / live) or a bare 11-char ID
- Language fallback: requested → auto-captions → English
- **Caching** on disk (`~/.cache/yt-transcript-mcp`, 30-day TTL) — repeat questions
  don't re-hit YouTube (the real rate-limit mitigation)
- **Cursor pagination** — long transcripts return a page + a `cursor="..."` line to
  continue, staying under claude.ai's ~150k-char tool-result limit

## Deploy (run at home, on the LAN — needs to reach the phone)

> First: **investigate the phone empirically and report** before changing anything —
> Python/pkg versions, cloudflared state, storage, battery. Additive changes only.

```bash
# from the Mac, over WiFi SSH (already set up):
ssh -p 8022 <phone-ip> 'pkg install -y python && python -m venv ~/yt-transcript-mcp/venv'
scp -O -P 8022 server.py requirements.txt <phone-ip>:yt-transcript-mcp/
ssh -p 8022 <phone-ip> '~/yt-transcript-mcp/venv/bin/pip install -r ~/yt-transcript-mcp/requirements.txt'

# 1. VERIFY FETCHING ON THE PHONE FIRST (the real residential-IP test):
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

## Open question to resolve at deploy: claude.ai auth

claude.ai custom connectors use **Streamable HTTP** (this server) and OAuth is
*documented as optional*, but the connector UI historically has friction with
no-auth servers and doesn't accept a plain bearer token. Plan: try adding it with
no auth; if rejected, front it with Cloudflare Access or add minimal OAuth. **Do not
leave it fully open to the internet** — an open server lets anyone use your
residential IP to scrape YouTube (abuse + rate-limit risk).

## Footprint

Python + `mcp` (starlette/uvicorn) + yt-dlp. Server process idles at tens of MB;
yt-dlp runs as a short-lived subprocess only on cache misses. Fine for the phone.
