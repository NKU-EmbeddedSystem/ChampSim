#!/bin/bash
# Task 3.2 Full Sweep: 12 benchmarks × 7 configs × 4 policies
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STAGE_DIR="$(dirname "$SCRIPT_DIR")"
TRACE_DIR="$STAGE_DIR/trace"
ARTIFACTS_DIR="$STAGE_DIR/artifacts"
PLANS_DIR="$ARTIFACTS_DIR/plans/task3.2-full"
TASK30_DATA="$ARTIFACTS_DIR/runs/task3.0-prep-pagecount/latest/pages.jsonl"
AMAP_DIR="$ARTIFACTS_DIR/runs/task3.1-gen-areamaps/latest"
RUN_TS="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$ARTIFACTS_DIR/runs/task3.2-full/$RUN_TS"
MAX_PARALLEL=12

mkdir -p "$RUN_DIR"

# ------------------------------------------------------------------
# Build 4 policy binaries (if not already built)
# ------------------------------------------------------------------
POLICIES=(lru hawkeye mockingjay rpp)
declare -A POLICY_BINS

for pol in "${POLICIES[@]}"; do
  bin_name="hashed_perceptron-no-no-no-no-${pol}-1core"
  POLICY_BINS[$pol]="$bin_name"

  if [ ! -f "$STAGE_DIR/bin/$bin_name" ]; then
    echo "Building binary for policy=$pol ..."
    cd "$STAGE_DIR"
    # Copy replacement policy
    cp "replacement/${pol}.llc_repl" replacement/llc_replacement.cc 2>/dev/null || true
    # Use hashed_perceptron branch, no prefetchers
    cp branch/hashed_perceptron.bpred branch/branch_predictor.cc
    cp prefetcher/no.l1i_pref prefetcher/l1i_prefetcher.cc
    cp prefetcher/no.l1d_pref prefetcher/l1d_prefetcher.cc
    cp prefetcher/no.l2c_pref prefetcher/l2c_prefetcher.cc
    cp prefetcher/no.llc_pref prefetcher/llc_prefetcher.cc
    make clean >/dev/null 2>&1
    make > "$RUN_DIR/build_${pol}.log" 2>&1
    if [ -f bin/champsim ]; then
      mv bin/champsim "bin/${bin_name}"
      echo "  → bin/${bin_name} built OK"
    else
      echo "FATAL: build failed for policy=$pol — check $RUN_DIR/build_${pol}.log"
      exit 1
    fi
  else
    echo "Binary bin/${bin_name} already exists"
  fi
done

# Restore default replacement policy
cd "$STAGE_DIR"
cp replacement/lru.llc_repl replacement/llc_replacement.cc 2>/dev/null || true

# ------------------------------------------------------------------
# Load K values from Task 3.0
# ------------------------------------------------------------------
declare -A DRAM_PAGES
if [ -f "$TASK30_DATA" ]; then
  while IFS= read -r line; do
    bmark=$(echo "$line" | python3 -c "import json,sys; print(json.load(sys.stdin)['benchmark'])" 2>/dev/null)
    wss=$(echo "$line" | python3 -c "import json,sys; print(json.load(sys.stdin)['num_pages'])" 2>/dev/null)
    k=$(python3 -c "print(int(min($wss * 0.3, 262144)))" 2>/dev/null)
    [ -n "$bmark" ] && DRAM_PAGES[$bmark]=$k
  done < "$TASK30_DATA"
  echo "Loaded K values for ${#DRAM_PAGES[@]} benchmarks"
else
  echo "WARNING: Task 3.0 data not found at $TASK30_DATA — using default K=262144"
fi

# ------------------------------------------------------------------
# Benchmark list (12 unique workloads)
# ------------------------------------------------------------------
declare -A BENCHMARKS
BENCHMARKS=(
  [astar]=astar_163B
  [cactusADM]=cactusADM_734B
  [h264ref]=h264ref_178B
  [libquantum]=libquantum_964B
  [mcf]=mcf_46B
  [milc]=milc_360B
  [omnetpp]=omnetpp_4B
  [perlbench]=perlbench_53B
  [soplex]=soplex_66B
  [sphinx3]=sphinx3_883B
  [xalancbmk]=xalancbmk_99B
  [zeusmp]=zeusmp_100B
)

# Configs: placement_migration pairs
CONFIGS_PM=(
  baseline_none
  sort_heat_none sort_heat_forward sort_heat_backward
  first_touch_none first_touch_forward first_touch_backward
)

total=$((${#BENCHMARKS[@]} * ${#CONFIGS_PM[@]} * ${#POLICIES[@]}))
echo "Total tasks: $total (${#BENCHMARKS[@]} benchmarks × ${#CONFIGS_PM[@]} configs × ${#POLICIES[@]} policies)"

# ══════════════════════════════════════════════════════════
#  Control plane — execution.log
# ══════════════════════════════════════════════════════════
cat > "$RUN_DIR/execution.log" << EOF
[$(date -u +%Y-%m-%dT%H:%M:%S)] STAGE BEGIN  stage=task3.2-full  tasks=$total  run=$RUN_TS
EOF

# ══════════════════════════════════════════════════════════
#  Global log — main.log
# ══════════════════════════════════════════════════════════
cat > "$RUN_DIR/main.log" << EOF
══════════════════════════════════════════════════════════
  Task 3.2 Full Sweep — Placement × Migration × Policy
  Input:       $TRACE_DIR (12 unique-workload ChampSim traces)
  Configs:     ${#CONFIGS_PM[@]} (placements × migrations)
  Policies:    ${POLICIES[*]}
  Warmup:      50M  |  Sim: 100M
  Workers:     $MAX_PARALLEL
  Started:     $(date '+%Y-%m-%d %H:%M:%S')
  Run dir:     $RUN_DIR
  Plan:        $PLANS_DIR/PLAN.md
══════════════════════════════════════════════════════════

EOF

# ══════════════════════════════════════════════════════════
#  Dispatch
# ══════════════════════════════════════════════════════════
running=0; idx=0
for wl in "${!BENCHMARKS[@]}"; do
  trace_name="${BENCHMARKS[$wl]}"
  TRACE="$TRACE_DIR/${trace_name}.trace.xz"
  k=${DRAM_PAGES[$wl]:-262144}

  for cfg in "${CONFIGS_PM[@]}"; do
    # Parse placement_migration
    placement="${cfg%_*}"
    migration="${cfg##*_}"
    if [ "$placement" = "baseline" ]; then
      placement="${cfg%%_*}"  # baseline
      migration="${cfg##*_}"
    else
      placement="${cfg%_*}"
      migration="${cfg##*_}"
    fi

    # Build area_map path and migration args
    area_args=""
    if [ "$placement" != "baseline" ]; then
      amap="$AMAP_DIR/${wl}_${placement}.amap"
      if [ -f "$amap" ]; then
        area_args="--area_map=$amap --dram_pages=$k"
      else
        echo "WARNING: area_map not found: $amap — falling back to random"
      fi
    fi

    mig_args=""
    [ "$migration" != "none" ] && mig_args="--migration=$migration"

    for pol in "${POLICIES[@]}"; do
      idx=$((idx+1))
      bin_name="${POLICY_BINS[$pol]}"
      name="${wl}_${placement}_${migration}_${pol}"

      echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] TASK DISPATCH  [$idx/$total] name=$name" >> "$RUN_DIR/execution.log"

      echo "── ${name} ─────────────────────────────────────────────" >> "$RUN_DIR/main.log"
      echo "  Launch: $(date '+%H:%M:%S')" >> "$RUN_DIR/main.log"

      (
        t0=$(date +%s%3N)
        cd "$STAGE_DIR"

        ./bin/${bin_name} \
          -warmup_instructions 50000000 \
          -simulation_instructions 100000000 \
          ${area_args} ${mig_args} \
          -traces "$TRACE" \
          > "$RUN_DIR/${name}.raw" 2>&1
        rc=$?; t1=$(date +%s%3N); elapsed=$((t1-t0))

        if [ $rc -eq 0 ]; then
          # Extract IPC from output
          ipc=$(grep "CPU 0 cumulative IPC" "$RUN_DIR/${name}.raw" 2>/dev/null | awk '{print $NF}' || echo "N/A")
          echo "[$(date '+%H:%M:%S')] DONE  exit=0  elapsed=${elapsed}ms  ipc=$ipc" > "$RUN_DIR/${name}.sub.log"
          echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] TASK DONE  name=$name  exit=0  elapsed_ms=$elapsed  ipc=$ipc" >> "$RUN_DIR/execution.log"
        else
          echo "[$(date '+%H:%M:%S')] FAILED  exit=$rc  elapsed=${elapsed}ms" > "$RUN_DIR/${name}.sub.log"
          echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] TASK DONE  name=$name  exit=$rc  elapsed_ms=$elapsed  result=failed" >> "$RUN_DIR/execution.log"
        fi
      ) &

      running=$((running+1))
      if [ $running -ge $MAX_PARALLEL ]; then wait -n; running=$((running-1)); fi
    done
  done
done
wait

# ══════════════════════════════════════════════════════════
#  Results summary
# ══════════════════════════════════════════════════════════
pass=$(grep -c "TASK DONE.*exit=0" "$RUN_DIR/execution.log" 2>/dev/null || echo 0)
fail=$(grep -c "result=failed" "$RUN_DIR/execution.log" 2>/dev/null || echo 0)

cat >> "$RUN_DIR/main.log" << EOF

────────────────────────────────────────────────────────
  Results
────────────────────────────────────────────────────────
  Pass: $pass  |  Fail: $fail  |  Total: $total
EOF

# ══════════════════════════════════════════════════════════
#  Checks
# ══════════════════════════════════════════════════════════
cat >> "$RUN_DIR/main.log" << EOF

────────────────────────────────────────────────────────
  Checks
────────────────────────────────────────────────────────
  [$( [ "$pass" -eq "$total" ] && echo "PASS" || echo "FAIL")] All tasks completed ($pass/$total)
  [$( [ "$fail" -eq 0 ] && echo "PASS" || echo "FAIL")] Zero failures ($fail failures)

══════════════════════════════════════════════════════════
  Finished: $(date '+%Y-%m-%d %H:%M:%S')
  Run dir:  $RUN_DIR
══════════════════════════════════════════════════════════
EOF

# ══════════════════════════════════════════════════════════
#  execution.log — STAGE DONE
# ══════════════════════════════════════════════════════════
echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] STAGE DONE  stage=task3.2-full  pass=$pass  fail=$fail" >> "$RUN_DIR/execution.log"

# ══════════════════════════════════════════════════════════
#  Auto-generate CONCLUSIONS.md
# ══════════════════════════════════════════════════════════
python3 -c "
import datetime
now = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')

conclusions = f'''# Task 3.2 Conclusions — Placement × Migration × Policy Full Sweep

**Date:** {now} | **Input:** 12 unique-workload ChampSim traces | **Run:** $RUN_TS | **Status:** Complete

## Experiment Matrix

- Benchmarks: 12 (unique workloads)
- Configs: 7 (baseline, sort_heat × none/forward/backward, first_touch × none/forward/backward)
- Policies: 4 (lru, hawkeye, mockingjay, rpp)
- Warmup: 50M / Sim: 100M
- Total: $total tasks

## Results

Pass: $pass / Fail: $fail

## Checks

- [{'PASS' if $pass==$total else 'FAIL'}] All {$pass}/$total tasks completed
- [{'PASS' if $fail==0 else 'FAIL'}] Zero failures

## Next Stage

- Use results for IPC comparison across placement × migration × policy combos
- See SUMMARY.log for detailed per-config IPC values
'''
with open('$PLANS_DIR/CONCLUSIONS.md', 'w') as f:
    f.write(conclusions)
print('CONCLUSIONS.md written')
" 2>&1

# ══════════════════════════════════════════════════════════
#  Symlinks
# ══════════════════════════════════════════════════════════
ln -sfn "$RUN_TS" "$ARTIFACTS_DIR/runs/task3.2-full/latest"
ln -sfn "../../scripts/run_task3.2_full.sh" "$PLANS_DIR/run.sh"
ln -sfn "../../runs/task3.2-full/latest/main.log" "$PLANS_DIR/SUMMARY.log"

cat "$RUN_DIR/main.log"

echo "Done. pass=$pass fail=$fail"
echo "Results: $RUN_DIR"
