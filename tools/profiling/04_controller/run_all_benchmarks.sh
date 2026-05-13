#!/usr/bin/env bash
#
# run_all_benchmarks.sh — Run profiling pipeline (stages 4-7) for all benchmarks.
#
# Usage:
#   ./run_all_benchmarks.sh                   # run all benchmarks, all stages
#   ./run_all_benchmarks.sh --stage 4         # only stage 4 for all benchmarks
#   ./run_all_benchmarks.sh --benchmarks 400.perlbench,429.mcf
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PIPELINE="$SCRIPT_DIR/run_pipeline.sh"

# Default: all benchmarks with traces ready (excluding data/batch_logs/stage_3 dirs)
BENCHMARKS=()
STAGE="all"
JOBS="${JOBS:-4}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stage) STAGE="$2"; shift 2 ;;
        --benchmarks) IFS=',' read -ra BENCHMARKS <<< "$2"; shift 2 ;;
        --jobs) JOBS="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Auto-detect benchmarks with traces if not specified
if [ ${#BENCHMARKS[@]} -eq 0 ]; then
    for d in "$SCRIPT_DIR/data/"*/; do
        name=$(basename "$d")
        # Skip non-benchmark directories
        [[ "$name" == "batch_logs" || "$name" == "stage_3" || "$name" == "data" ]] && continue
        # Check if traces exist
        if ls "$d/traces/"*.champsimtrace.xz &>/dev/null; then
            BENCHMARKS+=("$name")
        fi
    done
fi

echo "=== run_all_benchmarks.sh ==="
echo "Benchmarks (${#BENCHMARKS[@]}): ${BENCHMARKS[*]}"
echo "Stage: $STAGE"
echo "Jobs per benchmark: $JOBS"
echo ""

total=${#BENCHMARKS[@]}
done_count=0
failed=()

for bench in "${BENCHMARKS[@]}"; do
    ((done_count++)) || true
    echo ""
    echo "================================================================"
    echo "[$done_count/$total] Running $bench (stage=$STAGE)"
    echo "================================================================"

    if JOBS="$JOBS" bash "$PIPELINE" "$bench" --stage "$STAGE" 2>&1; then
        echo "[$done_count/$total] $bench: DONE"
    else
        echo "[$done_count/$total] $bench: FAILED (exit code $?)"
        failed+=("$bench")
    fi
done

echo ""
echo "=== All benchmarks processed ==="
echo "Done: $((total - ${#failed[@]}))/$total"
if [ ${#failed[@]} -gt 0 ]; then
    echo "Failed: ${failed[*]}"
fi
