#!/usr/bin/env bash
#
# deploy.sh — deploy a local website folder to the phone's nginx docroot.
#
# Tars the folder, serves it from the Mac, and has Termux curl+extract it into the
# docroot (the curl|tar pipe runs inside Termux, so it is safe). No storage perms.
#
# Usage:
#   scripts/deploy.sh ./my-site           # replaces the served site with ./my-site/*
#   scripts/deploy.sh ./my-site 8080      # nginx port for the post-deploy verify
#   ANDROID_SERIAL=<serial> scripts/deploy.sh ./my-site
#
set -euo pipefail
SRC="${1:?usage: deploy.sh <site-dir> [nginx-port]}"
NGINX_PORT="${2:-8080}"
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib.sh"
resolve_serial

[ -d "$SRC" ] || die "'$SRC' is not a directory"

TMP="$(mktemp -d)"; SRV_PID=""
cleanup(){ [ -n "$SRV_PID" ] && kill "$SRV_PID" 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

PREFIX='/data/data/com.termux/files/usr'
tar czf "$TMP/site.tgz" -C "$SRC" .

cat > "$TMP/_deploy.sh" <<EOF
#!/data/data/com.termux/files/usr/bin/bash
set -e
DOC="$PREFIX/share/nginx/html"
mkdir -p "\$DOC"
curl -fsS "http://__IP__:__PORT__/site.tgz" | tar xzf - -C "\$DOC"
nginx -s reload 2>/dev/null || nginx 2>/dev/null || true
echo DEPLOY_DONE
EOF

read -r IP PORT SRV_PID < <(start_file_server "$TMP" 8013)
sed -i '' "s/__IP__/$IP/; s/__PORT__/$PORT/" "$TMP/_deploy.sh"

log "deploying $(du -sh "$SRC" | cut -f1) from $SRC"
termux_fetch_run "http://$IP:$PORT/_deploy.sh" "_deploy.sh"

PHONE_IP=$(adb shell ip -f inet addr show wlan0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | tr -d '\r')
if [ -n "$PHONE_IP" ]; then
  sleep 2
  code=$(curl -s -o /dev/null -m 6 -w '%{http_code}' "http://$PHONE_IP:$NGINX_PORT" || true)
  log "deployed -> http://$PHONE_IP:$NGINX_PORT (HTTP $code)"
else
  log "deployed (could not auto-detect phone IP to verify)"
fi
