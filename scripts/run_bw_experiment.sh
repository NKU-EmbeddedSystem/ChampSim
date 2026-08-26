#!/bin/bash
# Build bandwidth-constrained binaries and run all traces in parallel.
# Usage: bash scripts/run_bw_experiment.sh [warmup] [sim]
set -uo pipefail

WARMUP="${1:-1000000}"
SIM="${2:-10000000}"
JOBS="${JOBS:-90}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$ROOT/bin"
DEMO_DIR="$ROOT/tools/l1d_hint_demo"
BW_CONFIG_DIR="$ROOT/configs/l1d-bw"
TRACE_DIR="/public/home/liz/trace/CRC2_trace/discriminative"
RUN_BASE="$ROOT/artifacts/runs/l1d-bw"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$RUN_BASE/$TIMESTAMP"

mkdir -p "$RUN_DIR/logs"
MAIN_LOG="$RUN_DIR/main.log"
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$MAIN_LOG"; }

log "══════════════════════════════════════════════════════════"
log "  L1D Bandwidth-Constrained Experiment"
log "  Warmup: $WARMUP  Sim: $SIM  Jobs: $JOBS"
log "══════════════════════════════════════════════════════════"

# ── Step 1: Generate BW configs ──
log "Step 1: Generating bandwidth configs..."
python3 "$DEMO_DIR/gen_bw_configs.py"

# ── Step 2: Build bw1600 and bw800 binaries (bw3200 = existing) ──
log "Step 2: Building bandwidth-constrained binaries..."
cd "$ROOT"
GLOBAL_OPTIONS="$ROOT/global.options"
ORIG_OPTIONS="$(cat "$GLOBAL_OPTIONS")"

build_one() {
    local cfg="$1" name="$2" macro="$3"
    if [ -x "$BIN_DIR/$name" ]; then
        return 0
    fi
    if [ -n "$macro" ]; then
        printf '%s\n%s\n' "$ORIG_OPTIONS" "$macro" > "$GLOBAL_OPTIONS"
    fi
    python3 config.sh "$cfg" > /dev/null 2>&1
    rm -f .csconfig/generated_environment.o
    if make -j"$(nproc)" > "$RUN_DIR/logs/build_${name}.log" 2>&1; then
        log "  [OK] $name${macro:+ ($macro)}"
    else
        log "  [FAIL] $name"
    fi
    printf '%s\n' "$ORIG_OPTIONS" > "$GLOBAL_OPTIONS"
}

for bw in bw1600 bw800; do
    log "  Building $bw variants..."
    while IFS='|' read -r cfg name macro; do
        [ -n "$cfg" ] || continue
        build_one "$cfg" "$name" "$macro"
    done < <(python3 - "$BW_CONFIG_DIR/manifest.json" "$bw" <<'PYEOF'
import json, sys
mf, bw = sys.argv[1], sys.argv[2]
for e in json.load(open(mf)):
    if e.get("bw_level") == bw and e.get("base_prefetcher") not in ("no_baseline", "hint_eval"):
        print("|".join((e["config_path"], e["name"], e.get("degree_macro") or "")))
PYEOF
)
done
printf '%s\n' "$ORIG_OPTIONS" > "$GLOBAL_OPTIONS"

# ── Step 3: Pick traces (one per workload) ──
TRACES=()
for wl in astar cactusADM h264ref libquantum mcf milc omnetpp perlbench soplex sphinx3 xalancbmk zeusmp; do
    t=$(ls "$TRACE_DIR"/${wl}_*.trace.xz 2>/dev/null | head -1)
    [ -n "$t" ] && TRACES+=("$t")
done
log "Step 3: ${#TRACES[@]} traces selected"

# ── Step 4: Run ALL (trace × prefetcher × bw_level) in parallel ──
log "Step 4: Running all simulations (JOBS=$JOBS)..."
running=0

for trace in "${TRACES[@]}"; do
    tname=$(basename "$trace" .trace.xz)

    for bw in bw1600 bw800; do
        tdir="$RUN_DIR/$tname/$bw"
        mkdir -p "$tdir"

        # B0 baseline for this BW level
        no_bin="$BIN_DIR/champsim_no_${bw}"
        if [ -x "$no_bin" ]; then
            "$no_bin" --warmup-instructions "$WARMUP" --simulation-instructions "$SIM" "$trace" \
                > "$tdir/b0_no.txt" 2>&1 &
            ((running++)) || true
            if [ "$running" -ge "$JOBS" ]; then wait -n 2>/dev/null || true; ((running--)) || true; fi
        fi

        # All profiling binaries for this BW level
        for bin_path in "$BIN_DIR"/champsim_l1d_*_"${bw}"; do
            [ -x "$bin_path" ] || continue
            bname=$(basename "$bin_path")
            pref_part="${bname#champsim_l1d_}"
            pref_part="${pref_part%_${bw}}"

            "$bin_path" --warmup-instructions "$WARMUP" --simulation-instructions "$SIM" "$trace" \
                > "$tdir/${pref_part}.txt" 2>&1 &
            ((running++)) || true
            if [ "$running" -ge "$JOBS" ]; then wait -n 2>/dev/null || true; ((running--)) || true; fi
        done
    done
done
wait
log "  All simulations complete."

# ── Step 5: Extract IPCs and compare rankings ──
log "Step 5: Extracting results..."
python3 "$DEMO_DIR/compare_bw.py" "$RUN_DIR" 2>&1 | tee -a "$MAIN_LOG"

log "Done. Run dir: $RUN_DIR"
