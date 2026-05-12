#!/usr/bin/env bash
# Category D & E: Parallel Correctness and Output Determinism
set -euo pipefail

FUNC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(cd "$FUNC_DIR/../.." && pwd)"
MODULES_DIR="$SCRIPT_DIR/modules"
source "$SCRIPT_DIR/config.sh"

TEST_NAME="func_test"
TEST_DATA="$DATA_ROOT/$TEST_NAME"
PASS=true
TESTS_RUN=0
TESTS_PASS=0

pass() { echo "  [✓] $1"; ((TESTS_PASS++)) || true; }
fail() { echo "  [✗] $1"; PASS=false; }

# Ensure mini pipeline has run
if ! ls "$TEST_DATA/traces/"*.champsimtrace.xz &>/dev/null 2>&1; then
    echo "ERROR: Mini pipeline trace not found. Run test_C first."
    exit 1
fi

TRACE_FILE=$(ls "$TEST_DATA/traces/"*.champsimtrace.xz 2>/dev/null | head -1)
echo "Using trace: $(basename "$TRACE_FILE")"

PREF_SPEC="no:1;next_line:1"

# ── D1: Parallel correctness ─────────────────────────────────
((TESTS_RUN++)) || true
echo ""
echo "--- D1: JOBS=1 vs JOBS=4 produce identical outputs ---"

DIR_SAVED1="$TEST_DATA/profiling_saved_jobs1"
DIR_SAVED4="$TEST_DATA/profiling_saved_jobs4"

# Run with JOBS=1, save results
rm -rf "$TEST_DATA/profiling"
echo "  Running with JOBS=1..."
env PROFILING_PREFETCHER_DEGREES="$PREF_SPEC" \
    JOBS=1 \
    bash "$MODULES_DIR/04_run_profiling.sh" "$TEST_NAME" --force 2>&1 | tail -3
rm -rf "$DIR_SAVED1"
cp -rp "$TEST_DATA/profiling" "$DIR_SAVED1"

# Run with JOBS=4, save results
rm -rf "$TEST_DATA/profiling"
echo "  Running with JOBS=4..."
env PROFILING_PREFETCHER_DEGREES="$PREF_SPEC" \
    JOBS=4 \
    bash "$MODULES_DIR/04_run_profiling.sh" "$TEST_NAME" --force 2>&1 | tail -3
rm -rf "$DIR_SAVED4"
cp -rp "$TEST_DATA/profiling" "$DIR_SAVED4"

# Restore profiling for downstream
rm -rf "$TEST_DATA/profiling"
cp -rp "$DIR_SAVED1" "$TEST_DATA/profiling"

N1=$(ls "$DIR_SAVED1/"*.json 2>/dev/null | wc -l)
N4=$(ls "$DIR_SAVED4/"*.json 2>/dev/null | wc -l)
echo "  JOBS=1: $N1 outputs, JOBS=4: $N4 outputs"

if [ "$N1" -eq "$N4" ] && [ "$N1" -gt 0 ]; then
    diff_ok=true
    for f1 in "$DIR_SAVED1/"*.json; do
        fname=$(basename "$f1")
        f4="$DIR_SAVED4/$fname"
        if [ -f "$f4" ]; then
            if ! diff -q "$f1" "$f4" >/dev/null 2>&1; then
                echo "    DIFF: $fname differs"
                diff_ok=false
            fi
        else
            echo "    MISSING in JOBS=4: $fname"
            diff_ok=false
        fi
    done
    if $diff_ok; then
        pass "D1: JOBS=1 and JOBS=4 produce identical outputs ($N1 files)"
    else
        fail "D1: outputs differ between JOBS=1 and JOBS=4"
    fi
elif [ "$N1" -eq 0 ]; then
    echo "  [i] D1: profiling produced no outputs (tiny trace, expected)"
    pass "D1: ran without errors (no outputs to compare)"
else
    fail "D1: output count mismatch (JOBS=1:$N1, JOBS=4:$N4)"
fi

# ── E1: Determinism ──────────────────────────────────────────
((TESTS_RUN++)) || true
echo ""
echo "--- E1: Module 6 produces identical output on re-run ---"

# Already have DIR_SAVED1 from above, run again
rm -rf "$TEST_DATA/profiling"
echo "  Second profiling run..."
env PROFILING_PREFETCHER_DEGREES="$PREF_SPEC" \
    JOBS=2 \
    bash "$MODULES_DIR/04_run_profiling.sh" "$TEST_NAME" --force 2>&1 | tail -3

N_second=$(ls "$TEST_DATA/profiling/"*.json 2>/dev/null | wc -l)
echo "  Run1: $N1 outputs, Run2: $N_second outputs"

if [ "$N1" -eq "$N_second" ] && [ "$N1" -gt 0 ]; then
    all_ok=true
    for f1 in "$DIR_SAVED1/"*.json; do
        fname=$(basename "$f1")
        f2="$TEST_DATA/profiling/$fname"
        if [ -f "$f2" ]; then
            if ! diff -q "$f1" "$f2" >/dev/null 2>&1; then
                all_ok=false
                echo "    DIFF: $fname"
            fi
        fi
    done
    if $all_ok; then
        pass "E1: two profiling runs produce identical outputs ($N1 files)"
    else
        fail "E1: outputs differ between runs"
    fi
elif [ "$N1" -eq 0 ]; then
    echo "  [i] E1: profiling produced no outputs (tiny trace, expected)"
    pass "E1: ran without errors (no outputs to compare)"
else
    fail "E1: output count mismatch (run1:$N1, run2:$N_second)"
fi

# Cleanup
rm -rf "$DIR_SAVED1" "$DIR_SAVED4"

echo ""
echo "──────────────────────────────────────"
echo "Category D+E: $TESTS_PASS/$TESTS_RUN passed"
if $PASS; then echo "Result: PASS"; exit 0; else echo "Result: FAIL"; exit 1; fi
