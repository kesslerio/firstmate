#!/usr/bin/env bash
set -u
ROOT=$PWD
E=/home/art/.no-mistakes/evidence/01M4B0WCFKS0F03ZZ5EPCCQ72P
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE TMUX TMUX_PANE
export FM_HOME="$ROOT/.lab"
STATE="$FM_HOME/state"
export TMUX_TMPDIR="$FM_HOME/tmux"
export TMUX="$(tmux -L fm-lab display-message -p '#{socket_path}'),0,0" FM_BACKEND=tmux
FM_ROOT=$ROOT
export FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=live-away-review
# Disposable host-turn input record, consumed by the real report endpoint.
printf 'turn=live-away-review\nunscoped=1\nrows=\ntasks=\nwake=heartbeat\nposture=away\n' > "$STATE/.supervision-host-turn"
. bin/fm-wake-lib.sh
fm_wake_append heartbeat heartbeat heartbeat
bin/fm-wake-grant.sh activate "$$" live-away-review || exit 1
rows=$(awk -F "\t" '{ print $2 }' "$STATE/.wake-queue")
bin/fm-wake-grant.sh publish live-away-review $rows || exit 1
bin/fm-afk-contract.sh readback > "$E/away-readback.txt"
bin/fm-branch-prompt.sh > "$E/agent-prompt.txt"
printf 'heartbeat\n' | bin/fm-branch-dispatch.mjs wake-prompt --report 'bin/fm-branch-report.sh' --away --readback-file "$E/away-readback.txt" > "$E/away-wake.txt"
. bin/fm-supervision-engine-lib.sh
. bin/fm-timeout-lib.sh
export TMPDIR="$ROOT/.test-tmp"
session=$(python -c 'import uuid; print(uuid.uuid4())')
fm_supervision_engine_turn claude sonnet "$E/agent-prompt.txt" "$E/away-wake.txt" "$session" new 160 "$E/away-result.json" "$E/away-errors.txt"
rc=$?
printf 'engine_exit=%s\n' "$rc"
[ ! -e "$STATE/branch-outcomes.jsonl" ] || cat "$STATE/branch-outcomes.jsonl" > "$E/away-outcomes.jsonl"
exit "$rc"
