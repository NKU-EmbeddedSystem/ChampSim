#!/bin/bash
# Batch L1D baseline across multiple traces (one per workload).
# All traces run in parallel. Binaries must already be built.
# Usage: bash scripts/run_batch_l1d.sh [warmup] [sim]
set -uo pipefail

WARMUP="${1:-1000000}"
SIM="${2:-10000000}"
JOBS="${JOBS:-90}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$ROOT/bin"
DEMO_DIR="$ROOT/tools/l1d_hint_demo"
TRACE_DIR="/mnt/sdd/trace/CRC2_trace/discriminative"
RUN_BASE="$ROOT/artifacts/runs/l1d-baseline-batch"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$RUN_BASE/$TIMESTAMP"

mkdir -p "$RUN_DIR"
MAIN_LOG="$RUN_DIR/main.log"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$MAIN_LOG"; }

# Pick one trace per workload (first alphabetically)
TRACES=()
for wl in astar cactusADM h264ref libquantum mcf milc omnetpp perlbench soplex sphinx3 xalancbmk zeusmp; do
    t=$(ls "$TRACE_DIR"/${wl}_*.trace.xz 2>/dev/null | head -1)
    [ -n "$t" ] && TRACES+=("$t")
done

log "══════════════════════════════════════════════════════════"
log "  L1D Baseline Batch"
log "  Traces: ${#TRACES[@]}  Warmup: $WARMUP  Sim: $SIM  Jobs: $JOBS"
log "══════════════════════════════════════════════════════════"

# Check binaries exist
NBINS=$(ls "$BIN_DIR"/champsim_l1d_* 2>/dev/null | wc -l)
if [ "$NBINS" -lt 2 ]; then
    log "ERROR: Profiling binaries not found. Run build_and_run_l1d.sh first."
    exit 1
fi
log "Found $NBINS profiling binaries"

# ── Phase 1: Run ALL (trace × binary) profiling in parallel ──
log "Phase 1: Running all profiling sims in parallel (JOBS=$JOBS)..."
running=0

for trace in "${TRACES[@]}"; do
    tname=$(basename "$trace" .trace.xz)
    tdir="$RUN_DIR/$tname"
    mkdir -p "$tdir/profiling" "$tdir/eval"

    # B0 baseline
    "$BIN_DIR/champsim_no" --warmup-instructions "$WARMUP" --simulation-instructions "$SIM" "$trace" \
        > "$tdir/eval/b0_no.txt" 2>&1 &
    ((running++)) || true

    # All profiling binaries
    for bin_path in "$BIN_DIR"/champsim_l1d_*; do
        [ -x "$bin_path" ] || continue
        bname=$(basename "$bin_path")
        [[ "$bname" =~ ^champsim_l1d_(.+)_d([0-9]+)$ ]] || continue
        pref="${BASH_REMATCH[1]}"
        deg="${BASH_REMATCH[2]}"

        (
            "$bin_path" --warmup-instructions "$WARMUP" --simulation-instructions "$SIM" "$trace" \
                > "$tdir/eval/${pref}_d${deg}.txt" 2>/dev/null
            grep '^{' "$tdir/eval/${pref}_d${deg}.txt" > "$tdir/profiling/${tname}__${pref}__${deg}.json"
        ) &
        ((running++)) || true

        if [ "$running" -ge "$JOBS" ]; then
            wait -n 2>/dev/null || true
            ((running--)) || true
        fi
    done
done
wait
log "  Phase 1 complete."

# ── Phase 2: Per-trace aggregate + hint + B2 (parallel) ──
log "Phase 2: Aggregation + B2 evaluation..."
echo "trace|B0_IPC|B1_IPC|B1_name|B2_IPC" > "$RUN_DIR/results.csv"
running=0

for trace in "${TRACES[@]}"; do
    tname=$(basename "$trace" .trace.xz)
    tdir="$RUN_DIR/$tname"

    (
        # Find B1 best
        best_ipc="0"
        best_name=""
        for ef in "$tdir"/eval/*.txt; do
            [ -f "$ef" ] || continue
            fn=$(basename "$ef" .txt)
            [[ "$fn" == "b0_no" ]] && continue
            ipc=$(grep -oP "cumulative IPC:\s*\K[\d.]+" "$ef" | tail -1)
            if [ -n "$ipc" ] && python3 -c "exit(0 if float('${ipc:-0}') > float('$best_ipc'))" 2>/dev/null; then
                best_ipc="$ipc"
                best_name="$fn"
            fi
        done
        [ -n "$best_name" ] && cp "$tdir/eval/${best_name}.txt" "$tdir/eval/b1_best.txt"

        # Aggregate + hint
        python3 "$ROOT/tools/profiling/03_workers/aggregate_ground_truth.py" \
            --profiling-dir "$tdir/profiling" --output "$tdir/ground_truth.jsonl" > /dev/null 2>&1
        python3 "$DEMO_DIR/oracle_gen.py" generate \
            --labels "$tdir/ground_truth.jsonl" --output "$tdir/hint.bin" > /dev/null 2>&1

        # B2 eval
        "$BIN_DIR/champsim_hint_eval" --warmup-instructions "$WARMUP" --simulation-instructions "$SIM" \
            --hint-file "$tdir/hint.bin" "$trace" > "$tdir/eval/b2_hint.txt" 2>&1

        # Extract IPCs
        b0_ipc=$(grep -oP "cumulative IPC:\s*\K[\d.]+" "$tdir/eval/b0_no.txt" | tail -1)
        b2_ipc=$(grep -oP "cumulative IPC:\s*\K[\d.]+" "$tdir/eval/b2_hint.txt" | tail -1)

        echo "$tname|$b0_ipc|${best_ipc}|$best_name|$b2_ipc" >> "$RUN_DIR/results.csv"
        echo "[$(date '+%H:%M:%S')]   [DONE] $tname: B0=$b0_ipc B1=$best_ipc($best_name) B2=$b2_ipc" >> "$MAIN_LOG"
    ) &
    ((running++)) || true
    if [ "$running" -ge "$JOBS" ]; then
        wait -n 2>/dev/null || true
        ((running--)) || true
    fi
done
wait
log "  Phase 2 complete."

# ── Summary table ──
log ""
log "══════════════════════════════════════════════════════════"
log "  RESULTS SUMMARY"
log "══════════════════════════════════════════════════════════"
printf "%-20s %8s %8s %8s %12s %8s\n" "Trace" "B0" "B1" "B2" "B1_name" "B2>B1?"
printf "%-20s %8s %8s %8s %12s %8s\n" "-----" "--" "--" "--" "-------" "------"

b2_wins=0
total=0
while IFS='|' read -r tname b0 b1 b1name b2; do
    [[ "$tname" == "trace" ]] && continue
    [ -z "$tname" ] && continue
    ((total++)) || true
    verdict="✗"
    if python3 -c "exit(0 if float('${b2:-0}') > float('${b1:-0}'))" 2>/dev/null; then
        verdict="✓"
        ((b2_wins++)) || true
    fi
    printf "%-20s %8s %8s %8s %12s %8s\n" "$tname" "$b0" "$b1" "$b2" "$b1name" "$verdict"
done < "$RUN_DIR/results.csv"

log ""
log "B2 > B1: $b2_wins / $total traces"
log "Results: $RUN_DIR/results.csv"
log "══════════════════════════════════════════════════════════"
