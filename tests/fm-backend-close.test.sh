#!/usr/bin/env bash
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

check_close() {
  local backend=$1 target=$2 expected=$3 rc=0
  shift 3
  "fm_backend_${backend}_kill" "$target" "$@" || rc=$?
  expect_code "$expected" "$rc" "$backend close reported an incorrect stop status"
}

(
  . "$ROOT/bin/backends/cmux.sh"
  fm_backend_cmux_window_of_workspace() { printf 'window 2'; }
  fm_backend_cmux_target_ready() { fm_backend_cmux_parse_target "$1"; }
  fm_backend_cmux_cli() { return "$close_status"; }
  close_status=1
  check_close cmux workspace:surface 1 '' fm-task
  close_status=0
  check_close cmux workspace:surface 0 '' fm-task
  fm_backend_cmux_window_of_workspace() { printf 'window 1'; }
  close_status=1
  check_close cmux workspace:surface 1 '' fm-task
  fm_backend_cmux_target_ready() { return 1; }
  check_close cmux workspace:surface 1 '' fm-task
) || exit 1
pass "cmux refuses failed closes, failed sibling creation and unresolved targets"

(
  . "$ROOT/bin/backends/zellij.sh"
  zellij() { printf 'firstmate\n'; return "$inventory_status"; }
  fm_backend_zellij_tab_for_pane() { printf '3'; }
  fm_backend_zellij_tab_matches_label() { return "$label_status"; }
  fm_backend_zellij_cli() { return "$close_status"; }
  inventory_status=0 label_status=0 close_status=1
  check_close zellij firstmate:7 1 3 fm-task
  check_close zellij firstmate:7 1
  close_status=0
  check_close zellij firstmate:7 0 3 fm-task
  fm_backend_zellij_tab_for_pane() { return 0; }
  close_status=1
  check_close zellij firstmate:7 1
  close_status=0
  check_close zellij firstmate:7 0
  label_status=1
  check_close zellij firstmate:7 1 3 fm-task
  inventory_status=1
  check_close zellij firstmate:7 1
  zellij() { printf 'other\n'; }
  check_close zellij firstmate:7 0
) || exit 1
pass "zellij distinguishes confirmed absence from failed reads, closes and identity checks"

(
  . "$ROOT/bin/backends/orca.sh"
  orca() { printf '%s\n' "$close_response"; return "$close_status"; }
  close_status=1 close_response='{}'
  check_close orca terminal 1
  close_status=0 close_response='{"ok":false}'
  check_close orca terminal 2
  close_response='{"ok":true}'
  check_close orca terminal 0
) || exit 1
pass "orca reports close command and protocol failures while accepting successful closes"
