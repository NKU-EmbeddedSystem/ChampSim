#!/usr/bin/env python3
"""Compare prefetcher IPC rankings across bandwidth levels."""
import os, re, sys
from collections import defaultdict

run_dir = sys.argv[1] if len(sys.argv) > 1 else "."
ipc_re = re.compile(r"cumulative IPC:\s*([\d.]+)")

# Also load bw3200 (unlimited) results from the earlier batch run
champsim_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
bw3200_dir = os.path.join(champsim_root, "artifacts/runs/stage2-l1d-batch/20260801-121706")

def get_ipc(path):
    # Skip runs that deadlocked/aborted or never finished: their last
    # "cumulative IPC" line is the warmup-phase IPC, not a real result.
    if not os.path.isfile(path):
        return None
    with open(path) as f:
        content = f.read()
    if "DEADLOCK" in content or "Simulation complete" not in content:
        return None
    matches = ipc_re.findall(content)
    return float(matches[-1]) if matches else None

# Collect: trace -> bw_level -> prefetcher -> ipc
data = defaultdict(lambda: defaultdict(dict))

# Load bw3200 from earlier batch run
if os.path.isdir(bw3200_dir):
    for tname in os.listdir(bw3200_dir):
        eval_dir = os.path.join(bw3200_dir, tname, "eval")
        if not os.path.isdir(eval_dir):
            continue
        for fn in os.listdir(eval_dir):
            if not fn.endswith(".txt") or fn in ("b0_no.txt", "b1_best.txt", "b2_hint.txt"):
                continue
            ipc = get_ipc(os.path.join(eval_dir, fn))
            if ipc is not None:
                data[tname]["bw3200"][fn.replace(".txt", "")] = ipc
        b0_ipc = get_ipc(os.path.join(eval_dir, "b0_no.txt"))
        if b0_ipc is not None:
            data[tname]["bw3200"]["no_d1"] = b0_ipc

# Load bw1600 and bw800 from this run
for tname in os.listdir(run_dir):
    tdir = os.path.join(run_dir, tname)
    if not os.path.isdir(tdir):
        continue
    for bw in ("bw1600", "bw800"):
        bw_dir = os.path.join(tdir, bw)
        if not os.path.isdir(bw_dir):
            continue
        for fn in os.listdir(bw_dir):
            if not fn.endswith(".txt"):
                continue
            ipc = get_ipc(os.path.join(bw_dir, fn))
            if ipc is not None:
                pref = fn.replace(".txt", "").replace("b0_no", "no_d1")
                data[tname][bw][pref] = ipc

# Print comparison table
print(f"\n{'='*100}")
print(f"  Bandwidth-Constrained Ranking Comparison")
print(f"{'='*100}")

all_bw = ["bw3200", "bw1600", "bw800"]
summary_rows = []

for tname in sorted(data):
    bw_data = data[tname]
    if "bw1600" not in bw_data and "bw800" not in bw_data:
        continue

    print(f"\n  {tname}:")
    print(f"  {'Prefetcher':<16} {'bw3200':>8} {'bw1600':>8} {'bw800':>8} {'Rank3200':>9} {'Rank1600':>9} {'Rank800':>9}")
    print(f"  {'-'*16} {'-'*8} {'-'*8} {'-'*8} {'-'*9} {'-'*9} {'-'*9}")

    # Get all prefetchers across all bw levels
    all_prefs = set()
    for bw in all_bw:
        all_prefs.update(bw_data.get(bw, {}).keys())

    # Rank within each bw level
    rankings = {}
    for bw in all_bw:
        ipcs = bw_data.get(bw, {})
        sorted_prefs = sorted(ipcs.items(), key=lambda x: x[1], reverse=True)
        rankings[bw] = {p: i+1 for i, (p, _) in enumerate(sorted_prefs)}

    # Sort by bw3200 IPC descending
    refs = bw_data.get("bw3200", bw_data.get("bw1600", {}))
    sorted_prefs = sorted(all_prefs, key=lambda p: refs.get(p, 0), reverse=True)

    for pref in sorted_prefs[:12]:
        ipc3200 = bw_data.get("bw3200", {}).get(pref)
        ipc1600 = bw_data.get("bw1600", {}).get(pref)
        ipc800 = bw_data.get("bw800", {}).get(pref)
        r3200 = rankings.get("bw3200", {}).get(pref, "-")
        r1600 = rankings.get("bw1600", {}).get(pref, "-")
        r800 = rankings.get("bw800", {}).get(pref, "-")

        s3 = f"{ipc3200:.4f}" if ipc3200 else "-"
        s1 = f"{ipc1600:.4f}" if ipc1600 else "-"
        s8 = f"{ipc800:.4f}" if ipc800 else "-"

        print(f"  {pref:<16} {s3:>8} {s1:>8} {s8:>8} {str(r3200):>9} {str(r1600):>9} {str(r800):>9}")

    # Track best prefetcher per bw level
    for bw in all_bw:
        ipcs = bw_data.get(bw, {})
        if ipcs:
            best = max(ipcs, key=ipcs.get)
            summary_rows.append((tname, bw, best, ipcs[best]))

# Summary: does the winner change?
print(f"\n{'='*100}")
print(f"  Winner per trace per bandwidth level")
print(f"{'='*100}")
print(f"  {'Trace':<22} {'bw3200 winner':<18} {'bw1600 winner':<18} {'bw800 winner':<18} {'Changed?':>8}")
print(f"  {'-'*22} {'-'*18} {'-'*18} {'-'*18} {'-'*8}")

traces = sorted(set(r[0] for r in summary_rows))
changed_count = 0
for tname in traces:
    winners = {}
    for bw in all_bw:
        for (t, b, w, ipc) in summary_rows:
            if t == tname and b == bw:
                winners[bw] = w
    w3 = winners.get("bw3200", "-")
    w1 = winners.get("bw1600", "-")
    w8 = winners.get("bw800", "-")
    changed = "Y" if len(set([w3, w1, w8])) > 1 else "N"
    if changed == "Y":
        changed_count += 1
    print(f"  {tname:<22} {w3:<18} {w1:<18} {w8:<18} {changed:>8}")

print(f"\n  Ranking changed: {changed_count} / {len(traces)} traces")
