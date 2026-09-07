#!/bin/bash
# ============================================================
# PageVault Log Transfer Script
# Transfers completed log files from ready/ to a remote server
# Uses .fin files to ensure file integrity on both ends
# Uses sftp (compatible with chrooted restricted upload user)
#
# Cron:
#   5 0 * * * $HOME/pagevault/scripts/transfer_logs.sh >> $HOME/pagevault/state/transfer.log 2>&1
# ============================================================

CONFIG_FILE="$HOME/pagevault/config/listener.conf"
LOCAL_READY="$HOME/pagevault/logs/ready"
LOCAL_ARCHIVED="$HOME/pagevault/logs/archived"
SSH_KEY="$HOME/.ssh/pagevault_upload"

# Read config
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Config file not found: $CONFIG_FILE"
    exit 1
fi
source "$CONFIG_FILE"

# Check if transfer is enabled
if [ "${TRANSFER_ENABLED:-false}" != "true" ]; then
    exit 0
fi

# Validate required settings
if [ -z "$REMOTE_USER" ] || [ -z "$REMOTE_HOST" ]; then
    echo "Transfer enabled but REMOTE_USER or REMOTE_HOST not set in config"
    exit 1
fi

mkdir -p "$LOCAL_ARCHIVED"

TIMESTAMP=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
echo "[$TIMESTAMP] Transfer scan starting"

TRANSFERRED=0
FAILED=0

for fin_file in "$LOCAL_READY"/*.txt.fin; do
    # Skip if no .fin files found (glob returns literal pattern)
    [ -f "$fin_file" ] || continue

    # Derive the data filename from the .fin filename
    data_file="${fin_file%.fin}"
    data_basename=$(basename "$data_file")

    # Verify the data file actually exists
    if [ ! -f "$data_file" ]; then
        echo "[$TIMESTAMP] WARNING: .fin exists but data file missing: $data_basename"
        rm -f "$fin_file"
        continue
    fi

    # Transfer the data file via sftp
    sftp -q -i "$SSH_KEY" -b - "${REMOTE_USER}@${REMOTE_HOST}" <<SFTP_BATCH 2>/dev/null
put $data_file logs/$data_basename
SFTP_BATCH

    if [ $? -ne 0 ]; then
        echo "[$TIMESTAMP] FAILED: Could not transfer $data_basename"
        FAILED=$((FAILED + 1))
        continue
    fi

    # Create .fin on remote by uploading an empty file
    TEMP_FIN=$(mktemp)
    sftp -q -i "$SSH_KEY" -b - "${REMOTE_USER}@${REMOTE_HOST}" <<SFTP_FIN 2>/dev/null
put $TEMP_FIN logs/${data_basename}.fin
SFTP_FIN
    rm -f "$TEMP_FIN"

    if [ $? -ne 0 ]; then
        echo "[$TIMESTAMP] WARNING: Transferred $data_basename but could not create remote .fin"
        FAILED=$((FAILED + 1))
        continue
    fi

    # Success -- move local files to archived
    mv "$data_file" "$LOCAL_ARCHIVED/"
    rm -f "$fin_file"

    echo "[$TIMESTAMP] OK: $data_basename transferred and archived"
    TRANSFERRED=$((TRANSFERRED + 1))
done

echo "[$TIMESTAMP] Transfer complete: $TRANSFERRED transferred, $FAILED failed"
