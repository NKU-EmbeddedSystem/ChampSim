#!/usr/bin/env python3
"""Plot per-segment (20 x 500k instructions) speedup vs no-prefetcher.

Reads heartbeat lines from the l1d-seg run outputs, computes each line's
speedup (%) over the no-prefetcher run's same segment, and draws one
figure per (trace, bw).
"""
import os
import re
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

SEG_DIR = sys.argv[1] if len(sys.argv) > 1 else "/home/liz/data_storage/pc-split/ChampSim/artifacts/runs/l1d-seg"
OUT_DIR = os.path.join(SEG_DIR, "plots")
HB_RE = re.compile(r"Heartbeat CPU \d+ instructions: (\d+) cycles: \d+ heartbeat IPC: ([\d.]+)")

LINES = [
    ("sandbox", "Sandbox", "#1f77b4"),
    ("dspatch", "DSPatch", "#ff7f0e"),
    ("mlop", "MLOP", "#2ca02c"),
    ("stream", "Stream", "#d62728"),
    ("hint", "Hint(4pick1)", "#9467bd"),
    ("hint_filter", "Hint+Filter", "#8c564b"),
]


def seg_ipcs(path):
    """Return list of (retired_instructions, window_IPC) per heartbeat."""
    vals = []
    with open(path, errors="replace") as f:
        for line in f:
            m = HB_RE.search(line)
            if m:
                vals.append((int(m.group(1)), float(m.group(2))))
    return vals


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    nplots = 0
    for tname in sorted(os.listdir(SEG_DIR)):
        tdir = os.path.join(SEG_DIR, tname)
        if not os.path.isdir(tdir):
            continue
        for bw in ("3200", "1600", "800"):
            bdir = os.path.join(tdir, f"bw{bw}")
            nop = os.path.join(bdir, "no.txt")
            if not os.path.isdir(bdir) or not os.path.exists(nop):
                continue
            base = seg_ipcs(nop)
            seg_span = base[1][0] - base[0][0] if len(base) > 1 else 5e5
            if not base:
                print(f"skip {tname} bw{bw}: no heartbeat data in no.txt")
                continue

            fig, ax = plt.subplots(figsize=(8, 5))
            plotted = 0
            for key, label, color in LINES:
                p = os.path.join(bdir, f"{key}.txt")
                if not os.path.exists(p):
                    continue
                ipcs = seg_ipcs(p)
                if not ipcs:
                    continue
                n = min(len(ipcs), len(base))
                if n < 2:
                    continue
                xs = [ipcs[i][0] for i in range(n)]
                sp = [(ipcs[i][1] - base[i][1]) / base[i][1] * 100.0 for i in range(n)]
                ax.plot(xs, sp, marker="o", ms=3, lw=1.5, color=color, label=label)
                plotted += 1
            if not plotted:
                plt.close(fig)
                continue
            ax.axhline(0, color="gray", lw=0.8, ls="--")
            ax.set_xlabel(f"Retired instructions (segment = {seg_span/1e6:g}M)")
            ax.set_ylabel("Speedup vs no-prefetcher (%)")
            ax.set_title(f"{tname}  @  bw{bw}")
            ax.legend(ncol=2, fontsize=8)
            ax.grid(alpha=0.3)
            fig.tight_layout()
            fig.savefig(os.path.join(OUT_DIR, f"{tname}_bw{bw}.png"), dpi=150)
            plt.close(fig)
            nplots += 1
    print(f"wrote {nplots} plots to {OUT_DIR}")


if __name__ == "__main__":
    sys.exit(main())
