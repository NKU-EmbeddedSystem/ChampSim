#!/usr/bin/env bash
# Test: Validate disasm_index.json output from Module 2.
#
# Usage:
#   ./tests/test_02_disassemble.sh <benchmark>
#   ./tests/test_02_disassemble.sh 400.perlbench
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_DIR/config.sh"

BENCHMARK="${1:-}"
if [ -z "$BENCHMARK" ]; then
    echo "Usage: $0 <benchmark>"
    exit 1
fi

DISASM_INDEX="$DATA_ROOT/$BENCHMARK/disasm_index.json"
PASS=true

echo "=== Test 02: Disassembly ==="

check() {
    local desc="$1"; shift
    if python3 -c "$@" 2>/dev/null; then
        echo "  [✓] $desc"
    else
        echo "  [✗] $desc"
        PASS=false
    fi
}

if [ ! -f "$DISASM_INDEX" ]; then
    echo "  [✗] disasm_index.json not found at $DISASM_INDEX"
    exit 1
fi
echo "  [✓] disasm_index.json exists"

# Test 1: Valid JSON with required keys
check "Has required keys: function_names, instructions, pc_list, load_pcs" "
import json; d = json.load(open('$DISASM_INDEX'))
for k in ('function_names', 'instructions', 'pc_list', 'load_pcs'):
    assert k in d, f'missing key: {k}'
"

# Test 2: instructions non-empty
check "instructions dict is non-empty" "
import json; d = json.load(open('$DISASM_INDEX'))
assert len(d['instructions']) > 0, 'empty instructions'
"

# Test 3: Instruction structure
check "Each instruction has mnemonic, operands, full_text, function_idx" "
import json; d = json.load(open('$DISASM_INDEX'))
for pc, insn in list(d['instructions'].items())[:100]:
    for f in ('mnemonic', 'operands', 'full_text', 'function_idx'):
        assert f in insn, f'{pc}: missing {f}'
"

# Test 4: load_pcs non-empty
check "load_pcs is non-empty" "
import json; d = json.load(open('$DISASM_INDEX'))
assert len(d['load_pcs']) > 0, 'empty load_pcs'
"

# Test 5: pc_list sorted ascending
check "pc_list is sorted ascending" "
import json; d = json.load(open('$DISASM_INDEX'))
assert d['pc_list'] == sorted(d['pc_list']), 'pc_list not sorted'
"

# Test 6: load_pcs are valid hex
check "load_pcs entries are valid hex strings" "
import json; d = json.load(open('$DISASM_INDEX'))
for pc in d['load_pcs'][:50]:
    assert pc.startswith('0x'), f'no 0x prefix: {pc}'
    int(pc, 16)
"

# Summary
python3 -c "
import json
d = json.load(open('$DISASM_INDEX'))
print(f'  {len(d[\"function_names\"])} functions, {len(d[\"instructions\"])} instructions, {len(d[\"load_pcs\"])} Load PCs')
"

if $PASS; then
    echo "Result: PASS"
    exit 0
else
    echo "Result: FAIL"
    exit 1
fi
