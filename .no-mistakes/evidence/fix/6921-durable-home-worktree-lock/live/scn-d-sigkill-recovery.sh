#!/usr/bin/env bash
# Live scenario D: a SIGKILLed retirement leaves the recoverable return record,
# and the next real teardown entry recovers the home before deciding, then
# finishes the retirement.
set -u
. "$(dirname "$0")/fm-live-common.sh"
trap teardown_world EXIT

world
tmux_up mate
H=$(seed_live mate) || { fail 'live seed failed'; exit 1; }
write_meta mate "$H"
GD=$(git -C "$H" rev-parse --absolute-git-dir)
make_slow_treehouse 8

note "1. start a forced retirement and SIGKILL the whole process tree mid-return"
( cd "$W" && env FM_GATE_REFUSE_BYPASS=1 FM_ROOT_OVERRIDE="$FM_ROOT_OVERRIDE" FM_HOME="$LAB" \
    FM_BACKEND=tmux TMUX_TMPDIR="$BASE/tmux" PATH="$BASE/shim:$PATH" \
    bash bin/fm-teardown.sh mate --force ) > "$EVID/scn-d-teardown.out" 2> "$EVID/scn-d-teardown.err" &
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
for pid in $(descendants_of "$script_pid"); do kill -KILL "$pid" 2>/dev/null || true; done
kill -KILL "$script_pid" 2>/dev/null || true
kill -KILL "$wrapper" 2>/dev/null || true
wait "$wrapper" 2>/dev/null
echo '--- crash state ---'
ls -A "$staged"
check "the crash left the home stripped of its payload" absent "$H/data"
check "the crash left the home stripped of its identity" absent "$H/.fm-secondmate-home"
check "the crash left a recoverable return record" present "$staged/return-record"
check "the record names the retired home" grep -Fxq "home=$H" "$staged/return-record"
check "the record names the mate" grep -Fxq 'id=mate' "$staged/return-record"
check "the lease is still held by mate" \
  bash -c "cd '$BASE/fmroot' && treehouse status 2>/dev/null | grep -E 'leased.*held by mate'"

note "2. the next real teardown entry recovers, then completes the retirement"
teardown_live mate --force > "$EVID/scn-d-retry.out" 2> "$EVID/scn-d-retry.err"
rc=$?
echo "retry rc=$rc"
grep -E 'recovering|preserving|REFUSED|error' "$EVID/scn-d-retry.err" | sed -n 1,4p
check "the next entry exits 0" [ "$rc" = 0 ]
check "the next entry reports that it recovered the interrupted return" \
  grep -q 'recovering the interrupted return' "$EVID/scn-d-retry.err"
check "the recovered home retired cleanly" home_retired_payload "$H"
check "the slot is available again" \
  bash -c "cd '$BASE/fmroot' && treehouse status 2>/dev/null | grep -E 'available.*$(basename "$H")'"
check "the parent meta record was retired" absent "$STATE/mate.meta"
check "no staging is left behind" [ -z "$(staging_dirs)" ]

note "result: $FAILS failure(s)"
exit "$FAILS"
