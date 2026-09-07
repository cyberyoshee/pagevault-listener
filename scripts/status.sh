#!/bin/bash
# PageVault status - quick view of what's happening
# Compatible with daemon v2.8+ (v2.10 adds disk fields to status.txt)

BASE_DIR="$HOME/pagevault"

echo "=== PageVault Status ==="
echo ""

echo "--- Daemon process ---"
if pgrep -f pagevault_daemon > /dev/null; then
    echo "Daemon: RUNNING (PID: $(pgrep -f pagevault_daemon | head -1))"
else
    echo "Daemon: NOT RUNNING"
fi

echo ""
echo "--- Current state ---"
if [ -f "$BASE_DIR/state/status.txt" ]; then
    cat "$BASE_DIR/state/status.txt"
else
    echo "No status file yet (daemon may still be starting)"
fi

echo ""
echo "--- Disk usage ---"
df -h "$BASE_DIR" | tail -1

echo ""
echo "--- Log file counts ---"
echo "Processing: $(ls "$BASE_DIR/logs/processing/"*.txt 2>/dev/null | wc -l) file(s)"
echo "Ready:      $(ls "$BASE_DIR/logs/ready/"*.txt 2>/dev/null | wc -l) file(s)"
echo "Archived:   $(ls "$BASE_DIR/logs/archived/"*.txt 2>/dev/null | wc -l) file(s)"

echo ""
echo "--- Recent errors ---"
if [ -s "$BASE_DIR/state/error.log" ]; then
    tail -5 "$BASE_DIR/state/error.log"
else
    echo "No errors logged"
fi

echo ""
echo "--- Recent daemon activity ---"
tail -10 "$BASE_DIR/state/daemon.log" 2>/dev/null
