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
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -n agent -x 120 -y 40 -c "$PWD" -e FM_HOME="$LAB" codex
sleep 3
tmux -L fm-lab send-keys -t primary:agent Escape
sleep 3
tmux -L fm-lab capture-pane -p -t primary:agent > "$E/codex-primary-after-skip.txt"
cat "$E/codex-primary-after-skip.txt"
tmux -L fm-lab new-window -d -t primary: -n keepalive -c "$PWD" bash
export TMUX=$(tmux -L fm-lab display-message -p -t primary:agent '#{socket_path}'),0,0
printf '%s\n' '{"rules":[{"when":"Sol","use":{"harness":"codex","model":"gpt-6.1-sol"}}]}' > "$LAB/config/crew-dispatch.json"
printf '%s\n' window=primary:agent model=gpt-6.1-sol kind=ship harness=codex > "$LAB/state/preserved.meta"
. bin/fm-wake-lib.sh
. bin/fm-secondmate-registry-lib.sh
. bin/fm-backend.sh
. bin/fm-sol-cap-lib.sh
printf 'Live endpoint verdict: '; fm_backend_agent_state tmux primary:agent; printf '\n'
fm_sol_cap_model_set "$LAB/config"
fm_sol_cap_active_count "$LAB/state"
printf 'Adopted count: %s\n' "$FM_SOL_COUNT"
cat "$LAB/state/sol-sessions.tsv"
[ "$FM_SOL_COUNT" = 1 ]
[ "$(awk -F '\t' '$1=="preserved" {print $4}' "$LAB/state/sol-sessions.tsv")" = -2 ]
bash bin/fm-sol-cap-lib.sh record-actual preserved gpt-6.1-sol "$LAB/state"
[ "$(awk -F '\t' '$1=="preserved" {print $4}' "$LAB/state/sol-sessions.tsv")" = -2 ]
printf 'Confirmed route report retained adopted reconciliation\n'
# Stop precisely this owned lab endpoint; keepalive preserves the private server.
tmux -L fm-lab respawn-window -k -t primary:agent bash
sleep 1
printf 'Stopped endpoint verdict: '; fm_backend_agent_state tmux primary:agent; printf '\n'
fm_sol_cap_active_count "$LAB/state"
printf 'Count after confirmed worker stop: %s\n' "$FM_SOL_COUNT"
cat "$LAB/state/sol-sessions.tsv"
[ "$FM_SOL_COUNT" = 0 ]
fm_sol_cap_active_count "$LAB/state"
[ "$FM_SOL_COUNT" = 0 ]
printf 'Repeated admission retained confirmed-stop evidence\n'
