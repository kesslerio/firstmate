#!/usr/bin/env bash
# Live drive: the primary supervisor's own live session lock holds a pooled seat.
set -u
REPO=${REPO:?set REPO to the checkout under test}
ROOT=$(mktemp -d /tmp/fm-lab.XXXXXX)
cleanup() { rm -rf "$ROOT" 2>/dev/null; }
trap cleanup EXIT
"$REPO/bin/fm-lab-home.sh" create "$ROOT" >/dev/null
printf '{"pools":[{"name":"shared","capacity":1,"models":["pool-model-a"]}],"primary_model":"pool-model-a"}\n' \
  > "$ROOT/config/fleet-seats"

seats() {
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$ROOT" "$REPO/bin/fm-fleet-seats.sh" "$@"
}

sleep 600 >/dev/null 2>&1 &
PRIMARY=$!
printf '%s\n' "$PRIMARY" > "$ROOT/state/.lock"
echo "LAB_ROOT=$ROOT"
echo "primary_model=pool-model-a, pool shared capacity 1"
echo "state/.lock names a live process (${PRIMARY}) - the primary session lock a running first mate writes"
echo
echo '=== scenario G: a live primary session occupies the pooled seat, so a new pooled launch refuses'
seats reserve worker --generation g-worker --harness claude --model pool-model-a --holder-pid "$$" 2>&1
echo "exit=$?"
echo
echo '-- spawn this task via the real fm-spawn.sh'
env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
  FM_BACKEND=tmux FM_HOME="$ROOT" "$REPO/bin/fm-spawn.sh" worker /tmp --mode local-only --yolo off \
  --harness claude --model pool-model-a 2>&1 | grep -v '^●' | tail -4
echo
echo '=== the primary session ends (lock holder exits), and the same launch is admitted'
kill "$PRIMARY" 2>/dev/null
wait "$PRIMARY" 2>/dev/null
seats reserve worker --generation g-worker --harness claude --model pool-model-a --holder-pid "$$" 2>&1
echo "exit=$?"
