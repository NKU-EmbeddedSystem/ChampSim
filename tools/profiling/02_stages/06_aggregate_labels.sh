#!/usr/bin/env bash
# Module 6: Aggregate ground truth labels across prefetcher profiling runs.
# Output: data/<benchmark>/ground_truth.jsonl
#
# Usage:
#   ./modules/06_aggregate_labels.sh <benchmark> [--force] [--dry-run]
#
# Re-runnable: Re-run when profiling data changes (new prefetchers added).
# Freshness check: skips if output is newer than all profiling JSONs.
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
PROFILING_DIR="$BENCH_DIR/profiling"
GROUND_TRUTH="$BENCH_DIR/ground_truth.jsonl"
MODULE_NAME="[06_labels]"

log()  { echo "[$(date '+%H:%M:%S')] $MODULE_NAME $*"; }
run()  {
    if $DRY_RUN; then
        echo "[DRY-RUN] $*"
    else
        eval "$@"
    fi
}

# Prerequisites
if [ ! -d "$PROFILING_DIR" ]; then
    log "ERROR: profiling/ directory not found. Run module 04 first."
    exit 1
fi

shopt -s nullglob
profiling_jsons=("$PROFILING_DIR"/*.json)
shopt -u nullglob

if [ ${#profiling_jsons[@]} -eq 0 ]; then
    log "ERROR: No profiling JSONs found in $PROFILING_DIR"
    exit 1
fi

# Idempotency with freshness check
if [ -f "$GROUND_TRUTH" ] && [ "$FORCE" != "true" ]; then
    gt_mtime=$(stat -c %Y "$GROUND_TRUTH")
    stale=false
    for pf in "${profiling_jsons[@]}"; do
        pf_mtime=$(stat -c %Y "$pf")
        if [ "$pf_mtime" -gt "$gt_mtime" ]; then
            stale=true
            log "  [STALE] $pf is newer than ground_truth.jsonl"
            break
        fi
    done
    if ! $stale; then
        gt_lines=$(wc -l < "$GROUND_TRUTH")
        if [ "$gt_lines" -gt 0 ]; then
            log "[SKIP] ground_truth.jsonl is up-to-date ($gt_lines lines)"
            log "  Use --force to re-aggregate"
            exit 0
        else
            log "[WARN] ground_truth.jsonl exists but is empty, re-aggregating..."
        fi
    else
        log "  Re-aggregating (newer profiling data detected)..."
    fi
fi

# Check that at least some profiling outputs have content
nonempty_count=0
for pf in "${profiling_jsons[@]}"; do
    if [ -s "$pf" ]; then
        ((nonempty_count++)) || true
    fi
done
if [ "$nonempty_count" -eq 0 ]; then
    log "ERROR: All ${#profiling_jsons[@]} profiling outputs are empty"
    log "  Profiling may have failed. Check profiling/*.log and re-run module 04."
    exit 1
fi

log "Aggregating ${#profiling_jsons[@]} profiling outputs ($nonempty_count non-empty)..."
run python3 "$SCRIPT_DIR/03_workers/aggregate_ground_truth.py" \
    --profiling-dir "$PROFILING_DIR" \
    --output "$GROUND_TRUTH"

log "Output: $GROUND_TRUTH"
