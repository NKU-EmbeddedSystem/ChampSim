#!/bin/bash
# Task 4.0: E2E RPP Performance — 1-Core Experiment
#   Benchmarks × 2 placements (random, first_touch) × 4 policies (lru, hawkeye, mockingjay, rpp)
#   Warmup: 50M  |  Sim: 1000M  |  No prefetch, no migration
# Usage:
#   bash scripts/run_task4.0_e2e_rpp_1core.sh <trace1.xz> <trace2.xz> ...
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STAGE_DIR="$(dirname "$SCRIPT_DIR")"
ARTIFACTS_DIR="$STAGE_DIR/artifacts"
PLANS_DIR="$ARTIFACTS_DIR/plans/task4.0-e2e-rpp"
RUN_TS="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$ARTIFACTS_DIR/runs/task4.0-e2e-rpp/$RUN_TS"
BIN_DIR="$STAGE_DIR/bin"

# Configurable
MAX_PARALLEL="${TASK4_0_1C_PARALLEL:-12}"
WARMUP="${TASK4_0_WARMUP:-50000000}"       # 50M
SIM="${TASK4_0_SIM:-1000000000}"            # 1000M

# Fixed config
PLACEMENTS=(random)
POLICIES=(lru hawkeye mockingjay rpp)
BRANCH_PRED="bimodal"
PREFETCHERS="no-no-no-no"  # L1I-L1D-L2C-LLC

# ------------------------------------------------------------------
# Argument parsing
# ------------------------------------------------------------------
if [ $# -eq 0 ]; then
  echo "Usage: $0 <trace1.xz> <trace2.xz> ..."
  echo ""
  echo "  Run Task 4.0 1-core experiment for each trace."
  echo "  For each trace: 2 placements × 4 policies = 8 simulations."
  echo ""
  echo "  Required: area_maps from run_task4.0_gen_areamaps.sh"
  echo "  Required: binaries from run_task4.0_build.sh"
  echo ""
  echo "  Environment variables:"
  echo "    TASK4_0_1C_PARALLEL  Max parallel sims (default: 12)"
  echo "    TASK4_0_WARMUP       Warmup instructions (default: 50000000)"
  echo "    TASK4_0_SIM          Simulation instructions (default: 1000000000)"
  echo "    TASK4_0_AMAP_DIR     Area maps directory (default: auto-detect)"
  exit 1
fi

TRACES=("$@")

# ------------------------------------------------------------------
# Locate area_maps
# ------------------------------------------------------------------
AMAP_DIR="${TASK4_0_AMAP_DIR:-}"
if [ -z "$AMAP_DIR" ]; then
  AMAP_DIR="$ARTIFACTS_DIR/runs/task4.0-e2e-rpp/area_maps/latest"
  if [ ! -d "$AMAP_DIR" ]; then
    echo "FATAL: area_maps not found at $AMAP_DIR"
    echo "  Run scripts/run_task4.0_gen_areamaps.sh first, or set TASK4_0_AMAP_DIR"
    exit 1
  fi
fi

# ------------------------------------------------------------------
# Verify binaries exist
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
  echo "FATAL: $missing_bins binaries missing. Run scripts/run_task4.0_build.sh first."
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
# Count and verify area_maps
# ------------------------------------------------------------------
N_TRACES=${#TRACES[@]}
N_TOTAL=$((N_TRACES * ${#PLACEMENTS[@]} * ${#POLICIES[@]}))

echo "=== Task 4.0 1-Core Experiment ==="
echo "  Traces:     $N_TRACES"
echo "  Placements: ${PLACEMENTS[*]}"
echo "  Policies:   ${POLICIES[*]}"
echo "  Warmup:     $WARMUP"
echo "  Sim:        $SIM"
echo "  Total tasks: $N_TOTAL"
echo "  Workers:    $MAX_PARALLEL"
echo "  Area maps:  $AMAP_DIR"
echo "  Run dir:    $RUN_DIR"
echo ""

# ------------------------------------------------------------------
# Control plane
# ------------------------------------------------------------------
cat > "$RUN_DIR/execution.log" << EOF
[$(date -u +%Y-%m-%dT%H:%M:%S)] STAGE BEGIN  stage=task4.0-e2e-rpp-1core  tasks=$N_TOTAL  run=$RUN_TS
  warmup=$WARMUP  sim=$SIM  workers=$MAX_PARALLEL  amap_dir=$AMAP_DIR
EOF

cat > "$RUN_DIR/main.log" << EOF
══════════════════════════════════════════════════════════
  Task 4.0: End-to-End RPP Performance — 1-Core
  Traces:     $N_TRACES
  Placements: ${PLACEMENTS[*]}
  Policies:   ${POLICIES[*]}
  Warmup:     $WARMUP
  Sim:        $SIM
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
    amap="$AMAP_DIR/${bname}_${placement}.amap"
    if [ ! -f "$amap" ]; then
      echo "MISSING area_map: $amap" >> "$RUN_DIR/main.log"
      missing_maps=$((missing_maps + 1))
    fi
  done
done
if [ "$missing_maps" -gt 0 ]; then
  echo "FATAL: missing $missing_maps area_map files. Generate them first." | tee -a "$RUN_DIR/main.log"
  echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] STAGE DONE  stage=task4.0-e2e-rpp-1core  result=missing_area_maps  missing=$missing_maps" >> "$RUN_DIR/execution.log"
  exit 1
fi

# ------------------------------------------------------------------
# Dispatch
# ------------------------------------------------------------------
running=0; task_idx=0

for trace in "${TRACES[@]}"; do
  bname="$(benchmark_name "$trace")"

  for placement in "${PLACEMENTS[@]}"; do
    amap="$AMAP_DIR/${bname}_${placement}.amap"

    for pol in "${POLICIES[@]}"; do
      task_idx=$((task_idx + 1))
      bin_name="${BRANCH_PRED}-${PREFETCHERS}-${pol}-1core"
      name="${bname}_${placement}_${pol}_1core"

      echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] TASK DISPATCH  [$task_idx/$N_TOTAL] name=$name" >> "$RUN_DIR/execution.log"
      echo "── ${name} ─────────────────────────────────────────────" >> "$RUN_DIR/main.log"
      echo "  Launch: $(date '+%H:%M:%S')  trace=$bname  placement=$placement  policy=$pol" >> "$RUN_DIR/main.log"

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
          # Extract IPC from raw output
          ipc=$(grep "CPU 0 cumulative IPC" "$RUN_DIR/${name}.raw" 2>/dev/null | awk '{print $NF}' || echo "N/A")

          # Extract average miss latency
          avg_lat=$(grep "AVERAGE MISS LATENCY" "$RUN_DIR/${name}.raw" 2>/dev/null | awk '{print $NF}' || echo "N/A")

          # Check IPC validity
          if [ "$ipc" = "N/A" ] || python3 -c "exit(0 if float('$ipc' or '0') > 0 else 1)" 2>/dev/null; then
            echo "[$(date '+%H:%M:%S')] DONE  exit=0  elapsed=${elapsed}ms  ipc=$ipc  avg_miss_lat=$avg_lat" > "$RUN_DIR/${name}.sub.log"
            echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] TASK DONE  name=$name  exit=0  elapsed_ms=$elapsed  ipc=$ipc  avg_lat=$avg_lat" >> "$RUN_DIR/execution.log"
          else
            echo "[$(date '+%H:%M:%S')] DONE  exit=0  elapsed=${elapsed}ms  ipc=$ipc  (IPC <= 0, possible anomaly)" > "$RUN_DIR/${name}.sub.log"
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
wait

# ------------------------------------------------------------------
# Results summary + IPC table
# ------------------------------------------------------------------
pass=$(grep -c "TASK DONE.*exit=0" "$RUN_DIR/execution.log" 2>/dev/null || true)
fail=$(grep -c "result=failed" "$RUN_DIR/execution.log" 2>/dev/null || true)
anomaly=$(grep -c "result=ipc_anomaly" "$RUN_DIR/execution.log" 2>/dev/null || true)

cat >> "$RUN_DIR/main.log" << EOF

────────────────────────────────────────────────────────
  IPC Geomean Summary (1-Core)
────────────────────────────────────────────────────────
EOF

# Compute geomean per placement×policy
for placement in "${PLACEMENTS[@]}"; do
  echo "  --- Placement: $placement ---" >> "$RUN_DIR/main.log"
  for pol in "${POLICIES[@]}"; do
    ipcs=()
    for trace in "${TRACES[@]}"; do
      bname="$(benchmark_name "$trace")"
      name="${bname}_${placement}_${pol}_1core"
      ipc=$(grep "CPU 0 cumulative IPC" "$RUN_DIR/${name}.raw" 2>/dev/null | awk '{print $NF}' || echo "")
      if [ -n "$ipc" ] && [ "$ipc" != "N/A" ]; then
        ipcs+=("$ipc")
      fi
    done
    if [ ${#ipcs[@]} -gt 0 ]; then
      geomean=$(python3 -c "
import math
vals = [float(x) for x in '${ipcs[*]}'.split()]
gm = math.exp(sum(math.log(v) for v in vals) / len(vals))
print(f'{gm:.4f}')
")
      echo "  ${placement}/${pol}: geomean IPC = $geomean (${#ipcs[@]} benchmarks)" >> "$RUN_DIR/main.log"
    else
      echo "  ${placement}/${pol}: geomean IPC = N/A" >> "$RUN_DIR/main.log"
    fi
  done
done

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

══════════════════════════════════════════════════════════
  Finished: $(date '+%Y-%m-%d %H:%M:%S')
  Run dir:  $RUN_DIR
══════════════════════════════════════════════════════════
EOF

echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] STAGE DONE  stage=task4.0-e2e-rpp-1core  pass=$pass  fail=$fail  anomaly=$anomaly" >> "$RUN_DIR/execution.log"

# Symlinks
ln -sfn "$RUN_TS" "$ARTIFACTS_DIR/runs/task4.0-e2e-rpp/latest"
ln -sfn "../../scripts/run_task4.0_e2e_rpp_1core.sh" "$PLANS_DIR/run_1core.sh"

cat "$RUN_DIR/main.log"
echo ""
echo "Done. pass=$pass fail=$fail anomaly=$anomaly"
echo "Results: $RUN_DIR"
