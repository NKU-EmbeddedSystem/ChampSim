#!/usr/bin/env bash
# Run all verification tests for the profiling pipeline.
#
# Usage:
#   ./tests/test_all.sh <benchmark>
#   ./tests/test_all.sh 400.perlbench
set -euo pipefail

BENCHMARK="${1:-}"
if [ -z "$BENCHMARK" ]; then
    echo "Usage: $0 <benchmark>"
    echo "Example: $0 400.perlbench"
    exit 1
fi

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo "╔══════════════════════════════════════╗"
echo "║  Profiling Pipeline Test Suite       ║"
echo "║  Benchmark: $BENCHMARK"
echo "╚══════════════════════════════════════╝"
echo ""

declare -A results=()
overall_pass=true

run_test() {
    local num="$1"
    local name="$2"
    local script="$TEST_DIR/test_0${num}_${name}.sh"

    echo "──────────────────────────────────────"
    if [ ! -f "$script" ]; then
        echo "[SKIP] Test 0${num}: ${name} — script not found"
        results["$num"]="SKIP"
        return
    fi

    if bash "$script" "$BENCHMARK"; then
        results["$num"]="PASS"
    else
        results["$num"]="FAIL"
        overall_pass=false
    fi
    echo ""
}

run_test 1 "simpoints"
run_test 2 "disassemble"
run_test 3 "traces"
run_test 4 "profiling"
run_test 5 "context"
run_test 6 "labels"
run_test 7 "dataset"

echo "╔══════════════════════════════════════╗"
echo "║  Test Results                        ║"
echo "╚══════════════════════════════════════╝"
echo ""

names=(
    "1: SimPoints"
    "2: Disassembly"
    "3: Traces"
    "4: Profiling"
    "5: Context"
    "6: Labels"
    "7: Dataset"
)

for i in $(seq 1 7); do
    status="${results[$i]:-SKIP}"

    case "$status" in
        PASS) echo "  [✓] Stage ${names[$((i-1))]}" ;;
        FAIL) echo "  [✗] Stage ${names[$((i-1))]}" ;;
        SKIP) echo "  [-] Stage ${names[$((i-1))]} (skipped)" ;;
    esac
done

echo ""

if $overall_pass; then
    echo "All tests passed."
    exit 0
else
    echo "Some tests FAILED. See above for details."
    exit 1
fi
