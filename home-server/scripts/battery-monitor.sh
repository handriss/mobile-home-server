#!/data/data/com.termux/files/usr/bin/bash
# battery-monitor.sh — home-server battery watchdog. No root; reads battery data via
# Termux:API (termux-battery-status), which uses Android's BatteryManager like a normal
# app — the raw /sys nodes are SELinux-blocked for apps. Pushes ntfy alerts on bad
# conditions, pings a healthchecks.io dead-man's switch, sends a daily digest.
# Boot-started by ~/.termux/boot/battery-monitor.sh.  Config: ~/batt-monitor/monitor.conf
# Test the digest any time:  bash battery-monitor.sh digest
set -u
DIR="$HOME/batt-monitor"
CONF="$DIR/monitor.conf"
LOG="$DIR/readings.csv"
STATE="$DIR/state"
mkdir -p "$DIR"
[ -f "$CONF" ] && . "$CONF"
: "${NAME:=home-server}"
: "${NTFY_URL:=https://ntfy.sh}"
: "${NTFY_TOPIC:=}"
: "${HEALTHCHECK_URL:=}"
: "${TEMP_WARN:=43}"       # °C  -> high-priority "warming" alert
: "${TEMP_URGENT:=48}"     # °C  -> urgent "hot" alert (breaks through DND)
: "${POLL_SECS:=300}"      # sample every 5 min
: "${DIGEST_HOUR:=9}"      # local hour (0-23) for the daily report
: "${PREFIX:=/data/data/com.termux/files/usr}"   # for the diagnostics web feed

notify(){ # priority tags title message
  [ -n "$NTFY_TOPIC" ] || return 0
  curl -fsS -m 10 -H "Priority: $1" -H "Tags: $2" -H "Title: $3" \
       -d "$4" "$NTFY_URL/$NTFY_TOPIC" >/dev/null 2>&1
}
gst(){ grep "^$1=" "$STATE" 2>/dev/null | cut -d= -f2-; }
sst(){ touch "$STATE"; grep -v "^$1=" "$STATE" 2>/dev/null > "$STATE.t"; echo "$1=$2" >> "$STATE.t"; mv "$STATE.t" "$STATE"; }

jnum(){ printf '%s' "$1" | grep -oE "\"$2\": *-?[0-9.]+" | grep -oE -- '-?[0-9.]+' | head -1; }
jstr(){ printf '%s' "$1" | grep -oE "\"$2\": *\"[^\"]*\"" | sed -E 's/.*"([^"]*)"$/\1/' | head -1; }

digest(){
  local now since; now=$(date +%s); since=$((now-86400))
  local body; body=$(awk -F, -v s="$since" '
    $1>=s {
      t=$2+0
      if(c==0){mx=mn=t; lx=ln=$3+0}
      if(t>mx)mx=t; if(t<mn)mn=t
      if($3+0>lx)lx=$3+0; if($3+0<ln)ln=$3+0
      sm+=t; c++
      if(t>=43)w++; if($3+0>=95)hi++
    }
    END{
      if(c==0){print "No samples in the last 24h."; exit}
      printf "Batt temp (24h): max %.1f C, avg %.1f C, min %.1f C\n", mx, sm/c, mn
      printf "Level: %d-%d%% (%.0f%% of time >=95%%)\n", ln, lx, hi*100.0/c
      printf "Warm samples >=43C: %d of %d", w+0, c
    }' "$LOG")
  local J; J=$(termux-battery-status 2>/dev/null)
  local ms upline; ms=$(gst mon_start)
  if [ -n "$ms" ]; then upline=$(awk -v a="$ms" -v b="$(date +%s)" 'BEGIN{printf "Monitor up %.1fh", (b-a)/3600}'); else upline="Monitor up ?"; fi
  notify default "bar_chart" "Daily report - $NAME" \
"$body
Now: $(jnum "$J" percentage)%, $(jnum "$J" temperature)C, health $(jstr "$J" health), $(jstr "$J" status)
$upline"
}

# write batt.json into the nginx docroot for the diagnostics page (diag.html).
# Uses the module-level temp/lvl/mv/ma/health/status set each poll; last 7 days of series.
write_web(){
  local doc="$PREFIX/share/nginx/html"; [ -d "$doc" ] || return 0
  local since=$(( $(date +%s) - 7*86400 )) ms upt
  ms=$(gst mon_start); upt=$(awk -v a="${ms:-0}" -v b="$(date +%s)" 'BEGIN{if(a>0)printf "%.1f",(b-a)/3600; else printf "0.0"}')
  { printf '{"generated":%s,"name":"%s","warn":%s,"urgent":%s,"now":{"temp":%s,"level":%s,"voltage":%s,"current":%s,"health":"%s","status":"%s","uptime_h":%s},"series":[' \
      "$(date +%s)" "$NAME" "$TEMP_WARN" "$TEMP_URGENT" "${temp:-null}" "${lvl:-0}" "${mv:-0}" "${ma:-0}" "${health:-?}" "${status:-?}" "$upt"
    awk -F, -v s="$since" 'BEGIN{f=1} $1>=s{if(!f)printf ","; printf "[%s,%s,%s]",$1,$2,$3; f=0}' "$LOG"
    printf ']}'
  } > "$doc/.batt.json.tmp" 2>/dev/null && mv "$doc/.batt.json.tmp" "$doc/batt.json" 2>/dev/null
}

# --- test hook: `battery-monitor.sh digest` sends a report immediately then exits ---
if [ "${1:-}" = "digest" ]; then digest; echo "digest sent"; exit 0; fi

# startup ping (doubles as the ntfy self-test)
sst mon_start "$(date +%s)"
notify low "battery" "Battery monitor started" "$NAME online; watching temp & health."

while true; do
  now=$(date +%s)
  J=$(termux-battery-status 2>/dev/null)
  temp=$(jnum "$J" temperature); lvl=$(jnum "$J" percentage)
  mv=$(jnum "$J" voltage); ma=$(jnum "$J" current)
  health=$(jstr "$J" health); status=$(jstr "$J" status)

  # if the API gave us nothing this cycle, skip (never alert on empty data)
  if [ -z "$temp" ] || [ -z "$health" ]; then sleep "$POLL_SECS"; continue; fi

  echo "$now,$temp,${lvl:-0},${mv:-0},${ma:-0},$health,${status:-?}" >> "$LOG"
  if [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 4000 ]; then tail -n 3000 "$LOG" > "$LOG.t"; mv "$LOG.t" "$LOG"; fi
  write_web

  tempint=${temp%.*}

  # --- temperature state machine (alert only on transitions) ---
  tl=0; [ "$tempint" -ge "$TEMP_WARN" ] && tl=1; [ "$tempint" -ge "$TEMP_URGENT" ] && tl=2
  pt=$(gst temp_lvl); pt=${pt:-0}
  if [ "$tl" -gt "$pt" ]; then
    if [ "$tl" -ge 2 ]; then notify urgent "fire" "Battery HOT - $NAME" "Battery ${temp}C (level ${lvl}%). Check it now."
    else notify high "warning" "Battery warming - $NAME" "Battery ${temp}C (level ${lvl}%)."; fi
  elif [ "$tl" -eq 0 ] && [ "$pt" -gt 0 ]; then
    notify default "white_check_mark" "Battery normal - $NAME" "Battery back to ${temp}C."
  fi
  sst temp_lvl "$tl"

  # --- health flag state machine (only genuinely-bad states alert; GOOD/UNKNOWN = ok) ---
  case "$health" in OVERHEAT|DEAD|OVER_VOLTAGE|COLD|UNSPECIFIED_FAILURE) hb=bad;; *) hb=ok;; esac
  ph=$(gst health_st); ph=${ph:-ok}
  if [ "$hb" = bad ] && [ "$ph" = ok ]; then notify urgent "warning" "Battery health: $health - $NAME" "health=${health} (temp ${temp}C, ${lvl}%). Inspect the pack."; fi
  if [ "$hb" = ok ] && [ "$ph" = bad ]; then notify default "white_check_mark" "Battery health normal - $NAME" "health=${health}."; fi
  sst health_st "$hb"

  # --- dead-man's switch heartbeat ---
  [ -n "$HEALTHCHECK_URL" ] && curl -fsS -m 10 "$HEALTHCHECK_URL" >/dev/null 2>&1

  # --- daily digest ---
  hour=$(date +%H); today=$(date +%Y-%m-%d)
  if [ "$((10#$hour))" -eq "$DIGEST_HOUR" ] && [ "$(gst digest_day)" != "$today" ]; then
    digest; sst digest_day "$today"
  fi

  sleep "$POLL_SECS"
done
