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
    if [ -z "${SPEC_ROOT:-}" ]; then
        log "ERROR: SPEC_ROOT not set and BINARY_PATH not provided"
        log "  Set BINARY_PATH=/path/to/binary or configure SPEC_ROOT in config.sh"
        exit 1
    fi

    exe_name=$(grep "exename" "$SPEC_ROOT/benchspec/CPU2006/$BENCHMARK/Spec/object.pm" 2>/dev/null | grep -oP "'\K[^']*" | head -1)
    if [ -z "$exe_name" ]; then
        exe_name=$(echo "$BENCHMARK" | sed 's/^[0-9]*\.//')
    fi

    spec_build_dir=$(find "$SPEC_ROOT/benchspec/CPU2006/$BENCHMARK/build" \
        -maxdepth 2 -type d -name "build_base_*" 2>/dev/null | head -1)
    spec_run_dir=$(find "$SPEC_ROOT/benchspec/CPU2006/$BENCHMARK/run" \
        -maxdepth 2 -type d -name "run_base_*" 2>/dev/null | head -1)

    if [ -n "$spec_build_dir" ]; then
        BINARY_PATH="$spec_build_dir/$exe_name"
    elif [ -n "$spec_run_dir" ]; then
        BINARY_PATH="$spec_run_dir/$exe_name"
    else
        log "ERROR: No compiled binary found for $BENCHMARK"
        log "  Build it first with SPEC or set BINARY_PATH=/path/to/binary"
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

log "Binary: $BINARY_PATH"

run mkdir -p "$BENCH_DIR"
run python3 "$SCRIPT_DIR/parse_disassembly.py" \
    --binary "$BINARY_PATH" \
    --output "$DISASM_INDEX"

log "Output: $DISASM_INDEX"
