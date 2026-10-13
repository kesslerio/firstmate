#!/usr/bin/env bash
set -euo pipefail
unset HERDR_SOCKET_PATH HERDR_PANE_ID HERDR_WORKSPACE_ID HERDR_TAB_ID TMUX TMUX_PANE FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
export LAB_HELPER=$PWD/bin/fm-herdr-lab.sh LAB_PATH=$PATH
T=$(mktemp -d "$PWD/.test-labs/live-adoption.XXXXXX")
export FM_HERDR_LAB_STATE_DIR=$T/tripwire
export LAB_SESSION=$($LAB_HELPER name adoption)
export LAB_CLOSED=$T/closed LAB_HOST=$T/host
mkdir -p "$LAB_HOST"
cleanup() { "$LAB_HELPER" teardown "$LAB_SESSION"; rm -rf "$T"; }
trap cleanup EXIT
"$LAB_HELPER" provision "$LAB_SESSION"
read -r LAB_WORKSPACE LAB_TAB LAB_PANE < <("$LAB_HELPER" run "$LAB_SESSION" workspace create --cwd "$LAB_HOST" --label adoption --no-focus | jq -r '[.result.workspace.workspace_id,.result.tab.tab_id,.result.root_pane.pane_id]|join(" ")')
export LAB_WORKSPACE LAB_TAB LAB_PANE
"$LAB_HELPER" run "$LAB_SESSION" pane send-text "$LAB_PANE" "exec -a claude python3 -c 'import ctypes,time; ctypes.CDLL(None).prctl(15,b\"claude\",0,0,0); print(\"Synthetic adoption fixture\",flush=True); time.sleep(300)'"
"$LAB_HELPER" run "$LAB_SESSION" pane send-keys "$LAB_PANE" enter
sleep 1
"$LAB_HELPER" run "$LAB_SESSION" pane report-agent "$LAB_PANE" --source synthetic --agent claude --state idle
"$LAB_HELPER" run "$LAB_SESSION" pane process-info --pane "$LAB_PANE"
TMPDIR="$T" bash /home/art/.no-mistakes/evidence/01M4EGNATFWY186FV48C2W9EBR/head85-adoption-live-body.sh
