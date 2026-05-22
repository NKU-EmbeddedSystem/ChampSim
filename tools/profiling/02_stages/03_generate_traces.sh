#!/usr/bin/env bash
# Module 3: Generate ChampSim traces via Intel PIN.
# Output: data/<benchmark>/traces/<benchmark>-<sid>B.champsimtrace.xz
#
# Usage:
#   ./modules/03_generate_traces.sh <benchmark> [--force] [--dry-run] [--jobs N]
#   BINARY_PATH=/path/to/binary ./modules/03_generate_traces.sh <benchmark>
#
# One-time: Re-trace only when the binary is recompiled.
# Parallel execution with concurrency control (default JOBS=4).
#
# Skip logic: checks trace existence BEFORE binary discovery, so that
# --dry-run and idempotency exits early without needing SPEC binaries.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

BENCHMARK="${1:-}"
shift 2>/dev/null || true
FORCE=false
DRY_RUN=false
JOBS="${JOBS:-4}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) FORCE=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --jobs) JOBS="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$BENCHMARK" ]; then
    echo "Usage: $0 <benchmark> [--force] [--dry-run] [--jobs N]"
    echo "Example: $0 400.perlbench --jobs 2"
    exit 1
fi

BENCH_DIR="$DATA_ROOT/$BENCHMARK"
SIMPOINTS_JSON="$BENCH_DIR/simpoints.json"
TRACES_DIR="$BENCH_DIR/traces"
MODULE_NAME="[03_traces]"

XZ_THREADS="${XZ_TRACE_THREADS:-1}"           # per-trace xz threads (avoid oversubscription)
XZ_LOCKFILE="$TRACES_DIR/.xz_compression.lock"  # serialize xz to avoid I/O thrashing

log()  { echo "[$(date '+%H:%M:%S')] $MODULE_NAME $*"; }
run()  {
    if $DRY_RUN; then
        echo "[DRY-RUN] $*"
    else
        eval "$@"
    fi
}

# Prerequisites
if [ ! -f "$SIMPOINTS_JSON" ]; then
    log "ERROR: simpoints.json not found. Run module 01 first."
    exit 1
fi

if [ ! -f "$PIN_TRACER" ]; then
    log "ERROR: PIN tracer not found at $PIN_TRACER"
    log "  Build it: cd ${CHAMPSIM_ROOT}/tracer/pin && make"
    exit 1
fi

# ── Phase 1: Read SimPoints & check trace existence ──────────
# Done BEFORE binary discovery so that --dry-run and idempotency
# can exit early without needing SPEC binaries.

declare -a sids=() starts=() weights=()
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
    log "ERROR: No SimPoints above weight threshold $WEIGHT_THRESHOLD"
    exit 1
fi

log "Found ${#sids[@]} SimPoint intervals to trace"

run mkdir -p "$TRACES_DIR"

# Minimum valid trace size: 1KB compressed (empty traces compress to 32 bytes)
MIN_TRACE_SIZE=1024

# Check which traces already exist and are valid
pending=0 completed=0
for i in "${!sids[@]}"; do
    sid="${sids[$i]}"
    trace_out="$TRACES_DIR/${BENCHMARK}-${sid}B.champsimtrace"
    if [ -f "${trace_out}.xz" ] && [ "$FORCE" != "true" ]; then
        fsize=$(stat -c %s "${trace_out}.xz" 2>/dev/null || echo 0)
        if [ "$fsize" -lt "$MIN_TRACE_SIZE" ]; then
            log "  [WARN] Interval $sid trace too small ($fsize bytes), re-generating"
            ((pending++)) || true
        else
            log "  [SKIP] Interval $sid already traced → ${trace_out}.xz"
            ((completed++)) || true
        fi
    else
        ((pending++)) || true
    fi
done

if [ "$pending" -eq 0 ]; then
    log "All $completed traces already exist. Nothing to do."
    exit 0
fi

log "  $pending to generate, $completed already done (concurrency=$JOBS)"

# ── Phase 2: Suite auto-detection + Binary discovery ──

# Auto-detect SPEC suite from benchmark name (always, even if BINARY_PATH is set)
if [[ "$BENCHMARK" =~ ^4[0-9] ]]; then
    SUITE="CPU2006"
    SPEC_ROOT="${SPEC2006_ROOT:-${SPEC_ROOT:-}}"
    BENCHSPEC_DIR="benchspec/CPU2006"
    RUN_PATTERN="run_base_ref_*"
elif [[ "$BENCHMARK" =~ ^6[0-9].*_s$ ]]; then
    SUITE="CPU2017"
    SPEC_ROOT="${SPEC2017_ROOT:-}"
    BENCHSPEC_DIR="benchspec/CPU"
    RUN_PATTERN="run_base_refspeed_*"
else
    log "ERROR: Cannot auto-detect SPEC suite for '$BENCHMARK'"
    log "  Use BINARY_PATH=/path/to/binary for unsupported suites"
    exit 1
fi

if [ -z "$SPEC_ROOT" ]; then
    log "ERROR: SPEC($SUITE)_ROOT not set. Check tools/benchmarks/spec*/config.sh"
    exit 1
fi

# Discover binary if not explicitly provided
BINARY_PATH="${BINARY_PATH:-}"
if [ -z "$BINARY_PATH" ]; then
    exe_name=$(grep "exename" "$SPEC_ROOT/$BENCHSPEC_DIR/$BENCHMARK/Spec/object.pm" 2>/dev/null | grep -oP "'\K[^']*" | head -1)
    [ -z "$exe_name" ] && exe_name=$(echo "$BENCHMARK" | sed 's/^[0-9]*\.//')
    spec_build_dir=$(find "$SPEC_ROOT/$BENCHSPEC_DIR/$BENCHMARK/build" -maxdepth 2 -type d -name "build_base_*" 2>/dev/null | head -1)
    spec_run_dir=$(find "$SPEC_ROOT/$BENCHSPEC_DIR/$BENCHMARK/run" -maxdepth 2 -type d -name "run_base_*" 2>/dev/null | head -1)
    if [ -n "$spec_build_dir" ]; then
        BINARY_PATH="$spec_build_dir/$exe_name"
    elif [ -n "$spec_run_dir" ]; then
        BINARY_PATH="$spec_run_dir/$exe_name"
    fi
fi

if [ -z "$BINARY_PATH" ] || [ ! -f "$BINARY_PATH" ]; then
    log "ERROR: SPEC binary not found. Set BINARY_PATH=/path/to/binary"
    exit 1
fi
log "Binary: $BINARY_PATH (suite=$SUITE)"

# SPEC run directory and args
spec_run_dir=$(find "$SPEC_ROOT/$BENCHSPEC_DIR/$BENCHMARK/run" \
    -maxdepth 2 -name "$RUN_PATTERN" -type d 2>/dev/null | head -1)
[ -z "$spec_run_dir" ] && spec_run_dir=$(dirname "$BINARY_PATH")

spec_work_dir="$spec_run_dir"
spec_args=""
spec_cmd_file="$spec_run_dir/speccmds.cmd"
if [ -f "$spec_cmd_file" ]; then
    while IFS= read -r line; do
        [[ "$line" =~ ^# ]] && continue
        [[ -z "$line" ]] && continue
        # CPU2017: skip -E (env), -r (redirect), -N (niceness) lines
        [[ "$line" =~ ^-[ErN] ]] && continue
        if [[ "$line" =~ ^-C ]]; then
            spec_work_dir=$(echo "$line" | sed 's/^-C //')
            continue
        fi
        # Strip -o <file>, -e <file>, -i <file>, binary path, and shell redirects
        spec_args=$(echo "$line" \
            | sed 's/-o [^ ]* //' \
            | sed 's/-e [^ ]* //' \
            | sed -E 's/[12]?>> ?[^ ]*//g' \
            | sed -E 's/> ?[^ ]*//g' \
            | sed 's/^ *//' \
            | sed -E 's/ ?[^ ]*_base\.[^ ]*//g' \
            | sed 's/  */ /g' \
            | sed 's/^ *//;s/ *$//')
        break
    done < "$spec_cmd_file"
    log "SPEC work dir: $spec_work_dir"
    log "SPEC args: $spec_args"
fi

stdin_file=""
if [[ "$spec_args" =~ -i[[:space:]]+([^[:space:]]+) ]]; then
    stdin_file="${BASH_REMATCH[1]}"
    spec_args=$(echo "$spec_args" | sed -E 's/-i [^ ]+ //' | sed 's/^ *//;s/ *$//')
    log "SPEC stdin redirect: $stdin_file"
fi

# ── Parallel execution ──────────────────────────────────────
running=0
failfile=$(mktemp)

for i in "${!sids[@]}"; do
    sid="${sids[$i]}"
    start="${starts[$i]}"
    weight="${weights[$i]}"
    trace_out="$TRACES_DIR/${BENCHMARK}-${sid}B.champsimtrace"

    if [ -f "${trace_out}.xz" ] && [ "$FORCE" != "true" ]; then
        fsize=$(stat -c %s "${trace_out}.xz" 2>/dev/null || echo 0)
        if [ "$fsize" -ge "$MIN_TRACE_SIZE" ]; then
            continue
        fi
    fi

    while [ "$running" -ge "$JOBS" ]; do
        wait -n 2>/dev/null || true
        ((running--)) || true
    done

    log "  [LAUNCH] SimPoint $sid (weight=$weight, start=$start, slot=$((running+1))/$JOBS)"

    (
        pin_cmd="${PIN_ROOT}/pin -t ${PIN_TRACER} -o ${trace_out} -s ${start} -t ${TRACE_LENGTH} -- ${BINARY_PATH} ${spec_args}"
        if $DRY_RUN; then
            echo "[DRY-RUN] cd ${spec_work_dir} && $pin_cmd"
            echo "[DRY-RUN] xz -T${XZ_THREADS} ${trace_out} && xz -t ${trace_out}.xz"
            exit 0
        fi

        echo "[$(date '+%H:%M:%S')] [PIN:$sid] Starting trace..."
        cd "$spec_work_dir" || { echo "[PIN:$sid] FAILED: cannot cd"; echo "1" >> "$failfile"; exit 1; }

        # Launch PIN in background to enable trace file size monitoring
        if [ -n "${stdin_file:-}" ] && [ -f "$stdin_file" ]; then
            eval "$pin_cmd" < "$stdin_file" &
        elif [ -n "${stdin_file:-}" ]; then
            eval "$pin_cmd" < "${spec_work_dir}/${stdin_file}" &
        else
            eval "$pin_cmd" &
        fi
        pin_pid=$!

        # Monitor trace file size; terminate PIN when 100M instructions recorded
        TRACE_TARGET=$(( TRACE_LENGTH * 64 ))   # 250M × 64 = 16GB
        TRACE_MIN=$(( TRACE_TARGET * 98 / 100 ))
        last_sz=0; stable=0
        while kill -0 $pin_pid 2>/dev/null; do
            sleep 10
            sz=$(stat -c %s "$trace_out" 2>/dev/null || echo 0)
            if [ "$sz" -ge "$TRACE_TARGET" ]; then
                echo "[$(date '+%H:%M:%S')] [PIN:$sid] Target reached (${sz} bytes), stopping..."
                kill $pin_pid 2>/dev/null
                break
            fi
            if [ "$sz" -ge "$TRACE_MIN" ] && [ "$sz" = "$last_sz" ] && [ "$sz" -gt 0 ]; then
                stable=$((stable + 1))
                if [ "$stable" -ge 3 ]; then
                    echo "[$(date '+%H:%M:%S')] [PIN:$sid] Stable at ${sz} bytes, stopping..."
                    kill $pin_pid 2>/dev/null
                    break
                fi
            else
                stable=0
            fi
            last_sz=$sz
        done
        wait $pin_pid 2>/dev/null || true

        if [ -f "$trace_out" ] && [ -s "$trace_out" ]; then
            echo "[$(date '+%H:%M:%S')] [PIN:$sid] Trace done, compressing..."
            # Serialize xz compression to avoid I/O thrashing when many traces finish together
            if flock "$XZ_LOCKFILE" xz -T"${XZ_THREADS}" "$trace_out"; then
                if xz -t "${trace_out}.xz" > /dev/null 2>&1; then
                    echo "[$(date '+%H:%M:%S')] [PIN:$sid] Compressed → ${trace_out}.xz"
                    exit 0
                else
                    echo "[$(date '+%H:%M:%S')] [PIN:$sid] FAILED: compressed trace is corrupt"
                    echo "1" >> "$failfile"
                    exit 1
                fi
            else
                echo "[$(date '+%H:%M:%S')] [PIN:$sid] FAILED: xz compression failed (exit=$?)"
                echo "1" >> "$failfile"
                exit 1
            fi
        else
            echo "[$(date '+%H:%M:%S')] [PIN:$sid] FAILED"
            echo "1" >> "$failfile"
            exit 1
        fi
    ) &
    ((running++)) || true
done

wait

if [ -s "$failfile" ]; then
    failed_count=$(wc -l < "$failfile")
    rm -f "$failfile"
    log "ERROR: $failed_count trace job(s) failed"
    exit 1
fi
rm -f "$failfile"

log "All traces in $TRACES_DIR"
