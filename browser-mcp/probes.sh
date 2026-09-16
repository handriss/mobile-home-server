#!/data/data/com.termux/files/usr/bin/bash
# probes.sh — corner-case probes for the phone-browser MCP gateway.
#
# The soak answers "does it survive?". These answer "does it fail *well*?".
# Each probe drives a specific failure mode and asserts the gateway turns it into
# a named, actionable error instead of a hang, a wedge, or a raw Playwright string.
#
# Probes:
#   concurrency  N clients at once      -> all served, FIFO staircase, no raw in-use error
#   shed         MAX_QUEUE+ clients     -> excess gets queue_full with retry_after_s
#   badurl       unresolvable host      -> clean dns_failure, lock released
#   slowpage     server that never      -> nav timeout surfaces, lock released, browser reusable
#                replies
#   bigpage      huge DOM               -> records snapshot bytes/ms (context-window risk)
#   abandon      client takes lock then -> idle_reclaim hands browser to the waiter
#                vanishes without DELETE
#
#   probes.sh run [tag]     all probes
#   probes.sh <probe> [tag] one probe
#
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
LAB="${LAB:-$HOME/job-search-pipeline-data}"
OUT="$LAB/probes.jsonl"
PORT="${GW_PORT:-8930}"
BASE="http://127.0.0.1:$PORT/mcp"
MAX_QUEUE="${GW_MAX_QUEUE:-8}"
STALL_PORT="${STALL_PORT:-8939}"
TAG="${2:-manual}"

mkdir -p "$LAB"
ts() { date +%Y-%m-%dT%H:%M:%S%z; }
res() { # res <probe> <pass|fail|info> <detail...>
  local probe="$1" verdict="$2"; shift 2
  local out="{\"ts\":\"$(ts)\",\"tag\":\"$TAG\",\"probe\":\"$probe\",\"verdict\":\"$verdict\""
  local kv k v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    v="${v//\\/\\\\}"; v="${v//\"/\\\"}"; v="${v//$'\n'/ }"
    out="$out,\"$k\":\"$v\""
  done
  echo "$out}" >> "$OUT"
  printf '%-12s %-5s %s\n' "$probe" "$verdict" "$*"
}

H1='Content-Type: application/json'
H2='Accept: application/json, text/event-stream'

open_sid() {
  curl -s -m 30 -D - -o /dev/null -X POST "$BASE" -H "$H1" -H "$H2" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"probe","version":"1"}}}' \
    2>/dev/null | grep -i '^mcp-session-id' | tr -d '\r' | awk '{print $2}'
}
inited() { curl -s -m 15 -X POST "$BASE" -H "mcp-session-id: $1" -H "$H1" -H "$H2" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null 2>&1; }
nav() { # nav <sid> <timeout> <url>
  curl -s -m "$2" -X POST "$BASE" -H "mcp-session-id: $1" -H "$H1" -H "$H2" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"browser_navigate\",\"arguments\":{\"url\":\"$3\"}}}" 2>/dev/null; }
snap() { curl -s -m "$2" -X POST "$BASE" -H "mcp-session-id: $1" -H "$H1" -H "$H2" \
    -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"browser_snapshot","arguments":{}}}' 2>/dev/null; }
close_sid() { curl -s -m 15 -X DELETE "$BASE" -H "mcp-session-id: $1" >/dev/null 2>&1; }
gw_depth() { timeout 8 curl -s "http://127.0.0.1:$PORT/status" 2>/dev/null \
  | python -c "import sys,json;print(json.load(sys.stdin)['queue']['depth'])" 2>/dev/null || echo "?"; }
browser_usable() { # can we still drive the browser after the probe?
  local s r; s="$(open_sid)"; [ -z "$s" ] && { echo no; return; }
  inited "$s"; r="$(nav "$s" 90 'https://example.com/')"; close_sid "$s"
  case "$r" in *'"isError":true'*|"") echo no;; *) echo yes;; esac; }

# ---------------------------------------------------------------- stall server
# A listener that accepts the connection and never answers, so Chromium's
# navigation hangs the way a wedged real-world site does.
start_stall() {
  python - "$STALL_PORT" <<'PY' >/dev/null 2>&1 &
import socket, sys, time
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(16)
conns = []
end = time.time() + 600
while time.time() < end:
    s.settimeout(5)
    try:
        c, _ = s.accept(); conns.append(c)   # accept, never reply
    except Exception:
        pass
PY
  echo $!
}

# ---------------------------------------------------------------------- probes

probe_concurrency() {
  local n="${CONC_N:-4}" i d tmp
  tmp="$(mktemp -d "$LAB/conc.XXXXXX")"
  for i in $(seq 1 "$n"); do
    (
      t0=$(date +%s%3N)
      sid="$(open_sid)"; [ -z "$sid" ] && { echo "noinit" > "$tmp/$i"; exit; }
      inited "$sid"
      r="$(nav "$sid" 180 'https://example.com/')"
      t1=$(date +%s%3N)
      cls=ok
      case "$r" in
        "")                   cls=empty;;
        *'already in use'*)   cls=RAW_IN_USE;;
        *'"isError":true'*)   cls=error;;
      esac
      echo "$cls $(( t1 - t0 ))" > "$tmp/$i"
      close_sid "$sid"
    ) &
  done
  wait
  local okc=0 raw=0 times=""
  for i in $(seq 1 "$n"); do
    read -r cls ms < "$tmp/$i" 2>/dev/null || { cls=missing; ms=0; }
    [ "$cls" = ok ] && okc=$((okc+1))
    [ "$cls" = RAW_IN_USE ] && raw=$((raw+1))
    times="${times:+$times|}${ms}"
  done
  rm -rf "$tmp"
  if [ "$okc" -eq "$n" ] && [ "$raw" -eq 0 ]; then
    res concurrency pass "clients=$n" "succeeded=$okc" "raw_in_use=$raw" "ms=$times"
  else
    res concurrency fail "clients=$n" "succeeded=$okc" "raw_in_use=$raw" "ms=$times"
  fi
}

probe_shed() {
  # Fire MAX_QUEUE+3 at once; the overflow must be shed with a descriptive error,
  # not parked forever and not crashed.
  local n=$(( MAX_QUEUE + 3 )) i tmp
  tmp="$(mktemp -d "$LAB/shed.XXXXXX")"
  for i in $(seq 1 "$n"); do
    ( sid="$(open_sid)"; [ -z "$sid" ] && { echo noinit > "$tmp/$i"; exit; }
      inited "$sid"
      r="$(nav "$sid" 120 'https://example.com/')"
      case "$r" in
        *queue_full*)        echo shed  > "$tmp/$i";;
        *retry_after*)       echo shed  > "$tmp/$i";;
        *'already in use'*)  echo RAW_IN_USE > "$tmp/$i";;
        *'"isError":true'*)  echo error > "$tmp/$i";;
        "")                  echo empty > "$tmp/$i";;
        *)                   echo ok    > "$tmp/$i";;
      esac
      close_sid "$sid" ) &
  done
  wait
  local shed=0 ok=0 raw=0 other=0 v
  for i in $(seq 1 "$n"); do
    v="$(cat "$tmp/$i" 2>/dev/null || echo missing)"
    case "$v" in shed) shed=$((shed+1));; ok) ok=$((ok+1));; RAW_IN_USE) raw=$((raw+1));; *) other=$((other+1));; esac
  done
  rm -rf "$tmp"
  # Healthy: everyone either served or cleanly shed; never a raw Playwright string.
  if [ "$raw" -eq 0 ] && [ $(( shed + ok )) -ge $(( n - 1 )) ]; then
    res shed pass "fired=$n" "served=$ok" "shed=$shed" "other=$other"
  else
    res shed fail "fired=$n" "served=$ok" "shed=$shed" "other=$other" "raw_in_use=$raw"
  fi
}

probe_badurl() {
  local sid r cls
  sid="$(open_sid)"; [ -z "$sid" ] && { res badurl fail "reason=no_session"; return; }
  inited "$sid"
  local t0; t0=$(date +%s%3N)
  r="$(nav "$sid" 90 'https://this-host-does-not-exist-9f2b1c.invalid/')"
  local ms=$(( $(date +%s%3N) - t0 ))
  close_sid "$sid"
  case "$r" in
    "")                  cls=hang_or_timeout;;
    *net::ERR_NAME*)     cls=dns_failure;;
    *net::ERR_*)         cls=network_error;;
    *'"isError":true'*)  cls=tool_error;;
    *)                   cls=unexpected_success;;
  esac
  local usable; usable="$(browser_usable)"
  if { [ "$cls" = dns_failure ] || [ "$cls" = network_error ] || [ "$cls" = tool_error ]; } \
     && [ "$usable" = yes ]; then
    res badurl pass "class=$cls" "ms=$ms" "browser_usable_after=$usable"
  else
    res badurl fail "class=$cls" "ms=$ms" "browser_usable_after=$usable"
  fi
}

probe_slowpage() {
  local pid sid r ms t0 cls
  pid="$(start_stall)"; sleep 1
  sid="$(open_sid)"; [ -z "$sid" ] && { kill "$pid" 2>/dev/null; res slowpage fail "reason=no_session"; return; }
  inited "$sid"
  t0=$(date +%s%3N)
  r="$(nav "$sid" 90 "http://127.0.0.1:$STALL_PORT/")"
  ms=$(( $(date +%s%3N) - t0 ))
  close_sid "$sid"
  kill "$pid" 2>/dev/null
  case "$r" in
    "")                 cls=client_timeout_no_reply;;
    *imeout*)           cls=nav_timeout;;
    *'"isError":true'*) cls=tool_error;;
    *)                  cls=returned_ok;;
  esac
  local usable; usable="$(browser_usable)"
  local depth; depth="$(gw_depth)"
  # The point is not that it fails -- it is that the lock came back.
  if [ "$usable" = yes ] && [ "$depth" = 0 ]; then
    res slowpage pass "class=$cls" "ms=$ms" "queue_depth_after=$depth" "browser_usable_after=$usable"
  else
    res slowpage fail "class=$cls" "ms=$ms" "queue_depth_after=$depth" "browser_usable_after=$usable"
  fi
}

probe_bigpage() {
  local sid r ms t0 bytes
  sid="$(open_sid)"; [ -z "$sid" ] && { res bigpage fail "reason=no_session"; return; }
  inited "$sid"
  nav "$sid" 180 'https://en.wikipedia.org/wiki/Android_(operating_system)' >/dev/null
  t0=$(date +%s%3N)
  r="$(snap "$sid" 180)"
  ms=$(( $(date +%s%3N) - t0 ))
  bytes=${#r}
  close_sid "$sid"
  # Informational: this is a context-window cost, not a correctness failure.
  res bigpage info "snapshot_bytes=$bytes" "ms=$ms" "approx_tokens=$(( bytes / 4 ))"
}

probe_abandon() {
  # A client takes the browser and dies without DELETE. A second client must still
  # get the browser once GW_IDLE_RELEASE_MS elapses, rather than waiting forever.
  local dead live r t0 waited
  dead="$(open_sid)"; [ -z "$dead" ] && { res abandon fail "reason=no_session"; return; }
  inited "$dead"
  nav "$dead" 120 'https://example.com/' >/dev/null      # takes the lock
  # ...and now we simply never touch or close $dead.

  live="$(open_sid)"; [ -z "$live" ] && { res abandon fail "reason=no_second_session"; return; }
  inited "$live"
  t0=$(date +%s%3N)
  r="$(nav "$live" 240 'https://example.com/')"           # must wait, then be granted
  waited=$(( $(date +%s%3N) - t0 ))
  close_sid "$live"; close_sid "$dead"
  case "$r" in
    *'"isError":true'*|"") res abandon fail "waited_ms=$waited" "detail=waiter_never_served";;
    *)                     res abandon pass "waited_ms=$waited" "detail=reclaimed_from_idle_holder";;
  esac
}

case "${1:-run}" in
  run)
    echo "--- probes ($TAG) ---"
    probe_concurrency; probe_badurl; probe_slowpage; probe_bigpage; probe_shed; probe_abandon
    echo "--- results appended to $OUT ---"
    ;;
  concurrency|shed|badurl|slowpage|bigpage|abandon) "probe_$1" ;;
  *) echo "usage: probes.sh {run|concurrency|shed|badurl|slowpage|bigpage|abandon} [tag]"; exit 1;;
esac
