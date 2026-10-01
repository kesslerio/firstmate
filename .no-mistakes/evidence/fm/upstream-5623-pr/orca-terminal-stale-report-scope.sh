#!/usr/bin/env bash
# End-user consequence: after the supervision branch claims an Orca stale wake
# keyed by its terminal handle, the branch's own report surface must accept a
# report for THAT Orca task (docs/pi-supervision-branch.md "Report scoping":
# "A stale row resolves through the task record naming that endpoint").
# The turn record below is the exact shape bin/fm-supervision-host.sh writes.
set -u
WORKTREE="$1"; LAB="$2"
export FM_HOME="$LAB"
unset NO_MISTAKES_GATE FM_STATE_OVERRIDE FM_ROOT_OVERRIDE FM_CONFIG_OVERRIDE \
  FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE TMUX TMUX_PANE
STATE="$LAB/state"; Q="$STATE/.wake-queue"
rm -f "$Q" "$STATE/.wake-queue.seq" "$STATE/.watcher-down" "$STATE/.branch-eligible-rows" \
  "$STATE/.branch-eligible-owner" "$STATE/.supervision-host-turn" "$STATE/.supervision-host-receipts"
printf 'working: lab scenario step\n' > "$STATE/orca-task.status"
printf 'working: lab scenario step\n' > "$STATE/window-task.status"

w() { bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_append "$2" "$3" "$4"' _ "$WORKTREE" "$1" "$2" "$3"; }
# The wake queue holds ONLY the Orca row, keyed by the task's Orca terminal handle.
w stale term-lab-orca-1 "stale: term-lab-orca-1 (idle Orca pane)"

echo "--- branch scan of the Orca terminal-keyed wake:"
scope=$(node "$WORKTREE/bin/fm-branch-dispatch.mjs" scope)
printf '%s\n' "$scope"
rows=$(printf '%s\n' "$scope" | sed -n 's/^rows=//p')
tasks=$(printf '%s\n' "$scope" | sed -n 's/^tasks=//p')
echo "--- (window-task is queued on nothing: the branch may report only the task the terminal key resolved to)"
"$WORKTREE/bin/fm-wake-grant.sh" activate $$ host-pid-1.turn-1
# shellcheck disable=SC2086
"$WORKTREE/bin/fm-wake-grant.sh" publish host-pid-1.turn-1 $rows
printf 'turn=%s\nrows=%s\ntasks=%s\nunscoped=%s\nwake=%s\nposture=%s\n' \
  "host-pid-1.turn-1" "$rows" "$tasks" "0" "stale: term-lab-orca-1 (idle Orca pane)" "attended" \
  > "$STATE/.supervision-host-turn"
echo "--- branch report for the Orca task the terminal-keyed row resolved to:"
FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=host-pid-1.turn-1 \
  "$WORKTREE/bin/fm-branch-report.sh" --task orca-task --verdict routine --summary "orca pane idle, nothing to do"
echo "exit=$?"
echo "--- branch report for a task the wake never named (must stay refused):"
FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=host-pid-1.turn-1 \
  "$WORKTREE/bin/fm-branch-report.sh" --task window-task --verdict routine --summary "should be refused"
echo "exit=$?"
echo "--- durable outcome store after the accepted report:"
"$WORKTREE/bin/fm-branch-outcome.sh" list 2>/dev/null | tail -3 || cat "$STATE"/.branch-outcomes* 2>/dev/null | tail -3
