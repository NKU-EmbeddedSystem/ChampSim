#!/usr/bin/env bash
# Module 1: Parse DPC-3 SimPoints for a benchmark.
# Output: data/<benchmark>/simpoints.json
#
# Usage:
#   ./modules/01_parse_simpoints.sh <benchmark> [--force] [--dry-run]
#
# One-time: SimPoints are DPC-3 reference data, generated once per benchmark.
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
SIMPOINTS_JSON="$BENCH_DIR/simpoints.json"
MODULE_NAME="[01_simpoints]"

log()  { echo "[$(date '+%H:%M:%S')] $MODULE_NAME $*"; }
run()  {
    if $DRY_RUN; then
        echo "[DRY-RUN] $*"
    else
        eval "$@"
    fi
}

# Idempotency check
if [ -f "$SIMPOINTS_JSON" ] && [ "$FORCE" != "true" ]; then
    if python3 -c "import json; json.load(open('$SIMPOINTS_JSON'))" 2>/dev/null; then
        log "[SKIP] simpoints.json already exists and is valid JSON"
        log "  Use --force to re-parse"
        exit 0
    else
        log "[WARN] simpoints.json exists but is invalid, re-parsing..."
    fi
fi

if [ ! -f "$SIMPOINTS_TARBALL" ]; then
    log "ERROR: SimPoints tarball not found at $SIMPOINTS_TARBALL"
    log "  Download from DPC-3 or set SIMPOINTS_TARBALL in config.sh"
    exit 1
fi

log "Parsing SimPoints for $BENCHMARK from tarball..."
run mkdir -p "$BENCH_DIR"
run python3 "$SCRIPT_DIR/03_workers/parse_simpoints.py" \
    --tarball "$SIMPOINTS_TARBALL" \
    --benchmark "$BENCHMARK" \
    --output-dir "$BENCH_DIR"

log "Output: $SIMPOINTS_JSON"
