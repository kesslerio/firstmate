#!/usr/bin/env bash
set -eu
ROOT=$PWD
E=/home/art/.no-mistakes/evidence/01M4BGQYGGV94BM61ERP44DRTK
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TASKS_AXI_FILE TASKS_AXI_BACKEND
export TMPDIR="$ROOT/.v/tmp"
# The real watcher is the runtime, and all backlog/state calls are real tools.
for mode in ready empty held; do
 home="$ROOT/.v/manual/$mode"
 "$ROOT/bin/fm-lab-home.sh" create "$home" >/dev/null
 cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
 export FM_HOME="$home"
 printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
 if [ "$mode" != empty ]; then
  "$ROOT/bin/fm-tasks-axi.sh" add next 'dependency-cleared next unit' >/dev/null
  "$ROOT/bin/fm-tasks-axi.sh" add dep 'landed dependency' >/dev/null
  "$ROOT/bin/fm-tasks-axi.sh" block next --by dep >/dev/null
  "$ROOT/bin/fm-tasks-axi.sh" 'done' dep --pr https://github.com/example/lab/pull/1 >/dev/null
 fi
 if [ "$mode" = held ]; then
  "$ROOT/bin/fm-captain-hold.sh" hold next --reason 'captain credential decision' >/dev/null
 fi
 { echo "SCENARIO $mode"; "$ROOT/bin/fm-tasks-axi.sh" ready; } > "$E/watch-$mode.log"
 FM_POLL=0.2 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$ROOT/bin/fm-watch.sh" > "$home/watch.out" 2> "$home/watch.err" &
 pid=$!
 for ((i=0;i<80;i++)); do
  [ -s "$home/watch.out" ] && break
  [ "$(cat "$home/state/.heartbeat-streak" 2>/dev/null || echo 0)" -ge 1 ] && break
  sleep .1
 done
 kill -TERM "$pid" 2>/dev/null || true
 wait "$pid" || rc=$?
 { cat "$home/watch.out"; cat "$home/watch.err"; "$ROOT/bin/fm-wake-drain.sh"; printf 'heartbeat-streak: '; cat "$home/state/.heartbeat-streak"; } >> "$E/watch-$mode.log" 2>&1
 if [ "$mode" = ready ]; then [ "$(cat "$home/watch.out")" = heartbeat ]; else [ ! -s "$home/watch.out" ] && [ ! -s "$home/state/.wake-queue" ]; fi
 done
