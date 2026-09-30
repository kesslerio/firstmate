#!/usr/bin/env bash
# Scenario 1 parent lab: a disposable primary home (candidate code copy) whose
# registered remote secondmate lives in the disposable lab on mama.
set -u
E=/Users/kesslerio/.no-mistakes/evidence/01M3RP9FKDWJ4VTFQQY8Q2R70E
SRC=/Users/kesslerio/.no-mistakes/worktrees/8036f35f7c08/01M3RP9FKDWJ4VTFQQY8Q2R70E
CODE="$E/s1c"; LAB="$E/s1l"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
mkdir -p "$CODE" && (cd "$SRC" && git ls-files -z | xargs -0 tar -cf -) | (cd "$CODE" && tar -xf -) && git -C "$CODE" init -q -b main && git -C "$CODE" add -A && git -C "$CODE" -c user.name=Test -c user.email=test@example.invalid commit -qm "candidate $(git -C "$SRC" rev-parse --short HEAD)" || exit 1
"$CODE/bin/fm-lab-home.sh" create "$LAB" || exit 1
mkdir -p "$LAB/tmux" "$E/s1-faults"
printf 'pi z-ai/glm-5.3-flash\n' > "$LAB/config/secondmate-harness"
echo ok
