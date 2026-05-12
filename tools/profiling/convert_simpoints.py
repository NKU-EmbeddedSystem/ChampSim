#!/usr/bin/env python3
"""
Convert SimPoint 3.2 output to the DPC-3 JSON format used by this project.

SimPoint 3.2 output format:
  simpoints.out  — <interval_id> <cluster_id>
  weights.out    — <weight> <cluster_id>

DPC-3 format (used by parse_simpoints.py):
  simpoints.out  — one interval_id per line
  weights.out    — one weight per line

And the final output:
  simpoints.json — [{"interval_id": N, "weight": W}, ...] sorted by weight desc.

Usage:
  python3 convert_simpoints.py \
    --simpoints <simpoints_file> \
    --weights <weights_file> \
    --output-dir <dir>
"""

import argparse
import json
import os
import sys


def convert(simpoints_path: str, weights_path: str, output_dir: str):
    """Strip cluster IDs, sort by weight desc, write simpoints.json."""
    os.makedirs(output_dir, exist_ok=True)

    simpoints_raw = []
    with open(simpoints_path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) >= 1:
                simpoints_raw.append(int(parts[0]))

    weights_raw = []
    with open(weights_path) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) >= 1:
                weights_raw.append(float(parts[0]))

    if len(simpoints_raw) != len(weights_raw):
        print(
            f"WARNING: {len(simpoints_raw)} simpoints != {len(weights_raw)} weights",
            file=sys.stderr,
        )

    intervals = []
    for sp, wt in zip(simpoints_raw, weights_raw):
        intervals.append({"interval_id": sp, "weight": wt})

    intervals.sort(key=lambda x: x["weight"], reverse=True)

    output_path = os.path.join(output_dir, "simpoints.json")
    with open(output_path, "w") as f:
        json.dump(intervals, f, indent=2)
        f.write("\n")

    print(f"Converted {len(intervals)} SimPoints → {output_path}")
    for entry in intervals:
        if entry["weight"] >= 0.01:
            print(
                f"  interval {entry['interval_id']:>6}  "
                f"weight={entry['weight']:.4f}  [SELECTED]"
            )
        else:
            print(
                f"  interval {entry['interval_id']:>6}  "
                f"weight={entry['weight']:.4f}"
            )

    return intervals


def main():
    parser = argparse.ArgumentParser(
        description="Convert SimPoint 3.2 output to DPC-3 JSON format"
    )
    parser.add_argument(
        "--simpoints", required=True, help="SimPoint simpoints output file"
    )
    parser.add_argument(
        "--weights", required=True, help="SimPoint weights output file"
    )
    parser.add_argument(
        "--output-dir", required=True, help="Directory for simpoints.json"
    )
    args = parser.parse_args()

    convert(args.simpoints, args.weights, args.output_dir)


if __name__ == "__main__":
    main()
