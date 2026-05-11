#!/usr/bin/env bash
#
# evals/batch_profile/run.sh — Full profiling pipeline for all benchmarks.
#
# Runs Stage 1-7 for every benchmark in SPEC_BENCHMARKS.
#
# Usage:
#   bash run.sh                              # serial, all benchmarks
#   bash run.sh --parallel                   # parallel benchmarks
#   bash run.sh --parallel --stage3-jobs 4   # parallel + 4 concurrent PIN traces
#   bash run.sh --tmux                       # each benchmark in its own tmux session
#   bash run.sh --benchmarks 400.perlbench,429.mcf  # subset only
#   bash run.sh --stage3-only                # only generate traces (Stage 3)
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$SCRIPT_DIR/../.."
PROFILING_DIR="$TOOLS_DIR/profiling"
SCRIPTS_DIR="$TOOLS_DIR/scripts"

source "$PROFILING_DIR/config.sh"

# ── Args ──────────────────────────────────────────────────────────────────────
MODE="serial"
SELECTED_BENCHMARKS=()
STAGE3_JOBS=1          # how many PIN trace processes in parallel per benchmark
STAGE3_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --parallel)    MODE="parallel"; shift ;;
        --tmux)        MODE="tmux"; shift ;;
        --stage3-jobs) STAGE3_JOBS="$2"; shift 2 ;;
        --stage3-only) STAGE3_ONLY=true; shift ;;
        --benchmarks)  IFS=',' read -ra SELECTED_BENCHMARKS <<< "$2"; shift 2 ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac
done

if [ ${#SELECTED_BENCHMARKS[@]} -eq 0 ]; then
    SELECTED_BENCHMARKS=("${SPEC_BENCHMARKS[@]}")
fi

# ── Setup reports dir ─────────────────────────────────────────────────────────
RUN_ID="batch-$(date '+%Y%m%d-%H%M%S')"
RUN_DIR="$REPORTS_DIR/$RUN_ID"
mkdir -p "$RUN_DIR"
echo "Run ID:       $RUN_ID"        | tee "$RUN_DIR/summary.txt"
echo "Mode:         $MODE"           | tee -a "$RUN_DIR/summary.txt"
echo "Stage3 jobs:  $STAGE3_JOBS"    | tee -a "$RUN_DIR/summary.txt"
echo "Benchmarks:   ${SELECTED_BENCHMARKS[*]}" | tee -a "$RUN_DIR/summary.txt"
echo "" | tee -a "$RUN_DIR/summary.txt"

# ── Stage 3 helper: parallel PIN trace generation ─────────────────────────────
generate_traces() {
    local bench="$1"
    local log="$RUN_DIR/${bench}_stage3.log"
    local SIM_JSON="$DATA_ROOT/$bench/simpoints.json"

    echo "[$(date '+%H:%M:%S')] Stage 3: $bench (parallel, max $STAGE3_JOBS jobs)" | tee -a "$log"

    if [ ! -f "$SIM_JSON" ]; then
        echo "  ERROR: simpoints.json not found. Run Stage 1 first." | tee -a "$log"
        return 1
    fi

    # Parse intervals and weights from simpoints.json
    local intervals_json=$(python3 -c "
import json
data = json.load(open('$SIM_JSON'))
entries = [e for e in data if e['weight'] >= $WEIGHT_THRESHOLD]
print(json.dumps(entries))
" 2>/dev/null)

    if [ -z "$intervals_json" ] || [ "$intervals_json" = "[]" ]; then
        echo "  WARNING: No SimPoints above weight threshold $WEIGHT_THRESHOLD" | tee -a "$log"
        return 0
    fi

    # Locate SPEC binary and run directory
    local exe_name=$(grep "exename" "$SPEC_ROOT/benchspec/CPU2006/$bench/Spec/object.pm" 2>/dev/null | grep -oP "'\K[^']*" | head -1)
    [ -z "$exe_name" ] && exe_name=$(echo "$bench" | sed 's/^[0-9]*\.//')

    local spec_build_dir=$(find "$SPEC_ROOT/benchspec/CPU2006/$bench/build" -maxdepth 2 -type d -name "build_base_*" 2>/dev/null | head -1)
    local spec_run_dir=$(find "$SPEC_ROOT/benchspec/CPU2006/$bench/run" -maxdepth 2 -type d -name "run_base_train_*" 2>/dev/null | head -1)

    if [ -z "$spec_run_dir" ]; then
        echo "  ERROR: No train run directory. Run: runspec --action=setup --size=train $bench" | tee -a "$log"
        return 1
    fi

    local BINARY_PATH="${spec_build_dir}/${exe_name}"
    if [ ! -f "$BINARY_PATH" ]; then
        BINARY_PATH="$spec_run_dir/${exe_name}_base.*"
        BINARY_PATH=$(ls $BINARY_PATH 2>/dev/null | head -1)
    fi

    if [ -z "$BINARY_PATH" ] || [ ! -f "$BINARY_PATH" ]; then
        echo "  ERROR: Binary not found at ${spec_build_dir}/${exe_name}" | tee -a "$log"
        return 1
    fi

    local TRACES_DIR="$DATA_ROOT/$bench/traces"
    mkdir -p "$TRACES_DIR"

    # Find a command from speccmds.cmd (take the first one — scrabbl or similar)
    local spec_cmd=$(grep -v '^#' "$spec_run_dir/speccmds.cmd" 2>/dev/null | head -1 | sed 's/.*-- //' || echo "")
    if [ -z "$spec_cmd" ]; then
        spec_cmd="./${exe_name}"
    fi

    # Launch PIN processes for each interval, respect STAGE3_JOBS limit
    local running=0
    local pids=()
    local trace_files=()

    local entries_count=$(python3 -c "print(len($intervals_json))" 2>/dev/null)

    for i in $(seq 0 $((entries_count - 1))); do
        local sid=$(python3 -c "print($intervals_json[$i]['interval_id'])" 2>/dev/null)
        local weight=$(python3 -c "print($intervals_json[$i]['weight'])" 2>/dev/null)
        local start=$(python3 -c "print(int($intervals_json[$i]['interval_id']) * $INTERVAL_SIZE)" 2>/dev/null)

        local trace_out="$TRACES_DIR/${bench}-${sid}B.champsimtrace"
        if [ -f "${trace_out}.xz" ]; then
            echo "  [skip] interval $sid (weight=$weight) — trace already exists" | tee -a "$log"
            trace_files+=("${trace_out}.xz")
            continue
        fi

        # Wait if we have too many jobs running
        while [ $running -ge $STAGE3_JOBS ]; do
            for j in "${!pids[@]}"; do
                if ! kill -0 "${pids[$j]}" 2>/dev/null; then
                    wait "${pids[$j]}" 2>/dev/null || true
                    running=$((running - 1))
                fi
            done
            sleep 2
        done

        echo "  [launch] interval $sid (weight=$weight, start=$start) — PID: " | tr -d '\n' | tee -a "$log"

        (
            cd "$spec_run_dir"
            "$PIN_ROOT/pin" -t "$PIN_TRACER" \
                -o "$trace_out" \
                -s "$start" \
                -t "$INTERVAL_SIZE" \
                -- $spec_cmd \
                >> "$log" 2>&1

            if [ -f "$trace_out" ]; then
                xz -T0 "$trace_out" >> "$log" 2>&1
                echo "    [done] interval $sid → ${trace_out}.xz" >> "$log"
            fi
        ) &

        local pid=$!
        pids+=($pid)
        trace_files+=("${trace_out}.xz")
        running=$((running + 1))
        echo "$pid" | tee -a "$log"
    done

    # Wait for all remaining processes
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    # Verify all traces exist
    local ok=0 missing=0
    for tf in "${trace_files[@]}"; do
        if [ -f "$tf" ]; then
            ok=$((ok + 1))
        else
            missing=$((missing + 1))
        fi
    done

    echo "  Stage 3 complete: $ok traces generated, $missing missing" | tee -a "$log"
    return $(( missing > 0 ? 1 : 0 ))
}

# ── Benchmark runner ──────────────────────────────────────────────────────────
run_benchmark() {
    local bench="$1"
    local log="$RUN_DIR/${bench}.log"

    echo "[$(date '+%H:%M:%S')] Starting $bench ..." | tee -a "$log"

    # Stage 1-2: SimPoints + disasm
    bash "$PROFILING_DIR/run_pipeline.sh" "$bench" --stage 1 >> "$log" 2>&1 || true
    bash "$PROFILING_DIR/run_pipeline.sh" "$bench" --stage 2 >> "$log" 2>&1 || {
        echo "  FAIL: Stage 2 (disasm) for $bench" | tee -a "$RUN_DIR/failures.txt"
        return 1
    }
    echo "  [✓] Stage 1-2 done" >> "$log"

    # Stage 3: Parallel trace generation
    generate_traces "$bench" || {
        echo "  FAIL: Stage 3 (traces) for $bench" | tee -a "$RUN_DIR/failures.txt"
        return 1
    }
    echo "  [✓] Stage 3 done" >> "$log"

    if $STAGE3_ONLY; then
        echo "[$(date '+%H:%M:%S')] $bench (Stage 3 only) complete" | tee -a "$RUN_DIR/completed.txt"
        return 0
    fi

    # Stage 4: Profiling with each prefetcher
    bash "$PROFILING_DIR/run_pipeline.sh" "$bench" --stage 4 >> "$log" 2>&1 || {
        echo "  FAIL: Stage 4 (profiling) for $bench" | tee -a "$RUN_DIR/failures.txt"
        return 1
    }
    echo "  [✓] Stage 4 done" >> "$log"

    # Stage 5-6-7
    bash "$PROFILING_DIR/run_pipeline.sh" "$bench" --stage 5 >> "$log" 2>&1 || true
    bash "$PROFILING_DIR/run_pipeline.sh" "$bench" --stage 6 >> "$log" 2>&1 || true
    bash "$PROFILING_DIR/run_pipeline.sh" "$bench" --stage 7 >> "$log" 2>&1 || true
    echo "  [✓] Stage 5-6-7 done" >> "$log"

    echo "[$(date '+%H:%M:%S')] $bench complete" | tee -a "$RUN_DIR/completed.txt"
}

# ── Execute ───────────────────────────────────────────────────────────────────
case "$MODE" in
    serial)
        for bench in "${SELECTED_BENCHMARKS[@]}"; do
            run_benchmark "$bench"
        done
        ;;
    parallel)
        # Run benchmarks in parallel, but each benchmark's Stage 3 may also
        # have parallel PIN processes. Watch total load.
        declare -A PIDS=()
        for bench in "${SELECTED_BENCHMARKS[@]}"; do
            run_benchmark "$bench" &
            PIDS[$!]="$bench"
        done
        for pid in "${!PIDS[@]}"; do
            wait "$pid" && echo "  ${PIDS[$pid]}: OK" || echo "  ${PIDS[$pid]}: FAIL"
        done
        ;;
    tmux)
        for bench in "${SELECTED_BENCHMARKS[@]}"; do
            local session="profiling-${bench}"
            local cmd="bash $0 --benchmarks $bench --stage3-jobs $STAGE3_JOBS"
            $STAGE3_ONLY && cmd="$cmd --stage3-only"
            bash "$SCRIPTS_DIR/launch_in_tmux.sh" "$session" $cmd
        done
        echo "All benchmarks launched in tmux sessions."
        echo "  tmux list-sessions"
        echo "  tmux attach -t profiling-400.perlbench"
        ;;
esac

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "────────────────────────────────────"
echo "  Run ID:       $RUN_ID"
echo "  Completed:    $(wc -l < "$RUN_DIR/completed.txt" 2>/dev/null || echo 0) / ${#SELECTED_BENCHMARKS[@]}"
echo "  Failures:     $(wc -l < "$RUN_DIR/failures.txt" 2>/dev/null || echo 0)"
echo "  Reports:      $RUN_DIR"
echo "────────────────────────────────────"
