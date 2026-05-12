#!/usr/bin/env bash
# Test: Validate profiling JSON outputs from Module 4.
#
# Usage:
#   ./tests/test_04_profiling.sh <benchmark>
#   ./tests/test_04_profiling.sh 400.perlbench
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

BENCHMARK="${1:-}"
if [ -z "$BENCHMARK" ]; then
    echo "Usage: $0 <benchmark>"
    exit 1
fi

PROFILING_DIR="$DATA_ROOT/$BENCHMARK/profiling"
TRACES_DIR="$DATA_ROOT/$BENCHMARK/traces"
PASS=true

echo "=== Test 04: Profiling ==="

if [ ! -d "$PROFILING_DIR" ]; then
    echo "  [✗] profiling/ directory not found at $PROFILING_DIR"
    exit 1
fi

shopt -s nullglob
profiling_jsons=("$PROFILING_DIR"/*.json)
shopt -u nullglob

if [ ${#profiling_jsons[@]} -eq 0 ]; then
    echo "  [✗] No .json files found in profiling/"
    exit 1
fi
echo "  [✓] ${#profiling_jsons[@]} profiling output(s)"

declare -A traces_seen=()
total_pcs=0 empty_count=0

for pf_json in "${profiling_jsons[@]}"; do
    fname=$(basename "$pf_json")
    fsize=$(stat -c %s "$pf_json")

    if [ ! -s "$pf_json" ]; then
        echo "  [✗] $fname: empty"
        PASS=false
        ((empty_count++)) || true
        continue
    fi

    # File naming: <trace>__<pref>__<deg>.json
    if [[ "$fname" =~ ^(.+?)__(.+?)__([0-9]+)\.json$ ]]; then
        trace_part="${BASH_REMATCH[1]}"
        pref_part="${BASH_REMATCH[2]}"
        deg_part="${BASH_REMATCH[3]}"
        traces_seen["$trace_part"]=1
        echo "  [✓] $fname: trace=$trace_part pref=$pref_part deg=$deg_part"
    else
        echo "  [✗] $fname: naming convention mismatch"
        PASS=false
        continue
    fi

    # Validate JSONL content (check first 5 lines)
    valid_lines=0
    while IFS= read -r line; do
        if python3 -c "
import json
r = json.loads('''$line''')
assert 'pc' in r, 'no pc'
assert 'access_count' in r or 'avg_amat' in r or 'hit_ratio' in r, 'no metric field'
" 2>/dev/null; then
            ((valid_lines++)) || true
        fi
    done < <(head -5 "$pf_json")

    if [ "$valid_lines" -gt 0 ]; then
        line_count=$(wc -l < "$pf_json")
        echo "       ${line_count} lines, ${valid_lines}/5 sampled valid"
        ((total_pcs += line_count)) || true
    else
        echo "  [✗] $fname: JSONL validation failed (no valid lines)"
        PASS=false
    fi
done

if [ "$empty_count" -gt 0 ]; then
    echo "  [✗] $empty_count empty file(s)"
fi

# Coverage: each trace should have at least one profiling output
if [ -d "$TRACES_DIR" ]; then
    shopt -s nullglob
    all_traces=("$TRACES_DIR"/*.champsimtrace.xz)
    shopt -u nullglob
    for t in "${all_traces[@]}"; do
        tn=$(basename "$t" .champsimtrace.xz)
        if [ -z "${traces_seen[$tn]:-}" ]; then
            echo "  [✗] No profiling for trace: $tn"
            PASS=false
        fi
    done
fi

echo "  Total PCs across all outputs: $total_pcs"

if $PASS; then
    echo "Result: PASS"
    exit 0
else
    echo "Result: FAIL"
    exit 1
fi
