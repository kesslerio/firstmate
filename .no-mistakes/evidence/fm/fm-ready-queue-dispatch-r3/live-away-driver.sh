#!/usr/bin/env bash
set -eu
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_TEST_SEAM TASKS_AXI_FILE TASKS_AXI_BACKEND
ROOT=$PWD
export FM_HOME="$ROOT/.validation/away-home"
"$ROOT/bin/fm-lab-home.sh" create "$FM_HOME"
cp "$ROOT/.tasks.toml" "$FM_HOME/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$FM_HOME/data/backlog.md"
"$ROOT/bin/fm-tasks-axi.sh" add other 'out of scope ready unit'
"$ROOT/bin/fm-afk-contract.sh" enter --spend 4 --words 'No dispatch is authorized. Do not merge, push, open a PR, or change global configuration.'
STATE="$FM_HOME/state"
FM_ROOT="$ROOT"
export FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=away-review FM_LEASE_HOLDER_PID=$$
printf '%s\n' "$$" > "$STATE/.lock"
printf 'turn=away-review\nunscoped=1\nrows=\ntasks=\nwake=heartbeat\nposture=away\n' > "$STATE/.supervision-host-turn"
. "$ROOT/bin/fm-wake-lib.sh"
fm_wake_append heartbeat heartbeat heartbeat
"$ROOT/bin/fm-wake-grant.sh" activate "$$" away-review
rows=$(awk -F '\t' '{print $2}' "$STATE/.wake-queue")
"$ROOT/bin/fm-wake-grant.sh" publish away-review $rows
"$ROOT/bin/fm-afk-contract.sh" readback > "$FM_HOME/readback"
"$ROOT/bin/fm-branch-prompt.sh" > "$FM_HOME/prompt"
printf 'heartbeat\n' | "$ROOT/bin/fm-branch-dispatch.mjs" wake-prompt --report bin/fm-branch-report.sh --away --readback-file "$FM_HOME/readback" > "$FM_HOME/wake"
. "$ROOT/bin/fm-supervision-engine-lib.sh"
. "$ROOT/bin/fm-timeout-lib.sh"
session=$(python3 -c 'import uuid; print(uuid.uuid4())')
fm_supervision_engine_turn claude sonnet "$FM_HOME/prompt" "$FM_HOME/wake" "$session" new 180 "$FM_HOME/result.json" "$FM_HOME/errors"
cat "$FM_HOME/result.json"
"$ROOT/bin/fm-tasks-axi.sh" show other --full
cat "$STATE/branch-outcomes.jsonl"
test ! -s "$STATE/.wake-queue"
test ! -e "$STATE/other.meta"
