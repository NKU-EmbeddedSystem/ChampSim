#!/usr/bin/env bash
#
# evals/pc_match/run.sh — Verify PC matching between trace and disassembly.
#
# Usage:
#   bash run.sh <benchmark> [--trace <path>]
#
# Pass criteria: ≥ 90% of unique Load PCs from the trace are found in disasm.
#

set -euo pipefail

BENCHMARK="${1:-}"
TRACE_OVERRIDE="${2:-}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS_DIR="$SCRIPT_DIR/../.."
PROFILING_DIR="$TOOLS_DIR/profiling"

source "$PROFILING_DIR/config.sh"

if [ -z "$BENCHMARK" ]; then
    echo "Usage: $0 <benchmark>"
    echo "Example: $0 400.perlbench"
    exit 1
fi

BENCH_DIR="$DATA_ROOT/$BENCHMARK"
DISASM_INDEX="$BENCH_DIR/disasm_index.json"
LOAD_PCS_JSON="$BENCH_DIR/load_pcs.json"
RESULT_JSON="$BENCH_DIR/pc_match_result.json"

echo "=== PC Match Eval: $BENCHMARK ==="
echo ""

# ── Stage 2: Ensure disasm exists ─────────────────────────────────────────────
if [ ! -f "$DISASM_INDEX" ]; then
    echo "[1/3] Running Stage 2: disassembly ..."
    bash "$PROFILING_DIR/run_pipeline.sh" "$BENCHMARK" --stage 2
else
    echo "[1/3] Disassembly index found: $DISASM_INDEX"
fi

# ── Find a trace ──────────────────────────────────────────────────────────────
TRACES_DIR="$BENCH_DIR/traces"
if [ -n "$TRACE_OVERRIDE" ] && [ -f "$TRACE_OVERRIDE" ]; then
    TRACE="$TRACE_OVERRIDE"
elif [ -d "$TRACES_DIR" ]; then
    TRACE=$(find "$TRACES_DIR" -name "*.champsimtrace*" -type f 2>/dev/null | head -1)
fi

if [ -z "${TRACE:-}" ]; then
    echo "ERROR: No trace found. Run Stage 3 first, or pass --trace <path>."
    exit 1
fi
echo "[2/3] Using trace: $(basename "$TRACE")"

# ── Extract Load PCs and match ───────────────────────────────────────────────
echo "[3/3] Extracting Load PCs and matching against disasm ..."
python3 "$PROFILING_DIR/trace_reader.py" \
    --trace "$TRACE" \
    --output "$LOAD_PCS_JSON" \
    --max-instructions 5000000

python3 "$PROFILING_DIR/extract_assembly_context.py" \
    --index "$DISASM_INDEX" \
    --load-pcs "$LOAD_PCS_JSON" \
    --output /dev/null 2>&1 | tee /tmp/pc_match_$$.log

# ── Compute match rate ───────────────────────────────────────────────────────
matched=$(grep -oP '\d+(?= matched)' /tmp/pc_match_$$.log 2>/dev/null || echo 0)
missing=$(grep -oP '\d+(?= not found)' /tmp/pc_match_$$.log 2>/dev/null || echo 0)
total=$((matched + missing))
rate=$(python3 -c "print(f'{$matched/$total*100:.1f}')" 2>/dev/null || echo "0")

echo ""
echo "────────────────────────────────────"
echo "  Matched:  $matched / $total"
echo "  Rate:     ${rate}%"
echo "────────────────────────────────────"

# ── Pass/fail ─────────────────────────────────────────────────────────────────
THRESHOLD=90
if python3 -c "exit(0 if $matched / max($total, 1) >= $THRESHOLD / 100 else 1)" 2>/dev/null; then
    echo "  RESULT: PASS"
    echo "{\"benchmark\": \"$BENCHMARK\", \"matched\": $matched, \"total\": $total, \"rate\": $rate, \"pass\": true}" > "$RESULT_JSON"
    exit 0
else
    echo "  RESULT: FAIL (threshold: ${THRESHOLD}%)"
    echo "{\"benchmark\": \"$BENCHMARK\", \"matched\": $matched, \"total\": $total, \"rate\": $rate, \"pass\": false}" > "$RESULT_JSON"
    exit 1
fi
