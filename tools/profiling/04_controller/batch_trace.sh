#!/usr/bin/env bash
# Run Stage 3 (PIN trace) for all SPEC2006 benchmarks with compiled binaries.
# Usage: ./batch_trace.sh [--max-benchmarks N] [--jobs-per-bench N]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"
cd "$SCRIPT_DIR"

# Benchmark list with compiled binaries (hardcoded from prior check)
BENCHMARKS=(
  400.perlbench 401.bzip2 403.gcc 410.bwaves 429.mcf 433.milc
  445.gobmk 456.hmmer 458.sjeng 462.libquantum 464.h264ref
  470.lbm 471.omnetpp 473.astar 483.xalancbmk
)

MAX_BENCHMARKS=0    # 0 = unlimited
JOBS_PER_BENCH=2
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-benchmarks) MAX_BENCHMARKS="$2"; shift 2 ;;
    --jobs-per-bench) JOBS_PER_BENCH="$2"; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    *) echo "Unknown: $1"; exit 1 ;;
  esac
done

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ── Step 0: Ensure SPEC train run directories exist ────────────────────
log "=== Phase 0: Ensuring SPEC train run environments ==="
for bench in "${BENCHMARKS[@]}"; do
  run_dir=$(find "$SPEC_ROOT/benchspec/CPU2006/$bench/run" -maxdepth 2 -name "run_base_train_*" -type d 2>/dev/null | head -1)
  if [ -n "$run_dir" ] && [ -f "$run_dir/speccmds.cmd" ]; then
    log "  [SKIP] $bench — run dir already exists"
    continue
  fi
  log "  [SETUP] $bench — runspec --action=setup --size=train"
  if $DRY_RUN; then
    echo "[DRY-RUN] cd $SPEC_ROOT && . ./shrc && runspec --action=setup --config=linux64-amd64-gcc-fortify0.cfg --tune=base --size=train $bench"
  else
    ( cd "$SPEC_ROOT" && . ./shrc && runspec --action=setup --config=linux64-amd64-gcc-fortify0.cfg --tune=base --size=train "$bench" 2>&1 | tail -1 )
  fi
done

# ── Step 1: Run Stages 1+2 for all benchmarks ──────────────────────────
log "=== Phase 1: Stages 1+2 (SimPoints + Disassembly) for ${#BENCHMARKS[@]} benchmarks ==="
for bench in "${BENCHMARKS[@]}"; do
  simpoints="$DATA_ROOT/$bench/simpoints.json"
  disasm="$DATA_ROOT/$bench/disasm_index.json"
  if [ -f "$simpoints" ] && [ -f "$disasm" ]; then
    log "  [SKIP] $bench — Stage 1+2 already done"
    continue
  fi
  log "  [PREP] $bench — Running stages 1+2..."
  if $DRY_RUN; then
    echo "[DRY-RUN] ./run_pipeline.sh $bench --stage 1 && ./run_pipeline.sh $bench --stage 2"
  else
    ./run_pipeline.sh "$bench" --stage 1 2>&1 | tail -1
    ./run_pipeline.sh "$bench" --stage 2 2>&1 | tail -1
  fi
done

# ── Step 2: Find binary for each benchmark ────────────────────────────
declare -A BINARIES
for bench in "${BENCHMARKS[@]}"; do
  exe_name=$(grep "exename" "$SPEC_ROOT/benchspec/CPU2006/$bench/Spec/object.pm" 2>/dev/null | grep -oP "'\K[^']*" | head -1)
  [ -z "$exe_name" ] && exe_name=$(echo "$bench" | sed 's/^[0-9]*\.//')
  bin_path=$(find "$SPEC_ROOT/benchspec/CPU2006/$bench/build" -maxdepth 3 -type f -executable -not -name "*.h" -not -name "*.c" -name "$exe_name*" 2>/dev/null | head -1)
  [ -z "$bin_path" ] && bin_path=$(find "$SPEC_ROOT/benchspec/CPU2006/$bench/run" -maxdepth 3 -type f -executable -name "${exe_name}_base*" 2>/dev/null | head -1)
  if [ -z "$bin_path" ]; then
    log "  [WARN] $bench: no binary found, skipping"
    continue
  fi
  BINARIES[$bench]="$bin_path"
  log "  $bench → ${BINARIES[$bench]}"
done

# ── Step 3: Launch Stage 3 for each benchmark in parallel ─────────────
LOG_DIR="$DATA_ROOT/batch_logs"
mkdir -p "$LOG_DIR"

BATCH_FAILFILE=$(mktemp)
launched=0

log "=== Phase 2: Stage 3 (Parallel PIN Trace) ==="
for bench in "${BENCHMARKS[@]}"; do
  bin="${BINARIES[$bench]:-}"
  [ -z "$bin" ] && continue

  traces_xz=$(find "$DATA_ROOT/$bench/traces" -name "*.xz" 2>/dev/null | wc -l || echo 0)
  simpoints_count=$(python3 -c "
import json
data = json.load(open('$DATA_ROOT/$bench/simpoints.json'))
print(sum(1 for e in data if e['weight'] >= $WEIGHT_THRESHOLD))
" 2>/dev/null || echo 0)

  if [ "$simpoints_count" -eq 0 ]; then
    log "  [SKIP] $bench: no SimPoints above threshold"
    continue
  fi

  # Count already-completed traces
  completed_count=0
  for sid in $(python3 -c "
import json
data = json.load(open('$DATA_ROOT/$bench/simpoints.json'))
for e in data:
    if e['weight'] >= $WEIGHT_THRESHOLD:
        print(e['interval_id'])
" 2>/dev/null); do
    [ -f "$DATA_ROOT/$bench/traces/${bench}-${sid}B.champsimtrace.xz" ] && ((completed_count++)) || true
  done

  if [ "$completed_count" -ge "$simpoints_count" ]; then
    log "  [SKIP] $bench: all $completed_count/$simpoints_count traces already done"
    continue
  fi

  log "  [LAUNCH] $bench ($completed_count/$simpoints_count done, launching remaining)"
  (
    export BINARY_PATH="$bin"
    export SPEC_ROOT="$SPEC_ROOT"
    if ./run_pipeline.sh "$bench" --stage 3 --jobs "$JOBS_PER_BENCH" > "$LOG_DIR/${bench}.log" 2>&1; then
      log "  [DONE] $bench — all traces complete"
    else
      log "  [FAIL] $bench — check $LOG_DIR/${bench}.log"
      echo "1" >> "$BATCH_FAILFILE"
    fi
  ) &
  ((launched++))

  [ "$MAX_BENCHMARKS" -gt 0 ] && [ "$launched" -ge "$MAX_BENCHMARKS" ] && break
done

log "Launched $launched benchmarks in background"
log "Logs: $LOG_DIR/"
log "Monitor: watch -n 10 'ls -lh $DATA_ROOT/*/traces/'"
log ""

wait

if [ -s "$BATCH_FAILFILE" ]; then
  failed=$(wc -l < "$BATCH_FAILFILE")
  log "ERROR: $failed benchmark(s) failed. Check logs in $LOG_DIR/"
  rm -f "$BATCH_FAILFILE"
  exit 1
fi

rm -f "$BATCH_FAILFILE"
log "All benchmarks complete!"
