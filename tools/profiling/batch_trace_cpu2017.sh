#!/usr/bin/env bash
#
# batch_trace_cpu2017.sh — CPU2017-specific PIN trace generation
# Adapted from the profiling pipeline for CPU2017.
#
# Usage:
#   ./batch_trace_cpu2017.sh                        # trace all available benchmarks
#   ./batch_trace_cpu2017.sh --bench 500.perlbench_r # single benchmark
#   ./batch_trace_cpu2017.sh --jobs 2                # 2 parallel traces per benchmark
#   ./batch_trace_cpu2017.sh --dry-run               # preview only
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh" 2>/dev/null || true

# ─── Configuration ───────────────────────────────────────────────────────────
CPU2017_ROOT="${CPU2017_ROOT:-$HOME/cpu2017}"
DATA_ROOT="${DATA_ROOT:-$SCRIPT_DIR/data}"
PIN_ROOT="${PIN_ROOT:-$HOME/pin-3.22-98547-g7a303a835-gcc-linux}"
PIN_TRACER="${PIN_TRACER:-$HOME/coordinate_proj/ChampSim/tracer/pin/obj-intel64/champsim_tracer.so}"
INTERVAL_SIZE="${INTERVAL_SIZE:-100000000}"
WEIGHT_THRESHOLD="${WEIGHT_THRESHOLD:-0.01}"

SINGLE_BENCH=""
DRY_RUN=false
JOBS="${JOBS:-2}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bench) SINGLE_BENCH="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --jobs) JOBS="$2"; shift 2 ;;
        *) SINGLE_BENCH="$1"; shift ;;
    esac
done

log()  { echo "[$(date '+%H:%M:%S')] $*"; }

# ─── Verify prerequisites ────────────────────────────────────────────────────
if [ ! -x "$PIN_ROOT/pin" ]; then
    log "ERROR: PIN not found at $PIN_ROOT/pin"
    exit 1
fi
if [ ! -f "$PIN_TRACER" ]; then
    log "ERROR: Tracer not found at $PIN_TRACER"
    exit 1
fi

# ─── Discover benchmarks ─────────────────────────────────────────────────────
declare -A BENCH_EXE BENCH_BINARY BENCH_RUN_DIR

discover_benchmarks() {
    for bench_dir in "$CPU2017_ROOT"/benchspec/CPU/*/; do
        local bname=$(basename "$bench_dir")
        [[ "$bname" =~ specrand ]] && continue

        # Skip if no disassembly (wasn't built)
        [ ! -f "$DATA_ROOT/$bname/disasm_index.json" ] && continue

        # Find build directory and binary
        local exe=$(grep "exename" "$bench_dir/Spec/object.pm" 2>/dev/null | grep -oP "'\K[^']*" | head -1)
        [ -z "$exe" ] && continue

        local build_dir=$(find "$bench_dir/build" -maxdepth 2 -type d -name "build_base_*" 2>/dev/null | head -1)
        [ -z "$build_dir" ] && continue

        local binary="$build_dir/$exe"
        [ ! -f "$binary" ] && binary=$(find "$build_dir" -type f -executable -name "$exe*" 2>/dev/null | head -1)
        [ ! -f "$binary" ] && continue

        # Find run directory
        local run_dir=$(find "$bench_dir/run" -maxdepth 2 -type d -name "run_base_train_*" 2>/dev/null | head -1)

        BENCH_EXE["$bname"]="$exe"
        BENCH_BINARY["$bname"]="$binary"
        BENCH_RUN_DIR["$bname"]="${run_dir:-}"
    done
}

discover_benchmarks

if [ ${#BENCH_EXE[@]} -eq 0 ]; then
    log "ERROR: No benchmarks found with valid build + disassembly"
    exit 1
fi

log "Discovered ${#BENCH_EXE[@]} benchmarks ready for tracing"

# ─── Ensure simpoints exist ──────────────────────────────────────────────────
ensure_simpoints() {
    local bname="$1"
    local simpoints_file="$DATA_ROOT/$bname/simpoints.json"

    if [ -f "$simpoints_file" ]; then
        return 0
    fi

    # For CPU2017, we use a simple default: skip 0, record 100M instructions.
    # The SimPoints approach used for CPU2006 (DPC-3) is not available.
    # Users can provide custom simpoints by creating this file manually.
    mkdir -p "$(dirname "$simpoints_file")"
    cat > "$simpoints_file" << 'EOF'
[{"interval_id": 0, "weight": 1.0}]
EOF
    log "  Created default simpoints for $bname (interval 0, 100M instrs from start)"
}

# ─── Parse speccmds.cmd for CPU2017 ──────────────────────────────────────────
parse_speccmds() {
    local cmd_file="$1"
    local work_dir=""
    local args=""

    if [ ! -f "$cmd_file" ]; then
        echo ""
        return
    fi

    # CPU2017 speccmds.cmd format:
    #   Lines 1-N: environment variables (-E KEY VAL)
    #   Line after env: -r, -N, -C <workdir>
    #   Then: -o <out> -e <err> <binary_path> <program_args> > <out> 2>> <err>

    while IFS= read -r line; do
        # Skip environment lines
        [[ "$line" =~ ^-E ]] && continue
        [[ "$line" =~ ^-r$ ]] && continue
        [[ "$line" =~ ^-N ]] && continue

        # Extract work directory
        if [[ "$line" =~ ^-C[[:space:]]+(.+)$ ]]; then
            work_dir="${BASH_REMATCH[1]}"
            continue
        fi

        # Parse command line: strip -o/-e, binary path, and shell redirects
        if [ -n "$line" ]; then
            # Remove -o <file> and -e <file>
            args=$(echo "$line" | sed -E 's/-o [^ ]+ //g; s/-e [^ ]+ //g')
            # Remove shell redirects (2>> file, >> file, > file, >file, &>file)
            args=$(echo "$args" | sed -E 's/[12]?[>][>]? ?[^ ]+//g')
            # Remove leading binary path (starts with ../)
            args=$(echo "$args" | sed -E 's/^\.\.\/[^ ]+ //')
            # Trim whitespace
            args=$(echo "$args" | sed 's/^ *//;s/ *$//')
            break
        fi
    done < "$cmd_file"

    echo "${work_dir}|${args}"
}

# ─── Run trace for one benchmark ─────────────────────────────────────────────
run_traces() {
    local bname="$1"

    ensure_simpoints "$bname"

    local binary="${BENCH_BINARY[$bname]}"
    local run_dir="${BENCH_RUN_DIR[$bname]}"
    local traces_dir="$DATA_ROOT/$bname/traces"
    mkdir -p "$traces_dir"

    # Read simpoints
    local simpoints_file="$DATA_ROOT/$bname/simpoints.json"
    local intervals=$(python3 -c "
import json
data = json.load(open('$simpoints_file'))
for e in data:
    if e['weight'] >= $WEIGHT_THRESHOLD:
        print(f\"{e['interval_id']},{e['interval_id'] * $INTERVAL_SIZE},{e['weight']}\")
" 2>/dev/null)

    if [ -z "$intervals" ]; then
        log "  [$bname] No intervals above threshold"
        return
    fi

    # Parse speccmds.cmd
    local cmd_file="$run_dir/speccmds.cmd"
    local parsed=""
    [ -f "$cmd_file" ] && parsed=$(parse_speccmds "$cmd_file")

    local work_dir=""
    local spec_args=""
    if [ -n "$parsed" ]; then
        work_dir=$(echo "$parsed" | cut -d'|' -f1)
        spec_args=$(echo "$parsed" | cut -d'|' -f2)
    fi

    [ -z "$work_dir" ] && work_dir="$run_dir"
    [ -z "$spec_args" ] && spec_args=""
    [ ! -d "$work_dir" ] && work_dir="$run_dir"

    log "  [$bname] work_dir=$work_dir"
    log "  [$bname] args=$spec_args"
    log "  [$bname] binary=$binary"

    local running=0
    local failfile=$(mktemp)

    while IFS=',' read -r sid start weight; do
        local trace_out="$traces_dir/${bname}-${sid}B.champsimtrace"

        if [ -f "${trace_out}.xz" ]; then
            log "  [$bname] [SKIP] interval $sid already traced"
            continue
        fi

        # Concurrency control
        while [ "$running" -ge "$JOBS" ]; do
            wait -n 2>/dev/null || true
            ((running--)) || true
        done

        log "  [$bname] [START] interval $sid (skip=$start, record=$INTERVAL_SIZE)"

        (
            if $DRY_RUN; then
                echo "[DRY-RUN] cd ${work_dir} && ${PIN_ROOT}/pin -t ${PIN_TRACER} -o ${trace_out} -s ${start} -t ${INTERVAL_SIZE} -- ${binary} ${spec_args}"
                echo "[DRY-RUN] xz -T0 ${trace_out}"
                exit 0
            fi

            cd "$work_dir" || { log "  [$bname] [FAIL] cannot cd to $work_dir"; echo "1" >> "$failfile"; exit 1; }

            log "  [$bname] [PIN:$sid] Starting trace (skip=$start, record=$INTERVAL_SIZE)..."
            ${PIN_ROOT}/pin -t "${PIN_TRACER}" -o "${trace_out}" -s "${start}" -t "${INTERVAL_SIZE}" -- ${binary} ${spec_args}
            local pin_ec=$?

            if [ "$pin_ec" -eq 0 ]; then
                log "  [$bname] [PIN:$sid] Trace done, compressing..."
                if [ -f "$trace_out" ]; then
                    xz -T0 "$trace_out"
                    log "  [$bname] [PIN:$sid] Compressed → ${trace_out}.xz"
                fi
                exit 0
            else
                log "  [$bname] [PIN:$sid] FAILED (exit code $pin_ec)"
                echo "1" >> "$failfile"
                exit 1
            fi
        ) &
        ((running++)) || true
    done <<< "$intervals"

    # Wait for remaining jobs
    wait

    local failures=$(wc -l < "$failfile" 2>/dev/null || echo 0)
    rm -f "$failfile"
    if [ "$failures" -gt 0 ]; then
        log "  [$bname] $failures trace(s) failed"
    else
        log "  [$bname] All traces complete"
    fi
}

# ─── Main ────────────────────────────────────────────────────────────────────
log "=== CPU2017 Batch Trace ==="
log "PIN: $PIN_ROOT/pin"
log "Tracer: $PIN_TRACER"
log "Data dir: $DATA_ROOT"
log "Jobs per benchmark: $JOBS"

if [ -n "$SINGLE_BENCH" ]; then
    if [ -z "${BENCH_EXE[$SINGLE_BENCH]:-}" ]; then
        log "ERROR: $SINGLE_BENCH not found or not ready"
        log "Available: ${!BENCH_EXE[*]}"
        exit 1
    fi
    run_traces "$SINGLE_BENCH"
else
    for bname in $(echo "${!BENCH_EXE[@]}" | tr ' ' '\n' | sort); do
        # Skip benchmarks without SimPoints (e.g. CPU2017 rate 5xx_r)
        if [ ! -f "$DATA_ROOT/$bname/simpoints.json" ]; then
            log "[SKIP] $bname — no simpoints.json (no DPC-3 SimPoints for this benchmark)"
            continue
        fi
        if [ -z "${BENCH_RUN_DIR[$bname]}" ]; then
            log "[SKIP] $bname — no run directory (run: runcpu --action=setup --size=train $bname)"
            continue
        fi
        log "=== $bname ==="
        run_traces "$bname"
    done
fi

log "=== Batch trace complete ==="
