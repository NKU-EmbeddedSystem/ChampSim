#!/usr/bin/env python3
"""Show oracle hint distribution for each trace in a batch run."""
import json, os, sys
from collections import Counter

champsim_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
run_dir = sys.argv[1] if len(sys.argv) > 1 else "artifacts/runs/l1d-baseline-batch/20260801-121706"
run_dir = os.path.join(champsim_root, run_dir) if not os.path.isabs(run_dir) else run_dir

trace_filter = sys.argv[2] if len(sys.argv) > 2 else None

for tname in sorted(os.listdir(run_dir)):
    tdir = os.path.join(run_dir, tname)
    gt_file = os.path.join(tdir, "ground_truth.jsonl")
    if not os.path.isfile(gt_file):
        continue
    if trace_filter and trace_filter not in tname:
        continue

    entries = []
    with open(gt_file) as f:
        for line in f:
            line = line.strip()
            if line:
                entries.append(json.loads(line))

    if not entries:
        continue

    pref_dist = Counter(e["best_prefetch"] for e in entries)
    deg_dist = Counter(e["best_degree"] for e in entries)
    total = len(entries)

    print(f"\n{'='*60}")
    print(f"  {tname}  ({total} PCs)")
    print(f"{'='*60}")
    print(f"  Prefetcher distribution:")
    for name, count in pref_dist.most_common():
        bar = "█" * int(40 * count / total)
        print(f"    {name:<14} {count:>4} ({100*count/total:>5.1f}%) {bar}")
    print(f"  Degree distribution:")
    for deg, count in sorted(deg_dist.items()):
        print(f"    degree={deg:<3} {count:>4} ({100*count/total:>5.1f}%)")

    # Show top PCs by access count (most impactful)
    top = sorted(entries, key=lambda e: e.get("best_amat", 999))[:5]
    print(f"  Top 5 PCs (lowest AMAT = best performance):")
    for e in top:
        print(f"    PC={e['pc']:<12} → {e['best_prefetch']:<12} deg={e['best_degree']}  AMAT={e['best_amat']:.1f}")
