#!/bin/bash
# Retrain per-(trace, bw) hint tables from bandwidth-constrained profiling data,
# then evaluate them with the matching hint_eval binary (b2_hint_native).
# Usage: bash retrain_hint_bw.sh <bw_run_dir> [warmup] [sim]
set -uo pipefail

RUN_DIR="${1:?Usage: $0 <bw_run_dir> [warmup] [sim]}"
WARMUP="${2:-1000000}"
SIM="${3:-10000000}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TRACE_DIR="/mnt/sdd/trace/CRC2_trace/discriminative"

# ── Phase 1: extract profiling JSONL, aggregate, generate hint.bin per (trace, bw) ──
for bw in bw1600 bw800; do
    for tdir in "$RUN_DIR"/*/; do
        tname=$(basename "$tdir")
        bw_dir="$tdir/$bw"
        [ -d "$bw_dir" ] || continue
        prof_dir="$bw_dir/profiling"
        mkdir -p "$prof_dir"

        for f in "$bw_dir"/*.txt; do
            fn=$(basename "$f" .txt)
            [[ "$fn" =~ ^(b0_no|b1_best|b2_) ]] && continue
            [[ "$fn" =~ ^(.+)_d([0-9]+)$ ]] || continue
            pref="${BASH_REMATCH[1]}"; deg="${BASH_REMATCH[2]}"
            grep '^{' "$f" > "$prof_dir/${tname}__${pref}__${deg}.json"
        done

        python3 "$ROOT/tools/profiling/03_workers/aggregate_ground_truth.py" \
            --profiling-dir "$prof_dir" --output "$bw_dir/ground_truth.jsonl" > /dev/null 2>&1
        python3 "$ROOT/tools/l1d_hint_demo/oracle_gen.py" generate \
            --labels "$bw_dir/ground_truth.jsonl" --output "$bw_dir/hint.bin" > /dev/null 2>&1
        echo "[hint] $tname $bw: $(stat -c%s "$bw_dir/hint.bin" 2>/dev/null || echo MISSING) bytes"
    done
done

# ── Phase 2: evaluate native hints (parallel) ──
echo "=== running b2_hint_native sims ==="
for bw in bw1600 bw800; do
    for tdir in "$RUN_DIR"/*/; do
        tname=$(basename "$tdir")
        bw_dir="$tdir/$bw"
        hint="$bw_dir/hint.bin"
        trace="$TRACE_DIR/$tname.trace.xz"
        [ -f "$hint" ] && [ -f "$trace" ] || continue
        "$ROOT/bin/champsim_hint_eval_$bw" --warmup-instructions "$WARMUP" --simulation-instructions "$SIM" \
            --hint-file "$hint" "$trace" > "$bw_dir/b2_hint_native.txt" 2>&1 &
    done
done
wait
incomplete=$(grep -L "Simulation complete" "$RUN_DIR"/*/bw*/b2_hint_native.txt 2>/dev/null | wc -l)
echo "=== b2_hint_native done, incomplete: $incomplete ==="
