#!/usr/bin/env bash
# Live driver for the Orca terminal-keyed stale-wake change.
#
# Every product surface here is a real firstmate entrypoint run against one
# disposable lab FM_HOME (bin/fm-lab-home.sh create):
#   bin/fm-wake-lib.sh fm_wake_append  - the product's durable wake writer
#                                        (the same call bin/fm-watch.sh makes
#                                        with $w = fm_backend_target_of_meta,
#                                        i.e. the Orca terminal handle)
#   bin/fm-branch-dispatch.mjs scope|offer - the product's supervision-branch
#                                        dispatch entry (docs/pi-supervision-branch.md)
#   bin/fm-wake-grant.sh + bin/fm-wake-drain.sh - the consume side
set -u
WORKTREE="$1"; LAB="$2"
export FM_HOME="$LAB"
unset NO_MISTAKES_GATE FM_STATE_OVERRIDE FM_ROOT_OVERRIDE FM_CONFIG_OVERRIDE \
  FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE TMUX TMUX_PANE
STATE="$LAB/state"
Q="$STATE/.wake-queue"

w() {  # <kind> <key> <payload>  (product wake writer)
  bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_append "$2" "$3" "$4"' _ \
    "$WORKTREE" "$1" "$2" "$3"
}
run_scope() { node "$WORKTREE/bin/fm-branch-dispatch.mjs" scope "$@"; }
run_offer() { node "$WORKTREE/bin/fm-branch-dispatch.mjs" offer "$@"; }
dump_q() { sed 's/\t/<TAB>/g' "$Q" 2>/dev/null || printf '(no queue)\n'; }
reset_queue() {
  rm -f "$Q" "$STATE/.wake-queue.seq" "$STATE/.watcher-down" \
    "$STATE/.branch-eligible-rows" "$STATE/.branch-eligible-owner" \
    "$STATE/.main-eligible-rows" "$STATE/.watcher-downtime-token"
  printf 'working: lab scenario step\n' > "$STATE/orca-task.status"
  printf 'working: lab scenario step\n' > "$STATE/window-task.status"
}

echo "### lab home: $LAB"
echo "### Orca task record (state/orca-task.meta), as bin/fm-spawn.sh writes one for backend=orca:"
cat "$STATE/orca-task.meta"
echo
echo "===================================================================="
echo "### S1 routine scan: a terminal-keyed Orca stale row queued with a routine row"
reset_queue
w stale term-lab-orca-1 "stale: term-lab-orca-1 (idle pane; the Orca terminal handle names this row)"
w signal orca-task.status "signal: orca-task.status"
echo "--- wake queue as the product's own writer serialized it:"
dump_q
echo "--- bin/fm-branch-dispatch.mjs scope"
run_scope; echo "exit=$?"

echo
echo "===================================================================="
echo "### S2 supervision-host offer for the stale:<terminal> close (the branch/main decision)"
printf 'stale: term-lab-orca-1 (idle pane)\n' | run_offer; echo "exit=$?"

echo
echo "===================================================================="
echo "### S3 heartbeat scan over the same two rows"
reset_queue
w heartbeat heartbeat heartbeat
w stale term-lab-orca-1 "stale: term-lab-orca-1 (idle pane)"
run_scope --heartbeat; echo "exit=$?"

echo
echo "===================================================================="
echo "### S4 adversarial: stale row keyed by a terminal no task record names"
reset_queue
w stale term-nobody "stale: term-nobody (unknown endpoint)"
w signal orca-task.status "signal: orca-task.status"
run_scope; echo "exit=$?"
printf 'stale: term-nobody (unknown endpoint)\n' | run_offer; echo "exit=$?"

echo
echo "===================================================================="
echo "### S5 adversarial: the Orca task has an OPEN needs-decision"
reset_queue
printf 'working: lab scenario step\nneeds-decision [key=ship-or-revert]: ship or revert?\n' > "$STATE/orca-task.status"
w stale term-lab-orca-1 "stale: term-lab-orca-1 (idle pane)"
w signal window-task.status "signal: window-task.status"
echo "--- attended scan:"; run_scope; echo "exit=$?"
echo "--- attended offer for that stale close:"
printf 'stale: term-lab-orca-1 (idle pane)\n' | run_offer; echo "exit=$?"
echo "--- away-posture scan (--afk):"; run_scope --afk; echo "exit=$?"

echo
echo "===================================================================="
echo "### S6 regression: a window-keyed (tmux) stale row still resolves next to the Orca row"
reset_queue
w stale fm-window-task "stale: fm-window-task"
w stale term-lab-orca-1 "stale: term-lab-orca-1 (idle pane)"
run_scope; echo "exit=$?"

echo
echo "===================================================================="
echo "### S7 the branch actor actually drains the terminal-keyed row"
reset_queue
w signal orca-task.status "signal: orca-task.status"
w stale term-lab-orca-1 "stale: term-lab-orca-1 (idle pane)"
echo "--- scan the branch claims from:"; run_scope
FM_HOME="$LAB" "$WORKTREE/bin/fm-wake-grant.sh" activate $$ labgen
FM_HOME="$LAB" "$WORKTREE/bin/fm-wake-grant.sh" publish labgen 1 2; echo "publish exit=$?"
echo "--- state/.branch-eligible-rows:"; cat "$STATE/.branch-eligible-rows"
echo "--- queue before the branch drain:"; dump_q
echo "--- branch-actor drain:"
FM_SUPERVISION_ACTOR=branch "$WORKTREE/bin/fm-wake-drain.sh" 2>&1 | sed -n '1,30p'
echo "--- queue after the branch drain:"; dump_q
