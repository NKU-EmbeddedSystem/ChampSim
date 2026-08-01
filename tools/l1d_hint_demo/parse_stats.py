#!/usr/bin/env python3
"""Parse ChampSim stdout and compare baseline vs hint-guided runs."""

import argparse
import re
import sys


def parse_stats(text: str) -> dict:
    stats = {}

    m = re.findall(r"cumulative IPC:\s*([\d.]+)", text)
    stats["ipc"] = float(m[-1]) if m else 0.0

    load_access = load_hit = load_miss = 0
    rfo_access = rfo_hit = rfo_miss = 0
    pf_requested = pf_issued = pf_useful = pf_useless = 0
    avg_miss_latency = 0.0

    for line in text.splitlines():
        if "cpu0_L1D" not in line:
            continue

        lm = re.search(r"LOAD\s+ACCESS:\s*(\d+)\s+HIT:\s*(\d+)\s+MISS:\s*(\d+)", line)
        if lm:
            load_access = int(lm.group(1))
            load_hit = int(lm.group(2))
            load_miss = int(lm.group(3))

        rm = re.search(r"RFO\s+ACCESS:\s*(\d+)\s+HIT:\s*(\d+)\s+MISS:\s*(\d+)", line)
        if rm:
            rfo_access = int(rm.group(1))
            rfo_hit = int(rm.group(2))
            rfo_miss = int(rm.group(3))

        pm = re.search(r"PREFETCH\s+REQUESTED:\s*(\d+)\s+ISSUED:\s*(\d+)\s+USEFUL:\s*(\d+)\s+USELESS:\s*(\d+)", line)
        if pm:
            pf_requested = int(pm.group(1))
            pf_issued = int(pm.group(2))
            pf_useful = int(pm.group(3))
            pf_useless = int(pm.group(4))

        ml = re.search(r"AVERAGE MISS LATENCY:\s*([\d.]+)", line)
        if ml:
            avg_miss_latency = float(ml.group(1))

    total_access = load_access + rfo_access
    total_hit = load_hit + rfo_hit
    demand_miss = load_miss + rfo_miss

    stats["l1d_access"] = total_access
    stats["l1d_hit"] = total_hit
    stats["l1d_miss"] = demand_miss
    stats["l1d_hit_rate"] = total_hit / total_access if total_access > 0 else 0.0
    stats["pf_requested"] = pf_requested
    stats["pf_issued"] = pf_issued
    stats["pf_useful"] = pf_useful
    stats["pf_useless"] = pf_useless
    stats["pf_accuracy"] = pf_useful / pf_issued if pf_issued > 0 else 0.0
    stats["pf_coverage"] = pf_useful / (pf_useful + demand_miss) if (pf_useful + demand_miss) > 0 else 0.0
    stats["avg_miss_latency"] = avg_miss_latency

    return stats


def print_comparison(base: dict, hint: dict):
    print("=" * 70)
    print(f"{'Metric':<25} {'Baseline':>12} {'Hint-guided':>12} {'Delta':>12}")
    print("=" * 70)

    rows = [
        ("IPC", base["ipc"], hint["ipc"], True),
        ("L1D Hit Rate", base["l1d_hit_rate"], hint["l1d_hit_rate"], True),
        ("L1D Misses", base["l1d_miss"], hint["l1d_miss"], False),
        ("PF Requested", base["pf_requested"], hint["pf_requested"], False),
        ("PF Issued", base["pf_issued"], hint["pf_issued"], False),
        ("PF Useful", base["pf_useful"], hint["pf_useful"], False),
        ("PF Accuracy", base["pf_accuracy"], hint["pf_accuracy"], True),
        ("PF Coverage", base["pf_coverage"], hint["pf_coverage"], True),
        ("Avg Miss Latency", base["avg_miss_latency"], hint["avg_miss_latency"], False),
    ]

    for name, b, h, is_rate in rows:
        if is_rate and b <= 1.0 and h <= 1.0 and "Rate" in name or "Accuracy" in name or "Coverage" in name:
            b_str = f"{b:.4f}"
            h_str = f"{h:.4f}"
            delta = h - b
            d_str = f"{delta:+.4f}"
        elif "IPC" in name:
            b_str = f"{b:.4f}"
            h_str = f"{h:.4f}"
            delta_pct = (h - b) / b * 100 if b > 0 else 0
            d_str = f"{delta_pct:+.2f}%"
        else:
            b_str = f"{int(b):,}"
            h_str = f"{int(h):,}"
            delta_pct = (h - b) / b * 100 if b > 0 else 0
            d_str = f"{delta_pct:+.1f}%"

        print(f"{name:<25} {b_str:>12} {h_str:>12} {d_str:>12}")

    print("=" * 70)

    ipc_delta = (hint["ipc"] - base["ipc"]) / base["ipc"] * 100 if base["ipc"] > 0 else 0
    print(f"\nIPC uplift: {ipc_delta:+.2f}%")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("baseline", help="Baseline stdout file")
    parser.add_argument("hint", help="Hint-guided stdout file")
    args = parser.parse_args()

    with open(args.baseline) as f:
        base = parse_stats(f.read())
    with open(args.hint) as f:
        hint = parse_stats(f.read())

    print_comparison(base, hint)
