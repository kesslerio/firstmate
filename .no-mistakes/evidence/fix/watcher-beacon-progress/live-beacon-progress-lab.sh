#!/usr/bin/env bash
# Live lab driver: a real arm-launched bin/fm-watch.sh works a sweep that runs
# several times longer than the grace its readers are given; the liveness beacon
# must keep tracking progress so the cycle never reads as a dead supervisor.
set -u
REPO={run-worktree}
ARM="$REPO/bin/fm-watch-arm.sh"
GRACE=4
clean_env=(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
  -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
  -u FM_PROJECTS_OVERRIDE -u FM_POLL -u FM_GUARD_GRACE -u FM_WATCHER_PID)

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || exit 1
OWNER=
cleanup() {
  [ ! -d "$LAB" ] || "${clean_env[@]}" FM_HOME="$LAB" timeout 30 "$ARM" --stop >/dev/null 2>&1
  [ -z "$OWNER" ] || kill -TERM "$OWNER" 2>/dev/null || true
  sleep 0.4
  [ -z "$OWNER" ] || kill -KILL "$OWNER" 2>/dev/null || true
  [ -z "$LAB" ] || rm -rf "$LAB"
}
trap cleanup EXIT

"$REPO/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux"
echo "lab=$LAB grace=${GRACE}s"
# Five 2s checks: one supervision cycle takes ~10s, about 2.5x the grace below.
for n in 1 2 3 4 5; do
  printf '#!/usr/bin/env bash\nsleep 2\nexit 0\n' > "$LAB/state/slow-$n.check.sh"
  chmod 0700 "$LAB/state/slow-$n.check.sh"
  "${clean_env[@]}" FM_HOME="$LAB" "$REPO/bin/fm-check-register.sh" "slow-$n" >/dev/null \
    || { echo "could not register fixture check slow-$n"; exit 1; }
done
echo "registered slow checks: $(ls "$LAB/state" | grep -c 'check.sh$')"

"${clean_env[@]}" FM_HOME="$LAB" FM_GUARD_GRACE="$GRACE" FM_POLL=1 \
  FM_CHECK_INTERVAL=1 FM_CHECK_TIMEOUT=30 FM_HEARTBEAT=999999 \
  "$ARM" > /tmp/live-s5-owner.log 2>&1 &
OWNER=$!
i=0
while [ "$i" -lt 300 ] && ! grep -q '^watcher: started' /tmp/live-s5-owner.log 2>/dev/null; do
  sleep 0.1
  i=$((i + 1))
done
grep -q '^watcher: started' /tmp/live-s5-owner.log || { echo "arm never started"; cat /tmp/live-s5-owner.log; exit 1; }
echo "--- owner arm log:"; cat /tmp/live-s5-owner.log
LOCK_PID=$(cat "$LAB/state/.watch.lock/pid" 2>/dev/null)
echo "--- lock pid=$LOCK_PID"

# Sample the beacon age for 12s while the single cycle is mid-sweep.
max_age=0
i=0
: > /tmp/live-s5-mtimes
echo "--- beacon age samples (seconds, once per 0.2s):"
while [ "$i" -lt 60 ]; do
  m=$(stat -c %Y "$LAB/state/.last-watcher-beat")
  printf '%s\n' "$m" >> /tmp/live-s5-mtimes
  age=$(( $(date +%s) - m ))
  [ "$age" -le "$max_age" ] || max_age=$age
  [ $((i % 10)) -ne 0 ] || printf '%s\n' "$age"
  i=$((i + 1))
  sleep 0.2
done
echo "--- max beacon age over the window: ${max_age}s (grace ${GRACE}s)"
echo "--- distinct beacon touches inside that one 12s cycle: $(sort -u /tmp/live-s5-mtimes | wc -l)"
echo "--- same live cycle still owns the lock: $(cat "$LAB/state/.watch.lock/pid" 2>/dev/null) (started $LOCK_PID)"
if [ "$max_age" -lt "$GRACE" ]; then
  echo "S5 RESULT: a working cycle longer than the grace kept its beacon fresh"
else
  echo "S5 RESULT: FAIL - beacon aged to ${max_age}s past the ${GRACE}s grace while working"
fi
"${clean_env[@]}" FM_HOME="$LAB" timeout 30 "$ARM" --stop > /tmp/live-s5-stop.log 2>&1
echo "--- stop:"; cat /tmp/live-s5-stop.log
kill -TERM "$OWNER" 2>/dev/null || true
wait "$OWNER" 2>/dev/null || true
OWNER=
rm -rf "$LAB"
LAB=
echo DONE
