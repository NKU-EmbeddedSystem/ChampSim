#!/usr/bin/env bash
# Functional Test Suite — Run all functional tests and report results.
#
# Usage:
#   bash tests/func/run_all.sh
set -euo pipefail

FUNC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  Profiling Pipeline — Functional Tests               ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

declare -A results=()
overall_pass=true
start_time=$(date +%s)

# ── Category A: CLI & Error Handling ────────────────────────
echo "┌─────────────────────────────────────────────────────┐"
echo "│  Category A: CLI & Error Handling                   │"
echo "└─────────────────────────────────────────────────────┘"
if bash "$FUNC_DIR/test_A_cli_errors.sh"; then
    results["A"]="PASS"
else
    results["A"]="FAIL"
    overall_pass=false
fi

# ── Category B: Idempotency & Flags ────────────────────────
echo ""
echo "┌─────────────────────────────────────────────────────┐"
echo "│  Category B: Idempotency & Control Flags            │"
echo "└─────────────────────────────────────────────────────┘"
if bash "$FUNC_DIR/test_B_idempotency.sh"; then
    results["B"]="PASS"
else
    results["B"]="FAIL"
    overall_pass=false
fi

# ── Category C: Mini Pipeline E2E ──────────────────────────
echo ""
echo "┌─────────────────────────────────────────────────────┐"
echo "│  Category C: Mini Pipeline End-to-End               │"
echo "└─────────────────────────────────────────────────────┘"
if bash "$FUNC_DIR/test_C_mini_pipeline.sh"; then
    results["C"]="PASS"
else
    results["C"]="FAIL"
    overall_pass=false
fi

# ── Category D+E: Parallel & Determinism ───────────────────
echo ""
echo "┌─────────────────────────────────────────────────────┐"
echo "│  Category D+E: Parallelism & Determinism            │"
echo "└─────────────────────────────────────────────────────┘"
if bash "$FUNC_DIR/test_DE_parallel_determinism.sh"; then
    results["DE"]="PASS"
else
    results["DE"]="FAIL"
    overall_pass=false
fi

# ── Category F: Controller ────────────────────────────────
echo ""
echo "┌─────────────────────────────────────────────────────┐"
echo "│  Category F: Batch Controller                       │"
echo "└─────────────────────────────────────────────────────┘"
if bash "$FUNC_DIR/test_F_controller.sh"; then
    results["F"]="PASS"
else
    results["F"]="FAIL"
    overall_pass=false
fi

# ── Summary ─────────────────────────────────────────────────
end_time=$(date +%s)
elapsed=$((end_time - start_time))

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  Functional Test Results                             ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

printf "  Category A (CLI & Errors):     %s\n" "${results[A]:-SKIP}"
printf "  Category B (Idempotency):      %s\n" "${results[B]:-SKIP}"
printf "  Category C (Mini Pipeline):    %s\n" "${results[C]:-SKIP}"
printf "  Category D+E (Parallel/Det):   %s\n" "${results[DE]:-SKIP}"
printf "  Category F (Controller):       %s\n" "${results[F]:-SKIP}"

echo ""
echo "  Elapsed: ${elapsed}s"

if $overall_pass; then
    echo ""
    echo "  All functional tests PASSED."
    exit 0
else
    echo ""
    echo "  Some tests FAILED. See details above."
    exit 1
fi
