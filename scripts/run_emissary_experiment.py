#!/usr/bin/env python3
"""
EMISSARY Validation Experiment
================================
Compares four L2C configurations to validate EMISSARY and the partitioned
heterogeneous approach.

Configurations:
  Baseline:    LRU                  @ 8-way  (full LRU, current default)
  Phase 1:     EMISSARY P(N)        @ 8-way  (full EMISSARY replacement)
  Phase 2:     LRU(4W) + P(N)(4W)   @ 8-way  (partitioned heterogeneous)
  Extra:       LRU                  @ 4-way  (capacity comparison baseline)

Output:
  emissary_experiment_summary.csv  — all metrics per (trace × config)
  emissary_experiment_report.md    — comparative analysis

Usage:
  # Full experiment on selected traces:
  python scripts/run_emissary_experiment.py -j 4

  # Custom traces:
  python scripts/run_emissary_experiment.py \\
      --traces barnes_1,facesim_1,fft_m24,streamcluster_1 -j 4
"""

import argparse
import csv
import json
import os
import shutil
import subprocess
import sys
from collections import defaultdict
from concurrent.futures import ProcessPoolExecutor, as_completed
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
PROJECT_ROOT = Path(__file__).resolve().parent.parent
CHAMPSIM_BIN_DIR = PROJECT_ROOT / "bin"
DEFAULT_CONFIG = PROJECT_ROOT / "champsim_config.json"

# Simulation parameters
WARMUP_INSTRUCTIONS  = 50_000_000
SIM_INSTRUCTIONS     = 500_000_000

# ---------------------------------------------------------------------------
# Four experiment configurations
# ---------------------------------------------------------------------------
CONFIGS = {
    "baseline": {
        "label": "Baseline LRU 8W",
        "binary": "champsim_baseline",
        "l2_ways": 8,
        "replacement": "lru",
        "partitioned": False,
    },
    "emissary": {
        "label": "Phase1 EMISSARY 8W",
        "binary": "champsim_emissary",
        "l2_ways": 8,
        "replacement": "emissary",
        "partitioned": False,
    },
    "partitioned": {
        "label": "Phase2 Partitioned 4+4W",
        "binary": "champsim_partitioned",
        "l2_ways": 8,
        "replacement": "partitioned_emissary",
        "partitioned": True,
    },
    "lru4w": {
        "label": "Extra LRU 4W",
        "binary": "champsim_lru4w",
        "l2_ways": 4,
        "replacement": "lru",
        "partitioned": False,
    },
}

# ---------------------------------------------------------------------------
# Data structures
# ---------------------------------------------------------------------------
@dataclass
class SimResult:
    trace_name: str
    config_name: str
    config_label: str
    l2_ways: int
    status: str = "PENDING"

    instructions: int = 0
    cycles: int = 0
    ipc: float = 0.0

    # L2C
    l2c_total_access: int = 0
    l2c_total_hit: int = 0
    l2c_total_miss: int = 0
    l2c_hit_rate: float = 0.0
    l2c_mpki: float = 0.0
    l2c_avg_miss_latency: float = 0.0

    # L1I (I-cache)
    l1i_total_access: int = 0
    l1i_total_hit: int = 0
    l1i_total_miss: int = 0
    l1i_hit_rate: float = 0.0
    l1i_mpki: float = 0.0

    # L1D
    l1d_total_access: int = 0
    l1d_total_miss: int = 0

    # LLC
    llc_total_access: int = 0
    llc_total_hit: int = 0
    llc_total_miss: int = 0

    # Front-end
    decode_starvation_cycles: int = 0
    branch_mispredict_rate: float = 0.0

    # EMISSARY-specific
    emissary_p1_evictions: int = -1
    emissary_p0_evictions: int = -1
    emissary_p1_ratio: float = -1.0

    # L2C capacity
    @property
    def l2c_capacity_kb(self) -> float:
        return (1024 * self.l2_ways * 64) / 1024


def _sum_cache(cache_data: dict):
    acc = 0; hit = 0; miss = 0
    for at in ("LOAD", "RFO", "WRITE", "PREFETCH", "TRANSLATION"):
        e = cache_data.get(at, {})
        h = sum(e.get("hit", [0]))
        m = sum(e.get("miss", [0]))
        acc += h + m; hit += h; miss += m
    return acc, hit, miss


def _parse_stats(rec: SimResult, data: list, plain_output: str = "") -> None:
    """Parse ChampSim JSON and plain-text output."""
    if not isinstance(data, list) or len(data) == 0:
        rec.status = "ERROR: invalid JSON"
        return

    phase = data[0]
    roi = phase.get("roi", {})

    # CPU
    cores = roi.get("cores", [])
    if cores:
        cpu0 = cores[0]
        rec.instructions = cpu0.get("instructions", 0)
        rec.cycles = cpu0.get("cycles", 0)
        rec.ipc = rec.instructions / rec.cycles if rec.cycles > 0 else 0.0
        rec.decode_starvation_cycles = cpu0.get("decode_starvation_cycles", 0)

    # L2C
    l2c = roi.get("cpu0_L2C", roi.get("L2C", {}))
    if l2c:
        acc, hit, miss = _sum_cache(l2c)
        rec.l2c_total_access = acc; rec.l2c_total_hit = hit; rec.l2c_total_miss = miss
        if acc > 0:
            rec.l2c_hit_rate = hit / acc
        if rec.instructions > 0:
            rec.l2c_mpki = miss / (rec.instructions / 1000.0)
        ml = l2c.get("miss latency", 0)
        rec.l2c_avg_miss_latency = float(ml) if ml else 0.0

    # L1I
    l1i = roi.get("cpu0_L1I", roi.get("L1I", {}))
    if l1i:
        acc, hit, miss = _sum_cache(l1i)
        rec.l1i_total_access = acc; rec.l1i_total_hit = hit; rec.l1i_total_miss = miss
        if acc > 0:
            rec.l1i_hit_rate = hit / acc
        if rec.instructions > 0:
            rec.l1i_mpki = miss / (rec.instructions / 1000.0)

    # L1D
    l1d = roi.get("cpu0_L1D", roi.get("L1D", {}))
    if l1d:
        acc, _, miss = _sum_cache(l1d)
        rec.l1d_total_access = acc; rec.l1d_total_miss = miss

    # LLC
    llc = roi.get("LLC", {})
    if llc:
        acc, hit, miss = _sum_cache(llc)
        rec.llc_total_access = acc; rec.llc_total_hit = hit; rec.llc_total_miss = miss

    # Branch mispredict rate
    if cores:
        mispredicts = cpu0.get("mispredict", {})
        total_mis = sum(int(v) for v in mispredicts.values()) if isinstance(mispredicts, dict) else 0
        if rec.instructions > 0:
            rec.branch_mispredict_rate = total_mis / (rec.instructions / 1000.0)

    # EMISSARY stats from plain-text output
    _parse_emissary_plain(rec, plain_output)

    rec.status = "OK"


def _parse_emissary_plain(rec: SimResult, output: str) -> None:
    """Parse EMISSARY/partitioned stats from the plain-text stdout."""
    if not output:
        return
    for line in output.splitlines():
        if "P=1 evictions:" in line and "EMISSARY" in line:
            try:
                parts = line.strip().split()
                rec.emissary_p1_evictions = int(parts[-1])
            except (ValueError, IndexError):
                pass
        if "P=0 evictions:" in line and "EMISSARY" in line:
            try:
                parts = line.strip().split()
                rec.emissary_p0_evictions = int(parts[-1])
            except (ValueError, IndexError):
                pass
        if "P=1 eviction ratio:" in line:
            try:
                rec.emissary_p1_ratio = float(line.strip().split(":")[-1].replace("%", ""))
            except (ValueError, IndexError):
                pass


# ---------------------------------------------------------------------------
# Config generation and compilation
# ---------------------------------------------------------------------------
def generate_l2_config(base_config_path: Path, l2_ways: int, replacement: str, output_path: Path):
    with open(base_config_path) as f:
        config = json.load(f)
    config["L2C"]["ways"] = l2_ways
    config["L2C"]["replacement"] = replacement
    with open(output_path, "w") as f:
        json.dump(config, f, indent=2)


def compile_champsim(config_path: Path, binary_name: str) -> Path:
    binary = CHAMPSIM_BIN_DIR / binary_name
    ret = subprocess.run(
        [str(PROJECT_ROOT / "config.sh"), str(config_path)],
        capture_output=True, text=True, cwd=str(PROJECT_ROOT), timeout=120
    )
    if ret.returncode != 0:
        raise RuntimeError(f"config.sh failed: {ret.stderr}")
    ret = subprocess.run(
        ["make", "-j", str(os.cpu_count() or 4)],
        capture_output=True, text=True, cwd=str(PROJECT_ROOT), timeout=300
    )
    if ret.returncode != 0:
        raise RuntimeError(f"make failed: {ret.stderr}")
    default_bin = CHAMPSIM_BIN_DIR / "champsim"
    if default_bin.is_file():
        shutil.copy2(default_bin, binary)
    return binary


# ---------------------------------------------------------------------------
# Simulation
# ---------------------------------------------------------------------------
def run_one_simulation(binary: Path, trace_path: str, trace_name: str,
                       output_dir: Path, config_info: dict,
                       warmup: int, sim_instr: int) -> SimResult:
    rec = SimResult(
        trace_name=trace_name,
        config_name=list(CONFIGS.keys())[list(CONFIGS.values()).index(config_info)],
        config_label=config_info["label"],
        l2_ways=config_info["l2_ways"],
    )
    json_file = output_dir / f"{Path(trace_name).stem}_{rec.config_name}.json"

    try:
        ret = subprocess.run(
            [str(binary),
             "--warmup-instructions", str(warmup),
             "--simulation-instructions", str(sim_instr),
             "--json", str(json_file),
             "--hide-heartbeat",
             trace_path],
            capture_output=True, text=True
        )
        if ret.returncode != 0:
            rec.status = f"ERROR: exit_code={ret.returncode}"
            return rec
        if not json_file.is_file():
            rec.status = "ERROR: JSON not created"
            return rec
        with open(json_file) as f:
            data = json.load(f)
        _parse_stats(rec, data, ret.stdout)
    except subprocess.TimeoutExpired:
        rec.status = "ERROR: TIMEOUT"
    except json.JSONDecodeError as e:
        rec.status = f"ERROR: JSON parse: {e}"
    except Exception as e:
        rec.status = f"ERROR: {e}"
    return rec


# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
RESULT_FIELDS = [
    "trace_name", "config_name", "config_label", "l2_ways", "l2c_capacity_kb", "status",
    "instructions", "cycles", "ipc",
    "l2c_total_access", "l2c_total_hit", "l2c_total_miss",
    "l2c_hit_rate", "l2c_mpki", "l2c_avg_miss_latency",
    "l1i_total_access", "l1i_total_hit", "l1i_total_miss",
    "l1i_hit_rate", "l1i_mpki",
    "l1d_total_access", "l1d_total_miss",
    "llc_total_access", "llc_total_hit", "llc_total_miss",
    "decode_starvation_cycles", "branch_mispredict_rate",
    "emissary_p1_evictions", "emissary_p0_evictions", "emissary_p1_ratio",
]


def write_summary_csv(results: list, output_dir: Path) -> Path:
    csv_path = output_dir / "emissary_experiment_summary.csv"
    with open(csv_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=RESULT_FIELDS, extrasaction="ignore")
        writer.writeheader()
        for rec in results:
            row = {}
            for fn in RESULT_FIELDS:
                val = getattr(rec, fn, "")
                row[fn] = f"{val:.6f}" if isinstance(val, float) else val
            writer.writerow(row)
    return csv_path


def write_report(results: list, output_dir: Path) -> Path:
    """Generate a comparative analysis report in Markdown."""
    report_path = output_dir / "emissary_experiment_report.md"

    # Group by trace
    by_trace = defaultdict(dict)
    for rec in results:
        if rec.status == "OK":
            by_trace[rec.trace_name][rec.config_name] = rec

    lines = []
    lines.append("# EMISSARY Validation Experiment Report")
    lines.append("")
    lines.append("## Configurations")
    lines.append("")
    lines.append("| Name | L2 Ways | Replacement | Label |")
    lines.append("|------|---------|-------------|-------|")
    for cname, cinfo in CONFIGS.items():
        lines.append(f"| {cname} | {cinfo['l2_ways']} | {cinfo['replacement']} | {cinfo['label']} |")
    lines.append("")

    # ── Per-trace comparison table ──
    lines.append("## Per-Trace Results")
    lines.append("")

    for tname in sorted(by_trace):
        recs = by_trace[tname]
        if len(recs) < 4:
            continue

        lines.append(f"### {tname}")
        lines.append("")
        lines.append("| Metric | Baseline LRU 8W | Phase1 EMISSARY 8W | Phase2 Part 4+4W | Extra LRU 4W |")
        lines.append("|--------|-----------------|--------------------|--------------------|--------------|")

        # IPC
        baseline = recs.get("baseline")
        if not baseline:
            continue
        def _row(name, fmt, key, pct=False):
            bl = getattr(baseline, key, 0)
            em = getattr(recs.get("emissary", baseline), key, 0)
            pa = getattr(recs.get("partitioned", baseline), key, 0)
            l4 = getattr(recs.get("lru4w", baseline), key, 0)
            if pct and bl != 0:
                em_str = f"{em*100:{fmt}} (+{em/bl-1:+7.1%})" if bl > 0 else f"{em*100:{fmt}}"
                pa_str = f"{pa*100:{fmt}} (+{pa/bl-1:+7.1%})" if bl > 0 else f"{pa*100:{fmt}}"
                l4_str = f"{l4*100:{fmt}} (+{l4/bl-1:+7.1%})" if bl > 0 else f"{l4*100:{fmt}}"
                return f"| {name} | {bl*100:{fmt}} | {em_str} | {pa_str} | {l4_str} |"
            else:
                em_str = f"{em:{fmt}} (+{em/bl-1:+7.1%})" if bl != 0 else f"{em:{fmt}}"
                pa_str = f"{pa:{fmt}} (+{pa/bl-1:+7.1%})" if bl != 0 else f"{pa:{fmt}}"
                l4_str = f"{l4:{fmt}} (+{l4/bl-1:+7.1%})" if bl != 0 else f"{l4:{fmt}}"
                return f"| {name} | {bl:{fmt}} | {em_str} | {pa_str} | {l4_str} |"

        lines.append(_row("**IPC**", ".4f", "ipc"))
        lines.append(_row("L2C Hit Rate", ".2f", "l2c_hit_rate", pct=True))
        lines.append(_row("L2C MPKI", ".2f", "l2c_mpki"))
        lines.append(_row("L1I Hit Rate", ".2f", "l1i_hit_rate", pct=True))
        lines.append(_row("L1I MPKI", ".2f", "l1i_mpki"))
        lines.append(_row("decode_starvation_cycles", ".0f", "decode_starvation_cycles"))
        lines.append(_row("Branch mispredict MPKI", ".2f", "branch_mispredict_rate"))
        lines.append("")

        # EMISSARY stats (only for emissary and partitioned)
        for cname in ["emissary", "partitioned"]:
            er = recs.get(cname)
            if er and er.emissary_p1_evictions >= 0:
                lines.append(f"**{CONFIGS[cname]['label']} EMISSARY stats:**")
                lines.append(f"- P=1 evictions: {er.emissary_p1_evictions}")
                lines.append(f"- P=0 evictions: {er.emissary_p0_evictions}")
                if er.emissary_p1_ratio >= 0:
                    lines.append(f"- P=1 eviction ratio: {er.emissary_p1_ratio:.1f}%")
                lines.append("")

    # ── Flat zone check ──
    lines.append("## Flat Zone Analysis")
    lines.append("")
    lines.append("| Trace | Baseline IPC | Extra LRU 4W IPC | IPC Drop% | Flat? |")
    lines.append("|-------|-------------|-------------------|-----------|-------|")
    for tname in sorted(by_trace):
        recs = by_trace[tname]
        bl = recs.get("baseline")
        l4 = recs.get("lru4w")
        if bl and l4 and bl.ipc > 0:
            drop = (bl.ipc - l4.ipc) / bl.ipc * 100
            is_flat = "⚠️ YES" if drop < 2.0 else "no"
            lines.append(f"| {tname} | {bl.ipc:.4f} | {l4.ipc:.4f} | {drop:+.1f}% | {is_flat} |")
    lines.append("")

    # ── EMISSARY effectiveness summary ──
    lines.append("## EMISSARY Effectiveness Summary")
    lines.append("")
    lines.append("| Trace | P1 vs Baseline IPC% | P2 vs Baseline IPC% | P2 vs LRU4W IPC% | Verdict |")
    lines.append("|-------|---------------------|---------------------|-------------------|---------|")
    for tname in sorted(by_trace):
        recs = by_trace[tname]
        bl = recs.get("baseline")
        em = recs.get("emissary")
        pa = recs.get("partitioned")
        l4 = recs.get("lru4w")
        if not all([bl, em, pa, l4]):
            continue
        p1_gain = (em.ipc - bl.ipc) / bl.ipc * 100 if bl.ipc > 0 else 0
        p2_gain = (pa.ipc - bl.ipc) / bl.ipc * 100 if bl.ipc > 0 else 0
        p2_vs_l4 = (pa.ipc - l4.ipc) / l4.ipc * 100 if l4.ipc > 0 else 0

        if p2_gain > 1.0:
            verdict = "✅ EMISSARY partitioning helps"
        elif p1_gain > 0.5:
            verdict = "✅ EMISSARY helps (unified)"
        elif p2_vs_l4 > 0.5:
            verdict = "⚠️ Marginal: partitioned > LRU4W"
        else:
            verdict = "— no significant gain"

        lines.append(f"| {tname} | {p1_gain:+.2f}% | {p2_gain:+.2f}% | {p2_vs_l4:+.2f}% | {verdict} |")
    lines.append("")

    # ── Interpretation guide ──
    lines.append("## Interpretation Guide")
    lines.append("")
    lines.append("- **Baseline vs Extra (LRU 8W vs LRU 4W)**: IPC drop < 2% → flat zone confirmed.")
    lines.append("  The trace's working set fits in 4-way; extra 4-way are underutilized.")
    lines.append("- **Phase 1 vs Baseline (EMISSARY 8W vs LRU 8W)**: IPC gain > 0% → EMISSARY replacement")
    lines.append("  policy is effective at protecting I-cache lines.")
    lines.append("- **Phase 2 vs Baseline (Partitioned vs LRU 8W)**: IPC gain > 0% → heterogeneous")
    lines.append("  partitioning works. The excess SRAM is better used for I-cache protection")
    lines.append("  than for additional data cache capacity.")
    lines.append("- **Phase 2 vs Extra (Partitioned vs LRU 4W)**: Same capacity for data (4-way),")
    lines.append("  but Phase 2 uses the other 4-way for EMISSARY. IPC gain → the EMISSARY")
    lines.append("  partition is providing measurable front-end benefits beyond just having")
    lines.append("  a smaller cache.")
    lines.append("- **decode_starvation_cycles**: Primary metric for EMISSARY. Should decrease")
    lines.append("  in Phase 1/2 vs Baseline if EMISSARY is working.")
    lines.append("- **L1I MPKI**: Secondary metric. Should decrease if I-cache lines are better")
    lines.append("  protected in L2.")

    with open(report_path, "w") as f:
        f.write("\n".join(lines))
    return report_path


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description="EMISSARY Validation Experiment")
    parser.add_argument(
        "--traces", type=str,
        default="gcc_13B.trace.xz,perlbench_135B.trace.xz,xalancbmk_768B.trace.xz",
        help="Comma-separated trace names, or path to validation CSV"
    )
    parser.add_argument("--output-dir", type=str, default="artifacts/runs/emissary_experiment2")
    parser.add_argument("--warmup", type=int, default=WARMUP_INSTRUCTIONS)
    parser.add_argument("--sim-instr", type=int, default=SIM_INSTRUCTIONS)
    parser.add_argument("-j", "--jobs", type=int, default=1)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--skip-compile", action="store_true")
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    # ── Resolve traces ──
    if args.traces.endswith(".csv"):
        traces = []
        with open(args.traces, newline="") as f:
            for row in csv.DictReader(f):
                if row.get("status") == "USABLE":
                    traces.append({"name": row["name"], "path": row["path"]})
    else:
        trace_names = [t.strip() for t in args.traces.split(",")]
        traces = []
        for tn in trace_names:
            found = None
            # If name already has extension, try as-is first
            search_exts = ["", ".xz"] if not tn.endswith(".xz") else [""]
            for subdir in ["", "new", "new2", "SPEC"]:
                for ext in search_exts:
                    candidate = PROJECT_ROOT / "traces" / subdir / (tn + ext)
                    if candidate.is_file():
                        found = str(candidate)
                        break
                if found:
                    break
            if found:
                traces.append({"name": tn, "path": found})
            else:
                print(f"WARNING: trace not found: {tn}")

    if not traces:
        print("No traces found.")
        sys.exit(1)

    print("=" * 70)
    print("EMISSARY Validation Experiment")
    print("=" * 70)
    print(f"Traces:        {len(traces)}")
    print(f"Configs:       {len(CONFIGS)}")
    print(f"Total runs:    {len(traces) * len(CONFIGS)}")
    print(f"Output:        {output_dir}")
    print()

    # ── Generate configs and compile ──
    config_dir = output_dir / "configs"
    config_dir.mkdir(parents=True, exist_ok=True)
    binaries = {}

    for cname, cinfo in CONFIGS.items():
        config_path = config_dir / f"champsim_config_{cname}.json"
        binary = cinfo["binary"]

        if not args.skip_compile:
            print(f"[Config] {cinfo['label']} → {config_path}")
            generate_l2_config(DEFAULT_CONFIG, cinfo["l2_ways"], cinfo["replacement"], config_path)
            print(f"[Compile] Building {binary} ...")
            compile_champsim(config_path, binary)
            print(f"[Compile] Done: {CHAMPSIM_BIN_DIR / binary}")
        else:
            if not (CHAMPSIM_BIN_DIR / binary).is_file():
                print(f"ERROR: --skip-compile but binary not found: {CHAMPSIM_BIN_DIR / binary}")
                sys.exit(1)

        binaries[cname] = CHAMPSIM_BIN_DIR / binary

    if args.dry_run:
        print("\nDRY RUN — would execute:")
        for cname, cinfo in CONFIGS.items():
            for t in traces:
                json_out = output_dir / f"{Path(t['name']).stem}_{cname}.json"
                print(f"  {binaries[cname]} --json {json_out} {t['path']}")
        return

    # ── Run simulations ──
    tasks = []
    for cname, cinfo in CONFIGS.items():
        for t in traces:
            tasks.append((cname, cinfo, binaries[cname], t))

    all_results = []
    completed = 0
    total = len(tasks)
    print(f"\n[Run] {total} simulations...")

    if args.jobs > 1:
        with ProcessPoolExecutor(max_workers=args.jobs) as executor:
            futures = {}
            for cname, cinfo, binary, t in tasks:
                fut = executor.submit(
                    run_one_simulation, binary, t["path"], t["name"],
                    output_dir, cinfo, args.warmup, args.sim_instr
                )
                futures[fut] = (cname, t)
            for future in as_completed(futures):
                cname, t = futures[future]
                try:
                    rec = future.result()
                except Exception as e:
                    rec = SimResult(trace_name=t["name"], config_name=cname,
                                    config_label=CONFIGS[cname]["label"],
                                    l2_ways=CONFIGS[cname]["l2_ways"])
                    rec.status = f"ERROR: {e}"
                all_results.append(rec)
                completed += 1
                status = f"IPC={rec.ipc:.4f}" if rec.status == "OK" else rec.status
                print(f"  [{completed}/{total}] {rec.config_label} {rec.trace_name} → {status}")
    else:
        for cname, cinfo, binary, t in tasks:
            rec = run_one_simulation(binary, t["path"], t["name"], output_dir, cinfo,
                                     args.warmup, args.sim_instr)
            all_results.append(rec)
            completed += 1
            status = f"IPC={rec.ipc:.4f}" if rec.status == "OK" else rec.status
            print(f"  [{completed}/{total}] {rec.config_label} {rec.trace_name} → {status}")

    # ── Output ──
    csv_path = write_summary_csv(all_results, output_dir)
    print(f"\nSummary CSV: {csv_path}")
    report_path = write_report(all_results, output_dir)
    print(f"Report:      {report_path}")

    # ── Quick console summary ──
    by_trace = defaultdict(dict)
    for rec in all_results:
        if rec.status == "OK":
            by_trace[rec.trace_name][rec.config_name] = rec

    print("\n" + "=" * 70)
    print("Quick Summary: IPC Comparison")
    print("=" * 70)
    print(f"{'Trace':<38} {'Baseline':>8} {'Emissary':>8} {'Part4+4':>8} {'LRU4W':>8} {'Flat?':>6}")
    print("-" * 80)
    for tname in sorted(by_trace):
        recs = by_trace[tname]
        bl = recs.get("baseline")
        if not bl:
            continue
        em = recs.get("emissary", bl)
        pa = recs.get("partitioned", bl)
        l4 = recs.get("lru4w", bl)
        drop = (bl.ipc - l4.ipc) / bl.ipc * 100 if bl.ipc > 0 else 0
        flat = "⚠️ YES" if drop < 2.0 else "no"
        print(f"{tname:<38} {bl.ipc:8.4f} {em.ipc:8.4f} {pa.ipc:8.4f} {l4.ipc:8.4f} {flat:>6}")

    flat_count = sum(1 for tname in by_trace
                     if (bl := by_trace[tname].get("baseline"))
                     and (l4 := by_trace[tname].get("lru4w"))
                     and bl.ipc > 0
                     and (bl.ipc - l4.ipc) / bl.ipc * 100 < 2.0)
    print(f"\n{flat_count}/{len(by_trace)} traces show flat zone (8W→4W IPC drop < 2%).")


if __name__ == "__main__":
    main()
