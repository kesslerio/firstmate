#!/usr/bin/env bash
# Evidence driver: MAIN's real drain keeps an older ready-work handoff visible
# until MAIN acknowledges it, even when a newer outcome for the same task omits
# it.
#
# Disposable: marked lab home under /tmp, removed on exit. The only seam is the
# fake harness (a bash symlink named claude) that makes the calling session a
# main session; the drain, the outcome store, and the acknowledgement are the
# real scripts.
set -u

ROOT=/home/art/.no-mistakes/worktrees/9f75ec418609/01M68G6B7Q26A53RVVPP9NH5H3
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
RESULT=0

cleanup_all() {
  "$ROOT/bin/fm-lab-home.sh" teardown "$LAB/home" >/dev/null 2>&1 || true
  rm -rf "$LAB"
}
trap cleanup_all EXIT

fail() { printf 'NOT OK: %s\n' "$1" >&2; RESULT=1; }
ok() { printf 'ok: %s\n' "$1"; }

mkdir -p "$LAB/fakebin"
ln -s /bin/bash "$LAB/fakebin/claude"
FAKE_CLAUDE="$LAB/fakebin/claude"
HOME_DIR="$LAB/home"
"$ROOT/bin/fm-lab-home.sh" create "$HOME_DIR" >/dev/null || exit 1
: > "$HOME_DIR/config/supervision-host"

drain() {
  FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$FAKE_CLAUDE" -c '"$0" 2>&1' \
    "$ROOT/bin/fm-wake-drain.sh"
}

FM_HOME="$HOME_DIR" "$ROOT/bin/fm-branch-outcome.sh" append --task source --verdict captain \
  --summary 'ready-work handoff: dispatch unit-next; its dependency landed' >/dev/null \
  || fail 'could not record the older handoff'
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-branch-outcome.sh" append --task source --verdict captain \
  --summary 'source task finished; no new handoff' >/dev/null \
  || fail 'could not record the newer summary'

if FM_HOME="$HOME_DIR" "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through 2 >/dev/null 2>&1; then
  fail 'an unpresented handoff was acknowledged'
else
  ok 'an unpresented handoff cannot be acknowledged'
fi

echo '--- first drain ---'
first=$(drain)
printf '%s\n' "$first"
printf '%s\n' "$first" | grep -q 'ready-work handoff: dispatch unit-next' \
  && ok 'the first drain presents the older ready-work handoff' \
  || fail 'the newer summary hid the older ready unit'
printf '%s\n' "$first" | grep -q 'mark-processed --through 2;' \
  && ok 'the presentation names the acknowledgement covering both rows' \
  || fail 'the presented run could not be acknowledged as a whole'
printf '%s\n' "$first" | grep -q 'before acknowledging any outcome' \
  && ok 'the presentation carries the ready-work handoff instruction' \
  || fail 'the presentation lost the ready-work instruction'

echo '--- second drain before acknowledgement ---'
second=$(drain)
printf '%s\n' "$second" | grep -q 'dispatch unit-next' \
  && ok 'the unprocessed handoff is presented again in full' \
  || fail 'an unprocessed handoff was lost'

FM_HOME="$HOME_DIR" "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through 2 >/dev/null \
  || fail 'the presented outcomes could not be acknowledged'
ok 'MAIN acknowledged both presented outcomes'

echo '--- drain after acknowledgement ---'
third=$(drain)
if printf '%s\n' "$third" | grep -q 'dispatch unit-next'; then
  fail 'the acknowledged handoff repeated'
else
  ok 'the acknowledged handoff does not repeat'
fi
pending=$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-branch-outcome.sh" unprocessed)
[ -z "$pending" ] && ok 'nothing remains pending' || fail 'acknowledged outcomes stayed pending'

exit "$RESULT"
