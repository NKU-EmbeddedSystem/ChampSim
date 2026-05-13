#!/usr/bin/env bash
# Category A: CLI & Error Handling Tests
# Tests that each module correctly reports errors when prerequisites are missing.
# These run fast — no real computation.
set -euo pipefail

FUNC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(cd "$FUNC_DIR/../.." && pwd)"
MODULES_DIR="$SCRIPT_DIR/02_stages"
source "$SCRIPT_DIR/config.sh"

PASS=true
TESTS_RUN=0
TESTS_PASS=0

pass() { echo "  [✓] $1"; ((TESTS_PASS++)) || true; }
fail() { echo "  [✗] $1"; PASS=false; }

run_test() {
    local id="$1" desc="$2"; shift 2
    ((TESTS_RUN++)) || true
    echo ""
    echo "--- $id: $desc ---"
    local out rc
    set +e; out=$("$@" 2>&1); rc=$?; set -e
    echo "    stderr/stdout (first 3 lines): $(echo "$out" | head -3 | tr '\n' '|')"
    echo "    exit code: $rc"
    # Return rc and out for caller inspection
    # We use global vars
    LAST_RC=$rc
    LAST_OUT="$out"
}

# ── A1: Module 1 with missing tarball ───────────────────────
run_test A1 "Module 1: missing tarball" \
    bash "$MODULES_DIR/01_parse_simpoints.sh" func_test_nonexist

if [ "$LAST_RC" -ne 0 ] && echo "$LAST_OUT" | grep -qi "tarball\|not found\|SIMPOINTS"; then
    pass "A1: correct error for missing tarball"
else
    fail "A1: expected exit!=0 and tarball error message"
fi

# ── A2: Module 2 with invalid BINARY_PATH ───────────────────
# Use unique benchmark name to avoid collision with A3
rm -rf "$DATA_ROOT/func_test_A2_invalid"
run_test A2 "Module 2: invalid BINARY_PATH" \
    env BINARY_PATH=/tmp/nonexistent_binary_xyz \
    bash "$MODULES_DIR/02_disassemble.sh" func_test_A2_invalid

if [ "$LAST_RC" -ne 0 ] && echo "$LAST_OUT" | grep -qi "not found\|ERROR"; then
    pass "A2: correct error for invalid binary path"
else
    fail "A2: expected exit!=0 and 'not found' error"
fi

# ── A3: Module 2 with valid BINARY_PATH (gcc itself) ────────
rm -rf "$DATA_ROOT/func_test_A3_gcc"
if [ -x /usr/bin/gcc ]; then
    run_test A3 "Module 2: valid BINARY_PATH override" \
        env BINARY_PATH=/usr/bin/gcc \
        bash "$MODULES_DIR/02_disassemble.sh" func_test_A3_gcc

    if [ "$LAST_RC" -eq 0 ]; then
        pass "A3: BINARY_PATH override works"
    else
        fail "A3: expected exit=0 with valid BINARY_PATH"
    fi
else
    echo "  [-] A3: skipped (gcc not found)"
fi
rm -rf "$DATA_ROOT/func_test_A3_gcc"

# ── A4: Module 3 without simpoints.json ─────────────────────
run_test A4 "Module 3: missing simpoints.json" \
    bash "$MODULES_DIR/03_generate_traces.sh" func_test_nonexist

if [ "$LAST_RC" -ne 0 ] && echo "$LAST_OUT" | grep -qi "simpoints\|module 01\|Run module"; then
    pass "A4: correct error for missing simpoints.json"
else
    fail "A4: expected exit!=0 and 'simpoints/module 01' error"
fi

# ── A5: Module 4 without traces ─────────────────────────────
run_test A5 "Module 4: missing traces" \
    bash "$MODULES_DIR/04_run_profiling.sh" func_test_nonexist

if [ "$LAST_RC" -ne 0 ] && echo "$LAST_OUT" | grep -qi "trace\|Run module 03\|No traces"; then
    pass "A5: correct error for missing traces"
else
    fail "A5: expected exit!=0 and 'traces/module 03' error"
fi

# ── A6: Module 5 without disasm ─────────────────────────────
run_test A6 "Module 5: missing disasm_index.json" \
    bash "$MODULES_DIR/05_extract_context.sh" func_test_nonexist

if [ "$LAST_RC" -ne 0 ] && echo "$LAST_OUT" | grep -qi "disasm\|module 02\|Run module"; then
    pass "A6: correct error for missing disasm"
else
    fail "A6: expected exit!=0 and 'disasm/module 02' error"
fi

# ── A7: Module 6 without profiling ──────────────────────────
run_test A7 "Module 6: missing profiling directory" \
    bash "$MODULES_DIR/06_aggregate_labels.sh" func_test_nonexist

if [ "$LAST_RC" -ne 0 ] && echo "$LAST_OUT" | grep -qi "profiling\|module 04\|Run module\|not found"; then
    pass "A7: correct error for missing profiling"
else
    fail "A7: expected exit!=0 and 'profiling/module 04' error"
fi

# ── A8: Module 7 without context or labels ──────────────────
run_test A8 "Module 7: missing assembly_context.jsonl" \
    bash "$MODULES_DIR/07_build_dataset.sh" func_test_nonexist

if [ "$LAST_RC" -ne 0 ] && echo "$LAST_OUT" | grep -qi "assembly_context\|module 05\|Run module\|not found"; then
    pass "A8: correct error for missing context"
else
    fail "A8: expected exit!=0 and 'assembly_context/module 05' error"
fi

echo ""
echo "──────────────────────────────────────"
echo "Category A: $TESTS_PASS/$TESTS_RUN passed"
if $PASS; then echo "Result: PASS"; exit 0; else echo "Result: FAIL"; exit 1; fi
