#!/usr/bin/env bash
# Live spawn refusal under the captain-declared concurrent-session ceiling.
# The real bin/fm-spawn.sh runs against a disposable lab home whose
# config/sol-cap declares a ceiling of four for one model.
set -eu
ROOT=$PWD
LAB=$(mktemp -d "$PWD/.spawn-live-XXXXXX")
trap 'rm -rf "$LAB"' EXIT
export FM_HOME=$LAB
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS TMUX
bin/fm-lab-home.sh create "$LAB"
mkdir -p "$LAB/project" "$LAB/data/fifth"
git -C "$LAB/project" init -q
printf 'max=4\nmodels=gpt-6.1-sol\n' > "$LAB/config/sol-cap"
printf '{"default":{"harness":"codex","model":"gpt-6.1-sol"}}\n' > "$LAB/config/crew-dispatch.json"
printf '# Task\n## Captain intent\nExercise admission refusal.\n## Firstmate spec\nNo worker must launch at capacity.\n# Definition of done\nDelivery contract: mode=no-mistakes\n' > "$LAB/data/fifth/brief.md"
for id in one two three four; do
  FM_HOME="$LAB" bin/fm-sol-cap-lib.sh record-actual "$id" gpt-6.1-sol "$LAB/state"
done
cp "$LAB/state/sol-sessions.tsv" "$LAB/before.tsv"
rc=0
FM_HOME="$LAB" bin/fm-spawn.sh fifth "$LAB/project" --harness codex --model gpt-6.1-sol --backend tmux --mode no-mistakes --yolo off > "$LAB/spawn.log" 2>&1 || rc=$?
cat "$LAB/spawn.log"
printf 'spawn exit=%s\n' "$rc"
[ "$rc" -ne 0 ]
grep -q 'Sol ceiling reached: 4 concurrent capped session(s)' "$LAB/spawn.log"
grep -q 'declared in config/sol-cap' "$LAB/spawn.log"
cmp "$LAB/before.tsv" "$LAB/state/sol-sessions.tsv"
[ ! -e "$LAB/state/fifth.meta" ]
[ ! -e "$LAB/state/fifth.launch" ]
printf 'Refusal preserved all four claims and created no fifth metadata or launch file.\n'
