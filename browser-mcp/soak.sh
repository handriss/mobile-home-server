#!/data/data/com.termux/files/usr/bin/bash
# soak.sh — overnight feasibility soak for the phone-browser MCP.
#
# Every INTERVAL seconds: make sure the @playwright/mcp server is up, drive a real
# page load through it over MCP, and record timings + memory + battery.
# The point is not speed; it is whether this survives unattended for many hours:
#   - does Android kill node / chromium overnight?
#   - does memory creep across cycles (leak) or stay flat?
#   - does the browser go stale after hours of being open?
#
# Writes one CSV row per cycle to ~/job-search-pipeline-data/soak.csv.
# Start:  bash ~/job-search-pipeline-data/soak.sh start
# Status: bash ~/job-search-pipeline-data/soak.sh status
# Stop:   bash ~/job-search-pipeline-data/soak.sh stop

set -u
LAB="$HOME/job-search-pipeline-data"
CSV="$LAB/soak.csv"
LOG="$LAB/soak.log"
PORT=8930                                  # the gateway, not @playwright/mcp directly
INTERVAL="${SOAK_INTERVAL:-1800}"          # 30 minutes
BASE="http://localhost:$PORT/mcp"
STACK="$HOME/job-search-pipeline/start.sh"

# Rotate targets so we are not just measuring one cached page.
TARGETS=(
  "https://news.ycombinator.com/"
  "https://en.wikipedia.org/wiki/Android_(operating_system)"
  "https://www.theverge.com/"
  "https://www.bbc.com/news"
)

ts()  { date +%Y-%m-%dT%H:%M:%S%z; }
note(){ echo "$(ts) $*" >> "$LOG"; }

# The whole stack must be up: Xvnc + openbox + @playwright/mcp + gateway.
mcp_up() {
  pgrep -f '@playwright/mcp' >/dev/null 2>&1 && pgrep -f 'gateway.js' >/dev/null 2>&1
}

start_mcp() { bash "$STACK" start >/dev/null 2>&1; sleep 5; }

# Sum PSS across all chromium processes (honest shared-page accounting).
chromium_pss() {
  local total=0 s
  for p in $(pgrep -f 'lib/chromium/chrome' 2>/dev/null); do
    s=$(awk '/^Pss:/{s+=$2} END{print s+0}' "/proc/$p/smaps_rollup" 2>/dev/null)
    [ -n "$s" ] && total=$((total + s))
  done
  echo "$total"
}
node_rss() {
  local p; p=$(pgrep -f '@playwright/mcp' | head -1)
  [ -n "$p" ] && awk '/^VmRSS:/{print $2}' "/proc/$p/status" 2>/dev/null || echo 0
}
nchrome() { pgrep -f 'lib/chromium/chrome' 2>/dev/null | wc -l | tr -d ' '; }
memavail(){ awk '/^MemAvailable:/{print $2}' /proc/meminfo; }
battery() { # -> "temp_c,percent"; empty fields if Termux:API is unavailable
  termux-battery-status 2>/dev/null | python -c '
import sys, json
try:
    d = json.load(sys.stdin)
    print("%s,%s" % (d.get("temperature", ""), d.get("percentage", "")))
except Exception:
    print(",")
' 2>/dev/null || echo ","
}

one_cycle() {
  local n="$1"
  local url="${TARGETS[$(( n % ${#TARGETS[@]} ))]}"
  local restarted=0 t0 dur_nav dur_snap ok=1 sid
  [ -f "$CSV" ] || echo "ts,cycle,url,ok,nav_ms,snapshot_ms,chrome_procs,chrome_pss_kb,node_rss_kb,mem_avail_kb,batt_temp_c,batt_pct,mcp_restarted,note" > "$CSV"

  if ! mcp_up; then note "MCP server down -> restarting"; start_mcp; restarted=1; fi

  local H1='Content-Type: application/json' H2='Accept: application/json, text/event-stream'

  sid=$(curl -s -m 30 -D - -o /dev/null -X POST "$BASE" -H "$H1" -H "$H2" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"soak","version":"1"}}}' \
    2>/dev/null | grep -i '^mcp-session-id' | tr -d '\r' | awk '{print $2}')

  if [ -z "$sid" ]; then
    note "cycle $n: initialize FAILED"
    echo "$(ts),$n,$url,0,,,$(nchrome),$(chromium_pss),$(node_rss),$(memavail),$(battery),$restarted,init_failed" >> "$CSV"
    return
  fi
  curl -s -m 20 -X POST "$BASE" -H "mcp-session-id: $sid" -H "$H1" -H "$H2" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null 2>&1

  t0=$(date +%s%3N)
  local nav; nav=$(curl -s -m 120 -X POST "$BASE" -H "mcp-session-id: $sid" -H "$H1" -H "$H2" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"browser_navigate\",\"arguments\":{\"url\":\"$url\"}}}" 2>/dev/null)
  dur_nav=$(( $(date +%s%3N) - t0 ))
  case "$nav" in *'"isError":true'*|"") ok=0;; esac

  t0=$(date +%s%3N)
  local snap; snap=$(curl -s -m 120 -X POST "$BASE" -H "mcp-session-id: $sid" -H "$H1" -H "$H2" \
    -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"browser_snapshot","arguments":{}}}' 2>/dev/null)
  dur_snap=$(( $(date +%s%3N) - t0 ))
  case "$snap" in *'"isError":true'*|"") ok=0;; esac

  # Close the session so we do not leak one browser tab per cycle.
  curl -s -m 20 -X DELETE "$BASE" -H "mcp-session-id: $sid" >/dev/null 2>&1

  echo "$(ts),$n,$url,$ok,$dur_nav,$dur_snap,$(nchrome),$(chromium_pss),$(node_rss),$(memavail),$(battery),$restarted," >> "$CSV"
  note "cycle $n ok=$ok nav=${dur_nav}ms snap=${dur_snap}ms pss=$(chromium_pss)kB procs=$(nchrome)"
}

case "${1:-start}" in
  start)
    mkdir -p "$LAB"
    [ -f "$CSV" ] || echo "ts,cycle,url,ok,nav_ms,snapshot_ms,chrome_procs,chrome_pss_kb,node_rss_kb,mem_avail_kb,batt_temp_c,batt_pct,mcp_restarted,note" > "$CSV"
    rm -f "$LAB/.soak-stop"
    if pgrep -f 'soak-loop' >/dev/null 2>&1; then echo "soak already running"; exit 0; fi
    termux-wake-lock 2>/dev/null
    note "=== soak started, interval ${INTERVAL}s ==="
    setsid bash -c '
      n=0
      while [ ! -f "$HOME/job-search-pipeline-data/.soak-stop" ]; do
        bash "$HOME/job-search-pipeline-data/soak.sh" cycle "$n"
        n=$((n+1))
        sleep '"$INTERVAL"'
      done   # soak-loop
    ' >/dev/null 2>&1 < /dev/null &
    sleep 2
    echo "soak started (interval ${INTERVAL}s). CSV: $CSV"
    ;;
  cycle)  one_cycle "${2:-0}" ;;
  stop)
    touch "$LAB/.soak-stop"; pkill -f 'soak-loop' 2>/dev/null
    note "=== soak stopped ==="; echo "soak stopped"
    ;;
  status)
    echo "loop:  $(pgrep -f 'soak-loop' >/dev/null && echo RUNNING || echo stopped)"
    echo "mcp:   $(mcp_up && echo RUNNING || echo stopped)"
    echo "cycles: $(( $(wc -l < "$CSV" 2>/dev/null || echo 1) - 1 ))"
    echo "--- last 10 ---"; tail -10 "$CSV" 2>/dev/null
    ;;
  *) echo "usage: soak.sh {start|stop|status}"; exit 1;;
esac
