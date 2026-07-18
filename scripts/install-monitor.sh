#!/data/data/com.termux/files/usr/bin/bash
# install-monitor.sh — runs INSIDE Termux. Installs battery-monitor.sh, writes its
# config + a Termux:Boot launcher, and (re)starts it. Fetched by the Mac deploy step.
# Args: NTFY_TOPIC  HEALTHCHECK_URL(or 'none')  MAC_IP  HTTP_PORT  [NAME]
set -e
TOPIC="${1:?need ntfy topic}"
HC="${2:-none}"; [ "$HC" = none ] && HC=""
MAC="${3:?need mac ip}"
PORT="${4:-8014}"
NAME="${5:-home-server}"
DIR="$HOME/batt-monitor"; mkdir -p "$DIR"

curl -fsS "http://$MAC:$PORT/battery-monitor.sh" -o "$DIR/monitor.sh"
chmod +x "$DIR/monitor.sh"

cat > "$DIR/monitor.conf" <<CONF
NAME=$NAME
NTFY_URL=https://ntfy.sh
NTFY_TOPIC=$TOPIC
HEALTHCHECK_URL=$HC
TEMP_WARN=43
TEMP_URGENT=48
POLL_SECS=300
DIGEST_HOUR=9
CONF

mkdir -p "$HOME/.termux/boot"
cat > "$HOME/.termux/boot/battery-monitor.sh" <<'BOOT'
#!/data/data/com.termux/files/usr/bin/sh
termux-wake-lock
pgrep -f batt-monitor/monitor.sh >/dev/null 2>&1 || nohup bash $HOME/batt-monitor/monitor.sh >/dev/null 2>&1 &
BOOT
chmod +x "$HOME/.termux/boot/battery-monitor.sh"

pkill -f batt-monitor/monitor.sh 2>/dev/null || true
sleep 1
nohup bash "$DIR/monitor.sh" >/dev/null 2>&1 &
sleep 3
echo "MONITOR_INSTALLED pid=$(pgrep -f batt-monitor/monitor.sh | head -1) topic=$TOPIC hc=${HC:-<none>}"
