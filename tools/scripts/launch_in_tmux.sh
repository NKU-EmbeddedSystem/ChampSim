#!/usr/bin/env bash
#
# launch_in_tmux.sh — Run a command in an isolated, detachable tmux session.
#
# Pattern from: coordinate_hint_cache/.claude/skills/tmux/
#
# Usage:
#   ./launch_in_tmux.sh <session-name> <command> [args...]
#   ./launch_in_tmux.sh profiling-400.perlbench-no_d1 bash run_pipeline.sh 400.perlbench --stage 4
#
# Notes:
#   - Tmux is for observation, not log persistence. Always redirect output to log files.
#   - Kill sessions when done:  tmux kill-session -t <name>
#   - List sessions:            tmux list-sessions
#

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <session-name> <command> [args...]" >&2
  exit 1
fi

session_name="$1"
shift

# Kill existing session with same name if present
tmux kill-session -t "$session_name" 2>/dev/null || true

tmux new-session -d -s "$session_name" "$*"
echo "[tmux] started session: $session_name  (tmux attach -t $session_name)"
