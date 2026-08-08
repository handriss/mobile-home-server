#!/usr/bin/env bash
#
# deploy-ssh.sh — deploy a local site folder to the phone over WiFi (scp), no ADB.
# Requires setup-ssh.sh to have run once. Termux accepts any username on port 8022.
#
# Usage:
#   PHONE_IP=10.0.0.42 scripts/deploy-ssh.sh ./www   # phone IP from the environment
#   scripts/deploy-ssh.sh ./www 10.0.0.42            # or as the second argument
#
set -euo pipefail
SRC="${1:?usage: deploy-ssh.sh <site-dir> [phone-ip]}"
PHONE_IP="${2:-${PHONE_IP:?set PHONE_IP, or pass the phone IP as the second argument}}"
PORT="${SSH_PORT:-8022}"
DOC="/data/data/com.termux/files/usr/share/nginx/html"
[ -d "$SRC" ] || { echo "error: '$SRC' is not a directory" >&2; exit 1; }
SSH="ssh -p $PORT -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=8"

echo ">> copying $(du -sh "$SRC" | cut -f1) from $SRC to $PHONE_IP over WiFi"
# -O uses the legacy scp transfer (Termux has no sftp-server by default)
scp -O -P "$PORT" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 \
   -r "$SRC"/* "$PHONE_IP:$DOC/"
$SSH "$PHONE_IP" 'nginx -s reload 2>/dev/null || nginx 2>/dev/null || true'
code=$(curl -s -o /dev/null -m 6 -w '%{http_code}' "http://$PHONE_IP:8080" || true)
echo ">> deployed -> http://$PHONE_IP:8080 (HTTP $code)"
