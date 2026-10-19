#!/usr/bin/env bash
set -eu
LAB=$(mktemp -d "$PWD/.pXXXXXX")
cleanup() {
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT
bin/fm-lab-home.sh create "$LAB"
mkdir -p "$LAB/tmux"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -x 120 -y 40 -c "$PWD" -e FM_HOME="$LAB" codex
sleep 6
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab capture-pane -p -t primary
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab list-panes -t primary -F 'pane_pid=#{pane_pid} size=#{pane_width}x#{pane_height}'
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server
sleep 1
if TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab list-sessions 2>/dev/null; then exit 1; fi
printf 'Private tmux server stopped; lab cleanup follows.\n'
