#!/bin/bash
# Task 3.1: Generate area_map files for 12 benchmarks × 2 strategies
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STAGE_DIR="$(dirname "$SCRIPT_DIR")"
TRACE_DIR="$STAGE_DIR/trace"
TOOL="$STAGE_DIR/build/bin/tools/gen_area_map"
ARTIFACTS_DIR="$STAGE_DIR/artifacts"
PLANS_DIR="$ARTIFACTS_DIR/plans/task3.1-gen-areamaps"
RUN_TS="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$ARTIFACTS_DIR/runs/task3.1-gen-areamaps/$RUN_TS"
MAX_PARALLEL=4
MAX_INSTR=150000000  # warmup(50M) + sim(100M)
TASK30_DATA="$ARTIFACTS_DIR/runs/task3.0-prep-pagecount/latest/pages.jsonl"

mkdir -p "$RUN_DIR"

# Build tool if needed
if [ ! -x "$TOOL" ]; then
  echo "Building gen_area_map..."
  g++ -std=c++17 -O2 -o "$TOOL" "$STAGE_DIR/src/tools/gen_area_map.cc" || {
    echo "FATAL: build failed"
    exit 1
  }
fi

# ------------------------------------------------------------------
# Load K values from Task 3.0 (or use default 262144)
# ------------------------------------------------------------------
declare -A DRAM_PAGES
if [ -f "$TASK30_DATA" ]; then
  while IFS= read -r line; do
    bmark=$(echo "$line" | python3 -c "import json,sys; print(json.load(sys.stdin)['benchmark'])" 2>/dev/null)
    wss=$(echo "$line" | python3 -c "import json,sys; print(json.load(sys.stdin)['num_pages'])" 2>/dev/null)
    k=$(python3 -c "print(int(min(int($wss / 3), 262144)))" 2>/dev/null)
    [ -n "$bmark" ] && DRAM_PAGES[$bmark]=$k
  done < "$TASK30_DATA"
  echo "Loaded K values for ${#DRAM_PAGES[@]} benchmarks from Task 3.0"
else
  echo "WARNING: Task 3.0 data not found, using default K=262144 for all"
fi

# 12 unique-workload benchmarks (same as task3.0)
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

STRATEGIES=(sort_heat first_touch)
N_TOTAL=$((${#BENCHMARKS[@]} * ${#STRATEGIES[@]}))

# ══════════════════════════════════════════════════════════
#  Control plane
# ══════════════════════════════════════════════════════════
cat > "$RUN_DIR/execution.log" << EOF
[$(date -u +%Y-%m-%dT%H:%M:%S)] STAGE BEGIN  stage=task3.1-gen-areamaps  tasks=$N_TOTAL  run=$RUN_TS  input=$TRACE_DIR
EOF

# ══════════════════════════════════════════════════════════
#  Global log — main.log (Header)
# ══════════════════════════════════════════════════════════
cat > "$RUN_DIR/main.log" << EOF
══════════════════════════════════════════════════════════
  Task 3.1: Generate area_map files
  Input:   $TRACE_DIR (ChampSim xz traces)
  Strategies: ${STRATEGIES[*]}  |  Benchmarks: ${#BENCHMARKS[@]} (12 unique workloads)
  Total tasks: $N_TOTAL  |  Workers: $MAX_PARALLEL
  Started: $(date '+%Y-%m-%d %H:%M:%S')
  Run dir: $RUN_DIR
  Plan:    $PLANS_DIR/PLAN.md
══════════════════════════════════════════════════════════

EOF

# ══════════════════════════════════════════════════════════
#  Dispatch
# ══════════════════════════════════════════════════════════
echo "── Task dispatch ──" >> "$RUN_DIR/main.log"

running=0; task_idx=0
for wl in "${!BENCHMARKS[@]}"; do
  trace_name="${BENCHMARKS[$wl]}"
  K=${DRAM_PAGES[$trace_name]:-262144}
  xz_path="$TRACE_DIR/${trace_name}.trace.xz"

  for strat in "${STRATEGIES[@]}"; do
    amap_path="$RUN_DIR/${wl}_${strat}.amap"
    name="${wl}_${strat}"

    echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] TASK DISPATCH  name=$name  log=${name}.sub.log  raw=${name}.raw" >> "$RUN_DIR/execution.log"

    echo "── ${name} (K=$K) ─────────────────────────────────────────────" >> "$RUN_DIR/main.log"
    echo "  Launch:   $(date '+%H:%M:%S')" >> "$RUN_DIR/main.log"

    (
      t0=$(date +%s%3N)
      "$TOOL" --trace="$xz_path" --output="$amap_path" --placement="$strat" --dram_pages="$K" --max_instructions=$MAX_INSTR > "$RUN_DIR/${name}.raw" 2>&1
      rc=$?; t1=$(date +%s%3N); elapsed=$((t1-t0))

      if [ $rc -eq 0 ] && [ -s "$amap_path" ]; then
        nbytes=$(stat --printf='%s' "$amap_path" 2>/dev/null || echo 0)
        # Verify magic bytes
        magic_ok=0
        [ "$(xxd -l 4 -p "$amap_path" 2>/dev/null)" = "41524541" ] && magic_ok=1
        echo "[$(date '+%H:%M:%S')] ${name} OK  bytes=$nbytes  magic_ok=$magic_ok  elapsed=${elapsed}ms" > "$RUN_DIR/${name}.sub.log"
        echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] TASK DONE  name=$name  exit=0  elapsed_ms=$elapsed  map_bytes=$nbytes  magic_ok=$magic_ok" >> "$RUN_DIR/execution.log"
      else
        echo "[$(date '+%H:%M:%S')] ${name} FAILED  exit=$rc" > "$RUN_DIR/${name}.sub.log"
        echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] TASK DONE  name=$name  exit=$rc  elapsed_ms=$elapsed  result=failed" >> "$RUN_DIR/execution.log"
      fi
    ) &

    running=$((running+1)); task_idx=$((task_idx+1))
    echo "  [$task_idx/$N_TOTAL] ${name} (K=$K)" >> "$RUN_DIR/main.log"
    if [ $running -ge $MAX_PARALLEL ]; then wait -n; running=$((running-1)); fi
  done
done
wait

echo "" >> "$RUN_DIR/main.log"
echo "  All $N_TOTAL launched. Waiting..." >> "$RUN_DIR/main.log"

# ══════════════════════════════════════════════════════════
#  Results → main.log
# ══════════════════════════════════════════════════════════
pass=$(grep -c "TASK DONE.*exit=0" "$RUN_DIR/execution.log" 2>/dev/null || echo 0)
fail=$(grep -c "TASK DONE.*result=failed" "$RUN_DIR/execution.log" 2>/dev/null || echo 0)

cat >> "$RUN_DIR/main.log" << EOF

────────────────────────────────────────────────────────
  Results
────────────────────────────────────────────────────────
$(for wl in "${!BENCHMARKS[@]}"; do
  for strat in "${STRATEGIES[@]}"; do
    name="${wl}_${strat}"
    amap="$RUN_DIR/${name}.amap"
    if [ -f "$amap" ]; then
      sz=$(stat --printf='%s' "$amap" 2>/dev/null)
      echo "  ${name}  bytes=$sz"
    else
      echo "  ${name}  MISSING"
    fi
  done
done)
EOF

# ══════════════════════════════════════════════════════════
#  Checks → main.log
# ══════════════════════════════════════════════════════════
magic_fail=0
for wl in "${!BENCHMARKS[@]}"; do
  for strat in "${STRATEGIES[@]}"; do
    amap="$RUN_DIR/${wl}_${strat}.amap"
    if [ -f "$amap" ]; then
      m=$(xxd -l 4 -p "$amap" 2>/dev/null)
      [ "$m" != "41524541" ] && magic_fail=$((magic_fail+1))
    fi
  done
done

cat >> "$RUN_DIR/main.log" << EOF

────────────────────────────────────────────────────────
  Checks
────────────────────────────────────────────────────────
  [$( [ "$pass" -eq "$N_TOTAL" ] && echo "PASS" || echo "FAIL")] All ${pass}/$N_TOTAL tasks succeeded
  [$( [ "$magic_fail" -eq 0 ] && echo "PASS" || echo "FAIL")] Magic bytes correct ($magic_fail failures)
  [$( [ "$fail" -eq 0 ] && echo "PASS" || echo "FAIL")] Zero failures ($fail failures)

══════════════════════════════════════════════════════════
  Finished: $(date '+%Y-%m-%d %H:%M:%S')
  Run dir:  $RUN_DIR
══════════════════════════════════════════════════════════
  Plan dir updated:
    $PLANS_DIR/SUMMARY.log → latest run
    $PLANS_DIR/CONCLUSIONS.md
EOF

# ══════════════════════════════════════════════════════════
#  execution.log — STAGE DONE
# ══════════════════════════════════════════════════════════
echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] STAGE DONE  stage=task3.1-gen-areamaps  pass=$pass  fail=$fail" >> "$RUN_DIR/execution.log"

# ══════════════════════════════════════════════════════════
#  Auto-generate CONCLUSIONS.md
# ══════════════════════════════════════════════════════════
python3 -c "
import datetime, subprocess

now = datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
rows = ''
for wl in ['astar','cactusADM','h264ref','libquantum','mcf','milc','omnetpp','perlbench','soplex','sphinx3','xalancbmk','zeusmp']:
    for s in ['sort_heat','first_touch']:
        name = f'{wl}_{s}'
        amap = f'$RUN_DIR/{name}.amap'
        try:
            sz = __import__('os').path.getsize(amap)
            rows += f'| {name} | {sz:,d} | PASS |\n'
        except:
            rows += f'| {name} | 0 | FAIL |\n'

conclusions = f'''# Task 3.1 Conclusions — Area Map Generation

**Date:** {now} | **Input:** ChampSim traces (12 unique workloads) | **Run:** $RUN_TS | **Status:** Complete

## Results

| Benchmark_Strategy | File Size (bytes) | Status |
|--------|---------|---------|
{rows}
- {len(rows.splitlines())} area_map files generated

## Checks

- [{'PASS' if $pass==$N_TOTAL else 'FAIL'}] All {$pass}/$N_TOTAL tasks succeeded
- [{'PASS' if $fail==0 else 'FAIL'}] Zero failures

## Next Stage

- Stage 3.2: Full sweep — 7 placement×migration configs × 4 replacement policies
- Use area_maps from this stage as --area_map inputs
'''
with open('$PLANS_DIR/CONCLUSIONS.md', 'w') as f:
    f.write(conclusions)
print('CONCLUSIONS.md written')
" 2>&1 >> "$RUN_DIR/main.log"

# ══════════════════════════════════════════════════════════
#  Symlinks
# ══════════════════════════════════════════════════════════
ln -sfn "$RUN_TS" "$ARTIFACTS_DIR/runs/task3.1-gen-areamaps/latest"
ln -sfn "../../scripts/run_task3.1_gen_areamaps.sh" "$PLANS_DIR/run.sh"
ln -sfn "../../runs/task3.1-gen-areamaps/latest/main.log" "$PLANS_DIR/SUMMARY.log"

cat "$RUN_DIR/main.log"

echo "Done. pass=$pass fail=$fail"
echo "Results: $RUN_DIR"
