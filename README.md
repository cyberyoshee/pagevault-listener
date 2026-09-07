# PageVault

Pager network monitoring system for Canadian FLEX/POCSAG pager networks.

Captures, decodes, and logs pager traffic from multiple frequencies simultaneously using RTL-SDR hardware and RTLSDR-Airband multi-channel demodulation.

## Quick Setup

On a fresh Ubuntu 26.04 LTS machine with RTL-SDR dongle(s) plugged in:

```bash
curl -sL https://raw.githubusercontent.com/cyberyoshee/pagevault/main/scripts/setup.sh | bash
```

Or clone and run:

```bash
git clone https://github.com/cyberyoshee/pagevault.git
cd pagevault/scripts
./setup.sh
```

## Commands

```
pagevault start      Start the daemon
pagevault stop       Stop the daemon
pagevault restart    Restart the daemon
pagevault status     Show current status
pagevault update     Pull latest scripts from repo
```

## Architecture

```
RTL-SDR Dongle(s)
    |
    v
rtl_airband (multi-channel NFM demodulation)
    |
    v
PulseAudio null sinks (one per channel)
    |
    v
parec -> sox (resample 16kHz -> 22050Hz) -> multimon-ng (FLEX/POCSAG decode)
    |
    v
Python daemon (log writer, daily rotation, health monitoring)
    |
    v
Daily log files -> transferred to central VPS via sftp
```

## Components

| File | Purpose |
|---|---|
| `scripts/setup.sh` | Bootstrap listener from fresh Ubuntu install |
| `scripts/pagevault` | Daemon control (start/stop/restart/status/update) |
| `scripts/pagevault_daemon_v2_9.py` | Main daemon |
| `scripts/push_status.sh` | Push status to central dashboard |
| `scripts/transfer_logs.sh` | Transfer logs to VPS via sftp |
| `scripts/status.sh` | Local status viewer |
| `scripts/update.sh` | Self-updating script puller |
| `scripts/convert_logs.py` | Convert old captures to daily format |

## Requirements

- Ubuntu 26.04 LTS (desktop with PipeWire/PulseAudio)
- RTL-SDR Blog V3 dongle(s)
- Internet access (for setup and dashboard push)
- Registration token from PageVault admin
