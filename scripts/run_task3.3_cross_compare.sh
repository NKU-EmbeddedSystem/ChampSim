#!/bin/bash
# Task 3.3: 10 configs × 3 policies × 12 benchmarks = 360 runs (50M+100M)
set -uo pipefail

STAGE_DIR="$(cd "$(dirname "$0")" && pwd)/.."
TRACE_DIR="$STAGE_DIR/trace"
AMAP_DIR="${AMAP_DIR:-$STAGE_DIR/artifacts/runs/task3.1-gen-areamaps/latest}"
RUN_TS="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$STAGE_DIR/artifacts/runs/task3.3-cross-compare/$RUN_TS"
MAX_PARALLEL="${MAX_PARALLEL:-48}"
WARMUP_INSTRUCTIONS="${WARMUP_INSTRUCTIONS:-50000000}"
SIMULATION_INSTRUCTIONS="${SIMULATION_INSTRUCTIONS:-100000000}"

mkdir -p "$RUN_DIR"
ln -sfn "$RUN_TS" "$STAGE_DIR/artifacts/runs/task3.3-cross-compare/latest"

# ── Benchmarks ──
declare -A TRACES
TRACES=(
  [astar]=astar_163B [cactusADM]=cactusADM_734B [h264ref]=h264ref_178B
  [libquantum]=libquantum_964B [mcf]=mcf_46B [milc]=milc_360B
  [omnetpp]=omnetpp_4B [perlbench]=perlbench_53B [soplex]=soplex_66B
  [sphinx3]=sphinx3_883B [xalancbmk]=xalancbmk_99B [zeusmp]=zeusmp_100B
)

# ── 10 configs: (placement, migration, l1d_pref, l2c_pref, label) ──
CONFIGS=(
  "random none no no Rnd+Nomig+NoPF"
  "sort_heat none no no Sort+Nomig+NoPF"
  "first_touch none no no FCFS+Nomig+NoPF"
  "random forward no no Rnd+Fwd+NoPF"
  "random backward no no Rnd+Bwd+NoPF"     # backward-lazy via migration engine
  "random none ipcp no Rnd+Nomig+IPCP"
  "random none no ip_stride Rnd+Nomig+IPstride"
  "random none ipcp ip_stride Rnd+Nomig+BothPF"
  "first_touch backward ipcp ip_stride FCFS+Bwd+BothPF"
  "sort_heat forward ipcp ip_stride Sort+Fwd+BothPF"
)

POLICIES=(lru mockingjay rpp)

TOTAL=$((${#TRACES[@]} * ${#CONFIGS[@]} * ${#POLICIES[@]}))

cat > "$RUN_DIR/execution.log" << EOF
[$(date -u +%Y-%m-%dT%H:%M:%S)] STAGE BEGIN  stage=task3.3-cross-compare  tasks=$TOTAL  run=$RUN_TS
EOF

cat > "$RUN_DIR/main.log" << EOF
══════════════════════════════════════════════════════════
  Task 3.3 Cross Compare — 10 Configs × 3 Policies
  Benchmarks: ${#TRACES[@]}  Configs: ${#CONFIGS[@]}  Policies: ${#POLICIES[@]}
  Warmup: $WARMUP_INSTRUCTIONS  Sim: $SIMULATION_INSTRUCTIONS  DRAM:CXL = 1:2
  Area maps: $AMAP_DIR
  Workers: $MAX_PARALLEL  Tasks: $TOTAL
  Started: $(date '+%Y-%m-%d %H:%M:%S')
══════════════════════════════════════════════════════════

EOF

missing_maps=0
for wl in "${!TRACES[@]}"; do
  for placement in random sort_heat first_touch; do
    amap="$AMAP_DIR/${wl}_${placement}.amap"
    if [ ! -f "$amap" ]; then
      echo "MISSING area_map: $amap" >> "$RUN_DIR/main.log"
      missing_maps=$((missing_maps+1))
    fi
  done
done
if [ "$missing_maps" -ne 0 ]; then
  echo "FATAL: missing $missing_maps area_map files. Run scripts/run_task3.1_gen_areamaps.sh first." | tee -a "$RUN_DIR/main.log"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] STAGE DONE stage=task3.3-cross-compare pass=0 fail=$TOTAL result=missing_area_maps" >> "$RUN_DIR/execution.log"
  exit 1
fi

missing_bins=0
for l1d in no ipcp; do
  for l2c in no ip_stride; do
    for pol in "${POLICIES[@]}"; do
      bin="$STAGE_DIR/bin/hashed_perceptron-no-${l1d}-${l2c}-no-${pol}-1core"
      if [ ! -x "$bin" ]; then
        echo "MISSING binary: $bin" >> "$RUN_DIR/main.log"
        missing_bins=$((missing_bins+1))
      fi
    done
  done
done
if [ "$missing_bins" -ne 0 ]; then
  echo "FATAL: missing $missing_bins binaries. Build the 4 prefetcher combos × 3 policies first." | tee -a "$RUN_DIR/main.log"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] STAGE DONE stage=task3.3-cross-compare pass=0 fail=$TOTAL result=missing_binaries" >> "$RUN_DIR/execution.log"
  exit 1
fi

running=0; idx=0
for wl in "${!TRACES[@]}"; do
  tname="${TRACES[$wl]}"
  TRACE="$TRACE_DIR/${tname}.trace.xz"

  for cfg in "${CONFIGS[@]}"; do
    read placement migration l1d l2c label <<< "$cfg"

    # Binary name
    bin="$STAGE_DIR/bin/hashed_perceptron-no-${l1d}-${l2c}-no-{pol}-1core"

    # Args
    extra_args=()
    amap="$AMAP_DIR/${wl}_${placement}.amap"
    extra_args+=("-a" "$amap")
    [ "$migration" != "none" ] && extra_args+=("-m" "$migration")

    for pol in "${POLICIES[@]}"; do
      idx=$((idx+1))
      bin_path="${bin/\{pol\}/$pol}"
      name="${wl}_${label}_${pol}"

      echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] TASK DISPATCH [$idx/$TOTAL] $name" >> "$RUN_DIR/execution.log"
      echo "── $name ──" >> "$RUN_DIR/main.log"

      (
        t0=$(date +%s%3N)
        "$bin_path" -warmup_instructions "$WARMUP_INSTRUCTIONS" -simulation_instructions "$SIMULATION_INSTRUCTIONS" \
          "${extra_args[@]}" -traces "$TRACE" > "$RUN_DIR/${name}.raw" 2>&1
        rc=$?; t1=$(date +%s%3N); elapsed=$((t1-t0))

        if [ $rc -eq 0 ] && grep -q "Finished CPU" "$RUN_DIR/${name}.raw" 2>/dev/null; then
          ipc=$(grep "CPU 0 cumulative IPC" "$RUN_DIR/${name}.raw" | tail -1 | awk '{for (i=1; i<=NF; i++) if ($i == "IPC:") {print $(i+1); exit}}')
          echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] TASK DONE name=$name exit=0 elapsed_ms=$elapsed ipc=$ipc" >> "$RUN_DIR/execution.log"
          echo "  OK ipc=$ipc elapsed=${elapsed}ms" > "$RUN_DIR/${name}.sub.log"
        else
          echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] TASK DONE name=$name exit=$rc elapsed_ms=$elapsed result=failed" >> "$RUN_DIR/execution.log"
          echo "  FAILED exit=$rc" > "$RUN_DIR/${name}.sub.log"
        fi
      ) &

      running=$((running+1))
      if [ $running -ge $MAX_PARALLEL ]; then wait -n; running=$((running-1)); fi
    done
  done
done
wait

pass=$(grep -c "TASK DONE.*exit=0" "$RUN_DIR/execution.log" 2>/dev/null || true)
fail=$(grep -c "result=failed" "$RUN_DIR/execution.log" 2>/dev/null || true)
echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] STAGE DONE stage=task3.3-cross-compare pass=$pass fail=$fail" >> "$RUN_DIR/execution.log"
ln -sfn "$RUN_TS" "$STAGE_DIR/artifacts/runs/task3.3-cross-compare/latest"

echo "Done. pass=$pass fail=$fail | $RUN_DIR"
