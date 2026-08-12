#!/usr/bin/env python3
"""Bandwidth-aware hint relabeling (coarse-grained, per-trace waste ratios).

Uses existing data only — no new profiling sims:
  - ground_truth.jsonl per (trace, bw): per-PC AMAT for every prefetcher:degree
  - prefetch_stats.csv: per (trace, prefetcher_degree, bw) global counters

Scheme A (bandwidth tax), relabels on bw-native ground truth:
    score(pc, pf:deg) = amat * (1 + lambda * waste(pf:deg, trace, bw))
    waste = (issued - useful_hit) / issued   (global per trace/prefetcher/bw)

Scheme B (hybrid gating), keeps the bw3200-trained label (clean signal):
    if waste(chosen pf:deg, trace, target bw) > theta -> relabel PC to 'no'

Usage:
  python3 relabel_hint_bw.py <bw_run_dir> <stage2_run_dir> <prefetch_stats.csv> [cost_profile_dir]

If cost_profile_dir (per-PC cost profiling at bw3200, layout <trace>/profiling/*.json)
is given, additionally generates fine-grained per-PC variants:
  hint_pc_tax_l05.bin / hint_pc_tax_l20.bin
    score(pc, pf:deg) = amat_native(pc, pf:deg) * (1 + lambda * waste_pc)
    waste_pc = (issued_pc - hit_pc) / issued_pc   (per PC, per prefetcher:degree)
"""
import csv
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ORACLE_GEN = os.path.join(HERE, "oracle_gen.py")

LAMBDAS = {"l05": 0.5, "l20": 2.0}
GATE_THETA = 0.9


def load_ground_truth(path):
    """pc -> {"best_prefetch","best_degree","all_amats"}"""
    out = {}
    if not os.path.isfile(path):
        return out
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            rec = json.loads(line)
            out[rec["pc"]] = rec
    return out


def load_waste(csv_path):
    """(trace, "ampm_d1", bw) -> waste ratio in [0,1]; 'no'/b0 -> 0"""
    waste = {}
    with open(csv_path) as f:
        for r in csv.DictReader(f):
            pf = r["prefetcher"]
            issued = int(r["pf_issued"])
            uhit = int(r["pf_useful_hit"])
            w = (issued - uhit) / issued if issued > 0 else 0.0
            waste[(r["trace"], pf, r["bw"])] = w
    return waste


def policy_to_stat_name(pf, deg):
    return f"{pf}_d{deg}"


def load_pc_cost(profile_dir):
    """Load per-PC prefetch cost from a profiling dir of <trace>__<pf>__<deg>.json files.
    Returns dict: (pc, "pf:deg") -> waste ratio in [0,1]."""
    import re
    fname_re = re.compile(r"(.+?)__(.+?)__(\d+)\.json$")
    cost = {}
    if not profile_dir or not os.path.isdir(profile_dir):
        return cost
    for fn in os.listdir(profile_dir):
        m = fname_re.match(fn)
        if not m:
            continue
        _, pf, deg = m.group(1), m.group(2), int(m.group(3))
        key = f"{pf}:{deg}"
        with open(os.path.join(profile_dir, fn)) as f:
            for line in f:
                line = line.strip()
                if not line.startswith("{"):
                    continue
                try:
                    rec = json.loads(line)
                except json.JSONDecodeError:
                    continue
                pc = rec.get("pc", "")
                pc = pc.lower() if isinstance(pc, str) else f"0x{pc:x}"
                issued = int(rec.get("prefetch_issued", 0))
                hit = int(rec.get("prefetch_hit", 0))
                if issued > 0:
                    cost[(pc, key)] = (issued - hit) / issued
    return cost


def gen_bin(labels, out_path):
    """labels: list of {"pc","best_prefetch","best_degree"}; write via oracle_gen."""
    tmp = out_path + ".jsonl"
    with open(tmp, "w") as f:
        for rec in labels:
            f.write(json.dumps(rec) + "\n")
    subprocess.run([sys.executable, ORACLE_GEN, "generate", "--labels", tmp, "--output", out_path],
                   check=True, capture_output=True)
    os.remove(tmp)


def main():
    run_dir, stage2_dir, stats_csv = sys.argv[1], sys.argv[2], sys.argv[3]
    cost_base = sys.argv[4] if len(sys.argv) > 4 else None
    waste = load_waste(stats_csv)

    for tname in sorted(os.listdir(run_dir)):
        tdir = os.path.join(run_dir, tname)
        if not os.path.isdir(tdir):
            continue
        gt3200 = load_ground_truth(os.path.join(stage2_dir, tname, "ground_truth.jsonl"))

        for bw in ("bw1600", "bw800"):
            bw_dir = os.path.join(tdir, bw)
            gt_native = load_ground_truth(os.path.join(bw_dir, "ground_truth.jsonl"))
            if not gt_native:
                continue

            def waste_of(pf, deg):
                if pf == "no":
                    return 0.0
                return waste.get((tname, policy_to_stat_name(pf, deg), bw), 0.0)

            # ── Scheme A: bandwidth tax on native ground truth ──
            for lname, lam in LAMBDAS.items():
                labels = []
                for pc, rec in gt_native.items():
                    best_key, best_score = None, None
                    for key, amat in rec["all_amats"].items():
                        pf, deg = key.rsplit(":", 1)
                        score = amat * (1.0 + lam * waste_of(pf, deg))
                        if best_score is None or score < best_score:
                            best_key, best_score = key, score
                    pf, deg = best_key.rsplit(":", 1)
                    labels.append({"pc": pc, "best_prefetch": pf, "best_degree": int(deg)})
                out = os.path.join(bw_dir, f"hint_tax_{lname}.bin")
                gen_bin(labels, out)

            # ── Scheme B: 3200 label + waste gate at target bw ──
            labels = []
            for pc, rec in gt3200.items():
                pf, deg = rec["best_prefetch"], int(rec.get("best_degree", 1))
                if pf != "no" and waste_of(pf, deg) > GATE_THETA:
                    pf, deg = "no", 1
                labels.append({"pc": pc, "best_prefetch": pf, "best_degree": deg})
            out = os.path.join(bw_dir, "hint_gate_t90.bin")
            gen_bin(labels, out)

            # ── Scheme A-fine: per-PC bandwidth tax on native ground truth ──
            if cost_base:
                pc_cost = load_pc_cost(os.path.join(cost_base, tname, "profiling"))
                for lname, lam in LAMBDAS.items():
                    labels = []
                    for pc, rec in gt_native.items():
                        best_key, best_score = None, None
                        for key, amat in rec["all_amats"].items():
                            pf, _ = key.rsplit(":", 1)
                            w = 0.0 if pf == "no" else pc_cost.get((pc, key), 0.0)
                            score = amat * (1.0 + lam * w)
                            if best_score is None or score < best_score:
                                best_key, best_score = key, score
                        pf, deg = best_key.rsplit(":", 1)
                        labels.append({"pc": pc, "best_prefetch": pf, "best_degree": int(deg)})
                    out = os.path.join(bw_dir, f"hint_pc_tax_{lname}.bin")
                    gen_bin(labels, out)

            # quick distribution summary
            from collections import Counter
            for fn in (f"hint_tax_{n}.bin" for n in LAMBDAS):
                pass
            dist_a = Counter(l["best_prefetch"] for l in labels)
            print(f"{tname} {bw}: gate_t90 no-share = "
                  f"{100*dist_a.get('no',0)/max(len(labels),1):.0f}% of {len(labels)} PCs")


if __name__ == "__main__":
    main()
