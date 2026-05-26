#!/bin/bash
# Stage 3: Per-PC × Context Oracle (B1 vs B2 vs B3)
# Usage: bash scripts/run_stage3.sh <trace> [warmup] [sim]

set -uo pipefail

TRACE="${1:?Usage: $0 <trace> [warmup] [sim]}"
WARMUP="${2:-1000000}"
SIM="${3:-10000000}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$ROOT/bin"
RUN_BASE="$ROOT/artifacts/runs/stage3"
PLAN_DIR="$ROOT/artifacts/plans/stage3"
STAGE1_LATEST="$ROOT/artifacts/runs/stage1/latest"
STAGE2_LATEST="$ROOT/artifacts/runs/stage2/latest"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
TRACE_NAME="$(basename "$TRACE" .champsimtrace.xz)"

PREFETCHERS=(no next_line ip_stride spp_dev va_ampm_lite)
EXTRACTORS=(page_offset delta_signature recent_pc_hash composite)
CONTEXT_FEATURES=(1 2 3 4)  # matches EXTRACTORS order

COORD_ROOT="$(cd "$ROOT/../coordinate_hint_cache" 2>/dev/null && pwd || echo "$ROOT/../coordinate_hint_cache")"

RUN_DIR="$RUN_BASE/$TIMESTAMP"
mkdir -p "$RUN_DIR" "$PLAN_DIR"
MAIN_LOG="$RUN_DIR/main.log"

# ── header ──
cat > "$MAIN_LOG" <<HEADER
══════════════════════════════════════════════════════════
  Stage 3: Per-PC × Context Oracle (B1 vs B2 vs B3)
  Trace:   $TRACE_NAME
  Warmup:  $WARMUP  Sim: $SIM
  Started: $(date '+%Y-%m-%d %H:%M:%S')
  Run dir: $RUN_DIR
  Plan:    $PLAN_DIR/PLAN.md
══════════════════════════════════════════════════════════

HEADER

# ══════════════════════════════════════════════════════════
# Step 1: Load B1 and B2 results from Stage 1 & 2
# ══════════════════════════════════════════════════════════
{
    echo "── Step 1: Load B1 (Stage 1) and B2 (Stage 2) ───────────"
} >> "$MAIN_LOG"

if [ ! -d "$STAGE1_LATEST" ]; then
    echo "  [ERROR] Stage 1 data not found at $STAGE1_LATEST" >> "$MAIN_LOG"
    exit 1
fi
if [ ! -d "$STAGE2_LATEST" ]; then
    echo "  [ERROR] Stage 2 data not found at $STAGE2_LATEST" >> "$MAIN_LOG"
    exit 1
fi

# Parse B1 results
declare -A B1_IPC B1_HR B1_PF_ACC B1_PF_ISS
BEST_B1_IPC="0"
BEST_B1_PREF=""

for pref in "${PREFETCHERS[@]}"; do
    SUB="$STAGE1_LATEST/${pref}.sub.log"
    if [ -f "$SUB" ]; then
        ipc=$(grep -oP 'IPC:\s+\K[\d.]+' "$SUB" | tail -1 || echo "N/A")
        hr=$(grep -oP 'Hit Rate:\s+\K[\d.]+' "$SUB" | tail -1 || echo "N/A")
        pf_acc=$(grep -oP 'Accuracy:\s+\K[\d.]+' "$SUB" | tail -1 || echo "N/A")
        pf_iss=$(grep -oP 'PF Issued:\s+\K[\d]+' "$SUB" | tail -1 || echo "N/A")
    else
        ipc="N/A"; hr="N/A"; pf_acc="N/A"; pf_iss="N/A"
    fi
    B1_IPC[$pref]="$ipc"
    B1_HR[$pref]="$hr"
    B1_PF_ACC[$pref]="$pf_acc"
    B1_PF_ISS[$pref]="$pf_iss"
    if [ "$ipc" != "N/A" ] && (( $(echo "$ipc > $BEST_B1_IPC" | bc -l 2>/dev/null) )); then
        BEST_B1_IPC="$ipc"
        BEST_B1_PREF="$pref"
    fi
done

# Parse B2 results
B2_IPC=$(grep -oP 'B2 IPC:\s+\K[\d.]+' "$STAGE2_LATEST/main.log" | tail -1 || echo "N/A")

{
    echo "  B1 (single policy):"
    printf "  %-16s %10s %10s %10s %10s\n" "Prefetcher" "IPC" "L1D HR" "PF Acc" "PF Issued"
    echo "  ──────────────── ────────── ────────── ────────── ──────────"
    for pref in "${PREFETCHERS[@]}"; do
        printf "  %-16s %10s %10s %10s %10s\n" "$pref" "${B1_IPC[$pref]}" "${B1_HR[$pref]}" "${B1_PF_ACC[$pref]}" "${B1_PF_ISS[$pref]}"
    done
    echo "  Best B1: $BEST_B1_PREF (IPC $BEST_B1_IPC)"
    echo ""
    echo "  B2 (per-PC Oracle): IPC $B2_IPC"
    echo ""
} >> "$MAIN_LOG"

# ══════════════════════════════════════════════════════════
# Step 2: Build context profiling binaries
# ══════════════════════════════════════════════════════════
{
    echo "── Step 2: Build context profiling binaries ───────────────"
} >> "$MAIN_LOG"

BUILD_LOG="$RUN_DIR/build.log"
OPTS_BACKUP="$ROOT/global.options.stage3.bak"
cp "$ROOT/global.options" "$OPTS_BACKUP"

# Add context profiling flag
if ! grep -q "HINT_CONTEXT_PROFILING" "$ROOT/global.options"; then
    echo "-DHINT_CONTEXT_PROFILING" >> "$ROOT/global.options"
fi

BUILD_OK=true
for pref in "${PREFETCHERS[@]}"; do
    CFG="$ROOT/configs/stage1/champsim_config_${pref}.json"
    if [ ! -f "$CFG" ]; then
        echo "  [ERROR] Config not found: $CFG" >> "$MAIN_LOG"
        BUILD_OK=false
        break
    fi
    echo "  Building champsim_${pref} (context profiling)..." >> "$BUILD_LOG"
    (cd "$ROOT" && python3 config.sh "configs/stage1/champsim_config_${pref}.json" >> "$BUILD_LOG" 2>&1 && make -j$(nproc) >> "$BUILD_LOG" 2>&1)
    if [ $? -ne 0 ]; then
        echo "  [ERROR] Build failed for champsim_${pref}" >> "$MAIN_LOG"
        BUILD_OK=false
        break
    fi
    echo "  Built: champsim_${pref}" >> "$MAIN_LOG"
done

# Restore global.options
cp "$OPTS_BACKUP" "$ROOT/global.options"
rm -f "$OPTS_BACKUP"

if [ "$BUILD_OK" = false ]; then
    echo "  [ERROR] Build failed. See $BUILD_LOG" >> "$MAIN_LOG"
    exit 1
fi
echo "" >> "$MAIN_LOG"

# ══════════════════════════════════════════════════════════
# Step 3: Run context profiling for 5 prefetchers (PARALLEL via tmux)
# ══════════════════════════════════════════════════════════
{
    echo "── Step 3: Context profiling (5 prefetchers, parallel) ───"
} >> "$MAIN_LOG"

PROF_DIR="$RUN_DIR/profiling"
mkdir -p "$PROF_DIR"

TMUX_LAUNCHER="$COORD_ROOT/.claude/skills/tmux/scripts/launch_in_tmux.sh"
PROF_SESSIONS=()

for pref in "${PREFETCHERS[@]}"; do
    BIN="$BIN_DIR/champsim_${pref}"
    OUT_RAW="$PROF_DIR/${pref}.raw"
    SESSION="s3-prof-${pref}"
    PROF_SESSIONS+=("$SESSION")

    # Kill any stale session
    tmux kill-session -t "$SESSION" 2>/dev/null || true

    echo "  Launching tmux: $SESSION → $pref" >> "$MAIN_LOG"
    bash "$TMUX_LAUNCHER" "$SESSION" bash -c "\"$BIN\" --warmup-instructions $WARMUP --simulation-instructions $SIM \"$TRACE\" > \"$OUT_RAW\" 2>&1"
done

# Wait for all tmux sessions to complete
echo "  Waiting for ${#PROF_SESSIONS[@]} profiling sessions..." >> "$MAIN_LOG"
for session in "${PROF_SESSIONS[@]}"; do
    while tmux has-session -t "$session" 2>/dev/null; do
        sleep 5
    done
    echo "    $session: done" >> "$MAIN_LOG"
done

# Collect results
for pref in "${PREFETCHERS[@]}"; do
    OUT_RAW="$PROF_DIR/${pref}.raw"
    OUT_PROFILE="$PROF_DIR/${TRACE_NAME}__${pref}__1.json"

    grep '^{' "$OUT_RAW" > "$OUT_PROFILE" 2>/dev/null || true

    PC_COUNT=$(grep -c '"pc"' "$OUT_PROFILE" 2>/dev/null || echo "0")
    CTX_COUNT=$(grep -c '"context_extractor"' "$OUT_PROFILE" 2>/dev/null || echo "0")

    echo "    ${pref}: ${PC_COUNT} per-PC + ${CTX_COUNT} context records" >> "$MAIN_LOG"
done
echo "" >> "$MAIN_LOG"

# ══════════════════════════════════════════════════════════
# Step 4: Aggregate per-(PC, context_key) for each extractor
# ══════════════════════════════════════════════════════════
{
    echo "── Step 4: Context-aware aggregation ─────────────────────"
} >> "$MAIN_LOG"

CTX_AGG_SCRIPT="$ROOT/tools/profiling/03_workers/aggregate_context_ground_truth.py"
CTX_AGG_LOG="$RUN_DIR/aggregate_context.log"
LABELS_BASE="$RUN_DIR/labels_ctx"

python3 "$CTX_AGG_SCRIPT" --profiling-dir "$PROF_DIR" --output-base "$LABELS_BASE" > "$CTX_AGG_LOG" 2>&1
AGG_EXIT=$?

if [ $AGG_EXIT -ne 0 ]; then
    echo "  [ERROR] Context aggregation failed" >> "$MAIN_LOG"
    cat "$CTX_AGG_LOG" >> "$MAIN_LOG"
    exit 1
fi

cat "$CTX_AGG_LOG" | sed 's/^/  /' >> "$MAIN_LOG"
echo "" >> "$MAIN_LOG"

# ══════════════════════════════════════════════════════════
# Step 5: Generate v2 hints.bin for each extractor
# ══════════════════════════════════════════════════════════
{
    echo "── Step 5: Generate v2 hints.bin ────────────────────────"
} >> "$MAIN_LOG"

ORACLE_SCRIPT="$COORD_ROOT/src/utils/oracle_gen.py"
declare -A HINTS_V2

for ext in "${EXTRACTORS[@]}"; do
    LABELS="$LABELS_BASE.${ext}.jsonl"
    HINTS="$RUN_DIR/hints_v2_${ext}.bin"
    HINTS_V2[$ext]="$HINTS"

    if [ ! -s "$LABELS" ]; then
        echo "  [WARN] No labels for extractor $ext" >> "$MAIN_LOG"
        continue
    fi

    python3 "$ORACLE_SCRIPT" context-profile --input "$LABELS" --output "$HINTS" >> "$MAIN_LOG" 2>&1
    if [ $? -ne 0 ]; then
        echo "  [ERROR] v2 hint generation failed for $ext" >> "$MAIN_LOG"
        continue
    fi

    if [ -f "$HINTS" ]; then
        BIN_SIZE=$(stat -c%s "$HINTS" 2>/dev/null || stat -f%z "$HINTS" 2>/dev/null)
        echo "  ${ext}: $BIN_SIZE bytes" >> "$MAIN_LOG"
    fi
done
echo "" >> "$MAIN_LOG"

# ══════════════════════════════════════════════════════════
# Step 6: Build evaluation binaries with context features
# ══════════════════════════════════════════════════════════
{
    echo "── Step 6: Build context evaluation binaries ────────────"
} >> "$MAIN_LOG"

EVAL_BUILD_LOG="$RUN_DIR/eval_build.log"
EVAL_CFG="$ROOT/configs/stage1/champsim_config_hint_eval.json"

EVAL_OK=true
for i in "${!EXTRACTORS[@]}"; do
    ext="${EXTRACTORS[$i]}"
    cf="${CONTEXT_FEATURES[$i]}"

    cp "$ROOT/global.options" "$OPTS_BACKUP"
    echo "-DCONTEXT_FEATURE=${cf}" >> "$ROOT/global.options"

    echo "  Building champsim_hint_eval_ctx_${cf} (CONTEXT_FEATURE=${cf}, ${ext})..." >> "$EVAL_BUILD_LOG"
    (cd "$ROOT" && python3 config.sh "configs/stage1/champsim_config_hint_eval.json" >> "$EVAL_BUILD_LOG" 2>&1)
    # Rename output to avoid overwriting
    # config.sh writes executable_name from JSON; we need to change it
    # Instead, just build and rename the binary
    (cd "$ROOT" && make -j$(nproc) >> "$EVAL_BUILD_LOG" 2>&1)
    if [ $? -ne 0 ]; then
        echo "  [ERROR] Build failed for CONTEXT_FEATURE=${cf}" >> "$MAIN_LOG"
        EVAL_OK=false
        cp "$OPTS_BACKUP" "$ROOT/global.options"
        rm -f "$OPTS_BACKUP"
        break
    fi

    # The binary is named champsim_hint_eval; copy to unique name
    cp "$BIN_DIR/champsim_hint_eval" "$BIN_DIR/champsim_hint_eval_ctx_${cf}"
    echo "  Built: champsim_hint_eval_ctx_${cf} (${ext})" >> "$MAIN_LOG"

    cp "$OPTS_BACKUP" "$ROOT/global.options"
    rm -f "$OPTS_BACKUP"
done

if [ "$EVAL_OK" = false ]; then
    echo "  [ERROR] Evaluation build failed. See $EVAL_BUILD_LOG" >> "$MAIN_LOG"
    exit 1
fi
echo "" >> "$MAIN_LOG"

# ══════════════════════════════════════════════════════════
# Step 7: Evaluate B3 for each extractor (PARALLEL)
# ══════════════════════════════════════════════════════════
{
    echo "── Step 7: Evaluate B3 (per-PC × context, parallel) ─────"
    echo "  Launching all 4 evaluation jobs in parallel..."
} >> "$MAIN_LOG"

declare -A B3_IPC B3_HR B3_PF_ACC B3_PF_ISS

EVAL_TMPDIR="$RUN_DIR/.eval_tmp"
mkdir -p "$EVAL_TMPDIR"

# Launch all 4 evaluation jobs in parallel
for i in "${!EXTRACTORS[@]}"; do
    ext="${EXTRACTORS[$i]}"
    cf="${CONTEXT_FEATURES[$i]}"
    HINTS="${HINTS_V2[$ext]}"
    EVAL_BIN="$BIN_DIR/champsim_hint_eval_ctx_${cf}"
    EVAL_RAW="$RUN_DIR/eval_${ext}.raw"

    if [ ! -f "$HINTS" ] || [ ! -f "$EVAL_BIN" ]; then
        echo "SKIP" > "$EVAL_TMPDIR/${ext}.skip"
        continue
    fi

    (
        START_TS=$(date +%s%N)
        "$EVAL_BIN" \
            --hint-file "$HINTS" \
            --warmup-instructions "$WARMUP" \
            --simulation-instructions "$SIM" \
            "$TRACE" \
            > "$EVAL_RAW" 2>&1
        EXIT_EVAL=$?
        END_TS=$(date +%s%N)
        ELAPSED=$(( (END_TS - START_TS) / 1000000 ))
        echo "$EXIT_EVAL" > "$EVAL_TMPDIR/${ext}.exit"
        echo "$ELAPSED" > "$EVAL_TMPDIR/${ext}.elapsed"
    ) &
done

echo "  Waiting for all 4 evaluation jobs..." >> "$MAIN_LOG"
wait

# Collect and parse results
for i in "${!EXTRACTORS[@]}"; do
    ext="${EXTRACTORS[$i]}"
    cf="${CONTEXT_FEATURES[$i]}"
    EVAL_RAW="$RUN_DIR/eval_${ext}.raw"

    if [ -f "$EVAL_TMPDIR/${ext}.skip" ]; then
        echo "  [SKIP] $ext: missing hints or binary" >> "$MAIN_LOG"
        B3_IPC[$ext]="N/A"
        continue
    fi

    EXIT_EVAL=$(cat "$EVAL_TMPDIR/${ext}.exit" 2>/dev/null || echo "?")
    ELAPSED=$(cat "$EVAL_TMPDIR/${ext}.elapsed" 2>/dev/null || echo "?")

    # Parse IPC
    ipc=$(grep -oP '(?:CPU 0 cumulative IPC|cpu0 cumulative IPC|cumulative IPC):\s*\K[\d.]+' "$EVAL_RAW" | tail -1 || echo "N/A")
    B3_IPC[$ext]="$ipc"

    # Parse L1D stats
    L1D_LINE=$(grep -oP 'cpu0_L1D\s+TOTAL\s+ACCESS:\s*\d+\s+HIT:\s*\d+\s+MISS:\s*\d+' "$EVAL_RAW" | head -1)
    if [ -n "$L1D_LINE" ]; then
        L1D_ACC=$(echo "$L1D_LINE" | grep -oP 'ACCESS:\s*\K\d+')
        L1D_HIT=$(echo "$L1D_LINE" | grep -oP 'HIT:\s*\K\d+')
        hr=$(echo "scale=4; if($L1D_ACC>0) $L1D_HIT/$L1D_ACC else 0" | bc 2>/dev/null || echo "N/A")
    else
        hr="N/A"
    fi
    B3_HR[$ext]="$hr"

    # Parse PF stats
    PF_LINE=$(grep -oP 'cpu0_L1D\s+.*PREFETCH\s+REQUESTED:\s*\d+\s+ISSUED:\s*\d+\s+USEFUL:\s*\d+\s+USELESS:\s*\d+' "$EVAL_RAW" | head -1)
    if [ -n "$PF_LINE" ]; then
        pf_iss=$(echo "$PF_LINE" | grep -oP 'ISSUED:\s*\K\d+')
        pf_use=$(echo "$PF_LINE" | grep -oP 'USEFUL:\s*\K\d+')
        pf_acc=$(echo "scale=4; if($pf_iss>0) $pf_use/$pf_iss else 0" | bc 2>/dev/null || echo "N/A")
    else
        pf_iss="N/A"; pf_acc="N/A"
    fi
    B3_PF_ACC[$ext]="$pf_acc"
    B3_PF_ISS[$ext]="$pf_iss"

    echo "    ${ext}: exit=$EXIT_EVAL  Elapsed: ${ELAPSED}ms  IPC: $ipc  HR: $hr  PF Acc: $pf_acc" >> "$MAIN_LOG"
done
rm -rf "$EVAL_TMPDIR"
echo "" >> "$MAIN_LOG"

# ══════════════════════════════════════════════════════════
# Step 8: Results comparison
# ══════════════════════════════════════════════════════════
{
    echo "────────────────────────────────────────────────────────"
    echo "  Results: B1 vs B2 vs B3"
    echo "────────────────────────────────────────────────────────"
    echo ""
    echo "  B1 (single policy):"
    printf "  %-16s %10s %10s %10s %10s\n" "Prefetcher" "IPC" "L1D HR" "PF Acc" "PF Issued"
    echo "  ──────────────── ────────── ────────── ────────── ──────────"
    for pref in "${PREFETCHERS[@]}"; do
        printf "  %-16s %10s %10s %10s %10s\n" "$pref" "${B1_IPC[$pref]}" "${B1_HR[$pref]}" "${B1_PF_ACC[$pref]}" "${B1_PF_ISS[$pref]}"
    done
    echo "  Best B1: $BEST_B1_PREF — IPC $BEST_B1_IPC"
    echo ""
    echo "  B2 (per-PC Oracle): IPC $B2_IPC"
    echo ""
    echo "  B3 (per-PC × context Oracle):"
    printf "  %-16s %10s %10s %10s %10s\n" "Extractor" "IPC" "L1D HR" "PF Acc" "PF Issued"
    echo "  ──────────────── ────────── ────────── ────────── ──────────"
    for ext in "${EXTRACTORS[@]}"; do
        printf "  %-16s %10s %10s %10s %10s\n" "$ext" "${B3_IPC[$ext]:-N/A}" "${B3_HR[$ext]:-N/A}" "${B3_PF_ACC[$ext]:-N/A}" "${B3_PF_ISS[$ext]:-N/A}"
    done
    echo ""
} >> "$MAIN_LOG"

# Primary judgment: B3 vs B2
BEST_B3_IPC="0"
BEST_B3_EXT=""
for ext in "${EXTRACTORS[@]}"; do
    ipc="${B3_IPC[$ext]:-0}"
    if [ "$ipc" != "N/A" ] && [ "$ipc" != "0" ]; then
        if (( $(echo "$ipc > $BEST_B3_IPC" | bc -l 2>/dev/null) )); then
            BEST_B3_IPC="$ipc"
            BEST_B3_EXT="$ext"
        fi
    fi
done

if [ "$BEST_B3_IPC" != "0" ] && [ "$B2_IPC" != "N/A" ]; then
    GAP_VS_B2=$(echo "scale=4; ($BEST_B3_IPC - $B2_IPC) / $B2_IPC * 100" | bc 2>/dev/null || echo "N/A")
    if (( $(echo "$BEST_B3_IPC > $B2_IPC" | bc -l 2>/dev/null) )); then
        VERDICT="PASS"
        echo "  Primary: B3-${BEST_B3_EXT} ($BEST_B3_IPC) > B2 ($B2_IPC) by ${GAP_VS_B2}% → [PASS]" >> "$MAIN_LOG"
    else
        VERDICT="FAIL"
        echo "  Primary: B3-${BEST_B3_EXT} ($BEST_B3_IPC) ≤ B2 ($B2_IPC) by ${GAP_VS_B2}% → [FAIL]" >> "$MAIN_LOG"
    fi

    # B3 vs B1
    GAP_VS_B1=$(echo "scale=4; ($BEST_B3_IPC - $BEST_B1_IPC) / $BEST_B1_IPC * 100" | bc 2>/dev/null || echo "N/A")
    echo "  B3 vs B1-best: ${GAP_VS_B1}%" >> "$MAIN_LOG"
else
    VERDICT="ERROR"
    GAP_VS_B2="N/A"
    echo "  Primary: Could not compare (B3=$BEST_B3_IPC, B2=$B2_IPC) → [ERROR]" >> "$MAIN_LOG"
fi

# ── footer ──
{
    echo ""
    echo "══════════════════════════════════════════════════════════"
    echo "  Finished: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Verdict:  $VERDICT (B3 vs B2 gap: ${GAP_VS_B2}%)"
    echo "  Run dir:  $RUN_DIR"
    echo "══════════════════════════════════════════════════════════"
} >> "$MAIN_LOG"

# ── update symlinks ──
ln -sfn "$TIMESTAMP" "$RUN_BASE/latest"
ln -sf "../../runs/stage3/latest/main.log" "$PLAN_DIR/SUMMARY.log" 2>/dev/null || true
ln -sf "../../../scripts/run_stage3.sh" "$PLAN_DIR/run_stage3.sh" 2>/dev/null || true

# ── generate CONCLUSIONS.md ──
cat > "$PLAN_DIR/CONCLUSIONS.md" <<EOF
# Stage 3 Conclusions — ${TRACE_NAME}

**Date:** $(date '+%Y-%m-%d %H:%M:%S') | **Trace:** $TRACE_NAME | **Run:** $TIMESTAMP | **Status:** Complete

## B1 Baseline (from Stage 1)

| Prefetcher | IPC | L1D Hit Rate | PF Accuracy | PF Issued |
|------------|-----|-------------|-------------|-----------|
EOF

for pref in "${PREFETCHERS[@]}"; do
    printf "| %s | %s | %s | %s | %s |\n" "$pref" "${B1_IPC[$pref]}" "${B1_HR[$pref]}" "${B1_PF_ACC[$pref]}" "${B1_PF_ISS[$pref]}" >> "$PLAN_DIR/CONCLUSIONS.md"
done

cat >> "$PLAN_DIR/CONCLUSIONS.md" <<EOF

**Best B1:** $BEST_B1_PREF — IPC $BEST_B1_IPC

## B2 Oracle Per-PC (from Stage 2)

| Metric | Value |
|--------|-------|
| IPC | $B2_IPC |

## B3 Oracle Per-PC × Context

| Extractor | IPC | L1D Hit Rate | PF Accuracy | PF Issued |
|-----------|-----|-------------|-------------|-----------|
EOF

for ext in "${EXTRACTORS[@]}"; do
    printf "| %s | %s | %s | %s | %s |\n" "$ext" "${B3_IPC[$ext]:-N/A}" "${B3_HR[$ext]:-N/A}" "${B3_PF_ACC[$ext]:-N/A}" "${B3_PF_ISS[$ext]:-N/A}" >> "$PLAN_DIR/CONCLUSIONS.md"
done

cat >> "$PLAN_DIR/CONCLUSIONS.md" <<EOF

**Best B3:** $BEST_B3_EXT — IPC $BEST_B3_IPC

## Primary Judgment

- B3 (best) IPC: $BEST_B3_IPC
- B2 IPC: $B2_IPC
- Gap vs B2: ${GAP_VS_B2}%
- Gap vs B1-best: ${GAP_VS_B1}%
- Verdict: **$VERDICT**

## Analysis

See SUMMARY.log for detailed auxiliary checks.

## Next Stage
- If PASS: context splitting provides value, proceed to production evaluation
- If FAIL: per-PC granularity is sufficient, context splitting not needed for this trace
EOF

echo "" >> "$MAIN_LOG"
echo "  Plan dir updated:" >> "$MAIN_LOG"
echo "    $PLAN_DIR/SUMMARY.log → latest run" >> "$MAIN_LOG"
echo "    $PLAN_DIR/CONCLUSIONS.md" >> "$MAIN_LOG"

echo ""
echo "Stage 3 complete: $RUN_DIR/main.log"
cat "$MAIN_LOG"
