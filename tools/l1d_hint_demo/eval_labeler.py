#!/usr/bin/env python3
"""RL-facing reward harness for the unified labeler.

One config in -> one reward out:

    python3 eval_labeler.py --config '{"lam_i":0.8,"gate":"pigou"}' \
        [--preset pigougate] [--traces povray_250B,mcf_158B] \
        [--bws 3200,1600,800] [--jobs 64]

Pipeline: build CellData per (trace, bw) cell (same loaders as
relabel_hint_bw.py) -> make_labels -> gen_bin into a scratch dir ->
run hint_eval sims in parallel -> parse cumulative IPC -> reward JSON.

Reward: log-geomean of ipc/ipc_no over the evaluated cells ("reward"),
same vs the wci labels ("reward_vs_wci"), plus per-cell IPCs. Reference
IPCs are read from the existing l1d-seg-x10 outputs (no.txt /
tax_wci.txt); a cell with a missing reference is dropped from that
geomean.

One reward evaluation costs len(traces) x len(bws) sims (1e7 warmup /
1e8 sim instructions each) - size the subset before searching.
"""
import argparse
import concurrent.futures as cf
import json
import math
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
CHAMPSIM = os.path.abspath(os.path.join(HERE, "..", ".."))

import relabel_hint_bw as R
from labeler import DEFAULT_CONFIG, PRESETS, config_slug

# ── campaign layout (see /tmp/rerun_pigougate.sh) ──
OB = "artifacts/runs/l1d-baseline-batch/20260822-172852"
NB = "artifacts/runs/l1d-baseline-batch/20260824-151432"
OW = "artifacts/runs/l1d-bw/20260822-173819"
NW = "artifacts/runs/l1d-bw/20260824-165928"
SEG = "artifacts/runs/l1d-seg-x10"
TRACE_ROOT = "/public/home/liz/trace/CRC2_trace"
TRACE_DIRS = ("discriminative", "non-discriminative", "parted-discriminative")
OLD12 = ("astar_", "cactusADM_", "h264ref_", "libquantum_", "mcf_", "milc_",
         "omnetpp_", "perlbench_", "soplex_", "sphinx3_", "xalancbmk_",
         "zeusmp_")
WARMUP, SIM_INST, SIM_TIMEOUT = 10000000, 100000000, 21600
EVAL_ROOT = os.path.join(CHAMPSIM, "artifacts/runs/l1d-rl-eval")


def is_old12(tname):
    return tname.startswith(OLD12)


def trace_path(tname):
    for d in TRACE_DIRS:
        p = os.path.join(TRACE_ROOT, d, tname + ".trace.xz")
        if os.path.isfile(p):
            return p
    return None


def ref_ipc(tname, bw, kind):
    """Cumulative IPC from an existing seg output (kind: no / tax_wci)."""
    txt = os.path.join(CHAMPSIM, SEG, tname, f"bw{bw}", f"{kind}.txt")
    ipc = R.seg_ipc(txt)
    return ipc


def build_bins(cfg, tag, traces, bws, stats, gdata):
    """Generate hint bins for every (trace, bw) cell into the scratch dir.
    gdata: (twaste, churn, ipc_gap, ipc_gap_no, waste, ipcs, no_ipcs)
    shared across cells. Returns {(tname, bw): bin_path}."""
    twaste, churn, ipc_gap, ipc_gap_no, waste, ipcs, no_ipcs = gdata
    run_dir = lambda t: os.path.join(CHAMPSIM, OW if is_old12(t) else NW)
    stage2 = lambda t: os.path.join(CHAMPSIM, OB if is_old12(t) else NB)
    out = {}
    for tname in traces:
        rd, sd = run_dir(tname), stage2(tname)
        gt3200 = R.load_ground_truth(os.path.join(sd, tname, "ground_truth.jsonl"))
        pc_w, pc_u = R.load_pc_weights(os.path.join(sd, tname, "profiling"))
        for bw in bws:
            if bw == "3200":
                data_dir = os.path.join(sd, tname)
                eval_dir = os.path.join(data_dir, "eval")
                gt_native = gt3200
                if not os.path.isdir(eval_dir):
                    stats["skipped"].append([tname, bw, "no eval dir"])
                    continue
            else:
                data_dir = os.path.join(rd, tname, f"bw{bw}")
                eval_dir = data_dir
                gt_native = R.load_ground_truth(
                    os.path.join(data_dir, "ground_truth.jsonl"))
            if not gt_native:
                stats["skipped"].append([tname, bw, "no ground truth"])
                continue
            gb = R.global_best(eval_dir) or R.GATE_FALLBACK
            acc = (twaste, churn, ipc_gap, ipc_gap_no,
                   R.l2_gaps(eval_dir), waste, ipcs,
                   no_ipcs.get((tname, f"bw{bw}")))
            cell_dir = os.path.join(EVAL_ROOT, tag, tname, f"bw{bw}")
            os.makedirs(cell_dir, exist_ok=True)
            written = R.run_schemes(
                [("hint.bin", cfg)], tname, f"bw{bw}",
                {"native": gt_native, "gt3200": gt3200},
                f"{gb[0]}:{gb[1]}", acc, pc_w, pc_u, ipcs, no_ipcs,
                os.path.join(data_dir, "hint_tax_wci.bin"),
                os.path.join(CHAMPSIM, SEG), cell_dir)
            if "hint.bin" in written:
                out[(tname, bw)] = written["hint.bin"]
            else:
                stats["skipped"].append([tname, bw, "no labels (wci bin missing?)"])
    return out


def run_sim(tname, bw, bin_path, out_dir):
    trace = trace_path(tname)
    if trace is None:
        return (tname, bw, None, "trace file not found")
    binary = os.path.join(CHAMPSIM, "bin", "champsim_hint_eval"
                          if bw == "3200" else f"champsim_hint_eval_bw{bw}")
    txt = os.path.join(out_dir, "sim.txt")
    with open(txt, "w") as f:
        rc = subprocess.run(
            ["timeout", str(SIM_TIMEOUT), binary,
             "--warmup-instructions", str(WARMUP),
             "--simulation-instructions", str(SIM_INST),
             "--hint-file", bin_path, trace],
            stdout=f, stderr=subprocess.STDOUT).returncode
    ipc = R.seg_ipc(txt)
    if rc != 0:
        return (tname, bw, ipc, f"sim rc={rc}")
    return (tname, bw, ipc, None if ipc is not None else "no IPC in output")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--config", help="JSON overrides on DEFAULT_CONFIG")
    src.add_argument("--preset", help="name from labeler.PRESETS")
    ap.add_argument("--traces", default=None,
                    help="comma-separated trace names (default: all 28)")
    ap.add_argument("--bws", default="3200,1600,800")
    ap.add_argument("--jobs", type=int, default=64)
    ap.add_argument("--tag", default=None, help="output tag (default: cfg_<hash>)")
    args = ap.parse_args()

    if args.preset:
        if args.preset not in PRESETS:
            sys.exit(f"unknown preset {args.preset!r}")
        cfg = PRESETS[args.preset]
        tag = args.tag or args.preset
    else:
        overrides = json.loads(args.config)
        unknown = set(overrides) - set(DEFAULT_CONFIG)
        if unknown:
            sys.exit(f"unknown config keys: {sorted(unknown)}")
        cfg = dict(DEFAULT_CONFIG)
        cfg.update(overrides)
        tag = args.tag or f"cfg_{config_slug(cfg)}"

    if args.traces:
        traces = [t.strip() for t in args.traces.split(",") if t.strip()]
    else:
        seg_root = os.path.join(CHAMPSIM, SEG)
        traces = sorted(
            t for t in os.listdir(seg_root)
            if os.path.isdir(os.path.join(
                CHAMPSIM, OB if is_old12(t) else NB, t))
            and trace_path(t) is not None)
    bws = [b.strip() for b in args.bws.split(",") if b.strip()]

    # global data (shared by all cells), loaded once through relabel's
    # loaders. Traces partition across the two campaign batches, so BOTH
    # prefetch_stats.csv files are needed (old-12 in OW, new-16 in NW).
    waste, twaste, churn, ipc_gap, ipc_gap_no, ipcs, no_ipcs = (
        {} for _ in range(7))
    for run_batch, stage2_batch in ((OW, OB), (NW, NB)):
        csv_path = os.path.join(CHAMPSIM, run_batch, "prefetch_stats.csv")
        waste.update(R.load_waste(csv_path))
        s2 = os.path.join(CHAMPSIM, stage2_batch)
        demand = {t: R.load_demand_total(os.path.join(s2, t, "profiling"))
                  for t in os.listdir(s2) if os.path.isdir(os.path.join(s2, t))}
        twaste.update(R.load_traffic_waste(csv_path, demand))
        churn.update(R.load_churn(csv_path, demand))
        g, gn, i, n = R.load_ipc_gaps(csv_path)
        ipc_gap.update(g); ipc_gap_no.update(gn); ipcs.update(i); no_ipcs.update(n)
    gdata = (twaste, churn, ipc_gap, ipc_gap_no, waste, ipcs, no_ipcs)

    stats = {"skipped": []}
    bins = build_bins(cfg, tag, traces, bws, stats, gdata)
    print(f"[eval_labeler] {len(bins)} bins ready, "
          f"{len(stats['skipped'])} cells skipped", file=sys.stderr)

    cells = {}
    work = []
    for (tname, bw), bin_path in sorted(bins.items()):
        out_dir = os.path.dirname(bin_path)
        work.append((tname, bw, bin_path, out_dir))
    with cf.ThreadPoolExecutor(max_workers=args.jobs) as ex:
        futs = {ex.submit(run_sim, *w): w for w in work}
        done = 0
        for fut in cf.as_completed(futs):
            tname, bw, ipc, err = fut.result()
            done += 1
            cells[f"{tname}@bw{bw}"] = {"ipc": ipc, **({"error": err} if err else {})}
            print(f"[eval_labeler] {done}/{len(work)} {tname} bw{bw} "
                  f"ipc={ipc}{' ERR:' + err if err else ''}", file=sys.stderr)

    def geomean_ratio(kind):
        vals = []
        for (tname, bw) in bins:
            c = cells.get(f"{tname}@bw{bw}", {})
            ref = ref_ipc(tname, bw, kind)
            if c.get("ipc") and ref:
                vals.append(math.log(c["ipc"] / ref))
        return (math.exp(sum(vals) / len(vals)), len(vals)) if vals else (None, 0)

    r_no, n_no = geomean_ratio("no")
    r_wci, n_wci = geomean_ratio("tax_wci")
    reward = {
        "tag": tag, "config": cfg,
        "reward": None if r_no is None else r_no - 1.0,
        "reward_vs_wci": None if r_wci is None else r_wci - 1.0,
        "cells": len(bins), "reward_cells": n_no, "reward_vs_wci_cells": n_wci,
        "per_cell": cells, "skipped": stats["skipped"],
    }
    out_dir = os.path.join(EVAL_ROOT, tag)
    os.makedirs(out_dir, exist_ok=True)
    with open(os.path.join(out_dir, "reward.json"), "w") as f:
        json.dump(reward, f, indent=1)
    # bins are tiny; the scratch dir is retained for postmortem either way
    print(json.dumps(reward))


if __name__ == "__main__":
    main()
