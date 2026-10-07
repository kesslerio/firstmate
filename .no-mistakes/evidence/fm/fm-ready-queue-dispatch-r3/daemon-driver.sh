#!/usr/bin/env bash
set -eu
ROOT=$PWD
E=/home/art/.no-mistakes/evidence/01M4BGQYGGV94BM61ERP44DRTK
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TASKS_AXI_FILE TASKS_AXI_BACKEND
export TMPDIR="$ROOT/.v/tmp"
export TMUX_TMPDIR="$ROOT/.l/tmux"
export TMUX="$(tmux -L fm-lab display-message -p -t primary '#{socket_path}'),0,0"
for mode in ready held empty failed; do
 home="$ROOT/.v/manual/daemon-$mode"
 "$ROOT/bin/fm-lab-home.sh" create "$home" >/dev/null
 cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
 export FM_HOME="$home"
 printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
 printf 'mode: quiet\n' > "$home/state/.afk"
 if [ "$mode" != empty ]; then
  "$ROOT/bin/fm-tasks-axi.sh" add next 'dependency-cleared next unit' >/dev/null
  "$ROOT/bin/fm-tasks-axi.sh" add dep 'landed dependency' >/dev/null
  "$ROOT/bin/fm-tasks-axi.sh" block next --by dep >/dev/null
  "$ROOT/bin/fm-tasks-axi.sh" 'done' dep --pr https://github.com/example/lab/pull/1 >/dev/null
 fi
 if [ "$mode" = held ]; then "$ROOT/bin/fm-captain-hold.sh" hold next --reason 'captain design pick' >/dev/null; fi
 if [ "$mode" = failed ]; then mkdir "$home/state/.subsuper-escalations"; fi
 FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET=primary:0 FM_POLL=.2 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 FM_ESCALATE_BATCH_SECS=9999 FM_WEDGE_ALARM_EXEC=discard timeout -k 3 8 "$ROOT/bin/fm-supervise-daemon.sh" > "$home/daemon.out" 2> "$home/daemon.err" || rc=$?
 { echo "SCENARIO daemon-$mode"; "$ROOT/bin/fm-tasks-axi.sh" ready; cat "$home/daemon.out" "$home/daemon.err" "$home/state/.supervise-daemon.log"; echo 'DURABLE HANDOFF'; if [ -f "$home/state/.subsuper-escalations" ]; then cat "$home/state/.subsuper-escalations"; fi; echo 'PENDING WAKE'; cat "$home/state/.wake-queue" 2>/dev/null || true; } > "$E/daemon-$mode.log"
 case "$mode" in
 ready) test -s "$home/state/.subsuper-escalations" ;;
 empty|held) test ! -s "$home/state/.subsuper-escalations" ;;
 failed) test -s "$home/state/.wake-queue" ;;
 esac
 done
