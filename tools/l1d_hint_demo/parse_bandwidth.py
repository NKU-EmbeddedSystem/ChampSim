#!/usr/bin/env python3
"""Parse prefetch bandwidth pressure stats from batch run eval files."""
import os, re, sys, csv

champsim_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
run_dir = sys.argv[1] if len(sys.argv) > 1 else "artifacts/runs/l1d-baseline-batch/20260801-121706"
run_dir = os.path.join(champsim_root, run_dir) if not os.path.isabs(run_dir) else run_dir
output_csv = sys.argv[2] if len(sys.argv) > 2 else os.path.join(run_dir, "bandwidth_stats.csv")

BLOCK_SIZE = 64
FREQ_MHZ = 4000

def parse_eval_file(path):
    with open(path) as f:
        text = f.read()

    stats = {}
    m = re.findall(r"cumulative IPC:\s*([\d.]+)", text)
    stats["ipc"] = float(m[-1]) if m else 0.0

    m = re.search(r"instructions:\s*(\d+)\s+cycles:\s*(\d+)", text)
    stats["cycles"] = int(m.group(2)) if m else 0

    for line in text.splitlines():
        if "cpu0_L1D" in line:
            pm = re.search(r"PREFETCH\s+REQUESTED:\s*(\d+)\s+ISSUED:\s*(\d+)\s+USEFUL:\s*(\d+)\s+USELESS:\s*(\d+)", line)
            if pm:
                stats["l1d_pf_requested"] = int(pm.group(1))
                stats["l1d_pf_issued"] = int(pm.group(2))
                stats["l1d_pf_useful"] = int(pm.group(3))
                stats["l1d_pf_useless"] = int(pm.group(4))

        if "cpu0->LLC" in line or "cpu0_LLC" in line:
            tm = re.search(r"TOTAL\s+ACCESS:\s*(\d+)\s+HIT:\s*(\d+)\s+MISS:\s*(\d+)", line)
            if tm:
                stats["llc_total_access"] = int(tm.group(1))
                stats["llc_total_hit"] = int(tm.group(2))
                stats["llc_total_miss"] = int(tm.group(3))

            lm = re.search(r"LOAD\s+ACCESS:\s*(\d+)\s+HIT:\s*(\d+)\s+MISS:\s*(\d+)", line)
            if lm:
                stats["llc_load_miss"] = int(lm.group(3))

            pm = re.search(r"PREFETCH\s+ACCESS:\s*(\d+)\s+HIT:\s*(\d+)\s+MISS:\s*(\d+)", line)
            if pm:
                stats["llc_pf_access"] = int(pm.group(1))
                stats["llc_pf_miss"] = int(pm.group(3))

            prm = re.search(r"PREFETCH\s+REQUESTED:\s*(\d+)\s+ISSUED:\s*(\d+)\s+USEFUL:\s*(\d+)\s+USELESS:\s*(\d+)", line)
            if prm:
                stats["llc_pf_issued"] = int(prm.group(2))
                stats["llc_pf_useful"] = int(prm.group(3))

    stats.setdefault("l1d_pf_issued", 0)
    stats.setdefault("l1d_pf_useful", 0)
    stats.setdefault("llc_total_miss", 0)
    stats.setdefault("llc_load_miss", 0)
    stats.setdefault("llc_pf_miss", 0)
    stats.setdefault("llc_pf_issued", 0)
    stats.setdefault("llc_pf_useful", 0)
    stats.setdefault("cycles", 1)

    sim_seconds = stats["cycles"] / (FREQ_MHZ * 1e6)
    stats["dram_bw_gbps"] = stats["llc_total_miss"] * BLOCK_SIZE / sim_seconds / 1e9 if sim_seconds > 0 else 0
    stats["pf_dram_bw_gbps"] = stats["llc_pf_miss"] * BLOCK_SIZE / sim_seconds / 1e9 if sim_seconds > 0 else 0

    return stats


rows = []
for tname in sorted(os.listdir(run_dir)):
    tdir = os.path.join(run_dir, tname)
    eval_dir = os.path.join(tdir, "eval")
    if not os.path.isdir(eval_dir):
        continue

    for fn in sorted(os.listdir(eval_dir)):
        if not fn.endswith(".txt") or fn in ("b0_no.txt", "b1_best.txt", "b2_hint.txt"):
            continue
        path = os.path.join(eval_dir, fn)
        pref_name = fn.replace(".txt", "")
        stats = parse_eval_file(path)
        rows.append({
            "trace": tname,
            "prefetcher": pref_name,
            "ipc": stats["ipc"],
            "l1d_pf_issued": stats["l1d_pf_issued"],
            "l1d_pf_useful": stats["l1d_pf_useful"],
            "l1d_pf_accuracy": stats["l1d_pf_useful"] / stats["l1d_pf_issued"] if stats["l1d_pf_issued"] > 0 else 0,
            "llc_total_miss": stats["llc_total_miss"],
            "llc_load_miss": stats["llc_load_miss"],
            "llc_pf_miss": stats["llc_pf_miss"],
            "dram_bw_gbps": stats["dram_bw_gbps"],
            "pf_dram_bw_gbps": stats["pf_dram_bw_gbps"],
        })

    # Also parse b0_no
    b0_path = os.path.join(eval_dir, "b0_no.txt")
    if os.path.isfile(b0_path):
        stats = parse_eval_file(b0_path)
        rows.append({
            "trace": tname,
            "prefetcher": "no_d1",
            "ipc": stats["ipc"],
            "l1d_pf_issued": 0,
            "l1d_pf_useful": 0,
            "l1d_pf_accuracy": 0,
            "llc_total_miss": stats["llc_total_miss"],
            "llc_load_miss": stats["llc_load_miss"],
            "llc_pf_miss": 0,
            "dram_bw_gbps": stats["dram_bw_gbps"],
            "pf_dram_bw_gbps": 0,
        })

# Write CSV
fields = ["trace", "prefetcher", "ipc", "l1d_pf_issued", "l1d_pf_useful", "l1d_pf_accuracy",
           "llc_total_miss", "llc_load_miss", "llc_pf_miss", "dram_bw_gbps", "pf_dram_bw_gbps"]
with open(output_csv, "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=fields)
    w.writeheader()
    w.writerows(rows)

print(f"Wrote {len(rows)} rows to {output_csv}")

# Print per-trace summary: top bandwidth consumers
print(f"\n{'='*90}")
print(f"  Bandwidth Pressure Summary (sorted by DRAM BW)")
print(f"{'='*90}")

from collections import defaultdict
by_trace = defaultdict(list)
for r in rows:
    by_trace[r["trace"]].append(r)

for tname in sorted(by_trace):
    entries = sorted(by_trace[tname], key=lambda x: x["dram_bw_gbps"], reverse=True)
    print(f"\n  {tname}:")
    print(f"  {'Prefetcher':<16} {'IPC':>7} {'PF_Issued':>10} {'PF_Acc':>7} {'LLC_Miss':>10} {'DRAM_BW':>9} {'PF_BW':>9}")
    print(f"  {'-'*16} {'-'*7} {'-'*10} {'-'*7} {'-'*10} {'-'*9} {'-'*9}")
    for e in entries[:8]:
        print(f"  {e['prefetcher']:<16} {e['ipc']:>7.4f} {e['l1d_pf_issued']:>10,} {e['l1d_pf_accuracy']:>6.1%} "
              f"{e['llc_total_miss']:>10,} {e['dram_bw_gbps']:>7.2f}G {e['pf_dram_bw_gbps']:>7.2f}G")
