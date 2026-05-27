---
name: tmux
description: Run commands in isolated tmux sessions. Use when the user wants to start a server, run long-lived processes, or execute commands that need detachable terminal sessions.
user-invocable: true
version: 2e671f8
---

# Tmux Session Management

When the user needs to run a long-lived command or detachable terminal session:

1. Launch via the helper script:
   ```
   bash .claude/skills/tmux/scripts/launch_in_tmux.sh <session-name> <command>
   ```
2. The script creates a detached tmux session — the command runs inside it.

## Session naming

Use descriptive names: `<project>-<context>`. Examples: `webui-dev-server`, `eval-run-3`.

## Important

- Tmux is for observation, not log persistence. Always redirect command output to log files.
- Kill sessions when done: `tmux kill-session -t <name>`.
