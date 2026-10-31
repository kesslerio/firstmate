#!/usr/bin/env bash
set -u
. "/home/art/.no-mistakes/worktrees/9f75ec418609/01M68ERTXFG1M8WBBKXPBN9FS0/bin/fm-session-lock-lib.sh"
if fm_proc_info "$1"; then
  if fm_harness_process_matches "$FM_PROC_COMM" "$FM_PROC_ARGS"; then m=yes; else m=no; fi
  printf 'verdict readable match=%s|' "$m"
  printf 'fields comm=%q args=%q ppid=%s' "$FM_PROC_COMM" "$FM_PROC_ARGS" "$FM_PROC_PPID"
else
  printf 'verdict unreadable match=no|fields none'
fi
