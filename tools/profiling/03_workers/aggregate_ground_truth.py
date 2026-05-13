#!/usr/bin/env python3
"""
Aggregate profiling results across multiple prefetcher runs to determine
the best prefetch policy per PC (lowest AMAT).

Input: Directory of profiling JSON files (one per prefetcher+degree run).
  Each file should be named: {benchmark}__{prefetcher}__{degree}.json
  Content: JSON lines from profiler flush() output.

Output: JSONL file:
  {"pc": "0x4c36f3", "best_prefetch": "ip_stride", "best_degree": 2,
   "best_amat": 12.5, "all_amats": {"no:1": 15.2, "next_line:1": 14.1, ...}}
"""

import argparse
import json
import os
import re
import sys
from collections import defaultdict

FILENAME_RE = re.compile(r"(.+?)__(.+?)__(\d+)\.json")


def parse_filename(filename: str):
    """Parse {benchmark}__{prefetcher}__{degree}.json"""
    m = FILENAME_RE.match(filename)
    if m:
        return m.group(1), m.group(2), int(m.group(3))
    return None, None, None


def load_profiling_file(filepath: str):
    """Load a profiling JSONL file, return dict: pc_hex → avg_amat (float)."""
    pc_amat = {}
    with open(filepath) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue

            pc = rec.get("pc", "")
            if isinstance(pc, str):
                pc = pc.lower()
            else:
                pc = f"0x{pc:x}"

            # Use avg_amat if available, else compute from hit_ratio
            amat = rec.get("avg_amat")
            if amat is None and rec.get("access_count", 0) > 0:
                # Fallback: use hit_ratio as proxy (lower miss rate → better)
                hit_ratio = rec.get("hit_ratio", 0)
                amat = 1.0 - hit_ratio  # crude proxy

            if amat is not None:
                pc_amat[pc] = float(amat)

    return pc_amat


def aggregate(profiling_dir: str):
    """Load all profiling outputs, compare AMAT per PC, produce labels."""

    # structure: pc_hex → { policy_key → amat }
    pc_amats = defaultdict(dict)

    for fname in os.listdir(profiling_dir):
        if not fname.endswith(".json"):
            continue
        benchmark, prefetcher, degree = parse_filename(fname)
        if prefetcher is None:
            continue

        policy_key = f"{prefetcher}:{degree}"
        filepath = os.path.join(profiling_dir, fname)
        pc_amat = load_profiling_file(filepath)

        for pc, amat in pc_amat.items():
            pc_amats[pc][policy_key] = amat

        print(f"  Loaded {fname}: {len(pc_amat)} PCs")

    # For each PC, find best (lowest AMAT) policy
    results = []
    num_multiple = 0
    for pc, policies in sorted(pc_amats.items()):
        if len(policies) < 2:
            continue  # skip PCs seen in only one run

        num_multiple += 1
        best_policy_key = min(policies, key=policies.get)
        best_amat = policies[best_policy_key]
        prefetcher_name, degree_str = best_policy_key.split(":")

        results.append({
            "pc": pc,
            "best_prefetch": prefetcher_name,
            "best_degree": int(degree_str),
            "best_amat": round(best_amat, 4),
            "all_amats": {k: round(v, 4) for k, v in sorted(policies.items())},
        })

    return results, num_multiple


def main():
    parser = argparse.ArgumentParser(description="Aggregate ground truth labels from profiling")
    parser.add_argument("--profiling-dir", required=True, help="Directory of profiling JSON files")
    parser.add_argument("--output", required=True, help="Output JSONL file")
    args = parser.parse_args()

    results, num_multi = aggregate(args.profiling_dir)

    # Sort by PC
    results.sort(key=lambda x: int(x["pc"], 16))

    with open(args.output, "w") as f:
        for entry in results:
            f.write(json.dumps(entry) + "\n")

    print(f"\nGround truth: {len(results)} PCs with ≥2 policy measurements")
    print(f"Saved → {args.output}")

    # Summary
    from collections import Counter
    pref_counts = Counter(r["best_prefetch"] for r in results)
    print("\nBest prefetch distribution:")
    for pref, count in pref_counts.most_common():
        print(f"  {pref}: {count} PCs ({100*count/len(results):.1f}%)")


if __name__ == "__main__":
    main()
