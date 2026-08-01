#!/usr/bin/env bash
#
# tools/l1d_hint_demo/run_demo.sh — End-to-end L1D prefetcher profiling + hint evaluation demo.
#
# Usage:
#   bash tools/l1d_hint_demo/run_demo.sh [TRACE]
#   WARMUP=1000000 SIM=10000000 JOBS=4 bash tools/l1d_hint_demo/run_demo.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHAMPSIM_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEMO_DIR="$CHAMPSIM_ROOT/tools/l1d_hint_demo"
CONFIG_DIR="$CHAMPSIM_ROOT/configs/l1d-profile"
WORK_DIR="$CHAMPSIM_ROOT/tools/l1d_hint_demo/work"

TRACE="${1:-$CHAMPSIM_ROOT/trace/602.gcc_s-1850B.champsimtrace.xz}"
WARMUP="${WARMUP:-1000000}"
SIM="${SIM:-10000000}"
JOBS="${JOBS:-4}"
SKIP_BUILD="${SKIP_BUILD:-false}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

# ── Sanity checks ──────────────────────────────────────────────
if [ ! -f "$TRACE" ]; then
    log "ERROR: Trace not found: $TRACE"
    exit 1
fi

mkdir -p "$WORK_DIR/profiling" "$WORK_DIR/logs" "$WORK_DIR/eval"

# ── Step 1: Generate configs ──────────────────────────────────
log "Step 1: Generating L1D-only profiling configs..."
python3 "$DEMO_DIR/gen_configs.py"

# ── Step 2: Build profiling binaries ─────────────────────────
if [ "$SKIP_BUILD" != "true" ]; then
    log "Step 2: Building profiling binaries..."
    cd "$CHAMPSIM_ROOT"

    GLOBAL_OPTIONS="$CHAMPSIM_ROOT/global.options"
    cp "$GLOBAL_OPTIONS" "$GLOBAL_OPTIONS.demo_bak"

    build_one() {
        local cfg="$1"
        local macro="$2"
        local name
        name=$(python3 -c "import json; print(json.load(open('$cfg'))['executable_name'])")

        if [ -x "bin/$name" ]; then
            log "  [SKIP] $name (already built)"
            return 0
        fi

        log "  [BUILD] $name ${macro:+(macro: $macro)}"

        if [ -n "$macro" ]; then
            echo "$macro" >> "$GLOBAL_OPTIONS"
        fi

        python3 config.sh "$cfg" > /dev/null 2>&1
        if make -j"$(nproc)" > "$WORK_DIR/logs/build_${name}.log" 2>&1; then
            log "  [OK] $name"
        else
            log "  [FAIL] $name — see $WORK_DIR/logs/build_${name}.log"
        fi

        if [ -n "$macro" ]; then
            cp "$GLOBAL_OPTIONS.demo_bak" "$GLOBAL_OPTIONS"
        fi
    }

    while IFS= read -r line; do
        cfg=$(echo "$line" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['config_path'])")
        macro=$(echo "$line" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('degree_macro') or '')")
        build_one "$cfg" "$macro"
    done < <(python3 -c "
import json
with open('$CONFIG_DIR/manifest.json') as f:
    for entry in json.load(f):
        print(json.dumps(entry))
")

    # Restore global.options
    cp "$GLOBAL_OPTIONS.demo_bak" "$GLOBAL_OPTIONS"

    # Build baseline (no prefetch) and hint_eval binaries
    log "  [BUILD] champsim_no (baseline)..."
    if [ ! -x bin/champsim_no ]; then
        python3 config.sh configs/stage1/champsim_config_no.json > /dev/null 2>&1
        make -j"$(nproc)" > "$WORK_DIR/logs/build_champsim_no.log" 2>&1 || true
    fi

    log "  [BUILD] champsim_hint_eval..."
    if [ ! -x bin/champsim_hint_eval ]; then
        python3 config.sh configs/stage1/champsim_config_hint_eval.json > /dev/null 2>&1
        make -j"$(nproc)" > "$WORK_DIR/logs/build_champsim_hint_eval.log" 2>&1 || true
    fi

    rm -f "$GLOBAL_OPTIONS.demo_bak"
else
    log "Step 2: Skipped (SKIP_BUILD=true)"
fi

# ── Step 3: Run profiling ─────────────────────────────────────
log "Step 3: Running profiling (warmup=$WARMUP, sim=$SIM, jobs=$JOBS)..."
cd "$CHAMPSIM_ROOT"

running=0
pids=()

for bin_path in bin/champsim_l1d_*; do
    [ -x "$bin_path" ] || continue
    bname=$(basename "$bin_path")

    # Parse prefetcher and degree from binary name: champsim_l1d_<pref>_d<deg>
    if [[ "$bname" =~ ^champsim_l1d_(.+)_d([0-9]+)$ ]]; then
        pref="${BASH_REMATCH[1]}"
        deg="${BASH_REMATCH[2]}"
    else
        continue
    fi

    outfile="$WORK_DIR/profiling/602.gcc_s__${pref}__${deg}.json"

    if [ -s "$outfile" ]; then
        log "  [SKIP] ${pref}_d${deg} (output exists)"
        continue
    fi

    log "  [RUN] ${pref}_d${deg}"
    (
        "$bin_path" --warmup-instructions "$WARMUP" --simulation-instructions "$SIM" "$TRACE" \
            2> "$WORK_DIR/logs/profile_${pref}_d${deg}.log" \
            | grep '^{' > "$outfile"
    ) &
    pids+=($!)
    ((running++)) || true

    if [ "$running" -ge "$JOBS" ]; then
        wait -n 2>/dev/null || true
        ((running--)) || true
    fi
done

wait
log "  Profiling complete."

# ── Step 4: Aggregate ground truth ────────────────────────────
log "Step 4: Aggregating ground truth labels..."
python3 "$CHAMPSIM_ROOT/tools/profiling/03_workers/aggregate_ground_truth.py" \
    --profiling-dir "$WORK_DIR/profiling" \
    --output "$WORK_DIR/ground_truth.jsonl"

# ── Step 5: Generate hint file ────────────────────────────────
log "Step 5: Generating hint binary..."
python3 "$DEMO_DIR/oracle_gen.py" generate \
    --labels "$WORK_DIR/ground_truth.jsonl" \
    --output "$WORK_DIR/hint.bin"

python3 "$DEMO_DIR/oracle_gen.py" validate --input "$WORK_DIR/hint.bin"

# ── Step 6: Run evaluation ────────────────────────────────────
log "Step 6: Running evaluation..."
cd "$CHAMPSIM_ROOT"

log "  [EVAL] Baseline (no prefetch)..."
bin/champsim_no --warmup-instructions "$WARMUP" --simulation-instructions "$SIM" "$TRACE" \
    > "$WORK_DIR/eval/baseline.txt" 2>&1

log "  [EVAL] Hint-guided..."
bin/champsim_hint_eval --warmup-instructions "$WARMUP" --simulation-instructions "$SIM" \
    --hint-file "$WORK_DIR/hint.bin" "$TRACE" \
    > "$WORK_DIR/eval/hint.txt" 2>&1

# ── Step 7: Compare results ───────────────────────────────────
log "Step 7: Results comparison..."
echo ""
python3 "$DEMO_DIR/parse_stats.py" "$WORK_DIR/eval/baseline.txt" "$WORK_DIR/eval/hint.txt"

log ""
log "Done. Artifacts in: $WORK_DIR/"
log "  Profiling:  $WORK_DIR/profiling/"
log "  Labels:     $WORK_DIR/ground_truth.jsonl"
log "  Hint file:  $WORK_DIR/hint.bin"
log "  Eval logs:  $WORK_DIR/eval/"
