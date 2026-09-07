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
#  11. Optionally starts daemon and enables auto-start on boot
#
# Usage:
#   ./setup.sh                     # Full setup
#   ./setup.sh --update            # Pull latest scripts only
#   ./setup.sh --help              # Show this help
#
# Prerequisites:
#   - Ubuntu 26.04 LTS (desktop with PipeWire/PulseAudio)
#   - Internet access
#   - sudo privileges
#   - Registration token from the PageVault admin
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
DAEMON_VERSION="v2_8"
PAGEVAULT_HOME="$HOME/pagevault"
PAGEVAULT_SCRIPTS="$PAGEVAULT_HOME/scripts"
PAGEVAULT_CONFIG="$PAGEVAULT_HOME/config"
PAGEVAULT_STATE="$PAGEVAULT_HOME/state"
AIRBAND_BUILD_DIR="$HOME/RTLSDR-Airband"

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

    TEMP_REPO="/tmp/pagevault-repo-$$"
    git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$TEMP_REPO" 2>/dev/null

    if [ -d "$TEMP_REPO/scripts" ]; then
        cp -r "$TEMP_REPO/scripts/"* "$PAGEVAULT_SCRIPTS/"
        chmod +x "$PAGEVAULT_SCRIPTS/"*.py "$PAGEVAULT_SCRIPTS/"*.sh 2>/dev/null || true
        [ -f "$PAGEVAULT_SCRIPTS/pagevault" ] && chmod +x "$PAGEVAULT_SCRIPTS/pagevault"
        log_info "Scripts updated from repository"
    else
        log_warn "No scripts directory found in repository"
    fi

    rm -rf "$TEMP_REPO"
    echo ""
    log_info "Update complete"
    exit 0
fi

# ----------------------------------------------------------
# STEP 1: Install system dependencies
# ----------------------------------------------------------

log_info "Step 1/11: Installing system dependencies"

sudo apt update -qq

sudo apt install -y -qq \
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
    > /dev/null 2>&1

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

TEMP_REPO="/tmp/pagevault-repo-$$"

if echo "$REPO_URL" | grep -q "CHANGEME"; then
    log_warn "Repository URL not configured in setup.sh"
    log_warn "Skipping script pull -- copy scripts manually to $PAGEVAULT_SCRIPTS/"
else
    git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$TEMP_REPO" 2>/dev/null

    if [ -d "$TEMP_REPO/scripts" ]; then
        cp -r "$TEMP_REPO/scripts/"* "$PAGEVAULT_SCRIPTS/"
        chmod +x "$PAGEVAULT_SCRIPTS/"*.py "$PAGEVAULT_SCRIPTS/"*.sh 2>/dev/null || true
        # Also chmod scripts without extensions (e.g. the 'pagevault' control script)
        [ -f "$PAGEVAULT_SCRIPTS/pagevault" ] && chmod +x "$PAGEVAULT_SCRIPTS/pagevault"
        log_info "Scripts pulled from repository"
    else
        log_warn "No scripts directory found in repository"
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
else
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
        read -p "  Enter listener ID: " LISTENER_ID
        if ! echo "$LISTENER_ID" | grep -qE '^[a-zA-Z0-9_-]+$'; then
            echo "  Invalid: use only letters, numbers, hyphens, underscores"
            LISTENER_ID=""
        fi
    done

    read -p "  Enter listener location (e.g. Montreal, QC): " LISTENER_LOCATION
    LISTENER_LOCATION="${LISTENER_LOCATION:-Unknown}"

    read -p "  Enter owner name (e.g. J. Smith): " LISTENER_OWNER
    LISTENER_OWNER="${LISTENER_OWNER:-Unknown}"

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
DONGLE2_ENABLED=false

# Central dashboard server (set by self-registration)
CENTRAL_URL=""
CENTRAL_API_KEY=""

# Remote transfer settings (set by self-registration)
REMOTE_USER=""
REMOTE_HOST=""
REMOTE_DIR=""
TRANSFER_ENABLED=false
CONFEOF

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

    read -p "  Enter registration token (or press Enter to skip): " REG_TOKEN

    if [ -n "$REG_TOKEN" ]; then
        # Ask for server URL if not already known
        read -p "  Enter server URL (default: https://pagevault.yoshee.me): " SERVER_URL
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

        # Call registration API
        RESPONSE=$(curl -s -X POST \
            -H "Content-Type: application/json" \
            -d "$JSON_PAYLOAD" \
            "$REG_URL")

        # Parse response
        STATUS=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('status',''))" 2>/dev/null || echo "")
        API_KEY=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('api_key',''))" 2>/dev/null || echo "")
        HEARTBEAT_URL=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('heartbeat_url',''))" 2>/dev/null || echo "")
        SFTP_USER=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('sftp_user',''))" 2>/dev/null || echo "")
        SFTP_HOST=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('sftp_host',''))" 2>/dev/null || echo "")
        ERROR_MSG=$(echo "$RESPONSE" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error',''))" 2>/dev/null || echo "unknown error")

        if [ "$STATUS" = "ok" ] && [ -n "$API_KEY" ]; then
            log_info "Registration successful!"

            # Update listener.conf with server details
            sed -i "s|^CENTRAL_URL=.*|CENTRAL_URL=\"$HEARTBEAT_URL\"|" "$LISTENER_CONF"
            sed -i "s|^CENTRAL_API_KEY=.*|CENTRAL_API_KEY=\"$API_KEY\"|" "$LISTENER_CONF"
            sed -i "s|^REMOTE_USER=.*|REMOTE_USER=\"$SFTP_USER\"|" "$LISTENER_CONF"
            sed -i "s|^REMOTE_HOST=.*|REMOTE_HOST=\"$SFTP_HOST\"|" "$LISTENER_CONF"
            sed -i "s|^REMOTE_DIR=.*|REMOTE_DIR=\"/var/pagevault/logs\"|" "$LISTENER_CONF"
            sed -i "s|^TRANSFER_ENABLED=.*|TRANSFER_ENABLED=true|" "$LISTENER_CONF"

            log_info "Config updated with API key and server details"
            log_info "Heartbeat URL: $HEARTBEAT_URL"
            log_info "SFTP: $SFTP_USER@$SFTP_HOST"

            # Pre-accept VPS host key so sftp doesn't prompt in cron
            if [ -n "$SFTP_HOST" ]; then
                ssh-keyscan -H "$SFTP_HOST" >> "$HOME/.ssh/known_hosts" 2>/dev/null
                log_info "VPS host key added to known_hosts"
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

DAEMON_SCRIPT="$PAGEVAULT_SCRIPTS/pagevault_daemon_${DAEMON_VERSION}.py"

if [ -f "$DAEMON_SCRIPT" ]; then
    echo ""
    read -p "  Start the daemon now? (y/n): " START_NOW
    if [ "$START_NOW" = "y" ] || [ "$START_NOW" = "Y" ]; then
        "$PAGEVAULT_SCRIPTS/pagevault" start
    fi

    # Auto-start on boot
    read -p "  Enable auto-start on boot? (y/n): " AUTO_START
    if [ "$AUTO_START" = "y" ] || [ "$AUTO_START" = "Y" ]; then
        if crontab -l 2>/dev/null | grep -q "pagevault_daemon"; then
            log_info "Auto-start already configured"
        else
            (crontab -l 2>/dev/null; echo "# PageVault -- auto-start daemon on boot (60s delay for system init)") | crontab -
            (crontab -l 2>/dev/null; echo "@reboot sleep 60 && /usr/local/bin/pagevault start >> $PAGEVAULT_STATE/daemon.log 2>&1") | crontab -
            log_info "Auto-start on boot configured (60s delay after boot)"
        fi
    fi
else
    log_warn "Daemon script not found at $DAEMON_SCRIPT -- cannot start"
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

echo ""
echo "  Check status:"
echo "     watch -n 5 cat $PAGEVAULT_STATE/status.txt"
echo ""
echo "  To update scripts later:"
echo "     $PAGEVAULT_SCRIPTS/update.sh"
echo ""

if ! groups "$USER" | grep -q "plugdev"; then
    echo -e "  ${YELLOW}IMPORTANT: Log out and back in for USB permissions${NC}"
    echo ""
fi

echo "============================================================"
