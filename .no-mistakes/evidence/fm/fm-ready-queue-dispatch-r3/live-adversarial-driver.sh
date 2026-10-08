#!/usr/bin/env bash
set -eu
ROOT=$PWD
EV=/home/art/.no-mistakes/evidence/01M4EQXX97HJEM6W27NF7DPAB6
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TASKS_AXI_FILE TASKS_AXI_BACKEND FM_GATE_REFUSE_BYPASS FM_TEST_SEAM
export FM_HOME="$ROOT/.validation/edge-home-rerun"
"$ROOT/bin/fm-lab-home.sh" create "$FM_HOME"
cp .tasks.toml "$FM_HOME/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$FM_HOME/data/backlog.md"
set +e
FM_POLL=0.2 FM_HEARTBEAT=1 FM_CHECK_INTERVAL=999999 timeout -k 5s 4s "$ROOT/bin/fm-watch.sh" > "$EV/live-empty-watcher.txt"
rc=$?
set -e
test "$rc" = 124
test ! -s "$EV/live-empty-watcher.txt"
test ! -s "$FM_HOME/state/.wake-queue"
printf 'LIVE empty queue: reviewed without wake\n'
export FM_HOME="$ROOT/.validation/unavailable-home"
"$ROOT/bin/fm-lab-home.sh" create "$FM_HOME"
cp .tasks.toml "$FM_HOME/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$FM_HOME/data/backlog.md"
printf 'backend = "unavailable-backend"\n' > "$FM_HOME/.tasks.toml"
FM_POLL=0.2 FM_HEARTBEAT=1 FM_CHECK_INTERVAL=999999 timeout -k 5s 20s "$ROOT/bin/fm-watch.sh" > "$EV/live-unavailable-watcher.txt"
cat "$EV/live-unavailable-watcher.txt"
grep -qx heartbeat "$EV/live-unavailable-watcher.txt"
mkdir "$FM_HOME/state/.subsuper-escalations"
(
  . "$ROOT/bin/fm-supervise-daemon.sh"
  LOG="$FM_HOME/state/daemon.log"
  if FM_ESCALATE_BATCH_SECS=90 handle_durable_wakes heartbeat "$FM_HOME/state"; then exit 1; fi
)
cat "$FM_HOME/state/.wake-queue"
test -s "$FM_HOME/state/.wake-queue"
cat "$FM_HOME/state/daemon.log"
printf 'LIVE unavailable readiness: heartbeat surfaced; refused handoff retained durable wake\n'
