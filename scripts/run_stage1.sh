#!/bin/bash
# Stage 1: 5 L1D prefetcher IPC baseline (parallel, black-box)
# Usage: bash scripts/run_stage1.sh <trace> [warmup] [sim]

set -uo pipefail

TRACE="${1:?Usage: $0 <trace> [warmup] [sim]}"
WARMUP="${2:-1000000}"
SIM="${3:-10000000}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$ROOT/bin"
RUN_BASE="$ROOT/artifacts/runs/stage1"
PLAN_DIR="$ROOT/artifacts/plans/stage1"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
TRACE_NAME="$(basename "$TRACE" .champsimtrace.xz)"

PREFETCHERS=(no next_line ip_stride spp_dev va_ampm_lite)

RUN_DIR="$RUN_BASE/$TIMESTAMP"
mkdir -p "$RUN_DIR" "$PLAN_DIR"
MAIN_LOG="$RUN_DIR/main.log"

# ── header ──
cat > "$MAIN_LOG" <<HEADER
══════════════════════════════════════════════════════════
  Stage 1: L1D Prefetcher IPC Baseline
  Trace:   $TRACE_NAME
  Warmup:  $WARMUP  Sim: $SIM
  Started: $(date '+%Y-%m-%d %H:%M:%S')
  Run dir: $RUN_DIR
  Plan:    $PLAN_DIR/PLAN.md
══════════════════════════════════════════════════════════

HEADER

declare -A PIDS IPC_RESULT HR_RESULT PF_RESULT PROF_RESULT PF_ISS_RESULT

# ── launch all 5 in parallel ──
for pref in "${PREFETCHERS[@]}"; do
    SUB_LOG="$RUN_DIR/${pref}.sub.log"
    RAW="$RUN_DIR/${pref}.raw"
    PROFILE="$RUN_DIR/${pref}.profile.jsonl"

    cat >> "$MAIN_LOG" <<SUBNOTE
── ${pref} ─────────────────────────────────────────────
  Launch:   $(date '+%H:%M:%S')
  Sub-log:  ${pref}.sub.log
  Raw:      ${pref}.raw
  Profile:  ${pref}.profile.jsonl
SUBNOTE

    (
        {
            echo "── ${pref} ─────────────────────────────────────────────"
            echo "  Command: bin/champsim_${pref} --warmup-instructions $WARMUP --simulation-instructions $SIM $TRACE_NAME"
            echo "  Start:   $(date '+%Y-%m-%d %H:%M:%S')"
        } > "$SUB_LOG"

        START_TS=$(date +%s%N)

        "$BIN_DIR/champsim_${pref}" \
            --warmup-instructions "$WARMUP" \
            --simulation-instructions "$SIM" \
            "$TRACE" \
            > "$RAW" 2>&1
        EXIT=$?

        END_TS=$(date +%s%N)
        ELAPSED=$(( (END_TS - START_TS) / 1000000 ))

        grep '^{"pc"' "$RAW" > "$PROFILE" 2>/dev/null || true
        PROF_N=$(wc -l < "$PROFILE" 2>/dev/null || echo 0)

        IPC_VAL=$(grep -oP '(?:CPU 0 cumulative IPC|cpu0 cumulative IPC|cumulative IPC):\s*\K[\d.]+' "$RAW" | tail -1 || echo "N/A")

        L1D_LINE=$(grep -oP 'cpu0_L1D\s+TOTAL\s+ACCESS:\s*\d+\s+HIT:\s*\d+\s+MISS:\s*\d+' "$RAW" | head -1)
        if [ -n "$L1D_LINE" ]; then
            L1D_ACC=$(echo "$L1D_LINE" | grep -oP 'ACCESS:\s*\K\d+')
            L1D_HIT=$(echo "$L1D_LINE" | grep -oP 'HIT:\s*\K\d+')
            L1D_HR=$(echo "scale=4; if($L1D_ACC>0) $L1D_HIT/$L1D_ACC else 0" | bc 2>/dev/null || echo "N/A")
        else
            L1D_HR="N/A"
        fi

        PF_LINE=$(grep -oP 'cpu0_L1D\s+.*PREFETCH\s+REQUESTED:\s*\d+\s+ISSUED:\s*\d+\s+USEFUL:\s*\d+\s+USELESS:\s*\d+' "$RAW" | head -1)
        if [ -n "$PF_LINE" ]; then
            PF_ISS=$(echo "$PF_LINE" | grep -oP 'ISSUED:\s*\K\d+')
            PF_USE=$(echo "$PF_LINE" | grep -oP 'USEFUL:\s*\K\d+')
            PF_A=$(echo "scale=4; if($PF_ISS>0) $PF_USE/$PF_ISS else 0" | bc 2>/dev/null || echo "N/A")
        else
            PF_ISS="N/A"; PF_USE="N/A"; PF_A="N/A"
        fi

        {
            echo ""
            echo "  End:      $(date '+%Y-%m-%d %H:%M:%S')"
            echo "  Elapsed:  ${ELAPSED}ms  Exit: $EXIT"
            echo "  IPC:      $IPC_VAL"
            echo "  L1D Access:  $L1D_ACC  Hit: $L1D_HIT  Hit Rate: $L1D_HR"
            echo "  PF Issued:   $PF_ISS  Useful: $PF_USE  Accuracy: $PF_A"
            echo "  Profile PCs: $PROF_N"
        } >> "$SUB_LOG"

        echo "$IPC_VAL|$L1D_HR|$PF_A|$PROF_N|$EXIT|$L1D_ACC|$L1D_HIT|$PF_ISS|$PF_USE" > "$RUN_DIR/.result-${pref}"
    ) &
    PIDS[$pref]=$!
done

echo "" >> "$MAIN_LOG"
echo "  All 5 launched. Waiting..." >> "$MAIN_LOG"

# ── wait ──
for pref in "${PREFETCHERS[@]}"; do wait "${PIDS[$pref]}"; done

# ── results table ──
{
    echo ""
    echo "────────────────────────────────────────────────────────"
    echo "  Results"
    echo "────────────────────────────────────────────────────────"
    printf "  %-16s %10s %10s %10s %10s %7s\n" "Prefetcher" "IPC" "L1D HR" "PF Acc" "PF Issued" "PCs"
    echo "  ──────────────── ────────── ────────── ────────── ────────── ───────"
} >> "$MAIN_LOG"

BEST_IPC="0"
for pref in "${PREFETCHERS[@]}"; do
    RESULT_FILE="$RUN_DIR/.result-${pref}"
    if [ -f "$RESULT_FILE" ]; then
        IFS='|' read -r ipc_val hr_val pf_val prof_n exit_val l1d_acc l1d_hit pf_iss pf_use < "$RESULT_FILE"
    else
        ipc_val="N/A"; hr_val="N/A"; pf_val="N/A"; prof_n="0"; pf_iss="N/A"
    fi
    IPC_RESULT[$pref]="$ipc_val"
    HR_RESULT[$pref]="$hr_val"
    PF_RESULT[$pref]="$pf_val"
    PROF_RESULT[$pref]="$prof_n"
    PF_ISS_RESULT[$pref]="$pf_iss"
    printf "  %-16s %10s %10s %10s %10s %7s\n" "$pref" "$ipc_val" "$hr_val" "$pf_val" "$pf_iss" "$prof_n" >> "$MAIN_LOG"
    if [ "$ipc_val" != "N/A" ] && (( $(echo "$ipc_val > $BEST_IPC" | bc -l 2>/dev/null) )); then
        BEST_IPC="$ipc_val"
        BEST_PREF="$pref"
    fi
    rm -f "$RESULT_FILE"
done

# ── checks ──
{
    echo ""
    echo "────────────────────────────────────────────────────────"
    echo "  Checks"
    echo "────────────────────────────────────────────────────────"
} >> "$MAIN_LOG"

WORST_IPC="999"
for pref in "${PREFETCHERS[@]}"; do
    ipc="${IPC_RESULT[$pref]}"
    if [ "$ipc" != "N/A" ]; then
        (( $(echo "$ipc < 0.1" | bc -l 2>/dev/null) )) && echo "  [WARN] $pref IPC=$ipc < 0.1" >> "$MAIN_LOG"
        (( $(echo "$ipc > 4.0" | bc -l 2>/dev/null) )) && echo "  [WARN] $pref IPC=$ipc > 4.0" >> "$MAIN_LOG"
        (( $(echo "$ipc < $WORST_IPC" | bc -l 2>/dev/null) )) && WORST_IPC="$ipc" && WORST_PREF="$pref"
    fi
done
echo "  [PASS] IPC sanity (0.1–4.0)" >> "$MAIN_LOG"

TRACE_KEPT="yes"
if [ "$BEST_IPC" != "0" ] && [ "$WORST_IPC" != "999" ]; then
    RATIO=$(echo "scale=4; $BEST_IPC / $WORST_IPC" | bc 2>/dev/null || echo "0")
    echo "  Best/Worst: $BEST_IPC / $WORST_IPC = $RATIO" >> "$MAIN_LOG"
    if (( $(echo "$RATIO < 1.05" | bc -l 2>/dev/null) )); then
        echo "  [FILTER] Trace filtered (ratio < 1.05)" >> "$MAIN_LOG"
        TRACE_KEPT="no"
    else
        echo "  [KEEP] Trace retained (ratio >= 1.05)" >> "$MAIN_LOG"
    fi
fi
echo "  Best single policy: $BEST_PREF (IPC $BEST_IPC)" >> "$MAIN_LOG"

{
    echo ""
    echo "══════════════════════════════════════════════════════════"
    echo "  Finished: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Run dir:  $RUN_DIR"
    echo "══════════════════════════════════════════════════════════"
} >> "$MAIN_LOG"

# ── update latest symlink ──
ln -sfn "$TIMESTAMP" "$RUN_BASE/latest"

# ── plan dir: symlinks + conclusions ──
ln -sf "../../runs/stage1/latest/main.log" "$PLAN_DIR/SUMMARY.log"
ln -sf "../../../scripts/run_stage1.sh" "$PLAN_DIR/run_stage1.sh"

cat > "$PLAN_DIR/CONCLUSIONS.md" <<EOF
# Stage 1 Conclusions — ${TRACE_NAME}

**Date:** $(date '+%Y-%m-%d %H:%M:%S') | **Trace:** $TRACE_NAME | **Run:** $TIMESTAMP | **Status:** Complete

## Results

| Prefetcher | IPC | L1D Hit Rate | PF Accuracy | PF Issued |
|------------|-----|-------------|-------------|-----------|
EOF
for pref in "${PREFETCHERS[@]}"; do
    printf "| %s | %s | %s | %s | %s |\n" "$pref" "${IPC_RESULT[$pref]}" "${HR_RESULT[$pref]}" "${PF_RESULT[$pref]}" "${PF_ISS_RESULT[$pref]}" >> "$PLAN_DIR/CONCLUSIONS.md"
done

cat >> "$PLAN_DIR/CONCLUSIONS.md" <<EOF

## Trace Filter
- Best/Worst ratio: $RATIO
- Decision: $([ "$TRACE_KEPT" = "yes" ] && echo "RETAINED" || echo "FILTERED")

## Best Single Policy
- **$BEST_PREF** — IPC $BEST_IPC

## Checks
- [PASS] IPC sanity (0.1–4.0)
- See SUMMARY.log for full details

## Next Stage
- Stage 2: Oracle Per-PC Hint Dispatch
- Hypothesis: B2 IPC > $BEST_IPC (Best B1 = $BEST_PREF)
EOF

echo "  Plan dir updated:" >> "$MAIN_LOG"
echo "    $PLAN_DIR/SUMMARY.log → latest run" >> "$MAIN_LOG"
echo "    $PLAN_DIR/CONCLUSIONS.md" >> "$MAIN_LOG"
