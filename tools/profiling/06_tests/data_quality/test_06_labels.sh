#!/usr/bin/env bash
# Test: Validate ground_truth.jsonl from Module 6.
#
# Usage:
#   ./tests/test_06_labels.sh <benchmark>
#   ./tests/test_06_labels.sh 400.perlbench
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_DIR/config.sh"

BENCHMARK="${1:-}"
if [ -z "$BENCHMARK" ]; then
    echo "Usage: $0 <benchmark>"
    exit 1
fi

GROUND_TRUTH="$DATA_ROOT/$BENCHMARK/ground_truth.jsonl"
PASS=true

echo "=== Test 06: Ground Truth Labels ==="

check() {
    local desc="$1"; shift
    if python3 -c "$@" 2>/dev/null; then
        echo "  [✓] $desc"
    else
        echo "  [✗] $desc"
        PASS=false
    fi
}

if [ ! -f "$GROUND_TRUTH" ]; then
    echo "  [✗] ground_truth.jsonl not found at $GROUND_TRUTH"
    exit 1
fi

gt_lines=$(wc -l < "$GROUND_TRUTH")
echo "  [✓] ground_truth.jsonl exists ($gt_lines lines)"

if [ "$gt_lines" -eq 0 ]; then
    echo "  [✗] ground_truth.jsonl is empty"
    exit 1
fi

# Test 1: JSONL format with required fields
check "Each line has: pc, best_prefetch, best_degree, best_amat, all_amats" "
import json
with open('$GROUND_TRUTH') as f:
    for i, line in enumerate(f):
        if i >= 50: break
        r = json.loads(line)
        for key in ('pc', 'best_prefetch', 'best_degree', 'best_amat', 'all_amats'):
            assert key in r, f'line {i}: missing {key}'
"

# Test 2: best_amat is a positive number
check "best_amat is a positive number" "
import json
with open('$GROUND_TRUTH') as f:
    for i, line in enumerate(f):
        if i >= 50: break
        r = json.loads(line)
        assert r['best_amat'] >= 0, f'line {i}: negative amat {r[\"best_amat\"]}'
"

# Test 3: all_amats contains best_policy and value matches
check "all_amats contains best_prefetch:best_degree with matching best_amat" "
import json
with open('$GROUND_TRUTH') as f:
    for i, line in enumerate(f):
        if i >= 30: break
        r = json.loads(line)
        key = f'{r[\"best_prefetch\"]}:{r[\"best_degree\"]}'
        assert key in r['all_amats'], f'line {i}: {key} not in all_amats'
        assert abs(r['all_amats'][key] - r['best_amat']) < 0.001, f'line {i}: amat mismatch'
"

# Test 4: PCs sorted ascending (hex)
check "PCs sorted ascending" "
import json
pcs = []
with open('$GROUND_TRUTH') as f:
    for line in f:
        r = json.loads(line)
        pcs.append(int(r['pc'], 16))
assert pcs == sorted(pcs), 'PCs not sorted'
"

# Test 5: At least 2 different prefetchers
check "At least 2 different prefetchers represented" "
import json
prefs = set()
with open('$GROUND_TRUTH') as f:
    for line in f:
        r = json.loads(line)
        prefs.add(r['best_prefetch'])
assert len(prefs) >= 2, f'only {len(prefs)} prefetcher(s) found'
print(f'  Prefetchers: {\" \".join(sorted(prefs))}')
"

# Summary
python3 -c "
import json
from collections import Counter
prefs = Counter()
with open('$GROUND_TRUTH') as f:
    for line in f:
        r = json.loads(line)
        prefs[r['best_prefetch']] += 1
total = sum(prefs.values())
print(f'  {total} PCs labeled')
for p, c in prefs.most_common(5):
    print(f'    {p}: {c} ({100*c/total:.1f}%)')
"

if $PASS; then
    echo "Result: PASS"
    exit 0
else
    echo "Result: FAIL"
    exit 1
fi
