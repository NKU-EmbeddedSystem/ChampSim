#!/bin/bash
# Re-run per-segment sims: per trace x bw -> {no, best tier of each of the
# 4 families, hint, hint_filter}, 1M warmup + 10M sim, 500k heartbeats.
set -uo pipefail
ROOT=/public/home/liz/pc-split/ChampSim
cd "$ROOT"
BATCH="${BATCH_DIR:-/public/home/liz/data_storage/pc-split/ChampSim/artifacts/runs/l1d-baseline-batch/20260822-173040}"
BWRUN="${BWRUN_DIR:-/public/home/liz/data_storage/pc-split/ChampSim/artifacts/runs/l1d-bw/20260822-175017}"
OUT="${3:-/public/home/liz/data_storage/pc-split/ChampSim/artifacts/runs/l1d-seg}"
mkdir -p "$OUT"
TRACE_DIR=/public/home/liz/trace/CRC2_trace/discriminative
JOBS=${JOBS:-90}; running=0
WARMUP="${1:-1000000}"; SIM="${2:-10000000}"

# Map: trace -> eval dir holding the 12 policy IPCs per bw
ipc() { grep -oP "cumulative IPC:\s*\K[\d.]+" "$1" 2>/dev/null | tail -1; }

run_one() { # bin hint_or_empty trace outfile
    # 6h cap: mcf+hint_eval runs pathologically slowly (prefetch flood through
    # the L1D tag queues); without a cap they would block SEGRUN_DONE forever.
    if [ -n "$2" ]; then
        timeout 21600 "$1" --warmup-instructions "$WARMUP" --simulation-instructions "$SIM" --hint-file "$2" "$3" > "$4" 2>&1
    else
        timeout 21600 "$1" --warmup-instructions "$WARMUP" --simulation-instructions "$SIM" "$3" > "$4" 2>&1
    fi
}

for trace in "$TRACE_DIR"/*.trace.xz; do
    tname=$(basename "$trace" .trace.xz)
    # one trace per workload only (same selection as batch: first alphabetically per wl)
    wl=$(echo "$tname" | sed 's/_[0-9]*B$//')
    first=$(ls "$TRACE_DIR"/${wl}_*.trace.xz | head -1)
    [ "$(basename "$trace")" != "$(basename "$first")" ] && continue
    [ -d "$BATCH/$tname" ] || continue

    for bw in 3200 1600 800; do
        if [ "$bw" = "3200" ]; then evaldir="$BATCH/$tname/eval"; suffix=""
        else evaldir="$BWRUN/$tname/bw${bw}"; suffix="_bw${bw}"; fi
        odir="$OUT/${tname}/bw${bw}"; mkdir -p "$odir"

        # pick best tier per family by overall IPC
        for fam in sandbox dspatch mlop stream; do
            best=""; bestipc=0
            for f in "$evaldir/${fam}_d"*.txt; do
                [ -f "$f" ] || continue
                v=$(ipc "$f")
                if [ -n "$v" ] && python3 -c "exit(0 if float('$v') > float('$bestipc') else 1)" 2>/dev/null; then
                    bestipc="$v"; best=$(basename "$f" .txt)
                fi
            done
            [ -n "$best" ] || continue
            run_one "bin/champsim_l1d_${best}${suffix}" "" "$trace" "$odir/${fam}.txt" &
            ((running++)) || true
        done

        # no baseline
        if [ "$bw" = "3200" ]; then nob="bin/champsim_l1d_no_d1"; else nob="bin/champsim_l1d_no_d1_bw${bw}"; fi
        run_one "$nob" "" "$trace" "$odir/no.txt" &
        ((running++)) || true

        # hints (trained at this bw)
        if [ "$bw" = "3200" ]; then hdir="$BATCH/$tname"; he="bin/champsim_hint_eval"
        else hdir="$BWRUN/$tname/bw${bw}"; he="bin/champsim_hint_eval_bw${bw}"; fi
        run_one "$he" "$hdir/hint.bin" "$trace" "$odir/hint.txt" &
        ((running++)) || true
        run_one "$he" "$hdir/hint_filter.bin" "$trace" "$odir/hint_filter.txt" &
        ((running++)) || true

        if [ "$running" -ge "$JOBS" ]; then wait -n 2>/dev/null || true; ((running--)) || true; fi
    done
done
wait
echo SEGRUN_DONE
