#!/usr/bin/env python3
"""Per-trace summary table: best basic prefetcher vs hint vs no-prefetcher.

Scans a batch run directory (one sub-directory per trace, each with an
eval/ folder of *_d<deg>.txt single-policy results plus b0_no.txt and
b2_hint.txt). Prints an aligned table with IPC columns and speedup over
the no-prefetcher baseline, a geomean row, and optionally writes a PNG
rendering of the same table alongside the segment plots.

Usage:
  summary_table.py <batch_dir> [--png <output.png>]
"""
import argparse
import math
import os
import re

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

IPC_RE = re.compile(r"cumulative IPC:\s*([\d.]+)")


def read_ipc(path):
    """Final cumulative IPC from a ChampSim text output, or None."""
    last = None
    try:
        with open(path, errors="replace") as f:
            for line in f:
                if "cumulative IPC" in line:
                    last = line
    except OSError:
        return None
    if last is None:
        return None
    m = IPC_RE.search(last)
    return float(m.group(1)) if m else None


def collect(batch_dir, seg_dir=None, bw="3200"):
    """[(trace, best_name, best_ipc, hint_ipc, no_ipc), ...] sorted by trace.

    With seg_dir, hint/no are taken from <seg_dir>/<trace>/bw<bw>/{hint,no}.txt
    (l1d-seg layout) instead of the batch dir's b2_hint/b0_no files.
    """
    rows = []
    for t in sorted(os.listdir(batch_dir)):
        edir = os.path.join(batch_dir, t, "eval")
        if not os.path.isdir(edir):
            continue
        cands = {}
        for f in os.listdir(edir):
            if f.endswith(".txt") and f[0] not in "b" and f != "no_d1.txt":
                v = read_ipc(os.path.join(edir, f))
                if v:
                    cands[f[:-4]] = v
        best_name, best_ipc = max(cands.items(), key=lambda kv: kv[1])
        if seg_dir:
            sdir = os.path.join(seg_dir, t, f"bw{bw}")
            hint = read_ipc(os.path.join(sdir, "hint.txt"))
            no = read_ipc(os.path.join(sdir, "no.txt"))
        else:
            hint = read_ipc(os.path.join(edir, "b2_hint.txt"))
            no = read_ipc(os.path.join(edir, "b0_no.txt"))
        if hint is None or no is None:
            continue
        rows.append((t, best_name, best_ipc, hint, no))
    return rows


def geomean(xs):
    return math.exp(sum(math.log(x) for x in xs) / len(xs))


def print_table(rows):
    header = (f"{'trace':18s} {'best_name':12s} {'best_ipc':>8s} "
              f"{'hint_ipc':>8s} {'no_ipc':>8s}  {'hint/no':>8s} {'best/no':>8s}")
    print(header)
    print("-" * len(header))
    for t, name, best, hint, no in rows:
        print(f"{t:18s} {name:12s} {best:8.4f} {hint:8.4f} {no:8.4f}  "
              f"{(hint / no - 1) * 100:+7.1f}% {(best / no - 1) * 100:+7.1f}%")
    print("-" * len(header))
    gb = geomean([r[2] for r in rows])
    gh = geomean([r[3] for r in rows])
    gn = geomean([r[4] for r in rows])
    print(f"{'GEOMEAN':18s} {'':12s} {gb:8.4f} {gh:8.4f} {gn:8.4f}  "
          f"{(gh / gn - 1) * 100:+7.1f}% {(gb / gn - 1) * 100:+7.1f}%")


def plot_table(rows, out_png):
    cells = [["trace", "best config", "best IPC", "hint IPC", "no-pf IPC",
              "hint/no", "best/no"]]
    for t, name, best, hint, no in rows:
        cells.append([t, name, f"{best:.4f}", f"{hint:.4f}", f"{no:.4f}",
                      f"{(hint / no - 1) * 100:+.1f}%",
                      f"{(best / no - 1) * 100:+.1f}%"])
    gb = geomean([r[2] for r in rows])
    gh = geomean([r[3] for r in rows])
    gn = geomean([r[4] for r in rows])
    cells.append(["GEOMEAN", "", f"{gb:.4f}", f"{gh:.4f}", f"{gn:.4f}",
                  f"{(gh / gn - 1) * 100:+.1f}%", f"{(gb / gn - 1) * 100:+.1f}%"])

    ncol = len(cells[0])
    width = max(len(c) for row in cells for c in row)
    fig_h = 0.35 * (len(cells) + 1) + 0.6
    fig_w = max(0.11 * width * ncol, 8)
    fig, ax = plt.subplots(figsize=(fig_w, fig_h))
    ax.axis("off")
    tbl = ax.table(cellText=cells[1:], colLabels=cells[0], loc="center",
                   cellLoc="center")
    tbl.auto_set_font_size(False)
    tbl.set_fontsize(9)
    tbl.scale(1, 1.4)
    # header bold, geomean row highlighted
    for j in range(ncol):
        tbl[0, j].set_text_props(fontweight="bold")
        tbl[len(cells) - 1, j].set_facecolor("#e8e8e8")
        tbl[len(cells) - 1, j].set_text_props(fontweight="bold")
    ax.set_title("Best single prefetcher vs hint(4pick1) vs no-prefetcher",
                 fontweight="bold")
    fig.tight_layout()
    fig.savefig(out_png, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"wrote table PNG to {out_png}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("batch_dir",
                    default="/home/liz/data_storage/pc-split/ChampSim/artifacts/runs/l1d-baseline-batch/20260822-173040",
                    nargs="?")
    ap.add_argument("--png", default=None,
                    help="also render the table as a PNG image")
    ap.add_argument("--seg-dir", default=None,
                    help="take hint/no columns from a l1d-seg run dir")
    ap.add_argument("--bw", default="3200",
                    help="bandwidth subdir when --seg-dir is given")
    args = ap.parse_args()
    rows = collect(args.batch_dir, args.seg_dir, args.bw)
    if not rows:
        raise SystemExit(f"no usable results under {args.batch_dir}")
    print_table(rows)
    if args.png:
        plot_table(rows, args.png)


if __name__ == "__main__":
    main()
