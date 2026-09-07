#!/usr/bin/env python3
"""
PageVault Log Converter
Splits original multi-hour capture files into daily files
matching the current listener naming format.

Input:  pagers_20260823_142000.txt (single file, many hours)
Output: mtl-01_929287500_pagenet_20260823.txt (one per UTC day)

Usage:
  python3 convert_logs.py <input_file> [listener_id] [freq_hz] [channel_name] [output_dir]
  python3 convert_logs.py pagers_20260823_142000.txt
  python3 convert_logs.py pagers_20260823_142000.txt mtl-01 929287500 pagenet ./converted

Defaults: listener_id=mtl-01, freq_hz=929287500, channel_name=pagenet, output_dir=./converted
"""

import sys
import os
import re
from collections import defaultdict

def extract_date(line):
    """Extract UTC date (YYYYMMDD) from a FLEX or POCSAG message line."""
    match = re.search(r'(\d{4}-\d{2}-\d{2})\s+\d{2}:\d{2}:\d{2}', line)
    if match:
        return match.group(1).replace("-", "")
    return None

def convert_file(input_path, listener_id, freq_hz, channel_name, output_dir):
    """Split one input file into daily output files."""
    daily_lines = defaultdict(list)
    skipped = 0
    total = 0

    print(f"Reading: {input_path}")

    with open(input_path, 'r', errors='replace') as f:
        current_message = None
        current_date = None

        for line in f:
            line = line.rstrip('\n').rstrip('\r')
            if not line:
                continue

            total += 1

            # Skip multimon-ng header
            if line.startswith("Enabled demodulators:"):
                continue

            # New message starts with FLEX or POCSAG
            if line.startswith("FLEX") or line.startswith("POCSAG"):
                # Write previous message
                if current_message is not None and current_date is not None:
                    daily_lines[current_date].append(current_message)

                current_message = line
                current_date = extract_date(line)

                if current_date is None:
                    skipped += 1
                    current_message = None
            else:
                # Continuation line (garbled multi-line message)
                if current_message is not None:
                    cleaned = ''.join(c if c.isprintable() or c == ' ' else '' for c in line).strip()
                    if cleaned:
                        current_message += " " + cleaned

        # Write last buffered message
        if current_message is not None and current_date is not None:
            daily_lines[current_date].append(current_message)

    # Write output files
    files_written = 0
    total_messages = 0

    for date, messages in sorted(daily_lines.items()):
        output_filename = f"{listener_id}_{freq_hz}_{channel_name}_{date}.txt"
        output_path = os.path.join(output_dir, output_filename)

        # Append if file already exists (in case of multiple input files for same day)
        mode = 'a' if os.path.exists(output_path) else 'w'
        with open(output_path, mode) as f:
            for msg in messages:
                f.write(msg + "\n")

        files_written += 1
        total_messages += len(messages)
        print(f"  {output_filename}: {len(messages)} messages")

    print(f"\nSummary:")
    print(f"  Input lines: {total}")
    print(f"  Messages written: {total_messages}")
    print(f"  Skipped (no date): {skipped}")
    print(f"  Daily files: {files_written}")
    print(f"  Output directory: {output_dir}")

    return files_written, total_messages

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 convert_logs.py <input_file> [listener_id] [freq_hz] [channel_name] [output_dir]")
        print("\nDefaults: listener_id=mtl-01, freq_hz=929287500, channel_name=pagenet")
        print("Output goes to ./converted/ by default")
        sys.exit(1)

    listener_id = sys.argv[2] if len(sys.argv) > 2 else "mtl-01"
    freq_hz = sys.argv[3] if len(sys.argv) > 3 else "929287500"
    channel_name = sys.argv[4] if len(sys.argv) > 4 else "pagenet"
    output_dir = sys.argv[5] if len(sys.argv) > 5 else "./converted"

    os.makedirs(output_dir, exist_ok=True)

    input_files = [sys.argv[1]]

    total_files = 0
    total_messages = 0

    for input_file in input_files:
        if not os.path.exists(input_file):
            print(f"File not found: {input_file}")
            continue

        files, messages = convert_file(input_file, listener_id, freq_hz, channel_name, output_dir)
        total_files += files
        total_messages += messages

    print(f"\n{'='*50}")
    print(f"Total: {total_messages} messages across {total_files} daily files")
    print(f"Output: {output_dir}/")

if __name__ == "__main__":
    main()
