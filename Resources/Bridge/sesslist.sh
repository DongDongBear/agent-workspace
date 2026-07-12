#!/usr/bin/env bash
# One TSV row per tmux session: id, cwd, display path, activity/title, pane id, Claude PID.
# pane_pid gives a stable cwd; pane_current_path is only the fallback.
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

_t(){ date -r "$1" +'%m-%d %H:%M' 2>/dev/null || date -d "@$1" +'%m-%d %H:%M' 2>/dev/null; }
_cwd(){ readlink "/proc/$1/cwd" 2>/dev/null || lsof -a -d cwd -p "$1" -Fn 2>/dev/null | sed -n 's/^n//p' | head -1; }
_is_claude_process(){
  local comm
  comm=$(ps -o comm= -p "$1" 2>/dev/null) || return 1
  comm=${comm##*/}
  case "$comm" in claude|claude.exe) return 0;; *) return 1;; esac
}
_claude_pid(){
  local pid child
  local queue=("$1")
  while [ "${#queue[@]}" -gt 0 ]; do
    pid=${queue[0]}
    queue=("${queue[@]:1}")
    if _is_claude_process "$pid"; then
      printf '%s\n' "$pid"
      return 0
    fi
    while read -r child; do
      [ -n "$child" ] && queue+=("$child")
    done < <(pgrep -P "$pid" 2>/dev/null || true)
  done
  return 1
}

G=$'\033[38;5;64m●\033[0m'; Y=$'\033[38;5;136m●\033[0m'
FMT=$'#{session_name}\t#{session_activity}\t#{pane_pid}\t#{pane_current_path}\t#{pane_id}\t#{pane_title}'
tmux list-sessions -F "$FMT" 2>/dev/null | while IFS=$'\t' read -r s act pp pcp pane title; do
  claude_pid=$(_claude_pid "$pp") || continue
  cwd=$(_cwd "$pp"); [ -n "$cwd" ] || cwd="$pcp"
  case "$cwd" in "$HOME") reldir='~';; "$HOME"/*) reldir="~${cwd#$HOME}";; *) reldir=${cwd:-\?};; esac
  fb=$(printf %s "$title" | od -An -tu1 -N1 2>/dev/null | tr -dc 0-9)
  task=""
  if [ "${fb:-0}" -ge 128 ]; then
    case "$title" in ✳*) dot=$G ;; *) dot=$Y ;; esac
    task=${title#* }; [ "$task" = "$title" ] && task=""
  else
    dot=$G
  fi
  printf '%s\t%s\t%s\t%s %s  %s\t%s\t%s\n' "$s" "$cwd" "$reldir" "$dot" "$(_t "$act")" "$task" "$pane" "$claude_pid"
done
