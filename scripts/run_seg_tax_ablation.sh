#!/bin/bash
# Segment runs for the tax ablation ladder (w / wc / wci variants) at all
# bandwidths. The wc labels are NOT the old l05 ones (measured: 17.2% of
# PCs differ on cactusADM), so tax_wc gets its own runs.
# Writes <seg_dir>/<trace>/bw<bw>/{tax_w,tax_wc,tax_wci}.txt.
set -uo pipefail
ROOT=/mnt/sdd/liz/pc-split/ChampSim
cd "$ROOT"
BWRUN=/home/liz/data_storage/pc-split/ChampSim/artifacts/runs/l1d-bw/20260822-175017
BATCH=/home/liz/data_storage/pc-split/ChampSim/artifacts/runs/l1d-baseline-batch/20260822-173040
TRACE_DIR=/mnt/sdd/trace/CRC2_trace/discriminative
OUT="${1:-/home/liz/data_storage/pc-split/ChampSim/artifacts/runs/l1d-seg}"
ONLY_BW="${2:-}"  # optional: "3200"/"1600"/"800" to restrict the bandwidth
JOBS=${JOBS:-90}; running=0
WARMUP=1000000; SIM=10000000
run_one() { # bin hint trace outfile
    "$1" --warmup-instructions "$WARMUP" --simulation-instructions "$SIM" --hint-file "$2" "$3" > "$4" 2>&1
}

for trace in "$TRACE_DIR"/*.trace.xz; do
    tname=$(basename "$trace" .trace.xz)
    wl=$(echo "$tname" | sed 's/_[0-9]*B$//')
    first=$(ls "$TRACE_DIR"/${wl}_*.trace.xz | head -1)
    [ "$(basename "$trace")" != "$(basename "$first")" ] && continue
    [ -d "$BWRUN/$tname" ] || continue

    # bw3200: ablation hints live in the batch trace dir, 3200 binary
    if [ -z "$ONLY_BW" ] || [ "$ONLY_BW" = "3200" ]; then
    for v in "hint_tax_w.bin tax_w" "hint_tax_wc.bin tax_wc" "hint_tax_wci.bin tax_wci"; do
        set -- $v
        [ -f "$BATCH/$tname/$1" ] || continue
        out="$OUT/$tname/bw3200/$2.txt"; mkdir -p "$OUT/$tname/bw3200"
        [ -f "$out" ] && grep -q "Simulation complete" "$out" && continue
        run_one bin/champsim_hint_eval "$BATCH/$tname/$1" "$trace" "$out" &
        ((running++)) || true
        if [ "$running" -ge "$JOBS" ]; then wait -n 2>/dev/null || true; ((running--)) || true; fi
    done
    fi

    for bw in 1600 800; do
        [ -n "$ONLY_BW" ] && [ "$ONLY_BW" != "$bw" ] && continue
        bwdir="$BWRUN/$tname/bw$bw"
        odir="$OUT/$tname/bw$bw"; mkdir -p "$odir"
        for v in "hint_tax_w.bin tax_w" "hint_tax_wc.bin tax_wc" "hint_tax_wci.bin tax_wci"; do
            set -- $v
            [ -f "$bwdir/$1" ] || continue
            out="$odir/$2.txt"
            [ -f "$out" ] && grep -q "Simulation complete" "$out" && continue
            run_one "bin/champsim_hint_eval_bw${bw}" "$bwdir/$1" "$trace" "$out" &
            ((running++)) || true
            if [ "$running" -ge "$JOBS" ]; then wait -n 2>/dev/null || true; ((running--)) || true; fi
        done
    done
done
wait
echo SEGTAX_ABLATION_DONE
