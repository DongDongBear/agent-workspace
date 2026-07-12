#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)

tmux() {
  if [ "${1:-}" = list-sessions ]; then
    printf '%s\n' $'claude-parent\t1\t101\t/tmp/project\t%1\tshell'
    printf '%s\n' $'plain-shell\t1\t202\t/tmp/project\t%2\tshell'
    printf '%s\n' $'claude-child\t1\t303\t/tmp/project\t%3\tshell'
    printf '%s\n' $'cockpit\t1\t404\t/tmp/project\t%4\tshell'
    printf '%s\n' $'mixed-panes\t1\t501\t/tmp/project\t%5\tshell'
  else
    printf '%s\n' $'claude-parent\t1\t101\t/tmp/project\t%1\tshell'
    printf '%s\n' $'plain-shell\t1\t202\t/tmp/project\t%2\tshell'
    printf '%s\n' $'claude-child\t1\t303\t/tmp/project\t%3\tshell'
    printf '%s\n' $'cockpit\t1\t404\t/tmp/project\t%4\tshell'
    printf '%s\n' $'mixed-panes\t1\t501\t/tmp/project\t%5\tshell'
    printf '%s\n' $'mixed-panes\t1\t503\t/tmp/project\t%6\tshell'
  fi
}
ps() {
  local pid=${!#}
  case "$pid" in 102|304|405|504) printf '%s\n' claude ;; *) printf '%s\n' zsh ;; esac
}
pgrep() {
  case "${!#}" in
    101) printf '%s\n' 102 ;;
    303) printf '%s\n' 304 ;;
    404) printf '%s\n' 405 ;;
    503) printf '%s\n' 504 ;;
    *) return 1 ;;
  esac
}
readlink() { printf '%s\n' /tmp/project; }
lsof() { return 1; }
date() { printf '%s\n' '01-01 00:00'; }
export -f tmux ps pgrep readlink lsof date

OUTPUT=$(bash "$ROOT/Resources/Bridge/sesslist.sh")
grep -q '^claude-parent' <<<"$OUTPUT"
grep -q '^claude-child' <<<"$OUTPUT"
grep -q '^cockpit' <<<"$OUTPUT"
awk -F $'\t' '$1 == "mixed-panes" && $5 == "%6" && $6 == 504 { count++ } END { exit !(count == 1) }' <<<"$OUTPUT" || {
  printf '%s\n' 'FAIL: sesslist missed Claude running in a non-active pane' >&2
  exit 1
}
awk -F $'\t' 'NF != 6 || $5 !~ /^%[0-9]+$/ || $6 !~ /^[0-9]+$/ { exit 1 }' <<<"$OUTPUT" || {
  printf '%s\n' 'FAIL: sesslist did not preserve exact pane and Claude process identities' >&2
  exit 1
}
awk -F $'\t' '$1 == "claude-parent" && $6 == 102 { parent = 1 } $1 == "claude-child" && $6 == 304 { child = 1 } END { exit !(parent && child) }' <<<"$OUTPUT" || {
  printf '%s\n' 'FAIL: sesslist returned a shell wrapper PID instead of the exact Claude child PID' >&2
  exit 1
}
if grep -q '^plain-shell' <<<"$OUTPUT"; then
  printf '%s\n' 'FAIL: sesslist included a non-Claude tmux session' >&2
  exit 1
fi

LOG=$(mktemp)
FIXTURE=$(mktemp -d)
trap 'rm -f "$LOG"; rm -rf "$FIXTURE"' EXIT
tmux() {
  printf '%s\n' "$*" >> "$LOG"
  if [ "${1:-}" = has-session ]; then
    [ "${3:-}" = '=agent-workspace-1' ]
    return
  fi
  return 0
}
claude() { :; }
export LOG
export -f tmux claude
SESSION=$(bash "$ROOT/Resources/Bridge/newsess.sh" "$FIXTURE")
[ "$SESSION" = agent-workspace-2 ] || { printf 'FAIL: expected agent-workspace-2, got %s\n' "$SESSION" >&2; exit 1; }
grep -Fq "new-session -d -s agent-workspace-2 -c $FIXTURE " "$LOG"
grep -q 'exec claude$' "$LOG"

printf '%s\n' 'PASS: bundled bridges find Claude sessions and start plain agent-workspace-N sessions'
