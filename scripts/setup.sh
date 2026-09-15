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
#   2. Verifies a PulseAudio/PipeWire session is actually reachable
#   3. Blacklists DVB kernel driver for RTL-SDR access
#   4. Configures USB permissions for non-root SDR access
#   5. Creates directory structure
#   6. Pulls latest PageVault scripts from the repository
#   7. Assigns a frequency block to each dongle, one dongle at a time
#   8. Builds and installs RTLSDR-Airband with NFM + PulseAudio
#   9. Creates listener config (interactive prompts)
#  10. Self-registers with central server (registration token)
#  11. Sets up cron jobs (status push, log transfer)
#  12. Optionally starts daemon and installs a systemd user unit
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
#   - The GitHub repo must be temporarily PUBLIC for setup to clone scripts;
#     setup aborts immediately if it cannot reach it anonymously
#
# ============================================================

set -e

# Catch errors and show where they happened
trap 'log_error "Setup failed at line $LINENO. Check output above for details."; exit 1' ERR

# ============================================================
# CONFIGURATION
# ============================================================

REPO_URL="https://github.com/cyberyoshee/pagevault-listener.git"
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
        log_error "  git clone $REPO_URL && ./pagevault-listener/scripts/setup.sh"
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

# Every code path that reaches scripts (this check, step 6's pull, and
# --update) does it by git-cloning REPO_URL anonymously. Against a private
# repo that clone doesn't just fail -- git tries a credential prompt first,
# which either hangs or garbles a `curl | bash` run. Check reachability up
# front, with prompting and hangs both disabled, so a private repo is one
# clear error instead of a confusing failure deep inside setup.
check_repo_public() {
    # git itself may not be preinstalled -- this runs before step 1's package
    # list, deliberately, so a private repo is caught before any real work.
    # Sudo access is already verified by the time this is called.
    if ! command -v git > /dev/null 2>&1; then
        log_info "Installing git (needed to check the repository)"
        sudo apt update -qq && sudo apt install -y -qq git \
            || { log_error "Could not install git"; exit 1; }
    fi

    log_info "Checking that the repository is public: $REPO_URL"
    if ! GIT_TERMINAL_PROMPT=0 timeout 15 git ls-remote "$REPO_URL" HEAD > /dev/null 2>&1; then
        log_error "Cannot reach $REPO_URL anonymously."
        log_error "Make the repository PUBLIC on GitHub for the duration of setup"
        log_error "(switch it back to private once setup finishes), then re-run setup."
        exit 1
    fi
    log_info "Repository is public and reachable"
}

# The whole decode pipeline runs through `pactl`/`parec` against whatever
# implements the PulseAudio protocol -- pipewire-pulse on a stock Ubuntu
# desktop, or classic pulseaudio. Without it, setup can still finish "green"
# while the daemon spins forever creating no sinks and decoding nothing. Check
# for a live session now, with a bounded timeout so a wedged server can't hang
# setup, and give a specific reason rather than just "pactl info failed".
check_audio_session() {
    local pulse_log
    if pulse_log=$(timeout 10 pactl info 2>&1); then
        log_info "Audio session OK: $(echo "$pulse_log" | grep '^Server Name' | cut -d: -f2- | sed 's/^ *//')"
        return 0
    fi

    log_error "Cannot reach a PulseAudio/PipeWire session ('pactl info' failed):"
    echo "$pulse_log" | sed 's/^/    /'
    echo ""

    if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
        log_error "XDG_RUNTIME_DIR is not set -- this shell has no active login session."
        log_error "Log into the desktop (directly, or over SSH once someone has logged"
        log_error "into the desktop at least once), then re-run setup."
    elif ! pgrep -x pipewire-pulse > /dev/null 2>&1 && ! pgrep -x pulseaudio > /dev/null 2>&1; then
        log_error "Neither pipewire-pulse nor pulseaudio is running for this user."
        log_error "Log into the graphical desktop session, then re-run setup."
    else
        log_error "A pulse server process is running but not answering. Check:"
        log_error "  systemctl --user status pipewire-pulse.service pulseaudio.service"
    fi

    exit 1
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
        head -40 "$0" | grep "^#" | sed 's/^# *//'
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

check_repo_public

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
    chmod 700 "$PAGEVAULT_HOME"
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

log_info "Step 1/12: Installing system dependencies"

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
    usbutils \
    openssh-client \
    > "$APT_LOG" 2>&1
then
    log_error "Package installation failed:"
    tail -30 "$APT_LOG"
    rm -f "$APT_LOG"
    exit 1
fi
rm -f "$APT_LOG"

# The daemon shells out to these directly, and step 6 depends on lsusb to
# detect dongles at all -- fail loudly here rather than leaving decoder
# chains to crash at runtime or dongle setup to silently see zero devices.
for bin in pactl parec sox multimon-ng rtl_test rtl_eeprom lsusb ssh-keygen sftp; do
    if ! command -v "$bin" > /dev/null 2>&1; then
        log_error "Required command '$bin' not found after package install"
        exit 1
    fi
done

log_info "System dependencies installed"

# ----------------------------------------------------------
# STEP 2: Verify PulseAudio/PipeWire audio session
# ----------------------------------------------------------

log_info "Step 2/12: Verifying PulseAudio/PipeWire audio session"

check_audio_session

# ----------------------------------------------------------
# STEP 3: Blacklist DVB kernel driver
# ----------------------------------------------------------

log_info "Step 3/12: Configuring kernel driver blacklist"

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
# STEP 4: USB permissions
# ----------------------------------------------------------

log_info "Step 4/12: Configuring USB permissions"

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
# STEP 5: Create directory structure
# ----------------------------------------------------------

log_info "Step 5/12: Creating directory structure"

mkdir -p "$PAGEVAULT_HOME/scripts"
mkdir -p "$PAGEVAULT_HOME/logs/processing"
mkdir -p "$PAGEVAULT_HOME/logs/ready"
mkdir -p "$PAGEVAULT_HOME/logs/archived"
mkdir -p "$PAGEVAULT_HOME/state"
mkdir -p "$PAGEVAULT_HOME/config"

# logs/ holds decoded pager traffic and config/ holds listener.conf's API key
# and dongles.conf -- none of that should be readable by other accounts on
# the box. mkdir's default mode plus Ubuntu's stock umask (002) leaves
# directories world-readable, so lock the whole tree down explicitly at the
# root rather than trust every subdirectory to inherit something tighter.
# Root (sudo steps) and the daemon's own systemd/cron jobs (which run as this
# same user, not root) are unaffected -- both already own or bypass this.
chmod 700 "$PAGEVAULT_HOME"

log_info "Directory structure created at $PAGEVAULT_HOME (mode 700 -- owner-only)"

# ----------------------------------------------------------
# STEP 6: Pull latest scripts from repository
# ----------------------------------------------------------

log_info "Step 6/12: Pulling latest scripts"

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
# STEP 7: Dongle configuration
# ----------------------------------------------------------

log_info "Step 7/12: Dongle configuration"

BLOCKS_PY="$PAGEVAULT_SCRIPTS/pagevault_blocks.py"
DONGLES_CONF="$PAGEVAULT_CONFIG/dongles.conf"

if [ ! -f "$BLOCKS_PY" ]; then
    log_error "Block catalogue tool missing: $BLOCKS_PY"
    log_error "The script pull in step 5 must have failed."
    exit 1
fi

if ! python3 "$BLOCKS_PY" validate; then
    log_error "Frequency block catalogue is invalid -- fix frequency_blocks.json"
    exit 1
fi

# Number of RTL-SDR devices currently on the USB bus
dongle_count() { lsusb | grep -c "0bda:2838" || true; }

# "<index><TAB><serial>" for every attached dongle
list_dongles() {
    timeout 5 rtl_test 2>&1 \
        | sed -n 's/^[[:space:]]*\([0-9]\{1,\}\):.*SN:[[:space:]]*\(.*\)$/\1\t\2/p' \
        | sed 's/[[:space:]]*$//'
}

# An EEPROM write only takes effect once the device re-enumerates
usb_reset_dongle() {
    local idx="$1" path
    path=$(lsusb | grep "0bda:2838" | sed -n "$((idx + 1))p" \
        | awk '{print "/dev/bus/usb/" $2 "/" $4}' | tr -d ':')
    if [ -n "$path" ] && [ -e "$path" ]; then
        sudo python3 -c "
import fcntl, os, sys
USBDEVFS_RESET = 21780
fd = os.open(sys.argv[1], os.O_WRONLY)
fcntl.ioctl(fd, USBDEVFS_RESET, 0)
os.close(fd)
" "$path" 2>/dev/null && return 0
    fi
    return 1
}

# Writes $2 to dongle $1's EEPROM (skipped if it already carries that serial,
# $3), resets the device so the new serial takes effect, and confirms some
# attached dongle now reports it. Shared by every path that assigns a block.
write_dongle_serial() {
    local idx="$1" target_serial="$2" current_serial="$3"

    if [ "$current_serial" = "$target_serial" ]; then
        log_info "Dongle already carries serial '$target_serial'"
        return 0
    fi

    log_info "Writing serial '$target_serial' to dongle $idx"
    rtl_eeprom -d "$idx" -s "$target_serial" > /dev/null 2>&1 <<< "y" || true

    if usb_reset_dongle "$idx"; then
        log_info "EEPROM written, USB reset complete"
    else
        log_warn "EEPROM written but the USB reset failed"
        prompt _REPLUG "  Unplug and replug this dongle, then press Enter: "
    fi
    sleep 2

    local verified=false vidx vser
    while IFS="$(printf '\t')" read -r vidx vser; do
        [ "$vser" = "$target_serial" ] && verified=true
    done < <(list_dongles)

    if [ "$verified" = true ]; then
        log_info "Verified: a dongle now reports serial '$target_serial'"
    else
        log_warn "Could not verify serial '$target_serial' -- the daemon may not find this dongle"
    fi
}

# Waits (up to 10s) for the attached-dongle count to rise above $2, then
# identifies whichever attached dongle's serial is not in $1 (newline
# separated). Sets NEW_DONGLE_INDEX/NEW_DONGLE_SERIAL and returns 0, or
# clears both and returns 1 if nothing new showed up.
detect_new_dongle() {
    local known_serials="$1" baseline="$2"
    local new_count=0 waited=0 idx ser
    NEW_DONGLE_INDEX=""
    NEW_DONGLE_SERIAL=""

    new_count=$(dongle_count)
    while [ "$new_count" -le "$baseline" ] && [ "$waited" -lt 10 ]; do
        sleep 1
        waited=$((waited + 1))
        new_count=$(dongle_count)
    done
    [ "$new_count" -gt "$baseline" ] || return 1

    while IFS="$(printf '\t')" read -r idx ser; do
        [ -n "$idx" ] || continue
        if ! printf '%s\n' "$known_serials" | grep -qxF "$ser"; then
            NEW_DONGLE_INDEX="$idx"
            NEW_DONGLE_SERIAL="$ser"
            return 0
        fi
    done < <(list_dongles)
    return 1
}

# Prints the block menu (excluding the comma list $1) and prompts for a
# choice. Sets CHOSEN_BLOCK_ID, or leaves it empty if nothing is left to offer.
prompt_block_choice() {
    local exclude="$1"
    local remaining bid blabel bdesc bnch bcentre bchans
    local menu_ids=() n=0 choice=""

    CHOSEN_BLOCK_ID=""
    remaining=$(python3 "$BLOCKS_PY" list --exclude "$exclude")
    [ -n "$remaining" ] || return 0

    echo ""
    echo "  Which frequency block should this dongle listen to?"
    echo ""
    while IFS="$(printf '\t')" read -r bid blabel bdesc bnch bcentre bchans; do
        [ -n "$bid" ] || continue
        n=$((n + 1))
        menu_ids+=("$bid")
        printf "    %d) %s -- %s\n" "$n" "$blabel" "$bdesc"
        printf "       %s channels centered on %s MHz\n" "$bnch" "$bcentre"
        printf "       %s\n\n" "$bchans"
    done <<< "$remaining"

    while [ -z "$choice" ]; do
        prompt choice "  Select block (1-$n): "
        if ! echo "$choice" | grep -qE '^[0-9]+$' \
            || [ "$choice" -lt 1 ] || [ "$choice" -gt "$n" ]; then
            echo "  Enter a number between 1 and $n"
            choice=""
        fi
    done
    CHOSEN_BLOCK_ID="${menu_ids[$((choice - 1))]}"
}

# ------------------------------------------------------------
# dongles.conf as in-memory parallel arrays: DC_BLOCK[i]/DC_SERIAL[i].
# Positions are renumbered 1..N on every save -- nothing else references
# them, so that's safe and keeps add/change/remove simple.
# ------------------------------------------------------------

load_dongles_conf() {
    DC_BLOCK=()
    DC_SERIAL=()
    [ -f "$DONGLES_CONF" ] || return 0
    # shellcheck disable=SC1090
    source "$DONGLES_CONF"
    local i bvar svar
    for i in $(seq 1 "${DONGLE_COUNT:-0}"); do
        bvar="DONGLE_${i}_BLOCK"
        svar="DONGLE_${i}_SERIAL"
        DC_BLOCK+=("${!bvar}")
        DC_SERIAL+=("${!svar}")
    done
}

save_dongles_conf() {
    mkdir -p "$PAGEVAULT_CONFIG"
    {
        echo "# ============================================================"
        echo "# PageVault Dongle Assignments"
        echo "# ============================================================"
        echo "#"
        echo "# Written by setup.sh -- one dongle per frequency block."
        echo "# Block definitions live in scripts/frequency_blocks.json."
        echo "#"
        echo "# The serials below are written into each dongle's EEPROM, so"
        echo "# re-run setup.sh to change assignments rather than editing"
        echo "# this file by hand."
        echo ""
        echo "DONGLE_COUNT=${#DC_BLOCK[@]}"
        local i
        for i in "${!DC_BLOCK[@]}"; do
            echo "DONGLE_$((i + 1))_BLOCK=\"${DC_BLOCK[$i]}\""
            echo "DONGLE_$((i + 1))_SERIAL=\"${DC_SERIAL[$i]}\""
        done
    } > "$DONGLES_CONF"
    log_info "Wrote $DONGLES_CONF (${#DC_BLOCK[@]} dongle(s))"
}

# Comma list of every currently-assigned block, optionally skipping index $1
# (0-based) -- used by "change" so an entry doesn't exclude its own block.
assigned_blocks_csv() {
    local skip="${1:--1}" out="" i
    for i in "${!DC_BLOCK[@]}"; do
        [ "$i" = "$skip" ] && continue
        out="${out:+$out,}${DC_BLOCK[$i]}"
    done
    printf '%s' "$out"
}

# Newline list of every currently-assigned serial.
assigned_serials_nl() {
    local i
    for i in "${!DC_SERIAL[@]}"; do
        printf '%s\n' "${DC_SERIAL[$i]}"
    done
}

# Attach-one/assign-one/repeat loop, shared by a full reconfigure and an
# incremental add. Assumes DC_BLOCK[]/DC_SERIAL[] already hold whatever
# should count as "already assigned" -- empty for a reconfigure, loaded from
# dongles.conf for an add -- and appends to them as dongles are configured.
assignment_loop() {
    local baseline block_serial
    while true; do
        if [ -z "$(python3 "$BLOCKS_PY" list --exclude "$(assigned_blocks_csv)")" ]; then
            echo ""
            log_info "Every block in the catalogue is now assigned"
            break
        fi

        echo ""
        echo "  ---- Dongle $((${#DC_BLOCK[@]} + 1)) ----"
        echo "  Attach the next dongle now, then press Enter."
        echo "  Or press Enter with nothing new attached to finish."
        baseline=$(dongle_count)
        prompt _GO "  > "

        if ! detect_new_dongle "$(assigned_serials_nl)" "$baseline"; then
            echo ""
            log_info "No new dongle detected -- finishing dongle configuration"
            break
        fi

        echo ""
        log_info "Detected dongle at index $NEW_DONGLE_INDEX (current serial: '$NEW_DONGLE_SERIAL')"

        prompt_block_choice "$(assigned_blocks_csv)"
        block_serial=$(python3 "$BLOCKS_PY" field "$CHOSEN_BLOCK_ID" serial)
        write_dongle_serial "$NEW_DONGLE_INDEX" "$block_serial" "$NEW_DONGLE_SERIAL"

        DC_BLOCK+=("$CHOSEN_BLOCK_ID")
        DC_SERIAL+=("$block_serial")
        log_info "Dongle ${#DC_BLOCK[@]} configured: block '$CHOSEN_BLOCK_ID'"
    done
}

reconfigure_all_dongles() {
    require_interactive "Dongle configuration"
    sudo rmmod dvb_usb_rtl28xxu 2>/dev/null || true

    echo ""
    echo "============================================================"
    echo "  Dongle Configuration -- Start Over"
    echo "============================================================"
    echo ""
    echo "  Each dongle is assigned one frequency block, and that block's"
    echo "  serial is written to the dongle's EEPROM so the daemon can"
    echo "  address it specifically."
    echo ""
    echo "  Dongles are configured ONE AT A TIME. With several attached"
    echo "  at once, enumeration order is arbitrary and there is no way"
    echo "  to tell which physical dongle -- and so which antenna -- is"
    echo "  which."
    echo ""

    # Start from a known state: nothing attached
    while [ "$(dongle_count)" -gt 0 ]; do
        log_warn "$(dongle_count) dongle(s) currently attached"
        prompt _UNPLUG "  Unplug ALL RTL-SDR dongles, then press Enter: "
        sleep 1
    done
    log_info "Starting with no dongles attached"

    DC_BLOCK=()
    DC_SERIAL=()
    assignment_loop

    if [ "${#DC_BLOCK[@]}" -eq 0 ]; then
        log_warn "No dongles configured -- the daemon will not start until at least one is"
    fi
    save_dongles_conf
}

add_dongles() {
    require_interactive "Dongle configuration"
    load_dongles_conf

    if [ -z "$(python3 "$BLOCKS_PY" list --exclude "$(assigned_blocks_csv)")" ]; then
        log_warn "Every block in the catalogue is already assigned to a dongle."
        log_warn "Add a new block to frequency_blocks.json first."
        return 0
    fi

    sudo rmmod dvb_usb_rtl28xxu 2>/dev/null || true

    echo ""
    echo "============================================================"
    echo "  Add Dongle(s)"
    echo "============================================================"
    echo ""
    echo "  Already-configured dongles can stay attached -- only the new"
    echo "  one needs to go in one at a time."
    echo ""

    assignment_loop
    save_dongles_conf
}

change_dongle_block() {
    require_interactive "Dongle configuration"
    load_dongles_conf

    if [ "${#DC_BLOCK[@]}" -eq 0 ]; then
        log_warn "No dongles configured yet"
        return 0
    fi

    echo ""
    echo "  Which dongle do you want to change?"
    echo ""
    local i choice sel current_serial found_idx idx ser block_serial
    for i in "${!DC_BLOCK[@]}"; do
        printf "    %d) block '%s' (serial %s)\n" "$((i + 1))" "${DC_BLOCK[$i]}" "${DC_SERIAL[$i]}"
    done

    choice=""
    while [ -z "$choice" ]; do
        prompt choice "  Select dongle (1-${#DC_BLOCK[@]}): "
        if ! echo "$choice" | grep -qE '^[0-9]+$' \
            || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#DC_BLOCK[@]}" ]; then
            echo "  Enter a number between 1 and ${#DC_BLOCK[@]}"
            choice=""
        fi
    done
    sel=$((choice - 1))
    current_serial="${DC_SERIAL[$sel]}"

    # This one is looked up by its known serial, not by "what's new", so it
    # has to actually be attached right now.
    found_idx=""
    while IFS="$(printf '\t')" read -r idx ser; do
        [ "$ser" = "$current_serial" ] && found_idx="$idx"
    done < <(list_dongles)

    if [ -z "$found_idx" ]; then
        log_error "No attached dongle currently reports serial '$current_serial'."
        log_error "Plug in the dongle for block '${DC_BLOCK[$sel]}' and try again."
        return 1
    fi

    prompt_block_choice "$(assigned_blocks_csv "$sel")"
    if [ -z "$CHOSEN_BLOCK_ID" ]; then
        log_warn "No other block available to switch to"
        return 0
    fi

    block_serial=$(python3 "$BLOCKS_PY" field "$CHOSEN_BLOCK_ID" serial)
    write_dongle_serial "$found_idx" "$block_serial" "$current_serial"

    DC_BLOCK[$sel]="$CHOSEN_BLOCK_ID"
    DC_SERIAL[$sel]="$block_serial"
    save_dongles_conf
    log_info "Dongle updated: now block '$CHOSEN_BLOCK_ID'"
}

remove_dongle() {
    require_interactive "Dongle configuration"
    load_dongles_conf

    if [ "${#DC_BLOCK[@]}" -eq 0 ]; then
        log_warn "No dongles configured yet"
        return 0
    fi

    echo ""
    echo "  Which dongle do you want to remove from the configuration?"
    echo ""
    local i choice sel
    for i in "${!DC_BLOCK[@]}"; do
        printf "    %d) block '%s' (serial %s)\n" "$((i + 1))" "${DC_BLOCK[$i]}" "${DC_SERIAL[$i]}"
    done

    choice=""
    while [ -z "$choice" ]; do
        prompt choice "  Select dongle (1-${#DC_BLOCK[@]}): "
        if ! echo "$choice" | grep -qE '^[0-9]+$' \
            || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#DC_BLOCK[@]}" ]; then
            echo "  Enter a number between 1 and ${#DC_BLOCK[@]}"
            choice=""
        fi
    done
    sel=$((choice - 1))

    log_info "Removing block '${DC_BLOCK[$sel]}' (serial ${DC_SERIAL[$sel]}) from the configuration"
    log_info "The dongle's EEPROM serial is left as-is -- it's free to be reassigned later"

    unset 'DC_BLOCK[sel]'
    unset 'DC_SERIAL[sel]'
    DC_BLOCK=("${DC_BLOCK[@]}")
    DC_SERIAL=("${DC_SERIAL[@]}")
    save_dongles_conf
}

if [ -f "$DONGLES_CONF" ]; then
    load_dongles_conf
    echo ""
    log_info "Existing dongle configuration (${#DC_BLOCK[@]} dongle(s)):"
    for _i in "${!DC_BLOCK[@]}"; do
        log_info "  $((_i + 1)). block '${DC_BLOCK[$_i]}' (serial ${DC_SERIAL[$_i]})"
    done

    if [ "$INTERACTIVE" != true ]; then
        echo ""
        log_info "Non-interactive run -- keeping existing dongle configuration"
    else
        echo ""
        echo "  What would you like to do?"
        echo "    1) Keep this configuration"
        echo "    2) Add a new dongle"
        echo "    3) Change a dongle's frequency block"
        echo "    4) Remove a dongle"
        echo "    5) Start over (reconfigure everything from scratch)"
        echo ""

        DONGLE_MENU_CHOICE=""
        while [ -z "$DONGLE_MENU_CHOICE" ]; do
            prompt DONGLE_MENU_CHOICE "  Select an option (1-5): "
            case "$DONGLE_MENU_CHOICE" in
                1|2|3|4|5) ;;
                *) echo "  Enter a number between 1 and 5"; DONGLE_MENU_CHOICE="" ;;
            esac
        done

        case "$DONGLE_MENU_CHOICE" in
            1) log_info "Keeping existing dongle configuration" ;;
            2) add_dongles ;;
            # change_dongle_block returns non-zero for a recoverable problem
            # (its target dongle isn't attached) -- under `set -e`, calling it
            # bare here would abort the whole setup run rather than just this
            # one menu action, so guard it explicitly.
            3) change_dongle_block || true ;;
            4) remove_dongle ;;
            5) reconfigure_all_dongles ;;
        esac
    fi
else
    reconfigure_all_dongles
fi

# ----------------------------------------------------------
# STEP 8: Build and install RTLSDR-Airband
# ----------------------------------------------------------

log_info "Step 8/12: Building RTLSDR-Airband"

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
# STEP 9: Create listener config if not exists
# ----------------------------------------------------------

log_info "Step 9/12: Checking listener configuration"

LISTENER_CONF="$PAGEVAULT_CONFIG/listener.conf"

if [ -f "$LISTENER_CONF" ]; then
    log_info "Listener config already exists, not overwriting"
    # Holds the central API key -- tighten perms on configs from older setups
    chmod 600 "$LISTENER_CONF"
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

    # Write initial config (API key and central URL added in step 9)
    cat > "$LISTENER_CONF" << CONFEOF
# ============================================================
# PageVault Listener Configuration
# ============================================================

# Listener identification
LISTENER_ID="${LISTENER_ID}"
LISTENER_LOCATION="${LISTENER_LOCATION}"
LISTENER_OWNER="${LISTENER_OWNER}"

# Dongle assignments live in config/dongles.conf, written by setup.sh.
# Frequency blocks are defined in scripts/frequency_blocks.json.

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
# STEP 10: Self-registration with central server
# ----------------------------------------------------------

log_info "Step 10/12: Server registration"

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

            # Decoded logs land in logs/ready/ regardless of this choice --
            # transfer is the only thing that leaves the machine. Letting
            # someone hold that off is a deliberate escape hatch to review a
            # few files locally before trusting the pipeline to ship them.
            echo ""
            echo "  Decoded logs are written locally either way. You can hold"
            echo "  off on uploading them until you've reviewed a few --"
            echo "  toggle this anytime later with: pagevault transfer on|off"
            echo ""
            prompt ENABLE_TRANSFER "  Enable automatic log file transfer now? (Y/n): "
            if [ "$ENABLE_TRANSFER" = "n" ] || [ "$ENABLE_TRANSFER" = "N" ]; then
                TRANSFER_ENABLED_VALUE=false
            else
                TRANSFER_ENABLED_VALUE=true
            fi

            # Update listener.conf with server details
            sed -i "s|^CENTRAL_URL=.*|CENTRAL_URL=\"$HEARTBEAT_URL\"|" "$LISTENER_CONF"
            sed -i "s|^CENTRAL_API_KEY=.*|CENTRAL_API_KEY=\"$API_KEY\"|" "$LISTENER_CONF"
            sed -i "s|^REMOTE_USER=.*|REMOTE_USER=\"$SFTP_USER\"|" "$LISTENER_CONF"
            sed -i "s|^REMOTE_HOST=.*|REMOTE_HOST=\"$SFTP_HOST\"|" "$LISTENER_CONF"
            sed -i "s|^REMOTE_DIR=.*|REMOTE_DIR=\"/var/pagevault/logs\"|" "$LISTENER_CONF"
            sed -i "s|^TRANSFER_ENABLED=.*|TRANSFER_ENABLED=$TRANSFER_ENABLED_VALUE|" "$LISTENER_CONF"

            chmod 600 "$LISTENER_CONF"

            if [ "$TRANSFER_ENABLED_VALUE" = false ]; then
                log_info "Log transfer left OFF -- review files in logs/ready/, then: pagevault transfer on"
            fi

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
# STEP 11: Set up cron jobs
# ----------------------------------------------------------

log_info "Step 11/12: Configuring cron jobs"

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
# STEP 12: Start the daemon
# ----------------------------------------------------------

log_info "Step 12/12: Daemon startup"

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
echo "     pagevault transfer [on|off]   Toggle uploading logs to the server"

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
