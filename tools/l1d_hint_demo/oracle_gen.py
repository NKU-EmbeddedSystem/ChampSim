#!/usr/bin/env python3
"""Generate binary hint file from aggregated ground truth labels."""

import argparse
import json
import struct
import sys

HINT_MAGIC = 0x544E4948
HINT_VERSION = 1
ENTRY_STRUCT = struct.Struct("<QBBBB4x")

PREFETCH_POLICIES = {
    'no': 0, 'next_line': 1, 'ip_stride': 2, 'spp_dev': 3, 'va_ampm_lite': 4,
    'stride': 5, 'stream': 6, 'ampm': 7, 'sms': 8, 'bingo': 9,
    'sandbox': 10, 'power7': 11, 'dspatch': 12, 'mlop': 13, 'ppf': 14,
}


def generate(labels_path: str, output_path: str):
    entries = []
    with open(labels_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            rec = json.loads(line)
            pc_str = rec["pc"]
            pc = int(pc_str, 16) if isinstance(pc_str, str) else int(pc_str)
            pref_name = rec.get("best_prefetch", "no")
            pref_idx = PREFETCH_POLICIES.get(pref_name, 0)
            degree = int(rec.get("best_degree", 1))
            entries.append((pc, pref_idx, degree))

    entries.sort(key=lambda e: e[0])

    with open(output_path, "wb") as f:
        f.write(struct.pack("<IIII", HINT_MAGIC, HINT_VERSION, len(entries), 0))
        for pc, pref_idx, degree in entries:
            f.write(ENTRY_STRUCT.pack(pc, 0, pref_idx, degree, 0))

    print(f"Wrote {len(entries)} hint entries to {output_path}")

    from collections import Counter
    idx_to_name = {v: k for k, v in PREFETCH_POLICIES.items()}
    dist = Counter(idx_to_name[e[1]] for e in entries)
    print("Prefetcher distribution:")
    for name, count in dist.most_common():
        print(f"  {name}: {count} PCs ({100*count/len(entries):.1f}%)")


def validate(path: str):
    with open(path, "rb") as f:
        magic, version, count, _ = struct.unpack("<IIII", f.read(16))
        assert magic == HINT_MAGIC, f"Bad magic: 0x{magic:08X}"
        assert version == HINT_VERSION, f"Bad version: {version}"
        print(f"Valid hint file: {count} entries (version {version})")
        idx_to_name = {v: k for k, v in PREFETCH_POLICIES.items()}
        for i in range(min(count, 5)):
            pc, repl, pref, degree, filt = ENTRY_STRUCT.unpack(f.read(16))
            print(f"  PC=0x{pc:016X} pref={idx_to_name.get(pref, pref)} degree={degree}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)

    gen = sub.add_parser("generate")
    gen.add_argument("--labels", required=True)
    gen.add_argument("--output", default="hint.bin")

    val = sub.add_parser("validate")
    val.add_argument("--input", required=True)

    args = parser.parse_args()
    if args.cmd == "generate":
        generate(args.labels, args.output)
    elif args.cmd == "validate":
        validate(args.input)
