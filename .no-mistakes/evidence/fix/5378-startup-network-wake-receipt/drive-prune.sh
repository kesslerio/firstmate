#!/usr/bin/env bash
# Live drive of bin/fm-startup-network.sh retention (prune mode + real reservation)
# against disposable, isolated homes. Run from the gate worktree:
#   bash drive-prune.sh
set -u
ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../..}
[ -d "$ROOT/bin" ] || { echo "ROOT must be the firstmate checkout" >&2; exit 2; }
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-prune-live.XXXXXX")
trap 'rm -rf "$LAB"' EXIT

FAILED=0
ok() { printf 'PASS %s\n' "$1"; }
no() { printf 'FAIL %s\n' "$1"; FAILED=$((FAILED + 1)); }
check_dir() { [ -d "$1" ] && [ ! -L "$1" ] && ok "present: ${1#"$LAB"/}" || no "missing: ${1#"$LAB"/}"; }
check_gone() { { [ ! -e "$1" ] && [ ! -L "$1" ]; } && ok "removed: ${1#"$LAB"/}" || no "survived: ${1#"$LAB"/}"; }
check_file() { [ -f "$1" ] && [ ! -L "$1" ] && ok "present: ${1#"$LAB"/}" || no "missing: ${1#"$LAB"/}"; }

# seed <home> <generation> [state] [settled-kind]
seed() {
  local home=$1 g=$2 state=${3:-done} kind=${4:-}
  mkdir -p "$home/state/.startup-network-results/$g"
  printf 'state=%s\nphases=probe,sweeps\nlocked=1\nstarted=1700000000\nrc=0\ngeneration=%s\nfinished=1700000100\nreport_published=1\nclaim_deadline=0\n' \
    "$state" "$g" > "$home/state/.startup-network-results/$g/status"
  printf 'ACTIONABLE_%s\n' "$g" > "$home/state/.startup-network-results/$g/report"
  [ -z "$kind" ] || printf '%s:%s\n' "$kind" "$g" > "$home/state/.startup-network-results/$g/settled"
}
prune() { # <home>
  FM_HOME="$1" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-startup-network.sh" prune
}
treeof() { # <home>
  ( cd "$1" && find state -mindepth 1 -maxdepth 3 \( -type d -name '*.*' -o -type f -o -type l \) -printf '%y %p\n' | LC_ALL=C sort )
}

echo '=== scenario 1: prune mode bounds retained results and keeps live obligations ==='
H=$LAB/s1; mkdir -p "$H/state"
printf 'state=running\ngeneration=1500.1.1\n' > "$H/state/.startup-network.status"
seed "$H" 1500.1.1                                     # current shared-status generation
seed "$H" 1400.1.1 done clean                          # settled
seed "$H" 1300.1.1 done inline                         # settled
seed "$H" 1200.1.1                                     # named by a queued wake row
seed "$H" 1100.1.1                                     # newest unsettled 1
seed "$H" 1000.1.1                                     # newest unsettled 2
seed "$H" 900.1.1                                      # newest unsettled 3
seed "$H" 800.1.1                                      # unsettled past the grace window
seed "$H" 700.1.1 done clean                           # settled, carries a receipt
mkdir -p "$H/state/.startup-network-wake-receipts"
printf '700.1.1\n' > "$H/state/.startup-network-wake-receipts/700.1.1"
printf '1500.1.1\n' > "$H/state/.startup-network-wake-receipts/1500.1.1"
printf '1700000000\t1\tcheck\tstartup-network:1200.1.1\tcheck: startup-network: actionable\n' > "$H/state/.wake-queue"
echo '--- before ---'; treeof "$H"
prune "$H"; rc=$?
[ "$rc" -eq 0 ] && ok "prune exited 0" || no "prune exited $rc"
echo '--- after ---'; treeof "$H"
for g in 1500.1.1 1200.1.1 1100.1.1 1000.1.1 900.1.1; do check_dir "$H/state/.startup-network-results/$g"; done
for g in 1400.1.1 1300.1.1 800.1.1 700.1.1; do check_gone "$H/state/.startup-network-results/$g"; done
check_gone "$H/state/.startup-network-wake-receipts/700.1.1"
check_file "$H/state/.startup-network-wake-receipts/1500.1.1"
grep -Fq 'startup-network:1200.1.1' "$H/state/.wake-queue" \
  && ok "queued wake row still present for 1200.1.1" || no "prune consumed the queued wake row"
echo '--- second pass (idempotent) ---'
prune "$H" && ok "second prune exited 0" || no "second prune failed"
for g in 1200.1.1 1100.1.1 1000.1.1 900.1.1; do check_dir "$H/state/.startup-network-results/$g"; done

echo
echo '=== scenario 2: malformed, incomplete, and symlinked entries are declined ==='
H=$LAB/s2; mkdir -p "$H/state"
printf 'state=running\ngeneration=1500.1.1\n' > "$H/state/.startup-network.status"
mkdir -p "$H/state/.startup-network-results/not-a-generation"
mkdir -p "$H/state/.startup-network-results/0600.1.1"          # no report: incomplete
printf 'state=done\ngeneration=0600.1.1\n' > "$H/state/.startup-network-results/0600.1.1/status"
mkdir -p "$H/state/.startup-network-results/0600.2.2"          # status names only the generation
printf 'generation=0600.2.2\n' > "$H/state/.startup-network-results/0600.2.2/status"
printf 'REPORT\n' > "$H/state/.startup-network-results/0600.2.2/report"
mkdir -p "$H/state/.startup-network-results/0600.3.3"          # settled marker but no finished/rc
printf 'state=done\ngeneration=0600.3.3\nreport_published=1\n' > "$H/state/.startup-network-results/0600.3.3/status"
printf 'REPORT\n' > "$H/state/.startup-network-results/0600.3.3/report"
printf 'clean:0600.3.3\n' > "$H/state/.startup-network-results/0600.3.3/settled"
mkdir -p "$LAB/foreign-result"                                 # symlinked completion
printf 'generation=0500.1.1\nstate=done\nfinished=1\nrc=0\nreport_published=1\n' > "$LAB/foreign-result/status"
printf 'FOREIGN\n' > "$LAB/foreign-result/report"
ln -s "$LAB/foreign-result" "$H/state/.startup-network-results/0500.1.1"
echo '--- before ---'; treeof "$H"
prune "$H"; rc=$?
[ "$rc" -eq 0 ] && ok "prune exited 0" || no "prune exited $rc"
echo '--- after ---'; treeof "$H"
for g in not-a-generation 0600.1.1 0600.2.2 0600.3.3; do check_dir "$H/state/.startup-network-results/$g"; done
[ -L "$H/state/.startup-network-results/0500.1.1" ] && ok "symlinked completion left in place" || no "symlinked completion was followed or removed"
[ -f "$LAB/foreign-result/report" ] && ok "symlink target untouched" || no "symlink target was deleted"

echo
echo '=== scenario 3: a symlinked receipt root is declined, never followed ==='
H=$LAB/s3; mkdir -p "$H/state" "$LAB/foreign-receipts"
printf 'state=running\ngeneration=1500.1.1\n' > "$H/state/.startup-network.status"
seed "$H" 0300.1.1 done clean
printf '0300.1.1\n' > "$LAB/foreign-receipts/0300.1.1"
ln -s "$LAB/foreign-receipts" "$H/state/.startup-network-wake-receipts"
echo '--- before ---'; treeof "$H"
prune "$H"; rc=$?
[ "$rc" -eq 0 ] && ok "prune exited 0" || no "prune exited $rc"
echo '--- after ---'; treeof "$H"
[ -f "$LAB/foreign-receipts/0300.1.1" ] && ok "foreign receipt outside the home untouched" || no "prune deleted a file through the symlinked receipt root"
[ -L "$H/state/.startup-network-wake-receipts" ] && ok "symlinked receipt root left in place" || no "prune replaced or removed the symlinked receipt root"

echo
echo '=== scenario 4: an interrupted cleanup stays retryable ==='
H=$LAB/s4; mkdir -p "$H/state/.startup-network-wake-receipts"
printf 'state=running\ngeneration=1500.1.1\n' > "$H/state/.startup-network.status"
seed "$H" 0900.1.1 done clean
printf '0900.1.1\n' > "$H/state/.startup-network-wake-receipts/0900.1.1"
chmod 0555 "$H/state/.startup-network-wake-receipts"
prune "$H"; echo "first prune rc=$?"
check_dir "$H/state/.startup-network-results/0900.1.1"    # left retryable, not an orphan receipt
check_file "$H/state/.startup-network-wake-receipts/0900.1.1"
chmod 0755 "$H/state/.startup-network-wake-receipts"
prune "$H" && ok "retry prune exited 0" || no "retry prune failed"
check_gone "$H/state/.startup-network-results/0900.1.1"
check_gone "$H/state/.startup-network-wake-receipts/0900.1.1"

echo
echo '=== scenario 5: a real session reservation prunes retired generations ==='
H=$LAB/s5; mkdir -p "$H/state"
seed "$H" 1000.1.1 done clean                    # settled, superseded: must go
mkdir -p "$H/state/.startup-network-wake-receipts"
printf '1000.1.1\n' > "$H/state/.startup-network-wake-receipts/1000.1.1"
seed "$H" 0950.1.1                               # oldest unsettled, but its wake row is queued
printf '1700000000\t1\tcheck\tstartup-network:0950.1.1\tcheck: startup-network: actionable\n' > "$H/state/.wake-queue"
echo '--- before ---'; treeof "$H"
FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" FM_STARTUP_NETWORK_TIMEOUT=45 FM_SESSION_START_TIMEOUT=45 \
  "$ROOT/bin/fm-startup-network.sh" start --locked 0 --harvest-pid 999999999
[ $? -eq 0 ] && ok "session start reserved a generation" || no "session start failed"
FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-startup-network.sh" wait 60 >/dev/null 2>&1 \
  && ok "the reserved run completed and published" || no "the reserved run never published"
echo '--- after ---'; treeof "$H"
check_gone "$H/state/.startup-network-results/1000.1.1"
check_gone "$H/state/.startup-network-wake-receipts/1000.1.1"
check_dir "$H/state/.startup-network-results/0950.1.1"
GEN=$(sed -n 's/^generation=//p' "$H/state/.startup-network.status" | tail -1)
echo "reserved generation: ${GEN:-<none>}"
[ -n "$GEN" ] && check_dir "$H/state/.startup-network-results/$GEN" || no "the run left no current generation"
grep -Fq 'startup-network:0950.1.1' "$H/state/.wake-queue" \
  && ok "queued generation survived the real reservation" || no "the real reservation dropped a queued generation"
echo '--- retained completion of the run itself ---'
[ -n "$GEN" ] && { cat "$H/state/.startup-network-results/$GEN/status"; echo '-- report --'; cat "$H/state/.startup-network-results/$GEN/report"; }
echo '--- operator read of the retained completion ---'
[ -n "$GEN" ] && FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-startup-network.sh" report --generation "$GEN" \
  && ok "report --generation read the retained completion" || no "report --generation could not read the retained completion"

echo
echo '=== scenario 6: repeated session starts keep retained state bounded ==='
H=$LAB/s6; mkdir -p "$H/state"
for i in 1 2 3 4 5 6; do
  sleep 1.1
  FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" FM_STARTUP_NETWORK_TIMEOUT=45 FM_SESSION_START_TIMEOUT=45 \
    "$ROOT/bin/fm-startup-network.sh" start --locked 0 --harvest-pid "$((900000 + i))" \
    || no "start $i failed"
  FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-startup-network.sh" wait 60 >/dev/null 2>&1 \
    || no "run $i never published"
  printf 'after start %s: retained result dirs=%s receipts=%s\n' "$i" \
    "$(find "$H/state/.startup-network-results" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)" \
    "$(find "$H/state/.startup-network-wake-receipts" -mindepth 1 -maxdepth 1 -type f 2>/dev/null | wc -l)"
done
echo '--- final state ---'; treeof "$H"
kept=$(find "$H/state/.startup-network-results" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
[ "$kept" -le 4 ] && ok "six starts retained only $kept result dir(s), so growth is bounded" \
  || no "six starts retained $kept result dirs"
ART=$(find "$H/state/.startup-network-results" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)
[ -n "$ART" ] && [ -f "$ART/report" ] && ok "a retained generation is still readable after six starts" \
  || no "no readable retained generation after six starts"

echo
echo '=== scenario 7: the pass runs under the startup publication lock ==='
H=$LAB/s7; mkdir -p "$H/state"
printf 'state=running\ngeneration=1500.1.1\n' > "$H/state/.startup-network.status"
seed "$H" 1500.1.1
seed "$H" 0800.1.1 done clean
FM_STATE_OVERRIDE="$H/state" FM_ROOT_OVERRIDE="$ROOT" bash -c '
  . "$1/fm-wake-lib.sh"
  fm_lock_try_acquire "$2" || exit 1
  exec sleep 120' _ "$ROOT/bin" "$H/state/.startup-network.lock" >/dev/null 2>&1 </dev/null &
holder=$!
waited=0
while [ "$(cat "$H/state/.startup-network.lock/pid" 2>/dev/null || true)" != "$holder" ] && [ "$waited" -lt 50 ]; do
  sleep 0.1; waited=$((waited + 1))
done
[ "$(cat "$H/state/.startup-network.lock/pid" 2>/dev/null || true)" = "$holder" ] \
  && ok "a live process holds the publication lock (pid $holder)" || no "could not hold the publication lock"
FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" FM_SESSION_START_TIMEOUT=3 \
  "$ROOT/bin/fm-startup-network.sh" prune >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "prune refused while a live process held the publication lock (rc=$rc)" \
  || no "prune ran without the publication lock (rc=$rc)"
check_dir "$H/state/.startup-network-results/0800.1.1"
kill "$holder" 2>/dev/null || true
wait "$holder" 2>/dev/null || true
FM_HOME="$H" FM_ROOT_OVERRIDE="$ROOT" FM_SESSION_START_TIMEOUT=5 \
  "$ROOT/bin/fm-startup-network.sh" prune && ok "prune proceeded once the lock was released" \
  || no "prune failed after the lock was released"
check_gone "$H/state/.startup-network-results/0800.1.1"
check_dir "$H/state/.startup-network-results/1500.1.1"

echo
echo '=== scenario 8: a symlinked results root is declined, never followed ==='
H=$LAB/s8; mkdir -p "$H/state" "$LAB/foreign-results"
printf 'state=running\ngeneration=1500.1.1\n' > "$H/state/.startup-network.status"
mkdir -p "$LAB/foreign-results/0200.1.1"
printf 'state=done\nfinished=1\nrc=0\nreport_published=1\ngeneration=0200.1.1\n' > "$LAB/foreign-results/0200.1.1/status"
printf 'FOREIGN\n' > "$LAB/foreign-results/0200.1.1/report"
printf 'clean:0200.1.1\n' > "$LAB/foreign-results/0200.1.1/settled"
ln -s "$LAB/foreign-results" "$H/state/.startup-network-results"
prune "$H"; rc=$?
[ "$rc" -eq 0 ] && ok "prune exited 0 against a symlinked results root" || no "prune exited $rc"
[ -f "$LAB/foreign-results/0200.1.1/report" ] && ok "content outside the home untouched" || no "prune deleted a file through the symlinked results root"
[ -L "$H/state/.startup-network-results" ] && ok "symlinked results root left in place" || no "prune replaced or removed the symlinked results root"

echo
if [ "$FAILED" -eq 0 ]; then echo 'RESULT: all live retention scenarios passed'; else echo "RESULT: $FAILED assertion(s) failed"; fi
exit "$FAILED"
