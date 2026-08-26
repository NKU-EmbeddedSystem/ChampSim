#!/bin/bash
# Segment runs for the bandwidth-tax hint variants (bw1600/800 only —
# the tax schemes were designed for bandwidth-constrained runs).
# Writes <seg_dir>/<trace>/bw<bw>/{tax_l05,tax_l20}.txt.
set -uo pipefail
ROOT=/public/home/liz/pc-split/ChampSim
cd "$ROOT"
BWRUN=$ROOT/artifacts/runs/l1d-bw/20260822-173819
BATCH=$ROOT/artifacts/runs/l1d-baseline-batch/20260822-172852
TRACE_DIR=/public/home/liz/trace/CRC2_trace/discriminative
OUT="${1:-$ROOT/artifacts/runs/l1d-seg-x10}"
ONLY_BW="${2:-}"  # optional: "3200"/"1600"/"800" to restrict the bandwidth
JOBS=${JOBS:-200}; running=0
WARMUP=10000000; SIM=100000000

run_one() { # bin hint trace outfile
    timeout 21600 "$1" --warmup-instructions "$WARMUP" --simulation-instructions "$SIM" --hint-file "$2" "$3" > "$4" 2>&1
}

for trace in "$TRACE_DIR"/*.trace.xz; do
    tname=$(basename "$trace" .trace.xz)
    wl=$(echo "$tname" | sed 's/_[0-9]*B$//')
    first=$(ls "$TRACE_DIR"/${wl}_*.trace.xz | head -1)
    [ "$(basename "$trace")" != "$(basename "$first")" ] && continue
    [ -d "$BWRUN/$tname" ] || continue

    # bw3200: tax hints live in the batch trace dir, run with the 3200 binary
    if [ -z "$ONLY_BW" ] || [ "$ONLY_BW" = "3200" ]; then
    for v in "hint_tax_l05.bin tax_l05" "hint_tax_l20.bin tax_l20"; do
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
        for v in "hint_tax_l05.bin tax_l05" "hint_tax_l20.bin tax_l20"; do
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
echo SEGTAX_DONE
