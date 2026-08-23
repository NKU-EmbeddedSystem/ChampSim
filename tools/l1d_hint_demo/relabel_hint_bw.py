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
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ORACLE_GEN = os.path.join(HERE, "oracle_gen.py")

LAMBDAS = {"l05": 0.5, "l20": 2.0}
GATE_THETA = 0.9

# 12-policy candidate set (see oracle_gen.py / hint_dispatch.h). Lowest tier
# per family is used as the conservative gate fallback — 'no' is no longer a
# dispatchable policy index.
CANDIDATE_FAMILIES = {
    "sandbox": [1, 4, 8],
    "dspatch": [1, 16, 64],
    "mlop": [1, 8, 16],
    "stream": [1, 4, 8],
}
CANDIDATE_KEYS = {(pf, deg) for pf, degs in CANDIDATE_FAMILIES.items() for deg in degs}
GATE_FALLBACK = ("sandbox", 1)  # lowest tier, policy index 0


def is_candidate(pf, deg):
    return (pf, deg) in CANDIDATE_KEYS


def all_amats_tied(rec):
    """True when every positive candidate AMAT is equal — the PC is
    insensitive to the prefetch policy (cold/tail PC)."""
    vals = []
    for key, amat in (rec.get("all_amats") or {}).items():
        pf, deg = key.rsplit(":", 1)
        if not is_candidate(pf, int(deg)):
            continue
        if float(amat) <= 0.0:
            continue
        vals.append(float(amat))
    return len(vals) >= 2 and max(vals) == min(vals)


IPC_RE = re.compile(r"cumulative IPC:\s*([\d.]+)")


def global_best(bw_dir):
    """Argmax cumulative IPC over the single-policy eval files in bw_dir.
    Returns (pf, deg) or None."""
    best = None
    best_ipc = 0.0
    for fn in os.listdir(bw_dir):
        m = re.match(r"^(sandbox|dspatch|mlop|stream)_d(\d+)\.txt$", fn)
        if not m:
            continue
        pf, deg = m.group(1), int(m.group(2))
        if not is_candidate(pf, deg):
            continue
        last = None
        try:
            with open(os.path.join(bw_dir, fn), errors="replace") as f:
                for line in f:
                    if "cumulative IPC" in line:
                        last = line
            v = float(IPC_RE.search(last).group(1))
        except (OSError, AttributeError, ValueError):
            continue
        if v > best_ipc:
            best_ipc, best = v, (pf, deg)
    return best


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
    """(trace, "ampm_d1", bw) -> waste ratio in [0,1]; 'no'/b0 -> 0

    Accuracy-based waste (1 - useful/issued): used by the GATE scheme,
    which thresholds on per-prefetch wastefulness.
    """
    waste = {}
    with open(csv_path) as f:
        for r in csv.DictReader(f):
            pf = r["prefetcher"]
            issued = int(r["pf_issued"])
            uhit = int(r["pf_useful_hit"])
            w = (issued - uhit) / issued if issued > 0 else 0.0
            waste[(r["trace"], pf, r["bw"])] = w
    return waste


def load_demand_total(profiling_dir):
    """Total demand accesses for the trace (policy-independent)."""
    if not os.path.isdir(profiling_dir):
        return 0
    for fn in os.listdir(profiling_dir):
        if not fn.endswith(".json"):
            continue
        tot = 0
        with open(os.path.join(profiling_dir, fn)) as f:
            for line in f:
                try:
                    tot += json.loads(line).get("access_count", 0)
                except json.JSONDecodeError:
                    pass
        return tot
    return 0


def load_traffic_waste(csv_path, demand_by_trace):
    """(trace, stat_name, bw) -> absolute-traffic waste = useless
    prefetches per demand access. Unlike 1-accuracy, this spreads
    policies apart on low-accuracy traces: dspatch on mcf ~ 1.3,
    sandbox ~ 0.6, stream ~ 0.05 — the tax can actually discriminate."""
    waste = {}
    with open(csv_path) as f:
        for r in csv.DictReader(f):
            dem = demand_by_trace.get(r["trace"], 0)
            w = int(r["pf_useless"]) / dem if dem > 0 else 0.0
            waste[(r["trace"], r["prefetcher"], r["bw"])] = w
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
    waste = load_waste(stats_csv)  # accuracy-based: gate scheme
    demand_by_trace = {tname: load_demand_total(os.path.join(stage2_dir, tname, "profiling"))
                       for tname in os.listdir(stage2_dir)}
    twaste = load_traffic_waste(stats_csv, demand_by_trace)  # traffic-based: tax schemes

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
            gb = global_best(bw_dir) or GATE_FALLBACK  # this bw's offline global best
            gb_key = f"{gb[0]}:{gb[1]}"

            def waste_of(pf, deg):
                if pf == "no":
                    return 0.0
                return waste.get((tname, policy_to_stat_name(pf, deg), bw), 0.0)

            # ── Scheme A: bandwidth tax on native ground truth ──
            for lname, lam in LAMBDAS.items():
                labels = []
                for pc, rec in gt_native.items():
                    if all_amats_tied(rec):
                        best_key = gb_key  # no per-PC signal: trace-wide best
                    else:
                        best_key, best_score = None, None
                        for key, amat in rec["all_amats"].items():
                            pf, deg = key.rsplit(":", 1)
                            deg = int(deg)
                            if not is_candidate(pf, deg):  # 'no' / stale 15-policy labels
                                continue
                            if float(amat) <= 0.0:
                                continue  # no measured data under this policy
                            w = twaste.get((tname, policy_to_stat_name(pf, deg), bw), 0.0)
                            score = amat * (1.0 + lam * w)
                            if best_score is None or score < best_score:
                                best_key, best_score = key, score
                        if best_key is None:
                            best_key = gb_key  # no data: trace-wide best
                    pf, deg = best_key.rsplit(":", 1)
                    labels.append({"pc": pc, "best_prefetch": pf, "best_degree": int(deg)})
                out = os.path.join(bw_dir, f"hint_tax_{lname}.bin")
                gen_bin(labels, out)

            # ── Scheme B: 3200 label + waste gate at target bw ──
            labels = []
            for pc, rec in gt3200.items():
                if pc in gt_native and all_amats_tied(gt_native[pc]):
                    pf, deg = gb  # no per-PC signal: this bw's trace-wide best
                else:
                    pf, deg = rec["best_prefetch"], int(rec.get("best_degree", 1))
                    if not is_candidate(pf, deg):
                        pf, deg = GATE_FALLBACK
                    elif waste_of(pf, deg) > GATE_THETA:
                        # conservative fallback: same family, lowest tier
                        pf, deg = pf, min(CANDIDATE_FAMILIES[pf])
                labels.append({"pc": pc, "best_prefetch": pf, "best_degree": deg})
            out = os.path.join(bw_dir, "hint_gate_t90.bin")
            gen_bin(labels, out)

            # ── Scheme A-fine: per-PC bandwidth tax on native ground truth ──
            if cost_base:
                pc_cost = load_pc_cost(os.path.join(cost_base, tname, "profiling"))
                for lname, lam in LAMBDAS.items():
                    labels = []
                    for pc, rec in gt_native.items():
                        if all_amats_tied(rec):
                            best_key = gb_key  # no per-PC signal: trace-wide best
                        else:
                            best_key, best_score = None, None
                            for key, amat in rec["all_amats"].items():
                                pf, deg = key.rsplit(":", 1)
                                if not is_candidate(pf, int(deg)):
                                    continue
                                if float(amat) <= 0.0:
                                    continue  # no measured data under this policy
                                w = pc_cost.get((pc, key), 0.0)
                                score = amat * (1.0 + lam * w)
                                if best_score is None or score < best_score:
                                    best_key, best_score = key, score
                            if best_key is None:
                                best_key = gb_key  # no data: trace-wide best
                        pf, deg = best_key.rsplit(":", 1)
                        labels.append({"pc": pc, "best_prefetch": pf, "best_degree": int(deg)})
                    out = os.path.join(bw_dir, f"hint_pc_tax_{lname}.bin")
                    gen_bin(labels, out)

            # quick distribution summary: share of lowest-tier (conservative) labels
            from collections import Counter
            dist_a = Counter((l["best_prefetch"], l["best_degree"]) for l in labels)
            low_share = sum(c for (pf, deg), c in dist_a.items() if deg == min(CANDIDATE_FAMILIES[pf]))
            print(f"{tname} {bw}: lowest-tier share = "
                  f"{100*low_share/max(len(labels),1):.0f}% of {len(labels)} PCs")

        # ── bw3200: bandwidth tax on the 3200 ground truth ──
        # The per-PC AMAT vs global IPC misalignment exists at 3200 too
        # (e.g. mcf: dspatch wins per-PC AMAT but floods the channel), so
        # the tax schemes apply at native bandwidth as well. Tied PCs get
        # the trace-wide best without tax.
        eval_dir = os.path.join(stage2_dir, tname, "eval")
        if not os.path.isdir(eval_dir):
            continue
        gb3200 = global_best(eval_dir) or GATE_FALLBACK
        for lname, lam in LAMBDAS.items():
            labels = []
            for pc, rec in gt3200.items():
                if all_amats_tied(rec):
                    best_key = f"{gb3200[0]}:{gb3200[1]}"
                else:
                    best_key, best_score = None, None
                    for key, amat in rec["all_amats"].items():
                        pf, deg = key.rsplit(":", 1)
                        if not is_candidate(pf, int(deg)):
                            continue
                        if float(amat) <= 0.0:
                            continue  # no measured data under this policy
                        w = twaste.get((tname, policy_to_stat_name(pf, int(deg)), "bw3200"), 0.0)
                        score = amat * (1.0 + lam * w)
                        if best_score is None or score < best_score:
                            best_key, best_score = key, score
                    if best_key is None:
                        best_key = f"{gb3200[0]}:{gb3200[1]}"  # no data: trace-wide best
                pf, deg = best_key.rsplit(":", 1)
                labels.append({"pc": pc, "best_prefetch": pf, "best_degree": int(deg)})
            out = os.path.join(stage2_dir, tname, f"hint_tax_{lname}.bin")
            gen_bin(labels, out)


if __name__ == "__main__":
    main()
