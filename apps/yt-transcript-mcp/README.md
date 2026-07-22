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

## Auth: Cloudflare Access (deployed)

The public endpoint `https://yt-mcp.example.com/mcp` is gated by **Cloudflare
Access** (Zero Trust, free tier) — a self-hosted application with an "Only me" email
policy. Leaving it open would let anyone use the phone's residential IP to scrape
YouTube (abuse + rate-limit risk), so it is **not** open to the internet.

Crucially, Cloudflare Access speaks the **MCP OAuth flow** natively. An unauthenticated
request gets `401/302` plus:

```
www-authenticate: Cloudflare-Access resource_metadata="…/.well-known/cloudflare-access-protected-resource/mcp"
```

which points MCP clients (claude.ai connectors, Claude Code) at the team domain's
OAuth authorization server (`…cloudflareaccess.com/.well-known/oauth-authorization-server`).
That server exposes `authorization`/`token`/`registration` endpoints with **PKCE (S256)
and Dynamic Client Registration** — exactly what those clients need. So no manual
client-ID/secret setup: the client self-registers, redirects the user to the Access
login (One-Time PIN to the allow-listed email), and gets a token. Verified end-to-end.

The server's own optional `YT_MCP_TOKEN` bearer is therefore left empty — Access is the
gate. (Keep it empty; a second bearer would break the OAuth clients.)

### Connect a client

- **claude.ai (web):** Settings → Connectors → Add custom connector →
  URL `https://yt-mcp.example.com/mcp` → complete the Cloudflare Access login.
- **Claude Code:** `claude mcp add --transport http yt-transcript https://yt-mcp.example.com/mcp`
  then run `/mcp` → **yt-transcript** → **Authenticate** to complete OAuth in the browser.
  (On the home LAN you can skip auth entirely with the direct URL
  `http://<phone-ip>:8765/mcp`, which bypasses Cloudflare.)

## Footprint

Python **standard library only** + yt-dlp (see `requirements.txt`). The server process
idles at tens of MB; yt-dlp runs as a short-lived subprocess only on cache misses.
Fine for the phone. Fronted on-device by `cloudflared` (named tunnel), autostarted by
Termux:Boot alongside the existing nginx / sshd / battery-monitor services.
