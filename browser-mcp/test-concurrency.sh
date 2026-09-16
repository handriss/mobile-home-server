#!/data/data/com.termux/files/usr/bin/bash
#
# test-concurrency.sh — fire N MCP sessions at the gateway simultaneously and show
# that they serialize instead of failing with "Browser is already in use".
#
# Without the gateway, exactly one of these succeeds and the rest error instantly.
# With it, all of them succeed and the later ones simply take longer.
#
#   test-concurrency.sh [N] [port]
#
set -u
N="${1:-3}"
PORT="${2:-8930}"
B="http://localhost:$PORT/mcp"
H1='Content-Type: application/json'
H2='Accept: application/json, text/event-stream'
OUT="$HOME/job-search-pipeline-data/conc"
rm -rf "$OUT"; mkdir -p "$OUT"

worker() {
  local i="$1" t0 sid nav elapsed verdict
  t0=$(date +%s%3N)
  sid=$(curl -s -m 30 -D - -o /dev/null -X POST "$B" -H "$H1" -H "$H2" \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"conc'"$i"'","version":"1"}}}' \
    | grep -i '^mcp-session-id' | tr -d '\r' | awk '{print $2}')
  [ -z "$sid" ] && { echo "$i,NO_SESSION,0,"  >> "$OUT/results.csv"; return; }
  curl -s -m 20 -X POST "$B" -H "mcp-session-id: $sid" -H "$H1" -H "$H2" \
    -d '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null

  nav=$(curl -s -m 400 -X POST "$B" -H "mcp-session-id: $sid" -H "$H1" -H "$H2" \
    -d '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"browser_navigate","arguments":{"url":"https://example.com/"}}}')
  elapsed=$(( $(date +%s%3N) - t0 ))

  if   echo "$nav" | grep -q 'already in use';    then verdict=IN_USE_ERROR
  elif echo "$nav" | grep -q '"isError":true';    then verdict=TOOL_ERROR
  elif echo "$nav" | grep -q 'Page URL';          then verdict=OK
  else                                                 verdict=UNKNOWN
  fi
  echo "$i,$verdict,$elapsed,$(echo "$nav" | head -c 120 | tr -d '\n,')" >> "$OUT/results.csv"

  # release the browser for the next waiter
  curl -s -m 20 -X DELETE "$B" -H "mcp-session-id: $sid" >/dev/null
}

echo "firing $N concurrent sessions at $B"
echo "client,verdict,elapsed_ms,excerpt" > "$OUT/results.csv"
for i in $(seq 1 "$N"); do worker "$i" & done
wait

echo
sort -t, -k1 -n "$OUT/results.csv" | column -s, -t
echo
echo "--- gateway view ---"
curl -s -m 5 "http://127.0.0.1:$PORT/status"
echo
ok=$(grep -c ',OK,' "$OUT/results.csv")
echo "RESULT: $ok/$N succeeded, $(grep -c 'IN_USE_ERROR' "$OUT/results.csv") hit the raw in-use error"
