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
export INTERVAL_SIZE=100000000   # 100M

# --- Weight threshold: only generate traces for SimPoints with weight above this ---
export WEIGHT_THRESHOLD=0.01

# --- Assembly context window (instructions before/after each Load PC) ---
export CTX_BEFORE=8
export CTX_AFTER=4

# --- Prefetch policies to evaluate ---
# Format: "policy_name:degree1,degree2,..."
export PREFETCH_POLICIES=(
  "no:1"
  "next_line:1"
  "ip_stride:1,2,3,4"
  "spp_dev:1,2,3,4"
  "va_ampm_lite:1,2,3,4"
)

# --- Load benchmark-specific configs ---
# Each benchmark suite under tools/benchmarks/<suite>/config.sh is auto-sourced.
# Add new suites there without modifying this file.
for _cfg in "${PIPELINE_ROOT}/../benchmarks/"*/config.sh; do
    [ -f "$_cfg" ] && source "$_cfg"
done
