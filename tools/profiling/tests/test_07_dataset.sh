#!/usr/bin/env bash
# Test: Validate tuning_dataset.jsonl from Module 7.
#
# Usage:
#   ./tests/test_07_dataset.sh <benchmark>
#   ./tests/test_07_dataset.sh 400.perlbench
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

BENCHMARK="${1:-}"
if [ -z "$BENCHMARK" ]; then
    echo "Usage: $0 <benchmark>"
    exit 1
fi

BENCH_DIR="$DATA_ROOT/$BENCHMARK"
TUNING_DATASET="$BENCH_DIR/tuning_dataset.jsonl"
GROUND_TRUTH="$BENCH_DIR/ground_truth.jsonl"
PASS=true

echo "=== Test 07: Training Dataset ==="

check() {
    local desc="$1"; shift
    if python3 -c "$@" 2>/dev/null; then
        echo "  [✓] $desc"
    else
        echo "  [✗] $desc"
        PASS=false
    fi
}

if [ ! -f "$TUNING_DATASET" ]; then
    echo "  [✗] tuning_dataset.jsonl not found at $TUNING_DATASET"
    exit 1
fi

td_lines=$(wc -l < "$TUNING_DATASET")
echo "  [✓] tuning_dataset.jsonl exists ($td_lines lines)"

if [ "$td_lines" -eq 0 ]; then
    echo "  [✗] tuning_dataset.jsonl is empty"
    exit 1
fi

# Test 1: JSONL format with required fields
check "Each line has: instruction, label, pc" "
import json
with open('$TUNING_DATASET') as f:
    for i, line in enumerate(f):
        if i >= 50: break
        r = json.loads(line)
        for key in ('instruction', 'label', 'pc'):
            assert key in r, f'line {i}: missing {key}'
"

# Test 2: label format "prefetcher:degree"
check "label format matches 'prefetcher_name:degree'" "
import json
import re
pat = re.compile(r'^[a-z_]+:\d+$')
with open('$TUNING_DATASET') as f:
    for i, line in enumerate(f):
        if i >= 50: break
        r = json.loads(line)
        assert pat.match(r['label']), f'line {i}: bad label format {r[\"label\"]}'
"

# Test 3: instruction is non-empty string
check "instruction is non-empty string" "
import json
with open('$TUNING_DATASET') as f:
    for i, line in enumerate(f):
        if i >= 20: break
        r = json.loads(line)
        assert isinstance(r['instruction'], str) and len(r['instruction']) > 0, f'line {i}: empty instruction'
"

# Test 4: No duplicate PCs
check "No duplicate PCs" "
import json
pcs = []
with open('$TUNING_DATASET') as f:
    for line in f:
        r = json.loads(line)
        pcs.append(r['pc'])
assert len(pcs) == len(set(pcs)), f'{len(pcs) - len(set(pcs))} duplicate PCs'
"

# Test 5: Cross-reference with ground truth
# (tuning dataset may be a subset — only PCs with assembly context)
if [ -f "$GROUND_TRUTH" ]; then
    check "Tuning dataset PCs are a subset of ground truth PCs" "
import json
gt_pcs = set()
with open('$GROUND_TRUTH') as f:
    for line in f:
        gt_pcs.add(json.loads(line)['pc'])
td_pcs = set()
with open('$TUNING_DATASET') as f:
    for line in f:
        td_pcs.add(json.loads(line)['pc'])
extra = td_pcs - gt_pcs
assert len(extra) == 0, f'{len(extra)} TD PCs not in ground truth'
assert len(td_pcs) > 0, 'TD is empty'
"
fi

echo "  Examples: $(python3 -c "
import json
with open('$TUNING_DATASET') as f:
    for i, line in enumerate(f):
        if i >= 3: break
        r = json.loads(line)
        print(f'{r[\"pc\"]} → {r[\"label\"]}')
" 2>/dev/null)"

if $PASS; then
    echo "Result: PASS"
    exit 0
else
    echo "Result: FAIL"
    exit 1
fi
