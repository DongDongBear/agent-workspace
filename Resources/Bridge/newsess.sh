#!/usr/bin/env bash
set -euo pipefail

export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8
NEWDIR="${1:-$HOME}"

command -v tmux >/dev/null 2>&1 || { printf '%s\n' 'Agent Workspace requires tmux.' >&2; exit 127; }
command -v claude >/dev/null 2>&1 || { printf '%s\n' 'Agent Workspace requires Claude Code.' >&2; exit 127; }
[ -d "$NEWDIR" ] || { printf 'Not a directory: %s\n' "$NEWDIR" >&2; exit 2; }

n=1
while tmux has-session -t "=agent-workspace-$n" 2>/dev/null; do n=$((n + 1)); done
session="agent-workspace-$n"
tmux new-session -d -s "$session" -c "$NEWDIR" \
  -e LANG=en_US.UTF-8 -e LC_ALL=en_US.UTF-8 -e "PATH=$PATH" 'exec claude'
printf '%s\n' "$session"
