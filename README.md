# Mobile Home Server

A spare **OPPO Reno5 Z (CPH2211), Android 13 / ColorOS** turned into an always-on home
server, running in Termux. Everything is driven from a Mac (ADB over USB, then SSH over
WiFi) — no root, no cloud host. This repo holds two projects that run on it:

## [`home-server/`](home-server/) — the phone server + status dashboard

Provisions the phone into a **Termux + nginx** web server (auto-start on boot, wake-lock,
battery-optimization exemption), deploys sites over WiFi, and runs a **battery-safety
monitor** (ntfy alerts + healthchecks.io heartbeat) feeding a **diagnostics dashboard**
(`www/diag.html`) that shows the phone's temperature, battery level, and health. Optional
public access via Cloudflare Tunnel (works behind CGNAT / DS-Lite). See its
[README](home-server/README.md); `make` from that directory lists the tasks.

## [`youtube-transcript-mcp/`](youtube-transcript-mcp/) — YouTube transcript MCP server

A remote **MCP server** (Streamable HTTP) exposing a `get_transcript` tool to claude.ai and
Claude Code, running **on-device** rather than on hosted infrastructure. Pure Python
standard library + `yt-dlp`, with disk caching, cursor pagination, and a built-in
**OAuth 2.1 (PKCE + DCR, owner-password consent)** layer so it's safe to expose through the
Cloudflare Tunnel. See its [README](youtube-transcript-mcp/README.md).

---

Both are additive and run side by side on the same phone (nginx on `:8080`, the MCP on
`:8765`, each fronted by `cloudflared`), autostarted by Termux:Boot.
