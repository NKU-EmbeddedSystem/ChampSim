#!/usr/bin/env bash
# Profiling Pipeline — General Configuration
# Source this file before running any pipeline stage.

# --- Paths ---
export CHAMPSIM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export PIPELINE_ROOT="${CHAMPSIM_ROOT}/tools/profiling"
export DATA_ROOT="${CHAMPSIM_ROOT}/tools/profiling/data"

# --- External tooling ---

# DPC-3 SimPoints tarball
export SIMPOINTS_TARBALL="${HOME}/Downloads/weights-and-simpoints-speccpu.tar.gz"
export SIMPOINTS_DIR="${DATA_ROOT}/simpoints"

# Intel PIN
export PIN_VERSION="3.22"
export PIN_BUILD="98547-g7a303a835"
export PIN_URL="https://software.intel.com/sites/landingpage/pintool/downloads/pin-${PIN_VERSION}-${PIN_BUILD}-gcc-linux.tar.gz"
export PIN_ROOT="${HOME}/pin-${PIN_VERSION}-${PIN_BUILD}-gcc-linux"
export PIN_TRACER="${CHAMPSIM_ROOT}/tracer/pin/obj-intel64/champsim_tracer.so"

# ChampSim
export CHAMPSIM_BIN="${CHAMPSIM_ROOT}/bin/champsim_hint_profile"
export CHAMPSIM_CONFIG="${CHAMPSIM_ROOT}/champsim_config_hint_profile.json"

# --- SimPoint interval size (instructions per interval) ---
# DPC-3 uses 1B instruction windows for SimPoint analysis.
# Skip = interval_id × INTERVAL_SIZE.
export INTERVAL_SIZE=1000000000  # 1B

# --- Trace recording length (instructions per trace) ---
# DPC-3 standard: 50M warmup + 200M simulation = 250M total.
# This is independent of INTERVAL_SIZE (recording starts at the skip point).
export TRACE_LENGTH=250000000    # 250M

# --- Weight threshold: only generate traces for SimPoints with weight above this ---
export WEIGHT_THRESHOLD=0.01

# --- Assembly context window (instructions before/after each Load PC) ---
export CTX_BEFORE=8
export CTX_AFTER=4

# --- Prefetch policies: 12 paper prefetchers from PORTING_STATUS.md ---
# Format: "policy_name:degree1,degree2,..."
# All 12 ported from Pythia + ChampSim built-ins.
# 12 paper prefetchers, low/med/high degree per prefetcher (3 tiers for ML training)
export PREFETCH_POLICIES=(
  "no:1"
  "next_line:1"
  "stride:1,4,8"
  "stream:1,4,8"
  "ampm:1,4,16"
  "sms:1,8,31"
  "bingo:1"
  "sandbox:1,4,8"
  "power7:1,3,6"
  "dspatch:8,32,64"
  "mlop:1,8,16"
  "ppf:1"
)

# --- Load benchmark-specific configs ---
# Each benchmark suite under tools/benchmarks/<suite>/config.sh is auto-sourced.
# Add new suites there without modifying this file.
for _cfg in "${PIPELINE_ROOT}/../benchmarks/"*/config.sh; do
    [ -f "$_cfg" ] && source "$_cfg"
done
