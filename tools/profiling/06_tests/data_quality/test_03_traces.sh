#!/usr/bin/env bash
# Test: Validate ChampSim trace files from Module 3.
#
# Usage:
#   ./tests/test_03_traces.sh <benchmark>
#   ./tests/test_03_traces.sh 400.perlbench
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_DIR/config.sh"

BENCHMARK="${1:-}"
if [ -z "$BENCHMARK" ]; then
    echo "Usage: $0 <benchmark>"
    exit 1
fi

TRACES_DIR="$DATA_ROOT/$BENCHMARK/traces"
SIMPOINTS_JSON="$DATA_ROOT/$BENCHMARK/simpoints.json"
PASS=true

echo "=== Test 03: Traces ==="

if [ ! -d "$TRACES_DIR" ]; then
    echo "  [✗] traces/ directory not found at $TRACES_DIR"
    exit 1
fi

# Count traces
shopt -s nullglob
traces=("$TRACES_DIR"/*.champsimtrace.xz)
shopt -u nullglob

if [ ${#traces[@]} -eq 0 ]; then
    echo "  [✗] No .champsimtrace.xz files found"
    exit 1
fi
echo "  [✓] ${#traces[@]} trace(s) found"

# Check each trace
for trace in "${traces[@]}"; do
    tname=$(basename "$trace")
    size=$(stat -c %s "$trace")

    # Test: Non-empty
    if [ "$size" -gt 0 ]; then
        echo "  [✓] $tname: non-empty ($size bytes)"
    else
        echo "  [✗] $tname: empty file"
        PASS=false
        continue
    fi

    # Test: Naming convention <benchmark>-<sid>B.champsimtrace.xz
    if [[ "$tname" =~ ^${BENCHMARK}-[0-9]+B\.champsimtrace\.xz$ ]]; then
        echo "  [✓] $tname: naming convention OK"
    else
        echo "  [✗] $tname: naming convention mismatch"
        PASS=false
    fi

    # Test: Can decompress (check magic bytes)
    if xz -t "$trace" 2>/dev/null; then
        echo "  [✓] $tname: valid xz compressed"
    else
        echo "  [✗] $tname: xz decompression test failed"
        PASS=false
    fi
done

# Compare count against expected from simpoints.json
if [ -f "$SIMPOINTS_JSON" ]; then
    expected=$(python3 -c "
import json
d = json.load(open('$SIMPOINTS_JSON'))
print(sum(1 for e in d if e['weight'] >= $WEIGHT_THRESHOLD))
" 2>/dev/null)
    ready=${#traces[@]}
    if [ "$ready" -ge "$expected" ]; then
        echo "  [✓] Trace count: $ready/$expected (all present)"
    else
        echo "  [✗] Trace count: $ready/$expected (missing $((expected - ready)))"
        PASS=false
    fi
fi

echo "  Total size: $(du -sh "$TRACES_DIR" | cut -f1)"

if $PASS; then
    echo "Result: PASS"
    exit 0
else
    echo "Result: FAIL"
    exit 1
fi
