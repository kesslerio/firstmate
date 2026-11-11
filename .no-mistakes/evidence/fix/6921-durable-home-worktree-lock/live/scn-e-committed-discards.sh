#!/usr/bin/env bash
# Live scenario E: a return killed after the real treehouse slot was released but
# before committed=1 is recorded must never restore the retired payload into the
# now-leasable slot: the next entry reads the released lease as committed, keeps
# the payload out, and finalizes the staging.
set -u
. "$(dirname "$0")/fm-live-common.sh"
. "$W/bin/fm-home-worktree-lock-lib.sh"
. "$W/bin/fm-home-payload-lib.sh"
trap teardown_world EXIT

world
H=$(seed_live mate) || { fail 'live seed failed'; exit 1; }
GD=$(git -C "$H" rev-parse --absolute-git-dir)
# The callback really returns the pool slot, then dies before the mover can
# append the committed record - the crash window the intent names.
release_slot_then_die() {
  ( cd "$FM_ROOT_OVERRIDE" && "$REAL_TREEHOUSE" return --force "$H" >/dev/null ) || return 1
  kill -KILL "$BASHPID"
}
status=0
fm_home_payload_return "$H" mate "$LAB" release_slot_then_die 2> "$EVID/scn-e-return.err" || status=$?
echo "return status=$status (expected 137: killed before the committed record)"
check "the killed return stopped on SIGKILL" [ "$status" = 137 ]
check "the slot was really released by the real pool" \
  bash -c "cd '$BASE/fmroot' && treehouse status 2>/dev/null | grep -E 'available.*$(basename "$H")'"
check "the payload left the home before the crash" absent "$H/data"
check "the identity left the home before the crash" absent "$H/.fm-secondmate-home"
check "a recoverable return record survived" present "$LAB"/state/.home-return.*/return-record

note "1. next entry: recovery must treat the released lease as committed"
recover=$(bash -c '
  set -u
  . "$1/bin/fm-home-worktree-lock-lib.sh"
  . "$1/bin/fm-home-payload-lib.sh"
  fm_home_payload_recover "$2" "$3" mate || exit 1
  printf "RETIRED=%s\n" "$FM_HOME_PAYLOAD_RETIRED"
' _ "$W" "$H" "$LAB" 2> "$EVID/scn-e-recover.err")
echo "$recover"
check "recovery reports the return as retired (not restored)" [ "$recover" = 'RETIRED=1' ]
check "recovery did not restore the payload into the leasable slot" absent "$H/data"
check "recovery did not restore the identity into the leasable slot" absent "$H/.fm-secondmate-home"
check "recovery did not relock the released slot" absent "$GD/locked"
check "recovery did not restore retired lock ownership" absent "$GD/firstmate-home-lock"

note "2. finalization clears the staging and the slot stays leasable"
bash -c '
  set -u
  . "$1/bin/fm-home-worktree-lock-lib.sh"
  . "$1/bin/fm-home-payload-lib.sh"
  fm_home_payload_finalize "$2" "$3" mate
' _ "$W" "$H" "$LAB" 2> "$EVID/scn-e-finalize.err"
rc=$?
check "finalization exits 0" [ "$rc" = 0 ]
check "no staging is left behind" [ -z "$(staging_dirs)" ]
next=$(cd "$BASE/fmroot" && "$REAL_TREEHOUSE" get --lease --lease-holder next 2>/dev/null)
echo "next lease: $next"
check "the next seed can lease the same slot" [ "$next" = "$H" ]

note "result: $FAILS failure(s)"
exit "$FAILS"
