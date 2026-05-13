#!/usr/bin/env bash
# Module 5: Extract assembly context for Load PCs.
# Output: data/<benchmark>/load_pcs.json, data/<benchmark>/assembly_context.jsonl
#
# Usage:
#   ./modules/05_extract_context.sh <benchmark> [--force] [--dry-run]
#
# One-time: Changes only when binary or trace changes.
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
TRACES_DIR="$BENCH_DIR/traces"
LOAD_PCS_JSON="$BENCH_DIR/load_pcs.json"
ASSEMBLY_CTX="$BENCH_DIR/assembly_context.jsonl"
MODULE_NAME="[05_context]"

log()  { echo "[$(date '+%H:%M:%S')] $MODULE_NAME $*"; }
run()  {
    if $DRY_RUN; then
        echo "[DRY-RUN] $*"
    else
        eval "$@"
    fi
}

# Idempotency check — both files must exist and have valid content
if [ -f "$LOAD_PCS_JSON" ] && [ -f "$ASSEMBLY_CTX" ] && [ "$FORCE" != "true" ]; then
    if python3 -c "
import json
pcs = json.load(open('$LOAD_PCS_JSON'))
assert isinstance(pcs, list) and len(pcs) > 0
" 2>/dev/null && [ -s "$ASSEMBLY_CTX" ]; then
        log "[SKIP] Assembly context already exists"
        log "  load_pcs.json: $(python3 -c "import json; print(len(json.load(open('$LOAD_PCS_JSON'))))") PCs"
        log "  assembly_context.jsonl: $(wc -l < "$ASSEMBLY_CTX") lines"
        log "  Use --force to re-extract"
        exit 0
    else
        log "[WARN] Existing context files invalid, re-extracting..."
    fi
fi

# Prerequisites
if [ ! -f "$DISASM_INDEX" ]; then
    log "ERROR: disasm_index.json not found. Run module 02 first."
    exit 1
fi

shopt -s nullglob
all_traces=("$TRACES_DIR"/*.champsimtrace.xz)
shopt -u nullglob

if [ ${#all_traces[@]} -eq 0 ]; then
    log "ERROR: No traces found. Run module 03 first."
    exit 1
fi

# Pick the first non-empty trace (skip 32-byte empty ones)
MIN_VALID_SIZE=1024
selected_trace=""
for t in "${all_traces[@]}"; do
    tsize=$(stat -c %s "$t" 2>/dev/null || echo 0)
    if [ "$tsize" -ge "$MIN_VALID_SIZE" ]; then
        selected_trace="$t"
        break
    fi
done

if [ -z "$selected_trace" ]; then
    log "ERROR: All ${#all_traces[@]} traces are too small (< $MIN_VALID_SIZE bytes)"
    log "  Traces appear to be invalid. Re-run module 03 to regenerate."
    exit 1
fi

log "Extracting Load PCs from $(basename "$selected_trace")..."
run python3 "$SCRIPT_DIR/03_workers/trace_reader.py" \
    --trace "$selected_trace" \
    --output "$LOAD_PCS_JSON"

log "Extracting assembly context (±${CTX_BEFORE}/${CTX_AFTER} instructions)..."
run python3 "$SCRIPT_DIR/03_workers/extract_assembly_context.py" \
    --index "$DISASM_INDEX" \
    --load-pcs "$LOAD_PCS_JSON" \
    --before "$CTX_BEFORE" \
    --after "$CTX_AFTER" \
    --output "$ASSEMBLY_CTX"

log "Output: $LOAD_PCS_JSON, $ASSEMBLY_CTX"
