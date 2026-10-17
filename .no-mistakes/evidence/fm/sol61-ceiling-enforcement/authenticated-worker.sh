#!/usr/bin/env bash
set -eu
E=/home/art/.no-mistakes/evidence/01M5416CTFJVDPWBPVA1J6A66S
LAB=$E/h
bin/fm-lab-home.sh create "$LAB" >/dev/null
mkdir -p "$LAB/tmux"
cleanup() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null || true; rm -rf "$LAB"; }
trap cleanup EXIT
unset TMUX FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
export TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB"
printf '%s\n' '{"rules":[{"when":"Sol","use":{"harness":"codex","model":"gpt-6.1-sol"}}]}' > "$LAB/config/crew-dispatch.json"
bash bin/fm-sol-cap-lib.sh refuse-claim authenticated ship codex gpt-6.1-sol "$LAB/config" "$LAB/state"
# Use the launch-hook interface with the same hook disabling flag used by real ship launches.
tmux -L fm-lab new-session -d -s primary -n agent -x 120 -y 40 -c "$PWD" -e FM_HOME="$LAB" "bash '$PWD/bin/fm-sol-cap-lib.sh' run authenticated '$LAB/state' codex --disable hooks --model gpt-6.1-sol 'Reply only OK. Do not use tools or modify any files.'"
sleep 12
tmux -L fm-lab capture-pane -p -S -100 -t primary:agent > "$E/authenticated-worker.txt"
cat "$E/authenticated-worker.txt"
cat "$LAB/state/sol-sessions.tsv"
