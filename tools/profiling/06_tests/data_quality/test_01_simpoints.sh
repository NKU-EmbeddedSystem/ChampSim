#!/usr/bin/env bash
# Test: Validate simpoints.json output from Module 1.
#
# Usage:
#   ./tests/test_01_simpoints.sh <benchmark>
#   ./tests/test_01_simpoints.sh 400.perlbench
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_DIR/config.sh"

BENCHMARK="${1:-}"
if [ -z "$BENCHMARK" ]; then
    echo "Usage: $0 <benchmark>"
    exit 1
fi

SIMPOINTS_JSON="$DATA_ROOT/$BENCHMARK/simpoints.json"
PASS=true

echo "=== Test 01: SimPoints ==="

check() {
    local desc="$1"; shift
    if python3 -c "$@" 2>/dev/null; then
        echo "  [✓] $desc"
    else
        echo "  [✗] $desc"
        PASS=false
    fi
}

# Test 1: File exists
if [ -f "$SIMPOINTS_JSON" ]; then
    echo "  [✓] simpoints.json exists"
else
    echo "  [✗] simpoints.json not found at $SIMPOINTS_JSON"
    PASS=false
    $PASS && exit 0 || exit 1
fi

# Test 2: Valid JSON
check "Valid JSON" "
import json; d = json.load(open('$SIMPOINTS_JSON'))
assert isinstance(d, list), 'not a list'
"

# Test 3: Contains required fields
check "Each entry has interval_id (int) and weight (float)" "
import json; d = json.load(open('$SIMPOINTS_JSON'))
for e in d:
    assert isinstance(e['interval_id'], int), f'interval_id not int: {e}'
    assert isinstance(e['weight'], (int, float)), f'weight not number: {e}'
    assert 0 <= e['weight'] <= 1, f'weight out of range: {e[\"weight\"]}'
"

# Test 4: Sorted by weight descending
check "Sorted by weight descending" "
import json; d = json.load(open('$SIMPOINTS_JSON'))
weights = [e['weight'] for e in d]
assert weights == sorted(weights, reverse=True), 'not sorted descending'
"

# Test 5: At least one interval above threshold
check "At least 1 interval with weight >= $WEIGHT_THRESHOLD" "
import json; d = json.load(open('$SIMPOINTS_JSON'))
count = sum(1 for e in d if e['weight'] >= $WEIGHT_THRESHOLD)
assert count > 0, f'no interval above threshold (got {len(d)} total)'
"

# Summary
count=$(python3 -c "import json; print(len(json.load(open('$SIMPOINTS_JSON'))))")
above=$(python3 -c "
import json; d = json.load(open('$SIMPOINTS_JSON'))
print(sum(1 for e in d if e['weight'] >= $WEIGHT_THRESHOLD))
")
echo "  $count intervals, $above above weight threshold"

if $PASS; then
    echo "Result: PASS"
    exit 0
else
    echo "Result: FAIL"
    exit 1
fi
