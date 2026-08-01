#!/bin/bash
# L1D Baseline: Full Prefetcher × Degree Profiling + Oracle Hint Evaluation
# Usage: bash scripts/run_l1d_baseline.sh <trace> [warmup] [sim]

set -uo pipefail

TRACE="${1:?Usage: $0 <trace> [warmup] [sim]}"
WARMUP="${2:-1000000}"
SIM="${3:-10000000}"
JOBS="${JOBS:-4}"
SKIP_BUILD="${SKIP_BUILD:-false}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$ROOT/bin"
RUN_BASE="$ROOT/artifacts/runs/l1d-baseline"
PLAN_DIR="$ROOT/artifacts/plans/l1d-baseline"
DEMO_DIR="$ROOT/tools/l1d_hint_demo"
CONFIG_DIR="$ROOT/configs/l1d-profile"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
TRACE_NAME="$(basename "$TRACE" .champsimtrace.xz)"

RUN_DIR="$RUN_BASE/$TIMESTAMP"
mkdir -p "$RUN_DIR/profiling" "$RUN_DIR/eval" "$RUN_DIR/logs" "$PLAN_DIR"
MAIN_LOG="$RUN_DIR/main.log"

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$MAIN_LOG"; }

# ── header ──
cat > "$MAIN_LOG" <<HEADER
══════════════════════════════════════════════════════════
  L1D Baseline: Prefetcher × Degree Profiling + Oracle Hint
  Trace:   $TRACE_NAME
  Warmup:  $WARMUP  Sim: $SIM  Jobs: $JOBS
  Started: $(date '+%Y-%m-%d %H:%M:%S')
  Run dir: $RUN_DIR
  Plan:    $PLAN_DIR/PLAN.md
══════════════════════════════════════════════════════════

HEADER

# ── Sanity ──
if [ ! -f "$TRACE" ]; then
    log "ERROR: Trace not found: $TRACE"
    exit 1
fi

# ── Phase A: Generate configs + Build + Profile ──
log "Phase A: Profiling"

log "  Generating configs..."
python3 "$DEMO_DIR/gen_configs.py" 2>&1 | tee -a "$MAIN_LOG"

if [ "$SKIP_BUILD" != "true" ]; then
    log "  Building profiling binaries..."
    cd "$ROOT"
    GLOBAL_OPTIONS="$ROOT/global.options"
    ORIG_OPTIONS="$(cat "$GLOBAL_OPTIONS")"

    while IFS= read -r line; do
        cfg=$(echo "$line" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['config_path'])")
        macro=$(echo "$line" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('degree_macro') or '')")
        name=$(echo "$line" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['name'])")

        if [ -x "$BIN_DIR/$name" ]; then
            log "    [SKIP] $name"
            continue
        fi

        log "    [BUILD] $name ${macro:+($macro)}"
        if [ -n "$macro" ]; then
            echo "$macro" >> "$GLOBAL_OPTIONS"
        fi
        python3 config.sh "$cfg" > /dev/null 2>&1
        if make -j"$(nproc)" > "$RUN_DIR/logs/build_${name}.log" 2>&1; then
            log "    [OK] $name"
        else
            log "    [FAIL] $name"
        fi
        echo "$ORIG_OPTIONS" > "$GLOBAL_OPTIONS"
    done < <(python3 -c "
import json
with open('$CONFIG_DIR/manifest.json') as f:
    for entry in json.load(f):
        print(json.dumps(entry))
")

    # Build eval binaries
    if [ ! -x "$BIN_DIR/champsim_no" ]; then
        log "    [BUILD] champsim_no"
        python3 config.sh configs/stage1/champsim_config_no.json > /dev/null 2>&1
        make -j"$(nproc)" > "$RUN_DIR/logs/build_champsim_no.log" 2>&1 || true
    fi
    if [ ! -x "$BIN_DIR/champsim_hint_eval" ]; then
        log "    [BUILD] champsim_hint_eval"
        python3 config.sh configs/stage1/champsim_config_hint_eval.json > /dev/null 2>&1
        make -j"$(nproc)" > "$RUN_DIR/logs/build_champsim_hint_eval.log" 2>&1 || true
    fi
fi

# Run profiling
log "  Running profiling (jobs=$JOBS)..."
cd "$ROOT"
running=0

for bin_path in "$BIN_DIR"/champsim_l1d_*; do
    [ -x "$bin_path" ] || continue
    bname=$(basename "$bin_path")
    if [[ "$bname" =~ ^champsim_l1d_(.+)_d([0-9]+)$ ]]; then
        pref="${BASH_REMATCH[1]}"
        deg="${BASH_REMATCH[2]}"
    else
        continue
    fi

    outfile="$RUN_DIR/profiling/${TRACE_NAME}__${pref}__${deg}.json"
    if [ -s "$outfile" ]; then
        log "    [SKIP] ${pref}_d${deg}"
        continue
    fi

    log "    [RUN] ${pref}_d${deg}"
    "$bin_path" --warmup-instructions "$WARMUP" --simulation-instructions "$SIM" "$TRACE" \
        2> "$RUN_DIR/logs/profile_${pref}_d${deg}.log" \
        | grep '^{' > "$outfile" &
    ((running++)) || true

    if [ "$running" -ge "$JOBS" ]; then
        wait -n 2>/dev/null || true
        ((running--)) || true
    fi
done
wait
log "  Profiling complete."

# ── Phase B: Aggregate ──
log "Phase B: Aggregating ground truth..."
python3 "$ROOT/tools/profiling/03_workers/aggregate_ground_truth.py" \
    --profiling-dir "$RUN_DIR/profiling" \
    --output "$RUN_DIR/ground_truth.jsonl" 2>&1 | tee -a "$MAIN_LOG"

# ── Phase C: Hint generation ──
log "Phase C: Generating hint binary..."
python3 "$DEMO_DIR/oracle_gen.py" generate \
    --labels "$RUN_DIR/ground_truth.jsonl" \
    --output "$RUN_DIR/hint.bin" 2>&1 | tee -a "$MAIN_LOG"

# ── Phase D: Evaluation ──
log "Phase D: Evaluation..."
cd "$ROOT"

log "  [B0] No prefetch..."
"$BIN_DIR/champsim_no" --warmup-instructions "$WARMUP" --simulation-instructions "$SIM" "$TRACE" \
    > "$RUN_DIR/eval/b0_no.txt" 2>&1
B0_IPC=$(grep -oP "cumulative IPC:\s*\K[\d.]+" "$RUN_DIR/eval/b0_no.txt" | tail -1)
log "  B0 IPC = $B0_IPC"

# Find best single prefetcher from profiling IPC
log "  [B1] Best single prefetcher..."
BEST_BIN=""
BEST_IPC="0"
for bin_path in "$BIN_DIR"/champsim_l1d_*; do
    [ -x "$bin_path" ] || continue
    bname=$(basename "$bin_path")
    [[ "$bname" == *"__no__"* ]] && continue
    [[ "$bname" =~ ^champsim_l1d_(.+)_d([0-9]+)$ ]] || continue
    pref="${BASH_REMATCH[1]}"
    deg="${BASH_REMATCH[2]}"

    "$bin_path" --warmup-instructions "$WARMUP" --simulation-instructions "$SIM" "$TRACE" \
        2>/dev/null | grep -oP "cumulative IPC:\s*\K[\d.]+" | tail -1 > /tmp/_ipc_tmp
    ipc=$(cat /tmp/_ipc_tmp)
    if [ -n "$ipc" ] && python3 -c "exit(0 if $ipc > $BEST_IPC else 1)" 2>/dev/null; then
        BEST_IPC="$ipc"
        BEST_BIN="$bin_path"
        BEST_NAME="${pref}_d${deg}"
    fi
done
log "  B1 = $BEST_NAME, IPC = $BEST_IPC"

# Save B1 eval
"$BEST_BIN" --warmup-instructions "$WARMUP" --simulation-instructions "$SIM" "$TRACE" \
    > "$RUN_DIR/eval/b1_best.txt" 2>&1

log "  [B2] Oracle hint dispatch..."
"$BIN_DIR/champsim_hint_eval" --warmup-instructions "$WARMUP" --simulation-instructions "$SIM" \
    --hint-file "$RUN_DIR/hint.bin" "$TRACE" \
    > "$RUN_DIR/eval/b2_hint.txt" 2>&1
B2_IPC=$(grep -oP "cumulative IPC:\s*\K[\d.]+" "$RUN_DIR/eval/b2_hint.txt" | tail -1)
log "  B2 IPC = $B2_IPC"

# ── Phase E: Comparison ──
log "Phase E: Comparison..."
echo "" | tee -a "$MAIN_LOG"
python3 "$DEMO_DIR/parse_stats.py" "$RUN_DIR/eval/b0_no.txt" "$RUN_DIR/eval/b2_hint.txt" \
    | tee "$RUN_DIR/comparison_b0_vs_b2.txt" | tee -a "$MAIN_LOG"

echo "" | tee -a "$MAIN_LOG"
python3 "$DEMO_DIR/parse_stats.py" "$RUN_DIR/eval/b1_best.txt" "$RUN_DIR/eval/b2_hint.txt" \
    | tee "$RUN_DIR/comparison_b1_vs_b2.txt" | tee -a "$MAIN_LOG"

# ── Summary ──
log ""
log "══════════════════════════════════════════════════════════"
log "  SUMMARY"
log "  B0 (no prefetch):     IPC = $B0_IPC"
log "  B1 (best single):     IPC = $BEST_IPC ($BEST_NAME)"
log "  B2 (oracle hint):     IPC = $B2_IPC"
if python3 -c "exit(0 if $B2_IPC > $BEST_IPC else 1)" 2>/dev/null; then
    log "  VERDICT: B2 > B1 ✓ (per-PC oracle beats best single)"
else
    log "  VERDICT: B2 ≤ B1 (per-PC oracle does not beat best single)"
fi
log "  Run dir: $RUN_DIR"
log "══════════════════════════════════════════════════════════"
