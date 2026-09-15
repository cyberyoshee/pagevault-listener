# PageVault

Pager network monitoring system for Canadian FLEX/POCSAG pager networks.

Captures, decodes, and logs pager traffic from multiple frequencies simultaneously using RTL-SDR hardware and RTLSDR-Airband multi-channel demodulation.

## Quick Setup

On a fresh Ubuntu 26.04 LTS machine with RTL-SDR dongle(s) plugged in:

```bash
curl -sL https://raw.githubusercontent.com/cyberyoshee/pagevault-listener/main/scripts/setup.sh | bash
```

Or clone and run:

```bash
git clone https://github.com/cyberyoshee/pagevault-listener.git
cd pagevault-listener/scripts
./setup.sh
```

## Commands

```
pagevault start      Start the daemon
pagevault stop       Stop the daemon
pagevault restart    Restart the daemon
pagevault status     Show current status
pagevault update     Pull latest scripts from repo
pagevault transfer [on|off]   Toggle uploading logs to the server
                              (with no argument, shows the current state)
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
| `scripts/pagevault_daemon_v2_11.py` | Main daemon |
| `scripts/push_status.sh` | Push status to central dashboard |
| `scripts/transfer_logs.sh` | Transfer logs to VPS via sftp |
| `scripts/status.sh` | Local status viewer |
| `scripts/update.sh` | Self-updating script puller |
| `scripts/convert_logs.py` | Convert old captures to daily format |
| `scripts/frequency_blocks.json` | Frequency block catalogue (edit to add coverage) |
| `scripts/pagevault_blocks.py` | Block catalogue loader/validator, shared by setup and daemon |

## Frequency blocks

A **block** is one dongle's worth of spectrum: a single center frequency with
every channel demodulated from that one tuner. Channels are grouped by
proximity because a dongle only covers so much at once (2.4 MHz reliably).

Setup configures dongles **one at a time** — attach one, pick its block, repeat.
With several attached at once the enumeration order is arbitrary, so there is no
way to tell which physical dongle, and therefore which antenna, is which. Each
dongle gets its block's serial written to its EEPROM, which is how the daemon
addresses it afterwards. Any number of dongles is supported, and a single-dongle
listener can pick whichever block it wants.

Blocks are defined in `scripts/frequency_blocks.json`. To add coverage, add a
block and check it with:

```bash
python3 scripts/pagevault_blocks.py validate
```

That enforces the rules the daemon relies on: channels inside the tuner span,
unique block ids, serials and channel names, and a serial short enough for the
EEPROM. Assignments are recorded in `config/dongles.conf`; re-run setup to
change them.

## Requirements

- Ubuntu 26.04 LTS (desktop with PipeWire/PulseAudio)
- RTL-SDR Blog V3 dongle(s)
- Internet access (for setup and dashboard push)
- Registration token from PageVault admin
