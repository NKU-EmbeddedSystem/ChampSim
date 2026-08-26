#!/bin/bash
# Regenerate all hint files with the tie -> trace-wide-global-best rule and
# clear the stale eval outputs they invalidate.
#   bw3200: hint.bin / hint_filter.bin (batch dirs)
#   bw1600/bw800: hint.bin / hint_filter.bin + tax/gate relabels (bw dirs)
set -uo pipefail
ROOT=/public/home/liz/pc-split/ChampSim
cd "$ROOT"
BATCH=/public/home/liz/pc-split/ChampSim/artifacts/runs/l1d-baseline-batch/20260822-172852
BWRUN=/public/home/liz/pc-split/ChampSim/artifacts/runs/l1d-bw/20260822-173819
SEGDIR=/public/home/liz/pc-split/ChampSim/artifacts/runs/l1d-seg-x10

ipc_of() { grep -oP "cumulative IPC:\s*\K[\d.]+" "$1" 2>/dev/null | tail -1; }

# global best single policy (name like stream_d8) from an eval dir
gb_of() { # $1 = dir with *_d<deg>.txt files
    local dir="$1" best_name="" best_ipc=0 fn v
    for f in "$dir"/*_d*.txt; do
        [ -f "$f" ] || continue
        fn=$(basename "$f" .txt)
        v=$(ipc_of "$f")
        if [ -n "$v" ] && python3 -c "exit(0 if float('${v:-0}') > float('$best_ipc') else 1)" 2>/dev/null; then
            best_ipc="$v"; best_name="$fn"
        fi
    done
    echo "$best_name"
}

# ── bw3200: batch hints ──
for tdir in "$BATCH"/*/; do
    tname=$(basename "$tdir"); [ -d "$tdir/eval" ] || continue
    gb=$(gb_of "$tdir/eval")
    [ -z "$gb" ] && continue
    args=(--labels "$tdir/ground_truth.jsonl")
    [ -n "$gb" ] && args+=(--default "$gb")
    python3 tools/l1d_hint_demo/oracle_gen.py generate "${args[@]}" --output "$tdir/hint.bin" >/dev/null 2>&1
    python3 tools/l1d_hint_demo/oracle_gen.py generate "${args[@]}" --output "$tdir/hint_filter.bin" --filter >/dev/null 2>&1
    rm -f "$tdir/eval/b2_hint.txt" "$tdir/eval/b5_hint_filter.txt"
    echo "regen bw3200 $tname -> default $gb"
done

# ── bw1600/800: native + filter hints with this bw's global best ──
for tdir in "$BWRUN"/*/; do
    tname=$(basename "$tdir"); [ -d "$tdir/bw1600" ] || continue
    for bw in bw1600 bw800; do
        bwdir="$tdir/$bw"
        gb=$(gb_of "$bwdir")
        [ -z "$gb" ] && continue
        args=(--labels "$bwdir/ground_truth.jsonl" --default "$gb")
        python3 tools/l1d_hint_demo/oracle_gen.py generate "${args[@]}" --output "$bwdir/hint.bin" >/dev/null 2>&1
        python3 tools/l1d_hint_demo/oracle_gen.py generate "${args[@]}" --output "$bwdir/hint_filter.bin" --filter >/dev/null 2>&1
        rm -f "$bwdir"/b2_hint_native.txt "$bwdir"/b5_hint_filter.txt \
              "$bwdir"/b3_hint_tax_l05.txt "$bwdir"/b3_hint_tax_l20.txt \
              "$bwdir"/b4_hint_gate_t90.txt "$bwdir"/b3_hint_pc_tax_l05.txt "$bwdir"/b3_hint_pc_tax_l20.txt
        echo "regen $tname $bw -> default $gb"
    done
done

# tax/gate relabels with the same tie rule (tied PCs -> this bw's global best)
python3 tools/l1d_hint_demo/relabel_hint_bw.py "$BWRUN" "$BATCH" \
    "$BWRUN/prefetch_stats.csv" > /tmp/relabel_tie.log 2>&1 && echo "relabel OK" || { echo "relabel FAIL"; tail -5 /tmp/relabel_tie.log; }

# ── l1d-seg hint runs (all bw) must be redone with the new hints ──
for tdir in "$SEGDIR"/*/; do
    for bw in bw3200 bw1600 bw800; do
        rm -f "$tdir/$bw/hint.txt" "$tdir/$bw/hint_filter.txt"
    done
done
echo REGEN_TIE_DONE
