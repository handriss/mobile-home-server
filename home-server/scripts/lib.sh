#!/usr/bin/env bash
# lib.sh — shared helpers for driving Termux on the phone from the Mac over ADB.
# Sourced by termux-run.sh and deploy.sh.
#
# Why typing + a served script (and not the RUN_COMMAND intent)? Passing an
# arbitrary command through `adb shell am ...` means it is re-parsed by the phone's
# shell, so any >, |, && etc. break. Instead we put the real command in a script,
# serve it from the Mac, and TYPE only operator-free lines (`curl -o` + `bash`).
# This is the same approach provision.sh uses, and it is robust.

log(){ printf '\033[1;36m>>\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

resolve_serial(){
  command -v adb >/dev/null || die "adb not found (brew install android-platform-tools)"
  adb start-server >/dev/null 2>&1 || true
  if [ -n "${ANDROID_SERIAL:-}" ]; then return; fi
  local devs; devs=$(adb devices | awk 'NR>1 && $2=="device"{print $1}')
  [ -z "$devs" ] && die "no authorized ADB device (plug in the phone, tap 'Allow USB debugging')"
  [ "$(echo "$devs" | wc -l)" -gt 1 ] && die "multiple devices; set ANDROID_SERIAL=<serial>"
  export ANDROID_SERIAL="$devs"
}

mac_ip(){
  local ifc ip
  ifc=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
  [ -n "${ifc:-}" ] && ip=$(ipconfig getifaddr "$ifc" 2>/dev/null || true)
  [ -z "${ip:-}" ] && ip=$(ipconfig getifaddr en0 2>/dev/null || true)
  echo "$ip"
}

wake(){ adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true; }

focus_termux(){
  wake
  adb shell monkey -p com.termux -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  sleep 3
  adb shell input tap 540 800   # raise soft-keyboard -> terminal gets input focus
  sleep 1
  adb shell input keyevent 66   # fresh prompt
}

# type a single command (must be OPERATOR-FREE) into the focused terminal + Enter.
# 'adb shell input text' drops spaces, so type word-by-word, inject SPACE (62) / ENTER (66).
adb_type(){
  local first=1 w
  for w in $1; do
    [ $first -eq 0 ] && adb shell input keyevent 62
    adb shell input text "$w"
    first=0
  done
  adb shell input keyevent 66
}

# Serve $1 (a directory) over HTTP; echoes "IP PORT PID".
# NB: background python DIRECTLY (via --directory) so $! is python's real PID.
# Wrapping it in a subshell ( ... ) & captures the subshell PID instead, leaving
# python orphaned and holding the port on cleanup.
start_file_server(){
  local dir="$1" port="${2:-8012}" ip; ip="$(mac_ip)"
  [ -n "$ip" ] || die "could not detect Mac LAN IP"
  python3 -m http.server "$port" --bind 0.0.0.0 --directory "$dir" >/dev/null 2>&1 &
  local pid=$!
  sleep 2
  curl -fsS "http://$ip:$port/" >/dev/null 2>&1 || { kill "$pid" 2>/dev/null; die "file server unreachable at $ip:$port"; }
  echo "$ip $port $pid"
}

# fetch a served script into Termux home and run it: termux_fetch_run <url> <remote_name> [args]
termux_fetch_run(){
  local url="$1" name="$2" args="${3:-}"
  focus_termux
  adb_type "curl $url -o $name"; sleep 3
  adb_type "bash $name $args";   sleep 4
}
