#!/usr/bin/env python3
"""
Experiment 1: Trace Availability Validation Script
===================================================
Performs a four-step validation on every trace file under traces/:

  Step 1 (static,  no champsim): xz integrity check      — `xz -t <file>`
  Step 2 (static,  no champsim): binary format check       — file_size % 64 == 0
  Step 3 (static,  no champsim): instruction count check   — total_instructions = file_size / 64
  Step 4 (runtime, uses bin/champsim): ChampSim dry-run   — short warmup+sim to catch
                                                             deadlock/livelock/assertions

Output: traces_validation.csv

┌──────────────────────────────────────────────────────────────────────────────┐
│ USAGE                                                                        │
├──────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   # 0. Compile ChampSim first (if not already):                              │
│   ./config.sh champsim_config.json && make                                   │
│                                                                              │
│   # 1. Run full validation (all 4 steps, sequential):                        │
│   python scripts/validate_traces.py                                          │
│                                                                              │
│   # 2. Parallel dry-run (4 jobs at once):                                    │
│   python scripts/validate_traces.py -j 4                                     │
│                                                                              │
│   # 3. Skip the ChampSim dry-run (static checks only, no bin/champsim):      │
│   python scripts/validate_traces.py --skip-dry-run                           │
│                                                                              │
│   # 4. Custom output path:                                                   │
│   python scripts/validate_traces.py --output artifacts/plans/my_result.csv   │
│                                                                              │
│   # 5. Custom traces dir or champsim binary:                                 │
│   python scripts/validate_traces.py \\                                        │
│       --traces-dir /path/to/traces \\                                         │
│       --champsim-bin /path/to/bin/champsim                                   │
│                                                                              │
│   # 6. Adjust dry-run instruction counts:                                    │
│   python scripts/validate_traces.py --dry-warmup 5000000 --dry-sim 500000    │
│                                                                              │
└──────────────────────────────────────────────────────────────────────────────┘
"""

import argparse
import csv
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from concurrent.futures import ProcessPoolExecutor, as_completed
from dataclasses import dataclass, field
from typing import Optional

# ---------------------------------------------------------------------------
# Configuration – adjust to your environment
# ---------------------------------------------------------------------------
CHAMPSIM_BIN = Path(__file__).resolve().parent.parent / "bin" / "champsim"
TRACES_DIR = Path(__file__).resolve().parent.parent / "traces"

# Subdirectories under traces/ to scan ("" = root)
TRACE_SUBDIRS = ["", "new", "new2"]

# Dry-run parameters
DRY_WARMUP_INSTR  = 10_000_000   # 10M warmup
DRY_SIM_INSTR     = 100_000_000  #  1M simulation

# Thresholds
MIN_INSTRUCTIONS  = 550_000_000  # 50M warmup + 500M simulation

# Struct size: sizeof(input_instr) = 64 bytes
INSTR_STRUCT_SIZE = 64

# ---------------------------------------------------------------------------
# Data structures
# ---------------------------------------------------------------------------
@dataclass
class TraceRecord:
    """Information gathered about a single trace file."""
    name: str
    subdir: str           # e.g. "", "new", "new2"
    path: Path            # absolute path to .xz file
    file_size: int = 0    # compressed size in bytes
    decompressed_size: int = 0
    xz_valid: bool = False
    size_aligned: bool = False        # decompressed_size % 64 == 0?
    total_instructions: int = 0       # decompressed_size / 64
    dry_run_exit_code: Optional[int] = None
    dry_run_ipc: Optional[float] = None
    dry_run_stderr: str = ""
    status: str = "PENDING"


# ---------------------------------------------------------------------------
# Step 1 – xz integrity
# ---------------------------------------------------------------------------
def check_xz_integrity(rec: TraceRecord) -> None:
    """Run `xz -t` and (separately) get decompressed size via `xz -l`.

    Timeouts are generous because 'xz -t' must decompress the entire file
    (which can be gigabytes), and the traces may reside on a remote/NFS
    filesystem accessed via symlink.
    """
    # Integrity test — full decompress, can be slow for large files
    # Timeout scales roughly: 2min base + file_size-based component
    xz_test_timeout = max(120, min(900, int(rec.path.stat().st_size / (50 * 1024 * 1024)) + 120))
    try:
        ret = subprocess.run(
            ["xz", "-t", str(rec.path)],
            capture_output=True, text=True, timeout=xz_test_timeout
        )
    except subprocess.TimeoutExpired:
        rec.xz_valid = False
        rec.status = "CORRUPTED"
        rec.decompressed_size = 0
        rec.file_size = rec.path.stat().st_size
        return

    if ret.returncode == 0:
        rec.xz_valid = True
    else:
        rec.xz_valid = False
        rec.status = "CORRUPTED"
        rec.file_size = rec.path.stat().st_size
        return

    # Decompressed size via xz --robot -l (fast: reads stream headers only)
    ret2 = subprocess.run(
        ["xz", "--robot", "-l", str(rec.path)],
        capture_output=True, text=True, timeout=30
    )
    if ret2.returncode == 0:
        for line in ret2.stdout.strip().split("\n"):
            parts = line.split("\t")
            if parts[0] == "totals" and len(parts) >= 5:
                rec.decompressed_size = int(parts[4])
                break

    rec.file_size = rec.path.stat().st_size


# ---------------------------------------------------------------------------
# Step 2 – binary format check
# ---------------------------------------------------------------------------
def check_format(rec: TraceRecord) -> None:
    """Verify decompressed size is a multiple of sizeof(input_instr) = 64."""
    if rec.decompressed_size <= 0:
        rec.size_aligned = False
        rec.status = "CORRUPTED"
        return
    rec.size_aligned = (rec.decompressed_size % INSTR_STRUCT_SIZE == 0)
    if not rec.size_aligned:
        rec.status = "FORMAT_ERROR"


# ---------------------------------------------------------------------------
# Step 3 – instruction count
# ---------------------------------------------------------------------------
def check_instruction_count(rec: TraceRecord) -> None:
    """Count instructions and check against minimum threshold."""
    rec.total_instructions = rec.decompressed_size // INSTR_STRUCT_SIZE
    if rec.total_instructions < MIN_INSTRUCTIONS:
        # Only mark INSUFFICIENT if format was OK but too few instructions
        if rec.status not in ("CORRUPTED", "FORMAT_ERROR"):
            rec.status = "INSUFFICIENT"


# ---------------------------------------------------------------------------
# Step 4 – ChampSim dry-run
# ---------------------------------------------------------------------------
def run_dry_run(rec: TraceRecord) -> TraceRecord:
    """Run ChampSim with a short warmup+simulation to catch runtime errors.

    Returns the modified TraceRecord (necessary for ProcessPoolExecutor
    which works on copies — the caller must use the returned value).
    """
    # Skip traces that already failed static checks
    if rec.status in ("CORRUPTED", "FORMAT_ERROR"):
        return rec

    champsim = CHAMPSIM_BIN
    if not champsim.is_file():
        print(f"[WARNING] champsim binary not found at {champsim}. Skipping dry-run for all traces.", file=sys.stderr)
        rec.dry_run_exit_code = -2  # binary not available
        return rec

    # IPC check constants from champsim.cc
    # Livelock detection: IPC < 0.01 triggers abort
    IPC_LIVELOCK_THRESHOLD = 0.01

    try:
        ret = subprocess.run(
            [
                str(champsim),
                "--warmup-instructions", str(DRY_WARMUP_INSTR),
                "--simulation-instructions", str(DRY_SIM_INSTR),
                "--hide-heartbeat",
                str(rec.path),
            ],
            capture_output=True, text=True
        )
        rec.dry_run_exit_code = ret.returncode
        rec.dry_run_stderr = ret.stderr

        if ret.returncode == 0:
            rec.dry_run_ipc = _parse_ipc(ret.stdout)
            if rec.dry_run_ipc is not None and rec.dry_run_ipc < IPC_LIVELOCK_THRESHOLD:
                rec.status = "RUNTIME_ERROR"
                rec.dry_run_stderr += f"\n[WARNING] IPC {rec.dry_run_ipc:.6g} below livelock threshold {IPC_LIVELOCK_THRESHOLD}"
            else:
                rec.status = "USABLE"
        else:
            rec.status = "RUNTIME_ERROR"

    except Exception as e:
        rec.dry_run_exit_code = -3
        rec.dry_run_stderr = str(e)
        rec.status = "RUNTIME_ERROR"

    return rec


def _parse_ipc(stdout: str) -> Optional[float]:
    """Extract cumulative IPC from ChampSim stdout.

    Example line:
      Simulation complete CPU 0 instructions: 1000000 cycles: 1500000 cumulative IPC: 0.6667 ...
    or:
      Simulation finished CPU 0 instructions: ... cycles: ... cumulative IPC: ...
    """
    for line in stdout.splitlines():
        # Match lines containing "cumulative IPC:"
        m = re.search(r"cumulative IPC:\s*([0-9.]+)", line)
        if m:
            return float(m.group(1))
    return None


# ---------------------------------------------------------------------------
# Trace discovery
# ---------------------------------------------------------------------------
def discover_traces() -> list[TraceRecord]:
    """Find all .xz trace files under TRACES_DIR/subdir."""
    records = []
    for subdir in TRACE_SUBDIRS:
        search_dir = TRACES_DIR / subdir if subdir else TRACES_DIR
        if not search_dir.is_dir():
            print(f"[WARNING] Directory {search_dir} does not exist, skipping.", file=sys.stderr)
            continue
        for fpath in sorted(search_dir.iterdir()):
            if fpath.suffix == ".xz":
                rec = TraceRecord(
                    name=fpath.name,
                    subdir=subdir if subdir else ".",
                    path=fpath.resolve(),
                )
                records.append(rec)
    return records


# ---------------------------------------------------------------------------
# Single-trace full validation (static steps 1-3)
# ---------------------------------------------------------------------------
def validate_trace_static(rec: TraceRecord) -> TraceRecord:
    """Run steps 1-3 on a single trace."""
    check_xz_integrity(rec)
    if rec.xz_valid:
        check_format(rec)
        if rec.size_aligned:
            check_instruction_count(rec)
    return rec


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    global CHAMPSIM_BIN, TRACES_DIR, DRY_WARMUP_INSTR, DRY_SIM_INSTR

    parser = argparse.ArgumentParser(
        description="Experiment 1: Validate all ChampSim traces"
    )
    parser.add_argument(
        "--skip-dry-run", action="store_true",
        help="Skip the ChampSim dry-run (Step 4)"
    )
    parser.add_argument(
        "--output", type=str, default="traces_validation.csv",
        help="Output CSV file path (default: traces_validation.csv)"
    )
    parser.add_argument(
        "--traces-dir", type=str, default=str(TRACES_DIR),
        help="Path to traces directory"
    )
    parser.add_argument(
        "--champsim-bin", type=str, default=str(CHAMPSIM_BIN),
        help="Path to champsim binary"
    )
    parser.add_argument(
        "--dry-warmup", type=int, default=DRY_WARMUP_INSTR,
        help="Warmup instructions for dry-run"
    )
    parser.add_argument(
        "--dry-sim", type=int, default=DRY_SIM_INSTR,
        help="Simulation instructions for dry-run"
    )
    parser.add_argument(
        "-j", "--jobs", type=int, default=1,
        help="Number of parallel dry-run jobs (default: 1)"
    )
    args = parser.parse_args()

    # Override module-level defaults from CLI args
    CHAMPSIM_BIN = Path(args.champsim_bin)
    TRACES_DIR = Path(args.traces_dir)
    DRY_WARMUP_INSTR = args.dry_warmup
    DRY_SIM_INSTR = args.dry_sim

    # --- Discover traces ---
    print("=" * 70)
    print("Experiment 1: Trace Availability Validation")
    print("=" * 70)
    print(f"Traces directory: {TRACES_DIR}")
    print(f"ChampSim binary:  {CHAMPSIM_BIN}")
    print()

    records = discover_traces()
    print(f"Found {len(records)} trace files.")
    print()

    # --- Steps 1-3: Static validation ---
    print("Running static checks (Steps 1-3)...")
    for i, rec in enumerate(records):
        file_mb = rec.path.stat().st_size / (1024 * 1024)
        print(f"  [{i+1}/{len(records)}] {rec.name} ({file_mb:.0f} MiB)...", end=" ", flush=True)
        validate_trace_static(rec)
        print(rec.status)

    # Print summary of static checks
    static_fail = [r for r in records if r.status in ("CORRUPTED", "FORMAT_ERROR")]
    if static_fail:
        print(f"  {len(static_fail)} trace(s) failed static checks:")
        for r in static_fail:
            print(f"    [{r.status}] {r.subdir}/{r.name}")
    else:
        print("  All traces passed static checks.")

    pass_static = [r for r in records if r.status not in ("CORRUPTED", "FORMAT_ERROR")]
    insufficient = [r for r in pass_static if r.status == "INSUFFICIENT"]
    if insufficient:
        print(f"  {len(insufficient)} trace(s) have insufficient instructions "
              f"(< {MIN_INSTRUCTIONS:,}):")
        for r in insufficient:
            print(f"    [{r.status}] {r.subdir}/{r.name} "
                  f"({r.total_instructions:,} instructions)")
    print()

    # --- Step 4: Dry-run ---
    if args.skip_dry_run:
        print("Skipping dry-run (--skip-dry-run specified).")
    elif not CHAMPSIM_BIN.is_file():
        print(f"ChampSim binary not found at {CHAMPSIM_BIN}. Skipping dry-run.")
        print("Compile ChampSim first: ./config.sh champsim_config.json && make")
    else:
        to_dry_run = [r for r in pass_static if r.status != "RUNTIME_ERROR"]
        print(f"Running ChampSim dry-run on {len(to_dry_run)} trace(s) "
              f"(warmup={DRY_WARMUP_INSTR:,}, sim={DRY_SIM_INSTR:,})...")
        print(f"Parallel jobs: {args.jobs}")
        print()

        if args.jobs > 1:
            # Parallel dry-run — ProcessPoolExecutor works on copies,
            # so we must use the returned record (not mutate in-place).
            completed = 0
            idx_map = {id(r): i for i, r in enumerate(records)}
            with ProcessPoolExecutor(max_workers=args.jobs) as executor:
                futures = {executor.submit(run_dry_run, r): id(r) for r in to_dry_run}
                for future in as_completed(futures):
                    obj_id = futures[future]
                    try:
                        result = future.result()  # modified copy from child process
                    except Exception as e:
                        # If the child itself crashes, mark the original
                        orig_idx = idx_map[obj_id]
                        records[orig_idx].dry_run_exit_code = -3
                        records[orig_idx].dry_run_stderr = str(e)
                        records[orig_idx].status = "RUNTIME_ERROR"
                        result = records[orig_idx]
                    completed += 1
                    # Replace the record in the original list with the returned copy
                    orig_idx = idx_map[obj_id]
                    records[orig_idx] = result
                    rec = records[orig_idx]
                    print(f"  [{completed}/{len(to_dry_run)}] {rec.subdir}/{rec.name} "
                          f"-> {rec.status}" + (f" (IPC={rec.dry_run_ipc:.4f})" if rec.dry_run_ipc else ""))
        else:
            # Sequential dry-run — same-process, in-place mutation works fine
            for i, rec in enumerate(to_dry_run):
                rec = run_dry_run(rec)
                print(f"  [{i+1}/{len(to_dry_run)}] {rec.subdir}/{rec.name} "
                      f"-> {rec.status}" + (f" (IPC={rec.dry_run_ipc:.4f})" if rec.dry_run_ipc else ""))
                # Print stderr if there was an error
                if rec.status == "RUNTIME_ERROR" and rec.dry_run_stderr:
                    short_err = rec.dry_run_stderr.strip()[-500:]
                    print(f"    stderr: {short_err}")

    print()

    # --- Write output CSV ---
    output_path = args.output
    fieldnames = [
        "name", "subdir", "path",
        "file_size", "decompressed_size",
        "xz_valid", "size_aligned",
        "total_instructions",
        "dry_run_exit_code", "dry_run_ipc",
        "status"
    ]
    with open(output_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        for rec in records:
            writer.writerow({
                "name": rec.name,
                "subdir": rec.subdir,
                "path": str(rec.path),
                "file_size": rec.file_size,
                "decompressed_size": rec.decompressed_size,
                "xz_valid": rec.xz_valid,
                "size_aligned": rec.size_aligned,
                "total_instructions": rec.total_instructions,
                "dry_run_exit_code": rec.dry_run_exit_code if rec.dry_run_exit_code is not None else "",
                "dry_run_ipc": f"{rec.dry_run_ipc:.6f}" if rec.dry_run_ipc is not None else "",
                "status": rec.status,
            })

    # --- Final summary ---
    usable   = sum(1 for r in records if r.status == "USABLE")
    insuff   = sum(1 for r in records if r.status == "INSUFFICIENT")
    runtime  = sum(1 for r in records if r.status == "RUNTIME_ERROR")
    corrupted = sum(1 for r in records if r.status == "CORRUPTED")
    fmt_err  = sum(1 for r in records if r.status == "FORMAT_ERROR")

    print("=" * 70)
    print("Validation Summary")
    print("=" * 70)
    print(f"  USABLE:          {usable:3d}")
    print(f"  INSUFFICIENT:    {insuff:3d}")
    print(f"  RUNTIME_ERROR:   {runtime:3d}")
    print(f"  CORRUPTED:       {corrupted:3d}")
    print(f"  FORMAT_ERROR:    {fmt_err:3d}")
    print(f"  ─────────────────────")
    print(f"  TOTAL:           {len(records):3d}")
    print()
    print(f"Output written to: {output_path}")

if __name__ == "__main__":
    main()
