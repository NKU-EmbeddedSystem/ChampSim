#!/bin/bash
# Re-run only missing or incomplete outputs in a l1d-seg style directory.
# Usage: run_seg_resume.sh <warmup> <sim> <seg_dir>
set -uo pipefail
ROOT=/mnt/sdd/liz/pc-split/ChampSim
cd "$ROOT"
BATCH=/home/liz/data_storage/pc-split/ChampSim/artifacts/runs/l1d-baseline-batch/20260822-173040
BWRUN=/home/liz/data_storage/pc-split/ChampSim/artifacts/runs/l1d-bw/20260822-175017
TRACE_DIR=/mnt/sdd/trace/CRC2_trace/discriminative
OUT="${3:?seg dir required}"
JOBS=${JOBS:-90}; running=0
WARMUP="${1:-1000000}"; SIM="${2:-10000000}"

ipc() { grep -oP "cumulative IPC:\s*\K[\d.]+" "$1" 2>/dev/null | tail -1; }
done_f() { [ -f "$1" ] && grep -q "Simulation complete" "$1"; }

run_one() { # bin hint_or_empty trace outfile
    if [ -n "$2" ]; then
        "$1" --warmup-instructions "$WARMUP" --simulation-instructions "$SIM" --hint-file "$2" "$3" > "$4" 2>&1
    else
        "$1" --warmup-instructions "$WARMUP" --simulation-instructions "$SIM" "$3" > "$4" 2>&1
    fi
}

for trace in "$TRACE_DIR"/*.trace.xz; do
    tname=$(basename "$trace" .trace.xz)
    wl=$(echo "$tname" | sed 's/_[0-9]*B$//')
    first=$(ls "$TRACE_DIR"/${wl}_*.trace.xz | head -1)
    [ "$(basename "$trace")" != "$(basename "$first")" ] && continue
    [ -d "$BATCH/$tname" ] || continue

    for bw in 3200 1600 800; do
        if [ "$bw" = "3200" ]; then evaldir="$BATCH/$tname/eval"; suffix=""
        else evaldir="$BWRUN/$tname/bw${bw}"; suffix="_bw${bw}"; fi
        odir="$OUT/${tname}/bw${bw}"; mkdir -p "$odir"

        for fam in sandbox dspatch mlop stream; do
            done_f "$odir/${fam}.txt" && continue
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
            if [ "$running" -ge "$JOBS" ]; then wait -n 2>/dev/null || true; ((running--)) || true; fi
        done

        if [ "$bw" = "3200" ]; then nob="bin/champsim_l1d_no_d1"; else nob="bin/champsim_l1d_no_d1_bw${bw}"; fi
        done_f "$odir/no.txt" || { run_one "$nob" "" "$trace" "$odir/no.txt" & ((running++)) || true; }

        if [ "$bw" = "3200" ]; then hdir="$BATCH/$tname"; he="bin/champsim_hint_eval"
        else hdir="$BWRUN/$tname/bw${bw}"; he="bin/champsim_hint_eval_bw${bw}"; fi
        done_f "$odir/hint.txt" || { run_one "$he" "$hdir/hint.bin" "$trace" "$odir/hint.txt" & ((running++)) || true; }
        done_f "$odir/hint_filter.txt" || { run_one "$he" "$hdir/hint_filter.bin" "$trace" "$odir/hint_filter.txt" & ((running++)) || true; }

        if [ "$running" -ge "$JOBS" ]; then wait -n 2>/dev/null || true; ((running--)) || true; fi
    done
done
wait
echo SEGRESUME_DONE
