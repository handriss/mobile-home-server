#!/data/data/com.termux/files/usr/bin/sh
# Start/restart the MCP server. Invoked BY NAME (sh run.sh) so the pkill below
# matches only the python server, not the shell that launched it.
D="$HOME/yt-transcript-mcp"
pkill -f server.py 2>/dev/null
sleep 1
cd "$D" || exit 1
setsid python -u server.py > mcp.log 2>&1 < /dev/null &
sleep 2
echo "pid=$(pgrep -f server.py | tr '\n' ' ')"
echo "log: $(cat mcp.log 2>/dev/null)"
