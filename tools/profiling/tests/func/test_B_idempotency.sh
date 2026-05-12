#!/usr/bin/env bash
# Category B: Idempotency & Control Flag Tests
# Tests skip/force/dry-run behaviors on existing 400.perlbench data.
# Tests that modify files (--force) backup and restore originals.
set -euo pipefail

FUNC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(cd "$FUNC_DIR/../.." && pwd)"
MODULES_DIR="$SCRIPT_DIR/modules"
source "$SCRIPT_DIR/config.sh"

BENCH="400.perlbench"
BENCH_DIR="$DATA_ROOT/$BENCH"
PASS=true
TESTS_RUN=0
TESTS_PASS=0

pass() { echo "  [✓] $1"; ((TESTS_PASS++)) || true; }
fail() { echo "  [✗] $1"; PASS=false; }

assert_contains()   { echo "$1" | grep -q "$2"; }
assert_not_contains(){ ! echo "$1" | grep -q "$2"; }

run_test() {
    local id="$1" desc="$2"; shift 2
    ((TESTS_RUN++)) || true
    echo ""
    echo "--- $id: $desc ---"
    set +e; out=$("$@" 2>&1); rc=$?; set -e
    echo "    exit=$rc, first lines: $(echo "$out" | head -3 | tr '\n' '|')"
    LAST_RC=$rc; LAST_OUT="$out"
}

# ── B1: Module 1 skip on existing data ──────────────────────
run_test B1 "Module 1: skip when simpoints.json exists" \
    bash "$MODULES_DIR/01_parse_simpoints.sh" "$BENCH"

if [ "$LAST_RC" -eq 0 ] && assert_contains "$LAST_OUT" "SKIP"; then
    pass "B1: correctly skips with [SKIP] message"
else
    fail "B1: expected exit=0 and SKIP message"
fi

# ── B2: Module 1 --force re-run ─────────────────────────────
# Backup first
cp -p "$BENCH_DIR/simpoints.json" "$BENCH_DIR/simpoints.json.bak"
run_test B2 "Module 1: --force re-parses" \
    bash "$MODULES_DIR/01_parse_simpoints.sh" "$BENCH" --force

if [ "$LAST_RC" -eq 0 ] && assert_not_contains "$LAST_OUT" "SKIP"; then
    pass "B2: --force triggers re-run (no SKIP)"
else
    fail "B2: expected re-run without SKIP"
fi
# Restore
mv "$BENCH_DIR/simpoints.json.bak" "$BENCH_DIR/simpoints.json"

# ── B3: Module 2 skip on existing data ──────────────────────
run_test B3 "Module 2: skip when disasm_index.json exists" \
    bash "$MODULES_DIR/02_disassemble.sh" "$BENCH"

if [ "$LAST_RC" -eq 0 ] && assert_contains "$LAST_OUT" "SKIP"; then
    pass "B3: correctly skips with SKIP message"
else
    fail "B3: expected exit=0 and SKIP message"
fi

# ── B4: Module 6 freshness skip ─────────────────────────────
run_test B4 "Module 6: freshness skip (output newer than inputs)" \
    bash "$MODULES_DIR/06_aggregate_labels.sh" "$BENCH"

if [ "$LAST_RC" -eq 0 ] && assert_contains "$LAST_OUT" "up-to-date\|SKIP"; then
    pass "B4: skips when ground_truth is up-to-date"
else
    fail "B4: expected exit=0 and up-to-date/SKIP message"
fi

# ── B5: Module 6 --force re-aggregate ───────────────────────
cp -p "$BENCH_DIR/ground_truth.jsonl" "$BENCH_DIR/ground_truth.jsonl.bak"
run_test B5 "Module 6: --force re-aggregates" \
    bash "$MODULES_DIR/06_aggregate_labels.sh" "$BENCH" --force

if [ "$LAST_RC" -eq 0 ] && assert_not_contains "$LAST_OUT" "up-to-date\|SKIP"; then
    pass "B5: --force triggers re-aggregation"
else
    fail "B5: expected re-run without SKIP"
fi
mv "$BENCH_DIR/ground_truth.jsonl.bak" "$BENCH_DIR/ground_truth.jsonl"

# ── B6: Module 7 freshness skip ─────────────────────────────
run_test B6 "Module 7: freshness skip (output newer than inputs)" \
    bash "$MODULES_DIR/07_build_dataset.sh" "$BENCH"

if [ "$LAST_RC" -eq 0 ] && assert_contains "$LAST_OUT" "up-to-date\|SKIP"; then
    pass "B6: skips when tuning_dataset is up-to-date"
else
    fail "B6: expected exit=0 and up-to-date/SKIP message"
fi

# ── B7: Module 7 --force rebuild ────────────────────────────
cp -p "$BENCH_DIR/tuning_dataset.jsonl" "$BENCH_DIR/tuning_dataset.jsonl.bak"
run_test B7 "Module 7: --force rebuilds" \
    bash "$MODULES_DIR/07_build_dataset.sh" "$BENCH" --force

if [ "$LAST_RC" -eq 0 ] && assert_not_contains "$LAST_OUT" "up-to-date\|SKIP"; then
    pass "B7: --force triggers rebuild"
else
    fail "B7: expected re-run without SKIP"
fi
mv "$BENCH_DIR/tuning_dataset.jsonl.bak" "$BENCH_DIR/tuning_dataset.jsonl"

# ── B8: --dry-run makes no file changes ─────────────────────
# Touch a timestamp file, run dry-run, verify no files newer than it
marker=$(mktemp)
sleep 1
run_test B8 "Module 2: --dry-run makes no changes" \
    bash "$MODULES_DIR/02_disassemble.sh" "$BENCH" --dry-run

# Check no file in BENCH_DIR was modified after marker
if [ "$LAST_RC" -eq 0 ]; then
    changed=$(find "$BENCH_DIR" -newer "$marker" -type f 2>/dev/null | wc -l)
    if [ "$changed" -eq 0 ]; then
        pass "B8: --dry-run produced no file changes"
    else
        fail "B8: $changed files modified during --dry-run"
    fi
else
    fail "B8: --dry-run should exit 0"
fi
rm -f "$marker"

# ── B9: run_pipeline.sh --dry-run ───────────────────────────
run_test B9 "run_pipeline.sh: --dry-run" \
    bash "$SCRIPT_DIR/run_pipeline.sh" "$BENCH" --dry-run

if [ "$LAST_RC" -eq 0 ] && assert_contains "$LAST_OUT" "STAGE 1\|SKIP\|DRY-RUN"; then
    pass "B9: orchestrator --dry-run lists stages"
else
    fail "B9: orchestrator --dry-run should list stages and exit 0"
fi

echo ""
echo "──────────────────────────────────────"
echo "Category B: $TESTS_PASS/$TESTS_RUN passed"
if $PASS; then echo "Result: PASS"; exit 0; else echo "Result: FAIL"; exit 1; fi
