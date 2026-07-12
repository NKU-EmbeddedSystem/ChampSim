#!/bin/bash
# Task 4.1 DRAM Ratio Sensitivity: Full Pipeline
#   gen_areamaps → build → dram_ratio experiment
# Usage:
#   bash scripts/run_task4.1_full.sh <trace1.xz> <trace2.xz> ...
#   TASK4_1_WARMUP=50000000 TASK4_1_SIM=1000000000 bash scripts/run_task4.1_full.sh ...
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ $# -eq 0 ]; then
  echo "Usage: $0 <trace1.xz> <trace2.xz> ..."
  echo ""
  echo "  Full pipeline for Task 4.1 DRAM Ratio Sensitivity:"
  echo "    1. Generate area_maps (7 ratios × 2 placements per trace)"
  echo "    2. Build 1-core binaries (lru, hawkeye, mockingjay, rpp)"
  echo "    3. Run DRAM ratio experiment (7 ratios × 2 placements × 4 policies)"
  echo ""
  echo "  DRAM ratios: 0% 10% 30% 50% 70% 90% 100%"
  echo "  Placements:  random first_touch"
  echo "  Policies:    lru hawkeye mockingjay rpp"
  echo ""
  echo "  Environment variables (all optional, set before running):"
  echo "    TASK4_1_WARMUP         Warmup instructions        (default: 50000000)"
  echo "    TASK4_1_SIM            Simulation instructions      (default: 1000000000)"
  echo "    TASK4_1_MAX_INSTR      Area_map page window        (default: WARMUP+SIM)"
  echo "    TASK4_1_PARALLEL       Parallel area_map gen jobs   (default: 8)"
  echo "    TASK4_1_SIM_PARALLEL   Parallel simulation jobs     (default: 12)"
  echo ""
  echo "  Example with custom sim length:"
  echo "    TASK4_1_SIM=500000000 bash $0 traces/*.xz"
  exit 1
fi

# ═══════════════════════════════════════════════════════════════
# Resolve & export all tunable parameters
# ═══════════════════════════════════════════════════════════════
export TASK4_1_WARMUP="${TASK4_1_WARMUP:-50000000}"
export TASK4_1_SIM="${TASK4_1_SIM:-1000000000}"

# Auto-derive MAX_INSTR = warmup + sim  (if user didn't set it explicitly)
if [ -z "${TASK4_1_MAX_INSTR+x}" ]; then
  export TASK4_1_MAX_INSTR=$((TASK4_1_WARMUP + TASK4_1_SIM))
fi

export TASK4_1_PARALLEL="${TASK4_1_PARALLEL:-16}"
# Simulation parallelism: separate from gen parallelism, falls back to TASK4_1_PARALLEL
export TASK4_1_SIM_PARALLEL="${TASK4_1_SIM_PARALLEL:-${TASK4_1_PARALLEL:-16}}"

TRACES=("$@")
N_TRACES=${#TRACES[@]}
N_TASKS_PER_TRACE=56   # 7 ratios × 2 placements × 4 policies
N_TOTAL=$((N_TRACES * N_TASKS_PER_TRACE))

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Task 4.1 DRAM Ratio Sensitivity — Full Pipeline           ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  %-30s %10s ║\n" "Traces:" "$N_TRACES"
printf "║  %-30s %10s ║\n" "Ratios:" "7 (0%-100%)"
printf "║  %-30s %10s ║\n" "Placements:" "2 (random first_touch)"
printf "║  %-30s %10s ║\n" "Policies:" "4 (lru hk mj rpp)"
printf "║  %-30s %10s ║\n" "Tasks/trace:" "$N_TASKS_PER_TRACE"
printf "║  %-30s %10s ║\n" "Total tasks:" "$N_TOTAL"
printf "║  %-30s %10s ║\n" "Warmup (TASK4_1_WARMUP):" "$TASK4_1_WARMUP"
printf "║  %-30s %10s ║\n" "Sim (TASK4_1_SIM):" "$TASK4_1_SIM"
printf "║  %-30s %10s ║\n" "Area_map window (derived):" "$TASK4_1_MAX_INSTR"
printf "║  %-30s %10s ║\n" "Parallel area_map jobs:" "$TASK4_1_PARALLEL"
printf "║  %-30s %10s ║\n" "Parallel sim jobs:" "$TASK4_1_SIM_PARALLEL"
echo "║  Pipeline: gen_areamaps → build → experiment               ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ------------------------------------------------------------------
# Stage 1: Generate area_maps
# ------------------------------------------------------------------
echo "=== Stage 1/3: Generate area_maps (7 ratios × 2 placements, window=$TASK4_1_MAX_INSTR) ==="
bash "$SCRIPT_DIR/run_task4.1_gen_areamaps.sh" "${TRACES[@]}"
rc=$?
if [ $rc -ne 0 ]; then
  echo ""
  echo "FATAL: Stage 1 (gen_areamaps) failed with exit=$rc"
  echo "  Log: artifacts/runs/task4.1-dram-ratio/area_maps/latest/main.log"
  exit $rc
fi
echo ""

# ------------------------------------------------------------------
# Stage 2: Build binaries
# ------------------------------------------------------------------
echo "=== Stage 2/3: Build 1-core binaries ==="
bash "$SCRIPT_DIR/run_task4.1_build.sh"
rc=$?
if [ $rc -ne 0 ]; then
  echo ""
  echo "FATAL: Stage 2 (build) failed with exit=$rc"
  echo "  Log: artifacts/runs/task4.1-dram-ratio/latest/main.log"
  exit $rc
fi
echo ""

# ------------------------------------------------------------------
# Stage 3: Run DRAM ratio experiment
# ------------------------------------------------------------------
echo "=== Stage 3/3: Run DRAM ratio experiment ($N_TOTAL tasks, warmup=$TASK4_1_WARMUP sim=$TASK4_1_SIM) ==="
echo "  This may take a while — each trace runs 56 simulations."
echo ""
bash "$SCRIPT_DIR/run_task4.1_dram_ratio.sh" "${TRACES[@]}"
rc=$?
echo ""
if [ $rc -eq 0 ]; then
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║  Task 4.1 DRAM Ratio — Pipeline Complete                   ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
else
  echo "WARNING: Stage 3 (experiment) had issues, exit=$rc"
  echo "  Log: artifacts/runs/task4.1-dram-ratio/latest/main.log"
fi
exit $rc
