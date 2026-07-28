#!/usr/bin/env python3
"""
Experiment 2: L2C Utilization Simulation
=========================================
Runs ChampSim simulations on all USABLE traces (from Experiment 1) and
collects L2C utilization metrics (hit rate, MPKI, miss rate, etc.).

Input:  traces_validation.csv    (produced by Experiment 1 / validate_traces.py)
Output: l2c_utilization_summary.csv
        One JSON file per trace  (in --output-dir)

Requires ChampSim to be compiled with the baseline configuration first:
  ./config.sh champsim_config.json && make

┌──────────────────────────────────────────────────────────────────────────────┐
│ USAGE                                                                        │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   # 0. Prerequisite — run Experiment 1 first:                                │
│   python scripts/validate_traces.py -j 4                                     │
│                                                                              │
│   # 1. Run simulation (sequential, one trace at a time):                     │
│   python scripts/run_simulation.py --validation-csv traces_validation.csv    │
│                                                                              │
│   # 2. Parallel simulation (4 traces at once):                               │
│   python scripts/run_simulation.py --validation-csv traces_validation.csv -j4│
│                                                                              │
│   # 3. Custom output directory:                                              │
│   python scripts/run_simulation.py --validation-csv traces_validation.csv \\  │
│       --output-dir artifacts/runs/exp2                                       │
│                                                                              │
│   # 4. Custom warmup/simulation instruction counts:                          │
│   python scripts/run_simulation.py --validation-csv traces_validation.csv \\  │
│       --warmup 100000000 --sim-instr 1000000000                              │
│                                                                              │
│   # 5. Dry-run mode (see what would be executed, without running):           │
│   python scripts/run_simulation.py --validation-csv traces_validation.csv \\  │
│       --dry-run                                                              │
│                                                                              │
│   # 6. Full pipeline (Experiment 1 -> Experiment 2):                         │
│   python scripts/validate_traces.py -j 4 && \\                                │
│   python scripts/run_simulation.py --validation-csv traces_validation.csv -j4│
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
"""

import argparse
import csv
import json
import os
import subprocess
import sys
from collections import defaultdict
from concurrent.futures import ProcessPoolExecutor, as_completed
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
CHAMPSIM_BIN = Path(__file__).resolve().parent.parent / "bin" / "champsim"

# Simulation parameters (can be overridden via CLI)
WARMUP_INSTRUCTIONS  = 50_000_000   # 50M
SIM_INSTRUCTIONS     = 500_000_000  # 500M

# ---------------------------------------------------------------------------
# Data structures
# ---------------------------------------------------------------------------
@dataclass
class L2CStats:
    """Parsed L2C statistics for a single trace simulation."""
    trace_name: str
    status: str = "PENDING"

    # From CPU stats
    instructions: int = 0
    cycles: int = 0
    ipc: float = 0.0

    # L2C total (sum across all access types)
    l2c_total_access: int = 0
    l2c_total_hit: int = 0
    l2c_total_miss: int = 0
    l2c_total_miss_merge: int = 0

    # L2C per-type
    l2c_load_access: int = 0
    l2c_load_hit: int = 0
    l2c_load_miss: int = 0

    l2c_rfo_access: int = 0
    l2c_rfo_hit: int = 0
    l2c_rfo_miss: int = 0

    l2c_write_access: int = 0
    l2c_write_hit: int = 0
    l2c_write_miss: int = 0

    l2c_prefetch_access: int = 0
    l2c_prefetch_hit: int = 0
    l2c_prefetch_miss: int = 0

    l2c_translation_access: int = 0
    l2c_translation_hit: int = 0
    l2c_translation_miss: int = 0

    # Prefetch stats (should be 0 since prefetch disabled)
    l2c_pf_requested: int = 0
    l2c_pf_issued: int = 0
    l2c_pf_useful: int = 0
    l2c_pf_useless: int = 0
    l2c_pf_fill: int = 0

    # Miss latency
    l2c_avg_miss_latency: float = 0.0

    # --- Derived metrics (computed) ---
    l2c_hit_rate: float = 0.0       # total_hit / total_access
    l2c_miss_rate: float = 0.0      # total_miss / total_access
    l2c_mpki: float = 0.0           # total_miss / (instructions / 1000)

    # L1D miss -> L2C ratio (if available)
    l1d_total_access: int = 0
    l1d_total_miss: int = 0
    l1d_to_l2c_ratio: float = 0.0   # l2c_total_access / l1d_total_miss (approx)

    # LLC access (for comparison)
    llc_total_access: int = 0
    llc_total_hit: int = 0
    llc_total_miss: int = 0
    l2c_to_llc_ratio: float = 0.0   # llc_total_access / l2c_total_access

    # Raw JSON for debugging
    raw_json: Optional[dict] = None


def load_usable_traces(validation_csv: str) -> list[dict]:
    """Read the Experiment 1 validation CSV and return USABLE traces."""
    traces = []
    with open(validation_csv, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            if row["status"] == "USABLE":
                traces.append(row)
    return traces


def run_one_simulation(trace_info: dict, output_dir: Path,
                       warmup: int, sim_instr: int) -> L2CStats:
    """Run ChampSim on a single trace and parse L2C stats."""
    rec = L2CStats(trace_name=trace_info["name"])
    trace_path = trace_info["path"]

    json_file = output_dir / f"{Path(trace_info['name']).stem}.json"

    champsim = CHAMPSIM_BIN
    if not champsim.is_file():
        rec.status = f"ERROR: champsim binary not found at {champsim}"
        return rec

    try:
        ret = subprocess.run(
            [
                str(champsim),
                "--warmup-instructions", str(warmup),
                "--simulation-instructions", str(sim_instr),
                "--json", str(json_file),
                "--hide-heartbeat",
                trace_path,
            ],
            capture_output=True, text=True, timeout=7200  # 2h per trace
        )

        if ret.returncode != 0:
            rec.status = f"ERROR: exit_code={ret.returncode}"
            return rec

        if not json_file.is_file():
            rec.status = f"ERROR: JSON output file not created: {json_file}"
            return rec

        # Parse JSON output
        with open(json_file) as f:
            data = json.load(f)

        rec.raw_json = data
        _parse_stats(rec, data)
        rec.status = "OK"

    except subprocess.TimeoutExpired:
        rec.status = "ERROR: TIMEOUT"
    except json.JSONDecodeError as e:
        rec.status = f"ERROR: JSON parse failed: {e}"
    except Exception as e:
        rec.status = f"ERROR: {e}"

    return rec


def _parse_stats(rec: L2CStats, data: list) -> None:
    """Extract L2C and related stats from ChampSim JSON output.

    Expected JSON structure:
    [{
      "name": "Simulation",
      "roi": {
        "cores": [{ "instructions": ..., "cycles": ... }],
        "L1D": { "LOAD": {"hit": [...], "miss": [...]}, ... },
        "L2C": { "LOAD": {"hit": [...], "miss": [...]}, ... },
        "LLC": { "LOAD": {"hit": [...], "miss": [...]}, ... },
        ...
      }
    }]
    """
    if not isinstance(data, list) or len(data) == 0:
        rec.status = "ERROR: unexpected JSON structure (not a list)"
        return

    phase = data[0]
    roi = phase.get("roi", {})

    # --- CPU stats ---
    cores = roi.get("cores", [])
    if cores:
        cpu0 = cores[0]
        rec.instructions = cpu0.get("instructions", 0)
        rec.cycles = cpu0.get("cycles", 0)
        rec.ipc = rec.instructions / rec.cycles if rec.cycles > 0 else 0.0

    # --- L2C stats ---
    l2c = roi.get("cpu0_L2C", roi.get("L2C", {}))
    if l2c:
        _parse_cache_level(rec, l2c, prefix="l2c")
        rec.l2c_pf_requested = l2c.get("prefetch requested", 0)
        rec.l2c_pf_issued = l2c.get("prefetch issued", 0)
        rec.l2c_pf_useful = l2c.get("useful prefetch", 0)
        rec.l2c_pf_useless = l2c.get("useless prefetch", 0)
        rec.l2c_pf_fill = l2c.get("prefetch fill", l2c.get("prefetch fill ", 0))

        # Average miss latency
        miss_lat = l2c.get("miss latency", 0)
        rec.l2c_avg_miss_latency = float(miss_lat) if miss_lat else 0.0

    # --- L1D stats (for L1D miss -> L2C ratio) ---
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
        if l1d_miss > 0:
            rec.l1d_to_l2c_ratio = rec.l2c_total_access / l1d_miss

    # --- LLC stats (for L2C/LLC comparison) ---
    llc = roi.get("LLC", {})
    if llc:
        llc_access = 0
        llc_hit = 0
        llc_miss = 0
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
        if llc_access > 0:
            rec.l2c_to_llc_ratio = llc_access / rec.l2c_total_access if rec.l2c_total_access > 0 else 0.0

    # --- Compute derived metrics ---
    if rec.l2c_total_access > 0:
        rec.l2c_hit_rate = rec.l2c_total_hit / rec.l2c_total_access
        rec.l2c_miss_rate = rec.l2c_total_miss / rec.l2c_total_access
    if rec.instructions > 0:
        rec.l2c_mpki = rec.l2c_total_miss / (rec.instructions / 1000.0)


def _parse_cache_level(rec: L2CStats, cache_data: dict, prefix: str) -> None:
    """Parse per-access-type hits/misses from a cache level JSON dict."""
    total_access = 0
    total_hit = 0
    total_miss = 0
    total_miss_merge = 0

    for atype, field_name in [
        ("LOAD", "load"), ("RFO", "rfo"), ("WRITE", "write"),
        ("PREFETCH", "prefetch"), ("TRANSLATION", "translation")
    ]:
        entry = cache_data.get(atype, {})
        hits = sum(entry.get("hit", [0]))
        misses = sum(entry.get("miss", [0]))
        miss_merges = sum(entry.get("miss_merge", [0]))

        setattr(rec, f"{prefix}_{field_name}_access", hits + misses)
        setattr(rec, f"{prefix}_{field_name}_hit", hits)
        setattr(rec, f"{prefix}_{field_name}_miss", misses)

        total_access += hits + misses
        total_hit += hits
        total_miss += misses
        total_miss_merge += miss_merges

    setattr(rec, f"{prefix}_total_access", total_access)
    setattr(rec, f"{prefix}_total_hit", total_hit)
    setattr(rec, f"{prefix}_total_miss", total_miss)
    setattr(rec, f"{prefix}_total_miss_merge", total_miss_merge)


# ---------------------------------------------------------------------------
# Result aggregation
# ---------------------------------------------------------------------------
OUTPUT_FIELDNAMES = [
    "trace_name", "status",
    "instructions", "cycles", "ipc",
    # L2C totals
    "l2c_total_access", "l2c_total_hit", "l2c_total_miss",
    "l2c_hit_rate", "l2c_miss_rate", "l2c_mpki",
    # L2C per-type
    "l2c_load_access", "l2c_load_hit", "l2c_load_miss",
    "l2c_rfo_access", "l2c_rfo_hit", "l2c_rfo_miss",
    "l2c_write_access", "l2c_write_hit", "l2c_write_miss",
    "l2c_prefetch_access", "l2c_prefetch_hit", "l2c_prefetch_miss",
    "l2c_translation_access", "l2c_translation_hit", "l2c_translation_miss",
    # Prefetch
    "l2c_pf_requested", "l2c_pf_issued", "l2c_pf_useful", "l2c_pf_useless",
    # Miss latency
    "l2c_avg_miss_latency",
    # Cross-level
    "l1d_total_access", "l1d_total_miss", "l1d_to_l2c_ratio",
    "llc_total_access", "llc_total_hit", "llc_total_miss", "l2c_to_llc_ratio",
]


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    global CHAMPSIM_BIN

    parser = argparse.ArgumentParser(
        description="Experiment 2: L2C Utilization Simulation"
    )
    parser.add_argument(
        "--validation-csv", type=str, required=True,
        help="Path to traces_validation.csv from Experiment 1"
    )
    parser.add_argument(
        "--output-dir", type=str, default="artifacts/runs/exp2",
        help="Directory for simulation outputs (JSON files and summary CSV)"
    )
    parser.add_argument(
        "--champsim-bin", type=str, default=str(CHAMPSIM_BIN),
        help="Path to champsim binary"
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
        help="Number of parallel simulation jobs (default: 1)"
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Print what would be run without actually running simulations"
    )
    args = parser.parse_args()

    CHAMPSIM_BIN = Path(args.champsim_bin)

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    # Load USABLE traces
    traces = load_usable_traces(args.validation_csv)
    if not traces:
        print("No USABLE traces found. Run Experiment 1 first.")
        sys.exit(1)

    print("=" * 70)
    print("Experiment 2: L2C Utilization Simulation")
    print("=" * 70)
    print(f"ChampSim binary:  {CHAMPSIM_BIN}")
    print(f"Output directory: {output_dir}")
    print(f"Warmup:           {args.warmup:,} instructions")
    print(f"Simulation:       {args.sim_instr:,} instructions")
    print(f"USABLE traces:    {len(traces)}")
    print(f"Parallel jobs:    {args.jobs}")
    print()

    if args.dry_run:
        print("DRY RUN -- would execute the following:")
        for t in traces:
            print(f"  bin/champsim -w {args.warmup} -i {args.sim_instr} "
                  f"--json {output_dir / Path(t['name']).stem}.json "
                  f"{t['path']}")
        return

    if not CHAMPSIM_BIN.is_file():
        print(f"ChampSim binary not found at {CHAMPSIM_BIN}.")
        print("Compile first: ./config.sh champsim_config.json && make")
        sys.exit(1)

    results: list[L2CStats] = []

    if args.jobs > 1:
        with ProcessPoolExecutor(max_workers=args.jobs) as executor:
            futures = {
                executor.submit(
                    run_one_simulation, t, output_dir,
                    args.warmup, args.sim_instr
                ): t for t in traces
            }
            for future in as_completed(futures):
                trace_info = futures[future]
                try:
                    rec = future.result()
                except Exception as e:
                    rec = L2CStats(trace_name=trace_info["name"])
                    rec.status = f"ERROR: {e}"
                results.append(rec)
                print(f"  [{len(results)}/{len(traces)}] {rec.trace_name} "
                      f"-> {rec.status}" +
                      (f" (IPC={rec.ipc:.4f}, L2C hit_rate={rec.l2c_hit_rate:.3f})"
                       if rec.status == "OK" else ""))
    else:
        for i, t in enumerate(traces):
            rec = run_one_simulation(t, output_dir, args.warmup, args.sim_instr)
            results.append(rec)
            print(f"  [{i+1}/{len(traces)}] {rec.trace_name} "
                  f"-> {rec.status}" +
                  (f" (IPC={rec.ipc:.4f}, L2C hit_rate={rec.l2c_hit_rate:.3f})"
                   if rec.status == "OK" else ""))

    # Sort by trace name for consistent output
    results.sort(key=lambda r: r.trace_name)

    # --- Write summary CSV ---
    summary_csv = output_dir / "l2c_utilization_summary.csv"
    with open(summary_csv, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=OUTPUT_FIELDNAMES, extrasaction="ignore")
        writer.writeheader()
        for rec in results:
            row = {fn: getattr(rec, fn, "") for fn in OUTPUT_FIELDNAMES}
            writer.writerow(row)

    # --- Print summary ---
    ok_results = [r for r in results if r.status == "OK"]
    error_results = [r for r in results if r.status != "OK"]

    print()
    print("=" * 70)
    print("Simulation Summary")
    print("=" * 70)
    print(f"  OK:              {len(ok_results):3d}")
    print(f"  ERROR:           {len(error_results):3d}")
    print()

    if ok_results:
        # Aggregate stats
        hit_rates = [r.l2c_hit_rate for r in ok_results]
        mpkis = [r.l2c_mpki for r in ok_results]
        miss_rates = [r.l2c_miss_rate for r in ok_results]
        ipcs = [r.ipc for r in ok_results]
        l1d_to_l2c = [r.l1d_to_l2c_ratio for r in ok_results]
        l2c_to_llc = [r.l2c_to_llc_ratio for r in ok_results]
        avg_miss_lat = [r.l2c_avg_miss_latency for r in ok_results]

        def stats(name, values):
            if not values:
                return
            print(f"  {name}:")
            print(f"    Mean:   {sum(values)/len(values):.4f}")
            print(f"    Median: {sorted(values)[len(values)//2]:.4f}")
            print(f"    Min:    {min(values):.4f}")
            print(f"    Max:    {max(values):.4f}")

        stats("L2C Hit Rate", hit_rates)
        stats("L2C MPKI", mpkis)
        stats("L2C Miss Rate", miss_rates)
        stats("IPC", ipcs)
        stats("L1D Miss -> L2C Ratio", l1d_to_l2c)
        stats("L2C / LLC Access Ratio", l2c_to_llc)
        stats("Avg Miss Latency (cycles)", avg_miss_lat)

        # Check for utilization signals
        high_hit = [r for r in ok_results if r.l2c_hit_rate > 0.9]
        low_mpki = [r for r in ok_results if r.l2c_mpki < 1.0]
        high_miss = [r for r in ok_results if r.l2c_miss_rate > 0.5]

        print()
        print(f"  Traces with L2C hit_rate > 90%:  {len(high_hit)}")
        print(f"  Traces with L2C MPKI < 1:        {len(low_mpki)}")
        print(f"  Traces with L2C miss_rate > 50%: {len(high_miss)}")

        # Utilization assessment (preliminary)
        both_low = [r for r in ok_results if r.l2c_hit_rate > 0.9 and r.l2c_mpki < 1.0]
        if both_low:
            print()
            print(f"  ⚠ {len(both_low)} trace(s) show BOTH high hit rate (>90%) AND low MPKI (<1):")
            print(f"    These may indicate L2C under-utilization.")
            for r in both_low:
                print(f"      - {r.trace_name}: hit_rate={r.l2c_hit_rate:.3f}, MPKI={r.l2c_mpki:.2f}")

    print()
    print(f"Summary CSV written to: {summary_csv}")
    print(f"JSON outputs in:        {output_dir}")


if __name__ == "__main__":
    main()
