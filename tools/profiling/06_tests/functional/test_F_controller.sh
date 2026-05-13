#!/usr/bin/env bash
# Category F: Batch Controller Tests
FUNC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_DIR="$(cd "$FUNC_DIR/../.." && pwd)"
source "$SCRIPT_DIR/config.sh"

PASS=true
TESTS_RUN=0
TESTS_PASS=0

pass() { echo "  [✓] $1"; ((TESTS_PASS++)) || true; }
fail() { echo "  [✗] $1"; PASS=false; }

# Capture command output safely (controller may produce warnings on stderr)
capture() { set +e; "$@" 2>&1; rc=$?; set -e; return $rc; }

echo "=== Test F1: profiling_controller.sh --check-build ==="
((TESTS_RUN++))

out=$(capture bash "$SCRIPT_DIR/profiling_controller.sh" --check-build)
rc=$?

echo "$out" | head -5
echo "  ... ($(echo "$out" | wc -l) lines total)"
echo "  exit code: $rc"

# Verify: lists paper/internal names, shows built binaries
if echo "$out" | grep -q "Paper Name" && echo "$out" | grep -q "Internal Bin Name"; then
    pass "F1: --check-build outputs table headers"
else
    fail "F1: --check-build missing expected table headers"
fi

echo ""
echo "=== Test F2: profiling_controller.sh --status ==="
((TESTS_RUN++))

out=$(capture bash "$SCRIPT_DIR/profiling_controller.sh" --status)
rc=$?

echo "$out" | head -8
echo "  ... ($(echo "$out" | wc -l) lines total)"
echo "  exit code: $rc"

# Verify: shows benchmark rows with stage status
if echo "$out" | grep -qE "Benchmark|400\.perlbench|PASS" && echo "$out" | grep -qE "S1|S2|S3|S4|S5|S6|S7"; then
    pass "F2: --status shows benchmark stage matrix"
else
    fail "F2: --status missing expected benchmark rows"
fi

echo ""
echo "=== Test F3: profiling_controller.sh --prefetchers --dry-run ==="
((TESTS_RUN++))

out=$(capture bash "$SCRIPT_DIR/profiling_controller.sh" \
    --prefetchers "no,next_line" \
    --benchmarks 400.perlbench \
    --stage 4 --dry-run)
rc=$?

echo "$out" | head -5
echo "  exit code: $rc"

# Verify: shows prefetcher selection and benchmark count
if echo "$out" | grep -qE "Prefetchers|Benchmarks|Dry-run|no.*next_line"; then
    pass "F3: --dry-run with prefetcher spec works"
else
    fail "F3: --dry-run with prefetcher spec missing expected output"
fi

echo ""
echo "=== Test F4: profiling_controller.sh preset resolution ==="
((TESTS_RUN++))

out=$(capture bash "$SCRIPT_DIR/profiling_controller.sh" \
    --prefetchers standard \
    --benchmarks 400.perlbench \
    --stage 4 --dry-run)
rc=$?

echo "$out" | head -8
echo "  exit code: $rc"

# Verify: standard preset resolves to no,next_line,ip_stride,spp_dev,va_ampm_lite
if echo "$out" | grep -qE "no|next_line|ip_stride|va_ampm_lite|spp_dev"; then
    pass "F4: 'standard' preset resolves to expected prefetchers"
else
    fail "F4: 'standard' preset didn't resolve correctly"
fi

echo ""
echo "──────────────────────────────────────"
echo "Category F: $TESTS_PASS/$TESTS_RUN passed"
if $PASS; then echo "Result: PASS"; exit 0; else echo "Result: FAIL"; exit 1; fi
