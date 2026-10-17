#!/usr/bin/env bash
set -eu
LAB="$PWD/.test-sol-remote"
trap 'rm -rf "$LAB"' EXIT
bin/fm-lab-home.sh create "$LAB"
printf '%s\n' '{"default":{"harness":"codex","model":"gpt-6.1-sol"}}' > "$LAB/config/crew-dispatch.json"
printf 'kind=secondmate\nremote_host=unconfigured-lab.invalid\nharness=codex\nmodel=glm-5\n' > "$LAB/state/mate.meta"
cp "$LAB/state/mate.meta" "$LAB/state/expected"
for n in 1 2 3 4; do printf 'held-%s\tgpt-6.1-sol\t1\t0\n' "$n"; done > "$LAB/state/sol-sessions.tsv"
export FM_HOME="$LAB"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
set +e
out=$(bin/fm-remote-secondmate-relaunch.sh mate codex gpt-6.1-sol medium 2>&1)
rc=$?
set -e
printf '%s\nexit=%s\n' "$out" "$rc"
[ "$rc" = 1 ]
case "$out" in *"Sol ceiling reached"*) ;; *) exit 1 ;; esac
cmp "$LAB/state/mate.meta" "$LAB/state/expected"
echo 'Remote switch denied before delivery; existing GLM metadata preserved.'
printf 'malformed\tgpt-6.1-sol\tnot-an-epoch\t0\n' > "$LAB/state/sol-sessions.tsv"
set +e
out=$(bin/fm-sol-cap-lib.sh refuse-claim broken ship codex gpt-6.1-sol "$LAB/config" "$LAB/state" 2>&1)
rc=$?
set -e
printf '%s\nexit=%s\n' "$out" "$rc"
[ "$rc" = 1 ]
case "$out" in *malformed*|*Malformed*) ;; *) exit 1 ;; esac
