#!/usr/bin/env bash
#
# termux-run.sh — run a shell command INSIDE Termux, from the Mac, over ADB.
#
# Puts your command in a script, serves it from the Mac, and types only the
# operator-free `curl -o` + `bash` on the phone (so >, |, && etc. all work,
# because they run inside Termux, never through the adb-shell parser).
#
# The command DOES appear typed in the Termux terminal on the phone screen; that's
# expected. Output stays on the phone — verify effects separately (e.g. curl the site).
#
# Usage:
#   scripts/termux-run.sh 'apt update && apt full-upgrade -y'
#   scripts/termux-run.sh 'nginx -s reload'
#   ANDROID_SERIAL=<serial> scripts/termux-run.sh '<cmd>'
#
set -euo pipefail
CMD="${1:?usage: termux-run.sh '<shell command>'}"
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
resolve_serial

TMP="$(mktemp -d)"; SRV_PID=""
cleanup(){ [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

cat > "$TMP/_run.sh" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
$CMD
EOF

read -r IP PORT SRV_PID < <(start_file_server "$TMP" 8012)
log "running in Termux: $CMD"
termux_fetch_run "http://$IP:$PORT/_run.sh" "_run.sh"
log "done (dispatched; check effects on the phone / via curl)"
