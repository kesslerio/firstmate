#!/usr/bin/env bash
# Live scenario F: an explicit-path seed uses an existing pool checkout without a
# lease. An unchanged unleased entry is no evidence that this attempt returned
# the slot, so a failed return must put the whole home back; only the successful
# return clears the payload.
set -u
. "$(dirname "$0")/fm-live-common.sh"
. "$W/bin/fm-home-worktree-lock-lib.sh"
. "$W/bin/fm-home-payload-lib.sh"
trap teardown_world EXIT

world
H=$(cd "$BASE/fmroot" && "$REAL_TREEHOUSE" get --lease --lease-holder pre 2>/dev/null)
( cd "$BASE/fmroot" && "$REAL_TREEHOUSE" return --force "$H" >/dev/null 2>&1 )
note "unleased pool checkout: $H"
echo '--- pool entry before the explicit-path seed ---'
pool_entry "$H"
H2=$(seed_explicit_path mate "$H") || { fail 'explicit-path seed failed'; exit 1; }
GD=$(git -C "$H" rev-parse --absolute-git-dir)
check "the explicit-path seed landed in the pool checkout" [ "$H2" = "$H" ]
check "the seeded home carries its payload" present "$H/data/charter.md"
check "the seeded home carries owned protection" present "$GD/firstmate-home-lock"
check "its pool entry is still unleased" \
  bash -c "cd '$BASE/fmroot' && treehouse status 2>/dev/null | grep -E 'available.*$(basename "$H")'"

note "1. a failed return of the unleased slot must not be read as a returned slot"
status=0
fm_home_payload_return "$H" mate "$LAB" false 2> "$EVID/scn-f-failed.err" || status=$?
echo "failed return status=$status"
check "the failed return reports failure" [ "$status" != 0 ]
check "the failed return put the payload back" present "$H/data/charter.md"
check "the failed return put the identity back" [ "$(cat "$H/.fm-secondmate-home" 2>/dev/null)" = mate ]
check "the failed return restored owned protection" present "$GD/locked"
check "the failed return restored owned lock ownership" present "$GD/firstmate-home-lock"
check "the failed return left no staging" [ -z "$(staging_dirs)" ]

note "2. the successful return of that same unleased slot clears the payload"
status=0
fm_home_payload_return "$H" mate "$LAB" true 2> "$EVID/scn-f-success.err" || status=$?
echo "successful return status=$status"
check "the successful return reports success" [ "$status" = 0 ]
check "the payload is cleared" absent "$H/data"
check "the identity is cleared" absent "$H/.fm-secondmate-home"
check "owned protection is released" absent "$GD/locked"
check "owned lock ownership is forgotten" absent "$GD/firstmate-home-lock"
check "the slot is still an available pool checkout" \
  bash -c "cd '$BASE/fmroot' && treehouse status 2>/dev/null | grep -E 'available.*$(basename "$H")'"
bash -c '
  set -u
  . "$1/bin/fm-home-worktree-lock-lib.sh"
  . "$1/bin/fm-home-payload-lib.sh"
  fm_home_payload_recover "$2" "$3" mate
  [ "$FM_HOME_PAYLOAD_RETIRED" = 1 ] || exit 1
  fm_home_payload_finalize "$2" "$3" mate
' _ "$W" "$H" "$LAB" 2> "$EVID/scn-f-finalize.err" || fail 'finalization of the committed return failed'
check "no staging is left behind" [ -z "$(staging_dirs)" ]

note "result: $FAILS failure(s)"
exit "$FAILS"
