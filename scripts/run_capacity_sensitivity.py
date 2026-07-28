#!/usr/bin/env python3
"""
L2C Capacity Sensitivity Experiment
====================================
Measures how L2 cache capacity (way count) affects performance for each
trace, to identify the "flat zone" where additional SRAM yields diminishing
returns — i.e., candidate space that could be repurposed.

Method:
  For each trace, run ChampSim with L2C ways in {1, 2, 4, 8, 16}
  → Plot IPC/L2C-hit-rate vs L2C capacity
  → The region where the curve flattens is the "excess capacity" zone.

Output:
  l2c_sensitivity_summary.csv   — one row per (trace × L2W), all metrics
  l2c_sensitivity_flatzone.md   — report identifying flat-zone traces
  l2c_sensitivity_curve.png     — visualization (optional, requires matplotlib)

Usage:
  # Full sweep on selected traces:
  python scripts/run_capacity_sensitivity.py                     \\
      --traces barnes_1,facesim_1,fft_m24,lu_ncb_1,dlrm_4g      \\
      --l2-ways 1,2,4,8,16                                      \\
      --output-dir artifacts/runs/capacity_sweep                 \\
      -j 4

  # Quick check (just 4-way and 8-way):
  python scripts/run_capacity_sensitivity.py                     \\
      --traces barnes_1,facesim_1                                \\
      --l2-ways 4,8                                              \\
      -j 2
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
TRACES_DIR = PROJECT_ROOT / "traces"

# Simulation parameters
WARMUP_INSTRUCTIONS  = 50_000_000
SIM_INSTRUCTIONS     = 500_000_000

# ---------------------------------------------------------------------------
# Data structures
# ---------------------------------------------------------------------------
@dataclass
class SimResult:
    """Parsed simulation result for one (trace × L2W) combination."""
    trace_name: str
    l2_ways: int
    l2_sets: int = 1024
    status: str = "PENDING"

    instructions: int = 0
    cycles: int = 0
    ipc: float = 0.0

    l2c_total_access: int = 0
    l2c_total_hit: int = 0
    l2c_total_miss: int = 0
    l2c_hit_rate: float = 0.0
    l2c_mpki: float = 0.0
    l2c_avg_miss_latency: float = 0.0

    l1d_total_access: int = 0
    l1d_total_miss: int = 0
    l1d_to_l2c_ratio: float = 0.0

    llc_total_access: int = 0
    llc_total_hit: int = 0
    llc_total_miss: int = 0

    l2c_pf_requested: int = 0
    l2c_pf_issued: int = 0
    l2c_pf_useful: int = 0
    l2c_pf_useless: int = 0

    @property
    def l2c_capacity_kb(self) -> float:
        """Effective L2C capacity in KB."""
        return (self.l2_sets * self.l2_ways * 64) / 1024


# ---------------------------------------------------------------------------
# Config generation
# ---------------------------------------------------------------------------
def generate_l2_config(base_config_path: Path, l2_ways: int, output_path: Path):
    """Copy base config and override L2C ways."""
    with open(base_config_path) as f:
        config = json.load(f)
    config["L2C"]["ways"] = l2_ways
    with open(output_path, "w") as f:
        json.dump(config, f, indent=2)
    return output_path


def compile_champsim(config_path: Path, binary_name: str) -> Path:
    """Run config.sh + make, return path to compiled binary."""
    binary = CHAMPSIM_BIN_DIR / binary_name

    # config.sh
    ret = subprocess.run(
        [str(PROJECT_ROOT / "config.sh"), str(config_path)],
        capture_output=True, text=True, cwd=str(PROJECT_ROOT), timeout=120
    )
    if ret.returncode != 0:
        raise RuntimeError(f"config.sh failed for {config_path}:\n{ret.stderr}")

    # make
    ret = subprocess.run(
        ["make", "-j", str(os.cpu_count() or 4)],
        capture_output=True, text=True, cwd=str(PROJECT_ROOT), timeout=300
    )
    if ret.returncode != 0:
        raise RuntimeError(f"make failed for {config_path}:\n{ret.stderr}")

    # Rename the binary to keep it
    default_bin = CHAMPSIM_BIN_DIR / "champsim"
    if default_bin.is_file():
        shutil.copy2(default_bin, binary)

    return binary


# ---------------------------------------------------------------------------
# Simulation
# ---------------------------------------------------------------------------
def run_one_simulation(binary: Path, trace_path: str, trace_name: str,
                       output_dir: Path, warmup: int, sim_instr: int) -> SimResult:
    """Run one ChampSim simulation and parse results."""
    rec = SimResult(trace_name=trace_name, l2_ways=0)
    json_file = output_dir / f"{Path(trace_name).stem}.json"

    try:
        ret = subprocess.run(
            [
                str(binary),
                "--warmup-instructions", str(warmup),
                "--simulation-instructions", str(sim_instr),
                "--json", str(json_file),
                "--hide-heartbeat",
                trace_path,
            ],
            capture_output=True, text=True, timeout=7200
        )

        if ret.returncode != 0:
            rec.status = f"ERROR: exit_code={ret.returncode}"
            return rec

        if not json_file.is_file():
            rec.status = f"ERROR: JSON not created"
            return rec

        with open(json_file) as f:
            data = json.load(f)
        _parse_stats(rec, data)
        rec.status = "OK"

    except subprocess.TimeoutExpired:
        rec.status = "ERROR: TIMEOUT"
    except json.JSONDecodeError as e:
        rec.status = f"ERROR: JSON parse: {e}"
    except Exception as e:
        rec.status = f"ERROR: {e}"

    return rec


def _parse_stats(rec: SimResult, data: list) -> None:
    """Parse ChampSim JSON output. Keys are cpu0_L2C, cpu0_L1D, etc."""
    if not isinstance(data, list) or len(data) == 0:
        rec.status = "ERROR: unexpected JSON structure"
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

    # L2C (key: cpu0_L2C in new ChampSim)
    l2c = roi.get("cpu0_L2C", roi.get("L2C", {}))
    if l2c:
        _parse_cache_stats(l2c, rec, "l2c")
        rec.l2c_pf_requested = l2c.get("prefetch requested", 0)
        rec.l2c_pf_issued = l2c.get("prefetch issued", 0)
        rec.l2c_pf_useful = l2c.get("useful prefetch", 0)
        rec.l2c_pf_useless = l2c.get("useless prefetch", 0)
        miss_lat = l2c.get("miss latency", 0)
        rec.l2c_avg_miss_latency = float(miss_lat) if miss_lat else 0.0

    # L1D (key: cpu0_L1D)
    l1d = roi.get("cpu0_L1D", roi.get("L1D", {}))
    if l1d:
        l1d_access = 0
        l1d_miss = 0
        for atype in ("LOAD", "RFO", "WRITE", "PREFETCH", "TRANSLATION"):
            entry = l1d.get(atype, {})
            hits = sum(entry.get("hit", [0]))
            misses = sum(entry.get("miss", [0]))
            l1d_access += hits + misses
            l1d_miss += misses
        rec.l1d_total_access = l1d_access
        rec.l1d_total_miss = l1d_miss
        if l1d_miss > 0 and rec.l2c_total_access > 0:
            rec.l1d_to_l2c_ratio = rec.l2c_total_access / l1d_miss

    # LLC
    llc = roi.get("LLC", {})
    if llc:
        llc_access = 0; llc_hit = 0; llc_miss = 0
        for atype in ("LOAD", "RFO", "WRITE", "PREFETCH", "TRANSLATION"):
            entry = llc.get(atype, {})
            hits = sum(entry.get("hit", [0]))
            misses = sum(entry.get("miss", [0]))
            llc_access += hits + misses
            llc_hit += hits
            llc_miss += misses
        rec.llc_total_access = llc_access
        rec.llc_total_hit = llc_hit
        rec.llc_total_miss = llc_miss

    # Derived
    if rec.l2c_total_access > 0:
        rec.l2c_hit_rate = rec.l2c_total_hit / rec.l2c_total_access
    if rec.instructions > 0:
        rec.l2c_mpki = rec.l2c_total_miss / (rec.instructions / 1000.0)


def _parse_cache_stats(cache_data: dict, rec: SimResult, prefix: str) -> None:
    """Sum hits/misses across access types."""
    total_access = 0; total_hit = 0; total_miss = 0
    for atype in ("LOAD", "RFO", "WRITE", "PREFETCH", "TRANSLATION"):
        entry = cache_data.get(atype, {})
        hits = sum(entry.get("hit", [0]))
        misses = sum(entry.get("miss", [0]))
        total_access += hits + misses
        total_hit += hits
        total_miss += misses

    setattr(rec, f"{prefix}_total_access", total_access)
    setattr(rec, f"{prefix}_total_hit", total_hit)
    setattr(rec, f"{prefix}_total_miss", total_miss)


# ---------------------------------------------------------------------------
# Flat-zone analysis
# ---------------------------------------------------------------------------
@dataclass
class FlatZoneReport:
    """Per-trace capacity sensitivity analysis."""
    trace_name: str
    results: list  # list of SimResult, one per L2W
    best_ipc: float = 0.0
    knee_ways: int = -1          # smallest way count achieving >=95% of best IPC
    best_hit_rate: float = 0.0
    knee_hit_ways: int = -1      # smallest way count achieving >=95% of best hit_rate
    is_flat: bool = False        # True if 4→8 way gives < 2% IPC gain


def analyze_trace(results: list[SimResult]) -> FlatZoneReport:
    """Analyze capacity sensitivity for one trace."""
    ok = [r for r in results if r.status == "OK" and r.l2c_total_access > 0]
    if len(ok) < 2:
        return FlatZoneReport(
            trace_name=results[0].trace_name if results else "unknown",
            results=results
        )

    ok.sort(key=lambda r: r.l2_ways)

    report = FlatZoneReport(trace_name=ok[0].trace_name, results=ok)
    report.best_ipc = max(r.ipc for r in ok)
    report.best_hit_rate = max(r.l2c_hit_rate for r in ok)

    # Knee detection by IPC: first way count reaching >=95% of best IPC
    for r in ok:
        if r.ipc >= 0.95 * report.best_ipc:
            report.knee_ways = r.l2_ways
            break

    # Knee detection by hit_rate
    for r in ok:
        if r.l2c_hit_rate >= 0.95 * report.best_hit_rate:
            report.knee_hit_ways = r.l2_ways
            break

    # Flat zone check: marginal IPC gain from 4→8 way (if data exists)
    ipc_map = {r.l2_ways: r.ipc for r in ok}
    if 4 in ipc_map and 8 in ipc_map:
        gain_4_to_8 = (ipc_map[8] - ipc_map[4]) / ipc_map[4] * 100 if ipc_map[4] > 0 else 0
        report.is_flat = gain_4_to_8 < 2.0  # <2% IPC gain from doubling capacity

    return report


# ---------------------------------------------------------------------------
# CSV output
# ---------------------------------------------------------------------------
RESULT_FIELDNAMES = [
    "trace_name", "l2_ways", "l2_capacity_kb", "status",
    "instructions", "cycles", "ipc",
    "l2c_total_access", "l2c_total_hit", "l2c_total_miss",
    "l2c_hit_rate", "l2c_mpki", "l2c_avg_miss_latency",
    "l1d_total_access", "l1d_total_miss", "l1d_to_l2c_ratio",
    "llc_total_access", "llc_total_hit", "llc_total_miss",
    "l2c_pf_requested", "l2c_pf_issued", "l2c_pf_useful", "l2c_pf_useless",
]


def write_summary_csv(results: list[SimResult], output_dir: Path):
    """Write all results to CSV."""
    csv_path = output_dir / "l2c_sensitivity_summary.csv"
    with open(csv_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=RESULT_FIELDNAMES, extrasaction="ignore")
        writer.writeheader()
        for rec in results:
            row = {fn: getattr(rec, fn, "") for fn in RESULT_FIELDNAMES}
            writer.writerow(row)
    return csv_path


def write_flatzone_report(reports: list[FlatZoneReport], output_dir: Path):
    """Write the flat-zone analysis report in Markdown."""
    report_path = output_dir / "l2c_sensitivity_flatzone.md"

    lines = []
    lines.append("# L2C Capacity Sensitivity — Flat-Zone Analysis")
    lines.append("")
    lines.append("## Method")
    lines.append("")
    lines.append("Each trace was run with L2C ways ∈ {1, 2, 4, 8, 16}.")
    lines.append("A trace is considered to have a **flat zone** (excess L2C capacity)")
    lines.append("if doubling L2C from 4-way to 8-way yields <2% IPC improvement.")
    lines.append("The **knee** is the smallest L2C way count reaching ≥95% of the best IPC.")
    lines.append("")

    # Per-trace details
    lines.append("## Per-Trace Analysis")
    lines.append("")
    lines.append("| Trace | Best IPC | IPC Knee | 4→8W Gain% | Best HR% | HR Knee | Flat? |")
    lines.append("|-------|----------|----------|------------|----------|---------|-------|")

    for rp in reports:
        ok = [r for r in rp.results if r.status == "OK"]
        if len(ok) < 2:
            lines.append(f"| {rp.trace_name} | — | — | — | — | — | insufficient data |")
            continue

        gain_str = ""
        ipc_map = {r.l2_ways: r.ipc for r in ok}
        if 4 in ipc_map and 8 in ipc_map:
            gain = (ipc_map[8] - ipc_map[4]) / ipc_map[4] * 100 if ipc_map[4] > 0 else 0
            gain_str = f"{gain:+.1f}%"

        flat_str = "⚠️ YES" if rp.is_flat else "no"

        lines.append(
            f"| {rp.trace_name} | {rp.best_ipc:.4f} | "
            f"W{rp.knee_ways} | {gain_str} | "
            f"{rp.best_hit_rate*100:.1f}% | W{rp.knee_hit_ways} | "
            f"{flat_str} |"
        )

    lines.append("")

    # Detailed per-trace breakdown
    lines.append("## Detailed Per-Trace Capacity Sweep")
    lines.append("")

    for rp in reports:
        ok = sorted([r for r in rp.results if r.status == "OK"], key=lambda r: r.l2_ways)
        if not ok:
            continue

        lines.append(f"### {rp.trace_name}")
        lines.append("")
        lines.append(f"| L2 Ways | Capacity | IPC | Hit Rate | MPKI | L1D→L2C Ratio | LLC Access |")
        lines.append(f"|---------|----------|-----|----------|------|---------------|------------|")

        for r in ok:
            lines.append(
                f"| {r.l2_ways} | {r.l2c_capacity_kb:.0f} KB | {r.ipc:.4f} | "
                f"{r.l2c_hit_rate*100:.1f}% | {r.l2c_mpki:.2f} | "
                f"{r.l1d_to_l2c_ratio:.1f} | {r.llc_total_access:,} |"
            )

        # Flat zone assessment
        if rp.is_flat:
            lines.append("")
            max_w = max(r.l2_ways for r in ok)
            excess_w = max_w - rp.knee_ways
            lines.append(f"**⚠️ This trace shows a flat zone.** "
                         f"Doubling L2C from 4-way to 8-way gives minimal IPC gain. "
                         f"The excess capacity ({excess_w} ways × {rp.results[0].l2_sets} sets × 64B "
                         f"≈ {excess_w * rp.results[0].l2_sets * 64 / 1024:.0f} KB) "
                         f"could potentially be repurposed for EMISSARY/IGNITE.")
        lines.append("")

    # Global summary
    flat_traces = [rp for rp in reports if rp.is_flat]
    lines.append("## Global Summary")
    lines.append("")
    lines.append(f"- Total traces analyzed: {len(reports)}")
    lines.append(f"- Traces with flat zone: **{len(flat_traces)}**")
    lines.append("")

    if flat_traces:
        lines.append("### Candidates for L2C Space Repurposing")
        lines.append("")
        lines.append("These traces show a flat capacity-performance curve, meaning their L2C")
        lines.append("has excess SRAM that could be reused for front-end acceleration:")
        lines.append("")
        for rp in flat_traces:
            ok = [r for r in rp.results if r.status == "OK"]
            max_w = max(r.l2_ways for r in ok)
            excess_kb = (max_w - rp.knee_ways) * rp.results[0].l2_sets * 64 / 1024
            lines.append(f"- **{rp.trace_name}**: knee at {rp.knee_ways}-way, "
                         f"~{excess_kb:.0f} KB potentially reusable")
        lines.append("")

    lines.append("## Interpretation")
    lines.append("")
    lines.append("- **IPC Knee** = smallest L2C way count achieving ≥95% of the best IPC "
                 "(across all tested sizes)")
    lines.append("- **Flat?** = 4→8 way doubling gives <2% IPC gain → capacity beyond knee "
                 "is underutilized")
    lines.append("- **L1D→L2C Ratio** = how many L2C accesses each L1D miss generates on average")
    lines.append("- A flat zone means the trace's working set fits comfortably in a smaller L2;")
    lines.append("  the additional SRAM provides negligible benefit and could be repurposed.")

    with open(report_path, "w") as f:
        f.write("\n".join(lines))
    return report_path


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(
        description="L2C Capacity Sensitivity Experiment"
    )
    parser.add_argument(
        "--traces", type=str,
        default="facesim_1.champsimtrace.xz,barnes_1.champsimtrace.xz,"
                "fft_m24.champsimtrace.xz,radix_1.champsimtrace.xz,"
                "ocean_cp_1.champsimtrace.xz,streamcluster_1.champsimtrace.xz",
        help="Comma-separated trace names, or path to a validation CSV "
             "(default: 6 traces spanning 2.8%–97.6% L2C hit rate)"
    )
    parser.add_argument(
        "--l2-ways", type=str, default="1,2,4,8,16",
        help="Comma-separated L2C way counts to test (default: 1,2,4,8,16)"
    )
    parser.add_argument(
        "--output-dir", type=str, default="artifacts/runs/capacity_sweep",
        help="Output directory for JSON results and CSV"
    )
    parser.add_argument(
        "--warmup", type=int, default=WARMUP_INSTRUCTIONS,
        help="Warmup instructions per trace"
    )
    parser.add_argument(
        "--sim-instr", type=int, default=SIM_INSTRUCTIONS,
        help="Simulation instructions per trace"
    )
    parser.add_argument(
        "-j", "--jobs", type=int, default=1,
        help="Parallel simulation jobs (default: 1)"
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Print what would be executed without running"
    )
    parser.add_argument(
        "--skip-compile", action="store_true",
        help="Skip compilation (use existing binaries in bin/)"
    )
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    # --- Resolve traces ---
    if args.traces.endswith(".csv"):
        # Read from validation CSV
        traces = []
        with open(args.traces, newline="") as f:
            reader = csv.DictReader(f)
            for row in reader:
                if row.get("status") == "USABLE":
                    traces.append({"name": row["name"], "path": row["path"]})
    else:
        # Comma-separated trace names
        trace_names = [t.strip() for t in args.traces.split(",")]
        traces = []
        for tn in trace_names:
            # Search in traces/, traces/new/, traces/new2/
            found = None
            for subdir in ["", "new", "new2"]:
                candidate = PROJECT_ROOT / "traces" / subdir / tn
                if candidate.is_file():
                    found = str(candidate)
                    break
                # Try with .xz extension
                for ext in [".xz", ""]:
                    candidate_ext = PROJECT_ROOT / "traces" / subdir / (tn + ext)
                    if candidate_ext.is_file():
                        found = str(candidate_ext)
                        break
                if found:
                    break
            if found:
                traces.append({"name": tn, "path": found})
            else:
                print(f"WARNING: trace file not found: {tn}")

    if not traces:
        print("No traces found. Aborting.")
        sys.exit(1)

    l2_ways_list = [int(w) for w in args.l2_ways.split(",")]

    print("=" * 70)
    print("L2C Capacity Sensitivity Experiment")
    print("=" * 70)
    print(f"Traces:           {len(traces)}")
    print(f"L2C way counts:   {l2_ways_list}")
    print(f"Total configs:    {len(l2_ways_list)}")
    print(f"Total simulations:{len(traces) * len(l2_ways_list)}")
    print(f"Output directory: {output_dir}")
    print(f"Warmup:           {args.warmup:,} instr")
    print(f"Simulation:       {args.sim_instr:,} instr")
    print()

    # --- Generate configs and compile ---
    binaries = {}  # l2_ways → binary path
    config_dir = output_dir / "configs"
    config_dir.mkdir(parents=True, exist_ok=True)

    for w in l2_ways_list:
        config_path = config_dir / f"champsim_config_L2W{w}.json"
        binary_name = f"champsim_L2W{w}"

        if not args.skip_compile:
            print(f"[Config] Generating L2C ways={w} → {config_path}")
            generate_l2_config(DEFAULT_CONFIG, w, config_path)
            print(f"[Compile] Building {binary_name} ...")
            compile_champsim(config_path, binary_name)
            print(f"[Compile] Done: {CHAMPSIM_BIN_DIR / binary_name}")
        else:
            if not (CHAMPSIM_BIN_DIR / binary_name).is_file():
                print(f"ERROR: --skip-compile set but binary not found: "
                      f"{CHAMPSIM_BIN_DIR / binary_name}")
                sys.exit(1)

        binaries[w] = CHAMPSIM_BIN_DIR / binary_name

    if args.dry_run:
        print("\nDRY RUN — would execute:")
        for w in l2_ways_list:
            for t in traces:
                json_out = output_dir / f"{Path(t['name']).stem}_L2W{w}.json"
                print(f"  {binaries[w]} --json {json_out} {t['path']}")
        print("\nDry run complete. No simulations executed.")
        return

    # --- Run simulations ---
    all_results: list[SimResult] = []

    # Build task list: (binary, trace_info, l2_ways)
    tasks = []
    for w in l2_ways_list:
        trace_output_dir = output_dir / f"L2W{w}"
        trace_output_dir.mkdir(parents=True, exist_ok=True)
        for t in traces:
            tasks.append((binaries[w], t, w, trace_output_dir))

    print(f"\n[Run] Executing {len(tasks)} simulations...")
    completed = 0

    if args.jobs > 1:
        with ProcessPoolExecutor(max_workers=args.jobs) as executor:
            futures = {
                executor.submit(
                    run_one_simulation, binary, t["path"], t["name"],
                    output_dir, args.warmup, args.sim_instr
                ): (t, w) for binary, t, w, output_dir in tasks
            }
            for future in as_completed(futures):
                t, w = futures[future]
                try:
                    rec = future.result()
                except Exception as e:
                    rec = SimResult(trace_name=t["name"], l2_ways=w)
                    rec.status = f"ERROR: {e}"
                rec.l2_ways = w
                all_results.append(rec)
                completed += 1
                ipc_str = f"IPC={rec.ipc:.4f}" if rec.status == "OK" else ""
                hr_str = f"HR={rec.l2c_hit_rate*100:.1f}%" if rec.status == "OK" else ""
                print(f"  [{completed}/{len(tasks)}] L2W{w} {rec.trace_name} → "
                      f"{rec.status} {ipc_str} {hr_str}")
    else:
        for binary, t, w, trace_output_dir in tasks:
            rec = run_one_simulation(
                binary, t["path"], t["name"],
                output_dir, args.warmup, args.sim_instr
            )
            rec.l2_ways = w
            all_results.append(rec)
            completed += 1
            ipc_str = f"IPC={rec.ipc:.4f}" if rec.status == "OK" else ""
            hr_str = f"HR={rec.l2c_hit_rate*100:.1f}%" if rec.status == "OK" else ""
            print(f"  [{completed}/{len(tasks)}] L2W{w} {rec.trace_name} → "
                  f"{rec.status} {ipc_str} {hr_str}")

    # --- Analyze ---
    print("\n" + "=" * 70)
    print("Analysis: L2C Capacity Sensitivity")
    print("=" * 70)

    # Group by trace
    by_trace = defaultdict(list)
    for rec in all_results:
        by_trace[rec.trace_name].append(rec)

    reports = []
    for trace_name in sorted(by_trace):
        trace_results = by_trace[trace_name]
        report = analyze_trace(trace_results)
        reports.append(report)

    # Sort: flat-zone traces first
    reports.sort(key=lambda r: (not r.is_flat, r.trace_name))

    # --- Output ---
    csv_path = write_summary_csv(all_results, output_dir)
    print(f"\nSummary CSV: {csv_path}")

    report_path = write_flatzone_report(reports, output_dir)
    print(f"Flat-zone report: {report_path}")

    # Quick console summary
    print("\nQuick Summary:")
    print(f"{'Trace':<38} {'Best IPC':>8} {'Knee':>6} {'4→8W':>8} {'Flat?':>6}")
    print("-" * 70)
    for rp in reports:
        ok = [r for r in rp.results if r.status == "OK"]
        if len(ok) < 2:
            continue
        ipc_map = {r.l2_ways: r.ipc for r in ok}
        gain_str = ""
        if 4 in ipc_map and 8 in ipc_map:
            gain = (ipc_map[8] - ipc_map[4]) / ipc_map[4] * 100 if ipc_map[4] > 0 else 0
            gain_str = f"{gain:+.2f}%"
        print(f"{rp.trace_name:<38} {rp.best_ipc:8.4f} W{rp.knee_ways:<4} {gain_str:>8} {'⚠️ YES' if rp.is_flat else 'no':>6}")

    flat_count = sum(1 for rp in reports if rp.is_flat)
    print(f"\n{flat_count}/{len(reports)} traces show a flat zone (excess L2C capacity).")


if __name__ == "__main__":
    main()
