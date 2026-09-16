#!/data/data/com.termux/files/usr/bin/bash
#
# supervise.sh — keep the browser stack alive.
#
# There is no systemd here, and Android will kill background processes under
# memory pressure. @playwright/mcp also exits when its browser dies, so anything
# that takes Chromium down takes the MCP server with it.
#
# This loop re-runs start.sh (which is idempotent -- each component is only
# started if absent) and logs whatever it had to bring back. That log is the
# record of how often Android is actually killing things.
#
#   supervise.sh start|stop|status
#
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LAB="${LAB:-$HOME/job-search-pipeline-data}"
LOG="$LAB/supervisor.log"
INTERVAL="${SUPERVISE_INTERVAL:-15}"

mkdir -p "$LAB"
jlog(){ printf '{"ts":"%s","evt":"%s","detail":"%s"}\n' "$(date -Iseconds)" "$1" "${2:-}" >> "$LOG"; }

case "${1:-start}" in
  start)
    if pgrep -f 'job-search-pipeline-supervisor' >/dev/null 2>&1; then echo "supervisor already running"; exit 0; fi
    termux-wake-lock 2>/dev/null
    jlog supervisor_start "interval=${INTERVAL}s"
    setsid bash -c '
      while true; do
        # start.sh prints ">> <component>" only for things it actually started.
        out=$('"$HERE"'/start.sh start 2>/dev/null | grep "^>>" || true)
        if [ -n "$out" ]; then
          while IFS= read -r line; do
            printf "{\"ts\":\"%s\",\"evt\":\"restarted\",\"detail\":\"%s\"}\n" \
              "$(date -Iseconds)" "${line#>> }" >> "'"$LOG"'"
          done <<< "$out"
        fi
        sleep '"$INTERVAL"'
      done   # job-search-pipeline-supervisor
    ' >/dev/null 2>&1 < /dev/null &
    sleep 2
    echo "supervisor started (every ${INTERVAL}s), log: $LOG"
    ;;
  stop)
    pkill -f 'job-search-pipeline-supervisor' 2>/dev/null
    jlog supervisor_stop
    echo "supervisor stopped (stack left running; use start.sh stop to tear it down)"
    ;;
  status)
    echo "supervisor: $(pgrep -f 'job-search-pipeline-supervisor' >/dev/null && echo RUNNING || echo stopped)"
    echo "--- restarts recorded ---"
    grep -c '"evt":"restarted"' "$LOG" 2>/dev/null || echo 0
    echo "--- last 10 events ---"
    tail -10 "$LOG" 2>/dev/null
    ;;
  *) echo "usage: supervise.sh {start|stop|status}"; exit 1 ;;
esac
