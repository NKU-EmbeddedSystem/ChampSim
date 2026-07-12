#!/bin/bash
# Task 4.1: Build ChampSim 1-core binaries for 4 replacement policies
#   Policies: lru, hawkeye, mockingjay, rpp
#   Branch:   bimodal
#   Prefetchers: no (all levels)
#   Cores:     1 only
# Usage:
#   bash scripts/run_task4.1_build.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STAGE_DIR="$(dirname "$SCRIPT_DIR")"
ARTIFACTS_DIR="$STAGE_DIR/artifacts"
PLANS_DIR="$ARTIFACTS_DIR/plans/task4.1-dram-ratio"
RUN_TS="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$ARTIFACTS_DIR/runs/task4.1-dram-ratio/$RUN_TS"
BIN_DIR="$STAGE_DIR/bin"

POLICIES=(lru hawkeye mockingjay rpp)
NCORES=1

mkdir -p "$RUN_DIR" "$BIN_DIR"

# ------------------------------------------------------------------
# Control plane
# ------------------------------------------------------------------
N_TOTAL=${#POLICIES[@]}
cat > "$RUN_DIR/execution.log" << EOF
[$(date -u +%Y-%m-%dT%H:%M:%S)] STAGE BEGIN  stage=task4.1-build  tasks=$N_TOTAL  run=$RUN_TS
EOF

cat > "$RUN_DIR/main.log" << EOF
══════════════════════════════════════════════════════════
  Task 4.1: Build ChampSim Binaries (1-core only)
  Policies:    ${POLICIES[*]}
  Cores:       $NCORES
  Branch pred: bimodal
  Prefetchers: no (all levels)
  Started:     $(date '+%Y-%m-%d %H:%M:%S')
  Run dir:     $RUN_DIR
  Plan:        $PLANS_DIR/PLAN.md
══════════════════════════════════════════════════════════

EOF

# ------------------------------------------------------------------
# Save original champsim.h
# ------------------------------------------------------------------
CHAMPSIM_H="$STAGE_DIR/inc/champsim.h"
CHAMPSIM_H_BAK="$STAGE_DIR/inc/champsim.h.bak.4.1"
cp "$CHAMPSIM_H" "$CHAMPSIM_H_BAK"

cleanup() {
  if [ -f "$CHAMPSIM_H_BAK" ]; then
    cp "$CHAMPSIM_H_BAK" "$CHAMPSIM_H"
    rm -f "$CHAMPSIM_H_BAK"
    echo "Restored $CHAMPSIM_H"
  fi
  cp "$STAGE_DIR/replacement/lru.llc_repl" "$STAGE_DIR/replacement/llc_replacement.cc" 2>/dev/null || true
}
trap cleanup EXIT

# ------------------------------------------------------------------
# Build
# ------------------------------------------------------------------
sed -i "s/^#define NUM_CPUS .*/#define NUM_CPUS ${NCORES}/" "$CHAMPSIM_H"
echo "Set NUM_CPUS=$NCORES in champsim.h" | tee -a "$RUN_DIR/main.log"

task_idx=0
for pol in "${POLICIES[@]}"; do
  task_idx=$((task_idx + 1))
  bin_name="bimodal-no-no-no-no-${pol}-${NCORES}core"
  log_file="$RUN_DIR/build_${pol}.log"
  name="build_${pol}"

  echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] TASK DISPATCH  [$task_idx/$N_TOTAL] name=$name" >> "$RUN_DIR/execution.log"
  echo "── ${name} ─────────────────────────────────────────────" >> "$RUN_DIR/main.log"

  t0=$(date +%s%3N)

  if [ -f "$BIN_DIR/$bin_name" ]; then
    echo "  → bin/${bin_name} already exists, skipping" | tee -a "$RUN_DIR/main.log"
    t1=$(date +%s%3N)
    echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] TASK DONE  name=$name  exit=0  elapsed_ms=$((t1-t0))  result=cached" >> "$RUN_DIR/execution.log"
    continue
  fi

  # Copy replacement policy
  cp "$STAGE_DIR/replacement/${pol}.llc_repl" "$STAGE_DIR/replacement/llc_replacement.cc" 2>/dev/null || {
    echo "FATAL: policy file replacement/${pol}.llc_repl not found" | tee -a "$RUN_DIR/main.log"
    echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] TASK DONE  name=$name  exit=1  result=missing_policy_file" >> "$RUN_DIR/execution.log"
    continue
  }

  # Copy branch predictor and prefetchers
  cp "$STAGE_DIR/branch/bimodal.bpred" "$STAGE_DIR/branch/branch_predictor.cc"
  cp "$STAGE_DIR/prefetcher/no.l1i_pref" "$STAGE_DIR/prefetcher/l1i_prefetcher.cc"
  cp "$STAGE_DIR/prefetcher/no.l1d_pref" "$STAGE_DIR/prefetcher/l1d_prefetcher.cc"
  cp "$STAGE_DIR/prefetcher/no.l2c_pref" "$STAGE_DIR/prefetcher/l2c_prefetcher.cc"
  cp "$STAGE_DIR/prefetcher/no.llc_pref" "$STAGE_DIR/prefetcher/llc_prefetcher.cc"

  cd "$STAGE_DIR"
  make clean >> "$log_file" 2>&1
  if ! make >> "$log_file" 2>&1; then
    t1=$(date +%s%3N)
    echo "  FATAL: build failed — see $log_file" | tee -a "$RUN_DIR/main.log"
    echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] TASK DONE  name=$name  exit=1  elapsed_ms=$((t1-t0))  result=build_failed" >> "$RUN_DIR/execution.log"
    continue
  fi

  if [ -f "$BIN_DIR/champsim" ]; then
    mv "$BIN_DIR/champsim" "$BIN_DIR/${bin_name}"
    t1=$(date +%s%3N)
    echo "  → bin/${bin_name} built OK" | tee -a "$RUN_DIR/main.log"
    echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] TASK DONE  name=$name  exit=0  elapsed_ms=$((t1-t0))  result=ok" >> "$RUN_DIR/execution.log"
  else
    t1=$(date +%s%3N)
    echo "  FATAL: bin/champsim not found after make" | tee -a "$RUN_DIR/main.log"
    echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] TASK DONE  name=$name  exit=1  elapsed_ms=$((t1-t0))  result=missing_binary" >> "$RUN_DIR/execution.log"
  fi
done

# ------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------
ok_count=$(grep -c "result=ok\|result=cached" "$RUN_DIR/execution.log" 2>/dev/null || true)
fail_count=$(grep -c "result=build_failed\|result=missing" "$RUN_DIR/execution.log" 2>/dev/null || true)

cat >> "$RUN_DIR/main.log" << EOF

────────────────────────────────────────────────────────
  Results
────────────────────────────────────────────────────────
  Built: $ok_count  |  Failed: $fail_count  |  Total: $N_TOTAL
────────────────────────────────────────────────────────
  Binaries:
$(for pol in "${POLICIES[@]}"; do
  bin_name="bimodal-no-no-no-no-${pol}-${NCORES}core"
  if [ -f "$BIN_DIR/$bin_name" ]; then
    echo "    bin/${bin_name}  $(stat --printf='%s' "$BIN_DIR/$bin_name" 2>/dev/null) bytes"
  else
    echo "    bin/${bin_name}  MISSING"
  fi
done)
────────────────────────────────────────────────────────
  Checks
────────────────────────────────────────────────────────
  [$( [ "$ok_count" -eq "$N_TOTAL" ] && echo "PASS" || echo "FAIL")] All ${ok_count}/$N_TOTAL binaries built
  [$( [ "$fail_count" -eq 0 ] && echo "PASS" || echo "FAIL")] Zero failures

══════════════════════════════════════════════════════════
  Finished: $(date '+%Y-%m-%d %H:%M:%S')
  Run dir:  $RUN_DIR
══════════════════════════════════════════════════════════
EOF

echo "[$(date -u +%Y-%m-%dT%H:%M:%S)] STAGE DONE  stage=task4.1-build  ok=$ok_count  fail=$fail_count" >> "$RUN_DIR/execution.log"

# Symlinks
ln -sfn "$RUN_TS" "$ARTIFACTS_DIR/runs/task4.1-dram-ratio/latest"

cat "$RUN_DIR/main.log"
echo "Done. ok=$ok_count fail=$fail_count"
