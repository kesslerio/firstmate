#!/usr/bin/env bash
set -eu
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_TEST_SEAM FM_TEST_HARNESS
export FM_HOME="$PWD/.phase/interface-home"
bin/fm-lab-home.sh create "$FM_HOME" >/dev/null
trap 'rm -rf "$FM_HOME"' EXIT
cp .tasks.toml "$FM_HOME/.tasks.toml"
touch "$FM_HOME/config/supervision-host"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$FM_HOME/data/backlog.md"
bin/fm-tasks-axi.sh add dependency 'landed predecessor'
bin/fm-tasks-axi.sh add next 'queued note without worker'
bin/fm-tasks-axi.sh add sibling 'independent ready sibling'
bin/fm-tasks-axi.sh add held 'captain lane'
bin/fm-tasks-axi.sh block next --by dependency
bin/fm-captain-hold.sh hold held --reason 'design decision'
printf '\nBEFORE LANDING\n'; bin/fm-tasks-axi.sh ready
bin/fm-tasks-axi.sh 'done' dependency --pr https://github.com/example/fixture/pull/1
printf '\nAFTER LANDING\n'; bin/fm-tasks-axi.sh ready
printf '\nWATCHER WITHOUT NEW STATUS EVENTS\n'
FM_POLL=0.2 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 timeout -k 5s 25s bin/fm-watch.sh
printf '\nDAEMON DURABLE HANDOFF\n'
(
 . bin/fm-supervise-daemon.sh
 LOG="$FM_HOME/state/daemon.log"
 FM_INJECT_SKIP=heartbeat FM_ESCALATE_BATCH_SECS=90 handle_durable_wakes heartbeat "$FM_HOME/state"
)
cat "$FM_HOME/state/.subsuper-escalations"
printf 'wake_remaining='; wc -c < "$FM_HOME/state/.wake-queue"
printf '\nOLDER HANDOFF AND NEWER OUTCOME\n'
bin/fm-branch-outcome.sh append --task source --verdict captain --summary 'ready-work handoff: dispatch next and sibling; dependencies landed'
bin/fm-branch-outcome.sh append --task source --verdict captain --summary 'source finished; no new handoff'
if bin/fm-branch-outcome.sh mark-processed --through 2; then exit 3; fi
bin/fm-wake-drain.sh
bin/fm-wake-drain.sh
bin/fm-branch-outcome.sh mark-processed --through 2
printf '\nLONG HANDOFF\n'
pad=$(python3 -c 'print("x"*4500)')
bin/fm-branch-outcome.sh append --task source --verdict captain --summary "ready-work handoff: dispatch first; $pad; dispatch last"
bin/fm-branch-outcome.sh append --task source --verdict captain --summary 'newer source update'
bin/fm-wake-drain.sh
bin/fm-branch-outcome.sh mark-processed --through 3
bin/fm-wake-drain.sh
