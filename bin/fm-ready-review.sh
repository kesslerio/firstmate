#!/usr/bin/env bash
# fm-ready-review.sh - durable owning-home dependency/ready-work review.
# Usage: fm-ready-review.sh scan | needs-review | poll | report-check routine|captain
#        fm-ready-review.sh guard main|branch
#        fm-ready-review.sh stop TASK GENERATION --gate structured|approval|credential|account|spend|capacity|away|external --reason TEXT --retry TEXT
#        fm-ready-review.sh launch TASK SPAWN_GENERATION
#
# bin/fm_ready_review.py owns the receipt schema, validation and lifecycle.
# scan prints current candidates and generation tokens. stop records a current
# concrete stop, invalidated by graph/hold or gate configuration changes.
# structured requires a still-current actual hold/blocker; other stops expire
# within five minutes and require renewed current evidence.
# Other stops are the acting supervisor's explicit attestations, not inferred
# from prose or proof that a credential was tested. Never put secrets in notes.
# launch is fm-spawn's post-commit hook, not a substitute for fm-spawn; it binds
# a launch and leaves processing proof to the current-state owner.
# A manual-backlog queued launch retains its confirmed fact as pending accounting
# without editing the row; the manual owner must move it In flight before current
# processing can settle the review.
# An observed start remains accounted after the same worker goes idle or ends.
# Pruning a Done prerequisite retains that exact observed start while marking
# the dependency missing; it grants no new dispatch or hold-release authority.
# Requeued work and changed task, hold or worker identity need a fresh start.
# Confirmed launch provenance survives graph unavailability only within its
# original candidate epoch; a later current processing observation is required.
# Receipts check owner consistency; they do not defend against same-user edits.
# Report and wake acknowledgments retain work without a current disposition.
# poll is the watcher's bounded graph-change observer; it queues before marking
# an observation and prints heartbeat only for a newly published durable wake.
set -eu
case "${1:-}" in
  -h|--help) sed -n '2,/^set -eu/{ /^#/s/^# \{0,1\}//p; }' "$0"; exit 0 ;;
esac
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
export FM_HOME
command -v python3 >/dev/null 2>&1 || { echo 'ready review: python3 is required to retain review responsibility' >&2; exit 1; }
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
DATA=${FM_DATA_OVERRIDE:-$FM_HOME/data}
if [ ! -e "$DATA" ] && [ ! -L "$DATA" ]; then
  BACKLOG_ROOT=$(cd "$(dirname "$DATA")" && pwd -P) || exit 1
  DATA="$BACKLOG_ROOT/$(basename "$DATA")"
else
  DATA=$(fm_backlog_data_absolute "$DATA") || exit 1
  BACKLOG_ROOT=$(fm_backlog_root "$DATA") || exit 1
fi
BACKEND=$(fm_tasks_axi_backend "$BACKLOG_ROOT") || exit 1
CONFIG=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
manual_args=()
if fm_backlog_backend_manual "$CONFIG"; then
  manual_args+=(--manual-lifecycle)
fi
exec python3 "$SCRIPT_DIR/fm_ready_review.py" --data "$DATA" --backend "$BACKEND" ${manual_args[@]+"${manual_args[@]}"} "$@"
