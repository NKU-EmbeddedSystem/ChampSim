#!/bin/bash
# Stage 2: Oracle Per-PC Hint Dispatch (B1 vs B2)
# Usage: bash scripts/run_stage2.sh <trace> [warmup] [sim]

set -uo pipefail

TRACE="${1:?Usage: $0 <trace> [warmup] [sim]}"
WARMUP="${2:-1000000}"
SIM="${3:-10000000}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$ROOT/bin"
RUN_BASE="$ROOT/artifacts/runs/stage2"
PLAN_DIR="$ROOT/artifacts/plans/stage2"
STAGE1_LATEST="$ROOT/artifacts/runs/stage1/latest"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
TRACE_NAME="$(basename "$TRACE" .champsimtrace.xz)"

PREFETCHERS=(no next_line ip_stride spp_dev va_ampm_lite)

# Prefetcher name → index mapping (must match hint_dispatch.cc)
declare -A PREF_INDEX=([no]=0 [next_line]=1 [ip_stride]=2 [spp_dev]=3 [va_ampm_lite]=4)

RUN_DIR="$RUN_BASE/$TIMESTAMP"
mkdir -p "$RUN_DIR" "$PLAN_DIR"
MAIN_LOG="$RUN_DIR/main.log"

# ── header ──
cat > "$MAIN_LOG" <<HEADER
══════════════════════════════════════════════════════════
  Stage 2: Oracle Per-PC Hint Dispatch (B1 vs B2)
  Trace:   $TRACE_NAME
  Warmup:  $WARMUP  Sim: $SIM
  Started: $(date '+%Y-%m-%d %H:%M:%S')
  Run dir: $RUN_DIR
  Plan:    $PLAN_DIR/PLAN.md
══════════════════════════════════════════════════════════

HEADER

# ══════════════════════════════════════════════════════════
# Step 1: Load B1 results from Stage 1
# ══════════════════════════════════════════════════════════
{
    echo "── Step 1: Load B1 from Stage 1 ─────────────────────────"
    echo "  Source: $STAGE1_LATEST"
} >> "$MAIN_LOG"

if [ ! -d "$STAGE1_LATEST" ]; then
    echo "  [ERROR] Stage 1 data not found at $STAGE1_LATEST" >> "$MAIN_LOG"
    echo "  Run Stage 1 first: bash scripts/run_stage1.sh $TRACE" >> "$MAIN_LOG"
    exit 1
fi

# Parse B1 results from stage1 sub-logs
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

{
    echo "  B1 results loaded:"
    printf "  %-16s %10s %10s %10s %10s\n" "Prefetcher" "IPC" "L1D HR" "PF Acc" "PF Issued"
    echo "  ──────────────── ────────── ────────── ────────── ──────────"
    for pref in "${PREFETCHERS[@]}"; do
        printf "  %-16s %10s %10s %10s %10s\n" "$pref" "${B1_IPC[$pref]}" "${B1_HR[$pref]}" "${B1_PF_ACC[$pref]}" "${B1_PF_ISS[$pref]}"
    done
    echo ""
    echo "  Best B1: $BEST_B1_PREF (IPC $BEST_B1_IPC)"
    echo ""
} >> "$MAIN_LOG"

# ══════════════════════════════════════════════════════════
# Step 2: Prepare profiling data for aggregation
# ══════════════════════════════════════════════════════════
{
    echo "── Step 2: Prepare profiling data ───────────────────────"
} >> "$MAIN_LOG"

PREP_DIR="$RUN_DIR/profiling_input"
mkdir -p "$PREP_DIR"
PREP_LOG="$RUN_DIR/prepare.log"

for pref in "${PREFETCHERS[@]}"; do
    SRC="$STAGE1_LATEST/${pref}.profile.jsonl"
    DST="$PREP_DIR/${TRACE_NAME}__${pref}__1.json"
    if [ -f "$SRC" ]; then
        cp "$SRC" "$DST"
        PC_COUNT=$(wc -l < "$DST")
        echo "  Copied: ${pref}.profile.jsonl → ${TRACE_NAME}__${pref}__1.json ($PC_COUNT PCs)" >> "$MAIN_LOG"
        echo "  $SRC → $DST ($PC_COUNT PCs)" >> "$PREP_LOG"
    else
        echo "  [WARN] Missing: $SRC" >> "$MAIN_LOG"
        echo "  [WARN] Missing: $SRC" >> "$PREP_LOG"
    fi
done
echo "" >> "$MAIN_LOG"

# ══════════════════════════════════════════════════════════
# Step 3: Aggregate — per-PC best prefetcher
# ══════════════════════════════════════════════════════════
{
    echo "── Step 3: Aggregate ground truth ───────────────────────"
} >> "$MAIN_LOG"

LABELS="$RUN_DIR/labels.jsonl"
AGG_LOG="$RUN_DIR/aggregate.log"

AGG_SCRIPT="$ROOT/tools/profiling/03_workers/aggregate_ground_truth.py"

if [ ! -f "$AGG_SCRIPT" ]; then
    # Fallback: check coordinate_hint_cache
    COORD_ROOT="$(cd "$ROOT/../coordinate_hint_cache" 2>/dev/null && pwd || echo "")"
    if [ -n "$COORD_ROOT" ]; then
        AGG_SCRIPT="$COORD_ROOT/ChampSim/tools/profiling/03_workers/aggregate_ground_truth.py"
    fi
fi

python3 "$AGG_SCRIPT" --profiling-dir "$PREP_DIR" --output "$LABELS" > "$AGG_LOG" 2>&1
AGG_EXIT=$?

{
    echo "  Script:  $AGG_SCRIPT"
    echo "  Exit:    $AGG_EXIT"
    echo "  Output:  $LABELS"
    if [ -f "$LABELS" ]; then
        LABEL_COUNT=$(wc -l < "$LABELS")
        echo "  Labels:  $LABEL_COUNT PCs"
    fi
    echo ""
    echo "  Distribution:"
    grep -A10 "Best prefetch distribution" "$AGG_LOG" 2>/dev/null | sed 's/^/  /'
    echo ""
} >> "$MAIN_LOG"

if [ $AGG_EXIT -ne 0 ] || [ ! -s "$LABELS" ]; then
    echo "  [ERROR] Aggregation failed or produced empty output" >> "$MAIN_LOG"
    cat "$AGG_LOG" >> "$MAIN_LOG"
    exit 1
fi

# ══════════════════════════════════════════════════════════
# Step 4: Convert labels (string → index)
# ══════════════════════════════════════════════════════════
{
    echo "── Step 4: Convert labels to indexed format ─────────────"
} >> "$MAIN_LOG"

LABELS_IDX="$RUN_DIR/labels_indexed.jsonl"

python3 -c "
import json, sys
sys.path.insert(0, '$ROOT/../coordinate_hint_cache/src')
from coordinate_hint_cache.utils.policy_registry import prefetch_name_to_index

count = 0
with open('$LABELS') as fin, open('$LABELS_IDX', 'w') as fout:
    for line in fin:
        line = line.strip()
        if not line:
            continue
        rec = json.loads(line)
        pref_name = rec.get('best_prefetch', 'no')
        idx = prefetch_name_to_index(pref_name, default=0)
        entry = {
            'pc': rec['pc'],
            'best_replacement': 'lru',
            'best_prefetch': pref_name,
            'prefetch_degree': rec.get('best_degree', 1),
            'demand_filter': 0
        }
        fout.write(json.dumps(entry) + '\n')
        count += 1

print(f'Converted {count} labels')
" >> "$MAIN_LOG" 2>&1

if [ ! -s "$LABELS_IDX" ]; then
    echo "  [ERROR] Label conversion failed" >> "$MAIN_LOG"
    exit 1
fi

IDX_COUNT=$(wc -l < "$LABELS_IDX")
echo "  Indexed labels: $IDX_COUNT entries" >> "$MAIN_LOG"
echo "" >> "$MAIN_LOG"

# ══════════════════════════════════════════════════════════
# Step 5: Generate hints.bin
# ══════════════════════════════════════════════════════════
{
    echo "── Step 5: Generate hints.bin ───────────────────────────"
} >> "$MAIN_LOG"

HINTS_BIN="$RUN_DIR/hints.bin"
HINT_GEN_LOG="$RUN_DIR/hint_gen.log"

ORACLE_SCRIPT="$ROOT/../coordinate_hint_cache/src/utils/oracle_gen.py"
if [ ! -f "$ORACLE_SCRIPT" ]; then
    # Try absolute fallback
    ORACLE_SCRIPT="$(cd "$ROOT/.." 2>/dev/null && pwd)/coordinate_hint_cache/src/utils/oracle_gen.py"
fi

python3 "$ORACLE_SCRIPT" profile --input "$LABELS_IDX" --output "$HINTS_BIN" > "$HINT_GEN_LOG" 2>&1
HINT_EXIT=$?

{
    echo "  Script:  $ORACLE_SCRIPT"
    echo "  Exit:    $HINT_EXIT"
    echo "  Output:  $HINTS_BIN"
    if [ -f "$HINTS_BIN" ]; then
        BIN_SIZE=$(stat -c%s "$HINTS_BIN" 2>/dev/null || stat -f%z "$HINTS_BIN" 2>/dev/null)
        echo "  Size:    $BIN_SIZE bytes"
    fi
    cat "$HINT_GEN_LOG" | sed 's/^/  /'
    echo ""
} >> "$MAIN_LOG"

if [ $HINT_EXIT -ne 0 ] || [ ! -s "$HINTS_BIN" ]; then
    echo "  [ERROR] Hint generation failed" >> "$MAIN_LOG"
    exit 1
fi

# ══════════════════════════════════════════════════════════
# Step 6: Evaluate with hint_dispatch
# ══════════════════════════════════════════════════════════
{
    echo "── Step 6: Evaluate B2 (hint_dispatch) ──────────────────"
    echo "  Binary:  $BIN_DIR/champsim_hint_eval"
    echo "  Hints:   $HINTS_BIN"
    echo "  Trace:   $TRACE"
    echo "  Start:   $(date '+%H:%M:%S')"
} >> "$MAIN_LOG"

EVAL_RAW="$RUN_DIR/eval.raw"
EVAL_SUB="$RUN_DIR/eval.sub.log"
EVAL_PROFILE="$RUN_DIR/eval.profile.jsonl"

{
    echo "── B2 Evaluation ─────────────────────────────────────────"
    echo "  Command: champsim_hint_eval --hint-file $HINTS_BIN --warmup-instructions $WARMUP --simulation-instructions $SIM $TRACE"
    echo "  Start:   $(date '+%Y-%m-%d %H:%M:%S')"
} > "$EVAL_SUB"

START_TS=$(date +%s%N)

"$BIN_DIR/champsim_hint_eval" \
    --hint-file "$HINTS_BIN" \
    --warmup-instructions "$WARMUP" \
    --simulation-instructions "$SIM" \
    "$TRACE" \
    > "$EVAL_RAW" 2>&1
EXIT_EVAL=$?

END_TS=$(date +%s%N)
ELAPSED=$(( (END_TS - START_TS) / 1000000 ))

# Extract profiling JSONL from raw output
grep '^{"pc"' "$EVAL_RAW" > "$EVAL_PROFILE" 2>/dev/null || true
PROF_N=$(wc -l < "$EVAL_PROFILE" 2>/dev/null || echo 0)

# Parse B2 IPC
B2_IPC=$(grep -oP '(?:CPU 0 cumulative IPC|cpu0 cumulative IPC|cumulative IPC):\s*\K[\d.]+' "$EVAL_RAW" | tail -1 || echo "N/A")

# Parse L1D stats
L1D_LINE=$(grep -oP 'cpu0_L1D\s+TOTAL\s+ACCESS:\s*\d+\s+HIT:\s*\d+\s+MISS:\s*\d+' "$EVAL_RAW" | head -1)
if [ -n "$L1D_LINE" ]; then
    L1D_ACC=$(echo "$L1D_LINE" | grep -oP 'ACCESS:\s*\K\d+')
    L1D_HIT=$(echo "$L1D_LINE" | grep -oP 'HIT:\s*\K\d+')
    B2_HR=$(echo "scale=4; if($L1D_ACC>0) $L1D_HIT/$L1D_ACC else 0" | bc 2>/dev/null || echo "N/A")
else
    L1D_ACC="N/A"; L1D_HIT="N/A"; B2_HR="N/A"
fi

# Parse PF stats
PF_LINE=$(grep -oP 'cpu0_L1D\s+.*PREFETCH\s+REQUESTED:\s*\d+\s+ISSUED:\s*\d+\s+USEFUL:\s*\d+\s+USELESS:\s*\d+' "$EVAL_RAW" | head -1)
if [ -n "$PF_LINE" ]; then
    B2_PF_ISS=$(echo "$PF_LINE" | grep -oP 'ISSUED:\s*\K\d+')
    B2_PF_USE=$(echo "$PF_LINE" | grep -oP 'USEFUL:\s*\K\d+')
    B2_PF_ACC=$(echo "scale=4; if($B2_PF_ISS>0) $B2_PF_USE/$B2_PF_ISS else 0" | bc 2>/dev/null || echo "N/A")
else
    B2_PF_ISS="N/A"; B2_PF_USE="N/A"; B2_PF_ACC="N/A"
fi

{
    echo ""
    echo "  End:      $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Elapsed:  ${ELAPSED}ms  Exit: $EXIT_EVAL"
    echo "  IPC:      $B2_IPC"
    echo "  L1D Access:  $L1D_ACC  Hit: $L1D_HIT  Hit Rate: $B2_HR"
    echo "  PF Issued:   $B2_PF_ISS  Useful: $B2_PF_USE  Accuracy: $B2_PF_ACC"
    echo "  Profile PCs: $PROF_N"
} >> "$EVAL_SUB"

{
    echo "  End:     $(date '+%H:%M:%S')"
    echo "  Elapsed: ${ELAPSED}ms  Exit: $EXIT_EVAL"
    echo "  B2 IPC:  $B2_IPC"
    echo ""
} >> "$MAIN_LOG"

# ══════════════════════════════════════════════════════════
# Step 7: Results comparison & checks
# ══════════════════════════════════════════════════════════
{
    echo "────────────────────────────────────────────────────────"
    echo "  Results: B1 vs B2"
    echo "────────────────────────────────────────────────────────"
    echo ""
    echo "  B1 (single policy):"
    printf "  %-16s %10s %10s %10s %10s\n" "Prefetcher" "IPC" "L1D HR" "PF Acc" "PF Issued"
    echo "  ──────────────── ────────── ────────── ────────── ──────────"
    for pref in "${PREFETCHERS[@]}"; do
        printf "  %-16s %10s %10s %10s %10s\n" "$pref" "${B1_IPC[$pref]}" "${B1_HR[$pref]}" "${B1_PF_ACC[$pref]}" "${B1_PF_ISS[$pref]}"
    done
    echo ""
    echo "  Best B1: $BEST_B1_PREF — IPC $BEST_B1_IPC"
    echo ""
    echo "  B2 (Oracle Per-PC Hint Dispatch):"
    printf "  %-16s %10s %10s %10s %10s\n" "hint_dispatch" "$B2_IPC" "$B2_HR" "$B2_PF_ACC" "$B2_PF_ISS"
    echo ""
} >> "$MAIN_LOG"

# Primary judgment
if [ "$B2_IPC" != "N/A" ] && [ "$BEST_B1_IPC" != "0" ]; then
    GAP=$(echo "scale=4; ($B2_IPC - $BEST_B1_IPC) / $BEST_B1_IPC * 100" | bc 2>/dev/null || echo "N/A")
    if (( $(echo "$B2_IPC > $BEST_B1_IPC" | bc -l 2>/dev/null) )); then
        VERDICT="PASS"
        echo "  Primary: B2 ($B2_IPC) > Best-B1 ($BEST_B1_IPC) by ${GAP}% → [PASS]" >> "$MAIN_LOG"
    elif (( $(echo "$B2_IPC == $BEST_B1_IPC" | bc -l 2>/dev/null) )); then
        VERDICT="TIE"
        echo "  Primary: B2 ($B2_IPC) == Best-B1 ($BEST_B1_IPC) → [TIE]" >> "$MAIN_LOG"
    else
        VERDICT="FAIL"
        echo "  Primary: B2 ($B2_IPC) < Best-B1 ($BEST_B1_IPC) by ${GAP}% → [FAIL]" >> "$MAIN_LOG"
    fi
else
    VERDICT="ERROR"
    GAP="N/A"
    echo "  Primary: Could not compare (B2=$B2_IPC, B1=$BEST_B1_IPC) → [ERROR]" >> "$MAIN_LOG"
fi

# ── Auxiliary checks ──
{
    echo ""
    echo "────────────────────────────────────────────────────────"
    echo "  Auxiliary Checks"
    echo "────────────────────────────────────────────────────────"
} >> "$MAIN_LOG"

# Check 1: Prefetcher distribution
echo "" >> "$MAIN_LOG"
echo "  [Check 1] Prefetcher selection distribution:" >> "$MAIN_LOG"
grep -A10 "Best prefetch distribution" "$AGG_LOG" 2>/dev/null | sed 's/^/    /' >> "$MAIN_LOG"
DOMINANT_PCT=$(grep -A1 "Best prefetch distribution" "$AGG_LOG" 2>/dev/null | tail -1 | grep -oP '\(([\d.]+)%\)' | grep -oP '[\d.]+' || echo "0")
if (( $(echo "$DOMINANT_PCT > 90" | bc -l 2>/dev/null) )); then
    echo "    [NOTE] Dominant prefetcher >90% — B2 ≈ single policy, small gap expected" >> "$MAIN_LOG"
fi

# Check 2: PF accuracy B2 vs B1-best
echo "" >> "$MAIN_LOG"
B1_BEST_PF_ACC="${B1_PF_ACC[$BEST_B1_PREF]}"
echo "  [Check 2] PF Accuracy: B2=$B2_PF_ACC vs B1-best($BEST_B1_PREF)=$B1_BEST_PF_ACC" >> "$MAIN_LOG"
if [ "$B2_PF_ACC" != "N/A" ] && [ "$B1_BEST_PF_ACC" != "N/A" ]; then
    if (( $(echo "$B2_PF_ACC >= $B1_BEST_PF_ACC" | bc -l 2>/dev/null) )); then
        echo "    [PASS] B2 accuracy >= B1-best accuracy" >> "$MAIN_LOG"
    else
        echo "    [WARN] B2 accuracy < B1-best accuracy" >> "$MAIN_LOG"
    fi
fi

# Check 3: Dispatch correctness (sample check via Python)
echo "" >> "$MAIN_LOG"
echo "  [Check 3] Dispatch correctness (profiler vs hints.bin):" >> "$MAIN_LOG"
if [ -s "$EVAL_PROFILE" ] && [ -s "$HINTS_BIN" ]; then
    python3 -c "
import json, struct, sys
sys.path.insert(0, '$ROOT/../coordinate_hint_cache/src')
from coordinate_hint_cache.utils.policy_registry import prefetch_index_to_name

HINT_MAGIC = 0x544E4948
ENTRY_STRUCT = struct.Struct('<QBBBB4x')

# Load hints.bin
hints = {}
with open('$HINTS_BIN', 'rb') as f:
    magic, version, count, reserved = struct.unpack('<IIII', f.read(16))
    for _ in range(count):
        pc, repl_idx, pref_idx, degree, demand_filter = ENTRY_STRUCT.unpack(f.read(16))
        hints[pc] = prefetch_index_to_name(pref_idx, default='unknown')

# Load profiler output
match = 0
mismatch = 0
not_activated = 0
not_in_hints = 0
total = 0
with open('$EVAL_PROFILE') as f:
    for line in f:
        rec = json.loads(line.strip())
        pc = int(rec['pc'], 16)
        prof_policy = rec.get('active_prefetch_policy', 'unknown')
        hint_policy = hints.get(pc, None)
        total += 1
        if hint_policy is None:
            not_in_hints += 1
        elif prof_policy == 'unknown':
            not_activated += 1
        elif prof_policy == hint_policy:
            match += 1
        else:
            mismatch += 1

print(f'    Total PCs profiled: {total}')
print(f'    In hints.bin:       {total - not_in_hints}')
print(f'    Prefetcher activated: {match + mismatch}')
print(f'    Not activated (unknown): {not_activated}')
print(f'    Match:              {match}')
print(f'    Mismatch:           {mismatch}')
if mismatch == 0 and match > 0:
    print('    [PASS] All activated dispatches correct')
elif mismatch == 0 and match == 0:
    print('    [SKIP] No prefetcher was activated in sample')
else:
    print(f'    [WARN] {mismatch} mismatches out of {match + mismatch} activated PCs')
" >> "$MAIN_LOG" 2>&1
else
    echo "    [SKIP] Missing eval profile or hints.bin" >> "$MAIN_LOG"
fi

# Check 4: PF volume B2 vs B1-best
echo "" >> "$MAIN_LOG"
B1_BEST_PF_ISS="${B1_PF_ISS[$BEST_B1_PREF]}"
echo "  [Check 4] PF Volume: B2=$B2_PF_ISS vs B1-best($BEST_B1_PREF)=$B1_BEST_PF_ISS" >> "$MAIN_LOG"
if [ "$B2_PF_ISS" != "N/A" ] && [ "$B1_BEST_PF_ISS" != "N/A" ] && [ "$B1_BEST_PF_ISS" != "0" ]; then
    PF_RATIO=$(echo "scale=2; $B2_PF_ISS / $B1_BEST_PF_ISS" | bc 2>/dev/null || echo "N/A")
    echo "    Ratio: ${PF_RATIO}x" >> "$MAIN_LOG"
    if (( $(echo "$PF_RATIO > 5.0" | bc -l 2>/dev/null) )); then
        echo "    [WARN] B2 PF volume > 5x B1-best" >> "$MAIN_LOG"
    else
        echo "    [PASS] PF volume reasonable" >> "$MAIN_LOG"
    fi
fi

# ── footer ──
{
    echo ""
    echo "══════════════════════════════════════════════════════════"
    echo "  Finished: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "  Verdict:  $VERDICT (gap: ${GAP}%)"
    echo "  Run dir:  $RUN_DIR"
    echo "══════════════════════════════════════════════════════════"
} >> "$MAIN_LOG"

# ── update symlinks ──
ln -sfn "$TIMESTAMP" "$RUN_BASE/latest"
ln -sf "../../runs/stage2/latest/main.log" "$PLAN_DIR/SUMMARY.log"
ln -sf "../../../scripts/run_stage2.sh" "$PLAN_DIR/run_stage2.sh"

# ── generate CONCLUSIONS.md ──
cat > "$PLAN_DIR/CONCLUSIONS.md" <<EOF
# Stage 2 Conclusions — ${TRACE_NAME}

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

## B2 Oracle Per-PC Hint Dispatch

| Metric | Value |
|--------|-------|
| IPC | $B2_IPC |
| L1D Hit Rate | $B2_HR |
| PF Accuracy | $B2_PF_ACC |
| PF Issued | $B2_PF_ISS |
| Profile PCs | $PROF_N |

## Primary Judgment

- B2 IPC: $B2_IPC
- Best-B1 IPC: $BEST_B1_IPC
- Gap: ${GAP}%
- Verdict: **$VERDICT**

## Auxiliary Checks

See SUMMARY.log for detailed check results.

## Next Stage
- If PASS: proceed to Stage 3 (diagnostic analysis) or Stage 4 (context splitting)
- If FAIL: Stage 3 root-cause analysis required
EOF

echo "" >> "$MAIN_LOG"
echo "  Plan dir updated:" >> "$MAIN_LOG"
echo "    $PLAN_DIR/SUMMARY.log → latest run" >> "$MAIN_LOG"
echo "    $PLAN_DIR/CONCLUSIONS.md" >> "$MAIN_LOG"
