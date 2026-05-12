#!/usr/bin/env bash
# Module 7: Build instruction-tuning dataset from assembly context + ground truth.
# Output: data/<benchmark>/tuning_dataset.jsonl
#
# Usage:
#   ./modules/07_build_dataset.sh <benchmark> [--force] [--dry-run]
#
# Re-runnable: Re-run when ground truth or context changes.
# Freshness check: skips if output is newer than both inputs.
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
ASSEMBLY_CTX="$BENCH_DIR/assembly_context.jsonl"
GROUND_TRUTH="$BENCH_DIR/ground_truth.jsonl"
TUNING_DATASET="$BENCH_DIR/tuning_dataset.jsonl"
MODULE_NAME="[07_dataset]"

log()  { echo "[$(date '+%H:%M:%S')] $MODULE_NAME $*"; }
run()  {
    if $DRY_RUN; then
        echo "[DRY-RUN] $*"
    else
        eval "$@"
    fi
}

# Prerequisites
if [ ! -f "$ASSEMBLY_CTX" ]; then
    log "ERROR: assembly_context.jsonl not found. Run module 05 first."
    exit 1
fi
if [ ! -f "$GROUND_TRUTH" ]; then
    log "ERROR: ground_truth.jsonl not found. Run module 06 first."
    exit 1
fi

# Idempotency with freshness check
if [ -f "$TUNING_DATASET" ] && [ "$FORCE" != "true" ]; then
    td_mtime=$(stat -c %Y "$TUNING_DATASET")
    ctx_mtime=$(stat -c %Y "$ASSEMBLY_CTX")
    gt_mtime=$(stat -c %Y "$GROUND_TRUTH")
    if [ "$td_mtime" -ge "$ctx_mtime" ] && [ "$td_mtime" -ge "$gt_mtime" ]; then
        td_lines=$(wc -l < "$TUNING_DATASET")
        if [ "$td_lines" -gt 0 ]; then
            log "[SKIP] tuning_dataset.jsonl is up-to-date ($td_lines lines)"
            log "  Use --force to rebuild"
            exit 0
        else
            log "[WARN] tuning_dataset.jsonl exists but is empty, rebuilding..."
        fi
    else
        log "  Rebuilding (newer inputs detected)..."
    fi
fi

log "Building tuning dataset..."
run python3 "$SCRIPT_DIR/build_tuning_dataset.py" \
    --context "$ASSEMBLY_CTX" \
    --labels "$GROUND_TRUTH" \
    --output "$TUNING_DATASET"

log "Output: $TUNING_DATASET"
