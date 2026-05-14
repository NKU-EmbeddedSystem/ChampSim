#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <session-name> <command> [args...]" >&2
  exit 1
fi

session_name="$1"
shift

tmux new-session -d -s "$session_name" "$*"
echo "started tmux session: $session_name"
