#!/usr/bin/env bash
# Live acceptance driver for branch fix/6921-durable-home-worktree-lock.
# Drives the real firstmate CLI (fm-home-seed.sh / fm-teardown.sh) against a
# real treehouse v2 pool and a real Git repository, all inside one throwaway
# lab: HOME is redirected so the pool lives under the lab, FM_HOME is a
# fm-lab-home-marked disposable home, and the code root is a clone of the
# reviewed worktree at HEAD.
set -u

SRC={run-worktree}
LAB=$(mktemp -d /tmp/fml.XXXXXX) || exit 1
CODE=$LAB/code
PARENT=$LAB/parent
FAIL=0

cleanup() {
  # Release any still-leased slot and drop the whole lab (pool included).
  if [ -d "$LAB/home/.treehouse" ]; then
    for wt in "$LAB/home/.treehouse"/*/*/code; do
      [ -d "$wt" ] || continue
      ( cd "$CODE" && HOME="$LAB/home" TREEHOUSE_NO_UPDATE_CHECK=1 treehouse return --force "$wt" >/dev/null 2>&1 ) || true
    done
  fi
  rm -rf -- "$LAB"
}
trap cleanup EXIT

step() { printf '\n=== %s ===\n' "$*"; }
ok()   { printf 'PASS: %s\n' "$*"; }
bad()  { printf 'FAIL: %s\n' "$*"; FAIL=1; }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

step "lab setup: clone reviewed HEAD, marked lab home, isolated pool"
git clone --quiet --no-checkout "$SRC" "$CODE" || { echo "clone failed"; exit 1; }
git -C "$CODE" checkout --quiet HEAD || exit 1
mkdir -p "$LAB/home"
HOME="$LAB/home" "$CODE/bin/fm-lab-home.sh" create "$PARENT" || exit 1
export HOME="$LAB/home" TREEHOUSE_NO_UPDATE_CHECK=1 FM_HOME="$PARENT"
echo "lab=$LAB"
echo "code_root=$CODE head=$(git -C "$CODE" rev-parse --short HEAD)"
echo "pool_dir=$LAB/home/.treehouse"

seed() {  # <id> <home|->
  ( cd "$CODE" && FM_SECONDMATE_CHARTER="$1 domain" ./bin/fm-home-seed.sh "$1" "$2" --no-projects 2>&1 )
}
teardown() {  # <id> [extra env via PATH etc]
  ( cd "$CODE" && ./bin/fm-teardown.sh "$1" --force 2>&1 )
}
write_meta() {  # <id> <home>
  cat > "$PARENT/state/$1.meta" <<EOF
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
pool_json() { cat "$LAB/home/.treehouse"/*/treehouse-state.json 2>/dev/null; }

# ---------------------------------------------------------------- scenario 1
step "S1: seed a durable secondmate home and inspect its owned Git worktree lock"
s1_out=$(seed alpha -); echo "$s1_out"
HOME_ALPHA=$(printf '%s\n' "$s1_out" | sed -n 's/^home=//p')
[ -n "$HOME_ALPHA" ] && ok "seed published home=$HOME_ALPHA" || bad "seed published no home"
GITDIR=$(git -C "$HOME_ALPHA" rev-parse --absolute-git-dir)
echo "gitdir=$GITDIR"
echo "locked: $(cat "$GITDIR/locked" 2>/dev/null)"
echo "receipt: $(sed -n '1,5p' "$GITDIR/firstmate-home-lock" 2>/dev/null | tr '\n' '|')"
check "owned Git worktree lock present with Firstmate reason" \
  'grep -q "Firstmate durable home alpha" "$GITDIR/locked"'
check "ownership receipt present" '[ -f "$GITDIR/firstmate-home-lock" ]'
s1_remove=$(git -C "$CODE" worktree remove "$HOME_ALPHA" 2>&1); s1_remove_rc=$?
echo "git worktree remove rc=$s1_remove_rc: $s1_remove"
check "plain git worktree remove refuses the protected durable home" \
  '[ "$s1_remove_rc" -ne 0 ] && printf "%s" "$s1_remove" | grep -q "cannot remove a locked working tree"'
check "durable home still present after the refused removal" '[ -d "$HOME_ALPHA" ]'

# ---------------------------------------------------------------- scenario 2
step "S2: guarded retirement (fm-teardown.sh --force) returns a clean, reusable slot"
write_meta alpha "$HOME_ALPHA"
s2_out=$(teardown alpha); s2_rc=$?; echo "$s2_out"
check "guarded retirement succeeded" '[ "$s2_rc" -eq 0 ]'
for p in data state config projects .fm-secondmate-home .fm-secondmate-parent; do
  check "returned slot carries no $p payload" '[ ! -e "$HOME_ALPHA/$p" ]'
done
check "owned Git worktree lock released" '[ ! -e "$GITDIR/locked" ]'
check "ownership receipt removed" '[ ! -e "$GITDIR/firstmate-home-lock" ]'
check "pool slot is unleased again" '! pool_json | grep -q "\"leased\": true"'
s2_seed=$(seed alpha2 -); echo "$s2_seed"
HOME_A2=$(printf '%s\n' "$s2_seed" | sed -n 's/^home=//p')
check "next seed re-leases the same pool slot" '[ "$HOME_A2" = "$HOME_ALPHA" ]'
check "next seed succeeded on the returned slot" 'printf "%s" "$s2_seed" | grep -q "^home="'
# retire that verification home so every later round starts from a free slot
write_meta alpha2 "$HOME_A2"
s2_td=$(teardown alpha2); s2_td_rc=$?; echo "$s2_td" | tail -2
check "verification home retired cleanly (slot reusable twice)" '[ "$s2_td_rc" -eq 0 ] && [ ! -e "$HOME_A2/data" ]'

# ---------------------------------------------------------------- scenario 3
step "S3: each handled INT/TERM/HUP during the payload move restores the home for retry"
mkdir -p "$LAB/fakebin"
REAL_MV=$(command -v mv)
cat > "$LAB/fakebin/mv" <<SH
#!/usr/bin/env bash
# Timing instrument only: the real mv always performs the move. It holds the
# payload staging move open long enough for the driver to deliver a signal.
case " \$* " in
  *"/.home-return."*)
    if [ ! -s "\$FM_TEST_MOVER_MARKER" ]; then printf '%s\n' "\$PPID" > "\$FM_TEST_MOVER_MARKER"; fi
    sleep 4 ;;
esac
exec "$REAL_MV" "\$@"
SH
chmod +x "$LAB/fakebin/mv"
for round in TERM:alpha3 INT:alpha4 HUP:alpha5; do
  sig=${round%%:*}; s3_id=${round##*:}
  step "S3.$sig: SIG$sig inside the payload staging window (home $s3_id)"
  s3_seed=$(seed "$s3_id" -); echo "$s3_seed"
  HOME_A2=$(printf '%s\n' "$s3_seed" | sed -n 's/^home=//p')
  check "$sig round seeded a durable home" '[ -n "$HOME_A2" ] && [ -f "$GITDIR/locked" ]'
  write_meta "$s3_id" "$HOME_A2"
  MARKER=$LAB/mover.pid
  rm -f "$MARKER"
  # The signal is delivered by a background watcher so the retirement itself
  # runs in the foreground: bash ignores SIGINT in asynchronous commands, so
  # backgrounding the product would silently disable its INT trap.
  (
    i=0
    while [ ! -s "$MARKER" ]; do
      i=$((i+1)); [ "$i" -lt 600 ] || exit 1
      sleep 0.05
    done
    kill -"$sig" "$(cat "$MARKER")"
  ) &
  watcher=$!
  ( cd "$CODE" && PATH="$LAB/fakebin:$PATH" FM_TEST_MOVER_MARKER="$MARKER" \
    ./bin/fm-teardown.sh "$s3_id" --force >"$LAB/s3-teardown-$sig.log" 2>&1 )
  s3_rc=$?
  if wait "$watcher"; then
    ok "delivered SIG$sig inside the staging window"
  else
    bad "teardown never reached the payload staging move"
  fi
  echo "teardown exit=$s3_rc"
  tail -4 "$LAB/s3-teardown-$sig.log"
  check "interrupted teardown reported failure instead of success" '[ "$s3_rc" -ne 0 ]'
  check "home payload restored" '[ -d "$HOME_A2/data" ] && [ -d "$HOME_A2/state" ]'
  check "home identity restored" '[ "$(cat "$HOME_A2/.fm-secondmate-home")" = "$s3_id" ]'
  check "parent binding restored" '[ -f "$HOME_A2/.fm-secondmate-parent" ]'
  check "owned Git worktree lock restored" 'grep -q "Firstmate durable home $s3_id" "$GITDIR/locked"'
  check "ownership receipt restored" '[ -f "$GITDIR/firstmate-home-lock" ]'
  check "slot was not released by the interrupted return" 'pool_json | grep -q "\"leased\": true"'
  check "no payload staging left behind" '[ -z "$(find "$PARENT/state" -maxdepth 1 -name ".home-return.*" -print -quit)" ]'
  check "task record kept for the retry" '[ -f "$PARENT/state/$s3_id.meta" ]'
  check "interrupted return did not report an unrestorable payload" '! grep -q "could not restore" "$LAB/s3-teardown-$sig.log"'
  s3_retry=$(teardown "$s3_id"); s3_retry_rc=$?; echo "$s3_retry" | tail -3
  check "retried retirement released the slot cleanly" '[ "$s3_retry_rc" -eq 0 ] && [ ! -e "$GITDIR/locked" ] && [ ! -e "$HOME_A2/data" ]'
done

# ---------------------------------------------------------------- scenario 4
step "S4 (adversarial): manual pre-V2 migration skipping the documented release leaves the slot refused"
s4_seed=$(seed delta -); echo "$s4_seed"
HOME_D=$(printf '%s\n' "$s4_seed" | sed -n 's/^home=//p')
GD_D=$(git -C "$HOME_D" rev-parse --absolute-git-dir)
# operator branch 3: clear the retired home's payload, force the slot back
for p in data state config projects .fm-secondmate-home .fm-secondmate-parent; do rm -rf -- "$HOME_D/$p"; done
( cd "$CODE" && treehouse return --force "$HOME_D" ) >"$LAB/s4-return.log" 2>&1; echo "treehouse return rc=$?"; cat "$LAB/s4-return.log"
check "manual force return left the Git worktree lock behind" '[ -f "$GD_D/locked" ]'
check "manual force return left the ownership receipt behind" '[ -f "$GD_D/firstmate-home-lock" ]'
# The docs steps 3 and 4 that surround the new paragraph: the retired mate's
# registry line and task record go with the manual retirement, so only the
# surviving lock and receipt can refuse the next seed.
if [ -f "$PARENT/data/secondmates.md" ]; then
  grep -v '^- delta ' "$PARENT/data/secondmates.md" > "$PARENT/data/secondmates.md.tmp" || true
  mv "$PARENT/data/secondmates.md.tmp" "$PARENT/data/secondmates.md"
fi
rm -f "$PARENT/state/delta.meta"
echo "registry after manual retirement: [$(cat "$PARENT/data/secondmates.md" 2>/dev/null)]"
s4_seed2=$(seed epsilon - 2>&1); s4_seed2_rc=$?; echo "$s4_seed2"
check "next seed refuses the slot when the lock and receipt survive" '[ "$s4_seed2_rc" -ne 0 ]'
check "refusal names the stale durable-home ownership" \
  'printf "%s" "$s4_seed2" | grep -q "REFUSED: unknown durable-home lock ownership"'
check "slot still holds delta's stale lock after the refused seed" 'grep -q "Firstmate durable home delta" "$GD_D/locked"'
# release the lease the refused seed attempt left behind so the next attempt
# gets the same single pool slot again
( cd "$CODE" && treehouse return --force "$HOME_D" ) >/dev/null 2>&1 || true
# Half the documented release is not enough: unlocking the worktree while the
# receipt survives still marks the slot for the retired mate.
( cd "$HOME_D" && git worktree unlock "$HOME_D" ); echo "doc step 1 applied alone (unlock) rc=$?"
check "unlock alone leaves the ownership receipt in place" '[ -f "$GD_D/firstmate-home-lock" ]'
s4_seed3=$(seed epsilon - 2>&1); s4_seed3_rc=$?; echo "$s4_seed3"
check "seed still refuses a slot marked for the retired mate" '[ "$s4_seed3_rc" -ne 0 ]'
check "half-released refusal names the stale ownership too" \
  'printf "%s" "$s4_seed3" | grep -q "REFUSED: unknown durable-home lock ownership"'
( cd "$CODE" && treehouse return --force "$HOME_D" ) >/dev/null 2>&1 || true

# ---------------------------------------------------------------- scenario 5
step "S5: following the documented manual release lets the next seed take the slot"
rm "$(git -C "$HOME_D" rev-parse --absolute-git-dir)/firstmate-home-lock"; echo "doc step 2 (rm <gitdir>/firstmate-home-lock) rc=$?"
check "documented release cleared the Git worktree lock" '[ ! -e "$GD_D/locked" ]'
check "documented release cleared the ownership receipt" '[ ! -e "$GD_D/firstmate-home-lock" ]'
( cd "$CODE" && treehouse return --force "$HOME_D" ) >"$LAB/s5-return.log" 2>&1; echo "released leftover lease rc=$?"
s5_seed=$(seed epsilon -); s5_seed_rc=$?; echo "$s5_seed"
HOME_E=$(printf '%s\n' "$s5_seed" | sed -n 's/^home=//p')
check "next seed succeeds on the released slot" '[ "$s5_seed_rc" -eq 0 ]'
check "next seed took the same pool slot" '[ "$HOME_E" = "$HOME_D" ]'
check "new home carries its own owned lock" 'grep -q "Firstmate durable home epsilon" "$(git -C "$HOME_E" rev-parse --absolute-git-dir 2>/dev/null)/locked"'
write_meta epsilon "$HOME_E"
s5_td=$(teardown epsilon); s5_rc=$?; echo "$s5_td" | tail -3
check "re-seeded home retires cleanly (slot reusable end to end)" '[ "$s5_rc" -eq 0 ]'

step "result"
if [ "$FAIL" = 0 ]; then echo "ALL SCENARIOS PASSED"; else echo "SOME CHECKS FAILED"; fi
exit "$FAIL"
