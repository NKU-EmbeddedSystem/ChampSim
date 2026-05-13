#!/usr/bin/env python3
"""
Read ChampSim binary trace (.xz compressed) and extract unique Load PCs.

ChampSim trace format (64 bytes per instruction, little-endian):
  struct input_instr {
    unsigned long long ip;                              // 8B  offset 0
    unsigned char is_branch;                            // 1B  offset 8
    unsigned char branch_taken;                         // 1B  offset 9
    unsigned char destination_registers[2];             // 2B  offset 10
    unsigned char source_registers[4];                  // 4B  offset 12
    unsigned long long destination_memory[2];           // 16B offset 16
    unsigned long long source_memory[4];                // 32B offset 32
  };                                                   // = 64B total

A Load instruction = source_memory[0] != 0 (instruction has at least one memory read).
"""

import argparse
import json
import lzma
import struct
import sys

TRACE_RECORD_SIZE = 64

# We only need 2 fields from the 64-byte record:
#   offset 0:  ip (8B, unsigned long long, little-endian)
#   offset 32: source_memory[0] (8B, unsigned long long, little-endian)
#
# Instead of unpacking the full struct per record, we read large buffers
# and extract just these fields with struct.unpack_from in a tight loop.
RECORD_ST_IP = struct.Struct("<Q")
RECORD_ST_SM0 = struct.Struct("<Q")  # reusing, but at offset 32


def extract_load_pcs(trace_path: str, max_instructions: int = 0):
    """Extract unique Load PCs from a ChampSim trace file.

    Uses external xz decompression (pipe) for speed, and processes records
    in 8MB buffers extracting only PC and source_memory[0] per record.

    Args:
        trace_path: Path to .xz or uncompressed trace file.
        max_instructions: If >0, stop after processing this many records.
    """
    load_pcs = set()
    total = 0
    loads = 0

    buf_size = 8 * 1024 * 1024  # 8MB, must be multiple of 64
    assert buf_size % TRACE_RECORD_SIZE == 0

    def open_trace(path):
        if path.endswith(".xz"):
            import subprocess
            return subprocess.Popen(
                ["xz", "-dc", path], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL
            ).stdout
        else:
            return open(path, "rb")

    with open_trace(trace_path) as f:
        tail = b""
        while True:
            chunk = f.read(buf_size)
            if not chunk:
                break

            data = tail + chunk
            n_records = len(data) // TRACE_RECORD_SIZE

            # Apply max_instructions cap
            if max_instructions > 0 and total + n_records > max_instructions:
                n_records = max_instructions - total

            processed = n_records * TRACE_RECORD_SIZE

            for i in range(n_records):
                offset = i * TRACE_RECORD_SIZE
                pc = RECORD_ST_IP.unpack_from(data, offset)[0]
                sm0 = RECORD_ST_SM0.unpack_from(data, offset + 32)[0]
                total += 1
                if sm0 != 0:
                    load_pcs.add(pc)
                    loads += 1

            tail = data[processed:]

            if total % 50_000_000 == 0 and total > 0:
                print(f"  ... {total:,} instructions, {len(load_pcs):,} unique Load PCs", file=sys.stderr)

            if max_instructions > 0 and total >= max_instructions:
                break

    load_pcs_hex = sorted([f"0x{pc:x}" for pc in load_pcs])
    print(f"Trace: {total:,} instructions, {loads:,} loads, {len(load_pcs):,} unique Load PCs")
    return load_pcs_hex


def main():
    parser = argparse.ArgumentParser(description="Extract unique Load PCs from ChampSim trace")
    parser.add_argument("--trace", required=True, help="Path to .champsimtrace.xz file")
    parser.add_argument("--output", required=True, help="Output JSON file (list of PC hex strings)")
    parser.add_argument("--max-instructions", type=int, default=0,
                        help="Stop after N instructions (0 = read all)")
    args = parser.parse_args()

    load_pcs = extract_load_pcs(args.trace, max_instructions=args.max_instructions)

    with open(args.output, "w") as f:
        json.dump(load_pcs, f, indent=2)
    print(f"Saved {len(load_pcs)} Load PCs → {args.output}")


if __name__ == "__main__":
    main()
