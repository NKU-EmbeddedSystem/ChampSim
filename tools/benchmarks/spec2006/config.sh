#!/usr/bin/env bash
# SPEC CPU2006 — Benchmark Configuration
# Sourced automatically by tools/profiling/config.sh

export SPEC_ROOT="${HOME}/cpu2006"
export SPEC_CONFIG="linux64-amd64-gcc-fortify0.cfg"
# - This config adds -D_FORTIFY_SOURCE=0 -fcommon -fgnu89-inline to work with modern gcc/glibc
# - Generated from config/Example-linux64-amd64-gcc43.cfg

# Benchmarks to build (used by setup.sh)
# Edit this list to add/remove benchmarks.
export SPEC_BENCHMARKS=(
  400.perlbench
  401.bzip2
  403.gcc
  410.bwaves
  429.mcf
  433.milc
  445.gobmk
  450.soplex
  456.hmmer
  458.sjeng
  462.libquantum
  464.h264ref
  470.lbm
  471.omnetpp
  473.astar
  483.xalancbmk
)
