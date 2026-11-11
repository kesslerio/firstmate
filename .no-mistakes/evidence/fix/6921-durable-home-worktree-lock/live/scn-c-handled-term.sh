#!/usr/bin/env bash
# Live scenario C: a handled SIGTERM while the return is in flight restores the
# staged payload and the owned protection, so the retirement retries cleanly.
set -u
. "$(dirname "$0")/fm-live-common.sh"
trap teardown_world EXIT

world
tmux_up mate
H=$(seed_live mate) || { fail 'live seed failed'; exit 1; }
write_meta mate "$H"
GD=$(git -C "$H" rev-parse --absolute-git-dir)
make_slow_treehouse 8

note "1. start a forced retirement whose treehouse return is slow enough to signal"
( cd "$W" && env FM_GATE_REFUSE_BYPASS=1 FM_ROOT_OVERRIDE="$FM_ROOT_OVERRIDE" FM_HOME="$LAB" \
    FM_BACKEND=tmux TMUX_TMPDIR="$BASE/tmux" PATH="$BASE/shim:$PATH" \
    bash bin/fm-teardown.sh mate --force ) > "$EVID/scn-c-teardown.out" 2> "$EVID/scn-c-teardown.err" &
wrapper=$!
script_pid=$wrapper   # the sub-shell execs the teardown script itself

staged=
waited=0
while [ -z "$staged" ]; do
  for dir in $(staging_dirs); do
    if present "$dir/data" || present "$dir/.fm-secondmate-home"; then staged=$dir; fi
  done
  [ -n "$staged" ] || sleep 0.02
  waited=$((waited + 1))
  [ "$waited" -lt 500 ] || { fail 'the return never staged the home payload'; exit 1; }
done
note "staged payload observed at $staged"
echo '--- staging content at signal time ---'; ls -A "$staged"
check "the home payload was already staged out while the return is in flight" absent "$H/data"

mover=
waited=0
while [ -z "$mover" ]; do
  mover=$(children_of "$script_pid" | head -1)
  [ -n "$mover" ] || sleep 0.02
  waited=$((waited + 1))
  [ "$waited" -lt 200 ] || { fail 'the return process disappeared before it could be signalled'; exit 1; }
done
note "delivering TERM to the process performing the return (pid $mover)"
kill -TERM "$mover"
for leftover in $(descendants_of "$script_pid"); do kill -KILL "$leftover" 2>/dev/null || true; done
wait "$wrapper"
rc=$?
echo "teardown rc=$rc"
grep -E 'recovering|preserving|error' "$EVID/scn-c-teardown.err" | sed -n 1,4p

note "2. the interrupted retirement must fail honestly and keep the home whole"
check "teardown reports failure" [ "$rc" != 0 ]
check "payload is restored" present "$H/data/charter.md"
check "identity marker is restored" [ "$(cat "$H/.fm-secondmate-home" 2>/dev/null)" = mate ]
check "parent binding is restored" present "$H/.fm-secondmate-parent"
check "owned Git protection is restored" grep -F 'Firstmate durable home mate [' "$GD/locked"
check "owned lock receipt is restored" present "$GD/firstmate-home-lock"
check "no payload staging is left behind" [ -z "$(staging_dirs)" ]
check "the lease is still held by mate" \
  bash -c "cd '$BASE/fmroot' && treehouse status 2>/dev/null | grep -E 'leased.*held by mate'"
check "the parent meta record survives for retry" present "$STATE/mate.meta"

note "3. the retried retirement now completes"
teardown_live mate --force > "$EVID/scn-c-retry.out" 2> "$EVID/scn-c-retry.err"
rc2=$?
echo "retry rc=$rc2"
check "retried teardown exits 0" [ "$rc2" = 0 ]
check "the retried retirement cleared the payload" home_retired_payload "$H"
check "the retried retirement returned the slot" \
  bash -c "cd '$BASE/fmroot' && treehouse status 2>/dev/null | grep -E 'available.*$(basename "$H")'"
check "the retried retirement left no staging" [ -z "$(staging_dirs)" ]

note "result: $FAILS failure(s)"
exit "$FAILS"
