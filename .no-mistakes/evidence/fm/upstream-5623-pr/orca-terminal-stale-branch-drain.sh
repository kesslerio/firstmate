#!/usr/bin/env bash
# S7b: the branch actor acknowledges the claimed terminal-keyed Orca stale row,
# so the durable queue proves the branch consumed it (main never sees it).
set -u
WORKTREE="$1"; LAB="$2"
export FM_HOME="$LAB"
unset NO_MISTAKES_GATE FM_STATE_OVERRIDE FM_ROOT_OVERRIDE FM_CONFIG_OVERRIDE \
  FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE TMUX TMUX_PANE
STATE="$LAB/state"; Q="$STATE/.wake-queue"
rm -f "$Q" "$STATE/.wake-queue.seq" "$STATE/.watcher-down" "$STATE/.branch-eligible-rows" \
  "$STATE/.branch-eligible-owner" "$STATE/.main-eligible-rows"
printf 'working: lab scenario step\n' > "$STATE/orca-task.status"

bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_append signal orca-task.status "signal: orca-task.status"' _ "$WORKTREE"
bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_append stale term-lab-orca-1 "stale: term-lab-orca-1 (idle pane)"' _ "$WORKTREE"

echo "--- unread queue (both rows are Orca-task rows; row 2 is keyed by the Orca terminal handle):"
sed 's/\t/<TAB>/g' "$Q"
echo "--- branch scan:"
node "$WORKTREE/bin/fm-branch-dispatch.mjs" scope

"$WORKTREE/bin/fm-wake-grant.sh" activate $$ labgen
"$WORKTREE/bin/fm-wake-grant.sh" publish labgen 1 2
echo "--- published grant (state/.branch-eligible-rows): $(tr '\n' ' ' < "$STATE/.branch-eligible-rows")"

echo "--- branch-actor drain (what the branch turn sees):"
out=$(FM_SUPERVISION_ACTOR=branch "$WORKTREE/bin/fm-wake-drain.sh" 2>&1)
printf '%s\n' "$out" | sed -n '1,20p'
gen=$(printf '%s\n' "$out" | sed -n 's/.*--recovery-generation \([^ ]*\).*/\1/p' | head -n 1)
echo "--- branch-actor acknowledgement through the presented sequence ($gen):"
FM_SUPERVISION_ACTOR=branch "$WORKTREE/bin/fm-wake-drain.sh" --ack-through 2 --recovery-generation "$gen" 2>&1 | sed -n '1,12p'
echo "--- unread queue after the branch ack:"
if [ -s "$Q" ]; then sed 's/\t/<TAB>/g' "$Q"; else printf '(empty: the branch consumed both Orca rows, including the terminal-keyed stale row)\n'; fi
