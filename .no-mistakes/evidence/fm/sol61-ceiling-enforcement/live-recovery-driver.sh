#!/usr/bin/env bash
set -eu
LAB=/home/art/.no-mistakes/evidence/01M53EGCQXW2H51Q8EPQ12MT36/h
bin/fm-lab-home.sh create "$LAB"
mkdir -p "$LAB/tmux"
cleanup() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null || true; rm -rf "$LAB"; }
trap cleanup EXIT
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -x 120 -y 40 -c "$PWD" bash
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-window -t primary -n fm-recover -c "$PWD" bash
SOCKET=$(TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab display-message -p -t primary '#{socket_path}')
export TMUX="$SOCKET,0,0" FM_HOME="$LAB"
source bin/fm-backend.sh
source bin/fm-wake-lib.sh
source bin/fm-secondmate-registry-lib.sh
source bin/fm-control-lib.sh
source bin/fm-sol-cap-lib.sh
printf 'backend=tmux\nwindow=primary:fm-recover\n' > "$LAB/state/recover.meta"
printf 'recover\tgpt-6.1-sol\t1\t0\n' > "$LAB/state/sol-sessions.tsv"
echo 'Real tmux endpoint state:'
fm_backend_agent_state tmux primary:fm-recover
fm_lock_try_acquire "$LAB/state/.spawn-recover.lock"
fm_sol_cap_reconcile_local recover "$LAB/state"
fm_lock_release "$LAB/state/.spawn-recover.lock"
[ ! -s "$LAB/state/sol-sessions.tsv" ]
echo 'Confirmed agent-free shell endpoint retired its owned pid-zero claim.'
printf 'recover\tgpt-6.1-sol\t1\t0\n' > "$LAB/state/sol-sessions.tsv"
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-window -t primary:fm-recover
fm_lock_try_acquire "$LAB/state/.spawn-recover.lock"
fm_sol_cap_reconcile_local recover "$LAB/state"
fm_lock_release "$LAB/state/.spawn-recover.lock"
[ -s "$LAB/state/sol-sessions.tsv" ]
echo 'Missing tmux endpoint without persisted socket identity remains uncertain; its claim is retained.'
