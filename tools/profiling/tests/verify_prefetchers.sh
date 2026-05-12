#!/usr/bin/env bash
# verify_prefetchers.sh — Comprehensive Prefetcher Verification Suite
#
# Tests all completed prefetchers from PORTING_STATUS.md:
#   1. Compiles each into current ChampSim
#   2. Runs each on a fixed trace at 3 simulation sizes
#   3. Verifies no crashes and IPC differs from baseline (no prefetcher)
#   4. Uses tmux sessions for parallel execution
#   5. Saves structured results to a report directory
#
# Usage:
#   ./verify_prefetchers.sh                          # full build + run
#   ./verify_prefetchers.sh --build-only             # only compile
#   ./verify_prefetchers.sh --run-only               # only run (skip build)
#   ./verify_prefetchers.sh --parallel 8             # 8 concurrent tmux sessions
#   ./verify_prefetchers.sh --trace /path/to/trace   # custom trace
#   ./verify_prefetchers.sh --results /path/to/dir   # custom results dir
#   PARALLEL=8 TRACE=... ./verify_prefetchers.sh     # via env vars
#   DRY_RUN=1 ./verify_prefetchers.sh                # print plan, don't execute

set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════
#  Configuration (override via env or CLI flags)
# ═══════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHAMPSIM_DIR="${CHAMPSIM_DIR:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
TRACE="${TRACE:-${CHAMPSIM_DIR}/trace/600.perlbench_s-570B.champsimtrace.xz}"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
RESULTS_DIR="${RESULTS_DIR:-${CHAMPSIM_DIR}/tools/profiling/results/verify_${TIMESTAMP}}"
PARALLEL="${PARALLEL:-4}"
TIMEOUT_SEC="${TIMEOUT_SEC:-7200}"
DRY_RUN="${DRY_RUN:-0}"

# Configs are generated on-the-fly from champsim_config.json (current format)
BASE_CONFIG="${CHAMPSIM_DIR}/champsim_config.json"
CONFIG_DIR="${RESULTS_DIR}/configs"

# Three simulation sizes: label, warmup_instructions, simulation_instructions
SIM_SIZES=(
  "1M:1000000:1000000"
  "10M:10000000:10000000"
  "20M:20000000:20000000"
)

# ═══════════════════════════════════════════════════════════════════════
#  Prefetchers from PORTING_STATUS.md § DONE (12 prefetchers)
#  Each gets a config generated from the base champsim_config.json
# ═══════════════════════════════════════════════════════════════════════
PF_ORDER=(
  "no" "next_line" "stride" "stream" "ampm" "sms"
  "sandbox" "power7" "bingo" "dspatch" "mlop" "ppf"
)

# Derived: binary name per prefetcher
pf_binary_name() { echo "champsim_verify_${1}"; }
pf_config_name() { echo "verify_${1}"; }

# ═══════════════════════════════════════════════════════════════════════
#  Terminal helpers
# ═══════════════════════════════════════════════════════════════════════
BOLD='\033[1m'
GREEN='\033[32m'
YELLOW='\033[33m'
RED='\033[31m'
CYAN='\033[36m'
RESET='\033[0m'

say()   { echo -e "${BOLD}$*${RESET}"; }
ok()    { echo -e "${GREEN}  [OK]${RESET} $*"; }
warn()  { echo -e "${YELLOW}  [WARN]${RESET} $*" >&2; }
fail()  { echo -e "${RED}  [FAIL]${RESET} $*" >&2; }
info()  { echo -e "${CYAN}  [INFO]${RESET} $*"; }
die()   { echo -e "${RED}FATAL: $*${RESET}" >&2; exit 1; }

# ═══════════════════════════════════════════════════════════════════════
#  Sanity checks
# ═══════════════════════════════════════════════════════════════════════
sanity_check() {
  if [[ ! -d "$CHAMPSIM_DIR" ]]; then
    die "ChampSim directory not found: $CHAMPSIM_DIR"
  fi
  if [[ ! -f "$TRACE" ]]; then
    die "Trace file not found: $TRACE\n  Set TRACE=/path/to/trace or use --trace"
  fi
  if ! command -v tmux &>/dev/null; then
    die "tmux is required but not installed"
  fi
  if [[ ! -f "$BASE_CONFIG" ]]; then
    die "Base config not found: $BASE_CONFIG"
  fi

  ok "ChampSim dir:  $CHAMPSIM_DIR"
  ok "Base config:   $(basename "$BASE_CONFIG")"
  ok "Trace:         $(basename "$TRACE")"
  ok "Results dir:   $RESULTS_DIR"
  ok "Parallel:      $PARALLEL"
  ok "Prefetchers:   ${#PF_ORDER[@]}"
  ok "Sizes:         ${#SIM_SIZES[@]}"

  local total_runs=$((${#PF_ORDER[@]} * ${#SIM_SIZES[@]}))
  info "Total runs:    $total_runs (${#PF_ORDER[@]} prefetchers × ${#SIM_SIZES[@]} sizes)"
}

# ═══════════════════════════════════════════════════════════════════════
#  Config generation — creates per-prefetcher configs from base template
# ═══════════════════════════════════════════════════════════════════════
generate_configs() {
  mkdir -p "${CONFIG_DIR}"

  for pf in "${PF_ORDER[@]}"; do
    local config_file="${CONFIG_DIR}/$(pf_config_name "$pf").json"
    local binary_name
    binary_name=$(pf_binary_name "$pf")

    if [[ -f "$config_file" ]] && [[ "${FORCE_REBUILD:-0}" != "1" ]]; then
      continue  # already generated
    fi

    python3 -c "
import json
with open('${BASE_CONFIG}') as f:
    cfg = json.load(f)
cfg['executable_name'] = '${binary_name}'
for lvl in ['L1I','L1D','L2C','LLC']:
    cfg[lvl]['prefetcher'] = '${pf}'
with open('${config_file}','w') as f:
    json.dump(cfg, f, indent=2)
"
    info "Generated config: $(pf_config_name "$pf").json ← ${pf}"
  done
}

# ═══════════════════════════════════════════════════════════════════════
#  Phase 1: Build all prefetcher binaries
# ═══════════════════════════════════════════════════════════════════════
build_one() {
  local pf_name="$1"
  local config_name
  config_name=$(pf_config_name "$pf_name")
  local config_file="${CONFIG_DIR}/${config_name}.json"
  local binary_name
  binary_name=$(pf_binary_name "$pf_name")
  local binary="${CHAMPSIM_DIR}/bin/${binary_name}"
  local manifest="${RESULTS_DIR}/build_manifest.txt"

  # Check build manifest: skip only if recorded by THIS verification run
  if [[ -f "$binary" ]] && grep -qFx "${binary}" "${manifest}" 2>/dev/null && [[ "${FORCE_REBUILD:-0}" != "1" ]]; then
    info "SKIP ${pf_name} — verified in manifest"
    return 0
  fi

  if [[ -f "$binary" ]] && [[ "${FORCE_REBUILD:-0}" != "1" ]]; then
    warn "${pf_name} binary exists but NOT in this run's manifest — will rebuild"
  fi

  if [[ "$DRY_RUN" -eq 1 ]]; then
    info "DRY-RUN: would build ${pf_name} ← ${config_name}"
    return 0
  fi

  say "BUILD ${pf_name} ← ${config_name}"
  (
    cd "${CHAMPSIM_DIR}"
    ./config.sh "${config_file}" 2>&1 | sed 's/^/    /'
    make -j"$(nproc)" 2>&1 | tail -3 | sed 's/^/    /'
  ) || die "Build failed for ${pf_name}"

  [[ -f "$binary" ]] || die "Binary not found after build: $binary"

  # Record in build manifest — marks this binary as ours
  echo "${binary} | ${config_name} | $(date -Iseconds) | ${CHAMPSIM_DIR}" >> "${manifest}"
  ok "${pf_name} → ${config_name}"
}

build_all() {
  say ""
  say "═══════════════════════════════════════════════════════"
  say "  Phase 1: Building ${#PF_ORDER[@]} prefetcher binaries"
  say "═══════════════════════════════════════════════════════"

  mkdir -p "${RESULTS_DIR}/logs"

  # Generate per-prefetcher configs from template
  say "Generating configs from base: $(basename "$BASE_CONFIG")"
  generate_configs
  say ""

  # Initialize build manifest (one line per binary = our verification stamp)
  local manifest="${RESULTS_DIR}/build_manifest.txt"
  if [[ ! -f "$manifest" ]]; then
    echo "# Build Manifest — ${TIMESTAMP}" > "$manifest"
    echo "# Binary | Config | BuildTime | ChampSimDir" >> "$manifest"
  fi

  local built=0 skipped=0 failed=0
  for pf in "${PF_ORDER[@]}"; do
    local binary="${CHAMPSIM_DIR}/bin/$(pf_binary_name "$pf")"
    if [[ -f "$binary" ]] && grep -qFx "${binary}" "${manifest}" 2>/dev/null && [[ "${FORCE_REBUILD:-0}" != "1" ]]; then
      ((skipped++)) || true
      info "SKIP ${pf} (in manifest)"
      continue
    fi

    if build_one "$pf"; then
      ((built++)) || true
    else
      ((failed++)) || true
    fi
  done

  say ""
  say "Build summary: ${built} built, ${skipped} skipped, ${failed} failed"
  [[ $failed -gt 0 ]] && die "Build failures detected — aborting"
  return 0
}

# ═══════════════════════════════════════════════════════════════════════
#  Phase 2: Run tests (one tmux session per prefetcher)
# ═══════════════════════════════════════════════════════════════════════

# Extract IPC from a log file — returns "N/A" if not found
extract_ipc() {
  grep "cumulative IPC:" "$1" 2>/dev/null | tail -1 | grep -oP 'cumulative IPC:\s*\K[\d.]+' || echo "N/A"
}

# Check log for crash signatures — returns "OK" or error description
check_crash() {
  local log="$1"
  local sigs=""

  grep -qi "Segmentation fault\|SIGSEGV" "$log" && sigs="${sigs}SEGFAULT "
  grep -qi "assert.*failed\|Assertion" "$log"    && sigs="${sigs}ASSERT "
  grep -qi "SIGABRT\|Aborted" "$log"              && sigs="${sigs}ABORT "
  grep -qi "DEADLOCK" "$log"                      && sigs="${sigs}DEADLOCK "
  grep -qi "munmap_chunk\|double free\|free()\|corruption\|invalid pointer\|invalid next size" "$log" && sigs="${sigs}HEAP_CORRUPTION "
  grep -qi "stack smashing\|buffer overflow" "$log" && sigs="${sigs}STACK "
  grep -qi "FATAL\|internal error" "$log"         && sigs="${sigs}FATAL "
  grep -qi "terminate called\|std::terminate" "$log" && sigs="${sigs}TERMINATE "

  echo "${sigs:-OK}" | sed 's/ $//'
}

# Run one (prefetcher, size) combination
# Writes a one-line result to the results file
run_one_size() {
  local pf_name="$1"
  local config_name="$2"
  local size_label="$3"
  local warmup="$4"
  local sim="$5"
  local binary="${CHAMPSIM_DIR}/bin/${config_name}"
  local logfile="${RESULTS_DIR}/logs/${pf_name}_${size_label}.log"

  echo "=== ${pf_name} [${size_label}] W=${warmup} S=${sim} ===" > "$logfile"
  echo "Binary:  ${binary}" >> "$logfile"
  echo "Trace:   ${TRACE}" >> "$logfile"
  echo "Start:   $(date -Iseconds)" >> "$logfile"
  echo "" >> "$logfile"

  local start_ts=$(date +%s)
  local exit_code=0

  timeout "${TIMEOUT_SEC}" "${binary}" \
    --warmup-instructions "${warmup}" \
    --simulation-instructions "${sim}" \
    "${TRACE}" >> "$logfile" 2>&1 || exit_code=$?

  local end_ts=$(date +%s)
  local elapsed=$((end_ts - start_ts))
  local elapsed_fmt=$(printf '%02d:%02d' $((elapsed/60)) $((elapsed%60)))

  local ipc
  ipc=$(extract_ipc "$logfile")
  local crash
  crash=$(check_crash "$logfile")

  local status="PASS"
  local notes=""

  if [[ "$exit_code" -eq 124 ]]; then
    status="FAIL"
    notes="TIMEOUT(${TIMEOUT_SEC}s)"
  elif [[ "$crash" != "OK" ]]; then
    status="FAIL"
    notes="$crash"
  elif [[ "$exit_code" -ne 0 ]]; then
    status="FAIL"
    notes="exit=${exit_code}"
  elif [[ "$ipc" == "N/A" ]]; then
    status="FAIL"
    notes="no IPC output"
  fi

  echo "Exit:    ${exit_code} (${elapsed_fmt})" >> "$logfile"
  echo "IPC:     ${ipc}" >> "$logfile"
  echo "Status:  ${status} ${notes}" >> "$logfile"

  # Write tabular result line
  echo "${pf_name}|${size_label}|${warmup}|${sim}|${exit_code}|${ipc}|${elapsed_fmt}|${status}|${notes}" \
    >> "${RESULTS_DIR}/results.txt"

  if [[ "$status" == "PASS" ]]; then
    ok "${pf_name} ${size_label}: IPC=${ipc} (${elapsed_fmt})"
    return 0
  else
    fail "${pf_name} ${size_label}: ${notes} IPC=${ipc} (${elapsed_fmt})"
    return 1
  fi
}

# Run all 3 sizes for one prefetcher — called inside tmux
run_prefetcher_all_sizes() {
  local pf_name="$1"
  local config_name="$2"
  local status_file="${RESULTS_DIR}/logs/${pf_name}.status"
  local passed=0
  local failed=0

  echo "RUNNING" > "$status_file"

  say ""
  say "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  say "  ${pf_name}  (config: ${config_name})"
  say "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  for size_spec in "${SIM_SIZES[@]}"; do
    IFS=':' read -r label warmup sim <<< "$size_spec"
    if run_one_size "$pf_name" "$config_name" "$label" "$warmup" "$sim"; then
      ((passed++)) || true
    else
      ((failed++)) || true
    fi
  done

  echo "DONE:${passed}:${failed}" > "$status_file"
  say ""
  say "${pf_name}: ${GREEN}${passed} passed${RESET}, ${RED}${failed} failed${RESET}"
  say ""
}

# Generate a standalone runner script that can be executed in tmux
write_runner_script() {
  local pf_name="$1"
  local config_name="$2"
  local runner="${RESULTS_DIR}/logs/run_${pf_name}.sh"

  cat > "$runner" << RUNNER_EOF
#!/usr/bin/env bash
# Auto-generated runner for ${pf_name}
# Do not edit — regenerated by verify_prefetchers.sh

export RESULTS_DIR="${RESULTS_DIR}"
export CHAMPSIM_DIR="${CHAMPSIM_DIR}"
export TRACE="${TRACE}"
export TIMEOUT_SEC="${TIMEOUT_SEC}"

# Rebuild SIM_SIZES array
SIM_SIZES=(
  "${SIM_SIZES[0]}"
  "${SIM_SIZES[1]}"
  "${SIM_SIZES[2]}"
)

# Source helper functions from parent script
source "${SCRIPT_DIR}/verify_prefetchers.sh" --source-only 2>/dev/null || true

run_prefetcher_all_sizes "${pf_name}" "${config_name}"
RUNNER_EOF

  chmod +x "$runner"
  echo "$runner"
}

# Count currently running tmux sessions matching our prefix
count_running() {
  tmux ls 2>/dev/null | grep -c "^pfv-${TIMESTAMP}-" || true
}

# Wait until a slot opens up
wait_for_slot() {
  while true; do
    local running
    running=$(count_running)
    if [[ $running -lt $PARALLEL ]]; then
      return 0
    fi
    local done_count=0
    for pf in "${PF_ORDER[@]}"; do
      local sf="${RESULTS_DIR}/logs/${pf}.status"
      [[ -f "$sf" ]] && grep -q "DONE" "$sf" && ((done_count++)) || true
    done
    say "Slots full (${running}/${PARALLEL}), done: ${done_count}/${#PF_ORDER[@]} ... waiting 15s"
    sleep 15
  done
}

run_all() {
  say ""
  say "═══════════════════════════════════════════════════════"
  say "  Phase 2: Running ${#PF_ORDER[@]} prefetchers × ${#SIM_SIZES[@]} sizes"
  say "  Parallel tmux sessions: ${PARALLEL}"
  say "═══════════════════════════════════════════════════════"

  mkdir -p "${RESULTS_DIR}/logs"

  # Write results header
  echo "prefetcher|size|warmup|sim|exit|ipc|elapsed|status|notes" > "${RESULTS_DIR}/results.txt"

  local launched=0

  for pf in "${PF_ORDER[@]}"; do
    local status_file="${RESULTS_DIR}/logs/${pf}.status"

    # Skip if already done (useful for resume)
    if [[ -f "$status_file" ]] && grep -q "DONE" "$status_file"; then
      local s
      s=$(cat "$status_file")
      info "SKIP ${pf} — already done (${s})"
      continue
    fi

    # Wait for a tmux slot
    wait_for_slot

    # Write per-prefetcher runner script
    local runner
    runner=$(write_runner_script "$pf" "$(pf_binary_name "$pf")")

    local session="pfv-${TIMESTAMP}-${pf}"
    echo "RUNNING" > "$status_file"

    if [[ "$DRY_RUN" -eq 1 ]]; then
      info "DRY-RUN: would launch tmux session ${session} with ${runner}"
      ((launched++)) || true
      continue
    fi

    # Kill stale session if it exists
    tmux kill-session -t "$session" 2>/dev/null || true
    sleep 0.5

    # Launch: the tmux session runs the runner script, then drops to an
    # interactive shell so the user can inspect output after completion.
    tmux new-session -d -s "$session" -x 120 -y 40 \
      "echo '=== Prefetcher: ${pf} ==='; echo 'Log: ${RESULTS_DIR}/logs/${pf}_*.log'; echo ''; bash '${runner}'; exit_code=\$?; echo ''; echo \"Session complete (exit=\${exit_code}). Closing in 10s...\"; sleep 10" 2>&1

    if [[ $? -eq 0 ]]; then
      ((launched++)) || true
      say "LAUNCH [${launched}/${#PF_ORDER[@]}] ${pf} → tmux:${session}"
      info "  Attach:  tmux attach -t ${session}"
      info "  Logs:    ${RESULTS_DIR}/logs/${pf}_*.log"
    else
      fail "Failed to launch tmux session for ${pf}"
      echo "FAILED:tmux_error:0" > "$status_file"
    fi

    # Brief delay to avoid thundering herd
    sleep 1
  done

  say ""
  say "All ${launched} sessions launched. Waiting for completion..."
  say ""
}

# ═══════════════════════════════════════════════════════════════════════
#  Phase 3: Collect results & generate report
# ═══════════════════════════════════════════════════════════════════════
wait_for_completion() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    say "DRY-RUN: skipping wait"
    return
  fi

  local prev_done=-1
  while true; do
    local done_count=0
    local total=${#PF_ORDER[@]}

    for pf in "${PF_ORDER[@]}"; do
      local sf="${RESULTS_DIR}/logs/${pf}.status"
      [[ -f "$sf" ]] && grep -q "DONE" "$sf" && ((done_count++)) || true
    done

    if [[ $done_count -ne $prev_done ]]; then
      say "Progress: ${done_count}/${total} prefetchers complete"
      prev_done=$done_count
    fi

    [[ $done_count -ge $total ]] && break
    sleep 20
  done

  say ""
  say "All ${total} prefetchers finished."
}

generate_report() {
  say ""
  say "═══════════════════════════════════════════════════════"
  say "  Phase 3: Results Report"
  say "═══════════════════════════════════════════════════════"

  local results="${RESULTS_DIR}/results.txt"
  local report="${RESULTS_DIR}/report.txt"

  {
    echo "============================================================"
    echo "  Prefetcher Verification Report"
    echo "  Generated: $(date -Iseconds)"
    echo "  Trace:     $(basename "$TRACE")"
    echo "  ChampSim:  ${CHAMPSIM_DIR}"
    echo "============================================================"
    echo ""

    # ── Per-prefetcher summary ──────────────────────────────
    echo "## Per-Prefetcher Summary"
    echo ""
    printf "%-14s %6s %8s %6s %8s %6s %8s %6s %7s\n" \
      "Prefetcher" "1M-IPC" "Δ-no" "10M-IPC" "Δ-no" "50M-IPC" "Δ-no" "Pass" "Status"
    printf "%-14s %6s %8s %6s %8s %6s %8s %6s %7s\n" \
      "----------" "------" "-----" "-------" "-----" "-------" "-----" "----" "------"

    # Collect baseline (no) IPC values
    local no_1m="" no_10m="" no_50m=""
    while IFS='|' read -r pf size warmup sim exit ipc elapsed status notes; do
      [[ "$pf" == "no" && "$size" == "1M" ]] && no_1m="$ipc"
      [[ "$pf" == "no" && "$size" == "10M" ]] && no_10m="$ipc"
      [[ "$pf" == "no" && "$size" == "50M" ]] && no_50m="$ipc"
    done < <(tail -n +2 "$results")

    # Compute and display per-prefetcher
    for pf in "${PF_ORDER[@]}"; do
      local pf_1m="" pf_10m="" pf_50m=""
      local pass_count=0 fail_count=0

      while IFS='|' read -r p size warmup sim exit ipc elapsed status notes; do
        [[ "$p" != "$pf" ]] && continue
        case "$size" in
          1M) pf_1m="$ipc";
              if [[ "$status" == "PASS" ]]; then ((pass_count++)) || true; else ((fail_count++)) || true; fi ;;
          10M) pf_10m="$ipc";
              if [[ "$status" == "PASS" ]]; then ((pass_count++)) || true; else ((fail_count++)) || true; fi ;;
          50M) pf_50m="$ipc";
              if [[ "$status" == "PASS" ]]; then ((pass_count++)) || true; else ((fail_count++)) || true; fi ;;
        esac
      done < <(tail -n +2 "$results")

      # Compute delta vs no
      local d1m="N/A" d10m="N/A" d50m="N/A"
      [[ -n "$pf_1m" && -n "$no_1m" && "$pf_1m" != "N/A" && "$no_1m" != "N/A" ]] && \
        d1m=$(python3 -c "print(f'{float($pf_1m)-float($no_1m):+.4f}')" 2>/dev/null || echo "N/A")
      [[ -n "$pf_10m" && -n "$no_10m" && "$pf_10m" != "N/A" && "$no_10m" != "N/A" ]] && \
        d10m=$(python3 -c "print(f'{float($pf_10m)-float($no_10m):+.4f}')" 2>/dev/null || echo "N/A")
      [[ -n "$pf_50m" && -n "$no_50m" && "$pf_50m" != "N/A" && "$no_50m" != "N/A" ]] && \
        d50m=$(python3 -c "print(f'{float($pf_50m)-float($no_50m):+.4f}')" 2>/dev/null || echo "N/A")

      local overall="PASS"
      [[ $fail_count -gt 0 ]] && overall="FAIL"

      printf "%-14s %6s %8s %6s %8s %6s %8s %6s %7s\n" \
        "$pf" "${pf_1m:-N/A}" "${d1m}" "${pf_10m:-N/A}" "${d10m}" "${pf_50m:-N/A}" "${d50m}" "${pass_count}/$((pass_count+fail_count))" "$overall"
    done

    echo ""

    # ── Detailed per-size results ──────────────────────────
    echo "## Detailed Results"
    echo ""
    printf "%-14s %6s %10s %10s %6s %8s %8s %-20s\n" \
      "Prefetcher" "Size" "Warmup" "Sim" "Exit" "IPC" "Elapsed" "Status/Notes"
    printf "%-14s %6s %10s %10s %6s %8s %8s %-20s\n" \
      "----------" "----" "------" "---" "----" "---" "-------" "-----------"

    while IFS='|' read -r pf size warmup sim exit ipc elapsed status notes; do
      [[ "$pf" == "prefetcher" ]] && continue  # skip header
      printf "%-14s %6s %10s %10s %6s %8s %8s %-20s\n" \
        "$pf" "$size" "$warmup" "$sim" "$exit" "$ipc" "$elapsed" "${status} ${notes}"
    done < <(tail -n +2 "$results")

    echo ""

    # ── IPC divergence check ──────────────────────────────
    echo "## IPC Divergence Check (vs no prefetcher)"
    echo ""
    echo "The IPC of each prefetcher MUST differ from the baseline (no prefetcher)."
    echo "Non-divergence suggests the prefetcher is a no-op or not correctly wired."
    echo ""

    local nondiv_count=0
    for pf in "${PF_ORDER[@]}"; do
      [[ "$pf" == "no" ]] && continue
      local nondiv=""

      while IFS='|' read -r p size warmup sim exit ipc elapsed status notes; do
        [[ "$p" != "$pf" ]] && continue
        [[ "$ipc" == "N/A" ]] && continue
        local baseline=""
        case "$size" in
          1M) baseline="$no_1m" ;;
          10M) baseline="$no_10m" ;;
          50M) baseline="$no_50m" ;;
        esac
        if [[ -n "$baseline" && "$baseline" != "N/A" ]]; then
          local diff
          diff=$(python3 -c "print(abs(float($ipc)-float($baseline)))" 2>/dev/null || echo "N/A")
          if [[ "$diff" != "N/A" ]] && python3 -c "exit(0 if float($diff) < 0.0001 else 1)" 2>/dev/null; then
            nondiv="${nondiv}${size} "
          fi
        fi
      done < <(tail -n +2 "$results")

      if [[ -n "$nondiv" ]]; then
        warn "${pf}: IPC matches no at: ${nondiv}"
        ((nondiv_count++)) || true
      else
        ok "${pf}: IPC diverges from no (all sizes)"
      fi
    done

    echo ""

    # ── Overall statistics ────────────────────────────────
    echo "## Overall Statistics"
    echo ""
    local total_pass=0 total_fail=0 total_runs=0
    while IFS='|' read -r pf size warmup sim exit ipc elapsed status notes; do
      [[ "$pf" == "prefetcher" ]] && continue
      ((total_runs++)) || true
      if [[ "$status" == "PASS" ]]; then ((total_pass++)) || true; else ((total_fail++)) || true; fi
    done < <(tail -n +2 "$results")

    echo "Total runs:      ${total_runs}"
    echo "Passed:          ${total_pass}"
    echo "Failed:          ${total_fail}"
    echo "Non-divergent:   ${nondiv_count}"
    echo ""

    # ── Crash summary ─────────────────────────────────────
    echo "## Crashes & Errors"
    echo ""
    local crash_count=0
    while IFS='|' read -r pf size warmup sim exit ipc elapsed status notes; do
      [[ "$pf" == "prefetcher" || "$status" == "PASS" ]] && continue
      echo "  ${pf} [${size}]: ${notes}"
      ((crash_count++))
    done < <(tail -n +2 "$results")

    [[ $crash_count -eq 0 ]] && ok "No crashes detected"

    echo ""
    echo "============================================================"
    echo "  Full logs: ${RESULTS_DIR}/logs/"
    echo "  Raw data:  ${RESULTS_DIR}/results.txt"
    echo "  Report:    ${report}"
    echo "============================================================"

  } | tee "$report"

  say ""
  say "Report saved to: ${report}"
}

# ═══════════════════════════════════════════════════════════════════════
#  Main
# ═══════════════════════════════════════════════════════════════════════
main() {
  local BUILD_ONLY=0
  local RUN_ONLY=0

  # Parse CLI args (override defaults)
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --parallel)   PARALLEL="$2"; shift 2 ;;
      --trace)      TRACE="$2"; shift 2 ;;
      --timeout)    TIMEOUT_SEC="$2"; shift 2 ;;
      --results)    RESULTS_DIR="$2"; shift 2 ;;
      --build-only)   BUILD_ONLY=1; shift ;;
      --run-only)     RUN_ONLY=1; shift ;;
      --force-rebuild) FORCE_REBUILD=1; shift ;;
      --source-only)  return 0 ;;  # internal: allow sourcing for function export
      --dry-run)      DRY_RUN=1; shift ;;
      -h|--help)
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --parallel N      Max concurrent tmux sessions (default: 4)"
        echo "  --trace PATH      Trace file path"
        echo "  --timeout SEC     Timeout per run in seconds (default: 7200)"
        echo "  --results DIR     Results directory"
        echo "  --build-only      Only compile, don't run tests"
        echo "  --run-only        Only run tests, skip compilation"
        echo "  --force-rebuild   Rebuild even if binary in manifest"
        echo "  --dry-run         Print plan, don't execute"
        echo "  -h, --help        Show this help"
        echo ""
        echo "Environment variables:"
        echo "  CHAMPSIM_DIR  TRACE  RESULTS_DIR  PARALLEL  TIMEOUT_SEC  DRY_RUN"
        exit 0
        ;;
      *) die "Unknown option: $1 (use --help)" ;;
    esac
  done

  # Header
  echo ""
  say "╔═══════════════════════════════════════════════════════╗"
  say "║     Prefetcher Verification Suite                     ║"
  say "║     PORTING_STATUS.md — 12 completed prefetchers      ║"
  say "╚═══════════════════════════════════════════════════════╝"
  echo ""

  sanity_check

  if [[ "$RUN_ONLY" -ne 1 ]]; then
    build_all
  fi

  if [[ "$BUILD_ONLY" -eq 1 ]]; then
    say "Build-only mode — skipping test runs."
    return 0
  fi

  run_all
  wait_for_completion
  generate_report

  say ""
  say "╔═══════════════════════════════════════════════════════╗"
  say "║     Verification Complete                             ║"
  say "╚═══════════════════════════════════════════════════════╝"
  say ""
  say "Tmux sessions:  tmux ls | grep pfv-${TIMESTAMP}-"
  say "Results:        ${RESULTS_DIR}/"
  say "Report:         ${RESULTS_DIR}/report.txt"
  say ""
}

# ── Entry point ────────────────────────────────────────────────────────
main "$@"
