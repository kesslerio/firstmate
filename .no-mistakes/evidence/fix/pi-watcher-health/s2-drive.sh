#!/usr/bin/env bash
# Scenario 2 (live, adversarial): the real bin/fm-watch.sh is pointed at a
# TMPDIR whose private snapshot root is a symlink to a victim directory, and
# whose legacy PID-prefixed snapshot names include a symlink swap plus a legit
# leftover directory. The watcher must never write through or delete the
# symlinked targets, must still honor the open-decision denial, and must still
# sweep the legitimate legacy leftover at exit.
set -u
ROOT=${ROOT:?}
EVID=${EVID:?}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmp" "$LAB/state/pending-replies"
touch "$LAB/config/wait-no-turns"
uid=$(id -u)
now=$(date +%s)
TMP="$LAB/tmp"
status="$LAB/state/t1.status"
printf 'needs-decision [key=color]: pick a color\n' > "$status"
rec="$LAB/state/pending-replies/aaaaaaaaaaaaaaaa"
cat > "$rec" <<EOF
schema=1
corr_id=aaaaaaaaaaaaaaaa
task_id=t1
parent_home=$LAB
parent_status=$status
request_summary=demo request needing an open decision
created_epoch=$((now-7200))
delivered_epoch=$((now-7100))
phase=awaiting_report
turn_seen_busy=0
request_turn_completed_epoch=$((now-7000))
recovery_attempted_epoch=
recovery_sender_pid=
recovery_sender_identity=
recovery_sent_epoch=
recovery_delivery_outcome=
recovery_turn_seen_busy=0
recovery_turn_completed_epoch=
escalated_epoch=
resolved_epoch=
resolved_via=
wrong_home_hits=0
grace_secs=60
EOF
chmod 600 "$rec"

# Victim for the private-root symlink: a directory a naive sweep could delete.
victimA="$LAB/victimA"
mkdir -p "$victimA"
printf 'private snap\n' > "$victimA/0"
printf 'secret-a\n' > "$victimA/secret.txt"
ln -s "$victimA" "$TMP/fm-pending-reply-$uid"

# Victim for the legacy PID-prefixed symlink swap.
victimB="$LAB/victimB"
mkdir -p "$victimB"
printf 'secret-b\n' > "$victimB/keep.txt"

env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB" TMPDIR="$TMP" FM_POLL=1 bash "$ROOT/bin/fm-watch.sh" \
    > "$LAB/watch.log" 2>&1 &
watch=$!
sleep 0.5
# Name the legacy shapes with the watcher's own pid, exactly as an interrupted
# older tick left them.
ln -s "$victimB" "$TMP/fm-pending-reply-decisions.$watch.swap"
mkdir -p "$TMP/fm-pending-reply-decisions.$watch.legacy"
printf 'leftover snapshot\n' > "$TMP/fm-pending-reply-decisions.$watch.legacy/0"
sleep 12
kill -TERM "$watch" 2>/dev/null
wait "$watch" 2>/dev/null
sleep 1

{
  echo "== victimA (private-root symlink target) =="
  ls -la "$victimA"
  find "$victimA" -type f -exec sh -c 'echo "-- $1"; cat "$1"' _ {} \;
  echo "== private root path =="
  ls -ld "$TMP/fm-pending-reply-$uid"
  echo "== victimB (legacy symlink target) =="
  ls -la "$victimB"
  cat "$victimB/keep.txt"
  echo "== legacy symlink path =="
  ls -ld "$TMP/fm-pending-reply-decisions.$watch.swap"
  echo "== legit legacy leftover dir (must be gone) =="
  ls -ld "$TMP/fm-pending-reply-decisions.$watch.legacy" 2>&1
  echo "== TMPDIR after exit =="
  ls -la "$TMP"
  echo "== pending record phase (denial must still hold) =="
  grep -E '^(phase|recovery_attempted_epoch|recovery_delivery_outcome)=' "$rec"
  echo "== watcher log =="
  cat "$LAB/watch.log"
} > "$EVID/s2-post.sh.out" 2>&1
echo "LAB=$LAB watcher_pid=$watch"
