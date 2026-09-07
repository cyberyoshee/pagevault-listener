#!/bin/bash
# ============================================================
# PageVault Listener Setup Script
# ============================================================
#
# Sets up a complete PageVault listener on a fresh Ubuntu 26.04 LTS
# install. Idempotent -- safe to run multiple times.
#
# What it does:
#   1. Installs system dependencies (apt packages)
#   2. Blacklists DVB kernel driver for RTL-SDR access
#   3. Configures USB permissions for non-root SDR access
#   4. Auto-detects and configures RTL-SDR dongle serial numbers
#   5. Builds and installs RTLSDR-Airband with NFM + PulseAudio
#   6. Creates directory structure
#   7. Pulls latest PageVault scripts from the repository
#   8. Creates listener config (interactive prompts)
#   9. Self-registers with central server (registration token)
#  10. Sets up cron jobs (status push, log transfer)
#  11. Optionally starts daemon and installs a systemd user unit
#
# Usage:
#   ./setup.sh                     # Full setup
#   ./setup.sh --update            # Pull latest scripts only
#   ./setup.sh --help              # Show this help
#
# Prerequisites:
#   - Ubuntu 26.04 LTS (desktop with PipeWire/PulseAudio)
#   - Internet access, sudo privileges, and a terminal (setup is interactive)
#   - Registration token from the PageVault admin
#   - Safe to run via `curl ... | bash`: prompts read from /dev/tty, not stdin
#
# ============================================================

set -e

# Catch errors and show where they happened
trap 'log_error "Setup failed at line $LINENO. Check output above for details."; exit 1' ERR

# ============================================================
# CONFIGURATION
# ============================================================

REPO_URL="https://github.com/cyberyoshee/pagevault.git"
REPO_BRANCH="main"
PAGEVAULT_HOME="$HOME/pagevault"
PAGEVAULT_SCRIPTS="$PAGEVAULT_HOME/scripts"
PAGEVAULT_CONFIG="$PAGEVAULT_HOME/config"
PAGEVAULT_STATE="$PAGEVAULT_HOME/state"
AIRBAND_BUILD_DIR="$PAGEVAULT_HOME/build/RTLSDR-Airband"
AIRBAND_BUILD_DIR_LEGACY="$HOME/RTLSDR-Airband"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ============================================================
# HELPERS
# ============================================================

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Prompts must read from the terminal, never stdin: when this script is
# installed via `curl ... | bash`, stdin is the script text itself and a bare
# `read` would silently consume the rest of the script as its answer.
# Probe with a redirect on a simple command: /dev/tty can pass -c/-r yet still
# fail to open with ENXIO when there is no controlling terminal, and a failed
# redirect on `exec` terminates the shell outright.
if (: < /dev/tty) 2>/dev/null; then
    exec 3< /dev/tty
    INTERACTIVE=true
elif [ -t 0 ]; then
    exec 3<&0
    INTERACTIVE=true
else
    INTERACTIVE=false
fi

# prompt <varname> <prompt text>
# Reads one line into <varname>. Leaves it empty when non-interactive.
prompt() {
    local __var="$1"
    local __text="$2"
    local __val=""

    if [ "$INTERACTIVE" = true ]; then
        # stdout is still the terminal even when stdin is a pipe
        printf "%s" "$__text"
        IFS= read -r __val <&3 || __val=""
    fi

    printf -v "$__var" '%s' "$__val"
}

require_interactive() {
    if [ "$INTERACTIVE" != true ]; then
        echo ""
        log_error "$1 requires an interactive terminal, but none is available."
        log_error "Re-run setup from a terminal:"
        log_error "  git clone $REPO_URL && ./pagevault/scripts/setup.sh"
        exit 1
    fi
}

# Install scripts from a staging directory into PAGEVAULT_SCRIPTS.
#
# Uses rename(2) rather than copying in place. This script is one of the files
# being replaced, and bash reads a script incrementally by byte offset -- an
# in-place overwrite corrupts the still-executing setup.sh precisely when the
# incoming version differs, which is exactly the update case. Replacing the
# inode leaves our open file descriptor pointing at the original content.
# The staging directory therefore has to live on the same filesystem.
install_scripts() {
    local staging="$1"
    local f name

    mkdir -p "$PAGEVAULT_SCRIPTS"

    for f in "$staging"/*; do
        [ -f "$f" ] || continue
        name=$(basename "$f")
        case "$name" in
            *.sh|*.py|pagevault) chmod +x "$f" ;;
        esac
        mv -f "$f" "$PAGEVAULT_SCRIPTS/$name"
    done
}

check_ubuntu() {
    if ! grep -q "Ubuntu" /etc/os-release 2>/dev/null; then
        log_error "This script is designed for Ubuntu."
        exit 1
    fi
    log_info "Detected: $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')"
}

# ============================================================
# PARSE ARGUMENTS
# ============================================================

UPDATE_ONLY=false

case "${1:-}" in
    --update)
        UPDATE_ONLY=true
        ;;
    --help|-h)
        head -35 "$0" | grep "^#" | sed 's/^# *//'
        exit 0
        ;;
esac

# ============================================================
# MAIN SETUP
# ============================================================

echo ""
echo "============================================================"
echo "  PageVault Listener Setup"
echo "============================================================"
echo ""

check_ubuntu

# Verify sudo access
if ! sudo -n true 2>/dev/null; then
    log_info "This script requires sudo access. You may be prompted for your password."
    sudo true || { log_error "Cannot obtain sudo access"; exit 1; }
fi

# ----------------------------------------------------------
# UPDATE MODE
# ----------------------------------------------------------

if [ "$UPDATE_ONLY" = true ]; then
    log_info "Update mode -- pulling latest scripts only"

    if echo "$REPO_URL" | grep -q "CHANGEME"; then
        log_error "Repository URL not configured in setup.sh"
        exit 1
    fi

    # Stage inside PAGEVAULT_HOME so install_scripts can use a plain rename
    mkdir -p "$PAGEVAULT_HOME"
    TEMP_REPO="$PAGEVAULT_HOME/.update-$$"
    trap 'rm -rf "$TEMP_REPO"' EXIT

    if ! git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$TEMP_REPO" 2>/dev/null; then
        log_error "Could not clone $REPO_URL (branch $REPO_BRANCH)"
        exit 1
    fi

    if [ -d "$TEMP_REPO/scripts" ]; then
        install_scripts "$TEMP_REPO/scripts"
        log_info "Scripts updated from repository"
    else
        log_warn "No scripts directory found in repository"
        rm -rf "$TEMP_REPO"
        exit 1
    fi

    rm -rf "$TEMP_REPO"

    # Pick up the new code if the daemon is running
    if pgrep -f pagevault_daemon > /dev/null; then
        log_info "Restarting daemon to apply updates"
        "$PAGEVAULT_SCRIPTS/pagevault" restart || log_warn "Daemon restart failed -- check 'pagevault status'"
    fi

    echo ""
    log_info "Update complete"
    exit 0
fi

# ----------------------------------------------------------
# STEP 1: Install system dependencies
# ----------------------------------------------------------

log_info "Step 1/11: Installing system dependencies"

sudo apt update -qq

APT_LOG=$(mktemp)
if ! sudo apt install -y -qq \
    rtl-sdr \
    multimon-ng \
    sox \
    libsox-fmt-mp3 \
    curl \
    git \
    build-essential \
    cmake \
    pkg-config \
    python3 \
    python3-pip \
    libusb-1.0-0-dev \
    libmp3lame-dev \
    libshout3-dev \
    libconfig++-dev \
    libfftw3-dev \
    librtlsdr-dev \
    libpulse-dev \
    pulseaudio-utils \
    > "$APT_LOG" 2>&1
then
    log_error "Package installation failed:"
    tail -30 "$APT_LOG"
    rm -f "$APT_LOG"
    exit 1
fi
rm -f "$APT_LOG"

# The daemon shells out to these directly -- fail loudly here rather than
# leaving every decoder chain to crash at runtime.
for bin in pactl parec sox multimon-ng rtl_test; do
    if ! command -v "$bin" > /dev/null 2>&1; then
        log_error "Required command '$bin' not found after package install"
        exit 1
    fi
done

log_info "System dependencies installed"

# ----------------------------------------------------------
# STEP 2: Blacklist DVB kernel driver
# ----------------------------------------------------------

log_info "Step 2/11: Configuring kernel driver blacklist"

BLACKLIST_FILE="/etc/modprobe.d/blacklist-rtl.conf"
if [ -f "$BLACKLIST_FILE" ]; then
    log_info "Blacklist already exists, skipping"
else
    sudo bash -c "cat > $BLACKLIST_FILE << EOF
blacklist dvb_usb_rtl28xxu
blacklist rtl2832
blacklist rtl2830
install dvb_usb_rtl28xxu /bin/true
EOF"
    sudo rmmod dvb_usb_rtl28xxu rtl2832 rtl2830 2>/dev/null || true
    log_info "DVB driver blacklisted"
fi

# ----------------------------------------------------------
# STEP 3: USB permissions
# ----------------------------------------------------------

log_info "Step 3/11: Configuring USB permissions"

UDEV_FILE="/etc/udev/rules.d/20-rtlsdr.rules"
if [ -f "$UDEV_FILE" ]; then
    log_info "USB permissions already configured, skipping"
else
    sudo bash -c "cat > $UDEV_FILE << EOF
SUBSYSTEM==\"usb\", ATTRS{idVendor}==\"0bda\", ATTRS{idProduct}==\"2838\", GROUP=\"plugdev\", MODE=\"0666\"
EOF"
    sudo udevadm control --reload-rules
    sudo udevadm trigger
    log_info "USB permissions configured"
fi

if groups "$USER" | grep -q "plugdev"; then
    log_info "User already in plugdev group"
else
    sudo usermod -aG plugdev "$USER"
    log_warn "Added $USER to plugdev group -- log out and back in for this to take effect"
fi

# ----------------------------------------------------------
# STEP 4: Auto-detect and configure RTL-SDR dongles
# ----------------------------------------------------------

log_info "Step 4/11: Detecting and configuring RTL-SDR dongles"

DONGLE_SERIALS=("929MHz" "931MHz")
sudo rmmod dvb_usb_rtl28xxu 2>/dev/null || true
DONGLE_COUNT=$(lsusb | grep -c "0bda:2838" || true)

if [ "$DONGLE_COUNT" -eq 0 ]; then
    log_warn "No RTL-SDR dongles detected -- plug them in and re-run setup"
else
    log_info "Found $DONGLE_COUNT RTL-SDR dongle(s)"

    for i in $(seq 0 $((DONGLE_COUNT - 1))); do
        EXPECTED_SERIAL="${DONGLE_SERIALS[$i]}"
        CURRENT_SERIAL=$(rtl_test -d $i 2>&1 | grep "SN:" | head -1 | sed 's/.*SN: //' | tr -d ' ' || echo "unknown")

        if [ "$CURRENT_SERIAL" = "$EXPECTED_SERIAL" ]; then
            log_info "Dongle $i: serial already set to '$EXPECTED_SERIAL'"
        else
            log_info "Dongle $i: current serial '$CURRENT_SERIAL', setting to '$EXPECTED_SERIAL'"
            rtl_eeprom -d $i -s "$EXPECTED_SERIAL" 2>/dev/null <<< "y" || true

            USB_PATH=$(lsusb | grep "0bda:2838" | sed -n "$((i + 1))p" | awk '{print "/dev/bus/usb/" $2 "/" $4}' | tr -d ':')

            if [ -n "$USB_PATH" ] && [ -e "$USB_PATH" ]; then
                sudo python3 -c "
import fcntl, os
USBDEVFS_RESET = 21780
fd = os.open('$USB_PATH', os.O_WRONLY)
fcntl.ioctl(fd, USBDEVFS_RESET, 0)
os.close(fd)
" 2>/dev/null && log_info "Dongle $i: USB reset complete" || log_warn "Dongle $i: USB reset failed, may need physical unplug/replug"
                sleep 2
            else
                log_warn "Dongle $i: could not find USB device path for reset"
            fi
        fi
    done

    sleep 2
    log_info "Verifying dongle configuration:"
    rtl_test -t 2>&1 | grep -E "Found|Realtek|SN:" | while read line; do
        log_info "  $line"
    done
fi

# ----------------------------------------------------------
# STEP 5: Build and install RTLSDR-Airband
# ----------------------------------------------------------

log_info "Step 5/11: Building RTLSDR-Airband"

if command -v rtl_airband &> /dev/null; then
    if ldd "$(which rtl_airband)" | grep -q "libpulse"; then
        log_info "RTLSDR-Airband already installed with PulseAudio support, skipping build"
    else
        log_warn "RTLSDR-Airband installed but missing PulseAudio support, rebuilding"
        REBUILD_AIRBAND=true
    fi
else
    REBUILD_AIRBAND=true
fi

if [ "${REBUILD_AIRBAND:-false}" = true ] || ! command -v rtl_airband &> /dev/null; then
    mkdir -p "$(dirname "$AIRBAND_BUILD_DIR")"

    # Setups before this change built in $HOME/RTLSDR-Airband. Reuse that clone
    # rather than re-fetching the whole upstream tree; step 5 wipes build/ and
    # reconfigures from scratch anyway, so no stale cmake state carries over.
    if [ -d "$AIRBAND_BUILD_DIR_LEGACY" ] && [ ! -d "$AIRBAND_BUILD_DIR" ]; then
        mv "$AIRBAND_BUILD_DIR_LEGACY" "$AIRBAND_BUILD_DIR"
        log_info "Moved existing build tree from $AIRBAND_BUILD_DIR_LEGACY"
    fi

    if [ -d "$AIRBAND_BUILD_DIR" ]; then
        cd "$AIRBAND_BUILD_DIR"
        git pull origin master 2>/dev/null || true
    else
        git clone https://github.com/szpajder/RTLSDR-Airband.git "$AIRBAND_BUILD_DIR"
        cd "$AIRBAND_BUILD_DIR"
    fi

    rm -rf build
    cmake -B build -DPLATFORM=generic -DNFM=ON -DPULSE=ON
    cmake --build build -j$(nproc)
    sudo cmake --install build
    log_info "RTLSDR-Airband built and installed"
fi

if ! ldd "$(which rtl_airband)" | grep -q "libpulse"; then
    log_error "RTLSDR-Airband PulseAudio support verification failed"
    exit 1
fi
log_info "RTLSDR-Airband verified: NFM + PulseAudio enabled"

# ----------------------------------------------------------
# STEP 6: Create directory structure
# ----------------------------------------------------------

log_info "Step 6/11: Creating directory structure"

mkdir -p "$PAGEVAULT_HOME/scripts"
mkdir -p "$PAGEVAULT_HOME/logs/processing"
mkdir -p "$PAGEVAULT_HOME/logs/ready"
mkdir -p "$PAGEVAULT_HOME/logs/archived"
mkdir -p "$PAGEVAULT_HOME/state"
mkdir -p "$PAGEVAULT_HOME/config"

log_info "Directory structure created at $PAGEVAULT_HOME"

# ----------------------------------------------------------
# STEP 7: Pull latest scripts from repository
# ----------------------------------------------------------

log_info "Step 7/11: Pulling latest scripts"

TEMP_REPO="$PAGEVAULT_HOME/.update-$$"
trap 'rm -rf "$TEMP_REPO"' EXIT

if echo "$REPO_URL" | grep -q "CHANGEME"; then
    log_warn "Repository URL not configured in setup.sh"
    log_warn "Skipping script pull -- copy scripts manually to $PAGEVAULT_SCRIPTS/"
else
    if git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$TEMP_REPO" 2>/dev/null; then
        if [ -d "$TEMP_REPO/scripts" ]; then
            install_scripts "$TEMP_REPO/scripts"
            log_info "Scripts pulled from repository"
        else
            log_warn "No scripts directory found in repository"
        fi
    else
        log_warn "Could not clone $REPO_URL -- continuing with scripts already on disk"
    fi

    rm -rf "$TEMP_REPO"
fi

# Create system-wide 'pagevault' command (after scripts are pulled)
if [ -f "$PAGEVAULT_SCRIPTS/pagevault" ]; then
    sudo ln -sf "$PAGEVAULT_SCRIPTS/pagevault" /usr/local/bin/pagevault
    log_info "Command 'pagevault' available system-wide"
fi

# ----------------------------------------------------------
# STEP 8: Create listener config if not exists
# ----------------------------------------------------------

log_info "Step 8/11: Checking listener configuration"

LISTENER_CONF="$PAGEVAULT_CONFIG/listener.conf"

if [ -f "$LISTENER_CONF" ]; then
    log_info "Listener config already exists, not overwriting"
    # Holds the central API key -- tighten perms on configs from older setups
    chmod 600 "$LISTENER_CONF"

    # Migration: setups before v2.9 always wrote DONGLE2_ENABLED=false, and the
    # daemon ignored the flag and drove both dongles anyway. Now that the flag
    # is honoured, a stale 'false' would silently drop a working second dongle.
    if [ "${DONGLE_COUNT:-0}" -ge 2 ] && grep -q '^DONGLE2_ENABLED=false' "$LISTENER_CONF"; then
        sed -i 's|^DONGLE2_ENABLED=.*|DONGLE2_ENABLED=true|' "$LISTENER_CONF"
        log_info "Second dongle detected -- enabled DONGLE2 in existing config"
    fi
else
    require_interactive "Listener configuration"
    echo ""
    echo "============================================================"
    echo "  Listener Identification"
    echo "============================================================"
    echo ""
    echo "  Each listener needs a unique ID. Use something descriptive"
    echo "  like: mtl-01, ottawa-01, qc-city-01, listener-home, etc."
    echo ""
    echo "  Only letters, numbers, hyphens, and underscores allowed."
    echo ""

    LISTENER_ID=""
    while [ -z "$LISTENER_ID" ]; do
        prompt LISTENER_ID "  Enter listener ID: "
        if [ -n "$LISTENER_ID" ] && ! echo "$LISTENER_ID" | grep -qE '^[a-zA-Z0-9_-]+$'; then
            echo "  Invalid: use only letters, numbers, hyphens, underscores"
            LISTENER_ID=""
        fi
    done

    prompt LISTENER_LOCATION "  Enter listener location (e.g. Montreal, QC): "
    LISTENER_LOCATION="${LISTENER_LOCATION:-Unknown}"

    prompt LISTENER_OWNER "  Enter owner name (e.g. J. Smith): "
    LISTENER_OWNER="${LISTENER_OWNER:-Unknown}"

    # Enable dongle 2 only if a second one was actually detected in step 4.
    # The daemon reads these flags -- leaving DONGLE2 enabled on a one-dongle
    # listener puts rtl_airband into a permanent restart loop.
    if [ "${DONGLE_COUNT:-0}" -ge 2 ]; then
        DONGLE2_ENABLED_VALUE=true
    else
        DONGLE2_ENABLED_VALUE=false
    fi
    log_info "Configuring for ${DONGLE_COUNT:-0} dongle(s) (dongle 2 enabled: $DONGLE2_ENABLED_VALUE)"

    # Write initial config (API key and central URL added in step 9)
    cat > "$LISTENER_CONF" << CONFEOF
# ============================================================
# PageVault Listener Configuration
# ============================================================

# Listener identification
LISTENER_ID="${LISTENER_ID}"
LISTENER_LOCATION="${LISTENER_LOCATION}"
LISTENER_OWNER="${LISTENER_OWNER}"

# Dongle 1 -- 929 MHz cluster
DONGLE1_SERIAL="929MHz"
DONGLE1_ENABLED=true

# Dongle 2 -- 931 MHz cluster
DONGLE2_SERIAL="931MHz"
DONGLE2_ENABLED=${DONGLE2_ENABLED_VALUE}

# Central dashboard server (set by self-registration)
CENTRAL_URL=""
CENTRAL_API_KEY=""

# Remote transfer settings (set by self-registration)
REMOTE_USER=""
REMOTE_HOST=""
REMOTE_DIR=""
TRANSFER_ENABLED=false
CONFEOF

    # Contains the central API key once registration completes
    chmod 600 "$LISTENER_CONF"

    log_info "Created listener config with ID: $LISTENER_ID"
fi

# ----------------------------------------------------------
# STEP 9: Self-registration with central server
# ----------------------------------------------------------

log_info "Step 9/11: Server registration"

source "$LISTENER_CONF"

if [ -n "$CENTRAL_API_KEY" ] && [ "$CENTRAL_API_KEY" != "" ]; then
    log_info "Already registered with central server, skipping"
else
    echo ""
    echo "============================================================"
    echo "  Register with Central Server"
    echo "============================================================"
    echo ""
    echo "  You need a registration token from the PageVault admin."
    echo "  The admin generates one on the server with:"
    echo "    sudo pagevault-generate-token"
    echo ""
    echo "  Leave blank to skip (you can register later)."
    echo ""

    prompt REG_TOKEN "  Enter registration token (or press Enter to skip): "

    if [ -n "$REG_TOKEN" ]; then
        # Ask for server URL if not already known
        prompt SERVER_URL "  Enter server URL (default: https://pagevault.yoshee.me): "
        SERVER_URL="${SERVER_URL:-https://pagevault.yoshee.me}"
        # Strip trailing slash
        SERVER_URL="${SERVER_URL%/}"
        REG_URL="${SERVER_URL}/api/register.php"

        # Generate SSH key for file transfer if it doesn't exist
        SSH_KEY="$HOME/.ssh/pagevault_upload"
        mkdir -p "$HOME/.ssh"
        chmod 700 "$HOME/.ssh"
        if [ ! -f "$SSH_KEY" ]; then
            ssh-keygen -t ed25519 -f "$SSH_KEY" -N "" -C "pagevault-${LISTENER_ID}" > /dev/null 2>&1
            log_info "Generated SSH key: $SSH_KEY"
        fi

        SSH_PUBKEY=$(cat "${SSH_KEY}.pub")

        # Build JSON safely using python3 (avoids issues with special chars in SSH key)
        JSON_PAYLOAD=$(python3 -c "
import json, sys
print(json.dumps({
    'token': sys.argv[1],
    'listener_id': sys.argv[2],
    'location': sys.argv[3],
    'owner': sys.argv[4],
    'ssh_pubkey': sys.argv[5],
}))
" "$REG_TOKEN" "$LISTENER_ID" "$LISTENER_LOCATION" "$LISTENER_OWNER" "$SSH_PUBKEY")

        # Call registration API. `set -e` would abort the whole run on a
        # failed command substitution, so capture the exit status instead --
        # an unreachable server should fall through to the "register later"
        # path below, not tear down a completed install.
        CURL_RC=0
        RESPONSE=$(curl -s --connect-timeout 10 --max-time 60 -X POST \
            -H "Content-Type: application/json" \
            -d "$JSON_PAYLOAD" \
            "$REG_URL") || CURL_RC=$?

        # Parse response
        STATUS=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status',''))" 2>/dev/null || echo "")
        API_KEY=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('api_key',''))" 2>/dev/null || echo "")
        HEARTBEAT_URL=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('heartbeat_url',''))" 2>/dev/null || echo "")
        SFTP_USER=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('sftp_user',''))" 2>/dev/null || echo "")
        SFTP_HOST=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('sftp_host',''))" 2>/dev/null || echo "")
        ERROR_MSG=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error',''))" 2>/dev/null || echo "unknown error")

        if [ "$CURL_RC" -ne 0 ]; then
            log_error "Could not reach $REG_URL (curl exit $CURL_RC)"
            log_warn "Register later by re-running setup once the server is reachable"
        elif [ "$STATUS" = "ok" ] && [ -n "$API_KEY" ]; then
            log_info "Registration successful!"

            # Update listener.conf with server details
            sed -i "s|^CENTRAL_URL=.*|CENTRAL_URL=\"$HEARTBEAT_URL\"|" "$LISTENER_CONF"
            sed -i "s|^CENTRAL_API_KEY=.*|CENTRAL_API_KEY=\"$API_KEY\"|" "$LISTENER_CONF"
            sed -i "s|^REMOTE_USER=.*|REMOTE_USER=\"$SFTP_USER\"|" "$LISTENER_CONF"
            sed -i "s|^REMOTE_HOST=.*|REMOTE_HOST=\"$SFTP_HOST\"|" "$LISTENER_CONF"
            sed -i "s|^REMOTE_DIR=.*|REMOTE_DIR=\"/var/pagevault/logs\"|" "$LISTENER_CONF"
            sed -i "s|^TRANSFER_ENABLED=.*|TRANSFER_ENABLED=true|" "$LISTENER_CONF"

            chmod 600 "$LISTENER_CONF"

            log_info "Config updated with API key and server details"
            log_info "Heartbeat URL: $HEARTBEAT_URL"
            log_info "SFTP: $SFTP_USER@$SFTP_HOST"

            # Pre-accept VPS host key so sftp doesn't prompt in cron
            if [ -n "$SFTP_HOST" ]; then
                if ssh-keyscan -H "$SFTP_HOST" >> "$HOME/.ssh/known_hosts" 2>/dev/null; then
                    log_info "VPS host key added to known_hosts"
                else
                    log_warn "Could not fetch host key for $SFTP_HOST -- first sftp run may fail"
                fi
            fi

            # Re-source the updated config
            source "$LISTENER_CONF"
        else
            log_error "Registration failed: $ERROR_MSG"
            log_warn "You can register later by re-running setup or manually editing listener.conf"
        fi
    else
        log_warn "Skipping registration -- edit listener.conf manually later or re-run setup"
    fi
fi

# ----------------------------------------------------------
# STEP 10: Set up cron jobs
# ----------------------------------------------------------

log_info "Step 10/11: Configuring cron jobs"

source "$LISTENER_CONF" 2>/dev/null || true

CRON_CHANGED=false

# Status push cron (every 30 seconds)
if [ -n "$CENTRAL_URL" ] && [ "$CENTRAL_URL" != "" ]; then
    PUSH_SCRIPT="$PAGEVAULT_SCRIPTS/push_status.sh"

    if [ -f "$PUSH_SCRIPT" ]; then
        if crontab -l 2>/dev/null | grep -q "push_status.sh"; then
            log_info "Status push cron already configured"
        else
            (crontab -l 2>/dev/null; echo "# PageVault -- push status to central dashboard every 30s") | crontab -
            (crontab -l 2>/dev/null; echo "* * * * * $PUSH_SCRIPT >> $PAGEVAULT_STATE/push.log 2>&1") | crontab -
            (crontab -l 2>/dev/null; echo "* * * * * sleep 30 && $PUSH_SCRIPT >> $PAGEVAULT_STATE/push.log 2>&1") | crontab -
            CRON_CHANGED=true
            log_info "Status push cron configured (every 30s)"
        fi
    else
        log_warn "push_status.sh not found -- skipping status push cron"
    fi
else
    log_info "No central dashboard URL configured -- skipping status push cron"
fi

# Log transfer cron (daily at 00:05 UTC)
TRANSFER_SCRIPT="$PAGEVAULT_SCRIPTS/transfer_logs.sh"

if [ -f "$TRANSFER_SCRIPT" ]; then
    source "$LISTENER_CONF" 2>/dev/null || true

    if [ "${TRANSFER_ENABLED:-false}" = "true" ] && [ -n "$REMOTE_HOST" ]; then
        if crontab -l 2>/dev/null | grep -q "transfer_logs.sh"; then
            log_info "Log transfer cron already configured"
        else
            (crontab -l 2>/dev/null; echo "# PageVault -- transfer completed logs daily at 00:05 UTC") | crontab -
            (crontab -l 2>/dev/null; echo "5 0 * * * $TRANSFER_SCRIPT >> $PAGEVAULT_STATE/transfer.log 2>&1") | crontab -
            CRON_CHANGED=true
            log_info "Log transfer cron configured (daily at 00:05 UTC)"
        fi
    else
        log_info "Log transfer not enabled -- skipping transfer cron"
    fi
else
    log_info "transfer_logs.sh not found -- skipping transfer cron"
fi

if [ "$CRON_CHANGED" = true ]; then
    log_info "Cron jobs installed. Verify with: crontab -l"
fi

# ----------------------------------------------------------
# STEP 11: Start the daemon
# ----------------------------------------------------------

log_info "Step 11/11: Daemon startup"

# Resolve the daemon the same way the control script does -- newest by
# version -- so shipping a new daemon never needs a constant bumped here.
DAEMON_SCRIPT=$(ls "$PAGEVAULT_SCRIPTS"/pagevault_daemon_v*.py 2>/dev/null | sort -V | tail -1)

if [ -z "$DAEMON_SCRIPT" ]; then
    log_warn "No daemon script found in $PAGEVAULT_SCRIPTS -- cannot start"
else
    log_info "Daemon: $(basename "$DAEMON_SCRIPT")"

    # Startup is handled by a systemd user unit, not @reboot cron.
    #
    # The daemon drives pactl and parec, so it needs a live PulseAudio/PipeWire
    # session. A cron job has neither XDG_RUNTIME_DIR nor DBUS_SESSION_BUS_ADDRESS
    # and runs with a PATH that excludes /usr/local/bin, where rtl_airband is
    # installed -- so the old @reboot entry could not have worked. A user unit
    # gets the session and a correct PATH; lingering brings that session up at
    # boot without requiring anyone to log in.

    # Drop the obsolete cron auto-start from earlier installs either way
    if crontab -l 2>/dev/null | grep -q "@reboot.*pagevault"; then
        crontab -l 2>/dev/null \
            | grep -v "@reboot.*pagevault" \
            | grep -v "auto-start daemon on boot" \
            | crontab -
        log_info "Removed obsolete @reboot cron auto-start (superseded by systemd)"
    fi

    if command -v systemctl > /dev/null 2>&1 && systemctl --user show-environment > /dev/null 2>&1; then
        SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
        UNIT_FILE="$SYSTEMD_USER_DIR/pagevault.service"

        mkdir -p "$SYSTEMD_USER_DIR"
        cat > "$UNIT_FILE" << UNITEOF
[Unit]
Description=PageVault listener daemon
After=default.target pipewire-pulse.service pulseaudio.service

[Service]
Type=simple
ExecStart=/usr/local/bin/pagevault run
Restart=always
RestartSec=10
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[Install]
WantedBy=default.target
UNITEOF

        systemctl --user daemon-reload || log_warn "systemctl --user daemon-reload failed"
        log_info "Installed systemd user unit: $UNIT_FILE"

        echo ""
        prompt AUTO_START "  Enable auto-start on boot? (y/n): "
        if [ "$AUTO_START" = "y" ] || [ "$AUTO_START" = "Y" ]; then
            if systemctl --user enable pagevault.service > /dev/null 2>&1; then
                # Without lingering, the user session -- and PipeWire with it --
                # only starts at graphical login, so a headless box never comes up
                if sudo loginctl enable-linger "$USER" 2>/dev/null; then
                    log_info "Auto-start enabled (lingering on: starts at boot without login)"
                else
                    log_warn "Unit enabled, but could not turn on lingering for $USER"
                    log_warn "The daemon will only start after a graphical login"
                fi
            else
                log_warn "Could not enable pagevault.service"
            fi
        fi
    else
        log_warn "No systemd user session available -- skipping auto-start setup"
        log_warn "Start the daemon manually with: pagevault start"
    fi

    echo ""
    prompt START_NOW "  Start the daemon now? (y/n): "
    if [ "$START_NOW" = "y" ] || [ "$START_NOW" = "Y" ]; then
        # A failed (or already-running) start must not abort setup before the summary
        "$PAGEVAULT_SCRIPTS/pagevault" start || log_warn "Daemon did not start -- check: pagevault status"
    fi
fi

# ============================================================
# SUMMARY
# ============================================================

echo ""
echo "============================================================"
echo "  PageVault Listener Setup Complete"
echo "============================================================"
echo ""
echo "  Install location:  $PAGEVAULT_HOME"
echo "  Scripts:           $PAGEVAULT_SCRIPTS"
echo "  Config:            $LISTENER_CONF"
echo "  Logs:              $PAGEVAULT_HOME/logs/"
echo "  State:             $PAGEVAULT_STATE/"
echo ""

if pgrep -f pagevault_daemon > /dev/null; then
    echo "  Daemon: RUNNING (PID: $(pgrep -f pagevault_daemon | head -1))"
else
    echo "  Start the daemon:"
    echo "     pagevault start"
fi

echo ""
echo "  Commands:"
echo "     pagevault start     Start the daemon"
echo "     pagevault stop      Stop the daemon"
echo "     pagevault restart   Restart the daemon"
echo "     pagevault status    Show current status"
echo "     pagevault update    Pull latest scripts and restart"

echo ""
echo "  Check status:"
echo "     watch -n 5 cat $PAGEVAULT_STATE/status.txt"
echo ""
echo "  To update scripts later:"
echo "     pagevault update"
echo ""

if [ -f "$HOME/.config/systemd/user/pagevault.service" ]; then
    if systemctl --user is-enabled pagevault.service > /dev/null 2>&1; then
        echo "  Auto-start: ENABLED (systemd user unit)"
        if ! loginctl show-user "$USER" -p Linger 2>/dev/null | grep -q "Linger=yes"; then
            echo -e "  ${YELLOW}NOTE: lingering is off -- daemon starts only after login${NC}"
        fi
    else
        echo "  Auto-start: not enabled (systemctl --user enable pagevault.service)"
    fi
    echo "  Unit logs: journalctl --user -u pagevault -f"
    echo ""
fi

if ! groups "$USER" | grep -q "plugdev"; then
    echo -e "  ${YELLOW}IMPORTANT: Log out and back in for USB permissions${NC}"
    echo ""
fi

echo "============================================================"
