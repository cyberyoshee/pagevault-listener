#!/usr/bin/env python3
"""
PageVault frequency block catalogue
===================================

Shared loader for frequency_blocks.json, used by both the daemon (imported)
and setup.sh (invoked as a CLI, so the block menu is not duplicated in bash).

A block is one rtl_airband device: one center frequency, one physical dongle,
and every channel demodulated from that single tuner. Channels are grouped by
proximity because a dongle can only cover so much spectrum at once -- the
catalogue's max_span_mhz records that limit and validate_catalogue() enforces
it, so a badly grouped block fails at setup rather than silently producing a
dead channel on air.

CLI:
    pagevault_blocks.py list [--exclude id,id]   menu rows, tab separated
    pagevault_blocks.py ids                      block ids, one per line
    pagevault_blocks.py field <id> <field>       one field of one block
    pagevault_blocks.py validate                 check the catalogue, exit 1 on error
"""

import json
import sys
from pathlib import Path

CATALOGUE_NAME = "frequency_blocks.json"

# rtl_eeprom writes this into a small EEPROM region; keep it short
MAX_SERIAL_LEN = 16

# Channel names become PulseAudio sink names, and rtl_airband stream names
SINK_PREFIX = "pv_"


class CatalogueError(Exception):
    """Raised when the catalogue is missing, malformed, or internally inconsistent."""


def catalogue_path(explicit=None):
    """Locate frequency_blocks.json, preferring an explicit path."""
    if explicit:
        return Path(explicit)
    return Path(__file__).resolve().parent / CATALOGUE_NAME


def load_catalogue(path=None):
    """Read and validate the catalogue. Raises CatalogueError on any problem."""
    p = catalogue_path(path)

    if not p.exists():
        raise CatalogueError(f"Block catalogue not found: {p}")

    try:
        with open(p) as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        raise CatalogueError(f"Could not parse {p}: {e}")

    validate_catalogue(data)
    return data


def validate_catalogue(data):
    """Check every rule a block has to satisfy. Raises CatalogueError on the first failure."""
    if not isinstance(data, dict):
        raise CatalogueError("Catalogue root must be a JSON object")

    blocks = data.get("blocks")
    if not isinstance(blocks, list) or not blocks:
        raise CatalogueError("Catalogue must define a non-empty 'blocks' list")

    max_span_hz = float(data.get("max_span_mhz", 2.4)) * 1_000_000

    seen_ids = set()
    seen_serials = set()
    seen_channels = set()

    for block in blocks:
        bid = block.get("id")
        if not bid:
            raise CatalogueError("Every block needs an 'id'")
        if bid in seen_ids:
            raise CatalogueError(f"Duplicate block id: {bid}")
        seen_ids.add(bid)

        serial = block.get("serial")
        if not serial:
            raise CatalogueError(f"Block '{bid}' has no 'serial'")
        if len(serial) > MAX_SERIAL_LEN:
            raise CatalogueError(
                f"Block '{bid}' serial '{serial}' is {len(serial)} chars, "
                f"max {MAX_SERIAL_LEN}"
            )
        # A serial addresses one physical dongle, so two blocks sharing one
        # would make the two tuners indistinguishable to rtl_airband
        if serial in seen_serials:
            raise CatalogueError(f"Duplicate serial '{serial}' (block '{bid}')")
        seen_serials.add(serial)

        center = block.get("center_freq_mhz")
        if not isinstance(center, (int, float)):
            raise CatalogueError(f"Block '{bid}' has no numeric 'center_freq_mhz'")
        center_hz = float(center) * 1_000_000

        channels = block.get("channels")
        if not isinstance(channels, list) or not channels:
            raise CatalogueError(f"Block '{bid}' has no channels")

        freqs = []
        for ch in channels:
            name = ch.get("name")
            freq = ch.get("freq_hz")
            if not name:
                raise CatalogueError(f"Block '{bid}' has a channel with no name")
            if not isinstance(freq, (int, float)) or freq <= 0:
                raise CatalogueError(f"Channel '{name}' has no valid freq_hz")
            # Sink names are derived from channel names, so they must be
            # unique across the whole catalogue, not just within a block
            if name in seen_channels:
                raise CatalogueError(f"Duplicate channel name '{name}' (block '{bid}')")
            seen_channels.add(name)
            freqs.append(float(freq))

        # Every channel has to sit inside the tuner's usable span around center
        half_span = max_span_hz / 2
        for ch, freq in zip(channels, freqs):
            offset = abs(freq - center_hz)
            if offset > half_span:
                raise CatalogueError(
                    f"Block '{bid}': channel '{ch['name']}' is "
                    f"{offset / 1_000_000:.3f} MHz from center "
                    f"{center:.4f} MHz, beyond the {max_span_hz / 2_000_000:.2f} MHz "
                    f"half-span. Re-center the block or split it."
                )

        span = (max(freqs) - min(freqs)) / 1_000_000
        if span * 1_000_000 > max_span_hz:
            raise CatalogueError(
                f"Block '{bid}' spans {span:.3f} MHz, over the "
                f"{max_span_hz / 1_000_000:.2f} MHz limit. Split it into two blocks."
            )

    return True


def get_block(block_id, data=None):
    """Return one block by id, or raise CatalogueError."""
    data = data or load_catalogue()
    for block in data["blocks"]:
        if block["id"] == block_id:
            return block
    raise CatalogueError(f"No such block: '{block_id}'")


def block_span_mhz(block):
    """Width from lowest to highest channel, in MHz."""
    freqs = [float(c["freq_hz"]) for c in block["channels"]]
    return (max(freqs) - min(freqs)) / 1_000_000


def to_dongle_config(block, data=None):
    """Shape one block the way the daemon consumes a dongle.

    Channels become (freq_hz, channel_name, sink_name) tuples, matching what
    the airband config generator and the decoder threads expect.
    """
    data = data or {}
    gain = block.get("gain", data.get("default_gain", 49.6))
    return {
        "block_id": block["id"],
        "serial": block["serial"],
        "center_freq_mhz": float(block["center_freq_mhz"]),
        "gain": gain,
        "channels": [
            (int(c["freq_hz"]), c["name"], SINK_PREFIX + c["name"])
            for c in block["channels"]
        ],
    }


# ============================================================
# CLI -- consumed by setup.sh
# ============================================================

def _cmd_list(args):
    data = load_catalogue()
    exclude = set()
    if "--exclude" in args:
        raw = args[args.index("--exclude") + 1]
        exclude = {x for x in raw.split(",") if x}

    for block in data["blocks"]:
        if block["id"] in exclude:
            continue
        chans = ", ".join(c["name"] for c in block["channels"])
        # id \t label \t description \t n_channels \t center \t channel names
        print("\t".join([
            block["id"],
            block.get("label", block["id"]),
            block.get("description", ""),
            str(len(block["channels"])),
            f"{float(block['center_freq_mhz']):.4f}",
            chans,
        ]))
    return 0


def _cmd_ids(args):
    for block in load_catalogue()["blocks"]:
        print(block["id"])
    return 0


def _cmd_field(args):
    if len(args) < 2:
        print("usage: field <block_id> <field>", file=sys.stderr)
        return 2
    block = get_block(args[0])
    value = block.get(args[1])
    if value is None:
        print(f"Block '{args[0]}' has no field '{args[1]}'", file=sys.stderr)
        return 1
    print(value)
    return 0


def _cmd_validate(args):
    data = load_catalogue()
    n_ch = sum(len(b["channels"]) for b in data["blocks"])
    print(f"Catalogue OK: {len(data['blocks'])} block(s), {n_ch} channel(s)")
    for block in data["blocks"]:
        print(
            f"  {block['id']:<10} {block.get('label', ''):<22} "
            f"center {float(block['center_freq_mhz']):.4f} MHz  "
            f"span {block_span_mhz(block):.3f} MHz  "
            f"{len(block['channels'])} ch  serial {block['serial']}"
        )
    return 0


COMMANDS = {
    "list": _cmd_list,
    "ids": _cmd_ids,
    "field": _cmd_field,
    "validate": _cmd_validate,
}


def main(argv):
    if len(argv) < 2 or argv[1] not in COMMANDS:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    try:
        return COMMANDS[argv[1]](argv[2:])
    except CatalogueError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
