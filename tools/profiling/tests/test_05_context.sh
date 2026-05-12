#!/usr/bin/env bash
# Test: Validate assembly_context.jsonl and load_pcs.json from Module 5.
#
# Usage:
#   ./tests/test_05_context.sh <benchmark>
#   ./tests/test_05_context.sh 400.perlbench
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

BENCHMARK="${1:-}"
if [ -z "$BENCHMARK" ]; then
    echo "Usage: $0 <benchmark>"
    exit 1
fi

BENCH_DIR="$DATA_ROOT/$BENCHMARK"
LOAD_PCS_JSON="$BENCH_DIR/load_pcs.json"
ASSEMBLY_CTX="$BENCH_DIR/assembly_context.jsonl"
PASS=true

echo "=== Test 05: Assembly Context ==="

check() {
    local desc="$1"; shift
    if python3 -c "$@" 2>/dev/null; then
        echo "  [✓] $desc"
    else
        echo "  [✗] $desc"
        PASS=false
    fi
}

if [ ! -f "$LOAD_PCS_JSON" ]; then
    echo "  [✗] load_pcs.json not found"
    PASS=false
else
    echo "  [✓] load_pcs.json exists"

    check "load_pcs.json is a JSON array of hex strings" "
import json; pcs = json.load(open('$LOAD_PCS_JSON'))
assert isinstance(pcs, list), 'not a list'
assert len(pcs) > 0, 'empty list'
for pc in pcs[:10]:
    assert pc.startswith('0x'), f'no 0x prefix: {pc}'
    int(pc, 16)
"
fi

if [ ! -f "$ASSEMBLY_CTX" ]; then
    echo "  [✗] assembly_context.jsonl not found"
    PASS=false
else
    ctx_lines=$(wc -l < "$ASSEMBLY_CTX")
    echo "  [✓] assembly_context.jsonl exists ($ctx_lines lines)"

    # Validate JSONL structure
    check "Each line has: pc, load_insn, function, context_before, context_after" "
import json
with open('$ASSEMBLY_CTX') as f:
    for i, line in enumerate(f):
        if i >= 20: break
        r = json.loads(line)
        for key in ('pc', 'load_insn', 'function', 'context_before', 'context_after'):
            assert key in r, f'line {i}: missing {key}'
"

    # Check context window sizes
    check "context_before ≤ ${CTX_BEFORE}, context_after ≤ ${CTX_AFTER}" "
import json
with open('$ASSEMBLY_CTX') as f:
    for i, line in enumerate(f):
        if i >= 50: break
        r = json.loads(line)
        assert len(r['context_before']) <= ${CTX_BEFORE}, f'line {i}: before={len(r[\"context_before\"])}'
        assert len(r['context_after']) <= ${CTX_AFTER}, f'line {i}: after={len(r[\"context_after\"])}'
"

    # Check PC coverage: context PCs should be a subset of load PCs
    # (trace may only cover a subset of SimPoint intervals)
    if [ -f "$LOAD_PCS_JSON" ]; then
        check "Assembly context PCs are a subset of load_pcs from trace" "
import json
with open('$LOAD_PCS_JSON') as f:
    load_pcs = set(json.load(f))
with open('$ASSEMBLY_CTX') as f:
    ctx_pcs = {json.loads(line)['pc'] for line in f}
extra = ctx_pcs - load_pcs
assert len(extra) == 0, f'{len(extra)} context PCs not in load_pcs'
"
    fi

    echo "  Coverage: $ctx_lines PCs with assembly context"
fi

if $PASS; then
    echo "Result: PASS"
    exit 0
else
    echo "Result: FAIL"
    exit 1
fi
