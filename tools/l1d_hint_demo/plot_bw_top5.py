#!/usr/bin/env python3
"""Plot per-trace top-5 prefetcher IPC and late-rate across bandwidth levels.

For each trace, produces one figure with two stacked panels sharing the x axis
(bandwidth level: bw3200 / bw1600 / bw800):
  top:    IPC lines for the union of per-bw top-5 strategies (+ B0 baseline);
          the winner at each bw is marked with a star
  bottom: grouped bars of USEFUL_LATE / (USEFUL_HIT + USEFUL_LATE) for the
          same strategies, same colors

Usage:
  python3 plot_bw_top5.py [prefetch_stats.csv] [out_dir]
Defaults: latest artifacts/runs/l1d-bw/*/prefetch_stats.csv, plots into <run_dir>/plots/
"""
import csv, glob, os, sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

BW_ORDER = ["bw3200", "bw1600", "bw800"]
BW_LABELS = ["3200 MT/s\n(25.6 GB/s)", "1600 MT/s\n(12.8 GB/s)", "800 MT/s\n(6.4 GB/s)"]
TOPN = 5

if len(sys.argv) > 1:
    csv_path = sys.argv[1]
else:
    cands = sorted(glob.glob(os.path.join(os.path.dirname(__file__), "..", "..", "artifacts/runs/l1d-bw/*/prefetch_stats.csv")))
    csv_path = cands[-1]
out_dir = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(csv_path), "plots")
os.makedirs(out_dir, exist_ok=True)

rows = list(csv.DictReader(open(csv_path)))
traces = sorted({r["trace"] for r in rows})

def val(r, key):
    return float(r[key]) if r[key] not in ("", "-1") else float("nan")

for trace in traces:
    trows = [r for r in rows if r["trace"] == trace]

    # union of per-bw top-N strategies by IPC; always include hint variants for comparison
    top_union, seen = [], set()
    for bw in BW_ORDER:
        sub = sorted([r for r in trows if r["bw"] == bw and r["prefetcher"] != "b0_no"], key=lambda r: -val(r, "ipc"))
        for r in sub[:TOPN]:
            if r["prefetcher"] not in seen:
                seen.add(r["prefetcher"])
                top_union.append(r["prefetcher"])
    for forced in ("b2_hint", "b2_hint_native", "b3_hint_tax_l05", "b3_hint_tax_l20", "b4_hint_gate", "b5_hint_pc_tax_l05", "b5_hint_pc_tax_l20", "c3_accgate"):
        if forced not in seen and any(r["prefetcher"] == forced for r in trows):
            seen.add(forced)
            top_union.append(forced)

    b0 = {r["bw"]: val(r, "ipc") for r in trows if r["prefetcher"] == "b0_no"}
    stats = {}
    for r in trows:
        uh, ul = val(r, "pf_useful_hit"), val(r, "pf_useful_late")
        late_share = ul / (uh + ul) * 100 if (uh + ul) > 0 else 0.0
        stats[(r["prefetcher"], r["bw"])] = (val(r, "ipc"), late_share)

    colors = {p: plt.cm.tab20(i % 20) for i, p in enumerate(top_union)}
    x = list(range(len(BW_ORDER)))

    fig, (ax_ipc, ax_late) = plt.subplots(2, 1, figsize=(9, 7), sharex=True, gridspec_kw={"height_ratios": [3, 2], "hspace": 0.08})

    # winners per bw (for star markers)
    winners = {}
    for bw in BW_ORDER:
        cands_bw = [(p, stats[(p, bw)][0]) for p in top_union if (p, bw) in stats]
        if cands_bw:
            winners[bw] = max(cands_bw, key=lambda t: t[1])[0]

    for p in top_union:
        ys = [stats.get((p, bw), (float("nan"), 0))[0] for bw in BW_ORDER]
        ax_ipc.plot(x, ys, marker="o", color=colors[p], label=p, linewidth=1.6, markersize=5)
        for xi, bw in zip(x, BW_ORDER):
            if winners.get(bw) == p:
                ax_ipc.plot(xi, stats[(p, bw)][0], marker="*", color=colors[p], markersize=16,
                            markeredgecolor="black", markeredgewidth=0.6, linestyle="none")
    if b0:
        ax_ipc.plot(x, [b0[bw] for bw in BW_ORDER], color="black", linestyle="--", linewidth=1.2, label="b0_no (baseline)")
    ax_ipc.set_ylabel("IPC")
    ax_ipc.set_title(f"{trace}: top-{TOPN} prefetchers across bandwidth (star = winner)")
    ax_ipc.grid(alpha=0.3)
    ax_ipc.legend(fontsize=8, ncol=2, loc="best")

    # late-rate grouped bars
    n = len(top_union)
    width = 0.8 / max(n, 1)
    for i, p in enumerate(top_union):
        xs = [xi - 0.4 + width * (i + 0.5) for xi in x]
        ys = [stats.get((p, bw), (0, 0))[1] for bw in BW_ORDER]
        ax_late.bar(xs, ys, width=width, color=colors[p], label=p)
    ax_late.set_ylabel("late rate (%)\nUSEFUL_LATE / USEFUL")
    ax_late.set_xticks(x)
    ax_late.set_xticklabels(BW_LABELS)
    ax_late.grid(alpha=0.3, axis="y")
    ax_late.set_ylim(bottom=0)

    out = os.path.join(out_dir, f"{trace}.png")
    fig.savefig(out, dpi=130, bbox_inches="tight")
    plt.close(fig)
    print(f"wrote {out}")

print(f"done, {len(traces)} figures -> {out_dir}")
