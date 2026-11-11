#!/usr/bin/env bash
# Live validation driver for fix/6921-durable-home-worktree-lock (recovery round).
# Drives the real product scripts (bin/fm-home-seed.sh, bin/fm-teardown.sh) from a
# disposable clone of the reviewed commit, against a REAL local treehouse pool
# (HOME-isolated state, repo-local treehouse.toml), real git, and a private tmux
# socket. Fault injection is limited to a `treehouse` shim (hung return, return
# that commits then kills its caller); the product code under test is unchanged.
# Nothing outside $LAB is touched.
set -u

WT={run-worktree}
REAL_TREEHOUSE=$(command -v treehouse)
LAB=$(mktemp -d /tmp/fm-lab.XXXXXX)
FAILS=0
PGIDS=()
cleanup() {
  for g in ${PGIDS[@]+"${PGIDS[@]}"}; do kill -KILL -- "-$g" 2>/dev/null || true; done
  TMUX_TMPDIR="$LAB/tmux" tmux kill-server 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

check() { if [ "$1" = ok ]; then printf 'PASS  %s\n' "$2"; else printf 'FAIL  %s\n' "$2"; FAILS=$((FAILS + 1)); fi; }
expect_absent() { if [ -e "$1" ]; then check fail "$2 (still present: $1)"; else check ok "$2"; fi; }
expect_present() { if [ -e "$1" ]; then check ok "$2"; else check fail "$2 (missing: $1)"; fi; }
expect_owned_lock() { # <locked-file> <id> <description>
  local reason
  reason=$(cat "$1" 2>/dev/null || true)
  case "$reason" in
    "Firstmate durable home $2 ["*']') check ok "$3 (reason: $reason)" ;;
    *) check fail "$3 (reason was: '$reason')" ;;
  esac
}
LAB_ENV=(env -u NO_MISTAKES_GATE -u TMUX -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE
  -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_GATE_REFUSE_BYPASS
  HOME="$LAB/home" FM_HOME="$LAB/parent" FM_ROOT_OVERRIDE="$LAB/code" TMUX_TMPDIR="$LAB/tmux")
run() { "${LAB_ENV[@]}" "$@"; }
# Spawn a command in its own session (so its whole tree can be SIGKILLed by pgid).
spawn_detached() { # <log> <cmd...> -> pid of the session leader
  local log=$1; shift
  LAB_LOG=$log LAB_CD=$CD python3 - "$@" <<'PY'
import os, subprocess, sys
with open(os.environ["LAB_LOG"], "ab") as out:
    p = subprocess.Popen(sys.argv[1:], cwd=os.environ["LAB_CD"], stdin=subprocess.DEVNULL,
                         stdout=out, stderr=subprocess.STDOUT, preexec_fn=os.setsid)
print(p.pid)
PY
}
wait_group_gone() { # <pgid> [tries]
  local pgid=$1 tries=${2:-100} i
  for ((i = 0; i < tries; i++)); do
    kill -0 -- "-$pgid" 2>/dev/null || return 0
    sleep 0.1
  done
  return 1
}
staging_dirs() { ls -d "$LAB/parent/state"/.home-return.* 2>/dev/null || true; }
wait_for_staging_record() { # <marker-line> -> echoes staging dir
  local want=$1 i staging
  for ((i = 0; i < 200; i++)); do
    for staging in $(staging_dirs); do
      [ -f "$staging/return-record" ] || continue
      grep -Fxq "$want" "$staging/return-record" || continue
      printf '%s\n' "$staging"
      return 0
    done
    sleep 0.1
  done
  return 1
}

printf '### lab %s (code HEAD %s)\n' "$LAB" "$(git -C "$WT" rev-parse HEAD)"
mkdir -p "$LAB/home" "$LAB/parent/state" "$LAB/parent/data" "$LAB/parent/config" "$LAB/parent/projects" "$LAB/tmux"
git clone --quiet --no-checkout "$WT" "$LAB/code"
git -C "$LAB/code" checkout --quiet "$(git -C "$WT" rev-parse HEAD)"
git -C "$LAB/code" checkout -B main --quiet
printf 'max_trees = 2\nroot = "%s/pool"\n' "$LAB" > "$LAB/code/treehouse.toml"
CD=$LAB/code
meta() { # <id> <home>
  cat > "$LAB/parent/state/$1.meta" <<EOF
window=firstmate:fm-$1
endpoint_task_id=$1
worktree=$2
project=$2
harness=echo
kind=secondmate
mode=secondmate
yolo=off
home=$2
projects=
EOF
}
pool_status() { ( cd "$CD" && HOME="$LAB/home" treehouse status 2>/dev/null | grep -v '^$' | tail -3 ); }
seed() { # <id> -> echoes home=
  ( cd "$CD" && run FM_SECONDMATE_CHARTER="live domain $1" FM_SECONDMATE_SCOPE="live domain $1" \
    bin/fm-home-seed.sh "$1" - --no-projects 2>&1 )
}

##############################################################################
echo
echo "=== SCENARIO 1: a seeded durable home is Git-locked and ordinary removal refuses"
seed_out=$(seed mate1); printf '%s\n' "$seed_out"
H1=$(printf '%s\n' "$seed_out" | sed -n 's/^home=//p' | tail -1)
GD1=$(git -C "$H1" rev-parse --absolute-git-dir)
echo "-- identity marker: $(cat "$H1/.fm-secondmate-home" 2>/dev/null)"
echo "-- git worktree lock: $(cat "$GD1/locked" 2>/dev/null)"
[ "$(cat "$H1/.fm-secondmate-home" 2>/dev/null)" = mate1 ] && check ok "seed published mate1 identity" || check fail "seed did not publish mate1 identity"
expect_owned_lock "$GD1/locked" mate1 "seeded home carries the durable-home Git lock"
rm_out=$(git -C "$CD" worktree remove "$H1" 2>&1); rm_rc=$?
printf '%s\n' "$rm_out" | sed 's/^/   /'
[ "$rm_rc" -ne 0 ] && check ok "ordinary 'git worktree remove' of the idle home is refused" || check fail "ordinary git worktree remove deleted an idle durable home"
expect_present "$H1/.fm-secondmate-home" "the refused removal left the home in place"
meta mate1 "$H1"

##############################################################################
echo
echo "=== SCENARIO 2: retirement releases the lock and hands back a reusable pool slot"
echo "-- pool before: $(pool_status)"
tear_out=$( cd "$CD" && run bin/fm-teardown.sh mate1 2>&1 ); tear_rc=$?
printf '%s\n' "$tear_out" | tail -5 | sed 's/^/   /'
[ "$tear_rc" -eq 0 ] && check ok "teardown of the durable home succeeded" || check fail "teardown of the durable home failed (rc=$tear_rc)"
expect_absent "$GD1/locked" "retirement released the Git worktree lock"
expect_absent "$GD1/firstmate-home-lock" "retirement removed the ownership receipt"
for p in data state config projects .fm-secondmate-home .fm-secondmate-parent; do
  expect_absent "$H1/$p" "returned slot carries no retired payload: $p"
done
expect_present "$H1/AGENTS.md" "returned slot keeps its checkout contents"
expect_absent "$LAB/parent/state/mate1.meta" "retirement removed the retired mate's task record"
echo "-- pool after return: $(pool_status)"
seed2_out=$(seed mate2); printf '%s\n' "$seed2_out" | tail -4 | sed 's/^/   /'
H2=$(printf '%s\n' "$seed2_out" | sed -n 's/^home=//p' | tail -1)
GD2=$(git -C "$H2" rev-parse --absolute-git-dir)
[ "$H2" = "$H1" ] && check ok "the next seed leased the very slot the retired mate returned" || check fail "next seed leased a different slot ($H2)"
[ "$(cat "$H2/.fm-secondmate-home" 2>/dev/null)" = mate2 ] && check ok "the re-leased slot carries the new mate's identity, not the retired one" || check fail "re-leased slot kept the retired identity"
expect_owned_lock "$GD2/locked" mate2 "the re-leased slot carries the new mate's owned lock"
expect_present "$H2/data/charter.md" "the re-leased home was seeded with its own payload"
meta mate2 "$H2"

##############################################################################
echo
echo "=== SCENARIO 3 (adversarial): foreign or unprovable lock ownership refuses retirement"
git -C "$H2" worktree unlock "$H2" >/dev/null 2>&1 || true
git -C "$H2" worktree lock --reason 'foreign owner' "$H2"
echo "-- foreign lock installed: $(cat "$GD2/locked")"
force_out=$( cd "$CD" && run bin/fm-teardown.sh mate2 --force 2>&1 ); force_rc=$?
printf '%s\n' "$force_out" | tail -3 | sed 's/^/   /'
[ "$force_rc" -ne 0 ] && check ok "forced retirement refused a foreign-owned durable home" || check fail "--force retired a foreign-locked home"
[ "$(cat "$GD2/locked" 2>/dev/null)" = 'foreign owner' ] && check ok "the refusal left the foreign lock byte-identical" || check fail "the refusal changed the foreign lock"
expect_present "$LAB/parent/state/mate2.meta" "the refusal preserved the mate's route for retry"
expect_present "$H2/.fm-secondmate-home" "the refusal preserved the home"
cp "$GD2/firstmate-home-lock" "$LAB/receipt2"
git -C "$H2" worktree unlock "$H2" >/dev/null 2>&1 || true
printf '%s\n' "$(sed -n '5p' "$LAB/receipt2" | sed 's/^reason=//')" > "$GD2/locked"
rm -f "$GD2/firstmate-home-lock"
noowner_out=$( cd "$CD" && run bin/fm-teardown.sh mate2 2>&1 ); noowner_rc=$?
printf '%s\n' "$noowner_out" | tail -3 | sed 's/^/   /'
[ "$noowner_rc" -ne 0 ] && check ok "retirement refused a familiar lock reason with no ownership receipt" || check fail "retirement trusted a reason with no receipt"
expect_present "$LAB/parent/state/mate2.meta" "the unknown-owner refusal preserved the route"
cp "$LAB/receipt2" "$GD2/firstmate-home-lock"
owned_out=$( cd "$CD" && run bin/fm-teardown.sh mate2 2>&1 ); owned_rc=$?
printf '%s\n' "$owned_out" | tail -3 | sed 's/^/   /'
[ "$owned_rc" -eq 0 ] && check ok "retirement succeeded once owned protection was restored" || check fail "retirement failed with owned protection restored (rc=$owned_rc)"
expect_absent "$GD2/locked" "the successful retry released the lock"
expect_absent "$H2/data" "the successful retry cleared the retired payload"

##############################################################################
echo
echo "=== SCENARIO 4: a failed pool return preserves the home, lock, and lease for retry"
seed3_out=$(seed mate3); printf '%s\n' "$seed3_out" | tail -3 | sed 's/^/   /'
H3=$(printf '%s\n' "$seed3_out" | sed -n 's/^home=//p' | tail -1)
GD3=$(git -C "$H3" rev-parse --absolute-git-dir)
meta mate3 "$H3"
mkdir -p "$LAB/shim-fail"
printf '#!/usr/bin/env bash\nif [ "${1:-}" = return ]; then echo "synthetic treehouse return failure" >&2; exit 17; fi\nexec %s "$@"\n' "$REAL_TREEHOUSE" > "$LAB/shim-fail/treehouse"
chmod +x "$LAB/shim-fail/treehouse"
fail_out=$( cd "$CD" && PATH="$LAB/shim-fail:$PATH" run bin/fm-teardown.sh mate3 2>&1 ); fail_rc=$?
printf '%s\n' "$fail_out" | tail -4 | sed 's/^/   /'
[ "$fail_rc" -ne 0 ] && check ok "teardown reported the failed pool return to the operator" || check fail "teardown hid the failed pool return"
expect_owned_lock "$GD3/locked" mate3 "the failed return restored the exact owned lock"
expect_present "$GD3/firstmate-home-lock" "the failed return restored the ownership receipt"
expect_present "$H3/.fm-secondmate-home" "the failed return kept the home identity"
expect_present "$H3/data/charter.md" "the failed return kept the retryable home payload"
expect_present "$LAB/parent/state/mate3.meta" "the failed return kept the route for retry"
held=$(pool_status); echo "-- pool after failed return: $held"
case "$held" in *leased*mate3*) check ok "the failed return left the slot leased to mate3 in the real pool" ;; *) check fail "the failed return lost the real pool lease ($held)" ;; esac
retry_out=$( cd "$CD" && run bin/fm-teardown.sh mate3 2>&1 ); retry_rc=$?
printf '%s\n' "$retry_out" | tail -3 | sed 's/^/   /'
[ "$retry_rc" -eq 0 ] && check ok "retrying the same retirement succeeded" || check fail "retry of the retirement failed (rc=$retry_rc)"
expect_absent "$H3/data" "the successful retry returned a clean slot"
expect_absent "$GD3/locked" "the successful retry released the lock"

##############################################################################
echo
echo "=== SCENARIO 5: a failed seed releases attempt-owned protection and returns its acquired slot"
fail_seed_out=$( cd "$CD" && run FM_SECONDMATE_CHARTER='' FM_SECONDMATE_SCOPE='' \
  bin/fm-home-seed.sh mate4 - --no-projects 2>&1 ); fs_rc=$?
printf '%s\n' "$fail_seed_out" | tail -5 | sed 's/^/   /'
H4=$(printf '%s\n' "$fail_seed_out" | sed -n 's/.*Leased worktree at \([^ ]*\)\..*/\1/p' | tail -1)
[ "$fs_rc" -ne 0 ] && check ok "the seed failed as expected on the missing charter" || check fail "seed unexpectedly succeeded without a charter"
echo "-- acquired slot $H4"
GD4=$(git -C "$H4" rev-parse --absolute-git-dir 2>/dev/null || true)
[ -n "$GD4" ] && expect_absent "$GD4/locked" "the failed seed left no attempt-owned Git lock" || check fail "acquired slot disappeared (expected a returned pool checkout)"
[ -n "$GD4" ] && expect_absent "$GD4/firstmate-home-lock" "the failed seed left no ownership receipt" || true
expect_absent "$H4/.fm-secondmate-home" "the returned slot carries no attempted identity"
expect_absent "$H4/data" "the returned slot carries no partial payload"
next_out=$(seed mate5); printf '%s\n' "$next_out" | tail -3 | sed 's/^/   /'
H5=$(printf '%s\n' "$next_out" | sed -n 's/^home=//p' | tail -1)
[ "$(printf '%s\n' "$next_out" | grep -c '^home=')" -ge 1 ] && check ok "the next seed could lease the slot the failed seed returned" || check fail "the slot stayed unusable after a failed seed"
[ "$H5" = "$H4" ] && check ok "the next seed leased the same slot" || check fail "next seed leased a different slot ($H5)"
GD5=$(git -C "$H5" rev-parse --absolute-git-dir)
expect_owned_lock "$GD5/locked" mate5 "the new seed owns its own protection"
meta mate5 "$H5"

##############################################################################
echo
echo "=== SCENARIO 6 (adversarial): a return killed mid-flight is recovered by the next retirement"
tear5=$( cd "$CD" && run bin/fm-teardown.sh mate5 2>&1 ); printf '%s\n' "$tear5" | tail -2 | sed 's/^/   /'
seed6_out=$(seed mate6); printf '%s\n' "$seed6_out" | tail -3 | sed 's/^/   /'
H6=$(printf '%s\n' "$seed6_out" | sed -n 's/^home=//p' | tail -1)
GD6=$(git -C "$H6" rev-parse --absolute-git-dir)
meta mate6 "$H6"
mkdir -p "$LAB/shim-hang"
cat > "$LAB/shim-hang/treehouse" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = return ]; then echo "synthetic treehouse return in flight" >&2; exec sleep 600; fi
exec $REAL_TREEHOUSE "\$@"
EOF
chmod +x "$LAB/shim-hang/treehouse"
pid6=$(spawn_detached "$LAB/hang6.log" "${LAB_ENV[@]}" PATH="$LAB/shim-hang:$PATH" bin/fm-teardown.sh mate6)
PGIDS+=("$pid6")
staging6=$(wait_for_staging_record returning=1) || true
if [ -n "${staging6:-}" ]; then check ok "the killed return reached its in-flight staging: $staging6"; else check fail "the return never staged the home"; fi
kill -KILL -- "-$pid6" 2>/dev/null || true
wait_group_gone "$pid6" || check fail "the killed return left a live process group"
PGIDS=()
echo "-- crash state: home marker present? $([ -e "$H6/.fm-secondmate-home" ] && echo yes || echo no); payload present? $([ -e "$H6/data" ] && echo yes || echo no)"
expect_absent "$H6/.fm-secondmate-home" "the killed return left the home stripped of identity"
expect_absent "$H6/data" "the killed return left the home stripped of payload"
[ -n "$(staging_dirs)" ] && check ok "the killed return left a recoverable staging record" || check fail "the killed return left no staging record"
echo "-- staging record: $(sed -n '1,3p' "${staging6:-/dev/null}/return-record" 2>/dev/null | tr '\n' ' ')"
case "$(pool_status)" in *leased*mate6*) check ok "the killed return left the real pool lease held for mate6" ;; *) check fail "the killed return lost the real pool lease ($(pool_status))" ;; esac
recover_out=$( cd "$CD" && run bin/fm-teardown.sh mate6 2>&1 ); recover_rc=$?
printf '%s\n' "$recover_out" | tail -6 | sed 's/^/   /'
[ "$recover_rc" -eq 0 ] && check ok "retrying the interrupted retirement succeeded" || check fail "retrying the interrupted retirement failed (rc=$recover_rc)"
expect_absent "$H6/data" "the recovered retirement returned a clean slot"
expect_absent "$H6/.fm-secondmate-home" "the recovered retirement cleared the interrupted identity"
expect_absent "$GD6/locked" "the recovered retirement released the lock"
expect_absent "$LAB/parent/state/mate6.meta" "the recovered retirement removed the task record"
[ -z "$(staging_dirs)" ] && check ok "the recovered retirement cleared its staging" || check fail "the recovered retirement stranded staging"

##############################################################################
echo
echo "=== SCENARIO 7 (adversarial): a crash after the slot return committed must not restore the retired payload"
seed7_out=$(seed mate7); printf '%s\n' "$seed7_out" | tail -3 | sed 's/^/   /'
H7=$(printf '%s\n' "$seed7_out" | sed -n 's/^home=//p' | tail -1)
GD7=$(git -C "$H7" rev-parse --absolute-git-dir)
meta mate7 "$H7"
mkdir -p "$LAB/shim-commit"
cat > "$LAB/shim-commit/treehouse" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = return ]; then
  $REAL_TREEHOUSE "\$@" || exit \$?
  # The real pool slot return is done; signal the driver and stall inside the
  # return callback so the whole teardown can be SIGKILLed after that commit.
  : > "$LAB/commit-trigger"
  exec sleep 600
fi
exec $REAL_TREEHOUSE "\$@"
EOF
chmod +x "$LAB/shim-commit/treehouse"
rm -f "$LAB/commit-trigger"
pid7=$(spawn_detached "$LAB/commit7.log" "${LAB_ENV[@]}" PATH="$LAB/shim-commit:$PATH" bin/fm-teardown.sh mate7)
PGIDS+=("$pid7")
staging7=$(wait_for_staging_record returning=1) || true
for ((i = 0; i < 200; i++)); do [ -f "$LAB/commit-trigger" ] && break; sleep 0.1; done
[ -f "$LAB/commit-trigger" ] && check ok "the real pool slot return completed before the crash" || check fail "the real pool slot return never completed"
kill -KILL -- "-$pid7" 2>/dev/null || true
wait_group_gone "$pid7" 200 || check fail "the crashed retirement left a live process group"
PGIDS=()
echo "-- crash log:"; sed 's/^/   /' "$LAB/commit7.log"
echo "-- staging after crash: ${staging7:-none}"
[ -n "${staging7:-}" ] && check ok "the crash left the in-flight staging record for recovery" || check fail "the crash left no staging record"
echo "-- crash staging record: $(tr '\n' ' ' < "${staging7:-/dev/null}/return-record" 2>/dev/null)"
grep -Fxq 'committed=1' "${staging7:-/dev/null}/return-record" 2>/dev/null && check fail "the crash already recorded the return as committed" || check ok "the crash state still has an unresolved return record"
expect_absent "$H7/.fm-secondmate-home" "the crashed retirement left the home stripped of identity"
expect_present "$LAB/parent/state/mate7.meta" "the crash left the mate's route record for the retry"
pool7=$(pool_status); echo "-- pool after crash (slot already returned): $pool7"
case "$pool7" in *"leased"*"mate7"*) check fail "the crash did not actually commit the slot return ($pool7)" ;; *) check ok "the crash happened after the real pool slot return" ;; esac
retry7_out=$( cd "$CD" && run bin/fm-teardown.sh mate7 2>&1 ); retry7_rc=$?
printf '%s\n' "$retry7_out" | tail -6 | sed 's/^/   /'
[ "$retry7_rc" -eq 0 ] && check ok "the retried retirement completed as a records-only retirement" || check fail "the retried retirement failed (rc=$retry7_rc)"
expect_absent "$H7/.fm-secondmate-home" "recovery did NOT restore the retired identity into the returned slot"
expect_absent "$H7/data" "recovery did NOT restore the retired payload into the returned slot"
expect_absent "$GD7/locked" "recovery did NOT re-lock the returned slot"
expect_absent "$GD7/firstmate-home-lock" "recovery did NOT republish the retired ownership receipt"
expect_absent "$LAB/parent/state/mate7.meta" "the records-only retirement removed the task record"
[ -z "$(staging_dirs)" ] && check ok "the records-only retirement drained its staging" || check fail "the records-only retirement stranded staging"
seed7b_out=$(seed mate7); printf '%s\n' "$seed7b_out" | tail -4 | sed 's/^/   /'
H7b=$(printf '%s\n' "$seed7b_out" | sed -n 's/^home=//p' | tail -1)
GD7b=$(git -C "$H7b" rev-parse --absolute-git-dir 2>/dev/null || true)
[ "$H7b" = "$H7" ] && check ok "the same mate id leased the same returned slot again" || check fail "the replacement seed leased a different slot ($H7b)"
[ "$(cat "$H7b/.fm-secondmate-home" 2>/dev/null)" = mate7 ] && check ok "the replacement home published its own identity" || check fail "the replacement home has no identity"
expect_owned_lock "$GD7b/locked" mate7 "the replacement home carries its own owned lock"
expect_present "$H7b/data/charter.md" "the replacement home was seeded with its own payload"
meta mate7 "$H7b"
final_out=$( cd "$CD" && run bin/fm-teardown.sh mate7 2>&1 ); final_rc=$?
printf '%s\n' "$final_out" | tail -4 | sed 's/^/   /'
[ "$final_rc" -eq 0 ] && check ok "retiring the replacement home succeeded" || check fail "retiring the replacement home failed (rc=$final_rc)"
expect_absent "$H7b/data" "the replacement retirement cleared its payload"
expect_absent "$H7b/.fm-secondmate-home" "the replacement retirement cleared its identity"
expect_absent "$GD7b/locked" "the replacement retirement released its lock"
expect_absent "$LAB/parent/state/mate7.meta" "the replacement retirement removed its task record"

echo
echo "=== SUMMARY: $FAILS failed check(s)"
[ "$FAILS" -eq 0 ]
