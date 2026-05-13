#!/usr/bin/env bash
# Module 2: Locate SPEC binary and run objdump disassembly.
# Output: data/<benchmark>/disasm_index.json
#
# Usage:
#   ./modules/02_disassemble.sh <benchmark> [--force] [--dry-run]
#   BINARY_PATH=/path/to/binary ./modules/02_disassemble.sh <benchmark>  # override
#
# One-time: Only changes when the SPEC binary is recompiled.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

BENCHMARK="${1:-}"
shift 2>/dev/null || true
FORCE=false
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) FORCE=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ -z "$BENCHMARK" ]; then
    echo "Usage: $0 <benchmark> [--force] [--dry-run]"
    echo "Example: $0 400.perlbench"
    exit 1
fi

BENCH_DIR="$DATA_ROOT/$BENCHMARK"
DISASM_INDEX="$BENCH_DIR/disasm_index.json"
MODULE_NAME="[02_disasm]"

log()  { echo "[$(date '+%H:%M:%S')] $MODULE_NAME $*"; }
run()  {
    if $DRY_RUN; then
        echo "[DRY-RUN] $*"
    else
        eval "$@"
    fi
}

# Idempotency check
if [ -f "$DISASM_INDEX" ] && [ "$FORCE" != "true" ]; then
    if python3 -c "
import json
d = json.load(open('$DISASM_INDEX'))
assert 'instructions' in d and len(d['instructions']) > 0
assert 'load_pcs' in d and len(d['load_pcs']) > 0
" 2>/dev/null; then
        log "[SKIP] disasm_index.json already exists and has valid structure"
        log "  Use --force to re-disassemble"
        exit 0
    else
        log "[WARN] disasm_index.json exists but is invalid, re-disassembling..."
    fi
fi

# Binary discovery (can override via env)
BINARY_PATH="${BINARY_PATH:-}"
if [ -z "$BINARY_PATH" ]; then
    # Auto-detect suite from benchmark name: 4XX → CPU2006, 6XX_s → CPU2017 speed
    if [[ "$BENCHMARK" =~ ^4[0-9] ]]; then
        SUITE="CPU2006"
        SPEC_ROOT="${SPEC2006_ROOT:-${SPEC_ROOT:-}}"
        BENCHSPEC_DIR="benchspec/CPU2006"
    elif [[ "$BENCHMARK" =~ ^6[0-9].*_s$ ]]; then
        SUITE="CPU2017"
        SPEC_ROOT="${SPEC2017_ROOT:-}"
        BENCHSPEC_DIR="benchspec/CPU"
    else
        log "ERROR: Cannot auto-detect SPEC suite for '$BENCHMARK'"
        log "  Benchmark must be CPU2006 (4XX) or CPU2017 speed (6XX_s)."
        log "  For CPU2017 rate (5XX_r), use BINARY_PATH=/path/to/binary"
        exit 1
    fi

    if [ -z "$SPEC_ROOT" ]; then
        log "ERROR: SPEC($SUITE)_ROOT not set"
        log "  Set it in tools/benchmarks/spec*/config.sh or provide BINARY_PATH"
        exit 1
    fi

    exe_name=$(grep "exename" "$SPEC_ROOT/$BENCHSPEC_DIR/$BENCHMARK/Spec/object.pm" 2>/dev/null | grep -oP "'\K[^']*" | head -1)
    if [ -z "$exe_name" ]; then
        exe_name=$(echo "$BENCHMARK" | sed 's/^[0-9]*\.//')
    fi

    spec_build_dir=$(find "$SPEC_ROOT/$BENCHSPEC_DIR/$BENCHMARK/build" \
        -maxdepth 2 -type d -name "build_base_*" 2>/dev/null | head -1)
    spec_run_dir=$(find "$SPEC_ROOT/$BENCHSPEC_DIR/$BENCHMARK/run" \
        -maxdepth 2 -type d -name "run_base_*" 2>/dev/null | head -1)

    if [ -n "$spec_build_dir" ]; then
        BINARY_PATH="$spec_build_dir/$exe_name"
    elif [ -n "$spec_run_dir" ]; then
        BINARY_PATH="$spec_run_dir/$exe_name"
    else
        log "ERROR: No compiled binary found for $BENCHMARK"
        log "  Build it with: cd $SPEC_ROOT && . ./shrc && runcpu --action=build --config=<cfg> $BENCHMARK"
        exit 1
    fi

    if [ ! -f "$BINARY_PATH" ]; then
        BINARY_PATH=$(find "${spec_build_dir:-$spec_run_dir}" -type f -executable -not -name "*.h" -not -name "*.c" -name "$exe_name*" 2>/dev/null | head -1)
    fi
fi

if [ ! -f "$BINARY_PATH" ]; then
    log "ERROR: Binary not found at $BINARY_PATH"
    exit 1
fi

log "Binary: $BINARY_PATH (suite=${SUITE:-override})"

run mkdir -p "$BENCH_DIR"
run python3 "$SCRIPT_DIR/03_workers/parse_disassembly.py" \
    --binary "$BINARY_PATH" \
    --output "$DISASM_INDEX"

log "Output: $DISASM_INDEX"
