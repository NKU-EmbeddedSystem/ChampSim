#!/bin/bash
# Task 4.0 4-Core: Full Pipeline
#   gen_areamaps (all traces) → build → 4-core experiment (auto-grouped)
# Usage:
#   bash scripts/run_task4.0_4core.sh <trace1.xz> ... <traceN.xz>   (N must be multiple of 4)
#   bash scripts/run_task4.0_4core.sh --groups <groups.txt>
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ------------------------------------------------------------------
# Parse arguments
# ------------------------------------------------------------------
if [ $# -eq 0 ]; then
  echo "Usage: $0 <trace1.xz> <trace2.xz> ..."
  echo "       $0 --groups <groups.txt>"
  echo ""
  echo "  Full pipeline for Task 4.0 4-core:"
  echo "    1. Generate area_maps for all unique traces"
  echo "    2. Build 1-core + 4-core binaries"
  echo "    3. Run 4-core experiment (traces auto-grouped into sets of 4)"
  echo ""
  echo "  Traces are auto-grouped in input order: first 4 → G0, next 4 → G1, ..."
  echo "  The number of traces must be a multiple of 4."
  echo ""
  echo "  Core assignment: ChampSim's 4 cores are symmetric, so trace→core"
  echo "  mapping within a group does NOT affect IPC. Only the GROUPING matters."
  echo ""
  echo "  Environment variables (all optional, set before running):"
  echo "    TASK4_0_WARMUP         Warmup instructions        (default: 50000000)"
  echo "    TASK4_0_SIM            Simulation instructions     (default: 1000000000)"
  echo "    TASK4_0_MAX_INSTR      Area_map page window        (default: WARMUP+SIM)"
  echo "    TASK4_0_PARALLEL       Parallel area_map gen jobs  (default: 8)"
  echo "    TASK4_0_4C_PARALLEL    Parallel simulation jobs    (default: 4)"
  echo ""
  echo "  Example:"
  echo "    TASK4_0_SIM=500000000 bash $0 trace1.xz trace2.xz ... trace8.xz"
  exit 1
fi

# ═══════════════════════════════════════════════════════════════
# Resolve & export all tunable parameters
# ═══════════════════════════════════════════════════════════════
export TASK4_0_WARMUP="${TASK4_0_WARMUP:-50000000}"
export TASK4_0_SIM="${TASK4_0_SIM:-1000000000}"

if [ -z "${TASK4_0_MAX_INSTR+x}" ]; then
  export TASK4_0_MAX_INSTR=$((TASK4_0_WARMUP + TASK4_0_SIM))
fi

export TASK4_0_PARALLEL="${TASK4_0_PARALLEL:-16}"
export TASK4_0_4C_PARALLEL="${TASK4_0_4C_PARALLEL:-4}"

# ------------------------------------------------------------------
# Collect traces & validate grouping
# ------------------------------------------------------------------
ALL_TRACES=()
USE_GROUPS_FILE=""

if [ "$1" = "--groups" ]; then
  if [ $# -lt 2 ] || [ ! -f "$2" ]; then
    echo "FATAL: --groups requires a valid group file (one line = 4 traces)"
    exit 1
  fi
  USE_GROUPS_FILE="$2"
  while IFS= read -r line; do
    line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    read -ra group_traces <<< "$line"
    if [ ${#group_traces[@]} -ne 4 ]; then
      echo "FATAL: each group must have exactly 4 traces, got ${#group_traces[@]}: $line"
      exit 1
    fi
    for t in "${group_traces[@]}"; do
      ALL_TRACES+=("$t")
    done
  done < "$USE_GROUPS_FILE"
  N_GROUPS=$(grep -c '[^[:space:]]' "$USE_GROUPS_FILE" 2>/dev/null || echo 0)
else
  ALL_TRACES=("$@")
  N_TRACES=${#ALL_TRACES[@]}
  if [ $((N_TRACES % 4)) -ne 0 ]; then
    echo "FATAL: number of traces ($N_TRACES) is not a multiple of 4."
    echo "  4-core mode requires exactly 4 traces per group."
    echo "  Use --groups <file> for explicit grouping."
    exit 1
  fi
  N_GROUPS=$((N_TRACES / 4))
fi

# Deduplicate traces for gen_areamaps
readarray -t UNIQUE_TRACES < <(printf '%s\n' "${ALL_TRACES[@]}" | sort -u)

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  Task 4.0 4-Core — Full Pipeline                           ║"
echo "╠══════════════════════════════════════════════════════════════╣"
printf "║  %-30s %10s ║\n" "Unique traces:" "${#UNIQUE_TRACES[@]}"
printf "║  %-30s %10s ║\n" "Groups (×4 traces):" "$N_GROUPS"
printf "║  %-30s %10s ║\n" "Warmup (TASK4_0_WARMUP):" "$TASK4_0_WARMUP"
printf "║  %-30s %10s ║\n" "Sim (TASK4_0_SIM):" "$TASK4_0_SIM"
printf "║  %-30s %10s ║\n" "Area_map window (derived):" "$TASK4_0_MAX_INSTR"
printf "║  %-30s %10s ║\n" "Parallel area_map jobs:" "$TASK4_0_PARALLEL"
printf "║  %-30s %10s ║\n" "Parallel sim jobs:" "$TASK4_0_4C_PARALLEL"
echo "║  Pipeline: gen_areamaps → build → experiment               ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ------------------------------------------------------------------
# Stage 1: Generate area_maps
# ------------------------------------------------------------------
echo "=== Stage 1/3: Generate area_maps (${#UNIQUE_TRACES[@]} unique traces, window=$TASK4_0_MAX_INSTR) ==="
bash "$SCRIPT_DIR/run_task4.0_gen_areamaps.sh" "${UNIQUE_TRACES[@]}"
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
echo "=== Stage 2/3: Build 1-core + 4-core binaries ==="
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
# Stage 3: Run 4-core experiment
# ------------------------------------------------------------------
echo "=== Stage 3/3: Run 4-core experiment ($N_GROUPS groups, warmup=$TASK4_0_WARMUP sim=$TASK4_0_SIM) ==="
if [ -n "$USE_GROUPS_FILE" ]; then
  bash "$SCRIPT_DIR/run_task4.0_e2e_rpp_4core.sh" --groups "$USE_GROUPS_FILE"
else
  bash "$SCRIPT_DIR/run_task4.0_e2e_rpp_4core.sh" "${ALL_TRACES[@]}"
fi
rc=$?
echo ""
if [ $rc -eq 0 ]; then
  echo "╔══════════════════════════════════════════════════════════════╗"
  echo "║  Task 4.0 4-Core — Pipeline Complete                       ║"
  echo "╚══════════════════════════════════════════════════════════════╝"
else
  echo "WARNING: Stage 3 (experiment) had issues, exit=$rc"
  echo "  Log: artifacts/runs/task4.0-e2e-rpp/latest/main.log"
fi
exit $rc
