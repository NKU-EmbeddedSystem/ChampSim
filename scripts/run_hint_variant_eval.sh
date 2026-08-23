#!/bin/bash
set -uo pipefail
cd /mnt/sdd/liz/pc-split/ChampSim
ROOT=/mnt/sdd/liz/pc-split/ChampSim
BWRUN=/home/liz/data_storage/pc-split/ChampSim/artifacts/runs/l1d-bw/20260822-175017
BATCH=/home/liz/data_storage/pc-split/ChampSim/artifacts/runs/l1d-baseline-batch/20260822-173040
TRACE_DIR=/mnt/sdd/trace/CRC2_trace/discriminative
JOBS=90; running=0
WARMUP=1000000; SIM=10000000

run_one() { # bin hint trace outfile
    "$1" --warmup-instructions "$WARMUP" --simulation-instructions "$SIM" --hint-file "$2" "$3" > "$4" 2>&1
}

# bw3200: fixed native hint + filter variant (regenerate first).
# PCs with all-tied candidate AMATs (cold/tail PCs, no per-PC signal) get
# the trace's offline global best single policy instead of a tie-break pick.
ipc_of() { grep -oP "cumulative IPC:\s*\K[\d.]+" "$1" 2>/dev/null | tail -1; }
for tdir in "$BATCH"/*/; do
    tname=$(basename "$tdir")
    trace=$(ls "$TRACE_DIR"/$(echo $tname | sed 's/_[0-9]*B$//')_*.trace.xz 2>/dev/null | head -1)
    [ -z "$trace" ] && { echo "no trace for $tname"; continue; }
    best_name=""; best_ipc=0
    for ef in "$tdir"/eval/*.txt; do
        [ -f "$ef" ] || continue
        fn=$(basename "$ef" .txt)
        [ "$fn" = "b0_no" ] && continue
        v=$(ipc_of "$ef")
        if [ -n "$v" ] && python3 -c "exit(0 if float('${v:-0}') > float('$best_ipc') else 1)" 2>/dev/null; then
            best_ipc="$v"; best_name="$fn"
        fi
    done
    python3 tools/l1d_hint_demo/oracle_gen.py generate --labels "$tdir/ground_truth.jsonl" --output "$tdir/hint.bin" \
        ${best_name:+--default "$best_name"} > /dev/null 2>&1
    python3 tools/l1d_hint_demo/oracle_gen.py generate --labels "$tdir/ground_truth.jsonl" --output "$tdir/hint_filter.bin" --filter \
        ${best_name:+--default "$best_name"} > /dev/null 2>&1
    run_one bin/champsim_hint_eval "$tdir/hint.bin" "$trace" "$tdir/eval/b2_hint.txt" &
    ((running++)) || true
    run_one bin/champsim_hint_eval "$tdir/hint_filter.bin" "$trace" "$tdir/eval/b5_hint_filter.txt" &
    ((running++)) || true
    if [ "$running" -ge "$JOBS" ]; then wait -n 2>/dev/null || true; ((running--)) || true; fi
done

# bw1600/bw800: native / filter / tax / gate
for tdir in "$BWRUN"/*/; do
    tname=$(basename "$tdir"); [ -d "$tdir/bw1600" ] || continue
    trace=$(ls "$TRACE_DIR"/$(echo $tname | sed 's/_[0-9]*B$//')_*.trace.xz 2>/dev/null | head -1)
    [ -z "$trace" ] && continue
    for bw in bw1600 bw800; do
        bwdir="$tdir/$bw"; n=${bw#bw}
        for v in "hint.bin b2_hint_native" "hint_filter.bin b5_hint_filter" "hint_tax_l05.bin b3_hint_tax_l05" "hint_tax_l20.bin b3_hint_tax_l20" "hint_gate_t90.bin b4_hint_gate_t90"; do
            set -- $v
            [ -f "$bwdir/$1" ] || continue
            run_one "bin/champsim_hint_eval_${bw}" "$bwdir/$1" "$trace" "$bwdir/$2.txt" &
            ((running++)) || true
            if [ "$running" -ge "$JOBS" ]; then wait -n 2>/dev/null || true; ((running--)) || true; fi
        done
    done
done
wait
echo EVAL_DONE
