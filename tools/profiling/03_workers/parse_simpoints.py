#!/usr/bin/env python3
"""
Parse DPC-3 SimPoints data for a given benchmark.

SimPoints format:
  simpoints.out  — one interval ID per line
  weights.out    — one weight per line (matching line order)

Output: JSON array of {interval_id, weight}, sorted by weight descending.
"""

import argparse
import json
import os
import sys
import tarfile


def extract_simpoints(tarball_path: str, benchmark: str, output_dir: str):
    """Extract simpoints.out and weights.out for a benchmark from the tarball."""
    os.makedirs(output_dir, exist_ok=True)
    sim_file = os.path.join(output_dir, "simpoints.json")

    with tarfile.open(tarball_path, "r:*") as tar:
        simpoints_member = f"{benchmark}/simpoints.out"
        weights_member = f"{benchmark}/weights.out"

        if simpoints_member not in tar.getnames():
            print(f"ERROR: {simpoints_member} not found in tarball", file=sys.stderr)
            sys.exit(1)

        simpoints_raw = tar.extractfile(simpoints_member).read().decode().strip().split("\n")
        weights_raw = tar.extractfile(weights_member).read().decode().strip().split("\n")

    intervals = []
    for sp_line, wt_line in zip(simpoints_raw, weights_raw):
        sp_line = sp_line.strip()
        wt_line = wt_line.strip()
        if not sp_line or not wt_line:
            continue
        intervals.append({
            "interval_id": int(sp_line),
            "weight": float(wt_line),
        })

    intervals.sort(key=lambda x: x["weight"], reverse=True)

    with open(sim_file, "w") as f:
        json.dump(intervals, f, indent=2)

    print(f"Parsed {len(intervals)} SimPoints for {benchmark} → {sim_file}")
    for entry in intervals:
        if entry["weight"] >= 0.01:
            print(f"  interval {entry['interval_id']:>6}  weight={entry['weight']:.4f}  [SELECTED]")
        else:
            print(f"  interval {entry['interval_id']:>6}  weight={entry['weight']:.4f}")

    return intervals


def main():
    parser = argparse.ArgumentParser(description="Parse DPC-3 SimPoints for a benchmark")
    parser.add_argument("--tarball", required=True, help="Path to weights-and-simpoints-speccpu.tar.gz")
    parser.add_argument("--benchmark", required=True, help="Benchmark name (e.g. 400.perlbench)")
    parser.add_argument("--output-dir", required=True, help="Directory for parsed JSON output")
    args = parser.parse_args()

    extract_simpoints(args.tarball, args.benchmark, args.output_dir)


if __name__ == "__main__":
    main()
