#!/usr/bin/env bash
# Live adversarial scenario B: a durable home whose Git worktree lock belongs to
# someone else must refuse retirement even with --force, and keep its payload,
# lease and records.
set -u
. "$(dirname "$0")/fm-live-common.sh"
trap teardown_world EXIT

world
tmux_up mate
H=$(seed_live mate) || { fail 'live seed failed'; exit 1; }
write_meta mate "$H"
GD=$(git -C "$H" rev-parse --absolute-git-dir)

note "1. replace owned protection with a foreign Git worktree lock"
rm -f "$GD/firstmate-home-lock"
git -C "$H" worktree unlock "$H"
git -C "$H" worktree lock --reason 'another tool owns this checkout' "$H"
echo '--- locked ---'; cat "$GD/locked"

note "2. forced retirement must refuse"
teardown_live mate --force > "$EVID/scn-b-teardown.out" 2> "$EVID/scn-b-teardown.err"
rc=$?
echo "teardown rc=$rc"
grep -E 'REFUSED|error' "$EVID/scn-b-teardown.err" | sed -n 1,4p
check "teardown refuses with a nonzero status" [ "$rc" != 0 ]
check "the refusal names the foreign lock" \
  grep -q 'foreign Git worktree lock' "$EVID/scn-b-teardown.err"
check "the home keeps its payload" present "$H/data/charter.md"
check "the home keeps its identity marker" [ "$(cat "$H/.fm-secondmate-home")" = mate ]
check "the home keeps its parent binding" present "$H/.fm-secondmate-parent"
check "the foreign lock is untouched" grep -Fxq 'another tool owns this checkout' "$GD/locked"
check "the lease is still held by mate" \
  bash -c "cd '$BASE/fmroot' && treehouse status 2>/dev/null | grep -E 'leased.*held by mate'"
check "the parent meta record survives for retry" present "$STATE/mate.meta"
check "no payload staging was created" [ -z "$(staging_dirs)" ]

note "3. normalise the foreign lock so the fixture is torn down cleanly"
git -C "$H" worktree unlock "$H" 2>/dev/null || true

note "result: $FAILS failure(s)"
exit "$FAILS"
