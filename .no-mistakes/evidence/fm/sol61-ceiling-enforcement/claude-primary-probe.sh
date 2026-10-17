#!/usr/bin/env bash
set -eu
E=/home/art/.no-mistakes/evidence/01M5416CTFJVDPWBPVA1J6A66S
LAB=$E/h
bin/fm-lab-home.sh create "$LAB" >/dev/null
mkdir -p "$LAB/tmux"
cleanup() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null || true; rm -rf "$LAB"; }
trap cleanup EXIT
unset TMUX
export TMUX_TMPDIR="$LAB/tmux"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -x 120 -y 40 -c "$PWD" -e FM_HOME="$LAB" claude
sleep 4
tmux -L fm-lab capture-pane -p -t primary > "$E/claude-primary.txt"
cat "$E/claude-primary.txt"
