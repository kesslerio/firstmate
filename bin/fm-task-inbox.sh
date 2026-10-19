#!/usr/bin/env bash
# Record an exact instruction's disposition, or inspect its obligations.
# Usage (FM_HOME is required; FM_STATE_OVERRIDE selects an explicit state channel):
#   fm-task-inbox.sh query <task>
#   fm-task-inbox.sh disposition <task> <record> --gen <spawn_gen> --disposition waiting|refused --reason <reason> --condition <condition-or-key>
#   fm-task-inbox.sh disposition <task> <record> --gen <spawn_gen> --disposition fulfilled --response <response-file-in-home>
#   fm-task-inbox.sh run <task> <record> --gen <spawn_gen> [--timeout 300] -- <executable> [args...]
#   fm-task-inbox.sh tick <task> [--report-only]
# run executes once, proves exec/return facts, and bounds its owned process group;
# it durably reserves an attempt before execution and never replays that attempt.
# Identical completed repeats return the recorded exit status without execution;
# pending or uncertain attempts refuse nonzero and require reconciliation.
# A reservation alone is not execution proof and remains an outstanding obligation,
# including when an executable could not start. It cannot be overwritten by a
# different disposition. Actual started proof settles the execution-start obligation.
# It cannot prove the command implements the instruction's meaning.
# Deliberately detached worker sessions remain their lifecycle owner's work.
# fulfilled is an agent attestation with a response artifact, not semantic proof.
# tick reconciles an acknowledged instruction once, then queues one escalation.
# Exit 75 means bounded metadata-lock contention with a live holder; retry a
# later observation cycle. Other failures require inspection.
# No command retries the original instruction. The Python owner defines the ledger.
# Python 3.9+ is required. All mutations hold the existing task metadata lock;
# run releases it after its durable execution-start handoff and reacquires it
# for generation-bound return facts. The Python module is internal, not a bypass.
# Set FM_HOME and FM_STATE_OVERRIDE to the record's owning home and channel,
# including when a secondmate receives instructions in its parent's home.
# Wait conditions are reported by the receiver, not mechanically evaluated;
# waiting also writes an instruction-keyed blocked status for ordinary supervision.
# Unverified or superseded unresolved obligations remain visible and block
# cleanup. This interface provides no cancellation or generation-transfer API;
# the owning supervisor must reconcile that retained work before lifecycle cleanup.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${1:-}" = --help ]; then sed -n '2,/^set -eu/{ /^#/s/^# \{0,1\}//p; }' "$0"; exit 0; fi
: "${FM_HOME:?FM_HOME is required}"
[ "$#" -ge 2 ] || { echo 'error: command and task required; see --help' >&2; exit 2; }
operation=$1 task=$2
shift 2
case "$task" in ''|*[!A-Za-z0-9._-]*|.|..) echo 'error: invalid task' >&2; exit 2 ;; esac
case "$operation" in
  query|tick|remote-tick|disposition|run|guard|finish)
    command -v python3 >/dev/null 2>&1 || { echo 'error: instruction dispositions require Python 3.9+' >&2; exit 1; }
    python3 "$SCRIPT_DIR/fm-task-inbox-obligation.py" validate "${FM_STATE_OVERRIDE:-$FM_HOME/state}" "$task" || exit 1
    ;;
esac
# shellcheck source=/dev/null
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"
case "$operation" in
  _remote)
    # shellcheck source=/dev/null
    . "$SCRIPT_DIR/fm-timeout-lib.sh"
    fm_run_timed 15 "$SCRIPT_DIR/fm-on.sh" "$task" fm-remote-secondmate-control.sh obligation-tick "$task" </dev/null
    exit ;;
  _wait)
    printf 'blocked [key=instruction-%s]: %s; condition: %s\n' "$1" \
      "$(printf '%s' "$2" | tr '\r\n' '  ')" "$(printf '%s' "$3" | tr '\r\n' '  ')" >> "$STATE/$task.status"
    exit ;;
  _wake)
    fm_wake_append stale "$task" "$1"
    exit ;;
  _ring)
    meta="$STATE/$task.meta"
    fm_backend_validate_task_endpoint "$meta" "$task" 2>/dev/null || exit 0
    backend=$FM_BACKEND_VALIDATED_BACKEND
    target=$FM_BACKEND_VALIDATED_TARGET
    case "$(fm_backend_agent_state "$backend" "$target" 2>/dev/null || true)" in dead|missing) exit 0 ;; esac
    [ "$(fm_backend_busy_state "$backend" "$target" 2>/dev/null || true)" != busy ] || exit 0
    fm_task_inbox_ring "$backend" "$target" "$1" "fm-$task" reconcile || true
    exit ;;
  query|tick|remote-tick|disposition|run|guard|finish) ;;
  *) echo 'error: unknown instruction command; see --help' >&2; exit 2 ;;
esac
lock=$(fm_meta_lock_path "$STATE/$task.meta")
lock_status=0
fm_task_inbox_lock_acquire "$lock" || lock_status=$?
if [ "$lock_status" -ne 0 ]; then
  echo 'error: instruction metadata lock unavailable' >&2
  exit "$lock_status"
fi
ready=
trap 'fm_lock_release "$lock"; [ -z "$ready" ] || rm -f "$ready"' EXIT
if [ "$operation" = run ]; then
  ready=$(mktemp "$STATE/.instruction-ready.XXXXXX")
  export FM_INSTRUCTION_READY_FILE=$ready
fi
python3 "$SCRIPT_DIR/fm-task-inbox-obligation.py" "$operation" "$STATE" "$task" "$@" &
engine=$!
trap 'kill -TERM "$engine" 2>/dev/null || true; wait "$engine" 2>/dev/null || true; exit 143' TERM HUP INT
if [ -n "$ready" ]; then
  while kill -0 "$engine" 2>/dev/null && [ ! -s "$ready" ]; do sleep 0.05; done
  if [ -s "$ready" ]; then
    # Start proof is durable. Release metadata while the command runs; finish
    # reacquires it and checks exact generation/receipt identity before writing.
    fm_lock_release "$lock"
  fi
fi
wait "$engine"
