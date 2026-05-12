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
#   Uses per-prefetcher binaries: bin/champsim_<pref>_d<deg>
#   Auto-detects available binaries — skip any that haven't been compiled yet.
# ─────────────────────────────────────────────────────────────────────────────
stage_4() {
    should_run 4 || return 0
    log "=== STAGE 4: Profiling for $BENCHMARK ==="

    # Prefetcher name mapping: paper name → ChampSim internal binary name
    # Only paper-listed prefetchers (no, next_line, stride, stream, ampm, ...).
    # The binary is bin/champsim_<internal>_d<degree>.
    declare -A PREFETCH_BIN_MAP=(
        ["no"]="no"
        ["next_line"]="next_line"
        ["stride"]="ip_stride"          # ChampSim's stride implementation
        ["ampm"]="va_ampm_lite"         # ChampSim's AMPM implementation
        # ["stream"]="stream"          # not yet compiled
    )

    # Discover available per-prefetcher profiling binaries
    declare -A pref_binaries=()  # key: "paper_name:degree" → value: binary path
    for paper_name in "${!PREFETCH_BIN_MAP[@]}"; do
        local bin_name="${PREFETCH_BIN_MAP[$paper_name]}"
        shopt -s nullglob
        for bin in "$CHAMPSIM_ROOT/bin/champsim_${bin_name}_d"*; do
            local bname=$(basename "$bin")
            if [[ "$bname" =~ ^champsim_${bin_name}_d([0-9]+)$ ]]; then
                local pdeg="${BASH_REMATCH[1]}"
                pref_binaries["${paper_name}:${pdeg}"]="$bin"
            fi
        done
        shopt -u nullglob
    done

    if [ ${#pref_binaries[@]} -eq 0 ]; then
        log "ERROR: No per-prefetcher binaries found in $CHAMPSIM_ROOT/bin/"
        log "  Build them: cd $CHAMPSIM_ROOT && for cfg in tools/profiling/configs/champsim_*_d*.json; do ./config.sh \"\$cfg\" && make -j\$(nproc); done"
        exit 1
    fi

    log "  Found ${#pref_binaries[@]} prefetcher binaries:"
    for key in "${!pref_binaries[@]}"; do
        log "    $key → ${pref_binaries[$key]}"
    done

    ensure_dir "$PROFILING_DIR"

    # Get traces
    shopt -s nullglob
    local traces=("$TRACES_DIR"/*.champsimtrace.xz)
    shopt -u nullglob

    if [ ${#traces[@]} -eq 0 ]; then
        log "ERROR: No traces found in $TRACES_DIR"
        exit 1
    fi

    # ── Build job list ─────────────────────────────────────────────────────
    local -a jobs_trace=() jobs_pref=() jobs_deg=() jobs_bin=() jobs_out=()
    for trace in "${traces[@]}"; do
        local trace_name=$(basename "$trace" .champsimtrace.xz)
        for pf_key in "${!pref_binaries[@]}"; do
            IFS=':' read -r pref_name degree <<< "$pf_key"
            local profile_out="$PROFILING_DIR/${trace_name}__${pref_name}__${degree}.json"
            if [ -f "$profile_out" ]; then
                log "  [SKIP] Already exists: ${trace_name}__${pref_name}__${degree}.json"
                continue
            fi
            jobs_trace+=("$trace")
            jobs_pref+=("$pref_name")
            jobs_deg+=("$degree")
            jobs_bin+=("${pref_binaries[$pf_key]}")
            jobs_out+=("$profile_out")
        done
    done

    local total_jobs=${#jobs_trace[@]}
    if [ "$total_jobs" -eq 0 ]; then
        log "All profiling outputs already exist. Nothing to do."
        return 0
    fi

    log "  $total_jobs profiling jobs to run (concurrency=$JOBS)"

    # ── Parallel execution with concurrency control ────────────────────────
    local running=0 job_idx=0
    local failfile
    failfile=$(mktemp)

    while [ "$job_idx" -lt "$total_jobs" ] || [ "$running" -gt 0 ]; do
        # Launch new jobs while under concurrency limit
        while [ "$job_idx" -lt "$total_jobs" ] && [ "$running" -lt "$JOBS" ]; do
            local t="${jobs_trace[$job_idx]}"
            local pn="${jobs_pref[$job_idx]}"
            local pd="${jobs_deg[$job_idx]}"
            local pb="${jobs_bin[$job_idx]}"
            local po="${jobs_out[$job_idx]}"
            local tn=$(basename "$t" .champsimtrace.xz)

            log "  [LAUNCH] trace=$tn pref=$pn degree=$pd (slot=$((running+1))/$JOBS)"

            (
                if $DRY_RUN; then
                    echo "[DRY-RUN] ${pb} --warmup-instructions ${PROFILE_WARMUP:-1000000} --simulation-instructions ${PROFILE_SIM:-10000000} ${t} | grep '^{' > ${po}"
                    exit 0
                fi
                "${pb}" --warmup-instructions ${PROFILE_WARMUP:-1000000} \
                    --simulation-instructions ${PROFILE_SIM:-10000000} \
                    "${t}" 2>"${po}.log" \
                    | grep "^{" > "${po}"
                local ec=$?
                if [ "$ec" -eq 0 ] && [ -s "$po" ]; then
                    echo "[$(date '+%H:%M:%S')] [OK] ${tn}__${pn}__${pd}: $(wc -l < "$po") PCs"
                    exit 0
                else
                    echo "[$(date '+%H:%M:%S')] [FAIL] ${tn}__${pn}__${pd} (exit=$ec)"
                    echo "1" >> "$failfile"
                    exit 1
                fi
            ) &
            ((running++)) || true
            ((job_idx++)) || true
        done

        # Wait for at least one job to finish before checking for more work
        if [ "$running" -gt 0 ]; then
            wait -n 2>/dev/null || true
            ((running--)) || true
        fi
    done

    # Drain any stragglers
    wait

    if [ -s "$failfile" ]; then
        local failed_count
        failed_count=$(wc -l < "$failfile")
        rm -f "$failfile"
        log "WARNING: $failed_count profiling job(s) failed — check .log files"
    fi
    rm -f "$failfile"

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
