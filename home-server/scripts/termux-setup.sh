#!/data/data/com.termux/files/usr/bin/bash
#
# termux-setup.sh — runs INSIDE Termux on the phone.
# Fetched and executed by provision.sh (via curl from the Mac's temp HTTP server).
#
# Args: MAC_IP  HTTP_PORT  NGINX_PORT
#   MAC_IP     IP of the provisioning Mac on the LAN (to fetch the site from)
#   HTTP_PORT  port of the Mac's temp HTTP server (default 8000)
#   NGINX_PORT port nginx should listen on (default 8080; must be >=1024, Android forbids lower)
#
set -e
MAC_IP="${1:?need MAC_IP}"
HTTP_PORT="${2:-8000}"
NGINX_PORT="${3:-8080}"
PREFIX=/data/data/com.termux/files/usr

echo ">> fetching site into nginx docroot"
mkdir -p "$PREFIX/share/nginx/html"
curl -fsS "http://$MAC_IP:$HTTP_PORT/index.html" -o "$PREFIX/share/nginx/html/index.html"

echo ">> setting nginx listen port to $NGINX_PORT"
# Termux's default nginx.conf listens on 8080; rewrite only if a different port is requested.
if [ "$NGINX_PORT" != "8080" ]; then
  sed -i "s/listen[[:space:]]\{1,\}8080;/listen $NGINX_PORT;/g" "$PREFIX/etc/nginx/nginx.conf"
fi

echo ">> installing Termux:Boot autostart script"
mkdir -p ~/.termux/boot
cat > ~/.termux/boot/start-server.sh <<'BOOT'
#!/data/data/com.termux/files/usr/bin/sh
# Runs on device boot (via the Termux:Boot app).
# Keep the CPU awake so the server survives screen-off / doze, then start nginx.
termux-wake-lock
if ! pgrep -x nginx >/dev/null 2>&1; then
  nginx
fi
BOOT
chmod +x ~/.termux/boot/start-server.sh

echo ">> starting server now"
termux-wake-lock
nginx -s stop 2>/dev/null || true
sleep 1
nginx

echo "TERMUX_SETUP_DONE port=$NGINX_PORT"
