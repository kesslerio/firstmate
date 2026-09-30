#!/usr/bin/env bash
set -u
E=/Users/kesslerio/.no-mistakes/evidence/01M3RP9FKDWJ4VTFQQY8Q2R70E
LAB="$E/s"
MATE="$E/m"
cleanup() {
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null || true
  python3 - "$LAB" "$MATE" <<'PY'
import shutil,sys,os
for p in sys.argv[1:]:
 if os.path.isdir(p):
  for d,dirs,files in os.walk(p): os.chmod(d,0o700)
  shutil.rmtree(p)
PY
}
trap cleanup EXIT
bin/fm-lab-home.sh create "$LAB" || exit 1
bin/fm-lab-home.sh create "$MATE" || exit 1
mkdir -p "$LAB/tmux" "$MATE/bin"
touch "$LAB/config/supervision-host"
printf 'spawnmate\n' > "$MATE/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$LAB" > "$MATE/.fm-secondmate-parent"
cp AGENTS.md README.md "$MATE/"
printf 'Disposable validation supervisor. There is no assigned work. Remain idle and do not edit files, launch workers, contact services, or install anything.\n' > "$MATE/data/charter.md"
printf -- '- spawnmate - Validation mate. (home: %s; scope: validation; projects: ; added 2026-09-30)\n' "$MATE" > "$LAB/data/secondmates.md"
printf '{"pools":[{"name":".shared","capacity":1,"models":["gpt-5.6-sol"]}]}\n' > "$LAB/config/fleet-seats"
printf 'codex gpt-5.6-sol low\n' > "$LAB/config/secondmate-harness"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
git -C "$MATE" init -q -b main || exit 1
git -C "$MATE" add AGENTS.md README.md || exit 1
git -C "$MATE" -c user.name=Test -c user.email=test@example.invalid commit -qm 'disposable lab' || exit 1
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -x 120 -y 40 -c "$PWD" -e FM_HOME="$LAB" claude || exit 1
export TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB"
TMUX=$(tmux -L fm-lab display-message -p -t primary '#{socket_path},#{pid},0'); export TMUX
unset FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
FM_CONTROL_LAUNCH_WAIT=0.1 FM_CONTROL_POLL=0.01 bin/fm-spawn.sh spawnmate "$MATE" --harness codex --model gpt-5.6-sol --effort low --backend tmux --secondmate
rc=$?
printf 'spawn_exit=%s\n' "$rc"
[ -f "$LAB/state/spawnmate.meta" ] && cat "$LAB/state/spawnmate.meta"
bin/fm-fleet-seats.sh show spawnmate
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab capture-pane -p -t primary:fm-spawnmate
sleep 2
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab capture-pane -p -t primary:fm-spawnmate
bin/fm-control.sh spawnmate relaunch --expect-generation stale-generation --model gpt-5.6-sol
printf 'stale_relaunch_exit=%s\n' "$?"
bin/fm-control.sh spawnmate exit
printf 'control_exit=%s\n' "$?"
