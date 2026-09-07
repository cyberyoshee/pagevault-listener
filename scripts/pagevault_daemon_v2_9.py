#!/usr/bin/env python3
"""
PageVault Daemon
================

VERSION: 2.9

CHANGELOG
---------
v2.9 (2026-09-07)
  - Dongles are now driven by DONGLE<N>_ENABLED in config/listener.conf
    instead of being unconditionally hardcoded. A single-dongle listener no
    longer spins rtl_airband and six decoder threads in a permanent restart
    loop for hardware it does not have.
  - DONGLE<N>_SERIAL in the config overrides the built-in serial
  - Config is read once at startup and passed down, not re-read per lookup

v2.8 (2026-09-06)
  - Message counters (per-channel and total) reset at midnight UTC
  - Dashboard always shows today's message count

v2.7 (2026-09-06)
  - Status file now includes raw ISO timestamp (last_at=) alongside human-readable (last=)
  - Also includes freq_hz per channel in status output
  - Enables push_status.sh to forward actual timestamps to the dashboard API

v2.6 (2026-09-05)
  - Added per-channel health monitoring
  - Status file now shows per-channel: process state, message count,
    last message time, and time since last message
  - Helps identify dead channels vs channels with no traffic

v2.5 (2026-09-05)
  - Enabled second dongle (931 MHz cluster, 6 channels)
  - Full 9-channel coverage: 3 channels on 929 MHz + 6 channels on 931 MHz

v2.4 (2026-09-05)
  - Daemon reads LISTENER_ID from config/listener.conf
  - Log filenames now include listener ID: <listener_id>_<freq>_<channel>_<date>.txt
  - Prevents filename collisions when multiple listeners upload to same server

v2.3 (2026-09-05)
  - Added error.log in state/ capturing stderr from parec, sox, and multimon-ng
  - Decoder chain crashes now log the exit codes and last stderr output

v2.2 (2026-09-03)
  - Added .fin file creation after moving log files to ready/
  - Signals to downstream processes that the data file is complete

v2.1 (2026-09-03)
  - FIX: Multi-line garbled FLEX messages now joined into single lines

v2.0 (2026-09-03)
  - Complete rewrite: switched from IQ record+decode to real-time pipeline
  - Uses rtl_airband for multi-channel demodulation from single dongle
  - PulseAudio routing: rtl_airband -> null sinks -> parec -> sox -> multimon-ng
  - Daemon reads multimon-ng stdout directly, writes to daily log files

v1.3 (2026-09-02)
  - FIX: Added inter-capture delay for USB release (obsolete in v2)

v1.2 (2026-09-02)
  - Moved daemon.log to state/, added processing/ready log dirs

v1.1 (2026-09-02)
  - FIX: rtl_sdr device selector syntax

v1.0 (2026-09-02)
  - Initial version (IQ capture approach - abandoned due to rtl_fm replay limitations)

DESCRIPTION
-----------
Real-time pager monitoring daemon. Uses rtl_airband to simultaneously
demodulate multiple FLEX pager channels from RTL-SDR dongles,
routes audio through PulseAudio null sinks, resamples with sox, and
decodes with multimon-ng. The daemon captures multimon-ng stdout and
writes to daily log files with automatic rotation.
"""

import os
import sys
import time
import signal
import logging
import threading
import subprocess
import shutil
from pathlib import Path
from datetime import datetime, timezone
from queue import Queue, Empty

# ============================================================
# CONFIGURATION
# ============================================================

BASE_DIR = Path.home() / "pagevault"
LOGS_DIR = BASE_DIR / "logs"
LOGS_PROCESSING = LOGS_DIR / "processing"
LOGS_READY = LOGS_DIR / "ready"
STATE_DIR = BASE_DIR / "state"
CONFIG_DIR = BASE_DIR / "config"
DAEMON_LOG = STATE_DIR / "daemon.log"
ERROR_LOG = STATE_DIR / "error.log"

# rtl_airband sample rate for NFM output
AIRBAND_AUDIO_RATE = 16000

# multimon-ng expected sample rate
MULTIMON_RATE = 22050

# Watchdog
DISK_PAUSE_THRESHOLD_PCT = 80
WATCHDOG_CHECK_INTERVAL_SEC = 30

# ============================================================
# DONGLE AND CHANNEL CONFIGURATION
# ============================================================

DONGLES = [
    {
        "serial": "929MHz",
        "center_freq_mhz": 929.5,
        "gain": 49.6,
        "channels": [
            (929_187_500, "telepage", "pv_telepage"),
            (929_287_500, "pagenet", "pv_pagenet"),
            (929_662_500, "bell929", "pv_bell929"),
        ],
    },
    {
        "serial": "931MHz",
        "center_freq_mhz": 931.8,
        "gain": 49.6,
        "channels": [
            (931_612_500, "rogers1", "pv_rogers1"),
            (931_687_500, "rogers2", "pv_rogers2"),
            (931_737_500, "telus_bell", "pv_telus_bell"),
            (931_887_500, "bell931", "pv_bell931"),
            (931_937_500, "rogers3", "pv_rogers3"),
            (931_987_500, "rogers4", "pv_rogers4"),
        ],
    },
]

# ============================================================
# LOGGING SETUP
# ============================================================

def setup_logging():
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    logging.basicConfig(
        level=logging.INFO,
        format='%(asctime)s [%(levelname)s] %(threadName)s: %(message)s',
        handlers=[
            logging.FileHandler(DAEMON_LOG),
            logging.StreamHandler(sys.stdout),
        ]
    )
    return logging.getLogger("pagevault")

# ============================================================
# GLOBAL STATE
# ============================================================

class DaemonState:
    def __init__(self):
        self.running = True
        self.lock = threading.Lock()
        self.processes = []
        self.stats = {
            "started_at": datetime.now(timezone.utc).isoformat(),
            "messages_decoded": 0,
            "channels_active": 0,
        }
        self.channels = {}
        self.current_utc_date = datetime.now(timezone.utc).strftime("%Y%m%d")

    def check_midnight_reset(self):
        """Reset message counters if UTC date has changed."""
        today = datetime.now(timezone.utc).strftime("%Y%m%d")
        if today != self.current_utc_date:
            with self.lock:
                log.info(f"Midnight UTC reset: date changed from {self.current_utc_date} to {today}")
                self.current_utc_date = today
                self.stats["messages_decoded"] = 0
                for ch_name in self.channels:
                    self.channels[ch_name]["message_count"] = 0

state = DaemonState()
log = None

# ============================================================
# HELPER FUNCTIONS
# ============================================================

def ensure_directories():
    for d in [LOGS_DIR, LOGS_PROCESSING, LOGS_READY, STATE_DIR, CONFIG_DIR]:
        d.mkdir(parents=True, exist_ok=True)

def disk_usage_percent(path):
    stat = shutil.disk_usage(path)
    return (stat.used / stat.total) * 100

def timestamp_utc():
    return datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")

def write_error_log(channel_name, context, message):
    """Append an error entry to the error log file."""
    try:
        stamp = datetime.now(timezone.utc).isoformat()
        with open(ERROR_LOG, "a") as f:
            f.write(f"[{stamp}] [{channel_name}] {context}: {message}\n")
    except Exception:
        pass

# ============================================================
# CONFIGURATION FILE READER
# ============================================================

def read_listener_config():
    """Read listener.conf and return a dict of key=value pairs."""
    config_file = CONFIG_DIR / "listener.conf"
    config = {}

    if not config_file.exists():
        log.error(f"Config file not found: {config_file}")
        log.error("Run setup.sh first or create the config file manually")
        sys.exit(1)

    with open(config_file) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            if '=' in line:
                key, value = line.split('=', 1)
                key = key.strip()
                value = value.strip().strip('"').strip("'")
                config[key] = value

    return config

def get_listener_id(config):
    """Return LISTENER_ID from a parsed config. Exit if not set."""
    listener_id = config.get("LISTENER_ID", "").strip()

    if not listener_id:
        log.error("LISTENER_ID is not set in config/listener.conf")
        sys.exit(1)

    if listener_id == "CHANGEME":
        log.error("LISTENER_ID is still set to 'CHANGEME' in config/listener.conf")
        sys.exit(1)

    import re
    if not re.match(r'^[a-zA-Z0-9_-]+$', listener_id):
        log.error(f"LISTENER_ID contains invalid characters: '{listener_id}'")
        sys.exit(1)

    return listener_id

def get_enabled_dongles(config):
    """Filter DONGLES using the DONGLE<N>_* keys in listener.conf.

    Keys are positional and 1-indexed: DONGLE1_* describes DONGLES[0]. A dongle
    with no matching DONGLE<N>_ENABLED key defaults to enabled, so a config
    written before these keys existed keeps its old behaviour.
    """
    enabled = []

    for idx, dongle in enumerate(DONGLES, start=1):
        flag = config.get(f"DONGLE{idx}_ENABLED")
        if flag is not None and flag.strip().lower() != "true":
            log.info(f"Dongle {idx} ({dongle['serial']}) disabled in config, skipping")
            continue

        serial = config.get(f"DONGLE{idx}_SERIAL", "").strip()
        if serial and serial != dongle["serial"]:
            log.info(f"Dongle {idx}: serial overridden by config: '{serial}'")
            dongle = {**dongle, "serial": serial}

        enabled.append(dongle)

    if not enabled:
        log.error("No dongles enabled in config/listener.conf -- nothing to do")
        log.error("Set DONGLE1_ENABLED=true (and DONGLE2_ENABLED=true if fitted)")
        sys.exit(1)

    return enabled

# ============================================================
# PULSEAUDIO SETUP
# ============================================================

def create_pulse_sinks(dongle_config):
    """Create PulseAudio null sinks for each channel."""
    for freq_hz, channel_name, sink_name in dongle_config["channels"]:
        result = subprocess.run(
            ["pactl", "list", "short", "sinks"],
            capture_output=True, text=True
        )
        if sink_name in result.stdout:
            log.info(f"PulseAudio sink '{sink_name}' already exists")
            continue

        result = subprocess.run(
            ["pactl", "load-module", "module-null-sink",
             f"sink_name={sink_name}",
             f"sink_properties=device.description={sink_name}"],
            capture_output=True, text=True
        )
        if result.returncode == 0:
            log.info(f"Created PulseAudio sink '{sink_name}' for {channel_name} ({freq_hz} Hz)")
        else:
            log.error(f"Failed to create sink '{sink_name}': {result.stderr}")

def route_sink_inputs(dongle_config):
    """Move rtl_airband's sink inputs to the correct null sinks."""
    time.sleep(2)

    for freq_hz, channel_name, sink_name in dongle_config["channels"]:
        found = False
        for attempt in range(5):
            result = subprocess.run(
                ["pactl", "list", "sink-inputs"],
                capture_output=True, text=True
            )

            lines = result.stdout.split('\n')
            current_id = None
            for i, line in enumerate(lines):
                if "Sink Input #" in line:
                    current_id = line.split('#')[1].strip()
                if f'application.name = "{channel_name}"' in line and current_id:
                    move_result = subprocess.run(
                        ["pactl", "move-sink-input", current_id, sink_name],
                        capture_output=True, text=True
                    )
                    if move_result.returncode == 0:
                        log.info(f"Routed '{channel_name}' (input {current_id}) to sink '{sink_name}'")
                        found = True
                    else:
                        log.error(f"Failed to route '{channel_name}': {move_result.stderr}")
                    break

            if found:
                break
            else:
                log.warning(f"Stream '{channel_name}' not found yet, retrying ({attempt+1}/5)")
                time.sleep(2)

        if not found:
            log.error(f"Could not find or route stream '{channel_name}' after 5 attempts")

# ============================================================
# RTLSDR-AIRBAND CONFIG GENERATION
# ============================================================

def generate_airband_config(dongle_config):
    """Generate rtl_airband config file for one dongle."""
    config_path = CONFIG_DIR / f"airband_{dongle_config['serial']}.conf"

    channels_str = ""
    for freq_hz, channel_name, sink_name in dongle_config["channels"]:
        freq_mhz = freq_hz / 1_000_000
        channels_str += f"""
      {{
        freq = {freq_mhz};
        modulation = "nfm";
        outputs: (
          {{
            type = "pulse";
            name = "{channel_name}";
          }}
        );
      }},"""

    channels_str = channels_str.rstrip(',')

    config = f"""devices: (
  {{
    type = "rtlsdr";
    serial = "{dongle_config['serial']}";
    gain = {dongle_config['gain']};
    correction = 0;
    centerfreq = {dongle_config['center_freq_mhz']};
    channels: ({channels_str}
    );
  }}
);
"""
    with open(config_path, 'w') as f:
        f.write(config)

    log.info(f"Generated rtl_airband config: {config_path}")
    return config_path

# ============================================================
# LOG FILE MANAGEMENT
# ============================================================

def move_stale_logs(current_date):
    """Move log files with dates older than current_date from processing/ to ready/.
    Creates a .fin file for each moved file.
    """
    moved = []
    for f in LOGS_PROCESSING.glob("*.txt"):
        try:
            file_date = f.stem.split('_')[-1]
            if file_date < current_date:
                dest = LOGS_READY / f.name
                shutil.move(str(f), str(dest))
                fin_file = LOGS_READY / f"{f.name}.fin"
                fin_file.touch()
                moved.append(f.name)
        except (IndexError, ValueError):
            pass
    if moved:
        log.info(f"Moved {len(moved)} log file(s) to ready/ with .fin signals: {moved}")

def startup_scan_logs():
    """On startup, move any stale log files in processing/ to ready/."""
    today = datetime.now(timezone.utc).strftime("%Y%m%d")
    moved_count = 0
    for f in LOGS_PROCESSING.glob("*.txt"):
        try:
            file_date = f.stem.split('_')[-1]
            if file_date < today:
                dest = LOGS_READY / f.name
                shutil.move(str(f), str(dest))
                fin_file = LOGS_READY / f"{f.name}.fin"
                fin_file.touch()
                moved_count += 1
        except (IndexError, ValueError):
            pass
    if moved_count > 0:
        log.info(f"Startup scan: moved {moved_count} stale log file(s) to ready/ with .fin signals")

def get_log_file(listener_id, freq_hz, channel_name):
    """Get the current daily log file path, triggering rotation if needed."""
    today = datetime.now(timezone.utc).strftime("%Y%m%d")
    log_file = LOGS_PROCESSING / f"{listener_id}_{freq_hz}_{channel_name}_{today}.txt"

    if not log_file.exists():
        move_stale_logs(today)

    return log_file

# ============================================================
# DECODER WORKER THREAD
# ============================================================

def decoder_chain_thread(listener_id, freq_hz, channel_name, sink_name):
    """Run parec -> sox -> multimon-ng for one channel, capture output to daily log files."""
    log.info(f"Decoder chain started for {channel_name} ({freq_hz} Hz)")

    with state.lock:
        state.channels[channel_name] = {
            "freq_hz": freq_hz,
            "status": "starting",
            "message_count": 0,
            "last_message_at": None,
            "last_restart_at": None,
            "restart_count": 0,
            "pids": {},
        }

    while state.running:
        try:
            parec_cmd = [
                "parec",
                f"--device={sink_name}.monitor",
                "--rate=16000",
                "--channels=1",
                "--format=s16le",
                "--raw",
            ]

            sox_cmd = [
                "sox",
                "-t", "raw", "-r", "16000", "-e", "signed-integer", "-b", "16", "-c", "1", "-",
                "-t", "raw", "-r", "22050", "-e", "signed-integer", "-b", "16", "-c", "1", "-",
            ]

            multimon_cmd = [
                "multimon-ng",
                "-t", "raw",
                "-a", "FLEX",
                "-a", "POCSAG1200",
                "-a", "POCSAG512",
                "-a", "POCSAG2400",
                "-e",
                "-f", "alpha",
                "/dev/stdin",
            ]

            parec_proc = subprocess.Popen(parec_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            sox_proc = subprocess.Popen(sox_cmd, stdin=parec_proc.stdout, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            multimon_proc = subprocess.Popen(multimon_cmd, stdin=sox_proc.stdout, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

            parec_proc.stdout.close()
            sox_proc.stdout.close()

            with state.lock:
                state.processes.extend([parec_proc, sox_proc, multimon_proc])
                state.channels[channel_name]["status"] = "running"
                state.channels[channel_name]["pids"] = {
                    "parec": parec_proc.pid,
                    "sox": sox_proc.pid,
                    "multimon": multimon_proc.pid,
                }

            log.info(f"Decoder pipeline running for {channel_name}")

            current_message = None
            for line_bytes in multimon_proc.stdout:
                if not state.running:
                    break

                line = line_bytes.decode('utf-8', errors='replace').rstrip('\n').rstrip('\r')
                if not line:
                    continue

                if line.startswith("Enabled demodulators:"):
                    continue

                if line.startswith("FLEX") or line.startswith("POCSAG"):
                    if current_message is not None:
                        log_file = get_log_file(listener_id, freq_hz, channel_name)
                        with open(log_file, "a") as f:
                            f.write(current_message + "\n")
                        with state.lock:
                            state.stats["messages_decoded"] += 1
                            state.channels[channel_name]["message_count"] += 1
                            state.channels[channel_name]["last_message_at"] = datetime.now(timezone.utc).isoformat()
                    current_message = line
                else:
                    if current_message is not None:
                        cleaned = ''.join(c if c.isprintable() or c == ' ' else '' for c in line).strip()
                        if cleaned:
                            current_message += " " + cleaned

            if current_message is not None:
                log_file = get_log_file(listener_id, freq_hz, channel_name)
                with open(log_file, "a") as f:
                    f.write(current_message + "\n")

            # Pipeline exited -- collect exit codes and stderr
            exit_info = {}
            for name, proc in [("parec", parec_proc), ("sox", sox_proc), ("multimon-ng", multimon_proc)]:
                try:
                    proc.terminate()
                    proc.wait(timeout=5)
                except:
                    proc.kill()
                    proc.wait(timeout=5)
                rc = proc.returncode
                stderr_output = ""
                try:
                    stderr_output = proc.stderr.read().decode('utf-8', errors='replace').strip()
                except:
                    pass
                exit_info[name] = (rc, stderr_output)

            crash_details = " | ".join(
                f"{name}: rc={rc}, stderr='{stderr[:200]}'"
                for name, (rc, stderr) in exit_info.items()
                if rc != 0 or stderr
            )
            if crash_details:
                log.warning(f"Decoder chain for {channel_name} crashed: {crash_details}")
                write_error_log(channel_name, "DECODER_CRASH", crash_details)
            else:
                write_error_log(channel_name, "DECODER_EXIT", "All processes exited with rc=0, no stderr")

        except Exception as e:
            log.exception(f"Decoder chain error for {channel_name}: {e}")
            with state.lock:
                state.channels[channel_name]["status"] = "error"

        if state.running:
            with state.lock:
                state.channels[channel_name]["status"] = "restarting"
                state.channels[channel_name]["restart_count"] += 1
                state.channels[channel_name]["last_restart_at"] = datetime.now(timezone.utc).isoformat()
                state.channels[channel_name]["pids"] = {}
            log.warning(f"Decoder chain for {channel_name} exited, restarting in 5s")
            time.sleep(5)

    with state.lock:
        state.channels[channel_name]["status"] = "stopped"
    log.info(f"Decoder chain stopped for {channel_name}")

# ============================================================
# RTLSDR-AIRBAND MANAGER THREAD
# ============================================================

def airband_manager_thread(dongle_config):
    """Launch and monitor rtl_airband for one dongle."""
    serial = dongle_config["serial"]
    log.info(f"Airband manager started for dongle {serial}")

    while state.running:
        config_path = generate_airband_config(dongle_config)

        cmd = ["rtl_airband", "-f", "-e", "-c", str(config_path)]

        try:
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            with state.lock:
                state.processes.append(proc)

            log.info(f"rtl_airband started for {serial} (PID {proc.pid})")

            route_thread = threading.Thread(
                target=route_sink_inputs,
                args=(dongle_config,),
                name=f"route-{serial}",
                daemon=True
            )
            route_thread.start()

            for line_bytes in proc.stdout:
                if not state.running:
                    break

            proc.wait()
            log.warning(f"rtl_airband for {serial} exited with code {proc.returncode}")

        except Exception as e:
            log.exception(f"Airband manager error for {serial}: {e}")

        if state.running:
            log.warning(f"Restarting rtl_airband for {serial} in 10s")
            time.sleep(10)

    log.info(f"Airband manager stopped for {serial}")

# ============================================================
# WATCHDOG THREAD
# ============================================================

def watchdog_thread():
    """Monitor system health and write status file."""
    log.info("Watchdog started")

    while state.running:
        try:
            usage = disk_usage_percent(BASE_DIR)
            now = datetime.now(timezone.utc)

            # Check for midnight UTC rollover
            state.check_midnight_reset()

            status_file = STATE_DIR / "status.txt"
            with open(status_file, "w") as f:
                f.write(f"timestamp: {now.isoformat()}\n")
                f.write(f"disk_usage_pct: {usage:.1f}\n")
                f.write(f"processing_files: {len(list(LOGS_PROCESSING.glob('*.txt')))}\n")
                f.write(f"ready_files: {len(list(LOGS_READY.glob('*.txt')))}\n")
                for key, val in state.stats.items():
                    f.write(f"{key}: {val}\n")

                f.write(f"\n--- Channel Health ---\n")
                with state.lock:
                    for ch_name, ch_info in sorted(state.channels.items()):
                        status = ch_info["status"]
                        count = ch_info["message_count"]
                        last_msg = ch_info["last_message_at"]
                        restarts = ch_info["restart_count"]
                        pids = ch_info.get("pids", {})
                        freq_hz = ch_info.get("freq_hz", 0)

                        if last_msg:
                            last_dt = datetime.fromisoformat(last_msg)
                            ago_sec = (now - last_dt).total_seconds()
                            if ago_sec < 60:
                                ago_str = f"{ago_sec:.0f}s ago"
                            elif ago_sec < 3600:
                                ago_str = f"{ago_sec/60:.0f}m ago"
                            else:
                                ago_str = f"{ago_sec/3600:.1f}h ago"
                        else:
                            ago_str = "never"

                        pid_str = "/".join(str(p) for p in pids.values()) if pids else "none"
                        last_at_str = last_msg if last_msg else "never"
                        f.write(f"{ch_name}: status={status} msgs={count} last={ago_str} last_at={last_at_str} freq_hz={freq_hz} restarts={restarts} pids={pid_str}\n")

        except Exception as e:
            log.exception(f"Watchdog exception: {e}")

        time.sleep(WATCHDOG_CHECK_INTERVAL_SEC)

    log.info("Watchdog stopped")

# ============================================================
# SIGNAL HANDLING AND CLEANUP
# ============================================================

def signal_handler(signum, frame):
    log.info(f"Received signal {signum}, initiating shutdown")
    state.running = False

def cleanup():
    """Kill all subprocesses on shutdown."""
    log.info("Cleaning up subprocesses")
    with state.lock:
        for proc in state.processes:
            try:
                proc.terminate()
            except:
                pass
    time.sleep(2)
    with state.lock:
        for proc in state.processes:
            try:
                if proc.poll() is None:
                    proc.kill()
            except:
                pass

# ============================================================
# MAIN
# ============================================================

def main():
    global log

    ensure_directories()
    log = setup_logging()

    config = read_listener_config()
    listener_id = get_listener_id(config)
    dongles = get_enabled_dongles(config)

    log.info("=" * 60)
    log.info("PageVault daemon v2.9 starting")
    log.info(f"Listener ID: {listener_id}")
    log.info(f"Base directory: {BASE_DIR}")
    log.info(f"Dongles enabled: {len(dongles)} of {len(DONGLES)} configured")
    for d in dongles:
        log.info(f"  - {d['serial']}: {d['center_freq_mhz']} MHz, {len(d['channels'])} channels")
        for freq, name, sink in d['channels']:
            log.info(f"      {freq} Hz -> {name} (sink: {sink})")
    log.info(f"Log filename format: {listener_id}_<freq>_<channel>_<YYYYMMDD>.txt")
    log.info("Ctrl+C to stop")
    log.info("=" * 60)

    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)

    startup_scan_logs()

    threads = []

    t = threading.Thread(target=watchdog_thread, name="watchdog", daemon=True)
    t.start()
    threads.append(t)

    for dongle_config in dongles:
        create_pulse_sinks(dongle_config)

        t = threading.Thread(
            target=airband_manager_thread,
            args=(dongle_config,),
            name=f"airband-{dongle_config['serial']}",
            daemon=True
        )
        t.start()
        threads.append(t)

        for freq_hz, channel_name, sink_name in dongle_config["channels"]:
            t = threading.Thread(
                target=decoder_chain_thread,
                args=(listener_id, freq_hz, channel_name, sink_name),
                name=f"dec-{channel_name}",
                daemon=True
            )
            t.start()
            threads.append(t)
            with state.lock:
                state.stats["channels_active"] += 1

    try:
        while state.running:
            time.sleep(1)
    except KeyboardInterrupt:
        log.info("KeyboardInterrupt received")
        state.running = False

    cleanup()

    log.info("Shutting down, waiting for threads")
    for t in threads:
        t.join(timeout=10)

    log.info("PageVault daemon stopped")

if __name__ == "__main__":
    main()
