#!/usr/bin/env bash
#
# provision.sh — turn a spare Android phone into a Termux + nginx home web server,
#                driven entirely from a Mac over ADB. Minimal human intervention.
#
# WHAT YOU MUST DO BY HAND FIRST (Android security gates these; ADB cannot):
#   1. Phone: Settings > About phone > tap "Build number" 7x  (enables Developer options)
#   2. Phone: Settings > (System >) Developer options > turn ON "USB debugging"
#      (recommended too: turn ON "Stay awake" so the screen stays on while charging)
#   3. Phone: connect to the SAME Wi-Fi as this Mac
#   4. Plug the phone into the Mac with a DATA cable, then tap "Allow USB debugging"
#      (tick "Always allow from this computer")
#
# Then just run:   ./provision.sh
#
# Options:
#   ./provision.sh --serial <adb-serial>   pick a device if several are attached
#   ./provision.sh --port 8080             nginx listen port (default 8080; must be >=1024)
#   ./provision.sh --help
#
# Idempotent-ish: re-running reinstalls the APKs (-r) and re-runs setup; safe.
#
# Tested on: OPPO Reno5 Z (CPH2211), Android 13 / ColorOS. Other phones may need
# tweaks (icon-focus tap coords, timing). See README.md.
#
set -euo pipefail

# ---- config / args --------------------------------------------------------
NGINX_PORT=8080
HTTP_PORT=8000
SERIAL=""
TERMUX_URL="https://github.com/termux/termux-app/releases/download/v0.118.3/termux-app_v0.118.3%2Bgithub-debug_arm64-v8a.apk"
BOOT_URL="https://github.com/termux/termux-boot/releases/download/v0.8.1/termux-boot-app_v0.8.1%2Bgithub.debug.apk"

HERE="$(cd "$(dirname "$0")" && pwd)"
CACHE="$HERE/cache"

while [ $# -gt 0 ]; do
  case "$1" in
    --serial) SERIAL="$2"; shift 2;;
    --port)   NGINX_PORT="$2"; shift 2;;
    --help|-h) sed -n '2,30p' "$0"; exit 0;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done

log(){ printf '\033[1;36m>>\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---- preflight ------------------------------------------------------------
command -v adb >/dev/null || die "adb not found. Install with: brew install android-platform-tools"
command -v python3 >/dev/null || die "python3 not found (needed for the temporary file server)."

adb start-server >/dev/null 2>&1 || true

# pick device
if [ -z "$SERIAL" ]; then
  mapfile -t devs < <(adb devices | awk 'NR>1 && $2=="device"{print $1}')
  [ "${#devs[@]}" -eq 0 ] && die "no authorized ADB device. Do the manual steps at the top, then tap 'Allow USB debugging' on the phone."
  [ "${#devs[@]}" -gt 1 ] && die "multiple devices attached; choose one with --serial (${devs[*]})"
  SERIAL="${devs[0]}"
fi
export ANDROID_SERIAL="$SERIAL"
log "using device: $SERIAL ($(adb shell getprop ro.product.model | tr -d '\r'), Android $(adb shell getprop ro.build.version.release | tr -d '\r'))"

ABI=$(adb shell getprop ro.product.cpu.abi | tr -d '\r')
[ "$ABI" = "arm64-v8a" ] || log "warning: device ABI is '$ABI', APK URLs are arm64-v8a. Edit TERMUX_URL/BOOT_URL if this fails."

# detect Mac LAN IP (so the phone can fetch files from us)
mac_ip(){
  local ifc ip
  ifc=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
  [ -n "${ifc:-}" ] && ip=$(ipconfig getifaddr "$ifc" 2>/dev/null || true)
  [ -z "${ip:-}" ] && ip=$(ipconfig getifaddr en0 2>/dev/null || true)
  echo "$ip"
}
MAC_IP="$(mac_ip)"; [ -n "$MAC_IP" ] || die "could not detect this Mac's LAN IP."
log "this Mac is $MAC_IP; phone will fetch setup files from http://$MAC_IP:$HTTP_PORT"

# ---- helper: type a command into the focused Termux terminal ---------------
# (adb 'input text' drops spaces, so type word-by-word and inject spaces/enter as key events)
adb_type(){
  local first=1 w
  for w in $1; do
    [ $first -eq 0 ] && adb shell input keyevent 62   # SPACE
    adb shell input text "$w"
    first=0
  done
  adb shell input keyevent 66                          # ENTER
}
wake(){ adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true; }
focus_termux(){
  adb shell monkey -p com.termux -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  sleep 3
  adb shell input tap 540 800   # tap the terminal to raise the soft-keyboard (gives it input focus)
  sleep 1
}

# ---- 1. download + install APKs -------------------------------------------
mkdir -p "$CACHE"
fetch(){ # url dest
  [ -s "$2" ] && { log "cached: $(basename "$2")"; return; }
  log "downloading $(basename "$2")"
  curl -fsSL "$1" -o "$2"
}
fetch "$TERMUX_URL" "$CACHE/termux.apk"
fetch "$BOOT_URL"   "$CACHE/termux-boot.apk"

log "installing Termux + Termux:Boot"
adb install -r -g "$CACHE/termux.apk"      | tail -1
adb install -r -g "$CACHE/termux-boot.apk" | tail -1

# ---- 2. first launch -> bootstrap the Linux userspace ----------------------
log "launching Termux to bootstrap (first run downloads the base system, ~60s)"
wake
adb shell monkey -p com.termux -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 60

# ---- 3. serve setup files to the phone -------------------------------------
log "starting temporary file server on the Mac"
SRV_DIR="$(mktemp -d)"
cp "$HERE/scripts/termux-setup.sh" "$SRV_DIR/termux-setup.sh"
cp "$HERE/www/index.html"          "$SRV_DIR/index.html"
# background python DIRECTLY (via --directory) so $! is its real PID — a subshell
# wrapper would leave python orphaned and holding the port on cleanup.
python3 -m http.server "$HTTP_PORT" --bind 0.0.0.0 --directory "$SRV_DIR" >/dev/null 2>&1 &
SRV_PID=$!
cleanup(){ kill "$SRV_PID" 2>/dev/null || true; rm -rf "$SRV_DIR"; }
trap cleanup EXIT
sleep 2
curl -fsS "http://$MAC_IP:$HTTP_PORT/termux-setup.sh" >/dev/null || die "phone-facing file server not reachable at $MAC_IP:$HTTP_PORT"

# ---- 4. drive Termux: upgrade, install, run setup --------------------------
# NOTE on ordering: a fresh Termux bootstrap ships a curl that breaks against the
# newer openssl (missing SSL_set_quic_tls_transport_params), and `pkg` itself uses
# curl. So we use `apt` directly and full-upgrade BEFORE installing curl, so
# everything lands at matching versions. --force-confold auto-keeps config files.
focus_termux
log "apt update"
adb_type "apt update";                                                   sleep 20
log "apt full-upgrade (fixes curl/openssl; ~2 min)"
adb_type "apt full-upgrade -y -o Dpkg::Options::=--force-confold";        sleep 150
log "installing nginx, curl, cloudflared"
adb_type "apt install -y nginx curl cloudflared";                        sleep 45
log "fetching + running the in-Termux setup script"
adb_type "curl http://$MAC_IP:$HTTP_PORT/termux-setup.sh -o s.sh";       sleep 5
adb_type "bash s.sh $MAC_IP $HTTP_PORT $NGINX_PORT";                      sleep 12

# ---- 5. ADB-side hardening (no typing) -------------------------------------
log "exempting Termux from battery optimization + enabling background + RUN_COMMAND"
adb shell dumpsys deviceidle whitelist +com.termux      >/dev/null 2>&1 || true
adb shell dumpsys deviceidle whitelist +com.termux.boot >/dev/null 2>&1 || true
for op in RUN_IN_BACKGROUND RUN_ANY_IN_BACKGROUND; do
  adb shell cmd appops set com.termux "$op" allow      >/dev/null 2>&1 || true
  adb shell cmd appops set com.termux.boot "$op" allow >/dev/null 2>&1 || true
done
adb shell pm grant com.termux com.termux.permission.RUN_COMMAND >/dev/null 2>&1 || true

log "registering Termux:Boot (must be opened once so Android lets it run on boot)"
adb shell monkey -p com.termux.boot -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
sleep 2

# ---- 6. verify -------------------------------------------------------------
PHONE_IP=$(adb shell ip -f inet addr show wlan0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | tr -d '\r')
log "verifying server at http://$PHONE_IP:$NGINX_PORT"
ok=""
for i in 1 2 3 4 5; do
  code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://$PHONE_IP:$NGINX_PORT" || true)
  [ "$code" = "200" ] && { ok=1; break; }
  sleep 5
done

echo
if [ -n "$ok" ]; then
  printf '\033[1;32m✓ DONE\033[0m — server is live at \033[1mhttp://%s:%s\033[0m\n' "$PHONE_IP" "$NGINX_PORT"
  echo "  • Auto-starts on boot (Termux:Boot). Reboot to confirm if you like."
  echo "  • Deploy a site:      scripts/deploy.sh ./my-site"
  echo "  • Run maintenance:    scripts/termux-run.sh 'apt update && apt full-upgrade -y'"
  echo "  • Public internet:    see README.md 'Cloudflare Tunnel'"
else
  printf '\033[1;31m✗ verify failed\033[0m (last HTTP: %s)\n' "${code:-none}"
  echo "  The typed-command step is the fragile part. Open Termux on the phone and check"
  echo "  it reached a prompt; you can re-run: scripts/termux-run.sh 'bash s.sh $MAC_IP $HTTP_PORT $NGINX_PORT'"
  echo "  or just re-run ./provision.sh. See README.md > Troubleshooting."
  exit 1
fi
