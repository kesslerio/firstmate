#!/usr/bin/env bash
# Scenario 2 lab: pooled local supervisor lifecycle on a real pi harness.
# The candidate tree is copied (tracked files, no gate git metadata) into a
# disposable code root and a disposable secondmate home, because the gate
# worktree's own git-common-dir makes every nested FM_STATE_OVERRIDE call
# (fm-secondmate-restart -> fm-send) refuse as fleet lifecycle.
set -u
E=/Users/kesslerio/.no-mistakes/evidence/01M3RP9FKDWJ4VTFQQY8Q2R70E
SRC=/Users/kesslerio/.no-mistakes/worktrees/8036f35f7c08/01M3RP9FKDWJ4VTFQQY8Q2R70E
CODE="$E/s2c"; LAB="$E/s2l"; MATE="$E/s2m"
M1='john-remote/qwen3.8-flash-next'; M2='john-remote/other-model'
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
copy_tree() { mkdir -p "$1" && (cd "$SRC" && git ls-files -z | xargs -0 tar -cf -) | (cd "$1" && tar -xf -) && git -C "$1" init -q -b main && git -C "$1" add -A && git -C "$1" -c user.name=Test -c user.email=test@example.invalid commit -qm "candidate $(git -C "$SRC" rev-parse --short HEAD)"; }
copy_tree "$CODE" || exit 1
copy_tree "$MATE" || exit 1
"$CODE/bin/fm-lab-home.sh" create "$LAB" || exit 1
mkdir -p "$LAB/tmux" "$MATE/data" "$MATE/state" "$MATE/config"
touch "$LAB/config/supervision-host"
printf 'labmate\n' > "$MATE/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$LAB" > "$MATE/.fm-secondmate-parent"
printf 'Disposable validation supervisor. There is no assigned work. Remain idle; do not edit project files, launch workers, contact services, or install anything. When your parent asks you to record open work, you hold none: answer on the parent channel that nothing is open.\n' > "$MATE/data/charter.md"
printf -- '- labmate - Validation mate. (home: %s; scope: validation; projects: ; added 2026-09-30)\n' "$MATE" > "$LAB/data/secondmates.md"
# One-seat shared pool for the supervisor model; a second one-seat pool that a
# blocker holds, so a cross-pool relaunch must refuse before touching the agent.
printf '{"pools":[{"name":".shared","capacity":1,"models":["%s"]},{"name":"..other","capacity":1,"models":["%s"]}]}\n' "$M1" "$M2" > "$LAB/config/fleet-seats"
printf 'pi %s\n' "$M1" > "$LAB/config/secondmate-harness"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -x 160 -y 45 -c "$CODE" -e FM_HOME="$LAB" bash || exit 1
echo ok
