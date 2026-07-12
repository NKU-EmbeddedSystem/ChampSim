#!/bin/bash
# Task 4.1: DRAM Ratio Sensitivity — RPP Performance Under Varying DRAM Capacity
#   Benchmarks × 7 ratios × 2 placements × 4 policies
#   Warmup: 50M  |  Sim: 1000M  |  1-core only  |  No prefetch, no migration
# Usage:
#   bash scripts/run_task4.1_dram_ratio.sh <trace1.xz> <trace2.xz> ...
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STAGE_DIR="$(dirname "$SCRIPT_DIR")"
ARTIFACTS_DIR="$STAGE_DIR/artifacts"
PLANS_DIR="$ARTIFACTS_DIR/plans/task4.1-dram-ratio"
RUN_TS="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$ARTIFACTS_DIR/runs/task4.1-dram-ratio/$RUN_TS"
BIN_DIR="$STAGE_DIR/bin"

# Configurable
MAX_PARALLEL="${TASK4_1_SIM_PARALLEL:-${TASK4_1_PARALLEL:-12}}"
WARMUP="${TASK4_1_WARMUP:-50000000}"       # 50M
SIM="${TASK4_1_SIM:-1000000000}"            # 1000M

# 7 DRAM ratios
RATIO_LABELS=("000" "010" "030" "050" "070" "090" "100")
RATIO_VALS=(0.00 0.10 0.30 0.50 0.70 0.90 1.00)
RATIO_PCTS=("0%" "10%" "30%" "50%" "70%" "90%" "100%")

PLACEMENTS=(random)
POLICIES=(lru hawkeye mockingjay rpp)
BRANCH_PRED="bimodal"
PREFETCHERS="no-no-no-no"

# ------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------
if [ $# -eq 0 ]; then
  echo "Usage: $0 <trace1.xz> <trace2.xz> ..."
  echo ""
  echo "  Run Task 4.1 DRAM ratio sensitivity experiment."
  echo "  For each trace: 7 ratios × 2 placements × 4 policies = 56 simulations."
  echo ""
  echo "  Required: area_maps from run_task4.1_gen_areamaps.sh"
  echo "  Required: binaries from run_task4.1_build.sh"
  echo ""
  echo "  Environment variables:"
  echo "    TASK4_1_PARALLEL  Max parallel sims (default: 12)"
  echo "    TASK4_1_WARMUP    Warmup instructions (default: 50000000)"
  echo "    TASK4_1_SIM       Simulation instructions (default: 1000000000)"
  echo "    TASK4_1_AMAP_DIR  Area maps directory (default: auto-detect)"
  exit 1
fi

TRACES=("$@")

# ------------------------------------------------------------------
# Locate area_maps
# ------------------------------------------------------------------
AMAP_DIR="${TASK4_1_AMAP_DIR:-}"
if [ -z "$AMAP_DIR" ]; then
  AMAP_DIR="$ARTIFACTS_DIR/runs/task4.1-dram-ratio/area_maps/latest"
  if [ ! -d "$AMAP_DIR" ]; then
    echo "FATAL: area_maps not found at $AMAP_DIR"
    echo "  Run scripts/run_task4.1_gen_areamaps.sh first, or set TASK4_1_AMAP_DIR"
    exit 1
  fi
fi

# ------------------------------------------------------------------
# Verify binaries
# ------------------------------------------------------------------
missing_bins=0
for pol in "${POLICIES[@]}"; do
  bin_name="${BRANCH_PRED}-${PREFETCHERS}-${pol}-1core"
  if [ ! -f "$BIN_DIR/$bin_name" ]; then
    echo "MISSING binary: bin/$bin_name"
    missing_bins=$((missing_bins + 1))
  fi
done
if [ "$missing_bins" -gt 0 ]; then
  echo "FATAL: $missing_bins binaries missing. Run scripts/run_task4.1_build.sh first."
  exit 1
fi

mkdir -p "$RUN_DIR"

# ------------------------------------------------------------------
# Derive benchmark name
# ------------------------------------------------------------------
benchmark_name() {
  local fname
  fname="$(basename "$1")"
  fname="${fname%.champsimtrace.xz}"
  fname="${fname%.champsim.trace.xz}"
  fname="${fname%.trace.xz}"
  fname="${fname%.xz}"
  echo "$fname"
}

# ------------------------------------------------------------------
# Count tasks
# ------------------------------------------------------------------
N_TRACES=${#TRACES[@]}
N_RATIOS=${#RATIO_LABELS[@]}
N_TASKS_PER_TRACE=$((N_RATIOS * ${#PLACEMENTS[@]} * ${#POLICIES[@]}))
N_TOTAL=$((N_TRACES * N_TASKS_PER_TRACE))

echo "=== Task 4.1 DRAM Ratio Sensitivity Experiment ==="
echo "  Traces:     $N_TRACES"
echo "  Ratios:     ${RATIO_PCTS[*]}"
echo "  Placements: ${PLACEMENTS[*]}"
echo "  Policies:   ${POLICIES[*]}"
echo "  Warmup:     $WARMUP"
echo "  Sim:        $SIM"
echo "  Tasks/trace: $N_TASKS_PER_TRACE"
echo "  Total tasks: $N_TOTAL"
echo "  Workers:    $MAX_PARALLEL"
echo "  Area maps:  $AMAP_DIR"
echo "  Run dir:    $RUN_DIR"
echo ""

# ------------------------------------------------------------------
# Control plane
# ------------------------------------------------------------------
cat > "$RUN_DIR/execution.log" << EOF
[$(date -u +%Y-%m-%dT%H:%M:%S)] STAGE BEGIN  stage=task4.1-dram-ratio  tasks=$N_TOTAL  run=$RUN_TS
  warmup=$WARMUP  sim=$SIM  workers=$MAX_PARALLEL  amap_dir=$AMAP_DIR
  ratios=${RATIO_PCTS[*]}  placements=${PLACEMENTS[*]}  policies=${POLICIES[*]}
EOF

cat > "$RUN_DIR/main.log" << EOF
══════════════════════════════════════════════════════════
  Task 4.1: DRAM Ratio Sensitivity
  Traces:     $N_TRACES
  Ratios:     ${RATIO_PCTS[*]} (${N_RATIOS} levels)
  Placements: ${PLACEMENTS[*]}
  Policies:   ${POLICIES[*]}
  Warmup:     $WARMUP
  Sim:        $SIM
  Tasks:      $N_TOTAL ($N_TASKS_PER_TRACE per trace)
  Workers:    $MAX_PARALLEL
  Area maps:  $AMAP_DIR
  Started:    $(date '+%Y-%m-%d %H:%M:%S')
  Run dir:    $RUN_DIR
  Plan:       $PLANS_DIR/PLAN.md
══════════════════════════════════════════════════════════

EOF

# ------------------------------------------------------------------
# Check for missing area_maps
# ------------------------------------------------------------------
missing_maps=0
for trace in "${TRACES[@]}"; do
  bname="$(benchmark_name "$trace")"
  for placement in "${PLACEMENTS[@]}"; do
    for ratio_label in "${RATIO_LABELS[@]}"; do
      amap="$AMAP_DIR/${bname}_${placement}_ratio${ratio_label}.amap"
      if [ ! -f "$amap" ]; then
        missing_maps=$((missing_maps + 1))
      fi
    done
  done
done
if [ "$missing_maps" -gt 0 ]; then
  echo "FATAL: missing $missing_maps area_map files. Run scripts/run_task4.1_gen_areamaps.sh first." | tee -a "$RUN_DIR/main.log"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] STAGE DONE  stage=task4.1-dram-ratio  result=missing_area_maps  missing=$missing_maps" >> "$RUN_DIR/execution.log"
  exit 1
fi

# ------------------------------------------------------------------
# Dispatch
# ------------------------------------------------------------------
running=0; task_idx=0

for trace in "${TRACES[@]}"; do
  bname="$(benchmark_name "$trace")"

  for ((ri = 0; ri < N_RATIOS; ri++)); do
    ratio_label="${RATIO_LABELS[$ri]}"
    ratio_pct="${RATIO_PCTS[$ri]}"

    for placement in "${PLACEMENTS[@]}"; do
      amap="$AMAP_DIR/${bname}_${placement}_ratio${ratio_label}.amap"

      for pol in "${POLICIES[@]}"; do
        task_idx=$((task_idx + 1))
        bin_name="${BRANCH_PRED}-${PREFETCHERS}-${pol}-1core"
        name="${bname}_${placement}_ratio${ratio_label}_${pol}"

        echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] TASK DISPATCH  [$task_idx/$N_TOTAL] name=$name" >> "$RUN_DIR/execution.log"
        echo "── ${name} (DRAM=${ratio_pct}) ─────────────────────────────" >> "$RUN_DIR/main.log"
        echo "  Launch: $(date '+%H:%M:%S')" >> "$RUN_DIR/main.log"

        (
          t0=$(date +%s%3N)
          cd "$STAGE_DIR"

          ./bin/${bin_name} \
            -warmup_instructions "$WARMUP" \
            -simulation_instructions "$SIM" \
            -a "$amap" \
            -traces "$trace" \
            > "$RUN_DIR/${name}.raw" 2>&1
          rc=$?; t1=$(date +%s%3N); elapsed=$((t1 - t0))

          if [ $rc -eq 0 ]; then
            # Extract IPC
            ipc=$(grep "CPU 0 cumulative IPC" "$RUN_DIR/${name}.raw" 2>/dev/null | awk '{print $NF}' || echo "N/A")

            # Extract average miss latency
            avg_lat=$(grep "AVERAGE MISS LATENCY" "$RUN_DIR/${name}.raw" 2>/dev/null | awk '{print $NF}' || echo "N/A")

            # Extract DRAM/CXL access counts
            dram_acc=$(grep "DRAM accesses:" "$RUN_DIR/${name}.raw" 2>/dev/null | awk '{print $3}' || echo "N/A")
            cxl_acc=$(grep "CXL accesses:" "$RUN_DIR/${name}.raw" 2>/dev/null | awk '{print $3}' || echo "N/A")

            # Sanity checks for 0% and 100% ratios
            sanity_note=""
            if [ "$ratio_label" = "000" ]; then
              # 0% DRAM → sim_dram_accesses should be 0
              if [ "$dram_acc" != "N/A" ] && [ "$dram_acc" != "0" ]; then
                sanity_note=" sanity=WARN_DRAM_ACCESS_NONZERO_AT_0PCT"
              fi
            elif [ "$ratio_label" = "100" ]; then
              # 100% DRAM → sim_cxl_accesses should be 0
              if [ "$cxl_acc" != "N/A" ] && [ "$cxl_acc" != "0" ]; then
                sanity_note=" sanity=WARN_CXL_ACCESS_NONZERO_AT_100PCT"
              fi
            fi

            # Check IPC validity
            if [ "$ipc" = "N/A" ] || python3 -c "exit(0 if float('$ipc' or '0') > 0 else 1)" 2>/dev/null; then
              echo "[$(date '+%H:%M:%S')] DONE  exit=0  elapsed=${elapsed}ms  ipc=$ipc  avg_miss_lat=$avg_lat  dram_acc=$dram_acc  cxl_acc=$cxl_acc" > "$RUN_DIR/${name}.sub.log"
              echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] TASK DONE  name=$name  exit=0  elapsed_ms=$elapsed  ipc=$ipc  avg_lat=$avg_lat  dram_acc=$dram_acc  cxl_acc=$cxl_acc${sanity_note}" >> "$RUN_DIR/execution.log"
            else
              echo "[$(date '+%H:%M:%S')] DONE  exit=0  elapsed=${elapsed}ms  ipc=$ipc  (IPC <= 0, anomaly)" > "$RUN_DIR/${name}.sub.log"
              echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] TASK DONE  name=$name  exit=0  elapsed_ms=$elapsed  ipc=$ipc  result=ipc_anomaly" >> "$RUN_DIR/execution.log"
            fi
          else
            echo "[$(date '+%H:%M:%S')] FAILED  exit=$rc  elapsed=${elapsed}ms" > "$RUN_DIR/${name}.sub.log"
            echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] TASK DONE  name=$name  exit=$rc  elapsed_ms=$elapsed  result=failed" >> "$RUN_DIR/execution.log"
          fi
        ) &

        running=$((running + 1))
        if [ $running -ge $MAX_PARALLEL ]; then wait -n; running=$((running - 1)); fi
      done
    done
  done
done
wait

# ------------------------------------------------------------------
# Results summary
# ------------------------------------------------------------------
pass=$(grep -c "TASK DONE.*exit=0" "$RUN_DIR/execution.log" 2>/dev/null || true)
fail=$(grep -c "result=failed" "$RUN_DIR/execution.log" 2>/dev/null || true)
anomaly=$(grep -c "result=ipc_anomaly" "$RUN_DIR/execution.log" 2>/dev/null || true)
sanity_warn=$(grep -c "sanity=WARN" "$RUN_DIR/execution.log" 2>/dev/null || true)

# ------------------------------------------------------------------
# Build IPC geomean tables (per ratio × placement × policy)
# ------------------------------------------------------------------
cat >> "$RUN_DIR/main.log" << EOF

────────────────────────────────────────────────────────
  IPC Geomean Tables
────────────────────────────────────────────────────────
EOF

# Table 1: IPC per ratio × policy (geomean over all traces and placements)
python3 -c "
import re, math, collections
exec_log = open('$RUN_DIR/execution.log').read()
# Parse: name=bench_placement_ratioXXX_policy ... ipc=VAL
rows = collections.defaultdict(list)  # key=(ratio,policy) -> [ipcs]
for line in exec_log.split('\n'):
    m = re.search(r'name=(\S+).*ipc=(\S+)', line)
    if m:
        name, ipc_str = m.group(1), m.group(2)
        parts = name.split('_')
        # name format: bench_placement_ratioXXX_policy
        if len(parts) >= 4:
            pol = parts[-1]
            ratio = parts[-2]  # ratioXXX
            # placement = parts[-3]
            try:
                ipc = float(ipc_str)
                if ipc > 0:
                    rows[(ratio, pol)].append(ipc)
            except: pass

ratio_order = ['ratio000','ratio010','ratio030','ratio050','ratio070','ratio090','ratio100']
ratio_display = {'ratio000':'0%','ratio010':'10%','ratio030':'30%','ratio050':'50%','ratio070':'70%','ratio090':'90%','ratio100':'100%'}
pol_order = ['lru','hawkeye','mockingjay','rpp']

print('  ┌──────────┬──────────┬──────────┬──────────┬──────────┐')
print('  │ DRAM     │ LRU      │ Hawkeye  │ MockingJ │ RPP      │')
print('  ├──────────┼──────────┼──────────┼──────────┼──────────┤')
for ratio in ratio_order:
    rd = ratio_display.get(ratio, ratio)
    parts = [f'  │ {rd:<8}']
    for pol in pol_order:
        vals = rows.get((ratio, pol), [])
        if vals:
            gm = math.exp(sum(math.log(v) for v in vals) / len(vals))
            parts.append(f' │ {gm:.4f}')
        else:
            parts.append(f' │ {"N/A":>8}')
    parts.append(' │')
    print(''.join(parts))
print('  └──────────┴──────────┴──────────┴──────────┴──────────┘')
" >> "$RUN_DIR/main.log"

# Table 2: Speedup vs LRU per ratio × policy
python3 -c "
import re, math, collections
exec_log = open('$RUN_DIR/execution.log').read()
rows = collections.defaultdict(list)
for line in exec_log.split('\n'):
    m = re.search(r'name=(\S+).*ipc=(\S+)', line)
    if m:
        name, ipc_str = m.group(1), m.group(2)
        parts = name.split('_')
        if len(parts) >= 4:
            pol = parts[-1]
            ratio = parts[-2]
            bench = '_'.join(parts[:-3])
            placement = parts[-3]
            try:
                ipc = float(ipc_str)
                if ipc > 0:
                    rows[(ratio, placement, bench, pol)] = ipc
            except: pass

ratio_order = ['ratio000','ratio010','ratio030','ratio050','ratio070','ratio090','ratio100']
ratio_display = {'ratio000':'0%','ratio010':'10%','ratio030':'30%','ratio050':'50%','ratio070':'70%','ratio090':'90%','ratio100':'100%'}
pols_compare = ['hawkeye','mockingjay','rpp']

# Compute per-(ratio,pol) speedups vs LRU for same (bench,placement)
speedups = collections.defaultdict(list)
for (ratio, placement, bench, pol), ipc in rows.items():
    lru_ipc = rows.get((ratio, placement, bench, 'lru'))
    if lru_ipc and lru_ipc > 0:
        speedups[(ratio, pol)].append(ipc / lru_ipc)

print('')
print('  Speedup vs LRU (geomean):')
print('  ┌──────────┬──────────┬──────────┬──────────┐')
print('  │ DRAM     │ Hawk/LRU │ MockJ/LRU│ RPP/LRU  │')
print('  ├──────────┼──────────┼──────────┼──────────┤')
for ratio in ratio_order:
    rd = ratio_display.get(ratio, ratio)
    parts = [f'  │ {rd:<8}']
    for pol in pols_compare:
        vals = speedups.get((ratio, pol), [])
        if vals:
            gm = math.exp(sum(math.log(v) for v in vals) / len(vals))
            parts.append(f' │ {gm:.4f}')
        else:
            parts.append(f' │ {\"N/A\":>8}')
    parts.append(' │')
    print(''.join(parts))
print('  └──────────┴──────────┴──────────┴──────────┘')
" >> "$RUN_DIR/main.log"

# ------------------------------------------------------------------
# Per-ratio IPC monotonicity check
# ------------------------------------------------------------------
python3 -c "
import re, math, collections
exec_log = open('$RUN_DIR/execution.log').read()
rows = collections.defaultdict(list)
for line in exec_log.split('\n'):
    m = re.search(r'name=(\S+).*ipc=(\S+)', line)
    if m:
        name, ipc_str = m.group(1), m.group(2)
        parts = name.split('_')
        if len(parts) >= 4:
            pol = parts[-1]
            ratio = parts[-2]
            try:
                ipc = float(ipc_str)
                if ipc > 0:
                    rows[(pol, ratio)].append(ipc)
            except: pass

ratio_order = ['ratio000','ratio010','ratio030','ratio050','ratio070','ratio090','ratio100']
pol_order = ['lru','hawkeye','mockingjay','rpp']

# Check monotonicity: for each pol, geomean IPC should increase with ratio
violations = 0
for pol in pol_order:
    prev_gm = -1
    for ratio in ratio_order:
        vals = rows.get((pol, ratio), [])
        if vals:
            gm = math.exp(sum(math.log(v) for v in vals) / len(vals))
            if gm < prev_gm:
                violations += 1
            prev_gm = gm

print(f'IPC monotonicity violations: {violations} (0 = all ratios show increasing IPC with more DRAM)')
" >> "$RUN_DIR/main.log"

# ------------------------------------------------------------------
# Checks
# ------------------------------------------------------------------
cat >> "$RUN_DIR/main.log" << EOF

────────────────────────────────────────────────────────
  Results
────────────────────────────────────────────────────────
  Pass: $pass  |  Fail: $fail  |  Anomalies: $anomaly  |  Total: $N_TOTAL
────────────────────────────────────────────────────────
  Checks
────────────────────────────────────────────────────────
  [$( [ "$pass" -eq "$N_TOTAL" ] && echo "PASS" || echo "FAIL")] All ${pass}/$N_TOTAL tasks completed
  [$( [ "$fail" -eq 0 ] && echo "PASS" || echo "FAIL")] Zero failures ($fail failures)
  [$( [ "$anomaly" -eq 0 ] && echo "PASS" || echo "WARN")] No IPC anomalies ($anomaly anomalies)
  [$( [ "$sanity_warn" -eq 0 ] && echo "PASS" || echo "WARN")] No 0%/100% sanity violations ($sanity_warn warnings)

══════════════════════════════════════════════════════════
  Finished: $(date '+%Y-%m-%d %H:%M:%S')
  Run dir:  $RUN_DIR
══════════════════════════════════════════════════════════
EOF

echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] STAGE DONE  stage=task4.1-dram-ratio  pass=$pass  fail=$fail  anomaly=$anomaly  sanity_warn=$sanity_warn" >> "$RUN_DIR/execution.log"

# Symlinks
ln -sfn "$RUN_TS" "$ARTIFACTS_DIR/runs/task4.1-dram-ratio/latest"
ln -sfn "../../scripts/run_task4.1_dram_ratio.sh" "$PLANS_DIR/run.sh"

cat "$RUN_DIR/main.log"
echo ""
echo "Done. pass=$pass fail=$fail anomaly=$anomaly sanity_warn=$sanity_warn"
echo "Results: $RUN_DIR"
