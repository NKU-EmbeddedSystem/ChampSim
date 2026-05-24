#!/usr/bin/env bash
# Generic ChampSim batch evaluation script
# Usage:
#   bash tools/eval/run_eval.sh --traces trace/ --configs lru,ship,mockingjay --warmup 50M --sim 200M
set -euo pipefail

# --- Defaults ---
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
WARMUP=50000000
SIM=200000000
N_JOBS=48
TRACE_DIR=""
CONFIG_NAMES=""
OUTPUT_DIR="$ROOT_DIR/reports/eval"
REPORT_DIR="$ROOT_DIR/reports/set-dueling-eval"  # for config JSONs
INCREMENTAL=false  # skip existing JSONs

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --traces) TRACE_DIR="$2"; shift 2 ;;
        --configs) CONFIG_NAMES="$2"; shift 2 ;;
        --warmup) WARMUP="$2"; shift 2 ;;
        --sim) SIM="$2"; shift 2 ;;
        --parallel) N_JOBS="$2"; shift 2 ;;
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        --incremental) INCREMENTAL=true; shift ;;
        --config-dir) REPORT_DIR="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

if [ -z "$TRACE_DIR" ] || [ -z "$CONFIG_NAMES" ]; then
    echo "Usage: $0 --traces <dir> --configs <cfg1,cfg2,...> [--warmup <N>] [--sim <N>] [--parallel <N>] [--output <dir>] [--incremental]"
    echo ""
    echo "  --traces DIR        Directory containing *.trace.xz or *.champsimtrace.xz files"
    echo "  --configs CFG1,CFG2 CSV list of config names (must match .json in config-dir)"
    echo "  --warmup N          Warmup instructions (default: 50000000)"
    echo "  --sim N             Simulation instructions (default: 200000000)"
    echo "  --parallel N        Max concurrent jobs (default: 48)"
    echo "  --output DIR        Output directory for JSONs and logs (default: reports/eval)"
    echo "  --incremental       Skip trace×config combos that already have JSON results"
    echo "  --config-dir DIR    Directory with <cfg>.json files (default: reports/set-dueling-eval/configs)"
    exit 1
fi

IFS=',' read -ra CONFIGS <<< "$CONFIG_NAMES"

# --- Find traces ---
TRACES=()
for pattern in "$TRACE_DIR"/*.trace.xz "$TRACE_DIR"/*.champsimtrace.xz "$TRACE_DIR"/**/*.trace.xz "$TRACE_DIR"/**/*.champsimtrace.xz; do
    [ -f "$pattern" ] && TRACES+=("$pattern")
done
# dedup
readarray -t TRACES < <(printf '%s\n' "${TRACES[@]}" | sort -u)

if [ ${#TRACES[@]} -eq 0 ]; then
    echo "ERROR: No trace files found in $TRACE_DIR"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"/{json,logs,bin}

total=$((${#CONFIGS[@]} * ${#TRACES[@]}))
echo "============================================================"
echo " Batch Eval: ${#TRACES[@]} traces × ${#CONFIGS[@]} configs = $total runs"
echo " Traces:  $TRACE_DIR"
echo " Configs: ${CONFIGS[*]}"
echo " Warmup:  $WARMUP  Sim: $SIM  Parallel: $N_JOBS"
echo " Output:  $OUTPUT_DIR"
echo "============================================================"
echo ""

# --- Build missing binaries ---
cd "$ROOT_DIR"
for cfg in "${CONFIGS[@]}"; do
    bin="$OUTPUT_DIR/bin/champsim_${cfg}"
    if [ -f "$bin" ]; then continue; fi
    cfg_file="$REPORT_DIR/configs/${cfg}.json"
    if [ ! -f "$cfg_file" ]; then
        echo "  [ERROR] Config file not found: $cfg_file"
        continue
    fi
    echo "  [build] $cfg ..."
    ./config.sh "$cfg_file" > /dev/null 2>&1 || { echo "  [FAIL] config.sh failed for $cfg"; exit 1; }
    make clean > /dev/null 2>&1 || true
    make -j$(nproc) > /dev/null 2>&1 || { echo "  [FAIL] make failed for $cfg"; exit 1; }
    cp bin/champsim "$bin" || { echo "  [FAIL] binary copy failed for $cfg"; exit 1; }
    echo "  [done] $cfg"
done

# --- Run simulations ---
n=0; skip=0; running=0
for cfg in "${CONFIGS[@]}"; do
    bin="$OUTPUT_DIR/bin/champsim_${cfg}"
    if [ ! -f "$bin" ]; then echo "  [ERROR] Missing binary: $bin"; continue; fi
    for trace in "${TRACES[@]}"; do
        tname=$(basename "$trace" | sed 's/\.\(trace\|champsimtrace\)\.xz//')
        json="$OUTPUT_DIR/json/${cfg}_${tname}.json"
        if $INCREMENTAL && [ -f "$json" ]; then
            skip=$((skip + 1)); continue
        fi
        n=$((n + 1))
        log="$OUTPUT_DIR/logs/${cfg}_${tname}.log"
        while [ "$running" -ge "$N_JOBS" ]; do wait -n 2>/dev/null || true; running=$((running - 1)); done
        printf "  [%3d/%3d] %-10s %s\n" "$n" "$((total - skip))" "$cfg" "$tname"
        "$bin" --hide-heartbeat --warmup-instructions "$WARMUP" \
               --simulation-instructions "$SIM" --json "$json" "$trace" > "$log" 2>&1 &
        running=$((running + 1))
    done
done
echo "  Waiting for $running jobs..."; wait
echo "  Done! $n sims ran ($skip skipped)."
echo "  JSONs: $OUTPUT_DIR/json/"
ls "$OUTPUT_DIR/json/"*.json 2>/dev/null | wc -l
echo "  files"
