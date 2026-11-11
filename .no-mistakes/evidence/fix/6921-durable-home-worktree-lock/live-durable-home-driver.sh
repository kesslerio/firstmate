#!/usr/bin/env bash
# Live end-to-end driver for fix/6921-durable-home-worktree-lock.
# Runs the real product (a disposable clone of the reviewed head, its own
# bin/fm-home-seed.sh and bin/fm-teardown.sh) against a real treehouse pool and
# real git worktrees, in disposable labs under /tmp.
set -uo pipefail

ROOT=${ROOT:?set ROOT to the worktree under validation}
OUT=${OUT:?set OUT to the evidence directory}
LABROOT=${LABROOT:-/tmp/fm-live-driver/labs}
rm -rf "$LABROOT"
mkdir -p "$LABROOT" "$OUT"

FAILS=0
say() { printf '\n=== %s\n' "$*"; }
ok() { printf 'ok   %s\n' "$*"; }
bad() {
  printf 'FAIL %s\n' "$*"
  FAILS=$((FAILS + 1))
}
check() { # <description> <command...>
  local desc=$1
  shift
  if "$@"; then ok "$desc"; else bad "$desc"; fi
}
present() { [ -e "$1" ] && ok "present: $1" || bad "missing: $1"; }
absent() { [ ! -e "$1" ] && ok "absent: $1" || bad "still present: $1"; }
has() { # <file> <text> <desc>
  if grep -F -- "$2" "$1" >/dev/null 2>&1; then ok "$3"; else bad "$3"; fi
}
hasnt() {
  if grep -F -- "$2" "$1" >/dev/null 2>&1; then bad "$3"; else ok "$3"; fi
}

# Lab: disposable code root (the reviewed head), real treehouse pool, parent home.
mklab() {  # <name> -> sets LAB CODE PARENT H
  LAB="$LABROOT/$1"
  CODE="$LAB/code"
  PARENT="$LAB/parent"
  mkdir -p "$LAB/pool" "$PARENT/data" "$PARENT/state" "$LAB/fake/bin"
  git clone --quiet --no-checkout "$ROOT" "$CODE" || return 1
  git -C "$CODE" checkout --quiet "$(git -C "$ROOT" rev-parse HEAD)" || return 1
  printf 'max_trees = 4\nroot = "%s/pool"\n' "$LAB" > "$CODE/treehouse.toml"
  git -C "$CODE" add treehouse.toml || return 1
  git -C "$CODE" -c user.name=lab -c user.email=lab@example.invalid commit -qm 'lab treehouse config' || return 1
  # Endpoint stand-in: the tmux surface is an external tool, not the product.
  cat > "$LAB/fake/bin/tmux" <<'SH'
#!/usr/bin/env bash
printf 'tmux %s\n' "$*" >> "${FM_FAKE_TMUX_LOG:-/dev/null}"
case "${1:-}" in
  list-windows) printf 'firstmate\n'; exit 0 ;;
  capture-pane) printf '\xe2\x9d\xaf\n'; exit 0 ;;
  display-message) printf '%s\n' 4242; exit 0 ;;
  list-panes) printf '0 1 1\n'; exit 0 ;;
esac
exit 0
SH
  chmod +x "$LAB/fake/bin/tmux"
}

# The product's own environment: no gate markers, lab paths only.
product() { # <command...>
  ( cd "$LAB" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE \
    -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    PATH="$LAB/fake/bin:$PATH" FM_FAKE_TMUX_LOG="$LAB/tmux.log" \
    FM_ROOT_OVERRIDE="$CODE" FM_HOME="$PARENT" "$@" )
}

seed() { # <id> <home|->
  product FM_SECONDMATE_CHARTER="$1 lab charter" FM_SECONDMATE_SCOPE="$1 lab scope" \
    bash "$CODE/bin/fm-home-seed.sh" "$1" "$2" --no-projects
}

teardown() { # <id> [args...]
  local id=$1
  shift
  product bash "$CODE/bin/fm-teardown.sh" "$id" "$@"
}

write_meta() { # <id> <home>
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

gitdir_of() { git -C "$1" rev-parse --absolute-git-dir; }

########################################################################
say 'S1: seeding a durable linked-worktree home locks it against ordinary git worktree remove'
mklab s1 || exit 1
seed mate1 - > "$LAB/seed.log" 2>&1
check 'real treehouse seed succeeded' [ "$(grep -c '^home=' "$LAB/seed.log")" = 1 ]
H=$(sed -n 's/^home=//p' "$LAB/seed.log")
printf 'seeded home: %s\n' "$H"
G=$(gitdir_of "$H")
present "$G/locked"
present "$G/firstmate-home-lock"
cat "$G/locked"
cat "$G/firstmate-home-lock"
if git -C "$CODE" worktree remove "$H" > "$LAB/remove.log" 2>&1; then
  bad 'ordinary git worktree remove deleted the protected home'
else
  ok 'ordinary git worktree remove refused the protected home'
fi
cat "$LAB/remove.log"
has "$LAB/remove.log" 'locked' 'git refused because of the worktree lock'
has "$G/locked" 'Firstmate durable home mate1' 'the lock reason names the durable home'
has "$G/firstmate-home-lock" 'home=' 'the ownership receipt is published'
# Repeated seed preserves the owned protection.
reason=$(cat "$G/locked")
seed mate1 "$H" > "$LAB/reseed.log" 2>&1
check 'repeated seed accepted its own lock' [ "$(cat "$G/locked")" = "$reason" ]
check 'repeated seed kept the lock byte-identical' [ "$(cat "$G/locked")" = "$reason" ]

########################################################################
say 'S2: retirement returns a payload-free slot and the next seed leases it again'
write_meta mate1 "$H"
teardown mate1 > "$LAB/teardown.log" 2>&1
check 'retirement of the durable home succeeded' [ "$?" = 0 ]
cat "$LAB/teardown.log"
absent "$G/locked"
absent "$G/firstmate-home-lock"
absent "$H/.fm-secondmate-home"
absent "$H/.fm-secondmate-parent"
absent "$H/data"
absent "$H/state"
absent "$H/config"
absent "$H/projects"
present "$H/AGENTS.md"
absent "$PARENT/state/mate1.meta"
( cd "$CODE" && treehouse status ) > "$LAB/status-after-return.log" 2>&1
cat "$LAB/status-after-return.log"
has "$LAB/status-after-return.log" 'available' 'the pool reports the slot available again'
seed mate2 - > "$LAB/reseed2.log" 2>&1
newhome=$(sed -n 's/^home=//p' "$LAB/reseed2.log")
printf 'the next mate leased: %s\n' "$newhome"
check 'the next mate leased the same returned slot' [ "$newhome" = "$H" ]
check 'the re-leased slot belongs to the new mate' [ "$(cat "$H/.fm-secondmate-home")" = mate2 ]
present "$G/locked"
has "$G/locked" 'Firstmate durable home mate2' 'the re-leased slot carries its own lock'

########################################################################
say 'S3: guarded retirement refuses a foreign lock and unknown ownership, even with --force'
mklab s3 || exit 1
seed mate1 - > "$LAB/seed.log" 2>&1
H=$(sed -n 's/^home=//p' "$LAB/seed.log")
G=$(gitdir_of "$H")
write_meta mate1 "$H"
reason=$(cat "$G/locked")
receipt=$(cat "$G/firstmate-home-lock")
git -C "$H" worktree unlock "$H"
git -C "$H" worktree lock --reason 'foreign owner' "$H"
if teardown mate1 --force > "$LAB/foreign.log" 2>&1; then
  bad 'forced retirement bypassed a foreign lock'
else
  ok 'forced retirement refused a foreign lock'
fi
cat "$LAB/foreign.log"
check 'the foreign lock is untouched' [ "$(cat "$G/locked")" = 'foreign owner' ]
has "$LAB/foreign.log" 'foreign' 'the refusal explains the foreign lock'
present "$PARENT/state/mate1.meta"
( cd "$CODE" && treehouse status ) > "$LAB/status.log" 2>&1
has "$LAB/status.log" 'leased' 'the foreign-locked home is still leased, not returned'
git -C "$H" worktree unlock "$H"
git -C "$H" worktree lock --reason "$reason" "$H"
# A familiar-looking reason with no ownership receipt never licenses unlocking.
rm "$G/firstmate-home-lock"
if teardown mate1 > "$LAB/noreceipt.log" 2>&1; then
  bad 'retirement trusted a lock reason without an ownership receipt'
else
  ok 'retirement refused a familiar reason with no ownership receipt'
fi
cat "$LAB/noreceipt.log"
check 'the lock survives the unknown-ownership refusal' [ "$(cat "$G/locked")" = "$reason" ]
present "$PARENT/state/mate1.meta"
printf '%s\n' "$receipt" > "$G/firstmate-home-lock"
# And a corrupt receipt is refused the same way.
printf 'corrupt\n' >> "$G/firstmate-home-lock"
if teardown mate1 > "$LAB/corrupt.log" 2>&1; then
  bad 'retirement accepted a corrupt ownership receipt'
else
  ok 'retirement refused a corrupt ownership receipt'
fi
cat "$LAB/corrupt.log"
printf '%s\n' "$receipt" > "$G/firstmate-home-lock"
teardown mate1 > "$LAB/retry.log" 2>&1
check 'retirement succeeds once owned protection is intact again' [ "$?" = 0 ]

########################################################################
say 'S4: a failed pool return puts the whole home back so the retry is not refused'
mklab s4 || exit 1
seed mate1 - > "$LAB/seed.log" 2>&1
H=$(sed -n 's/^home=//p' "$LAB/seed.log")
G=$(gitdir_of "$H")
write_meta mate1 "$H"
reason=$(cat "$G/locked")
cp "$G/firstmate-home-lock" "$LAB/receipt"
# The pool provider is an external boundary: a delegating stand-in fails only
# the return command, exactly like a provider that cannot release the lease.
cat > "$LAB/fake/bin/treehouse" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = return ]; then
  printf 'synthetic pool failure\n' >&2
  printf 'treehouse %s\n' "$*" >> "$LAB_TREEHOUSE_LOG"
  exit 17
fi
exec "$LAB_REAL_TREEHOUSE" "$@"
SH
chmod +x "$LAB/fake/bin/treehouse"
LAB_TREEHOUSE_LOG="$LAB/treehouse.log" LAB_REAL_TREEHOUSE="$(command -v treehouse)" \
  teardown mate1 > "$LAB/failed-return.log" 2>&1
rc=$?
[ "$rc" != 0 ] && ok "failed retirement reported failure (rc=$rc)" || bad 'retirement hid a failed pool return'
cat "$LAB/failed-return.log"
has "$LAB/treehouse.log" 'return' 'the return command was reached'
check 'the owned lock is restored exactly' [ "$(cat "$G/locked")" = "$reason" ]
present "$G/firstmate-home-lock"
check 'the receipt is restored exactly' [ "$(cat "$G/firstmate-home-lock")" = "$(cat "$LAB/receipt")" ]
present "$PARENT/state/mate1.meta"
present "$H/.fm-secondmate-home"
present "$H/.fm-secondmate-parent"
present "$H/data/charter.md"
[ -z "$(ls -A "$PARENT/state" | grep home-return || true)" ] && ok 'no payload staging is left behind' || bad 'payload staging stranded'
rm "$LAB/fake/bin/treehouse"
teardown mate1 > "$LAB/retry.log" 2>&1
check 'the retried retirement is not refused' [ "$?" = 0 ]
cat "$LAB/retry.log"
absent "$PARENT/state/mate1.meta"
absent "$G/locked"
absent "$H/data"

interrupt_case() { # <lab> <signal>
  mklab "$1" || return 1
seed mate1 - > "$LAB/seed.log" 2>&1
H=$(sed -n 's/^home=//p' "$LAB/seed.log")
G=$(gitdir_of "$H")
write_meta mate1 "$H"
reason=$(cat "$G/locked")
real_mv=$(command -v mv)
cat > "$LAB/fake/bin/mv" <<SH
#!/usr/bin/env bash
case " \$* " in
  *'/.home-return.'*)
    [ -e "\$FM_TEST_MOVER_MARKER" ] || printf '%s\n' "\$PPID" > "\$FM_TEST_MOVER_MARKER"
    sleep 0.4
    ;;
esac
exec "$real_mv" "\$@"
SH
chmod +x "$LAB/fake/bin/mv"
marker="$LAB/mover.pid"
# Job control so the async child keeps the default SIGINT disposition; a
# background job of a non-job-control shell inherits SIGINT ignored, which would
# make the INT case unrunnable rather than prove anything.
set -m
FM_TEST_MOVER_MARKER="$marker" teardown mate1 > "$LAB/interrupted.log" 2>&1 &
job=$!
set +m
waits=0
while [ ! -s "$marker" ]; do
  waits=$((waits + 1))
  if [ "$waits" -gt 400 ]; then
    kill -KILL "$job" 2>/dev/null
    bad 'the return never started its payload move'
    break
  fi
  sleep 0.05
done
if [ -s "$marker" ]; then
  mover=$(cat "$marker")
  printf 'signalling the returning process %s with %s\n' "$mover" "$2"
  kill -"$2" "$mover" 2>/dev/null && ok 'the interrupted return was signalled' || bad 'the mover exited before the interrupt'
fi
waits=0
while kill -0 "$job" 2>/dev/null; do
  waits=$((waits + 1))
  if [ "$waits" -gt 400 ]; then
    kill -KILL "$job" 2>/dev/null
    bad 'the interrupted retirement did not stop'
    break
  fi
  sleep 0.05
done
status=0
wait "$job" || status=$?
[ "$status" != 0 ] && ok "interrupted retirement reported failure (rc=$status)" || bad 'interrupted retirement reported success'
cat "$LAB/interrupted.log"
check 'the interrupted home kept its data' [ "$(cat "$H/data/charter.md" 2>/dev/null | wc -l)" -gt 0 ]
check 'the interrupted home kept its identity' [ "$(cat "$H/.fm-secondmate-home")" = mate1 ]
has "$H/.fm-secondmate-parent" "parent_home=$PARENT" 'the interrupted home kept its parent binding' 
check 'the interrupted home kept its protection' [ "$(cat "$G/locked")" = "$reason" ]
present "$G/firstmate-home-lock"
present "$PARENT/state/mate1.meta"
present "$H/projects"
[ -z "$(ls -A "$PARENT/state" | grep home-return || true)" ] && ok 'the restore left no payload staging' || bad 'the restore left payload staging'
( cd "$CODE" && treehouse status ) > "$LAB/status.log" 2>&1
has "$LAB/status.log" 'leased' 'the interrupted return did not release the slot'
rm "$LAB/fake/bin/mv"
teardown mate1 > "$LAB/retry.log" 2>&1
check 'the retried retirement after the interrupt succeeded' [ "$?" = 0 ]
cat "$LAB/retry.log"
absent "$PARENT/state/mate1.meta"
absent "$G/locked"
absent "$H/data"
absent "$H/.fm-secondmate-home"
}

say 'S5: a handled TERM during the payload move restores the home for a retry'
interrupt_case s5-termsig TERM
say 'S5b: a handled INT during the payload move restores the home for a retry'
interrupt_case s5-intsig INT
say 'S5c: a handled HUP during the payload move restores the home for a retry'
interrupt_case s5-hupsig HUP

########################################################################
say 'S6: a failed seed rolls back its own protection and keeps earlier owned protection'
mklab s6 || exit 1
H="$LAB/home2"
git -C "$CODE" worktree add --quiet --detach "$H" HEAD || exit 1
G=$(gitdir_of "$H")
if product FM_SECONDMATE_CHARTER='' bash "$CODE/bin/fm-home-seed.sh" retry "$H" --no-projects \
  > "$LAB/seed-missing-charter.log" 2>&1; then
  bad 'seed accepted an absent charter'
else
  ok 'seed refused an absent charter'
fi
cat "$LAB/seed-missing-charter.log"
absent "$G/locked"
absent "$G/firstmate-home-lock"
seed retry "$H" > "$LAB/seed-ok.log" 2>&1
check 'the seed retry on the same worktree succeeded' [ "$?" = 0 ]
reason=$(cat "$G/locked")
cp "$G/firstmate-home-lock" "$LAB/receipt"
printf 'retained\n' > "$H/projects/retained"
if seed retry "$H" > "$LAB/seed-fail-again.log" 2>&1; then
  bad 'repeat seed accepted a populated projectless home'
else
  ok 'repeat seed refused a populated projectless home'
fi
cat "$LAB/seed-fail-again.log"
check 'the failed repeat seed kept the earlier owned lock' [ "$(cat "$G/locked")" = "$reason" ]
check 'the failed repeat seed kept the earlier receipt' [ "$(cat "$G/firstmate-home-lock")" = "$(cat "$LAB/receipt")" ]

########################################################################
say 'S7: a home whose tree tracks payload paths refuses the return and keeps its checkout'
mklab s7 || exit 1
seed mate1 - > "$LAB/seed.log" 2>&1
H=$(sed -n 's/^home=//p' "$LAB/seed.log")
G=$(gitdir_of "$H")
write_meta mate1 "$H"
reason=$(cat "$G/locked")
git -C "$H" add -f data/charter.md
if teardown mate1 > "$LAB/tracked.log" 2>&1; then
  bad 'retirement retired a home whose tree tracks payload paths'
else
  ok 'retirement refused a home whose tree tracks payload paths'
fi
cat "$LAB/tracked.log"
has "$LAB/tracked.log" 'tracks payload paths' 'the refusal names the tracked payload'
check 'the refused cleanup kept protection' [ "$(cat "$G/locked")" = "$reason" ]
present "$PARENT/state/mate1.meta"
present "$H/data/charter.md"
( cd "$CODE" && treehouse status ) > "$LAB/status.log" 2>&1
has "$LAB/status.log" 'leased' 'the refused cleanup did not return the slot'
git -C "$H" reset -q
teardown mate1 > "$LAB/retry.log" 2>&1
check 'the retried retirement after clearing the index succeeded' [ "$?" = 0 ]
absent "$G/locked"
absent "$H/data"

printf '\n=== summary: %s failing assertion(s)\n' "$FAILS"
exit "$FAILS"
