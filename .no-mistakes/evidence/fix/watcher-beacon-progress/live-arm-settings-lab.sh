#!/usr/bin/env bash
# Live lab driver: drive the real bin/fm-watch-arm.sh / bin/fm-watch.sh against
# throwaway marked lab homes to prove home-settings loading (config/watch.env +
# config/x-mode.env via fm_watch_settings_load) still reaches the arm after the
# unused CONFIG assignment was removed.
#
# Every lab is created with bin/fm-lab-home.sh and removed in this run.
set -u
REPO={run-worktree}
EVID=~/.no-mistakes/evidence/01M77TT015RB584XQG5V31A01V
ARM="$REPO/bin/fm-watch-arm.sh"

clean_env=(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
  -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
  -u FM_PROJECTS_OVERRIDE -u FM_POLL -u FM_GUARD_GRACE -u FM_WATCHER_PID)

say() { printf '\n=== %s\n' "$*"; }

backdate_beacon() {  # <home> <secs>
  touch -d "@$(( $(date +%s) - $2 ))" "$1/state/.last-watcher-beat"
}

beacon_age() {  # <home>
  echo $(( $(date +%s) - $(stat -c %Y "$1/state/.last-watcher-beat") ))
}

wait_started() {  # <log> <seconds>
  local i=0
  while [ "$i" -lt $(( $2 * 10 )) ]; do
    grep -q '^watcher: started' "$1" 2>/dev/null && return 0
    sleep 0.1
    i=$(( i + 1 ))
  done
  return 1
}

new_lab() {
  local lab
  lab=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || exit 1
  "$REPO/bin/fm-lab-home.sh" create "$lab" >/dev/null || exit 1
  mkdir -p "$lab/tmux"
  printf '%s\n' "$lab"
}

OWNER_PID=
LAB=
cleanup() {
  if [ -n "$LAB" ] && [ -d "$LAB" ]; then
    "${clean_env[@]}" FM_HOME="$LAB" timeout 30 "$ARM" --stop >/dev/null 2>&1
  fi
  [ -z "$OWNER_PID" ] || kill -TERM "$OWNER_PID" 2>/dev/null || true
  sleep 0.5
  [ -z "$OWNER_PID" ] || kill -KILL "$OWNER_PID" 2>/dev/null || true
  [ -z "$LAB" ] || rm -rf "$LAB"
}
trap cleanup EXIT

########## Scenario 1: home config/watch.env long poll lets the arm attach
say "S1 start: lab home with config/watch.env FM_POLL=600"
LAB=$(new_lab)
echo "lab=$LAB"
printf 'export FM_POLL=600\n' > "$LAB/config/watch.env"
echo "--- config/watch.env:"; cat "$LAB/config/watch.env"

"${clean_env[@]}" FM_HOME="$LAB" "$ARM" > /tmp/live-s1-owner.log 2>&1 &
OWNER_PID=$!
wait_started /tmp/live-s1-owner.log 20 || { echo "S1 owner never started"; cat /tmp/live-s1-owner.log; exit 1; }
sleep 1
echo "--- owner arm log:"; cat /tmp/live-s1-owner.log
echo "--- lock pid=$(cat "$LAB/state/.watch.lock/pid") heartbeat_age=$(beacon_age "$LAB")s"

backdate_beacon "$LAB" 320
echo "--- backdated state/.last-watcher-beat to age $(beacon_age "$LAB")s (default grace would be 300s)"
say "S1: arm against the live holder with the configured long poll"
"${clean_env[@]}" FM_HOME="$LAB" timeout 10 "$ARM" > /tmp/live-s1-arm.log 2>&1
echo "rc=$? (124 = attached arm still following when the harness timeout fired)"
echo "--- second arm output:"; cat /tmp/live-s1-arm.log
grep -q '^watcher: attached pid=' /tmp/live-s1-arm.log \
  && echo "S1 RESULT: attached to the holder with a >300s beacon under the home-configured poll" \
  || echo "S1 RESULT: NO ATTACH"

########## Scenario 2: adversarial explicit grace in the same home replaces the holder
say "S2 start: same home, config/watch.env now also exports FM_GUARD_GRACE=60"
printf 'export FM_POLL=600\nexport FM_GUARD_GRACE=60\n' > "$LAB/config/watch.env"
cat "$LAB/config/watch.env"
backdate_beacon "$LAB" 320
echo "--- beacon age $(beacon_age "$LAB")s; hard bound with grace 60 is 180s"
"${clean_env[@]}" FM_HOME="$LAB" timeout 30 "$ARM" > /tmp/live-s2-arm.log 2>&1
echo "rc=$?"
echo "--- arm output:"; cat /tmp/live-s2-arm.log
grep -q 'replaced stalled pid' /tmp/live-s2-arm.log \
  && echo "S2 RESULT: explicit configured grace won - arm refused to attach and replaced the stalled holder" \
  || echo "S2 RESULT: unexpected"
"${clean_env[@]}" FM_HOME="$LAB" timeout 30 "$ARM" --stop > /tmp/live-s2-stop.log 2>&1
echo "--- stop:"; cat /tmp/live-s2-stop.log
kill -TERM "$OWNER_PID" 2>/dev/null || true
wait "$OWNER_PID" 2>/dev/null || true
OWNER_PID=
rm -rf "$LAB"
LAB=

########## Scenario 3: control - no home settings, same beacon age, arm refuses
say "S3 start: fresh lab home with NO config/watch.env (defaults only)"
LAB=$(new_lab)
echo "lab=$LAB"; echo "--- config dir contents:"; ls -a "$LAB/config"
# Keep the live watcher asleep past 300s by giving the OWNER a 600s poll on its
# environment only: no settings file exists for any reader to load.
"${clean_env[@]}" FM_HOME="$LAB" FM_POLL=600 "$ARM" > /tmp/live-s3-owner.log 2>&1 &
OWNER_PID=$!
wait_started /tmp/live-s3-owner.log 20 || { echo "S3 owner never started"; cat /tmp/live-s3-owner.log; exit 1; }
sleep 1
echo "--- owner arm log:"; cat /tmp/live-s3-owner.log
backdate_beacon "$LAB" 320
say "S3a: arm WITH FM_POLL=600 in its own environment (positive control for the age)"
"${clean_env[@]}" FM_HOME="$LAB" FM_POLL=600 timeout 10 "$ARM" > /tmp/live-s3a-arm.log 2>&1
echo "rc=$?"; cat /tmp/live-s3a-arm.log
backdate_beacon "$LAB" 320
say "S3b: arm with NO settings file and NO FM_POLL/FM_GUARD_GRACE environment"
echo "--- beacon age $(beacon_age "$LAB")s"
"${clean_env[@]}" FM_HOME="$LAB" FM_WATCHER_STARTUP_LOCK_BOUND=5 timeout 40 "$ARM" > /tmp/live-s3b-arm.log 2>&1
echo "rc=$?"; echo "--- arm output:"; cat /tmp/live-s3b-arm.log
if grep -q '^watcher: attached pid=' /tmp/live-s3b-arm.log; then
  echo "S3 RESULT: WRONG - attached off defaults"
elif grep -q 'heartbeat is stale' /tmp/live-s3b-arm.log; then
  echo "S3 RESULT: refused the same 320s beacon under the 300s default - the settings file is load-bearing"
else
  echo "S3 RESULT: no attach, unexpected detail"
fi
"${clean_env[@]}" FM_HOME="$LAB" timeout 30 "$ARM" --stop > /tmp/live-s3-stop.log 2>&1
echo "--- stop:"; cat /tmp/live-s3-stop.log
kill -TERM "$OWNER_PID" 2>/dev/null || true
wait "$OWNER_PID" 2>/dev/null || true
OWNER_PID=
rm -rf "$LAB"
LAB=
say "DONE"
