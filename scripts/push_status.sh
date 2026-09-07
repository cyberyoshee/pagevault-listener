#!/bin/bash
# ============================================================
# PageVault Status Push Script
# Reads local status.txt and POSTs to central dashboard API
# Runs via cron every 30 seconds
#
# Features:
#   - Staleness detection: if daemon is dead (status.txt > 2 min old),
#     sends zeroed heartbeat so dashboard shows the problem
#   - Parses per-channel last_at (ISO timestamp) and freq_hz
#   - Authenticates with X-API-Key header
# ============================================================

CONFIG_FILE="$HOME/pagevault/config/listener.conf"
STATUS_FILE="$HOME/pagevault/state/status.txt"

# Read config
if [ ! -f "$CONFIG_FILE" ]; then
    exit 0
fi
source "$CONFIG_FILE"

# Bail if no central URL configured
if [ -z "$CENTRAL_URL" ]; then
    exit 0
fi

# Bail if no status file yet
if [ ! -f "$STATUS_FILE" ]; then
    exit 0
fi

# Check if status file is stale (daemon may have crashed)
# The daemon's watchdog updates status.txt every 30 seconds
# If it's older than 120 seconds, the daemon is likely dead
STATUS_AGE=$(( $(date +%s) - $(stat -c %Y "$STATUS_FILE") ))
if [ "$STATUS_AGE" -gt 120 ]; then
    # Push a minimal heartbeat flagging the daemon as down
    JSON="{\"listener_id\":\"${LISTENER_ID:-unknown}\",\"location\":\"${LISTENER_LOCATION:-}\",\"owner\":\"${LISTENER_OWNER:-}\",\"disk_usage_pct\":0,\"messages_decoded\":0,\"channels_active\":0,\"channels\":[]}"
    curl -s -X POST \
        -H "Content-Type: application/json" \
        -H "X-API-Key: ${CENTRAL_API_KEY:-}" \
        -d "$JSON" \
        "$CENTRAL_URL" > /dev/null 2>&1
    exit 0
fi

# Read values from status file
DISK=$(grep "disk_usage_pct" "$STATUS_FILE" | awk '{print $2}')
MSGS=$(grep "messages_decoded" "$STATUS_FILE" | awk '{print $2}')
ACTIVE=$(grep "channels_active" "$STATUS_FILE" | awk '{print $2}')

# Default to 0 if not found
DISK="${DISK:-0}"
MSGS="${MSGS:-0}"
ACTIVE="${ACTIVE:-0}"

# Build channel JSON array from the Channel Health section
CHANNELS_JSON="["
FIRST=true
while IFS= read -r line; do
    if echo "$line" | grep -qE "^[a-z].*: status="; then
        CH_NAME=$(echo "$line" | cut -d: -f1 | tr -d ' ')
        CH_STATUS=$(echo "$line" | grep -oP 'status=\K\S+')
        CH_MSGS=$(echo "$line" | grep -oP 'msgs=\K\d+')
        CH_RESTARTS=$(echo "$line" | grep -oP 'restarts=\K\d+')
        CH_PIDS=$(echo "$line" | grep -oP 'pids=\K\S+')
        CH_FREQ=$(echo "$line" | grep -oP 'freq_hz=\K\d+')
        CH_LAST_AT=$(echo "$line" | grep -oP 'last_at=\K\S+')

        # Format last_message_at as JSON
        if [ "$CH_LAST_AT" = "never" ] || [ -z "$CH_LAST_AT" ]; then
            CH_LAST_JSON="null"
        else
            CH_LAST_JSON="\"$CH_LAST_AT\""
        fi

        if [ "$FIRST" = true ]; then
            FIRST=false
        else
            CHANNELS_JSON+=","
        fi

        CHANNELS_JSON+="{\"name\":\"$CH_NAME\",\"freq_hz\":${CH_FREQ:-0},\"status\":\"$CH_STATUS\",\"message_count\":${CH_MSGS:-0},\"last_message_at\":$CH_LAST_JSON,\"restart_count\":${CH_RESTARTS:-0},\"pids\":\"${CH_PIDS:-}\"}"
    fi
done < "$STATUS_FILE"
CHANNELS_JSON+="]"

# Build full JSON payload
JSON="{\"listener_id\":\"${LISTENER_ID:-unknown}\",\"location\":\"${LISTENER_LOCATION:-}\",\"owner\":\"${LISTENER_OWNER:-}\",\"disk_usage_pct\":${DISK},\"messages_decoded\":${MSGS},\"channels_active\":${ACTIVE},\"channels\":${CHANNELS_JSON}}"

# POST to central server with API key
curl -s -X POST \
    -H "Content-Type: application/json" \
    -H "X-API-Key: ${CENTRAL_API_KEY:-}" \
    -d "$JSON" \
    "$CENTRAL_URL" > /dev/null 2>&1
