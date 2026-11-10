#!/usr/bin/env bash
# Live validation driver for fix/6921-durable-home-worktree-lock.
# Drives the real product scripts (bin/fm-home-seed.sh, bin/fm-teardown.sh)
# from a disposable clone of the reviewed commit, against a REAL local
# treehouse pool (HOME-isolated state, repo-local treehouse.toml), real git,
# and a private tmux socket. Nothing outside $LAB is touched.
set -u

WT={run-worktree}
REAL_TREEHOUSE=$(command -v treehouse)
LAB=$(mktemp -d /tmp/fm-lab.XXXXXX)
FAILS=0
cleanup() {
  TMUX_TMPDIR="$LAB/tmux" tmux kill-server 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

check() { # <ok|fail> <description>
  if [ "$1" = ok ]; then printf 'PASS  %s\n' "$2"; else printf 'FAIL  %s\n' "$2"; FAILS=$((FAILS + 1)); fi
}
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
run() { env -u NO_MISTAKES_GATE -u TMUX -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
  -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u FM_GATE_REFUSE_BYPASS \
  HOME="$LAB/home" FM_HOME="$LAB/parent" FM_ROOT_OVERRIDE="$LAB/code" \
  TMUX_TMPDIR="$LAB/tmux" "$@"; }

printf '### lab %s (code HEAD %s)\n' "$LAB" "$(git -C "$WT" rev-parse HEAD)"
mkdir -p "$LAB/home" "$LAB/parent/state" "$LAB/parent/data" "$LAB/parent/config" "$LAB/parent/projects" "$LAB/tmux"
git clone --quiet --no-checkout "$WT" "$LAB/code"
git -C "$LAB/code" checkout --quiet "$(git -C "$WT" rev-parse HEAD)"
git -C "$LAB/code" checkout -B main --quiet
# Run the reviewed commit plus this run's uncommitted repair (message contract).
git -C "$WT" status --porcelain | awk '{print $2}' | while read -r f; do
  [ -n "$f" ] && cp "$WT/$f" "$LAB/code/$f" && echo "overlay: $f"
done
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

##############################################################################
echo
echo "=== SCENARIO 1: a seeded durable home is Git-locked and ordinary removal refuses"
seed_out=$( cd "$CD" && run FM_SECONDMATE_CHARTER='live domain one' FM_SECONDMATE_SCOPE='live domain one' \
  bin/fm-home-seed.sh mate1 - --no-projects 2>&1 )
printf '%s\n' "$seed_out"
H1=$(printf '%s\n' "$seed_out" | sed -n 's/^home=//p' | tail -1)
GD1=$(git -C "$H1" rev-parse --absolute-git-dir)
echo "-- identity marker: $(cat "$H1/.fm-secondmate-home")"
echo "-- git worktree lock: $(cat "$GD1/locked")"
echo "-- ownership receipt:"; sed 's/^/   /' "$GD1/firstmate-home-lock"
[ "$(cat "$H1/.fm-secondmate-home")" = mate1 ] && check ok "seed published mate1 identity" || check fail "seed did not publish mate1 identity"
expect_owned_lock "$GD1/locked" mate1 "seeded home carries the durable-home Git lock"
rm_out=$(git -C "$CD" worktree remove "$H1" 2>&1); rm_rc=$?
printf '%s\n' "$rm_out" | sed 's/^/   /'
[ "$rm_rc" -ne 0 ] && check ok "ordinary 'git worktree remove' of the idle home is refused" || check fail "ordinary git worktree remove deleted an idle durable home"
expect_present "$H1/.fm-secondmate-home" "the refused removal left the home in place"
reason_before=$(cat "$GD1/locked")
reseed_out=$( cd "$CD" && run FM_SECONDMATE_CHARTER='live domain one' FM_SECONDMATE_SCOPE='live domain one' \
  bin/fm-home-seed.sh mate1 "$H1" --no-projects 2>&1 )
printf '%s\n' "$reseed_out" | sed 's/^/   /'
[ "$(cat "$GD1/locked")" = "$reason_before" ] && check ok "re-seeding an already-owned home preserves the exact owned lock" || check fail "re-seed changed the owned lock"
meta mate1 "$H1"

##############################################################################
echo
echo "=== SCENARIO 2: retirement releases the lock and hands back a reusable pool slot"
before=$( cd "$CD" && HOME="$LAB/home" treehouse status 2>/dev/null | tail -2 )
echo "-- treehouse before: $before"
tear_out=$( cd "$CD" && run bin/fm-teardown.sh mate1 2>&1 ); tear_rc=$?
printf '%s\n' "$tear_out" | tail -6 | sed 's/^/   /'
[ "$tear_rc" -eq 0 ] && check ok "teardown of the durable home succeeded" || check fail "teardown of the durable home failed (rc=$tear_rc)"
expect_absent "$GD1/locked" "retirement released the Git worktree lock"
expect_absent "$GD1/firstmate-home-lock" "retirement removed the ownership receipt"
for p in data state config projects .fm-secondmate-home .fm-secondmate-parent; do
  expect_absent "$H1/$p" "returned slot carries no retired payload: $p"
done
expect_present "$H1/AGENTS.md" "returned slot keeps its checkout contents"
expect_absent "$LAB/parent/state/mate1.meta" "retirement removed the retired mate's task record"
echo "-- treehouse after return: $( cd "$CD" && HOME="$LAB/home" treehouse status 2>/dev/null | tail -2 )"

seed2_out=$( cd "$CD" && run FM_SECONDMATE_CHARTER='live domain two' FM_SECONDMATE_SCOPE='live domain two' \
  bin/fm-home-seed.sh mate2 - --no-projects 2>&1 )
printf '%s\n' "$seed2_out" | tail -4 | sed 's/^/   /'
H2=$(printf '%s\n' "$seed2_out" | sed -n 's/^home=//p' | tail -1)
GD2=$(git -C "$H2" rev-parse --absolute-git-dir)
[ "$H2" = "$H1" ] && check ok "the next seed leased the very slot the retired mate returned" || check fail "next seed leased a different slot ($H2)"
[ "$(cat "$H2/.fm-secondmate-home")" = mate2 ] && check ok "the re-leased slot carries the new mate's identity, not the retired one" || check fail "re-leased slot kept the retired identity"
expect_owned_lock "$GD2/locked" mate2 "the re-leased slot carries the new mate's owned lock"
expect_present "$H2/data/charter.md" "the re-leased home was seeded with its own payload"
meta mate2 "$H2"

##############################################################################
echo
echo "=== SCENARIO 3 (adversarial): foreign or unprovable lock ownership refuses retirement"
git -C "$H2" worktree unlock "$H2"
git -C "$H2" worktree lock --reason 'foreign owner' "$H2"
echo "-- foreign lock installed: $(cat "$GD2/locked")"
cp "$GD2/firstmate-home-lock" "$LAB/receipt"
: > "$LAB/lease-held"; ( cd "$CD" && HOME="$LAB/home" treehouse status 2>/dev/null | tail -2 ) > "$LAB/lease-held"
force_out=$( cd "$CD" && run bin/fm-teardown.sh mate2 --force 2>&1 ); force_rc=$?
printf '%s\n' "$force_out" | tail -3 | sed 's/^/   /'
[ "$force_rc" -ne 0 ] && check ok "forced retirement refused a foreign-owned durable home" || check fail "--force retired a foreign-locked home"
[ "$(cat "$GD2/locked")" = 'foreign owner' ] && check ok "the refusal left the foreign lock byte-identical" || check fail "the refusal changed the foreign lock"
expect_present "$LAB/parent/state/mate2.meta" "the refusal preserved the mate's route for retry"
expect_present "$H2/.fm-secondmate-home" "the refusal preserved the home"

# A familiar-looking reason without the ownership receipt is not ownership.
git -C "$H2" worktree unlock "$H2"
printf '%s\n' "$(sed -n '5p' "$LAB/receipt" | sed 's/^reason=//')" > "$GD2/locked"
rm -f "$GD2/firstmate-home-lock"
noowner_out=$( cd "$CD" && run bin/fm-teardown.sh mate2 2>&1 ); noowner_rc=$?
printf '%s\n' "$noowner_out" | tail -3 | sed 's/^/   /'
[ "$noowner_rc" -ne 0 ] && check ok "retirement refused a familiar lock reason with no ownership receipt" || check fail "retirement trusted a reason with no receipt"
expect_present "$LAB/parent/state/mate2.meta" "the unknown-owner refusal preserved the route"

# Restore owned protection: retirement now proceeds.
cp "$LAB/receipt" "$GD2/firstmate-home-lock"
owned_out=$( cd "$CD" && run bin/fm-teardown.sh mate2 2>&1 ); owned_rc=$?
printf '%s\n' "$owned_out" | tail -3 | sed 's/^/   /'
[ "$owned_rc" -eq 0 ] && check ok "retirement succeeded once owned protection was restored" || check fail "retirement failed with owned protection restored (rc=$owned_rc)"
expect_absent "$GD2/locked" "the successful retry released the lock"
expect_absent "$H2/data" "the successful retry cleared the retired payload"

##############################################################################
echo
echo "=== SCENARIO 4: a failed pool return preserves the home, lock, and lease for retry"
seed3_out=$( cd "$CD" && run FM_SECONDMATE_CHARTER='live domain three' FM_SECONDMATE_SCOPE='live domain three' \
  bin/fm-home-seed.sh mate3 - --no-projects 2>&1 )
printf '%s\n' "$seed3_out" | tail -3 | sed 's/^/   /'
H3=$(printf '%s\n' "$seed3_out" | sed -n 's/^home=//p' | tail -1)
GD3=$(git -C "$H3" rev-parse --absolute-git-dir)
meta mate3 "$H3"
mkdir -p "$LAB/shim"
printf '#!/usr/bin/env bash\nif [ "${1:-}" = return ]; then echo "synthetic treehouse return failure" >&2; exit 17; fi\nexec %s "$@"\n' "$REAL_TREEHOUSE" > "$LAB/shim/treehouse"
chmod +x "$LAB/shim/treehouse"
fail_out=$( cd "$CD" && PATH="$LAB/shim:$PATH" run bin/fm-teardown.sh mate3 2>&1 ); fail_rc=$?
printf '%s\n' "$fail_out" | tail -4 | sed 's/^/   /'
[ "$fail_rc" -ne 0 ] && check ok "teardown reported the failed pool return to the operator" || check fail "teardown hid the failed pool return"
expect_owned_lock "$GD3/locked" mate3 "the failed return restored the exact owned lock"
expect_present "$GD3/firstmate-home-lock" "the failed return restored the ownership receipt"
expect_present "$H3/.fm-secondmate-home" "the failed return kept the home identity"
expect_present "$H3/data/charter.md" "the failed return kept the retryable home payload"
expect_present "$LAB/parent/state/mate3.meta" "the failed return kept the route for retry"
held=$( cd "$CD" && HOME="$LAB/home" treehouse status 2>/dev/null | tail -2 )
echo "-- pool after failed return: $held"
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
next_out=$( cd "$CD" && run FM_SECONDMATE_CHARTER='live domain five' FM_SECONDMATE_SCOPE='live domain five' \
  bin/fm-home-seed.sh mate5 - --no-projects 2>&1 ); next_rc=$?
printf '%s\n' "$next_out" | tail -3 | sed 's/^/   /'
H5=$(printf '%s\n' "$next_out" | sed -n 's/^home=//p' | tail -1)
[ "$next_rc" -eq 0 ] && check ok "the next seed could lease the slot the failed seed returned" || check fail "the slot stayed unusable after a failed seed"
[ "$H5" = "$H4" ] && check ok "the next seed leased the same slot" || check fail "next seed leased a different slot ($H5)"
GD5=$(git -C "$H5" rev-parse --absolute-git-dir)
expect_owned_lock "$GD5/locked" mate5 "the new seed owns its own protection"
meta mate5 "$H5"

echo
echo "=== SUMMARY: $FAILS failed check(s)"
[ "$FAILS" -eq 0 ]
