#!/data/data/com.termux/files/usr/bin/bash
#
# start.sh — bring up the phone browser stack, in order:
#   Xvnc (virtual display)  ->  openbox (WM)  ->  @playwright/mcp (headed)  ->  gateway (queue)
#
# Headed-on-a-virtual-display rather than headless: it removes the HeadlessChrome
# fingerprint tells, and the same X display can be attached to with a VNC viewer
# to log into a site by hand (see README).
#
#   start.sh start|stop|status|restart
#
set -u
LAB="${LAB:-$HOME/job-search-pipeline-data}"
HERE="$(cd "$(dirname "$0")" && pwd)"
DISPLAY_NUM="${DISPLAY_NUM:-1}"
GEOMETRY="${GEOMETRY:-1280x900}"
MCP_PORT="${MCP_PORT:-8931}"
GW_PORT="${GW_PORT:-8930}"
PROFILE="${PROFILE:-$LAB/profiles/default}"
CHROME="$PREFIX/lib/chromium/chrome"
export DISPLAY=":$DISPLAY_NUM"
export TMPDIR="$HOME/tmp"

mkdir -p "$LAB" "$TMPDIR" "$PROFILE"

# Local, untracked config: the real public hostname and any secrets-adjacent settings live
# here, not in this repo. Sourced so the supervisor's restarts inherit them too -- without
# this, an auto-restart would drop BROWSER_MCP_PUBLIC_URL and the OAuth metadata would fall
# back to trusting the Host header.
[ -f "$LAB/gateway.env" ] && . "$LAB/gateway.env"

up(){ pgrep -f "$1" >/dev/null 2>&1; }

start_all() {
  termux-wake-lock 2>/dev/null

  if ! up "Xvnc :$DISPLAY_NUM"; then
    echo ">> Xvnc on :$DISPLAY_NUM ($GEOMETRY)"
    # -localhost: the VNC port never leaves the device. Reach it with an SSH tunnel.
    #
    # VncAuth rather than SecurityTypes None: macOS Screen Sharing refuses "None" and
    # prompts for a password it can never accept. The password file is generated once,
    # 0600, and never leaves the device -- read it with:
    #     ssh -p 8022 <phone> 'cat ~/.config/browser-mcp/vncpass.txt'
    if [ ! -f "$HOME/.vnc/passwd" ]; then
      mkdir -p "$HOME/.vnc" "$HOME/.config/browser-mcp"
      VNCPW="$(head -c 9 /dev/urandom | base64 | tr -d "=+/" | cut -c1-8)"
      printf '%s\n' "$VNCPW" > "$HOME/.config/browser-mcp/vncpass.txt"
      chmod 600 "$HOME/.config/browser-mcp/vncpass.txt"
      printf '%s\n%s\n' "$VNCPW" "$VNCPW" | vncpasswd -f > "$HOME/.vnc/passwd" 2>/dev/null
      chmod 600 "$HOME/.vnc/passwd"
      echo ">> generated a VNC password (see ~/.config/browser-mcp/vncpass.txt)"
    fi
    setsid Xvnc ":$DISPLAY_NUM" -geometry "$GEOMETRY" -depth 24 \
      -SecurityTypes VncAuth -PasswordFile "$HOME/.vnc/passwd" -localhost -AlwaysShared \
      >> "$LAB/xvnc.log" 2>&1 < /dev/null &
    sleep 5
  fi

  if ! up "openbox"; then
    echo ">> openbox"
    setsid openbox >> "$LAB/openbox.log" 2>&1 < /dev/null &
    sleep 2
  fi

  # With GW_NO_STATIC_UPSTREAM=1 no browser is started here at all; the gateway spawns
  # whichever profile is actually asked for. That makes GW_MAX_LIVE_PROFILES a real limit
  # -- an adopted static upstream is exempt from eviction, so with one running you always
  # get a second browser the moment any named profile is used. Two concurrent Chromiums is
  # the condition present at every process-shedding incident on this device.
  if [ "${GW_NO_STATIC_UPSTREAM:-0}" != "1" ] && ! up '@playwright/mcp'; then
    echo ">> @playwright/mcp (headed, profile: $PROFILE)"
    cd "$LAB" || exit 1
    setsid node --require "$LAB/shim.cjs" "$LAB/node_modules/@playwright/mcp/cli.js" \
      --port "$MCP_PORT" --host 127.0.0.1 \
      --browser chromium --executable-path "$CHROME" \
      --no-sandbox \
      --user-data-dir "$PROFILE" \
      --viewport-size "${GEOMETRY/x/,}" \
      >> "$LAB/mcp-pw.log" 2>&1 < /dev/null &
    sleep 8
  fi

  if ! up 'gateway.js'; then
    echo ">> gateway (queue+auth) on 127.0.0.1:$GW_PORT"
    # BROWSER_MCP_PUBLIC_URL pins the OAuth issuer/endpoints. Behind the tunnel it MUST
    # be set, or a spoofed Host header could redirect a client's whole auth flow.
    # GW_MAX_SNAPSHOT_BYTES: 0 = log snapshot sizes only; set a cap to refuse huge ones.
    GW_PORT="$GW_PORT" GW_UPSTREAM_PORT="$MCP_PORT" \
    BROWSER_MCP_PUBLIC_URL="${BROWSER_MCP_PUBLIC_URL:-}" \
    GW_MAX_SNAPSHOT_BYTES="${GW_MAX_SNAPSHOT_BYTES:-0}" \
      setsid node "$HERE/gateway.js" >> "$LAB/gateway.log" 2>&1 < /dev/null &
    sleep 3
  fi
  status_all
}

stop_all() {
  pkill -f 'gateway.js' 2>/dev/null
  pkill -f '@playwright/mcp' 2>/dev/null
  sleep 2
  pkill -f 'lib/chromium/chrome' 2>/dev/null
  pkill -f 'openbox' 2>/dev/null
  pkill -f "Xvnc :$DISPLAY_NUM" 2>/dev/null
  echo "stopped"
}

status_all() {
  printf '%-14s %s\n' "Xvnc"     "$(up "Xvnc :$DISPLAY_NUM" && echo "up (:$DISPLAY_NUM $GEOMETRY)" || echo down)"
  printf '%-14s %s\n' "openbox"  "$(up openbox && echo up || echo down)"
  printf '%-14s %s\n' "mcp"      "$(up '@playwright/mcp' && echo "up (:$MCP_PORT)" || \
    { [ "${GW_NO_STATIC_UPSTREAM:-0}" = "1" ] && echo "on demand (no static upstream)" || echo down; })"
  printf '%-14s %s\n' "gateway"  "$(up 'gateway.js' && echo "up (:$GW_PORT)" || echo down)"
  printf '%-14s %s\n' "chromium" "$(pgrep -fc 'lib/chromium/chrome' 2>/dev/null || echo 0) processes"
  echo "--- gateway status ---"
  curl -s -m 5 "http://127.0.0.1:$GW_PORT/status" || echo "(gateway not answering)"
}

case "${1:-start}" in
  start)   start_all ;;
  stop)    stop_all ;;
  restart) stop_all; sleep 2; start_all ;;
  status)  status_all ;;
  *) echo "usage: start.sh {start|stop|status|restart}"; exit 1 ;;
esac
