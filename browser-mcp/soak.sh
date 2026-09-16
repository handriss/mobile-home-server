#!/data/data/com.termux/files/usr/bin/bash
# soak.sh — unattended endurance soak for the phone-browser MCP stack.
#
# Every INTERVAL seconds: drive a real page load through the gateway over MCP and
# record timings, memory, battery and gateway internals. The question is not speed,
# it is whether this survives unattended for many hours:
#   - does Android kill node / chromium overnight?
#   - does memory creep across cycles (leak) or stay flat?
#   - does the browser go stale, or the gateway's lock drift from reality?
#
# This phone is not a dedicated device. It also serves nginx, the yt-transcript MCP
# and Forgejo. The soak therefore runs with GUARD RAILS: if the battery gets hot, if
# free memory collapses, or if a neighbour service stops answering, the soak aborts
# itself, tears the browser down and shouts on ntfy. Losing soak data beats losing
# the issue tracker.
#
#   soak.sh start | stop | status | report
#
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LAB="${LAB:-$HOME/job-search-pipeline-data}"
CSV="$LAB/soak.csv"
LOG="$LAB/soak.log"          # human-readable one-liners
EVT="$LAB/soak-events.jsonl" # verbose structured events
STOP="$LAB/.soak-stop"
PORT="${GW_PORT:-8930}"
BASE="http://127.0.0.1:$PORT/mcp"
INTERVAL="${SOAK_INTERVAL:-1800}"      # 30 min, per ticket #2
PROBE_EVERY="${SOAK_PROBE_EVERY:-4}"   # run corner-case probes every Nth cycle
STACK="$HERE/start.sh"

# ---- guard rails ------------------------------------------------------------
ABORT_TEMP_C="${SOAK_ABORT_TEMP_C:-43}"          # same threshold as battery-monitor
ABORT_MEM_KB="${SOAK_ABORT_MEM_KB:-1572864}"     # 1.5 GiB MemAvailable floor
NEIGHBOUR_FAILS="${SOAK_NEIGHBOUR_FAILS:-3}"     # consecutive failures before abort
# host:port:label — the co-tenants this soak must not take down
NEIGHBOURS=("8080:nginx" "8765:yt-mcp" "3000:forgejo")

NTFY_URL="${NTFY_URL:-https://ntfy.sh}"
NTFY_TOPIC="${NTFY_TOPIC:-$(grep -m1 '^NTFY_TOPIC=' "$HOME/batt-monitor/monitor.conf" 2>/dev/null | cut -d= -f2)}"

TARGETS=(
  "https://news.ycombinator.com/"
  "https://en.wikipedia.org/wiki/Android_(operating_system)"
  "https://www.theverge.com/"
  "https://www.bbc.com/news"
)

ts()   { date +%Y-%m-%dT%H:%M:%S%z; }
note() { echo "$(ts) $*" >> "$LOG"; }
# Structured event. jev <evt> <k=v>... — values are JSON-escaped as strings.
jev() {
  local evt="$1"; shift
  local out="{\"ts\":\"$(ts)\",\"evt\":\"$evt\""
  local kv k v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    v="${v//\\/\\\\}"; v="${v//\"/\\\"}"; v="${v//$'\n'/ }"
    out="$out,\"$k\":\"$v\""
  done
  echo "$out}" >> "$EVT"
}
ntfy() { # ntfy <priority> <title> <body>
  [ -n "${NTFY_TOPIC:-}" ] || return 0
  curl -s -m 15 -H "Title: $2" -H "Priority: $1" -d "$3" \
    "$NTFY_URL/$NTFY_TOPIC" >/dev/null 2>&1 || true
}

# ---- sampling ---------------------------------------------------------------
chromium_pss() { local t=0 s
  for p in $(pgrep -f 'lib/chromium/chrome' 2>/dev/null); do
    s=$(awk '/^Pss:/{s+=$2} END{print s+0}' "/proc/$p/smaps_rollup" 2>/dev/null)
    [ -n "$s" ] && t=$((t+s)); done; echo "$t"; }
node_rss() { local p; p=$(pgrep -f '@playwright/mcp' | head -1)
  [ -n "$p" ] && awk '/^VmRSS:/{print $2}' "/proc/$p/status" 2>/dev/null || echo 0; }
nchrome()  { pgrep -f 'lib/chromium/chrome' 2>/dev/null | wc -l | tr -d ' '; }
memavail() { awk '/^MemAvailable:/{print $2}' /proc/meminfo; }
batt_json(){ timeout 25 termux-battery-status 2>/dev/null; }
batt_field(){ echo "$1" | python -c "
import sys,json
try: print(json.load(sys.stdin).get('$2',''))
except Exception: print('')
" 2>/dev/null; }

# Gateway internals: queue depth + the counters that reveal drift/wedging.
gw_stat() { # -> "depth,granted,timedOut,idleReleases,shed,reconciles,upstreamRestarts,chrome_procs"
  timeout 10 curl -s "http://127.0.0.1:$PORT/status" 2>/dev/null | python -c "
import sys,json
try:
    d=json.load(sys.stdin); q=d.get('queue',{}); s=d.get('stats',{})
    print(','.join(str(x) for x in [q.get('depth',''),s.get('granted',''),s.get('timedOut',''),
        s.get('idleReleases',''),s.get('shed',''),s.get('reconciles',''),
        s.get('upstreamRestarts',''),d.get('chrome_processes','')]))
except Exception: print(',,,,,,,')
" 2>/dev/null || echo ",,,,,,,"
}

stack_up() { pgrep -f '@playwright/mcp' >/dev/null 2>&1 && pgrep -f 'gateway.js' >/dev/null 2>&1; }

# ---- guard evaluation -------------------------------------------------------
NEIGHBOUR_STREAK=0
check_neighbours() { # -> echoes "ok" or "down:<labels>"
  local down=() np nl code
  for n in "${NEIGHBOURS[@]}"; do
    np="${n%%:*}"; nl="${n##*:}"
    code=$(timeout 8 curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$np/" 2>/dev/null)
    # any HTTP response means the service is alive; 000/empty means it is not
    case "${code:-000}" in 000|"") down+=("$nl");; esac
  done
  if [ ${#down[@]} -eq 0 ]; then echo "ok"; else
    local IFS=+; echo "down:${down[*]}"; fi
}

# Returns 0 to continue, 1 to abort. Sets ABORT_REASON.
ABORT_REASON=""
guards_ok() {
  local bj temp mem nb
  bj="$(batt_json)"; temp="$(batt_field "$bj" temperature)"; mem="$(memavail)"

  if [ -n "$temp" ] && awk "BEGIN{exit !($temp >= $ABORT_TEMP_C)}"; then
    ABORT_REASON="battery ${temp}C >= ${ABORT_TEMP_C}C"; return 1; fi
  if [ -n "$mem" ] && [ "$mem" -lt "$ABORT_MEM_KB" ]; then
    ABORT_REASON="MemAvailable ${mem}kB < ${ABORT_MEM_KB}kB"; return 1; fi

  nb="$(check_neighbours)"
  if [ "$nb" = "ok" ]; then NEIGHBOUR_STREAK=0; else
    NEIGHBOUR_STREAK=$((NEIGHBOUR_STREAK+1))
    jev neighbour_unhealthy "detail=$nb" "streak=$NEIGHBOUR_STREAK"
    if [ "$NEIGHBOUR_STREAK" -ge "$NEIGHBOUR_FAILS" ]; then
      ABORT_REASON="neighbour(s) ${nb#down:} unreachable ${NEIGHBOUR_STREAK}x"; return 1; fi
  fi
  return 0
}

do_abort() {
  local why="$1"
  note "!!! ABORT: $why"
  jev abort "reason=$why"
  touch "$STOP"
  bash "$STACK" stop >/dev/null 2>&1
  ntfy urgent "Browser soak ABORTED" "$why -- browser stack torn down to protect the phone. See $EVT"
}

# ---- MCP helpers ------------------------------------------------------------
H1='Content-Type: application/json'
H2='Accept: application/json, text/event-stream'

mcp_open() { # -> session id, or empty
  curl -s -m 30 -D - -o /dev/null -X POST "$BASE" -H "$H1" -H "$H2" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"soak","version":"2"}}}' \
    2>/dev/null | grep -i '^mcp-session-id' | tr -d '\r' | awk '{print $2}'
}
mcp_call() { # mcp_call <sid> <timeout_s> <json-params-for-tools/call>
  curl -s -m "$2" -X POST "$BASE" -H "mcp-session-id: $1" -H "$H1" -H "$H2" -d "$3" 2>/dev/null
}
mcp_close() { curl -s -m 20 -X DELETE "$BASE" -H "mcp-session-id: $1" >/dev/null 2>&1; }

# Classify an MCP response so failures are named, not just "ok=0".
classify() { # classify <response-body> <curl-exit-ish>
  local r="$1"
  if [ -z "$r" ]; then echo "empty_response_or_timeout"; return; fi
  case "$r" in
    *'"isError":true'*)
      case "$r" in
        *queue_full*)            echo "gw_queue_full";;
        *queue_timeout*)         echo "gw_queue_timeout";;
        *'already in use'*)      echo "raw_browser_in_use_LEAK";;  # gateway should never let this through
        *net::ERR_NAME*)         echo "dns_failure";;
        *net::ERR_*)             echo "network_error";;
        *imeout*)                echo "nav_timeout";;
        *)                       echo "tool_error";;
      esac;;
    *'"error"'*) echo "jsonrpc_error";;
    *) echo "";;
  esac
}

# ---- one soak cycle ---------------------------------------------------------
one_cycle() {
  local n="$1"
  local url="${TARGETS[$(( n % ${#TARGETS[@]} ))]}"
  local restarted=0 t0 dur_nav=0 dur_snap=0 ok=1 sid note_field="" cls

  [ -f "$CSV" ] || echo "ts,cycle,url,ok,nav_ms,snapshot_ms,chrome_procs,chrome_pss_kb,node_rss_kb,mem_avail_kb,batt_temp_c,batt_pct,gw_depth,gw_granted,gw_timedout,gw_idlereleases,gw_shed,gw_reconciles,gw_upstreamrestarts,gw_chrome,neighbours,mcp_restarted,note" > "$CSV"

  jev cycle_start "cycle=$n" "url=$url"

  if ! stack_up; then
    note "stack down -> restarting"; jev stack_restart "cycle=$n"
    bash "$STACK" start >/dev/null 2>&1; sleep 8; restarted=1
  fi

  sid="$(mcp_open)"
  if [ -z "$sid" ]; then
    ok=0; note_field="init_failed"; jev init_failed "cycle=$n"
  else
    curl -s -m 20 -X POST "$BASE" -H "mcp-session-id: $sid" -H "$H1" -H "$H2" \
      -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null 2>&1

    t0=$(date +%s%3N)
    local nav; nav="$(mcp_call "$sid" 150 "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"browser_navigate\",\"arguments\":{\"url\":\"$url\"}}}")"
    dur_nav=$(( $(date +%s%3N) - t0 ))
    cls="$(classify "$nav")"
    [ -n "$cls" ] && { ok=0; note_field="nav:$cls"; jev nav_failed "cycle=$n" "class=$cls" "ms=$dur_nav"; }

    t0=$(date +%s%3N)
    local snap; snap="$(mcp_call "$sid" 150 '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"browser_snapshot","arguments":{}}}')"
    dur_snap=$(( $(date +%s%3N) - t0 ))
    cls="$(classify "$snap")"
    [ -n "$cls" ] && { ok=0; note_field="${note_field:+$note_field;}snap:$cls"; jev snap_failed "cycle=$n" "class=$cls" "ms=$dur_snap"; }
    jev snapshot_size "cycle=$n" "bytes=${#snap}"

    mcp_close "$sid"
  fi

  local bj temp pct nb gw
  bj="$(batt_json)"; temp="$(batt_field "$bj" temperature)"; pct="$(batt_field "$bj" percentage)"
  nb="$(check_neighbours)"; gw="$(gw_stat)"

  echo "$(ts),$n,$url,$ok,$dur_nav,$dur_snap,$(nchrome),$(chromium_pss),$(node_rss),$(memavail),$temp,$pct,$gw,$nb,$restarted,$note_field" >> "$CSV"
  note "cycle $n ok=$ok nav=${dur_nav}ms snap=${dur_snap}ms pss=$(chromium_pss)kB procs=$(nchrome) mem=$(memavail)kB temp=${temp}C nb=$nb ${note_field:+[$note_field]}"
  jev cycle_end "cycle=$n" "ok=$ok" "nav_ms=$dur_nav" "snap_ms=$dur_snap" "pss_kb=$(chromium_pss)" "mem_kb=$(memavail)" "temp=$temp" "neighbours=$nb" "note=$note_field"
}

# ---- main -------------------------------------------------------------------
case "${1:-start}" in
  start)
    mkdir -p "$LAB"
    if ps -ef 2>/dev/null | grep -q "[s]oak-loop"; then echo "soak already running"; exit 0; fi
    rm -f "$STOP"
    termux-wake-lock 2>/dev/null
    note "=== soak started: interval=${INTERVAL}s probes_every=${PROBE_EVERY} abort_temp=${ABORT_TEMP_C}C abort_mem=${ABORT_MEM_KB}kB ==="
    jev soak_start "interval=$INTERVAL" "probe_every=$PROBE_EVERY" "abort_temp=$ABORT_TEMP_C" "abort_mem_kb=$ABORT_MEM_KB"
    ntfy default "Browser soak started" "interval ${INTERVAL}s, aborts at ${ABORT_TEMP_C}C or <$((ABORT_MEM_KB/1024))MB free"
    SELF="$HERE/soak.sh"
    setsid bash -c '
      n=0
      while [ ! -f "'"$STOP"'" ]; do
        if ! bash "'"$SELF"'" guard; then break; fi
        bash "'"$SELF"'" cycle "$n"
        if [ "'"$PROBE_EVERY"'" -gt 0 ] && [ $(( n % '"$PROBE_EVERY"' )) -eq 0 ]; then
          bash "'"$HERE"'/probes.sh" run "$n" >/dev/null 2>&1 || true
        fi
        n=$((n+1))
        sleep '"$INTERVAL"'
      done   # soak-loop
    ' >/dev/null 2>&1 < /dev/null &
    sleep 3
    if ps -ef 2>/dev/null | grep -q "[s]oak-loop"; then
      echo "soak RUNNING (interval ${INTERVAL}s). csv=$CSV events=$EVT"
    else
      echo "ERROR: soak loop failed to stay alive"; jev soak_launch_failed; exit 1
    fi
    ;;
  guard)
    # called by the loop before every cycle; non-zero exit stops the soak
    if guards_ok; then exit 0; else do_abort "$ABORT_REASON"; exit 1; fi
    ;;
  cycle) one_cycle "${2:-0}" ;;
  stop)
    touch "$STOP"
    ps -ef 2>/dev/null | grep "[s]oak-loop" | awk '{print $2}' | xargs -r kill 2>/dev/null
    note "=== soak stopped by request ==="; jev soak_stop; echo "soak stopped"
    ;;
  status)
    echo "loop:    $(ps -ef 2>/dev/null | grep -q '[s]oak-loop' && echo RUNNING || echo stopped)"
    echo "stack:   $(stack_up && echo up || echo DOWN)"
    echo "cycles:  $(( $(wc -l < "$CSV" 2>/dev/null || echo 1) - 1 ))"
    echo "aborted: $(grep -c '"evt":"abort"' "$EVT" 2>/dev/null; true)"
    echo "mem:     $(memavail) kB avail"
    echo "--- last 8 cycles ---"; tail -8 "$CSV" 2>/dev/null
    ;;
  report) bash "$HERE/report.sh" ;;
  *) echo "usage: soak.sh {start|stop|status|report}"; exit 1;;
esac
