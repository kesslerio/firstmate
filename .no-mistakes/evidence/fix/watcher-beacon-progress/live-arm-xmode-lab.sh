#!/usr/bin/env bash
# Live lab driver: the arm's consolidated settings load must source
# config/x-mode.env second (Relay's authoritative cadence artifact), so a grace
# declared only there still governs the arm's attach-vs-replace decision.
set -u
REPO={run-worktree}
ARM="$REPO/bin/fm-watch-arm.sh"
clean_env=(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
  -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
  -u FM_PROJECTS_OVERRIDE -u FM_POLL -u FM_GUARD_GRACE -u FM_WATCHER_PID)

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || exit 1
OWNER=
cleanup() {
  [ -z "$OWNER" ] || kill -TERM "$OWNER" 2>/dev/null || true
  [ -z "$OWNER" ] || kill -KILL "$OWNER" 2>/dev/null || true
  [ ! -d "$LAB" ] || "${clean_env[@]}" FM_HOME="$LAB" timeout 30 "$ARM" --stop >/dev/null 2>&1
  rm -rf "$LAB"
}
trap cleanup EXIT

"$REPO/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux"
# watch.env owns the (long) poll; the grace lives only in the Relay cadence file.
printf 'export FM_POLL=600\n' > "$LAB/config/watch.env"
printf 'export FM_GUARD_GRACE=60\n' > "$LAB/config/x-mode.env"
echo "lab=$LAB"
echo "--- config/watch.env:"; cat "$LAB/config/watch.env"
echo "--- config/x-mode.env:"; cat "$LAB/config/x-mode.env"

"${clean_env[@]}" FM_HOME="$LAB" "$ARM" > /tmp/live-s4-owner.log 2>&1 &
OWNER=$!
i=0
while [ "$i" -lt 200 ] && ! grep -q '^watcher: started' /tmp/live-s4-owner.log 2>/dev/null; do sleep 0.1; i=$((i+1)); done
sleep 1
echo "--- owner arm log:"; cat /tmp/live-s4-owner.log
touch -d "@$(( $(date +%s) - 320 ))" "$LAB/state/.last-watcher-beat"
echo "--- beacon age $(( $(date +%s) - $(stat -c %Y "$LAB/state/.last-watcher-beat") ))s (x-mode grace 60 => hard bound 180s; watch.env poll 600 => derived default would be 660s)"

"${clean_env[@]}" FM_HOME="$LAB" timeout 40 "$ARM" > /tmp/live-s4-arm.log 2>&1
echo "--- arm rc=$?"
echo "--- arm output:"; cat /tmp/live-s4-arm.log
if grep -q 'replaced stalled pid' /tmp/live-s4-arm.log; then
  echo "S4 RESULT: x-mode.env was sourced second and its grace governed the arm"
elif grep -q '^watcher: attached pid=' /tmp/live-s4-arm.log; then
  echo "S4 RESULT: WRONG - arm ignored x-mode.env and attached"
else
  echo "S4 RESULT: no attach, unexpected detail"
fi
"${clean_env[@]}" FM_HOME="$LAB" timeout 30 "$ARM" --stop > /tmp/live-s4-stop.log 2>&1
echo "--- stop:"; cat /tmp/live-s4-stop.log
kill -TERM "$OWNER" 2>/dev/null || true
wait "$OWNER" 2>/dev/null || true
OWNER=
rm -rf "$LAB"
LAB=
echo DONE
