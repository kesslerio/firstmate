#!/usr/bin/env bash
# Live scenario G: after a crash leaves an unleased slot's return record behind,
# another holder takes that slot through the real pool (a real `treehouse get`
# records its own owner_pid/owner_started_at). Recovery must read that new
# process owner as proof the slot was transferred and must not restore the
# retired payload or lock into the new occupant's checkout.
set -u
. "$(dirname "$0")/fm-live-common.sh"
. "$W/bin/fm-home-worktree-lock-lib.sh"
. "$W/bin/fm-home-payload-lib.sh"
trap teardown_world EXIT

world
H=$(cd "$BASE/fmroot" && "$REAL_TREEHOUSE" get --lease --lease-holder pre 2>/dev/null)
( cd "$BASE/fmroot" && "$REAL_TREEHOUSE" return --force "$H" >/dev/null 2>&1 )
H2=$(seed_explicit_path mate "$H") || { fail 'explicit-path seed failed'; exit 1; }
GD=$(git -C "$H" rev-parse --absolute-git-dir)
check "the seeded home carries a payload before the crash" present "$H/data/charter.md"
echo '--- saved pool entry before the return ---'
pool_entry "$H"

note "1. drive the return to its staged state, then SIGKILL it"
hang() { printf '%s\n' "$BASHPID" > "$BASE/hang.pid"; while :; do sleep 0.05; done; }
fm_home_payload_return "$H" mate "$LAB" hang 2> "$EVID/scn-g-return.err" &
job=$!
waited=0
while [ ! -s "$BASE/hang.pid" ]; do
  sleep 0.02
  waited=$((waited + 1))
  [ "$waited" -lt 500 ] || { fail 'the return never staged the home payload'; exit 1; }
done
mover=$(cat "$BASE/hang.pid")
kill -KILL "$mover" 2>/dev/null || true
wait "$job" 2>/dev/null
check "the crash stripped the home payload" absent "$H/data"
check "the crash released owned protection" absent "$GD/locked"
check "a recoverable return record survived" present "$LAB"/state/.home-return.*/return-record

note "2. another holder takes the freed slot through the real pool"
mkfifo "$BASE/get.fifo"
( sleep 60 > "$BASE/get.fifo" & )
( cd "$BASE/fmroot" && "$REAL_TREEHOUSE" get < "$BASE/get.fifo" > "$EVID/scn-g-get.log" 2>&1 ) &
getpid=$!
waited=0
owner=
while [ -z "$owner" ]; do
  owner=$(python3 - "$(pool_json)" "$H" <<'PY'
import json, os, sys
state, home = sys.argv[1:]
entries = json.load(open(state))["worktrees"]
match = [e for e in entries if os.path.realpath(e["path"]) == os.path.realpath(home)]
pid = match[0].get("owner_pid") if match else None
print(pid if isinstance(pid, int) and pid > 0 else "")
PY
)
  [ -n "$owner" ] || sleep 0.05
  waited=$((waited + 1))
  [ "$waited" -lt 400 ] || { fail 'the real pool never recorded a new process owner'; exit 1; }
done
note "the real pool recorded a new process owner pid $owner"
echo '--- pool entry after the takeover ---'
pool_entry "$H"
mkdir -p "$H/state"
printf 'new occupant\n' > "$H/state/sentinel.meta"

note "3. recovery must read the takeover as committed"
recover=$(bash -c '
  set -u
  . "$1/bin/fm-home-worktree-lock-lib.sh"
  . "$1/bin/fm-home-payload-lib.sh"
  fm_home_payload_recover "$2" "$3" mate || exit 1
  printf "RETIRED=%s\n" "$FM_HOME_PAYLOAD_RETIRED"
' _ "$W" "$H" "$LAB" 2> "$EVID/scn-g-recover.err")
echo "$recover"
check "recovery reports the return as retired" [ "$recover" = 'RETIRED=1' ]
check "recovery did not restore the retired payload" absent "$H/data"
check "recovery did not restore the retired identity" absent "$H/.fm-secondmate-home"
check "recovery did not lock the new occupant out" absent "$GD/locked"
check "recovery did not restore retired lock ownership" absent "$GD/firstmate-home-lock"
check "the new occupant's own file survives" [ "$(cat "$H/state/sentinel.meta")" = 'new occupant' ]
check "the pool still reports the slot in use by the new holder" \
  bash -c "cd '$BASE/fmroot' && treehouse status 2>/dev/null | grep -E 'in-use.*$(basename "$H")'"
bash -c '
  set -u
  . "$1/bin/fm-home-worktree-lock-lib.sh"
  . "$1/bin/fm-home-payload-lib.sh"
  fm_home_payload_finalize "$2" "$3" mate
' _ "$W" "$H" "$LAB" 2> "$EVID/scn-g-finalize.err" || fail 'finalization of the committed return failed'
check "no staging is left behind" [ -z "$(staging_dirs)" ]

note "4. release the fixture holder"
kill -KILL "$getpid" 2>/dev/null || true
pkill -f "$BASE/get.fifo" 2>/dev/null || true
rm -f "$BASE/get.fifo"

note "result: $FAILS failure(s)"
exit "$FAILS"
