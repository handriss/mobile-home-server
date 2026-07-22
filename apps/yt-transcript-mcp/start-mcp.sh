#!/data/data/com.termux/files/usr/bin/sh
# Termux:Boot launcher for the YouTube-transcript MCP server.
# ADDITIVE — does not touch nginx / battery-monitor / sshd.
# Deployed as ~/.termux/boot/30-yt-mcp.sh (00-sshd, 10-nginx/monitor run first).
termux-wake-lock

# start the MCP server if not already running (pgrep pattern won't match this script's name)
if ! pgrep -f server.py >/dev/null 2>&1; then
  cd "$HOME/yt-transcript-mcp" && setsid python -u server.py > mcp.log 2>&1 < /dev/null &
fi

# Named Cloudflare tunnel (added once `cloudflared tunnel` is configured at deploy):
if [ -f "$HOME/.cloudflared/config.yml" ] && ! pgrep -f "cloudflared.*tunnel.*run" >/dev/null 2>&1; then
  setsid cloudflared tunnel run > "$HOME/yt-transcript-mcp/tunnel.log" 2>&1 < /dev/null &
fi
