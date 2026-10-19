# shellcheck shell=bash
fm_ready_queue_needs_review() (
  local script_dir rc
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
  "$script_dir/fm-ready-review.sh" needs-review >/dev/null 2>&1 && return 0
  rc=$?
  # A failed read remains actionable uncertainty, never an empty queue.
  [ "$rc" != 1 ]
)
