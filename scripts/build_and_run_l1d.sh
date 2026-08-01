#!/bin/bash
# Build all L1D profiling binaries sequentially (with proper clean), then run all in parallel.
# Usage: bash scripts/build_and_run_l1d.sh <trace> [warmup] [sim]
set -uo pipefail

TRACE="${1:?Usage: $0 <trace> [warmup] [sim]}"
WARMUP="${2:-1000000}"
SIM="${3:-10000000}"
JOBS="${JOBS:-90}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$ROOT/bin"
CONFIG_DIR="$ROOT/configs/l1d-profile"
DEMO_DIR="$ROOT/tools/l1d_hint_demo"
RUN_BASE="$ROOT/artifacts/runs/l1d-baseline"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
TRACE_NAME="$(basename "$TRACE" .champsimtrace.xz)"
RUN_DIR="$RUN_BASE/$TIMESTAMP"

mkdir -p "$RUN_DIR/profiling" "$RUN_DIR/eval" "$RUN_DIR/logs"
MAIN_LOG="$RUN_DIR/main.log"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$MAIN_LOG"; }

log "══════════════════════════════════════════════════════════"
log "  L1D Baseline (parallel)"
log "  Trace: $TRACE_NAME  Warmup: $WARMUP  Sim: $SIM  Jobs: $JOBS"
log "══════════════════════════════════════════════════════════"

# ── Step 1: Generate configs ──
log "Step 1: Generating configs..."
python3 "$DEMO_DIR/gen_configs.py"

# ── Step 2: Build all binaries (sequential, with clean) ──
log "Step 2: Building binaries..."
cd "$ROOT"
GLOBAL_OPTIONS="$ROOT/global.options"
ORIG_OPTIONS="$(cat "$GLOBAL_OPTIONS")"

build_one() {
    local cfg="$1" macro="$2" name="$3"
    if [ -x "$BIN_DIR/$name" ]; then
        log "  [SKIP] $name"
        return 0
    fi
    log "  [BUILD] $name ${macro:+($macro)}"
    if [ -n "$macro" ]; then
        printf '%s\n%s\n' "$ORIG_OPTIONS" "$macro" > "$GLOBAL_OPTIONS"
    else
        printf '%s\n' "$ORIG_OPTIONS" > "$GLOBAL_OPTIONS"
    fi
    python3 config.sh "$cfg" > /dev/null 2>&1
    rm -f .csconfig/generated_environment.o
    if make -j"$(nproc)" > "$RUN_DIR/logs/build_${name}.log" 2>&1; then
        log "  [OK] $name"
    else
        log "  [FAIL] $name — $(grep -m1 'error:' "$RUN_DIR/logs/build_${name}.log")"
    fi
}

while IFS= read -r line; do
    cfg=$(echo "$line" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['config_path'])")
    macro=$(echo "$line" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('degree_macro') or '')")
    name=$(echo "$line" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['name'])")
    build_one "$cfg" "$macro" "$name"
done < <(python3 -c "
import json
with open('$CONFIG_DIR/manifest.json') as f:
    for entry in json.load(f):
        print(json.dumps(entry))
")

# Restore global.options and build eval binaries
printf '%s\n' "$ORIG_OPTIONS" > "$GLOBAL_OPTIONS"

if [ ! -x "$BIN_DIR/champsim_no" ]; then
    log "  [BUILD] champsim_no"
    python3 config.sh configs/stage1/champsim_config_no.json > /dev/null 2>&1
    rm -f .csconfig/generated_environment.o
    make -j"$(nproc)" > "$RUN_DIR/logs/build_champsim_no.log" 2>&1 || true
fi
if [ ! -x "$BIN_DIR/champsim_hint_eval" ]; then
    log "  [BUILD] champsim_hint_eval"
    python3 config.sh configs/stage1/champsim_config_hint_eval.json > /dev/null 2>&1
    rm -f .csconfig/generated_environment.o
    make -j"$(nproc)" > "$RUN_DIR/logs/build_champsim_hint_eval.log" 2>&1 || true
fi

# ── Step 3: Run ALL profiling + B0 + B1 evals in parallel ──
log "Step 3: Running all simulations in parallel (JOBS=$JOBS)..."
cd "$ROOT"
running=0

# B0 baseline
log "  [LAUNCH] B0 (no prefetch)"
"$BIN_DIR/champsim_no" --warmup-instructions "$WARMUP" --simulation-instructions "$SIM" "$TRACE" \
    > "$RUN_DIR/eval/b0_no.txt" 2>&1 &
((running++)) || true

# All profiling binaries (also serves as B1 IPC measurement)
for bin_path in "$BIN_DIR"/champsim_l1d_*; do
    [ -x "$bin_path" ] || continue
    bname=$(basename "$bin_path")
    [[ "$bname" =~ ^champsim_l1d_(.+)_d([0-9]+)$ ]] || continue
    pref="${BASH_REMATCH[1]}"
    deg="${BASH_REMATCH[2]}"

    outfile="$RUN_DIR/profiling/${TRACE_NAME}__${pref}__${deg}.json"
    evalfile="$RUN_DIR/eval/b1_${pref}_d${deg}.txt"

    log "  [LAUNCH] ${pref}_d${deg}"
    (
        "$bin_path" --warmup-instructions "$WARMUP" --simulation-instructions "$SIM" "$TRACE" \
            > "$evalfile" 2> "$RUN_DIR/logs/profile_${pref}_d${deg}.log"
        grep '^{' "$evalfile" > "$outfile"
    ) &
    ((running++)) || true

    if [ "$running" -ge "$JOBS" ]; then
        wait -n 2>/dev/null || true
        ((running--)) || true
    fi
done

wait
log "  All simulations complete."

# ── Step 4: Find B1 best ──
log "Step 4: Finding best single prefetcher..."
BEST_IPC="0"
BEST_NAME=""
for evalfile in "$RUN_DIR"/eval/b1_*.txt; do
    [ -f "$evalfile" ] || continue
    bname=$(basename "$evalfile" .txt)
    ipc=$(grep -oP "cumulative IPC:\s*\K[\d.]+" "$evalfile" | tail -1)
    if [ -n "$ipc" ] && python3 -c "exit(0 if float('$ipc') > float('$BEST_IPC'))" 2>/dev/null; then
        BEST_IPC="$ipc"
        BEST_NAME="${bname#b1_}"
    fi
done
log "  B1 = $BEST_NAME, IPC = $BEST_IPC"
cp "$RUN_DIR/eval/b1_${BEST_NAME}.txt" "$RUN_DIR/eval/b1_best.txt"

# ── Step 5: Aggregate + Hint ──
log "Step 5: Aggregating + generating hint..."
python3 "$ROOT/tools/profiling/03_workers/aggregate_ground_truth.py" \
    --profiling-dir "$RUN_DIR/profiling" \
    --output "$RUN_DIR/ground_truth.jsonl" 2>&1 | tee -a "$MAIN_LOG"

python3 "$DEMO_DIR/oracle_gen.py" generate \
    --labels "$RUN_DIR/ground_truth.jsonl" \
    --output "$RUN_DIR/hint.bin" 2>&1 | tee -a "$MAIN_LOG"

# ── Step 6: B2 evaluation ──
log "Step 6: B2 oracle hint evaluation..."
"$BIN_DIR/champsim_hint_eval" --warmup-instructions "$WARMUP" --simulation-instructions "$SIM" \
    --hint-file "$RUN_DIR/hint.bin" "$TRACE" \
    > "$RUN_DIR/eval/b2_hint.txt" 2>&1
B0_IPC=$(grep -oP "cumulative IPC:\s*\K[\d.]+" "$RUN_DIR/eval/b0_no.txt" | tail -1)
B2_IPC=$(grep -oP "cumulative IPC:\s*\K[\d.]+" "$RUN_DIR/eval/b2_hint.txt" | tail -1)

# ── Step 7: Comparison ──
log "Step 7: Results..."
echo "" | tee -a "$MAIN_LOG"
log "B0 vs B2:"
python3 "$DEMO_DIR/parse_stats.py" "$RUN_DIR/eval/b0_no.txt" "$RUN_DIR/eval/b2_hint.txt" \
    | tee "$RUN_DIR/comparison_b0_vs_b2.txt" | tee -a "$MAIN_LOG"
echo "" | tee -a "$MAIN_LOG"
log "B1 vs B2:"
python3 "$DEMO_DIR/parse_stats.py" "$RUN_DIR/eval/b1_best.txt" "$RUN_DIR/eval/b2_hint.txt" \
    | tee "$RUN_DIR/comparison_b1_vs_b2.txt" | tee -a "$MAIN_LOG"

log ""
log "══════════════════════════════════════════════════════════"
log "  SUMMARY"
log "  B0 (no prefetch):     IPC = $B0_IPC"
log "  B1 (best single):     IPC = $BEST_IPC ($BEST_NAME)"
log "  B2 (oracle hint):     IPC = $B2_IPC"
if python3 -c "exit(0 if float('$B2_IPC') > float('$BEST_IPC'))" 2>/dev/null; then
    log "  VERDICT: B2 > B1 ✓"
else
    log "  VERDICT: B2 ≤ B1"
fi
log "  Run dir: $RUN_DIR"
log "══════════════════════════════════════════════════════════"
