#!/usr/bin/env python3
"""Per-(trace, prefetcher, bandwidth) prefetch statistics.

Extracts from ChampSim stdout:
  - cumulative IPC
  - L1D PREFETCH REQUESTED / ISSUED / USEFUL / USELESS
  - derived: DROPPED = REQUESTED - ISSUED (back-pressure / queue-full drops)

bw3200 comes from the stage2 batch run (eval/*.txt), bw1600/bw800 from a
stage3 bandwidth run (<trace>/<bw>/*.txt). b2_hint (hint-dispatch) is included
as a pseudo-prefetcher when present.

Usage:
  python3 prefetch_bw_stats.py [bw_run_dir] [bw3200_eval_base]
Outputs:
  <bw_run_dir>/prefetch_stats.csv   (long-format table)
  printed summary: top-N distribution + hint-dispatch across bandwidth
"""
import os, re, sys, csv
from collections import defaultdict

champsim_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
run_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(champsim_root, "artifacts/runs/l1d-bw/20260802-142911")
bw3200_base = sys.argv[2] if len(sys.argv) > 2 else os.path.join(champsim_root, "artifacts/runs/stage2-l1d-batch/20260801-121706")

ipc_re = re.compile(r"cumulative IPC:\s*([\d.]+)")
pf_re = re.compile(r"cpu0_L1D PREFETCH REQUESTED:\s*(\d+)\s+ISSUED:\s*(\d+)\s+USEFUL:\s*(\d+)\s+USEFUL_HIT:\s*(\d+)\s+USEFUL_LATE:\s*(\d+)\s+USELESS:\s*(\d+)")
pf_re_legacy = re.compile(r"cpu0_L1D PREFETCH REQUESTED:\s*(\d+)\s+ISSUED:\s*(\d+)\s+USEFUL:\s*(\d+)\s+USELESS:\s*(\d+)")

def parse(path):
    """Return dict(ipc, req, issued, useful, useful_hit, useful_late, useless) or None if run invalid."""
    if not os.path.isfile(path):
        return None
    with open(path) as f:
        content = f.read()
    if "DEADLOCK" in content or "Simulation complete" not in content:
        return None
    m = ipc_re.findall(content)
    p = pf_re.search(content)
    if p:
        useful, uhit, ulate, useless = int(p.group(3)), int(p.group(4)), int(p.group(5)), int(p.group(6))
        req, issued = int(p.group(1)), int(p.group(2))
    else:
        # legacy format without the hit/late split
        p = pf_re_legacy.search(content)
        req, issued = (int(p.group(1)), int(p.group(2))) if p else (0, 0)
        useful, useless = (int(p.group(3)), int(p.group(4))) if p else (0, 0)
        uhit, ulate = -1, -1  # unknown
    return {
        "ipc": float(m[-1]) if m else None,
        "req": req,
        "issued": issued,
        "useful": useful,
        "useful_hit": uhit,
        "useful_late": ulate,
        "useless": useless,
    }

# data[trace][pref][bw] = stats
data = defaultdict(lambda: defaultdict(dict))

# bw3200 from stage2 eval dirs
for tname in sorted(os.listdir(bw3200_base)):
    eval_dir = os.path.join(bw3200_base, tname, "eval")
    if not os.path.isdir(eval_dir):
        continue
    for fn in sorted(os.listdir(eval_dir)):
        if not fn.endswith(".txt") or fn == "b1_best.txt":
            continue
        st = parse(os.path.join(eval_dir, fn))
        if st:
            data[tname][fn[:-4]]["bw3200"] = st

# bw1600/bw800 from the bw run
for tname in sorted(os.listdir(run_dir)):
    tdir = os.path.join(run_dir, tname)
    if not os.path.isdir(tdir):
        continue
    for bw in ("bw1600", "bw800"):
        bw_dir = os.path.join(tdir, bw)
        if not os.path.isdir(bw_dir):
            continue
        for fn in sorted(os.listdir(bw_dir)):
            if not fn.endswith(".txt"):
                continue
            st = parse(os.path.join(bw_dir, fn))
            if st:
                data[tname][fn[:-4]][bw] = st

# ── Write long-format CSV ──
csv_path = os.path.join(run_dir, "prefetch_stats.csv")
rows = []
for tname, prefs in sorted(data.items()):
    for pref, bws in sorted(prefs.items()):
        for bw in ("bw3200", "bw1600", "bw800"):
            st = bws.get(bw)
            if not st:
                continue
            rows.append({
                "trace": tname, "prefetcher": pref, "bw": bw,
                "ipc": st["ipc"], "pf_requested": st["req"], "pf_issued": st["issued"],
                "pf_dropped": st["req"] - st["issued"],
                "pf_useful": st["useful"], "pf_useful_hit": st["useful_hit"], "pf_useful_late": st["useful_late"],
                "pf_useless": st["useless"],
            })
with open(csv_path, "w", newline="") as f:
    w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
    w.writeheader()
    w.writerows(rows)
print(f"Wrote {len(rows)} rows -> {csv_path}")

ALL_BW = ("bw3200", "bw1600", "bw800")

# ── Analysis 1: prefetch volume/drop/useful shifts across bw ──
print(f"\n{'='*112}")
print("  Prefetch volume vs bandwidth (requested / dropped / useful; rows sorted by bw3200 requested)")
print(f"{'='*112}")
for tname, prefs in sorted(data.items()):
    cands = [(p, bws) for p, bws in prefs.items() if p != "b0_no" and "bw3200" in bws and len(bws) == 3]
    if not cands:
        continue
    cands.sort(key=lambda x: x[1]["bw3200"]["req"], reverse=True)
    print(f"\n  {tname}:")
    print(f"  {'prefetcher':<16} {'req3200':>8} {'req1600':>8} {'req800':>8} {'drp3200':>8} {'drp1600':>8} {'drp800':>8}"
          f" {'uhit3200':>8} {'uhit1600':>8} {'uhit800':>8} {'ult3200':>8} {'ult1600':>8} {'ult800':>8}")
    shown = 0
    for pref, bws in cands:
        if shown >= 8 and pref != "b2_hint":
            continue
        r = [bws[bw]["req"] for bw in ALL_BW]
        d = [bws[bw]["req"] - bws[bw]["issued"] for bw in ALL_BW]
        uh = [bws[bw]["useful_hit"] for bw in ALL_BW]
        ul = [bws[bw]["useful_late"] for bw in ALL_BW]
        print(f"  {pref:<16} {r[0]:>8} {r[1]:>8} {r[2]:>8} {d[0]:>8} {d[1]:>8} {d[2]:>8}"
              f" {uh[0]:>8} {uh[1]:>8} {uh[2]:>8} {ul[0]:>8} {ul[1]:>8} {ul[2]:>8}")
        shown += 1

# ── Analysis 2: top-N distribution shift ──
TOPN = 5
print(f"\n{'='*112}")
print(f"  Top-{TOPN} prefetchers by IPC per trace per bandwidth")
print(f"{'='*112}")
top_sets = {}
for tname, prefs in sorted(data.items()):
    tops = {}
    for bw in ALL_BW:
        cands = {p: st["ipc"] for p, bws in prefs.items() for bw2, st in bws.items()
                 if bw2 == bw and p != "b0_no" and st["ipc"] is not None}
        tops[bw] = [p for p, _ in sorted(cands.items(), key=lambda x: x[1], reverse=True)[:TOPN]]
    top_sets[tname] = tops
    o32_16 = len(set(tops["bw3200"]) & set(tops["bw1600"]))
    o32_8 = len(set(tops["bw3200"]) & set(tops["bw800"]))
    print(f"  {tname:<18} 3200: {', '.join(tops['bw3200'])}")
    print(f"  {'':<18} 1600: {', '.join(tops['bw1600'])}   (overlap w/3200: {o32_16}/{TOPN})")
    print(f"  {'':<18}  800: {', '.join(tops['bw800'])}   (overlap w/3200: {o32_8}/{TOPN})")

print(f"\n  Top-{TOPN} appearance count across 12 traces:")
freq = defaultdict(lambda: defaultdict(int))
for tname, tops in top_sets.items():
    for bw in ALL_BW:
        for p in tops[bw]:
            freq[p][bw] += 1
print(f"  {'prefetcher':<18} {'bw3200':>7} {'bw1600':>7} {'bw800':>7}")
for p in sorted(freq, key=lambda p: -freq[p]["bw3200"]):
    print(f"  {p:<18} {freq[p]['bw3200']:>7} {freq[p]['bw1600']:>7} {freq[p]['bw800']:>7}")

# ── Analysis 3: hint-dispatch across bandwidth (3200-trained vs bw-native) ──
print(f"\n{'='*112}")
print("  Hint-dispatch across bandwidth (b2_hint = trained at bw3200, b2_hint_native = trained at matching bw)")
print(f"{'='*112}")
print(f"  {'trace':<18} {'bw':>7} {'variant':<15} {'IPC':>8} {'B0_IPC':>8} {'req':>9} {'dropped':>9} {'useful':>9} {'usef_hit':>9} {'usef_late':>9} {'useless':>9}")
for tname, prefs in sorted(data.items()):
    b0 = prefs.get("b0_no", {})
    for bw in ALL_BW:
        for variant in ("b2_hint", "b2_hint_native", "b3_hint_tax_l05", "b3_hint_tax_l20", "b4_hint_gate", "b5_hint_pc_tax_l05", "b5_hint_pc_tax_l20", "c3_accgate"):
            st = prefs.get(variant, {}).get(bw)
            if not st:
                continue
            b0ipc = b0.get(bw, {}).get("ipc")
            print(f"  {tname:<18} {bw:>7} {variant:<15} {st['ipc']:>8.4f} {b0ipc if b0ipc else 0:>8.4f} {st['req']:>9} {st['req']-st['issued']:>9} {st['useful']:>9}"
                  f" {st['useful_hit']:>9} {st['useful_late']:>9} {st['useless']:>9}")
