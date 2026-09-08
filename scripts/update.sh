#!/bin/bash
# ============================================================
# PageVault Update
# ============================================================
# Fetches the latest setup.sh from the repository and runs it
# in update mode. This ensures setup.sh itself is always current.
#
# This file should NEVER need to change. If the repo URL
# changes, update it here and push to all listeners.
# ============================================================

REPO_RAW_URL="https://raw.githubusercontent.com/cyberyoshee/pagevault-listener/main/scripts/setup.sh"

echo "Fetching latest setup script..."
TEMP_SETUP=$(mktemp)

if curl -sL -o "$TEMP_SETUP" "$REPO_RAW_URL" && [ -s "$TEMP_SETUP" ]; then
    bash "$TEMP_SETUP" --update
    rm -f "$TEMP_SETUP"
else
    echo "Failed to fetch setup script from $REPO_RAW_URL"
    echo "Falling back to local setup.sh..."
    rm -f "$TEMP_SETUP"

    LOCAL_SETUP="$HOME/pagevault/scripts/setup.sh"
    if [ -f "$LOCAL_SETUP" ]; then
        "$LOCAL_SETUP" --update
    else
        echo "No local setup.sh found either. Cannot update."
        exit 1
    fi
fi
