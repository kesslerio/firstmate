#!/usr/bin/env bash
# Scenario 3 (live): an interrupted tick's decision snapshot (a snapshot dir
# named with the running watcher's pid, left under the private root) is removed
# by the real watcher's own exit cleanup when it receives TERM.
set -u
ROOT=${ROOT:?}
EVID=${EVID:?}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmp" "$LAB/state/pending-replies"
touch "$LAB/config/wait-no-turns"
uid=$(id -u)
TMP="$LAB/tmp"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB" TMPDIR="$TMP" FM_POLL=1 bash "$ROOT/bin/fm-watch.sh" \
    > "$LAB/watch.log" 2>&1 &
watch=$!
sleep 1
root="$TMP/fm-pending-reply-$uid"
mkdir -p "$root/fm-pending-reply-decisions.$watch.abandoned"
printf 'interrupted snapshot payload\n' > "$root/fm-pending-reply-decisions.$watch.abandoned/0"
{
  echo "== planted interrupted snapshot before TERM =="
  ls -la "$root"
  cat "$root/fm-pending-reply-decisions.$watch.abandoned/0"
} > "$EVID/s3-before.txt" 2>&1
kill -TERM "$watch" 2>/dev/null
wait "$watch" 2>/dev/null
sleep 1
{
  echo "== TMPDIR after TERM cleanup (must hold no snapshot dirs) =="
  ls -la "$TMP"
  echo "== watcher log =="
  cat "$LAB/watch.log"
} > "$EVID/s3-post.sh.out" 2>&1
echo "LAB=$LAB watcher_pid=$watch"
