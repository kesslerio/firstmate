#!/usr/bin/env bash
# Live scenario A: a real treehouse-leased durable home gains an owned Git
# worktree lock; the real bin/fm-teardown.sh retires it, returning a clean,
# re-seedable pool slot.
set -u
. "$(dirname "$0")/fm-live-common.sh"
trap teardown_world EXIT

world
note "fixture: throwaway firstmate root + real treehouse pool at $BASE"
tmux_up mate
H=$(seed_live mate) || { fail 'live seed failed'; exit 1; }
note "seeded durable home: $H"
write_meta mate "$H"
GD=$(git -C "$H" rev-parse --absolute-git-dir)

note "1. the seeded lease carries owned Git worktree protection"
check "pool reports the slot leased by mate" \
  bash -c "cd '$BASE/fmroot' && treehouse status 2>/dev/null | grep -E 'leased.*held by mate'"
check "Git records our lock reason" grep -F "Firstmate durable home mate [" "$GD/locked"
check "owned per-worktree lock receipt exists" present "$GD/firstmate-home-lock"
check "worktree list reports the worktree locked" \
  bash -c "git -C '$BASE/fmroot' worktree list --porcelain | grep -F 'locked Firstmate durable home mate ['"
echo '--- plain git worktree remove ---'
git -C "$BASE/fmroot" worktree remove "$H" 2>&1 | sed -n 1,2p
check "plain git worktree remove refuses the durable home" \
  bash -c "git -C '$BASE/fmroot' worktree remove '$H' >/dev/null 2>&1; [ \$? -ne 0 ]"
check "the refused removal left the home payload intact" present "$H/data/charter.md"

note "2. real teardown retires the home and returns the slot"
teardown_live mate > "$EVID/scn-a-teardown.out" 2> "$EVID/scn-a-teardown.err"
rc=$?
echo "teardown rc=$rc"
sed -n 1,4p "$EVID/scn-a-teardown.out"
check "teardown exits 0" [ "$rc" = 0 ]
check "payload, markers and owned protection are gone" home_retired_payload "$H"
check "no payload staging is left behind" [ -z "$(staging_dirs)" ]
check "the parent meta record was retired" absent "$STATE/mate.meta"
check "treehouse reports the slot available again" \
  bash -c "cd '$BASE/fmroot' && treehouse status 2>/dev/null | grep -E 'available.*$(basename "$H")'"
echo '--- pool entry after return ---'
pool_entry "$H"

note "3. the returned slot is reusable by the next seed"
H2=$(seed_live mate) || fail 're-seed of the returned slot failed'
check "re-seed leased the same pooled slot" [ "$H2" = "$H" ]
check "re-seeded home carries its own payload" present "$H2/data/charter.md"
check "re-seeded home carries fresh owned protection" \
  grep -F 'Firstmate durable home mate [' "$(git -C "$H2" rev-parse --absolute-git-dir)/locked"

note "result: $FAILS failure(s)"
exit "$FAILS"
