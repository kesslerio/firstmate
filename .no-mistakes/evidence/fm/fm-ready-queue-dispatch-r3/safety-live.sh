#!/usr/bin/env bash
set -eu
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_TEST_SEAM FM_TEST_HARNESS
export FM_HOME="$PWD/.phase/safety-home"
bin/fm-lab-home.sh create "$FM_HOME" >/dev/null
trap 'rm -rf "$FM_HOME"' EXIT
cp .tasks.toml "$FM_HOME/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$FM_HOME/data/backlog.md"
bin/fm-tasks-axi.sh add next 'ready unit'
STATE="$FM_HOME/state"
. bin/fm-wake-lib.sh
fm_wake_append heartbeat heartbeat heartbeat
mkdir "$STATE/.subsuper-escalations"
printf '\nFAILED HANDOFF MUST KEEP WAKE\n'
(
 . bin/fm-supervise-daemon.sh
 LOG="$FM_HOME/state/daemon.log"
 if handle_durable_wakes heartbeat "$FM_HOME/state"; then exit 3; fi
)
bin/fm-wake-drain.sh
rmdir "$STATE/.subsuper-escalations"
(
 . bin/fm-supervise-daemon.sh
 LOG="$FM_HOME/state/daemon.log"
 handle_durable_wakes heartbeat "$FM_HOME/state"
)
printf '\nRETRY HANDOFF\n'; cat "$STATE/.subsuper-escalations"
bin/fm-captain-hold.sh hold next --reason 'explicit captain hold'
printf '\nONLY HELD WORK\n'; bin/fm-tasks-axi.sh ready
FM_POLL=0.2 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 bin/fm-watch.sh > "$FM_HOME/watch.out" &
pid=$!
for ((i=0;i<80;i++)); do
 [ "$(cat "$STATE/.heartbeat-streak" 2>/dev/null || echo 0)" -ge 1 ] && break
 sleep 0.1
done
kill -TERM "$pid" 2>/dev/null || true
wait "$pid" || true
printf 'heartbeat_streak='; cat "$STATE/.heartbeat-streak"
printf 'watch_output_bytes='; wc -c < "$FM_HOME/watch.out"
printf 'wake_queue_bytes='; wc -c < "$STATE/.wake-queue"
