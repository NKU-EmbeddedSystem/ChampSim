#!/usr/bin/env bash
# Show PIN trace capture status for all benchmarks.
# Usage: ./trace_status.sh [--watch]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/config.sh"

print_status() {
  clear 2>/dev/null || true
  echo "PIN Trace Status — $(date '+%H:%M:%S')"
  echo "========================================="
  printf "%-20s %6s %6s %8s  %s\n" "benchmark" "ready" "expect" "size" "status"
  printf "%-20s %6s %6s %8s  %s\n" "--------------------" "-----" "-----" "------" "------"

  for bench_dir in "$DATA_ROOT"/*/; do
    b=$(basename "$bench_dir")
    [ "$b" = "batch_logs" ] && continue
    [ "$b" = "stage_3" ] && continue
    [ "$b" = "simpoints" ] && continue

    traces_dir="$bench_dir/traces"
    [ ! -d "$traces_dir" ] && continue

    # Count ready (.xz) and raw (still recording) files
    ready=0; raw=0
    for f in "$traces_dir"/*.xz; do [ -f "$f" ] && ((ready++)); done 2>/dev/null
    for f in "$traces_dir"/*.champsimtrace; do
      [ -f "$f" ] && [[ "$f" != *.xz ]] && ((raw++))
    done 2>/dev/null

    # Get expected count from simpoints.json
    expect=0
    simpoints_file="$bench_dir/simpoints.json"
    if [ -f "$simpoints_file" ]; then
      expect=$(python3 -c "
import json
d=json.load(open('$simpoints_file'))
print(sum(1 for e in d if e['weight']>=0.01))
" 2>/dev/null)
    fi

    [ "$expect" = "0" ] && continue

    # Determine status
    if [ "$ready" -ge "$expect" ]; then
      st="DONE"
    elif [ "$raw" -gt 0 ]; then
      st="RECORDING"
    elif [ "$ready" -gt 0 ]; then
      st="PARTIAL"
    else
      st="PENDING"
    fi

    # Get total size
    sz=$(du -sh "$traces_dir" 2>/dev/null | cut -f1)

    printf "%-20s %6s %6s %8s  %s\n" "$b" "$ready/$expect" "$expect" "$sz" "$st"
  done

  echo ""
  echo "Refresh: watch -n 30 ./tools/profiling/trace_status.sh"
}

if [ "${1:-}" = "--watch" ]; then
  while true; do
    print_status
    sleep 30
  done
else
  print_status
fi
