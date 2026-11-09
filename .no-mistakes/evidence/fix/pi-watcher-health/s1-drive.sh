#!/usr/bin/env bash
# Scenario 1 (live): real bin/fm-watch.sh in a disposable lab home with
# config/wait-no-turns and pending-reply records that hit the open-decision
# denial path. Observes where the per-tick decision snapshots live.
set -u
ROOT=${ROOT:?}
EVID=${EVID:?}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmp" "$LAB/state/pending-replies"
touch "$LAB/config/wait-no-turns"
uid=$(id -u)
now=$(date +%s)
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
# 20 further records so one tick keeps its cache directory alive long enough
# for an independent observer loop to read it.
for i in $(seq 1 20); do
  id=$(printf 'b%015d' "$i")
  s="$LAB/state/t2.status"
  printf 'needs-decision [key=color]: pick a color\n' > "$s"
  sed -e "s/aaaaaaaaaaaaaaaa/$id/" -e "s/^task_id=.*/task_id=t2/" "$rec" > "$LAB/state/pending-replies/$id"
done

TMP="$LAB/tmp"
OBS="$EVID/s1-observer.log"
: > "$OBS"
(
  while :; do
    if [ -d "$TMP" ]; then
      for d in "$TMP"/fm-pending-reply-decisions.*; do
        [ -e "$d" ] || continue
        printf 'legacy-path-dir %s\n' "$d" >> "$OBS"
      done
      root="$TMP/fm-pending-reply-$uid"
      if [ -L "$root" ]; then
        printf 'root-symlink %s\n' "$root" >> "$OBS"
      elif [ -d "$root" ]; then
        mode=$(stat -c '%a' "$root" 2>/dev/null)
        own=$(stat -c '%u' "$root" 2>/dev/null)
        printf 'root mode=%s owner=%s\n' "$mode" "$own" >> "$OBS"
        for d in "$root"/fm-pending-reply-decisions.*; do
          [ -d "$d" ] || continue
          printf 'snapshot-dir %s contents=%s\n' "$d" "$(ls -A "$d" | tr '\n' ' ')" >> "$OBS"
        done
      fi
    fi
  done
) &
obs=$!

env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB" TMPDIR="$TMP" FM_POLL=1 bash "$ROOT/bin/fm-watch.sh" \
    > "$LAB/watch.log" 2>&1 &
watch=$!
sleep 25
kill -TERM "$watch" 2>/dev/null
wait "$watch" 2>/dev/null
sleep 1
kill -TERM "$obs" 2>/dev/null
wait "$obs" 2>/dev/null

sort -u "$OBS" > "$EVID/s1-observer-uniq.log"
{
  echo "== watcher log =="
  cat "$LAB/watch.log"
  echo "== TMPDIR after watcher exit =="
  ls -la "$TMP"
  echo "== record phase =="
  grep -E '^(phase|recovery_attempted_epoch|recovery_delivery_outcome)=' "$rec"
  echo "== status file unchanged =="
  cat "$status"
} > "$EVID/s1-post.sh.out" 2>&1
echo "LAB=$LAB"
