#!/bin/bash
# Task 4.0 1-Core: Full Pipeline
#   gen_areamaps → build → 1-core experiment
# Usage:
#   bash scripts/run_task4.0_1core.sh <trace1.xz> <trace2.xz> ...
#   TASK4_0_WARMUP=50000000 TASK4_0_SIM=1000000000 bash scripts/run_task4.0_1core.sh ...
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ $# -eq 0 ]; then
  echo "Usage: $0 <trace1.xz> <trace2.xz> ..."
  echo ""
  echo "  Full pipeline for Task 4.0 1-core:"
  echo "    1. Generate area_maps (random + first_touch, DRAM:CXL=1:2)"
  echo "    2. Build 1-core binaries (lru, hawkeye, mockingjay, rpp)"
  echo "    3. Run 1-core experiment (2 placements × 4 policies per trace)"
  echo ""
  echo "  Environment variables (all optional, set before running):"
  echo "    TASK4_0_WARMUP         Warmup instructions        (default: 50000000)"
  echo "    TASK4_0_SIM            Simulation instructions     (default: 1000000000)"
  echo "    TASK4_0_MAX_INSTR      Area_map page window        (default: WARMUP+SIM)"
  echo "    TASK4_0_PARALLEL       Parallel area_map gen jobs  (default: 8)"
  echo "    TASK4_0_1C_PARALLEL    Parallel simulation jobs    (default: 12)"
  echo ""
  echo "  Example with custom sim length:"
  echo "    TASK4_0_SIM=500000000 bash $0 traces/*.xz"
  exit 1
fi

# ═══════════════════════════════════════════════════════════════
# Resolve & export all tunable parameters
# ═══════════════════════════════════════════════════════════════
export TASK4_0_WARMUP="${TASK4_0_WARMUP:-50000000}"
export TASK4_0_SIM="${TASK4_0_SIM:-1000000000}"

# Auto-derive MAX_INSTR = warmup + sim  (if user didn't set it explicitly)
if [ -z "${TASK4_0_MAX_INSTR+x}" ]; then
  export TASK4_0_MAX_INSTR=$((TASK4_0_WARMUP + TASK4_0_SIM))
fi

export TASK4_0_PARALLEL="${TASK4_0_PARALLEL:-48}"
export TASK4_0_1C_PARALLEL="${TASK4_0_1C_PARALLEL:-48}"

TRACES=("$@")
N_TRACES=${#TRACES[@]}

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Task 4.0 1-Core — Full Pipeline                           ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  %-30s %10s ║\n" "Traces:" "$N_TRACES"
printf "║  %-30s %10s ║\n" "Warmup (TASK4_0_WARMUP):" "$TASK4_0_WARMUP"
printf "║  %-30s %10s ║\n" "Sim (TASK4_0_SIM):" "$TASK4_0_SIM"
printf "║  %-30s %10s ║\n" "Area_map window (derived):" "$TASK4_0_MAX_INSTR"
printf "║  %-30s %10s ║\n" "Parallel area_map jobs:" "$TASK4_0_PARALLEL"
printf "║  %-30s %10s ║\n" "Parallel sim jobs:" "$TASK4_0_1C_PARALLEL"
echo "║  Pipeline: gen_areamaps → build → experiment               ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ------------------------------------------------------------------
# Stage 1: Generate area_maps
# ------------------------------------------------------------------
echo "=== Stage 1/3: Generate area_maps (window=$TASK4_0_MAX_INSTR instructions) ==="
bash "$SCRIPT_DIR/run_task4.0_gen_areamaps.sh" "${TRACES[@]}"
rc=$?
if [ $rc -ne 0 ]; then
  echo ""
  echo "FATAL: Stage 1 (gen_areamaps) failed with exit=$rc"
  echo "  Log: artifacts/runs/task4.0-e2e-rpp/area_maps/latest/main.log"
  exit $rc
fi
echo ""

# ------------------------------------------------------------------
# Stage 2: Build binaries
# ------------------------------------------------------------------
echo "=== Stage 2/3: Build 1-core binaries ==="
bash "$SCRIPT_DIR/run_task4.0_build.sh"
rc=$?
if [ $rc -ne 0 ]; then
  echo ""
  echo "FATAL: Stage 2 (build) failed with exit=$rc"
  echo "  Log: artifacts/runs/task4.0-e2e-rpp/latest/main.log"
  exit $rc
fi
echo ""

# ------------------------------------------------------------------
# Stage 3: Run 1-core experiment
# ------------------------------------------------------------------
echo "=== Stage 3/3: Run 1-core experiment (warmup=$TASK4_0_WARMUP sim=$TASK4_0_SIM) ==="
bash "$SCRIPT_DIR/run_task4.0_e2e_rpp_1core.sh" "${TRACES[@]}"
rc=$?
echo ""
if [ $rc -eq 0 ]; then
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║  Task 4.0 1-Core — Pipeline Complete                       ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
else
  echo "WARNING: Stage 3 (experiment) had issues, exit=$rc"
  echo "  Log: artifacts/runs/task4.0-e2e-rpp/latest/main.log"
fi
exit $rc
