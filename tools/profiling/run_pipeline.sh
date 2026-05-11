#!/usr/bin/env bash
#
# run_pipeline.sh — Automated Profiling Pipeline
#
# Orchestrates the full data collection workflow:
#   Stage 0: Environment setup (PIN + ChampSim)
#            → delegates to setup.sh (general)
#            For benchmark compilation, see tools/benchmarks/<suite>/setup.sh
#   Stage 1: Parse SimPoints
#   Stage 2: Locate binary + disassemble (objdump)
#   Stage 3: Generate ChampSim traces via PIN (per SimPoint interval)
#   Stage 4: Run ChampSim profiling (per trace × per prefetcher/degree)
#   Stage 5: Extract assembly context for Load PCs
#   Stage 6: Aggregate ground truth labels (cross-prefetcher AMAT comparison)
#   Stage 7: Build instruction-tuning dataset (context + labels)
#
# Usage:
#   ./run_pipeline.sh 400.perlbench              # run all stages
#   ./run_pipeline.sh 400.perlbench --stage 1    # run specific stage
#   ./run_pipeline.sh 400.perlbench --setup      # run setup first, then all stages
#   ./run_pipeline.sh --setup-only               # only run setup (no benchmark needed)
#   ./run_pipeline.sh 400.perlbench --dry-run    # print commands without executing
#

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

BENCHMARK="${1:-}"
shift 2>/dev/null || true

STAGE="all"
DRY_RUN=false
DO_SETUP=false
SETUP_ONLY=false
JOBS="${JOBS:-4}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stage) STAGE="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --setup) DO_SETUP=true; shift ;;
        --setup-only) SETUP_ONLY=true; shift ;;
        --jobs) JOBS="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if $SETUP_ONLY; then
    bash "$SCRIPT_DIR/setup.sh"
    exit 0
fi

if [ -z "$BENCHMARK" ]; then
    echo "Usage: $0 <benchmark> [--stage N] [--setup] [--setup-only] [--dry-run] [--jobs N]"
    echo "Example: $0 400.perlbench"
    echo "         $0 400.perlbench --setup     # run setup then pipeline"
    echo "         $0 --setup-only               # only setup environment"
    exit 1
fi

# ─── Derived paths ───────────────────────────────────────────────────────────
BENCH_DIR="$DATA_ROOT/$BENCHMARK"
SIMPOINTS_JSON="$BENCH_DIR/simpoints.json"
BINARY_PATH="${BINARY_PATH:-}"         # set in stage 2, or pre-set via env
DISASM_INDEX="$BENCH_DIR/disasm_index.json"
TRACES_DIR="$BENCH_DIR/traces"
PROFILING_DIR="$BENCH_DIR/profiling"
GROUND_TRUTH="$BENCH_DIR/ground_truth.jsonl"
ASSEMBLY_CTX="$BENCH_DIR/assembly_context.jsonl"
TUNING_DATASET="$BENCH_DIR/tuning_dataset.jsonl"

# ─── Helpers ─────────────────────────────────────────────────────────────────
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
run()  {
    if $DRY_RUN; then
        echo "[DRY-RUN] $*"
    else
        log "Running: $*"
        eval "$@"
    fi
}
ensure_dir() { run mkdir -p "$1"; }

should_run() {
    # $1 = target stage number
    [ "$STAGE" = "all" ] || [ "$STAGE" = "$1" ]
}

# ─────────────────────────────────────────────────────────────────────────────
# Stage 1: Parse SimPoints
# ─────────────────────────────────────────────────────────────────────────────
stage_1() {
    should_run 1 || return 0
    log "=== STAGE 1: Parse SimPoints for $BENCHMARK ==="

    if [ ! -f "$SIMPOINTS_TARBALL" ]; then
        log "ERROR: SimPoints tarball not found at $SIMPOINTS_TARBALL"
        log "Download from DPC-3 or set SIMPOINTS_TARBALL in config.sh"
        exit 1
    fi

    ensure_dir "$BENCH_DIR"
    run python3 "$SCRIPT_DIR/parse_simpoints.py" \
        --tarball "$SIMPOINTS_TARBALL" \
        --benchmark "$BENCHMARK" \
        --output-dir "$BENCH_DIR"

    log "SimPoints ready: $SIMPOINTS_JSON"
}

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2: Verify SPEC binary + objdump disassembly
# ─────────────────────────────────────────────────────────────────────────────
stage_2() {
    should_run 2 || return 0
    log "=== STAGE 2: Disassembly for $BENCHMARK ==="

    # Find the SPEC binary — look in build/ first (--action=build), fallback to run/
    local exe_name=$(grep "exename" "$SPEC_ROOT/benchspec/CPU2006/$BENCHMARK/Spec/object.pm" 2>/dev/null | grep -oP "'\K[^']*" | head -1)
    if [ -z "$exe_name" ]; then
        exe_name=$(echo "$BENCHMARK" | sed 's/^[0-9]*\.//')
    fi

    local spec_build_dir=$(find "$SPEC_ROOT/benchspec/CPU2006/$BENCHMARK/build" \
        -maxdepth 2 -type d -name "build_base_*" 2>/dev/null | head -1)
    local spec_run_dir=$(find "$SPEC_ROOT/benchspec/CPU2006/$BENCHMARK/run" \
        -maxdepth 2 -type d -name "run_base_*" 2>/dev/null | head -1)

    if [ -n "$spec_build_dir" ]; then
        BINARY_PATH="$spec_build_dir/$exe_name"
    elif [ -n "$spec_run_dir" ]; then
        BINARY_PATH="$spec_run_dir/$exe_name"
    else
        log "ERROR: No compiled binary found for $BENCHMARK."
        log "  Please run: cd $SPEC_ROOT && . ./shrc && runspec --action=build --config=$SPEC_CONFIG --tune=base $BENCHMARK"
        exit 1
    fi

    if [ ! -f "$BINARY_PATH" ]; then
        BINARY_PATH=$(find "${spec_build_dir:-$spec_run_dir}" -type f -executable -not -name "*.h" -not -name "*.c" -name "$exe_name*" 2>/dev/null | head -1)
    fi

    if [ ! -f "$BINARY_PATH" ]; then
        log "ERROR: Binary '$exe_name' not found in ${spec_build_dir:-$spec_run_dir}"
        exit 1
    fi

    log "SPEC binary: $BINARY_PATH"

    # Run objdump
    run python3 "$SCRIPT_DIR/parse_disassembly.py" \
        --binary "$BINARY_PATH" \
        --output "$DISASM_INDEX"

    log "Disassembly index: $DISASM_INDEX"
}

# ─────────────────────────────────────────────────────────────────────────────
# Stage 3: Generate traces via PIN (one per SimPoint above threshold)
#           Runs multiple traces in parallel (concurrency = JOBS).
# ─────────────────────────────────────────────────────────────────────────────
stage_3() {
    should_run 3 || return 0
    log "=== STAGE 3: Generate traces for $BENCHMARK (parallel, jobs=$JOBS) ==="

    if [ ! -f "$PIN_TRACER" ]; then
        log "ERROR: PIN tracer not found at $PIN_TRACER"
        log "  Build it: cd ${CHAMPSIM_ROOT}/tracer/pin && make"
        log "  (Requires Intel PIN installed at PIN_ROOT=$PIN_ROOT)"
        exit 1
    fi

    if [ -z "${BINARY_PATH:-}" ]; then
        log "ERROR: Run stage 2 first to locate the binary"
        exit 1
    fi

    # Read SimPoints JSON into arrays
    local -a sids=() starts=() weights=()
    while IFS=',' read -r sid start weight; do
        sids+=("$sid")
        starts+=("$start")
        weights+=("$weight")
    done < <(python3 -c "
import json
data = json.load(open('$SIMPOINTS_JSON'))
for entry in data:
    if entry['weight'] >= $WEIGHT_THRESHOLD:
        sid = entry['interval_id']
        start = sid * $INTERVAL_SIZE
        print(f'{sid},{start},{entry[\"weight\"]}')
" 2>/dev/null)

    if [ ${#sids[@]} -eq 0 ]; then
        log "ERROR: No SimPoints found above weight threshold $WEIGHT_THRESHOLD"
        exit 1
    fi

    log "  Found ${#sids[@]} SimPoint intervals to trace"

    ensure_dir "$TRACES_DIR"

    # Find SPEC run directory (where speccmds.cmd and input files live)
    local spec_run_dir=$(find "$SPEC_ROOT/benchspec/CPU2006/$BENCHMARK/run" \
        -maxdepth 2 -name "run_base_train_*" -type d 2>/dev/null | head -1)
    [ -z "$spec_run_dir" ] && spec_run_dir=$(dirname "$BINARY_PATH")

    # Read SPEC command-line args from speccmds.cmd
    # Format: -C <rundir>  then  -o <out> -e <err> <binary> <args...>
    # We skip -C lines and strip -o/-e to get <binary> <args>
    local spec_work_dir="$spec_run_dir"
    local spec_args=""
    local spec_cmd_file="$spec_run_dir/speccmds.cmd"
    if [ -f "$spec_cmd_file" ]; then
        while IFS= read -r line; do
            [[ "$line" =~ ^# ]] && continue
            [[ -z "$line" ]] && continue
            if [[ "$line" =~ ^-C ]]; then
                spec_work_dir=$(echo "$line" | sed 's/^-C //')
                continue
            fi
            # Command line: strip -o <file>, -e <file>, and any binary reference (words containing _base.)
            # We use BINARY_PATH as the executable; keep only the real program arguments
            spec_args=$(echo "$line" | sed 's/-o [^ ]* //' | sed 's/-e [^ ]* //' | sed 's/^ *//' | sed -E 's/ ?[^ ]*_base\.[^ ]*//g' | sed 's/  */ /g' | sed 's/^ *//;s/ *$//')
            break
        done < "$spec_cmd_file"
        log "  SPEC work dir: $spec_work_dir"
        log "  SPEC args: $spec_args"
    fi

    # Parse specinvoke -i <file> (stdin redirect) if present
    local stdin_file=""
    if [[ "$spec_args" =~ -i[[:space:]]+([^[:space:]]+) ]]; then
        stdin_file="${BASH_REMATCH[1]}"
        spec_args=$(echo "$spec_args" | sed -E 's/-i [^ ]+ //' | sed 's/^ *//;s/ *$//')
        log "  SPEC stdin redirect: $stdin_file"
    fi

    # ── Parallel execution with concurrency control ─────────────────────────
    local running=0
    local failfile
    failfile=$(mktemp)

    for i in "${!sids[@]}"; do
        sid="${sids[$i]}"
        start="${starts[$i]}"
        weight="${weights[$i]}"
        trace_out="$TRACES_DIR/${BENCHMARK}-${sid}B.champsimtrace"

        # Skip if already completed
        if [ -f "${trace_out}.xz" ]; then
            log "  [SKIP] Interval $sid already traced → ${trace_out}.xz"
            continue
        fi

        # Wait if at concurrency limit (drain one completed job)
        while [ "$running" -ge "$JOBS" ]; do
            wait -n 2>/dev/null || true
            ((running--)) || true
        done

        log "  [LAUNCH] SimPoint $sid (weight=$weight, start_instr=$start, slot=$((running+1))/$JOBS)"

        (
            pin_cmd="${PIN_ROOT}/pin -t ${PIN_TRACER} -o ${trace_out} -s ${start} -t ${INTERVAL_SIZE} -- ${BINARY_PATH} ${spec_args}"
            if $DRY_RUN; then
                echo "[DRY-RUN] cd ${spec_work_dir} && $pin_cmd"
                echo "[DRY-RUN] xz -T0 ${trace_out}"
                exit 0
            fi

            echo "[$(date '+%H:%M:%S')] [PIN:$sid] cd ${spec_work_dir}"
            cd "$spec_work_dir" || { echo "[$(date '+%H:%M:%S')] [PIN:$sid] FAILED: cannot cd to $spec_work_dir"; echo "1" >> "$failfile"; exit 1; }

            echo "[$(date '+%H:%M:%S')] [PIN:$sid] Starting trace (skip ${start} instrs, record ${INTERVAL_SIZE})..."
            if [ -n "${stdin_file:-}" ] && [ -f "$stdin_file" ]; then
                eval "$pin_cmd" < "$stdin_file"
            elif [ -n "${stdin_file:-}" ]; then
                eval "$pin_cmd" < "${spec_work_dir}/${stdin_file}"
            else
                eval "$pin_cmd"
            fi
            local pin_ec=$?
            if [ "$pin_ec" -eq 0 ]; then
                echo "[$(date '+%H:%M:%S')] [PIN:$sid] Trace done, compressing..."
                if [ -f "$trace_out" ]; then
                    xz -T0 "$trace_out"
                    echo "[$(date '+%H:%M:%S')] [PIN:$sid] Compressed → ${trace_out}.xz"
                fi
                exit 0
            else
                echo "[$(date '+%H:%M:%S')] [PIN:$sid] FAILED (exit code $pin_ec)"
                echo "1" >> "$failfile"
                exit 1
            fi
        ) &
        ((running++)) || true
    done

    # Wait for all remaining background jobs
    wait

    if [ -s "$failfile" ]; then
        local failed_count
        failed_count=$(wc -l < "$failfile")
        rm -f "$failfile"
        log "ERROR: $failed_count trace job(s) failed"
        exit 1
    fi
    rm -f "$failfile"

    log "All traces generated in $TRACES_DIR"
}

# ─────────────────────────────────────────────────────────────────────────────
# Stage 4: Run ChampSim profiling (per trace × per prefetcher/degree)
# ─────────────────────────────────────────────────────────────────────────────
stage_4() {
    should_run 4 || return 0
    log "=== STAGE 4: Profiling for $BENCHMARK ==="

    if [ ! -f "$CHAMPSIM_BIN" ]; then
        log "ERROR: ChampSim binary not found at $CHAMPSIM_BIN"
        log "  Build it: cd $CHAMPSIM_ROOT && ./config.sh champsim_config_hint_profile.json && make"
        exit 1
    fi

    ensure_dir "$PROFILING_DIR"

    # Get traces
    shopt -s nullglob
    local traces=("$TRACES_DIR"/*.champsimtrace.xz)
    shopt -u nullglob

    if [ ${#traces[@]} -eq 0 ]; then
        log "ERROR: No traces found in $TRACES_DIR"
        exit 1
    fi

    for trace in "${traces[@]}"; do
        local trace_name=$(basename "$trace" .champsimtrace.xz)

        for policy_spec in "${PREFETCH_POLICIES[@]}"; do
            IFS=':' read -r pref_name degrees_str <<< "$policy_spec"
            IFS=',' read -ra degrees <<< "$degrees_str"

            for degree in "${degrees[@]}"; do
                local profile_out="$PROFILING_DIR/${trace_name}__${pref_name}__${degree}.json"

                if [ -f "$profile_out" ]; then
                    log "  Profiling output already exists: $profile_out"
                    continue
                fi

                log "  Profiling: trace=$trace_name prefetcher=$pref_name degree=$degree"

                # Run ChampSim with HINT_PROFILING, capturing stdout (JSON lines)
                # We use a default hint file (all zeros) since profiling mode
                # records per-PC stats regardless of hint content
                run "${CHAMPSIM_BIN} --warmup-instructions 10000000 \
                      --simulation-instructions 100000000 \
                      ${trace} > ${profile_out} 2>${PROFILING_DIR}/${trace_name}__${pref_name}__${degree}.log"

                log "    Output: $profile_out ($(wc -l < $profile_out) PCs)"
            done
        done
    done

    log "Profiling complete. Results in $PROFILING_DIR"
}

# ─────────────────────────────────────────────────────────────────────────────
# Stage 5: Assembly context extraction
# ─────────────────────────────────────────────────────────────────────────────
stage_5() {
    should_run 5 || return 0
    log "=== STAGE 5: Assembly context for $BENCHMARK ==="

    if [ ! -f "$DISASM_INDEX" ]; then
        log "ERROR: Disassembly index not found. Run stage 2 first."
        exit 1
    fi

    # Extract Load PCs from the first trace (any trace works; PCs are same per binary)
    shopt -s nullglob
    local traces=("$TRACES_DIR"/*.champsimtrace.xz)
    shopt -u nullglob

    if [ ${#traces[@]} -eq 0 ]; then
        log "ERROR: No traces found. Run stage 3 first."
        exit 1
    fi

    local load_pcs_json="$BENCH_DIR/load_pcs.json"
    run python3 "$SCRIPT_DIR/trace_reader.py" \
        --trace "${traces[0]}" \
        --output "$load_pcs_json"

    run python3 "$SCRIPT_DIR/extract_assembly_context.py" \
        --index "$DISASM_INDEX" \
        --load-pcs "$load_pcs_json" \
        --before "$CTX_BEFORE" \
        --after "$CTX_AFTER" \
        --output "$ASSEMBLY_CTX"

    log "Assembly context: $ASSEMBLY_CTX"
}

# ─────────────────────────────────────────────────────────────────────────────
# Stage 6: Ground truth aggregation
# ─────────────────────────────────────────────────────────────────────────────
stage_6() {
    should_run 6 || return 0
    log "=== STAGE 6: Ground truth aggregation for $BENCHMARK ==="

    run python3 "$SCRIPT_DIR/aggregate_ground_truth.py" \
        --profiling-dir "$PROFILING_DIR" \
        --output "$GROUND_TRUTH"

    log "Ground truth: $GROUND_TRUTH"
}

# ─────────────────────────────────────────────────────────────────────────────
# Stage 7: Build training dataset
# ─────────────────────────────────────────────────────────────────────────────
stage_7() {
    should_run 7 || return 0
    log "=== STAGE 7: Training dataset for $BENCHMARK ==="

    if [ ! -f "$ASSEMBLY_CTX" ]; then
        log "ERROR: Assembly context not found. Run stage 5 first."
        exit 1
    fi
    if [ ! -f "$GROUND_TRUTH" ]; then
        log "ERROR: Ground truth not found. Run stage 6 first."
        exit 1
    fi

    run python3 "$SCRIPT_DIR/build_tuning_dataset.py" \
        --context "$ASSEMBLY_CTX" \
        --labels "$GROUND_TRUTH" \
        --output "$TUNING_DATASET"

    log "Training dataset: $TUNING_DATASET"
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

if $DO_SETUP; then
    log "Running environment setup first..."
    bash "$SCRIPT_DIR/setup.sh"
fi

log "Pipeline start: benchmark=$BENCHMARK stage=$STAGE"
log "Output directory: $BENCH_DIR"

ensure_dir "$DATA_ROOT"
ensure_dir "$BENCH_DIR"

stage_1
stage_2
stage_3
stage_4
stage_5
stage_6
stage_7

log "Pipeline complete for $BENCHMARK"
log ""
log "Output files:"
[ -f "$SIMPOINTS_JSON" ]  && echo "  SimPoints:     $SIMPOINTS_JSON"
[ -f "$DISASM_INDEX" ]    && echo "  Disassembly:   $DISASM_INDEX"
[ -d "$TRACES_DIR" ]      && echo "  Traces:        $TRACES_DIR"
[ -d "$PROFILING_DIR" ]   && echo "  Profiling:     $PROFILING_DIR"
[ -f "$ASSEMBLY_CTX" ]    && echo "  Asm Context:   $ASSEMBLY_CTX"
[ -f "$GROUND_TRUTH" ]    && echo "  Ground Truth:  $GROUND_TRUTH"
[ -f "$TUNING_DATASET" ]  && echo "  Tuning Dataset: $TUNING_DATASET"
