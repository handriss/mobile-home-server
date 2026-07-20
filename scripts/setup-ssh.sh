#!/usr/bin/env bash
#
# setup-ssh.sh — install & configure Termux sshd on the phone (key-based, auto-start
# on boot) so future deploys go over WiFi with no USB/ADB. Run ONCE over ADB (USB).
#
# After this:  scripts/deploy-ssh.sh <site-dir>     (deploy over WiFi, no cable)
#              ssh -p 8022 <phone-ip> '<cmd>'       (Termux accepts any username)
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; source "$HERE/lib.sh"; resolve_serial

PUB=""
for k in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub" "$HOME/.ssh/id_ecdsa.pub"; do
  [ -f "$k" ] && PUB="$k" && break
done
[ -n "$PUB" ] || die "no SSH public key found (~/.ssh/id_*.pub). Make one: ssh-keygen -t ed25519"
log "authorizing key: $PUB"

MAC_IP="$(mac_ip)"; [ -n "$MAC_IP" ] || die "could not detect Mac LAN IP"

# 1. Install openssh FIRST, on its own. (Doing this inside the file-server window below
#    caused a race: pkg install outran the Mac's wait and the server was torn down
#    before the phone could fetch the key.)
log "installing openssh on the phone (~20s)"
"$HERE/termux-run.sh" 'pkg install -y openssh'
sleep 20

# 2. Now the fast part: fetch the key, write the boot launcher, start sshd.
HTTP="${SSH_HTTP_PORT:-8017}"
SRV="$(mktemp -d)"; cp "$PUB" "$SRV/mac.pub"
cat > "$SRV/finish-ssh.sh" <<'EOF'
#!/data/data/com.termux/files/usr/bin/bash
MAC="$1"; PORT="$2"
mkdir -p ~/.ssh; chmod 700 ~/.ssh
curl -fsS "http://$MAC:$PORT/mac.pub" -o ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
mkdir -p ~/.termux/boot
printf '#!/data/data/com.termux/files/usr/bin/sh\nsshd\n' > ~/.termux/boot/00-sshd.sh
chmod +x ~/.termux/boot/00-sshd.sh
pkill sshd 2>/dev/null || true; sleep 1; sshd
EOF
python3 -m http.server "$HTTP" --bind 0.0.0.0 --directory "$SRV" >/dev/null 2>&1 &
SP=$!; trap 'kill "$SP" 2>/dev/null || true; rm -rf "$SRV"' EXIT
sleep 2
curl -fsS "http://$MAC_IP:$HTTP/finish-ssh.sh" >/dev/null || die "file server unreachable"
log "authorizing key + starting sshd"
termux_fetch_run "http://$MAC_IP:$HTTP/finish-ssh.sh" "finish-ssh.sh" "$MAC_IP $HTTP"
sleep 3

# 3. Verify over WiFi.
PHONE_IP=$(adb shell ip -f inet addr show wlan0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | tr -d '\r')
if ssh -p 8022 -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=8 "$PHONE_IP" 'true' 2>/dev/null; then
  printf '\033[1;32m✓ sshd up — WiFi deploys enabled\033[0m\n'
  echo "  deploy:  scripts/deploy-ssh.sh ./www           (over WiFi, no cable)"
  echo "  shell:   ssh -p 8022 $PHONE_IP"
else
  die "sshd verify failed — open Termux and check 'sshd' is running / 'pgrep sshd'"
fi
