#!/usr/bin/env python3
"""
Aggregate context-aware profiling results across multiple prefetcher runs
to determine the best prefetch policy per (PC, context_key) pair.

Input: Directory of profiling JSON files (one per prefetcher+degree run).
  Each file should be named: {benchmark}__{prefetcher}__{degree}.json
  Content: JSON lines from profiler flush() output, including both:
    - Per-PC records (no context_extractor field)
    - Per-(PC, context_key) records (with context_extractor field)

Output: Per-extractor JSONL files:
  {output_base}.{extractor}.jsonl
  Each line: {"pc": "0x4c36f3", "context_extractor": "delta_signature",
              "context_key": 419, "best_prefetch": "ip_stride", "best_degree": 1,
              "best_amat": 12.5, "all_amats": {"no:1": 15.2, ...}}

Usage:
  python aggregate_context_ground_truth.py --profiling-dir <dir> --output-base labels_ctx
"""

import argparse
import json
import os
import re
import sys
from collections import Counter, defaultdict

FILENAME_RE = re.compile(r"(.+?)__(.+?)__(\d+)\.json")

EXTRACTOR_NAMES = ["page_offset", "delta_signature", "recent_pc_hash", "composite"]


def parse_filename(filename: str):
    """Parse {benchmark}__{prefetcher}__{degree}.json"""
    m = FILENAME_RE.match(filename)
    if m:
        return m.group(1), m.group(2), int(m.group(3))
    return None, None, None


def load_context_profiling_file(filepath: str):
    """Load a profiling JSONL file, return per-(PC, extractor, context_key) AMAT data.

    Returns:
        dict: (pc_hex, extractor_name, context_key) → avg_amat (float)
    """
    ctx_amat = {}
    with open(filepath) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue

            # Only process context-aware records
            extractor = rec.get("context_extractor")
            if extractor is None:
                continue

            pc = rec.get("pc", "")
            if isinstance(pc, str):
                pc = pc.lower()
            else:
                pc = f"0x{pc:x}"

            ctx_key = rec.get("context_key", 0)

            amat = rec.get("avg_amat")
            if amat is None and rec.get("access_count", 0) > 0:
                hit_ratio = rec.get("hit_ratio", 0)
                amat = 1.0 - hit_ratio

            if amat is not None:
                ctx_amat[(pc, extractor, ctx_key)] = float(amat)

    return ctx_amat


def aggregate(profiling_dir: str):
    """Load all context profiling outputs, compare AMAT per (PC, extractor, context_key)."""

    # structure: (pc, extractor, context_key) → { policy_key → amat }
    ctx_amats = defaultdict(dict)
    file_stats = {}

    for fname in sorted(os.listdir(profiling_dir)):
        if not fname.endswith(".json"):
            continue
        benchmark, prefetcher, degree = parse_filename(fname)
        if prefetcher is None:
            continue

        policy_key = f"{prefetcher}:{degree}"
        filepath = os.path.join(profiling_dir, fname)
        ctx_amat = load_context_profiling_file(filepath)

        for key, amat in ctx_amat.items():
            ctx_amats[key][policy_key] = amat

        file_stats[fname] = len(ctx_amat)
        print(f"  Loaded {fname}: {len(ctx_amat)} context records")

    # Group results by extractor
    results_by_extractor = {name: [] for name in EXTRACTOR_NAMES}

    for (pc, extractor, ctx_key), policies in sorted(ctx_amats.items()):
        if len(policies) < 2:
            continue

        best_policy_key = min(policies, key=policies.get)
        best_amat = policies[best_policy_key]
        prefetcher_name, degree_str = best_policy_key.split(":")

        entry = {
            "pc": pc,
            "context_extractor": extractor,
            "context_key": ctx_key,
            "best_prefetch": prefetcher_name,
            "best_degree": int(degree_str),
            "best_amat": round(best_amat, 4),
            "all_amats": {k: round(v, 4) for k, v in sorted(policies.items())},
        }

        if extractor in results_by_extractor:
            results_by_extractor[extractor].append(entry)

    return results_by_extractor


def main():
    parser = argparse.ArgumentParser(
        description="Aggregate context-aware ground truth labels from profiling"
    )
    parser.add_argument("--profiling-dir", required=True, help="Directory of profiling JSON files")
    parser.add_argument(
        "--output-base",
        required=True,
        help="Output base path (will create {base}.{extractor}.jsonl)",
    )
    args = parser.parse_args()

    results_by_extractor = aggregate(args.profiling_dir)

    total_records = 0
    for extractor_name in EXTRACTOR_NAMES:
        results = results_by_extractor[extractor_name]
        results.sort(key=lambda x: (int(x["pc"], 16), x["context_key"]))

        output_path = f"{args.output_base}.{extractor_name}.jsonl"
        with open(output_path, "w") as f:
            for entry in results:
                f.write(json.dumps(entry) + "\n")

        # Summary
        pref_counts = Counter(r["best_prefetch"] for r in results)
        num_unique_pcs = len(set(r["pc"] for r in results))
        num_unique_ctx = len(results)

        print(f"\n  [{extractor_name}] {num_unique_ctx} (PC, context) entries across {num_unique_pcs} PCs")
        print(f"  → {output_path}")
        for pref, count in pref_counts.most_common():
            print(f"    {pref}: {count} ({100 * count / max(len(results), 1):.1f}%)")

        total_records += len(results)

    print(f"\nTotal: {total_records} context labels across {len(EXTRACTOR_NAMES)} extractors")


if __name__ == "__main__":
    main()
