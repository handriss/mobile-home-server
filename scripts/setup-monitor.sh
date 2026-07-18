#!/usr/bin/env bash
#
# setup-monitor.sh — install the battery-safety monitor on the phone, end to end,
# from the Mac. Installs Termux:API (APK + package), deploys battery-monitor.sh with
# its config + boot autostart, and starts it. Run AFTER provision.sh.
#
# Usage:
#   scripts/setup-monitor.sh
#   NTFY_TOPIC=my-topic HEALTHCHECK_URL=https://hc-ping.com/xxxx NAME=oppo-server scripts/setup-monitor.sh
#
# Env (all optional):
#   NTFY_TOPIC        ntfy.sh topic to publish to (default: a random one, printed at the end)
#   HEALTHCHECK_URL   healthchecks.io ping URL for the dead-man's switch (default: off)
#   NAME              label used in notification titles (default: home-server)
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
resolve_serial

NAME="${NAME:-home-server}"
NTFY_TOPIC="${NTFY_TOPIC:-home-svr-batt-$(openssl rand -hex 5)}"
HEALTHCHECK_URL="${HEALTHCHECK_URL:-none}"
HTTP_PORT="${MON_HTTP_PORT:-8016}"
MAC_IP="$(mac_ip)"; [ -n "$MAC_IP" ] || die "could not detect Mac LAN IP"
CACHE="$HERE/../cache"; mkdir -p "$CACHE"

# 1. Termux:API companion APK (needed for termux-battery-status; the raw /sys nodes
#    are SELinux-blocked for apps). Universal APK, pinned like provision.sh's APKs.
TERMUX_API_URL="https://github.com/termux/termux-api/releases/download/v0.53.0/termux-api-app_v0.53.0%2Bgithub.debug.apk"
APK="$CACHE/termux-api.apk"
if [ ! -s "$APK" ]; then
  log "downloading Termux:API APK"
  curl -fsSL "$TERMUX_API_URL" -o "$APK"
fi
log "installing Termux:API app"
adb install -r -g "$APK" | tail -1

# 2. termux-api package inside Termux
log "installing termux-api package"
"$HERE/termux-run.sh" 'pkg install -y termux-api'
sleep 20

# 3. deploy + start the monitor
SRV="$(mktemp -d)"; cp "$HERE/battery-monitor.sh" "$HERE/install-monitor.sh" "$SRV/"
python3 -m http.server "$HTTP_PORT" --bind 0.0.0.0 --directory "$SRV" >/dev/null 2>&1 &
SRV_PID=$!; trap 'kill "$SRV_PID" 2>/dev/null || true; rm -rf "$SRV"' EXIT
sleep 2
curl -fsS "http://$MAC_IP:$HTTP_PORT/install-monitor.sh" >/dev/null || die "file server unreachable at $MAC_IP:$HTTP_PORT"
log "installing + starting the battery monitor"
termux_fetch_run "http://$MAC_IP:$HTTP_PORT/install-monitor.sh" "im.sh" "$NTFY_TOPIC $HEALTHCHECK_URL $MAC_IP $HTTP_PORT $NAME"
sleep 3

# 4. self-test + report
curl -s -m 10 -H "Title: Monitor installed" -H "Tags: white_check_mark" \
  -d "Battery monitor is live on $NAME." "https://ntfy.sh/$NTFY_TOPIC" >/dev/null || true
echo
printf '\033[1;32m✓ monitor installed\033[0m\n'
echo "  ntfy topic : $NTFY_TOPIC   (subscribe in the ntfy app; server ntfy.sh)"
echo "  healthcheck: $([ "$HEALTHCHECK_URL" = none ] && echo '(off — set HEALTHCHECK_URL to enable)' || echo "$HEALTHCHECK_URL")"
echo "  preview digest:  scripts/termux-run.sh 'bash \$HOME/batt-monitor/monitor.sh digest'"
