#!/usr/bin/env bash
set -eu
ROOT=$PWD
EV=/home/art/.no-mistakes/evidence/01M4EQXX97HJEM6W27NF7DPAB6
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TASKS_AXI_FILE TASKS_AXI_BACKEND FM_GATE_REFUSE_BYPASS FM_TEST_SEAM
export FM_HOME="$ROOT/.validation/core-home"
"$ROOT/bin/fm-lab-home.sh" create "$FM_HOME"
cp .tasks.toml "$FM_HOME/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$FM_HOME/data/backlog.md"
touch "$FM_HOME/config/supervision-host"
"$ROOT/bin/fm-tasks-axi.sh" add next 'stale spend stop now cleared'
"$ROOT/bin/fm-tasks-axi.sh" add dep 'dependency'
"$ROOT/bin/fm-tasks-axi.sh" block next --by dep
"$ROOT/bin/fm-tasks-axi.sh" done dep --pr https://github.com/example/fixture/pull/1
"$ROOT/bin/fm-tasks-axi.sh" ready
for form in absolute relative trailing; do
  (
    cd "$FM_HOME"
    case $form in absolute) export FM_DATA_OVERRIDE="$FM_HOME/data";; relative) export FM_DATA_OVERRIDE=data;; trailing) export FM_DATA_OVERRIDE="$FM_HOME/data/";; esac
    . "$ROOT/bin/fm-ready-queue-lib.sh"
    fm_ready_queue_needs_review
    printf 'LIVE addressing %s: landed dependency requires review\n' "$form"
  )
done
FM_POLL=0.2 FM_HEARTBEAT=1 FM_CHECK_INTERVAL=999999 timeout -k 5s 20s "$ROOT/bin/fm-watch.sh" > "$EV/live-watcher.txt"
cat "$EV/live-watcher.txt"
grep -qx heartbeat "$EV/live-watcher.txt"
(
  . "$ROOT/bin/fm-supervise-daemon.sh"
  LOG="$FM_HOME/state/daemon.log"
  FM_ESCALATE_BATCH_SECS=90 handle_durable_wakes heartbeat "$FM_HOME/state"
)
cat "$FM_HOME/state/.subsuper-escalations"
test ! -s "$FM_HOME/state/.wake-queue"
printf 'LIVE daemon: durable ready-work handoff exists before heartbeat acknowledgement\n'
"$ROOT/bin/fm-captain-hold.sh" hold next --reason 'live explicit hold'
"$ROOT/bin/fm-tasks-axi.sh" ready
(
  . "$ROOT/bin/fm-ready-queue-lib.sh"
  if fm_ready_queue_needs_review; then exit 1; fi
)
set +e
FM_POLL=0.2 FM_HEARTBEAT=1 FM_CHECK_INTERVAL=999999 timeout -k 5s 4s "$ROOT/bin/fm-watch.sh" > "$EV/live-held-watcher.txt"
rc=$?
set -e
test "$rc" = 124
test ! -s "$EV/live-held-watcher.txt"
test ! -s "$FM_HOME/state/.wake-queue"
printf 'LIVE held queue: reviewed but no heartbeat emitted\n'
"$ROOT/bin/fm-branch-outcome.sh" append --task source --verdict captain --summary 'ready-work handoff: dispatch unit-older; dependency landed'
pad=$(python3 -c 'print("x"*4500)')
"$ROOT/bin/fm-branch-outcome.sh" append --task source --verdict captain --summary "ready-work handoff: dispatch unit-first; $pad; dispatch unit-last"
"$ROOT/bin/fm-branch-outcome.sh" append --task source --verdict captain --summary 'source settled; no new handoff'
if "$ROOT/bin/fm-branch-outcome.sh" mark-processed --through 3; then exit 1; fi
"$ROOT/bin/fm-wake-drain.sh" > "$EV/live-drain-first.txt" 2>&1
cat "$EV/live-drain-first.txt"
grep -q 'dispatch unit-older' "$EV/live-drain-first.txt"
"$ROOT/bin/fm-branch-outcome.sh" mark-processed --through 1
"$ROOT/bin/fm-wake-drain.sh" > "$EV/live-drain-long.txt" 2>&1
cat "$EV/live-drain-long.txt"
grep -q 'dispatch unit-last' "$EV/live-drain-long.txt"
grep -q "$pad" "$EV/live-drain-long.txt"
"$ROOT/bin/fm-branch-outcome.sh" mark-processed --through 2
"$ROOT/bin/fm-wake-drain.sh" > "$EV/live-drain-final.txt" 2>&1
grep -q 'source settled' "$EV/live-drain-final.txt"
"$ROOT/bin/fm-branch-outcome.sh" mark-processed --through 3
test -z "$("$ROOT/bin/fm-branch-outcome.sh" unprocessed)"
printf 'LIVE drain: older and oversized handoffs presented completely; unseen acknowledgement refused\n'
