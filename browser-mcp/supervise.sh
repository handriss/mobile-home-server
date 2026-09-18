#!/data/data/com.termux/files/usr/bin/bash
#
# supervise.sh — keep the browser stack (and your way back in) alive.
#
# There is no systemd here, and Android will kill background processes. @playwright/mcp
# also exits when its browser dies, so anything that takes Chromium down takes the MCP
# server with it.
#
# Three things this does beyond re-running start.sh:
#
#   1. Watches sshd. On 2026-09-16 sshd died mid-run and locked us out of the device
#      entirely. The Forgejo watchdog did recover it, but only on its ~15 min cadence.
#      At 15s here, the lockout window shrinks from a quarter hour to seconds.
#   2. Exponential backoff. Restarting a component that is failing for a persistent
#      reason, every 15s forever, just burns battery and fills the log.
#   3. Crash-loop detection. Past CRASH_LOOP_N restarts inside CRASH_LOOP_WINDOW, it
#      stops trying, says so loudly on ntfy, and leaves the wreckage for diagnosis
#      rather than papering over it.
#
#   supervise.sh start|stop|status
#
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LAB="${LAB:-$HOME/job-search-pipeline-data}"
LOG="$LAB/supervisor.log"
INTERVAL="${SUPERVISE_INTERVAL:-15}"
BACKOFF_MAX="${SUPERVISE_BACKOFF_MAX:-300}"      # cap a single component's backoff
CRASH_LOOP_N="${SUPERVISE_CRASH_LOOP_N:-6}"      # restarts...
CRASH_LOOP_WINDOW="${SUPERVISE_CRASH_LOOP_WINDOW:-600}"  # ...within this many seconds
WATCH_SSHD="${SUPERVISE_WATCH_SSHD:-1}"
# Other single-points-of-failure on this device that nothing else restarts.
# cloudflared: if it dies, EVERY tunnelled service (Forgejo, yt-mcp, forgejo-mcp, this
#   gateway) goes dark at once, while all of them look perfectly healthy on localhost.
# forgejo-mcp: wedged once and stayed down ~5.5h because nothing watched it.
WATCH_CLOUDFLARED="${SUPERVISE_WATCH_CLOUDFLARED:-1}"
WATCH_FORGEJO_MCP="${SUPERVISE_WATCH_FORGEJO_MCP:-1}"
FORGEJO_MCP_PORT="${FORGEJO_MCP_PORT:-8766}"
SSHD_PORT="${SSHD_PORT:-8022}"

NTFY_URL="${NTFY_URL:-https://ntfy.sh}"
NTFY_TOPIC="${NTFY_TOPIC:-$(grep -m1 '^NTFY_TOPIC=' "$HOME/batt-monitor/monitor.conf" 2>/dev/null | cut -d= -f2)}"

mkdir -p "$LAB"

case "${1:-start}" in
  start)
    if ps -ef 2>/dev/null | grep -q '[p]ipeline-supervisor'; then echo "supervisor already running"; exit 0; fi
    termux-wake-lock 2>/dev/null
    printf '{"ts":"%s","evt":"supervisor_start","detail":"interval=%ss backoff_max=%ss crash_loop=%s/%ss sshd=%s"}\n' \
      "$(date -Iseconds)" "$INTERVAL" "$BACKOFF_MAX" "$CRASH_LOOP_N" "$CRASH_LOOP_WINDOW" "$WATCH_SSHD" >> "$LOG"

    HERE="$HERE" LAB="$LAB" LOG="$LOG" INTERVAL="$INTERVAL" BACKOFF_MAX="$BACKOFF_MAX" \
    CRASH_LOOP_N="$CRASH_LOOP_N" CRASH_LOOP_WINDOW="$CRASH_LOOP_WINDOW" \
    WATCH_SSHD="$WATCH_SSHD" SSHD_PORT="$SSHD_PORT" \
    WATCH_CLOUDFLARED="$WATCH_CLOUDFLARED" WATCH_FORGEJO_MCP="$WATCH_FORGEJO_MCP" \
    FORGEJO_MCP_PORT="$FORGEJO_MCP_PORT" \
    NTFY_URL="$NTFY_URL" NTFY_TOPIC="$NTFY_TOPIC" \
    setsid bash -c '
      jlog(){ printf "{\"ts\":\"%s\",\"evt\":\"%s\",\"detail\":\"%s\"}\n" "$(date -Iseconds)" "$1" "${2:-}" >> "$LOG"; }
      ntfy(){ [ -n "${NTFY_TOPIC:-}" ] || return 0
              curl -s -m 15 -H "Title: $2" -H "Priority: $1" -d "$3" "$NTFY_URL/$NTFY_TOPIC" >/dev/null 2>&1 || true; }

      # component -> next allowed attempt time, current backoff, restart timestamps
      declare -A next_at backoff hist
      halted=""

      note_restart(){ # note_restart <component>
        local c="$1" now; now=$(date +%s)
        case " $halted " in *" $c "*) return;; esac   # already given up; never re-alert
        hist[$c]="${hist[$c]:-} $now"
        # prune outside the window
        local kept="" t
        for t in ${hist[$c]}; do
          [ $(( now - t )) -le "$CRASH_LOOP_WINDOW" ] && kept="$kept $t"
        done
        hist[$c]="$kept"
        local n; n=$(echo $kept | wc -w | tr -d " ")
        if [ "$n" -ge "$CRASH_LOOP_N" ]; then
          halted="$halted $c"
          jlog crash_loop "$c restarted ${n}x in ${CRASH_LOOP_WINDOW}s -- giving up, not restarting again"
          ntfy urgent "Browser stack crash-loop" "$c restarted ${n}x in ${CRASH_LOOP_WINDOW}s. Supervisor has stopped restarting it. Check $LOG"
          return
        fi
        # exponential backoff: 0, INTERVAL, 2x, 4x ... capped
        local b="${backoff[$c]:-0}"
        if [ "$b" -eq 0 ]; then b="$INTERVAL"; else b=$(( b * 2 )); fi
        [ "$b" -gt "$BACKOFF_MAX" ] && b="$BACKOFF_MAX"
        backoff[$c]="$b"
        next_at[$c]=$(( now + b ))
        jlog restarted "$c (next attempt no sooner than ${b}s)"
      }

      healthy(){ # a component that has been up a full interval earns its backoff back
        local c="$1"
        [ "${backoff[$c]:-0}" -ne 0 ] && jlog recovered "$c"
        backoff[$c]=0; next_at[$c]=0
      }

      ready(){ # ready <component> -> 0 if we may try restarting it now
        local c="$1" now; now=$(date +%s)
        case " $halted " in *" $c "*) return 1;; esac
        [ "$now" -ge "${next_at[$c]:-0}" ]
      }

      # Is cloudflared actually running? This CANNOT be a grep over full command lines:
      # this supervisor process has "cloudflared tunnel run" inside its own argv (the
      # restart command below), so any such grep matches itself and reports a healthy
      # tunnel forever. Match on the executable name only, by reading argv[0] per process.
      cloudflared_up(){
        local p exe
        for p in /proc/[0-9]*; do
          [ -r "$p/cmdline" ] || continue
          exe=$(tr "\0" "\n" < "$p/cmdline" 2>/dev/null | head -1)
          case "${exe##*/}" in cloudflared) return 0;; esac
        done
        return 1
      }

      while true; do
        # ---- sshd: the way back into the device. Checked first, always.
        if [ "$WATCH_SSHD" = "1" ]; then
          if pgrep -x sshd >/dev/null 2>&1; then
            healthy sshd
          elif ready sshd; then
            sshd >/dev/null 2>&1
            sleep 1
            if pgrep -x sshd >/dev/null 2>&1; then
              note_restart sshd
              ntfy high "sshd was down" "Restarted sshd on :$SSHD_PORT. Remote access is back."
            else
              note_restart sshd
              jlog sshd_restart_failed ""
            fi
          fi
        fi

        # ---- cloudflared: one process, four public services depend on it
        if [ "$WATCH_CLOUDFLARED" = "1" ]; then
          if cloudflared_up; then
            healthy cloudflared
          elif ready cloudflared; then
            cd "$HOME" && nohup setsid cloudflared tunnel run >> "$HOME/cloudflared-run.log" 2>&1 < /dev/null &
            sleep 6
            if cloudflared_up; then
              note_restart cloudflared
              ntfy high "cloudflared was down" "Restarted it. All tunnelled services were unreachable until now."
            else
              note_restart cloudflared; jlog cloudflared_restart_failed ""
            fi
          fi
        fi

        # ---- forgejo-mcp: liveness by PORT, not by process. It wedged once while the
        # process was still alive, and its argv ("python -u server.py") is indistinguishable
        # from that of yt-mcp, so a pgrep check would be both wrong and ambiguous.
        if [ "$WATCH_FORGEJO_MCP" = "1" ] && [ -x "$HOME/forgejo-mcp/run.sh" ]; then
          code=$(curl -s -o /dev/null -m 8 -w "%{http_code}" "http://127.0.0.1:$FORGEJO_MCP_PORT/mcp" 2>/dev/null)
          if [ "${code:-000}" != "000" ]; then
            healthy forgejo_mcp
          elif ready forgejo_mcp; then
            (cd "$HOME/forgejo-mcp" && sh run.sh >> "$HOME/forgejo-mcp/boot.log" 2>&1)
            sleep 4
            code=$(curl -s -o /dev/null -m 8 -w "%{http_code}" "http://127.0.0.1:$FORGEJO_MCP_PORT/mcp" 2>/dev/null)
            note_restart forgejo_mcp
            [ "${code:-000}" != "000" ] && ntfy high "forgejo-mcp was down" "Restarted it; board access is back." \
              || jlog forgejo_mcp_restart_failed ""
          fi
        fi

        # ---- browser stack: start.sh is idempotent and prints ">> <component>"
        # only for things it actually had to start.
        if ready stack; then
          out=$("$HERE"/start.sh start 2>/dev/null | grep "^>>" || true)
          if [ -n "$out" ]; then
            while IFS= read -r line; do
              jlog restarted_component "${line#>> }"
            done <<< "$out"
            note_restart stack
          else
            healthy stack
          fi
        fi

        sleep "$INTERVAL"
      done   # job-search-pipeline-supervisor
    ' >/dev/null 2>&1 < /dev/null &
    sleep 2
    if ps -ef 2>/dev/null | grep -q '[p]ipeline-supervisor'; then
      echo "supervisor RUNNING (every ${INTERVAL}s, sshd watch=${WATCH_SSHD}), log: $LOG"
    else
      echo "ERROR: supervisor failed to stay alive"; exit 1
    fi
    ;;
  stop)
    ps -ef 2>/dev/null | grep '[p]ipeline-supervisor' | awk '{print $2}' | xargs -r kill 2>/dev/null
    printf '{"ts":"%s","evt":"supervisor_stop","detail":""}\n' "$(date -Iseconds)" >> "$LOG"
    echo "supervisor stopped (stack left running; use start.sh stop to tear it down)"
    ;;
  status)
    echo "supervisor: $(ps -ef 2>/dev/null | grep -q '[p]ipeline-supervisor' && echo RUNNING || echo stopped)"
    echo "sshd:       $(pgrep -x sshd >/dev/null 2>&1 && echo up || echo DOWN)"
    echo "cloudflared:$(for p in /proc/[0-9]*; do [ -r "$p/cmdline" ] || continue; e=$(tr "\0" "\n" < "$p/cmdline" 2>/dev/null | head -1); case "${e##*/}" in cloudflared) echo " up"; break;; esac; done | head -1 | grep -q up && echo " up" || echo " DOWN")"
    echo "forgejo-mcp:$(curl -s -o /dev/null -m 5 -w "%{http_code}" "http://127.0.0.1:${FORGEJO_MCP_PORT}/mcp" 2>/dev/null | grep -qv "^000$" && echo " up" || echo " DOWN")"
    echo "restarts:   $(grep -c '"evt":"restarted"' "$LOG" 2>/dev/null; true)"
    echo "crash-loops:$(grep -c '"evt":"crash_loop"' "$LOG" 2>/dev/null; true)"
    echo "--- last 12 events ---"
    tail -12 "$LOG" 2>/dev/null
    ;;
  *) echo "usage: supervise.sh {start|stop|status}"; exit 1 ;;
esac
