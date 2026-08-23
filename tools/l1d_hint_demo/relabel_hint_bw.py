#!/usr/bin/env python3
"""Bandwidth-aware hint relabeling (coarse-grained, per-trace waste ratios).

Uses existing data only — no new profiling sims:
  - ground_truth.jsonl per (trace, bw): per-PC AMAT for every prefetcher:degree
  - prefetch_stats.csv: per (trace, prefetcher_degree, bw) global counters + IPC

Tax ablation ladder (all relabel on bw-native ground truth):
  score(pc, pf:deg) = amat * (1 + lam_w*waste + CHURN_LAMBDA*churn
                              + lam_i*ipc_gap + lam_l*l2_gap)
    waste    = useless / demand        (absolute DRAM traffic per demand access)
    churn    = extra net issues vs the family's best-IPC degree, / demand
    ipc_gap  = 1 - ipc / ipc_best      (opportunity cost vs the trace's best policy)
    l2_gap   = hitrate_best - hitrate  (diffuse L2 pollution: prefetch lines
                                        evicting demand lines hurt every PC's
                                        L2 hit rate — invisible to per-PC AMAT)
  Variants: w (waste), wc (+churn), wci (+ipc gap). Retired: wcl/wcil
  (L2-pollution tax — real signal, failed as a per-PC linear tax, see
  comment at VARIANTS).

Scheme B (hybrid gating), keeps the bw3200-trained label (clean signal):
    if waste(chosen pf:deg, trace, target bw) > theta -> relabel PC to lowest tier

Usage:
  python3 relabel_hint_bw.py <bw_run_dir> <stage2_run_dir> <prefetch_stats.csv> [cost_profile_dir]
"""
import csv
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ORACLE_GEN = os.path.join(HERE, "oracle_gen.py")

CHURN_LAMBDA = 1.0  # pipeline-occupancy tax weight (issued/demand)
GATE_THETA = 0.9

# Ablation ladder over tax terms: name -> (waste weight, churn?, ipc-gap
# weight, l2-pollution weight). Each rung CUMULATES the previous one's terms.
#   w   : absolute-traffic waste tax only
#   wc  : + IPC-gated churn tax (degree selection within a family)
#   wci : + opportunity-cost tax (policy's global IPC gap to the trace's best)
# IPC_LAMBDA=0.5 flips noise picks (local AMAT edge <=2%) while real edges
# (milc's dspatch_d64 hot PCs, ~15%) survive the charge.
#
# Retired (failed): wcl (waste+churn+L2-pollution) and wcil. The
# L2-pollution tax — demand L2 hit-rate gap of the isolated policy run — is
# a real diffuse-cost signal but fails as a per-PC linear tax:
#   (a) pollution is superlinear in the polluter's rate: cactusADM keeps a
#       9%-miss-mass sandbox residue whose flood drops the mix's L2 hit rate
#       75%->35% (below the 48%-mass variant), so flipping marginal PCs to
#       the clean policy ADDS victims and loses IPC;
#   (b) the isolated hit rate conflates self-coverage with externality:
#       xalancbmk's hr-champion (dspatch_d1, 87.7%) is a -33% IPC policy,
#       so the tax steers toward hit-rate gamers.
# Net geomean worse than wci at every bandwidth. l2_gaps() is kept so the
# experiment is one tuple away from rerunning; bins/sims stay on disk.
VARIANTS = {
    "w": (0.5, False, 0.0, 0.0),
    "wc": (0.5, True, 0.0, 0.0),
    "wci": (0.5, True, 0.5, 0.0),
}

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


def load_churn(csv_path, demand_by_trace):
    """(trace, stat_name, bw) -> pipeline churn tax for degree selection.

    For each family, the degree with the best GLOBAL IPC is the reference
    (its extra issues are evidently productive). Any other degree pays a
    tax equal to its extra net-waste above the reference:
        [(issued - useful_hit) - (issued_ref - useful_hit_ref)] / demand
    This penalizes degree inflation only when the market (global IPC) has
    proven it net-harmful — cactusADM stream_d8 pays, soplex stream_d8
    (genuinely better than d1) pays nothing.
    """
    issued = {}
    hits = {}
    ipcs = {}
    with open(csv_path) as f:
        for r in csv.DictReader(f):
            dem = demand_by_trace.get(r["trace"], 0)
            key = (r["trace"], r["prefetcher"], r["bw"])
            issued[key] = int(r["pf_issued"]) / dem if dem > 0 else 0.0
            hits[key] = int(r["pf_useful_hit"]) / dem if dem > 0 else 0.0
            try:
                ipcs[key] = float(r["ipc"])
            except ValueError:
                ipcs[key] = 0.0
    # per (trace, family, bw): best-IPC degree and its net waste
    best = {}
    for (t, name, bw), ipc in ipcs.items():
        m = re.match(r"^(sandbox|dspatch|mlop|stream)_d\d+$", name)
        if not m:
            continue
        fam_key = (t, m.group(1), bw)
        if fam_key not in best or ipc > best[fam_key][0]:
            best[fam_key] = (ipc, issued[(t, name, bw)] - hits[(t, name, bw)])
    churn = {}
    for (t, name, bw), v in issued.items():
        m = re.match(r"^(sandbox|dspatch|mlop|stream)_d\d+$", name)
        if not m:
            continue
        ref_net = best[(t, m.group(1), bw)][1]
        churn[(t, name, bw)] = max(0.0, (v - hits[(t, name, bw)]) - ref_net)
    return churn


def load_ipc_gaps(csv_path):
    """(trace, stat_name, bw) -> 1 - ipc/ipc_best over the 12 candidates.

    Opportunity-cost tax: a policy whose full-trace IPC sits far below the
    trace's best must beat that policy locally by a comparable margin to
    win a PC. This is the cross-family generalization of the churn tax
    (which only compares degrees within one family).
    """
    ipcs = {}
    with open(csv_path) as f:
        for r in csv.DictReader(f):
            if not re.match(r"^(sandbox|dspatch|mlop|stream)_d\d+$", r["prefetcher"]):
                continue
            try:
                ipcs[(r["trace"], r["prefetcher"], r["bw"])] = float(r["ipc"])
            except ValueError:
                pass
    best = {}
    for (t, name, bw), v in ipcs.items():
        best[(t, bw)] = max(best.get((t, bw), 0.0), v)
    gap = {}
    for (t, name, bw), v in ipcs.items():
        b = best.get((t, bw), 0.0)
        gap[(t, name, bw)] = max(0.0, 1.0 - v / b) if b > 0 else 0.0
    return gap


L2_LOAD_RE = re.compile(r"^cpu0->cpu0_L2C LOAD\s+ACCESS:\s*(\d+) HIT:\s*(\d+)")


def l2_gaps(bw_dir):
    """(pf, deg) -> L2-pollution tax = max(0, hr_best - hr) over the 12
    candidates' eval files in bw_dir.

    The demand L2 hit rate is a global observable: prefetch pollution that
    evicts demand-needed lines slows every PC's L2 hits, which per-PC AMAT
    structurally cannot see (benefit concentrates in the prefetching PC,
    cost diffuses to everyone). The isolated single-policy runs already
    carry the signature — cactusADM: stream_d1 75.5% vs sandbox 53% — so
    no new experiment is needed, just this parse."""
    hrs = {}
    for fn in os.listdir(bw_dir):
        m = re.match(r"^(sandbox|dspatch|mlop|stream)_d(\d+)\.txt$", fn)
        if not m:
            continue
        pf, deg = m.group(1), int(m.group(2))
        if not is_candidate(pf, deg):
            continue
        try:
            with open(os.path.join(bw_dir, fn), errors="replace") as f:
                for line in f:
                    mm = L2_LOAD_RE.match(line)
                    if mm:
                        acc, hit = int(mm.group(1)), int(mm.group(2))
                        hrs[(pf, deg)] = hit / acc if acc > 0 else None
                        break
        except OSError:
            continue
    best = max((v for v in hrs.values() if v is not None), default=None)
    if best is None:
        return {}
    return {k: max(0.0, best - v) for k, v in hrs.items() if v is not None}


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
    churn = load_churn(stats_csv, demand_by_trace)  # pipeline-occupancy tax: degree selection
    ipc_gap = load_ipc_gaps(stats_csv)  # opportunity-cost tax: policy selection

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

            # ── Scheme A: tax ablation ladder on native ground truth ──
            l2g = l2_gaps(bw_dir)
            for lname, (lam_w, use_churn, lam_i, lam_l2) in VARIANTS.items():
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
                            sname = policy_to_stat_name(pf, deg)
                            w = twaste.get((tname, sname, bw), 0.0)
                            c = churn.get((tname, sname, bw), 0.0) if use_churn else 0.0
                            g = lam_i * ipc_gap.get((tname, sname, bw), 0.0)
                            l = lam_l2 * l2g.get((pf, deg), 0.0)
                            score = amat * (1.0 + lam_w * w + CHURN_LAMBDA * c + g + l)
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
        l2g3200 = l2_gaps(eval_dir)
        for lname, (lam_w, use_churn, lam_i, lam_l2) in VARIANTS.items():
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
                        sname = policy_to_stat_name(pf, int(deg))
                        w = twaste.get((tname, sname, "bw3200"), 0.0)
                        c = churn.get((tname, sname, "bw3200"), 0.0) if use_churn else 0.0
                        g = lam_i * ipc_gap.get((tname, sname, "bw3200"), 0.0)
                        l = lam_l2 * l2g3200.get((pf, int(deg)), 0.0)
                        score = amat * (1.0 + lam_w * w + CHURN_LAMBDA * c + g + l)
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
