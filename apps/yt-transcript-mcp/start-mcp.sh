#!/data/data/com.termux/files/usr/bin/sh
# Termux:Boot launcher for the YouTube-transcript MCP server.
# ADDITIVE — does not touch nginx / battery-monitor. Copy to ~/.termux/boot/30-yt-mcp.sh
# (the "30-" makes it run after nginx(10)/monitor; sshd(00) is already there).
termux-wake-lock

DIR="$HOME/yt-transcript-mcp"

# 1. MCP server (listens on 127.0.0.1:8765 — only cloudflared reaches it)
if ! pgrep -f "yt-transcript-mcp/server.py" >/dev/null 2>&1; then
  cd "$DIR" || exit 0
  nohup "$DIR/venv/bin/python" "$DIR/server.py" >>"$DIR/mcp.log" 2>&1 &
fi

# 2. Named Cloudflare tunnel (set up once at deploy: `cloudflared tunnel login`,
#    create tunnel, route DNS, write ~/.cloudflared/config.yml -> localhost:8765).
if [ -f "$HOME/.cloudflared/config.yml" ] && ! pgrep -f "cloudflared.*tunnel.*run" >/dev/null 2>&1; then
  nohup cloudflared tunnel run >>"$DIR/tunnel.log" 2>&1 &
fi
