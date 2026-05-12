#!/usr/bin/env bash
#
# run_pipeline.sh — Profiling Pipeline Orchestrator
#
# Thin wrapper that calls standalone modules/ scripts in sequence.
# Use --stage N to run a single stage; omit for all stages 1-7.
#
# Usage:
#   ./run_pipeline.sh <benchmark>              # run all stages
#   ./run_pipeline.sh <benchmark> --stage 4    # run specific stage
#   ./run_pipeline.sh <benchmark> --force      # re-run all (ignore idempotency)
#   ./run_pipeline.sh <benchmark> --dry-run    # preview commands
#   ./run_pipeline.sh <benchmark> --setup      # run setup first, then pipeline
#   ./run_pipeline.sh --setup-only             # only run setup (no benchmark)
#   ./run_pipeline.sh <benchmark> --jobs 8     # set concurrency
#
# For individual module usage, see modules/0X_*.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

BENCHMARK="${1:-}"
shift 2>/dev/null || true

STAGE="all"
DRY_RUN=false
DO_SETUP=false
SETUP_ONLY=false
FORCE=false
JOBS="${JOBS:-4}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stage)       STAGE="$2"; shift 2 ;;
        --dry-run)     DRY_RUN=true; shift ;;
        --setup)       DO_SETUP=true; shift ;;
        --setup-only)  SETUP_ONLY=true; shift ;;
        --force)       FORCE=true; shift ;;
        --jobs)        JOBS="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Setup only ──────────────────────────────────────────────
if $SETUP_ONLY; then
    bash "$SCRIPT_DIR/setup.sh"
    exit 0
fi

if [ -z "$BENCHMARK" ]; then
    echo "Usage: $0 <benchmark> [--stage N] [--force] [--dry-run] [--setup] [--jobs N]"
    echo "       $0 --setup-only"
    echo ""
    echo "Stages:"
    echo "  1  Parse SimPoints       → data/<bench>/simpoints.json"
    echo "  2  Disassemble binary    → data/<bench>/disasm_index.json"
    echo "  3  Generate traces       → data/<bench>/traces/*.xz"
    echo "  4  Run profiling         → data/<bench>/profiling/*.json"
    echo "  5  Extract context       → data/<bench>/assembly_context.jsonl"
    echo "  6  Aggregate labels      → data/<bench>/ground_truth.jsonl"
    echo "  7  Build dataset         → data/<bench>/tuning_dataset.jsonl"
    echo ""
    echo "Examples:"
    echo "  $0 400.perlbench                     # all stages"
    echo "  $0 400.perlbench --stage 4 --force   # re-run profiling"
    echo "  $0 400.perlbench --dry-run           # preview"
    exit 1
fi

log() { echo "[$(date '+%H:%M:%S')] [pipeline] $*"; }

# ── Setup ───────────────────────────────────────────────────
if $DO_SETUP; then
    log "Running environment setup..."
    bash "$SCRIPT_DIR/setup.sh"
fi

# Build module flags
MODULE_FLAGS=""
$FORCE   && MODULE_FLAGS="$MODULE_FLAGS --force"
$DRY_RUN && MODULE_FLAGS="$MODULE_FLAGS --dry-run"

MODULES_DIR="$SCRIPT_DIR/modules"

run_module() {
    local num="$1"
    local script
    script=$(ls "$MODULES_DIR/0${num}_"*.sh 2>/dev/null | head -1)
    log "=== STAGE $num ==="
    if [ -n "$script" ] && [ -f "$script" ]; then
        # Only pass --jobs to parallel stages (3 and 4)
        local extra_flags="$MODULE_FLAGS"
        if [ "$num" = "3" ] || [ "$num" = "4" ]; then
            extra_flags="$extra_flags --jobs $JOBS"
        fi
        bash "$script" "$BENCHMARK" $extra_flags
    else
        log "ERROR: Module script not found: $MODULES_DIR/0${num}_*.sh"
        exit 1
    fi
}

# ── Run stages ──────────────────────────────────────────────
log "Pipeline start: benchmark=$BENCHMARK stage=$STAGE jobs=$JOBS"
log "Output directory: $DATA_ROOT/$BENCHMARK"
echo ""

should_run() { [ "$STAGE" = "all" ] || [ "$STAGE" = "$1" ]; }

should_run 1 && run_module 1
should_run 2 && run_module 2
should_run 3 && run_module 3
should_run 4 && run_module 4
should_run 5 && run_module 5
should_run 6 && run_module 6
should_run 7 && run_module 7

# ── Summary ─────────────────────────────────────────────────
echo ""
log "Pipeline complete for $BENCHMARK"
log ""
log "Output files:"
BENCH_DIR="$DATA_ROOT/$BENCHMARK"
[ -f "$BENCH_DIR/simpoints.json" ]          && echo "  SimPoints:     $BENCH_DIR/simpoints.json"
[ -f "$BENCH_DIR/disasm_index.json" ]        && echo "  Disassembly:   $BENCH_DIR/disasm_index.json"
[ -d "$BENCH_DIR/traces" ]                   && echo "  Traces:        $BENCH_DIR/traces"
[ -d "$BENCH_DIR/profiling" ]                && echo "  Profiling:     $BENCH_DIR/profiling"
[ -f "$BENCH_DIR/assembly_context.jsonl" ]   && echo "  Asm Context:   $BENCH_DIR/assembly_context.jsonl"
[ -f "$BENCH_DIR/ground_truth.jsonl" ]       && echo "  Ground Truth:  $BENCH_DIR/ground_truth.jsonl"
[ -f "$BENCH_DIR/tuning_dataset.jsonl" ]     && echo "  Tuning Dataset: $BENCH_DIR/tuning_dataset.jsonl"
