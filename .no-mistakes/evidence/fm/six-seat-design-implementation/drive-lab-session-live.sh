#!/usr/bin/env bash
# Live drive: a remote secondmate endpoint recorded under an isolated fm-lab-*
# Herdr session resolves, refuses without its recorded session, and retires on
# that same session - against a real Herdr lab session provisioned through
# bin/fm-herdr-lab.sh (never the default session).
set -u
REPO=${1:?repo}
cd "$REPO" || exit 1
LAB_HELPER=$REPO/bin/fm-herdr-lab.sh
CONTROL=$REPO/bin/fm-remote-secondmate-control.sh
say() { printf '\n### %s\n' "$*"; }

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || exit 1
"$REPO/bin/fm-lab-home.sh" create "$LAB/main" >/dev/null || exit 1
REMOTE=$LAB/remote
"$REPO/bin/fm-lab-home.sh" create "$REMOTE" >/dev/null || exit 1
mkdir -p "$REMOTE/state/parent-route" "$REMOTE/bin"
printf 'lab\n' > "$REMOTE/.fm-secondmate-home"
printf 'Synthetic remote secondmate home.\n' > "$REMOTE/AGENTS.md"

SESSION=$("$LAB_HELPER" name retirelive) || exit 1
cleanup() { "$LAB_HELPER" teardown "$SESSION" >/dev/null 2>&1 || true; rm -rf "$LAB"; }
trap cleanup EXIT
say "LAB=$LAB  lab session=$SESSION"
"$LAB_HELPER" provision "$SESSION" || { echo "provision failed"; exit 1; }
echo "lab session provisioned (isolated, non-default):"
"$LAB_HELPER" run "$SESSION" session list --json 2>/dev/null | jq -c --arg n "$SESSION" '.sessions[] | select(.name == $n) | {name, default, running}'

say "Create a real workspace/tab/pane in the lab session to act as the endpoint"
CREATE=$("$LAB_HELPER" run "$SESSION" workspace create --cwd "$REMOTE" --label fm-lab-retire --no-focus 2>&1)
printf '%s\n' "$CREATE" | head -c 400; echo
WS=$(printf '%s' "$CREATE" | jq -r '.result.workspace.workspace_id // empty')
PANE=$(printf '%s' "$CREATE" | jq -r '.result.root_pane.pane_id // empty')
TAB=$(printf '%s' "$CREATE" | jq -r '.result.tab.tab_id // .result.root_tab.tab_id // empty')
echo "workspace=$WS pane=$PANE tab=$TAB"
[ -n "$WS" ] && [ -n "$PANE" ] || { echo "could not create a lab endpoint"; exit 1; }

META=$REMOTE/state/parent-route/lab.meta
{
  printf 'window=%s:%s\n' "$SESSION" "$PANE"
  printf 'backend=herdr\nendpoint_task_id=lab\n'
  printf 'herdr_session=%s\nherdr_workspace_id=%s\nherdr_tab_id=%s\nherdr_pane_id=%s\n' "$SESSION" "$WS" "$TAB" "$PANE"
  printf 'worktree=%s\nproject=%s\nhome=%s\n' "$REMOTE" "$REMOTE" "$REMOTE"
  printf 'harness=claude\nkind=secondmate\nmode=secondmate\nspawn_gen=lab.g1\n'
} > "$META"
say "Recorded endpoint under the lab session:"; cat "$META"

# The retirement leg mutates fleet state, so it needs the documented
# test-harness escape hatch: the lab-home allowance cannot cover the control
# plane's own FM_STATE_OVERRIDE (the endpoint's parent-route state).
control() { env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE \
  FM_HOME="$REMOTE" FM_ROOT_OVERRIDE="$LAB/main" "$CONTROL" "$@" 2>&1; }
control_retire() { env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE \
  FM_GATE_REFUSE_BYPASS=1 FM_HOME="$REMOTE" FM_ROOT_OVERRIDE="$LAB/main" "$CONTROL" "$@" 2>&1; }

say "Scenario A: the recorded lab session resolves the route"
out=$(control route lab --herdr-session "$SESSION"); rc=$?
printf '%s\nexit=%s   <- expected 0 with target=%s:%s\n' "$out" "$rc" "$SESSION" "$PANE"

say "Scenario B (adversarial): without its recorded session the same endpoint is refused before any Herdr effect"
out=$(control route lab); rc=$?
printf '%s\nexit=%s   <- expected 1\n' "$out" "$rc"
out=$(control retire lab --expect-generation lab.g1); rc=$?
printf '%s\nexit=%s   <- expected 1, records untouched\n' "$out" "$rc"
[ -f "$META" ] && echo "endpoint record still present: yes" || echo "endpoint record still present: NO (unexpected)"

say "Scenario C: retirement on the recorded lab session closes the real pane and publishes evidence"
out=$(control_retire retire lab --expect-generation lab.g1 --herdr-session "$SESSION"); rc=$?
printf '%s\nexit=%s   <- expected 0\n' "$out" "$rc"
echo "endpoint record after retirement:"; ls "$REMOTE/state/parent-route" 2>/dev/null || true
echo "retirement evidence:"
ls "$LAB/main/state/remote-secondmate-history" 2>/dev/null
echo "published proof:"
cat "$LAB/main/state/remote-secondmate-history/lab.retirement.lab.g1.json" 2>/dev/null || echo "(no proof file)"
"$LAB_HELPER" run "$SESSION" workspace list --json 2>/dev/null | jq -c '[.result.workspaces[]?.workspace_id]'
say "Live drive done; tearing down the lab session"
