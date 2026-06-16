#!/bin/bash
# Task 3.3: 10 configs × 3 policies × 12 benchmarks = 360 runs (50M+100M)
set -uo pipefail

STAGE_DIR="$(cd "$(dirname "$0")" && pwd)/.."
TRACE_DIR="$STAGE_DIR/trace"
AMAP_DIR="$STAGE_DIR/artifacts/runs/task3.1-gen-areamaps/latest"
TASK30_DATA="$STAGE_DIR/artifacts/runs/task3.0-prep-pagecount/latest/pages.jsonl"
RUN_TS="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$STAGE_DIR/artifacts/runs/task3.3-cross-compare/$RUN_TS"
MAX_PARALLEL=64

mkdir -p "$RUN_DIR"

# ── Load K values ──
declare -A K
if [ -f "$TASK30_DATA" ]; then
  while IFS= read -r line; do
    bmark=$(echo "$line" | python3 -c "import json,sys; print(json.load(sys.stdin)['benchmark'])" 2>/dev/null)
    wss=$(echo "$line" | python3 -c "import json,sys; print(json.load(sys.stdin)['num_pages'])" 2>/dev/null)
    K[$bmark]=$(python3 -c "print(int(min($wss / 3, 262144)))" 2>/dev/null)
  done < "$TASK30_DATA"
fi

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
  Warmup: 50M  Sim: 100M  DRAM:CXL = 1:2
  Workers: $MAX_PARALLEL  Tasks: $TOTAL
  Started: $(date '+%Y-%m-%d %H:%M:%S')
══════════════════════════════════════════════════════════

EOF

running=0; idx=0
for wl in "${!TRACES[@]}"; do
  tname="${TRACES[$wl]}"
  TRACE="$TRACE_DIR/${tname}.trace.xz"
  kv=${K[$tname]:-262144}

  for cfg in "${CONFIGS[@]}"; do
    read placement migration l1d l2c label <<< "$cfg"

    # Binary name
    bin="$STAGE_DIR/bin/hp-${l1d}-${l2c}-no-{pol}-1core"

    # Args
    extra_args=""
    if [ "$placement" != "random" ]; then
      amap="$AMAP_DIR/${wl}_${placement}.amap"
      [ -f "$amap" ] && extra_args="--area_map=$amap --dram_pages=$kv"
    fi
    [ "$migration" != "none" ] && extra_args="$extra_args --migration=${migration}"

    for pol in "${POLICIES[@]}"; do
      idx=$((idx+1))
      bin_path="${bin/\{pol\}/$pol}"
      name="${wl}_${label}_${pol}"

      echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] TASK DISPATCH [$idx/$TOTAL] $name" >> "$RUN_DIR/execution.log"
      echo "── $name ──" >> "$RUN_DIR/main.log"

      (
        t0=$(date +%s%3N)
        "$bin_path" -warmup_instructions 50000000 -simulation_instructions 100000000 \
          $extra_args -traces "$TRACE" > "$RUN_DIR/${name}.raw" 2>&1
        rc=$?; t1=$(date +%s%3N); elapsed=$((t1-t0))

        if [ $rc -eq 0 ] && grep -q "Finished CPU" "$RUN_DIR/${name}.raw" 2>/dev/null; then
          ipc=$(grep "cumulative IPC" "$RUN_DIR/${name}.raw" | tail -1 | awk '{print $NF}')
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

pass=$(grep -c "TASK DONE.*exit=0" "$RUN_DIR/execution.log" 2>/dev/null || echo 0)
fail=$(grep -c "result=failed" "$RUN_DIR/execution.log" 2>/dev/null || echo 0)
echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] STAGE DONE stage=task3.3-cross-compare pass=$pass fail=$fail" >> "$RUN_DIR/execution.log"
ln -sfn "$RUN_TS" "$STAGE_DIR/artifacts/runs/task3.3-cross-compare/latest"

echo "Done. pass=$pass fail=$fail | $RUN_DIR"
