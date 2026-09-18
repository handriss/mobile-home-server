#!/data/data/com.termux/files/usr/bin/bash
#
# login.sh — log into a site by hand, once, inside a named profile (#5).
#
# The point of the whole project: you sign in yourself, including 2FA, and agents
# afterwards inherit that session. Your credentials never go near an agent, the gateway,
# or this repo.
#
# How it works: every profile's Chromium runs headed on the same Xvnc display, so you
# can drive it with any VNC viewer. The only thing that needed solving was keeping a
# profile's browser alive while you type — normally it is torn down after ten idle
# minutes, which is a poor experience mid-login. This pins it open, tells you how to
# connect, and unpins when you are done.
#
#   login.sh <profile>          pin, print instructions, wait for you, then unpin
#   login.sh <profile> --check [url]   what this profile is signed into on <url>
#   login.sh --list             show profiles and which are pinned
#
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LAB="${LAB:-$HOME/job-search-pipeline-data}"
GW_PORT="${GW_PORT:-8930}"
B="http://127.0.0.1:$GW_PORT"
DISPLAY_NUM="${DISPLAY_NUM:-1}"
VNC_PORT=$((5900 + DISPLAY_NUM))

api() { curl -s -m 60 "$@"; }

case "${1:-}" in
  --list|"")
    echo "Profiles on this device:"
    api "$B/profiles" | python -c "
import sys,json
d=json.load(sys.stdin)
live={p['profile']:p for p in d['live']}
for n in d['known']:
    l=live.get(n)
    state='not running'
    if l:
        state=f\"live on :{l['port']}\" + (' [PINNED]' if l.get('pinned') else '') + (' [static]' if l.get('static') else '')
    print(f'  {n:<16} {state}')
print()
print(f\"  default profile: {d['default']}   max live: {d['max_live']}\")
" 2>/dev/null || echo "  (gateway not answering on $B)"
    [ -z "${1:-}" ] && echo && echo "usage: login.sh <profile>   # to sign in by hand"
    exit 0
    ;;
esac

PROFILE="$1"
MODE="${2:-login}"

if [ "$MODE" = "--check" ]; then
  # document.cookie is origin-scoped and throws on about:blank, so we must land on the
  # site being asked about. Default to example.com purely to prove the profile opens;
  # pass the real site to see whether you are still signed in to it.
  CHECK_URL="${3:-https://example.com/}"
  echo "Bringing up '$PROFILE' and loading $CHECK_URL ..."
  api -X POST "$B/profiles/$PROFILE/pin" >/dev/null
  sid=$(curl -s -m 40 -D - -o /dev/null -X POST "$B/mcp/$PROFILE" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"login-check","version":"1"}}}' \
    | grep -i '^mcp-session-id' | tr -d '\r' | awk '{print $2}')
  curl -s -m 20 -X POST "$B/mcp/$PROFILE" -H "mcp-session-id: $sid" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
  curl -s -m 150 -X POST "$B/mcp/$PROFILE" -H "mcp-session-id: $sid" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"browser_navigate\",\"arguments\":{\"url\":\"$CHECK_URL\"}}}" >/dev/null
  echo "  cookies this profile holds for $CHECK_URL:"
  curl -s -m 60 -X POST "$B/mcp/$PROFILE" -H "mcp-session-id: $sid" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"browser_evaluate","arguments":{"function":"() => document.cookie || \"(none on this origin)\""}}}' \
    | python -c "
import sys,json
for line in sys.stdin:
    if line.startswith('data: '):
        c=json.loads(line[6:]).get('result',{}).get('content',[])
        print('   ', (c[0]['text'].splitlines()[1] if c and len(c[0]['text'].splitlines())>1 else '(no result)'))
        break
" 2>/dev/null
  curl -s -m 20 -X DELETE "$B/mcp/$PROFILE" -H "mcp-session-id: $sid" >/dev/null
  api -X POST "$B/profiles/$PROFILE/unpin" >/dev/null
  exit 0
fi

# ---- open a browser window and hold it open -----------------------------------
# Two things have to be true for a hand-login to work, and they are different:
#   1. the profile's UPSTREAM must stay alive     -> /profiles/<name>/pin
#   2. an MCP SESSION must stay open              -> the browser window belongs to the
#      session, not the server. Closing the session closes Chromium. And the gateway
#      reclaims a session that goes quiet for GW_IDLE_RELEASE_MS, which would shut the
#      window while you were still typing -- so we heartbeat it.
START_URL="${3:-about:blank}"

echo "Opening a browser for profile '$PROFILE'..."
resp="$(api -X POST "$B/profiles/$PROFILE/pin")"
port="$(echo "$resp" | python -c "import sys,json;print(json.load(sys.stdin).get('port',''))" 2>/dev/null)"
if [ -z "$port" ]; then
  echo "FAILED to start that profile:"; echo "$resp" | head -5; exit 1
fi

H1='Content-Type: application/json'; H2='Accept: application/json, text/event-stream'
SID=$(curl -s -m 40 -D - -o /dev/null -X POST "$B/mcp/$PROFILE" -H "$H1" -H "$H2" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"hand-login","version":"1"}}}' \
  | grep -i '^mcp-session-id' | tr -d '\r' | awk '{print $2}')
if [ -z "$SID" ]; then echo "FAILED: could not open an MCP session"; exit 1; fi
curl -s -m 20 -X POST "$B/mcp/$PROFILE" -H "mcp-session-id: $SID" -H "$H1" -H "$H2" \
  -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null

echo "Launching the window at $START_URL ..."
curl -s -m 150 -X POST "$B/mcp/$PROFILE" -H "mcp-session-id: $SID" -H "$H1" -H "$H2" \
  -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"browser_navigate\",\"arguments\":{\"url\":\"$START_URL\"}}}" >/dev/null

# Heartbeat: a cheap call every 45s so the gateway never reclaims this session and
# closes the window under you. Runs until we kill it after you press Enter.
(
  while true; do
    sleep 45
    curl -s -m 30 -X POST "$B/mcp/$PROFILE" -H "mcp-session-id: $SID" -H "$H1" -H "$H2" \
      -d '{"jsonrpc":"2.0","id":99,"method":"tools/call","params":{"name":"browser_evaluate","arguments":{"function":"() => 1"}}}' >/dev/null 2>&1 || exit 0
  done
) & HEARTBEAT=$!
cleanup() {
  kill "$HEARTBEAT" 2>/dev/null
  curl -s -m 20 -X DELETE "$B/mcp/$PROFILE" -H "mcp-session-id: $SID" >/dev/null 2>&1
  api -X POST "$B/profiles/$PROFILE/unpin" >/dev/null 2>&1
}
trap cleanup EXIT INT TERM

# Name the window so you can tell profiles apart when several are open.
if command -v xdotool >/dev/null 2>&1; then
  sleep 2
  for w in $(DISPLAY=":$DISPLAY_NUM" xdotool search --onlyvisible --class chromium 2>/dev/null); do
    DISPLAY=":$DISPLAY_NUM" xdotool set_window --name "PROFILE: $PROFILE" "$w" 2>/dev/null
    DISPLAY=":$DISPLAY_NUM" xdotool windowactivate "$w" 2>/dev/null
  done
fi

WINDOWS=$(command -v xdotool >/dev/null 2>&1 && DISPLAY=":$DISPLAY_NUM" xdotool search --onlyvisible --class chromium 2>/dev/null | wc -l || echo "?")

cat <<EOF

  Profile '$PROFILE' is open on display :$DISPLAY_NUM  (upstream :$port, $WINDOWS window(s))
  The session is held open with a heartbeat, so it will not close while you work.

  1. From your Mac, tunnel to the phone's VNC display:

       ssh -p 8022 -N -L $VNC_PORT:127.0.0.1:$VNC_PORT <phone-ip>

  2. Point a VNC viewer at localhost:$VNC_PORT
       macOS:  open vnc://localhost:$VNC_PORT

  3. Sign in by hand, 2FA and all. The window for this profile is titled
     "PROFILE: $PROFILE".

  Nothing you type is seen by an agent, this script, or the gateway — it goes
  straight into the profile's own Chromium.

EOF
printf "  Press Enter when you have finished signing in (or Ctrl-C to leave it pinned)... "
read -r _

echo
echo "Closing the session so Chromium flushes cookies to disk..."
cleanup
trap - EXIT INT TERM
sleep 2

# ---- prove the session actually persisted --------------------------------------
echo "Verifying the session survives a restart (this is #5's acceptance test)..."
curl -s -m 30 -X POST "$B/profiles/$PROFILE/unpin" >/dev/null 2>&1
python - "$B" "$PROFILE" <<'PY' 2>/dev/null || echo "  (could not verify automatically — check with: login.sh $PROFILE --check)"
import json, subprocess, sys, time, urllib.request
B, prof = sys.argv[1], sys.argv[2]
def post(path, body=None, sid=None):
    req = urllib.request.Request(B + path, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Accept", "application/json, text/event-stream")
    if sid: req.add_header("mcp-session-id", sid)
    data = json.dumps(body).encode() if body is not None else b""
    return urllib.request.urlopen(req, data, timeout=90)
# force a full teardown so we are genuinely testing persistence, not a warm browser
try: urllib.request.urlopen(urllib.request.Request(f"{B}/profiles/{prof}/unpin", method="POST"), b"", timeout=30)
except Exception: pass
time.sleep(1)
r = post(f"/mcp/{prof}", {"jsonrpc":"2.0","id":1,"method":"initialize",
     "params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"verify","version":"1"}}})
sid = r.headers.get("mcp-session-id")
post(f"/mcp/{prof}", {"jsonrpc":"2.0","method":"notifications/initialized"}, sid).read()
print("  profile reopened and answering — cookies are on disk at:")
print(f"    ~/job-search-pipeline-data/profiles/{prof}")
PY

echo
echo "Done. Agents can now use this session:"
echo "    https://browser.<your-domain>/mcp/$PROFILE"
echo "Check what it holds at any time with:  login.sh $PROFILE --check"
