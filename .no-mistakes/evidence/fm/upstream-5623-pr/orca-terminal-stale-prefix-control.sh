#!/usr/bin/env bash
# Negative control: the SAME lab fixture (an Orca task record whose stale wake
# is keyed by its terminal handle) against the PRE-FIX dispatch module
# (base commit 549e07f), to prove the scenario can catch the bug.
set -u
WORKTREE="$1"; LAB="$2"; CTRL="$3"
export FM_HOME="$LAB"
unset NO_MISTAKES_GATE FM_STATE_OVERRIDE FM_ROOT_OVERRIDE FM_CONFIG_OVERRIDE \
  FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE TMUX TMUX_PANE
STATE="$LAB/state"; Q="$STATE/.wake-queue"
rm -f "$Q" "$STATE/.wake-queue.seq" "$STATE/.watcher-down" "$STATE/.branch-eligible-rows" \
  "$STATE/.branch-eligible-owner" "$STATE/.main-eligible-rows"
printf 'working: lab scenario step\n' > "$STATE/orca-task.status"
bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_append stale term-lab-orca-1 "stale: term-lab-orca-1 (idle pane)"; fm_wake_append signal orca-task.status "signal: orca-task.status"' _ "$WORKTREE"
echo "--- unread queue:"; sed 's/\t/<TAB>/g' "$Q"
echo "--- PRE-FIX (base 549e07f) scope: the whole wake was vetoed to main"
node "$CTRL/bin/fm-branch-dispatch.mjs" scope; echo "exit=$?"
echo "--- PRE-FIX offer for the stale:<terminal> close (main, not the branch):"
printf 'stale: term-lab-orca-1 (idle pane)\n' | node "$CTRL/bin/fm-branch-dispatch.mjs" offer; echo "exit=$?"
echo "--- POST-FIX (this change) scope on the identical fixture"
node "$WORKTREE/bin/fm-branch-dispatch.mjs" scope; echo "exit=$?"
echo "--- POST-FIX offer for the same close"
printf 'stale: term-lab-orca-1 (idle pane)\n' | node "$WORKTREE/bin/fm-branch-dispatch.mjs" offer; echo "exit=$?"
