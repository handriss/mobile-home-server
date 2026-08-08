# Mobile Home Server

A spare **Android phone** turned into an always-on home server, running in Termux.
Everything is driven from a Mac (ADB over USB, then SSH over WiFi) — **no root, no cloud
host**. Built and validated on an OPPO Reno5 Z (CPH2211), Android 13 / ColorOS; see
[Portability](#portability) for what changes on other handsets.

This repo holds two projects that run on it:

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

## Portability

Nothing here is Oppo-specific by design — it's a Termux project, so it should run on any
Android phone that can install Termux, Termux:API and Termux:Boot. Battery telemetry comes
from `termux-battery-status`, which reads Android's own `BatteryManager`, so it is
vendor-neutral. The MCP server is pure Python + `yt-dlp` and knows nothing about the device
at all.

Four things need attention on a different handset:

| | |
|---|---|
| **ADB tap coordinates** | `home-server/provision.sh` automates the on-phone setup with `adb shell input tap` at fixed coordinates. **These will not transfer** — a different screen size or launcher and the taps land somewhere else. Either adjust them or do that part by hand; it is a handful of taps, once. |
| **Battery-optimisation whitelist** | Every vendor kills background processes, but the menu path differs — and some (notably Xiaomi/MIUI) are considerably more aggressive than ColorOS. The requirement is universal; only the route through Settings changes. |
| **Charge capping** | Documented here as unavailable, and that holds everywhere: the relevant `/sys` nodes are root-owned on every modern vendor. The paths named in `home-server/README.md` happen to be Oppo's. |
| **Post-reboot ADB timing** | This phone takes ~20 s to re-expose USB ADB after a reboot. Yours may differ. Cosmetic. |

Everything else — nginx, SSH on `:8022`, `scp` deploys, wake-lock, Termux:Boot autostart,
the alerting state machine, the diagnostics dashboard, the Cloudflare Tunnel — is stock
Android and Termux.
