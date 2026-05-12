#!/usr/bin/env python3
"""
CPU2017 PIN trace generation — full parallel, /tmp for raw traces.
Uses DPC-3 SimPoints for speed benchmarks.
"""

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

# ─── Configuration ───────────────────────────────────────────────────────────
PIN_ROOT = Path.home() / "pin-3.22-98547-g7a303a835-gcc-linux"
PIN = PIN_ROOT / "pin"
TRACER = Path.home() / "coordinate_proj/ChampSim/tracer/pin/obj-intel64/champsim_tracer.so"
CPU2017_ROOT = Path.home() / "cpu2017"
DATA_ROOT = Path.home() / "coordinate_proj/ChampSim/tools/profiling/data"
TMP_ROOT = Path("/tmp/cpu2017_traces")
INTERVAL_SIZE = 100_000_000
TRACE_TARGET_BYTES = INTERVAL_SIZE * 64  # 6.4GB
TRACE_MIN_BYTES = int(TRACE_TARGET_BYTES * 0.98)  # 98% threshold for early termination
WEIGHT_THRESHOLD = 0.01

def log(msg: str):
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def get_exe_name(bench_dir: Path) -> str:
    obj_pm = bench_dir / "Spec" / "object.pm"
    if not obj_pm.exists():
        return ""
    m = re.search(r"\$exename\s*=\s*'([^']+)'", obj_pm.read_text())
    return m.group(1) if m else ""


def find_binary(bench_dir: Path, exe_name: str) -> Path | None:
    for build_dir in bench_dir.glob("build/build_base_*"):
        binary = build_dir / exe_name
        if binary.exists() and binary.is_file() and os.access(binary, os.X_OK):
            return binary
        for f in build_dir.iterdir():
            if f.is_file() and os.access(f, os.X_OK) and f.name.lower() == exe_name.lower():
                return f
    for run_dir in bench_dir.glob("run/run_base_train_*"):
        binary = run_dir / exe_name
        if binary.exists() and binary.is_file() and os.access(binary, os.X_OK):
            return binary
        for f in run_dir.iterdir():
            if f.is_file() and os.access(f, os.X_OK) and f.name.startswith(exe_name):
                return f
    return None


def find_run_dir(bench_dir: Path) -> Path | None:
    for pattern in ["run_base_refspeed_*", "run_base_refrate_*", "run_base_ref_*", "run_base_train_*"]:
        dirs = list(bench_dir.glob(f"run/{pattern}"))
        if dirs:
            return dirs[0]
    return None


def load_simpoints(bench_name: str) -> list[dict]:
    sim_json = DATA_ROOT / bench_name / "simpoints.json"
    if not sim_json.exists():
        return []
    return [e for e in json.loads(sim_json.read_text()) if e["weight"] >= WEIGHT_THRESHOLD]


def parse_speccmds(cmd_file: Path) -> tuple[str, str, str]:
    """Parse speccmds.cmd. Returns (work_dir, args, stdin_file)."""
    if not cmd_file.exists():
        return "", "", ""
    work_dir = ""
    stdin_file = ""
    for line in cmd_file.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("-E") or line.startswith("-r") or line.startswith("-N"):
            continue
        if line.startswith("-C "):
            work_dir = line[3:].strip()
            continue
        # Extract specinvoke -i <stdin_file>
        m = re.search(r'(?:^|\s)-i\s+(\S+)', line)
        if m:
            stdin_file = m.group(1)
        # Strip specinvoke markers: -i <file>, -o <file>, -e <file>
        args = re.sub(r'(?:^|\s)-i\s+\S+', '', line, count=1)
        args = re.sub(r'(?:^|\s)-o\s+\S+', '', args, count=1)
        args = re.sub(r'(?:^|\s)-e\s+\S+', '', args, count=1)
        # Strip shell redirects and binary path
        args = re.sub(r'\s*[12]?>>?\s*\S+', '', args)
        args = re.sub(r'(?:^|\s)\.\.\/\S+', '', args)
        return work_dir, args.strip(), stdin_file
    return "", "", ""


def trace_interval(bench_name: str, interval: dict, binary: Path,
                   work_dir: Path, spec_args: str, stdin_file: str = "") -> bool:
    sid = interval["interval_id"]
    start_instr = sid * INTERVAL_SIZE

    # Raw trace goes to /tmp
    tmp_dir = TMP_ROOT / bench_name
    tmp_dir.mkdir(parents=True, exist_ok=True)
    trace_out = tmp_dir / f"{bench_name}-{sid}B.champsimtrace"

    # Final compressed destination
    final_dir = DATA_ROOT / bench_name / "traces"
    final_xz = final_dir / f"{bench_name}-{sid}B.champsimtrace.xz"

    if final_xz.exists():
        log(f"  [{bench_name}] [SKIP] interval {sid} — already done")
        return True

    cmd = [
        str(PIN), "-t", str(TRACER),
        "-o", str(trace_out),
        "-s", str(start_instr),
        "-t", str(INTERVAL_SIZE),
        "--", str(binary),
    ] + spec_args.split()

    log(f"  [{bench_name}] [PIN:{sid}] start (skip={start_instr}, record={INTERVAL_SIZE})")

    try:
        stdin_fh = None
        if stdin_file:
            stdin_path = Path(work_dir) / stdin_file
            if not stdin_path.exists():
                stdin_path = Path(stdin_file)
            if stdin_path.exists():
                stdin_fh = open(stdin_path, "rb")

        proc = subprocess.Popen(cmd, cwd=str(work_dir),
                                stdin=stdin_fh,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        last_size_report = 0
        while proc.poll() is None:
            time.sleep(10)
            if trace_out.exists():
                sz = trace_out.stat().st_size
                if sz >= TRACE_TARGET_BYTES:
                    log(f"  [{bench_name}] [PIN:{sid}] "
                        f"{sz / (1024**3):.1f}GB target reached, terminating")
                    proc.terminate()
                    try:
                        proc.wait(timeout=30)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait()
                    break
                # Also terminate if file stopped growing at > 98% target for 30s
                if sz >= TRACE_MIN_BYTES and sz == last_size_report and sz > 0:
                    stable_count = getattr(trace_interval, '_stable_count', 0) + 1
                    # Use a local var instead of function attr — check prev iter
                    if sz == last_size_report:
                        pass  # handled below by checking stability across iterations
                    last_size_report = sz
                    continue  # just report progress
                if sz - last_size_report >= 1_000_000_000:
                    pct = min(100, sz * 100 // TRACE_TARGET_BYTES)
                    log(f"  [{bench_name}] [PIN:{sid}] {sz / (1024**3):.1f}GB ({pct}%)")
                last_size_report = sz

        if trace_out.exists() and trace_out.stat().st_size > 0:
            log(f"  [{bench_name}] [PIN:{sid}] compressing...")
            subprocess.run(["xz", "-T0", str(trace_out)], check=True)
            # Move to final location
            final_dir.mkdir(parents=True, exist_ok=True)
            xz_file = Path(str(trace_out) + ".xz")
            shutil.move(str(xz_file), str(final_xz))
            log(f"  [{bench_name}] [PIN:{sid}] done → {final_xz} ({final_xz.stat().st_size // (1024*1024)}MB)")
            return True
        else:
            log(f"  [{bench_name}] [PIN:{sid}] FAILED — no trace produced")
            return False
    except Exception as e:
        log(f"  [{bench_name}] [PIN:{sid}] ERROR: {e}")
        return False


def process_benchmark(bench_name: str, jobs: int):
    bench_dir = CPU2017_ROOT / "benchspec" / "CPU" / bench_name
    simpoints = load_simpoints(bench_name)
    if not simpoints:
        log(f"[{bench_name}] SKIP — no simpoints")
        return

    exe_name = get_exe_name(bench_dir)
    binary = find_binary(bench_dir, exe_name)
    if not binary:
        log(f"[{bench_name}] SKIP — binary not found")
        return

    run_dir = find_run_dir(bench_dir)
    if not run_dir:
        log(f"[{bench_name}] SKIP — no run dir")
        return

    work_dir, spec_args, stdin_file = parse_speccmds(run_dir / "speccmds.cmd")
    work_dir = work_dir or str(run_dir)
    spec_args = spec_args or ""

    n = sum(1 for e in simpoints if e["weight"] >= WEIGHT_THRESHOLD)
    extra = f" stdin={stdin_file}" if stdin_file else ""
    log(f"[{bench_name}] binary={binary.name} intervals={n} args={spec_args[:80]}{extra}")

    with ThreadPoolExecutor(max_workers=jobs) as pool:
        futures = {pool.submit(trace_interval, bench_name, e, binary, Path(work_dir), spec_args, stdin_file): e
                   for e in simpoints}
        ok = fail = 0
        for f in as_completed(futures):
            if f.result():
                ok += 1
            else:
                fail += 1
        log(f"[{bench_name}] done: {ok} ok, {fail} failed")


def discover_speed_benchmarks() -> list[str]:
    result = []
    for d in sorted(DATA_ROOT.iterdir()):
        if d.is_dir() and d.name.endswith("_s") and (d / "simpoints.json").exists() and (d / "disasm_index.json").exists():
            result.append(d.name)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bench", help="Single benchmark")
    parser.add_argument("--jobs", type=int, default=2, help="Concurrent intervals per benchmark")
    parser.add_argument("--parallel", type=int, default=4, help="Concurrent benchmarks")
    args = parser.parse_args()

    if not PIN.exists():
        log(f"ERROR: PIN not found at {PIN}"); sys.exit(1)
    if not TRACER.exists():
        log(f"ERROR: Tracer not found at {TRACER}"); sys.exit(1)

    benchmarks = [args.bench] if args.bench else discover_speed_benchmarks()

    TMP_ROOT.mkdir(parents=True, exist_ok=True)
    log(f"PIN: {PIN}")
    log(f"TMP: {TMP_ROOT} ({shutil.disk_usage(str(TMP_ROOT)).free // (1024**3)}GB free)")
    log(f"Benchmarks: {len(benchmarks)}, parallel={args.parallel}, jobs-per-bench={args.jobs}")
    log(f"Total peak disk: ~{len(benchmarks) * args.parallel * 6.4:.0f}GB raw (in /tmp)")

    with ThreadPoolExecutor(max_workers=args.parallel) as pool:
        futures = {pool.submit(process_benchmark, b, args.jobs): b for b in benchmarks}
        for f in as_completed(futures):
            b = futures[f]
            try:
                f.result()
            except Exception as e:
                log(f"[{b}] FAILED: {e}")

    log("=== All benchmarks complete ===")


if __name__ == "__main__":
    main()
