#!/usr/bin/env bash
set -eu
ROOT=$PWD
LAB=$(mktemp -d "$PWD/.shared-live-XXXXXX")
trap 'rm -rf "$LAB"' EXIT
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS TMUX
bin/fm-lab-home.sh create "$LAB"
mkdir -p "$LAB/mate/state" "$LAB/mate/config" "$LAB/mate/data"
printf '{"default":{"model":"gpt-6.1-sol"}}\n' > "$LAB/config/crew-dispatch.json"
cp "$LAB/config/crew-dispatch.json" "$LAB/mate/config/crew-dispatch.json"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$LAB" > "$LAB/mate/.fm-secondmate-parent"
printf -- '- mate - local mate (home: %s; scope: test; projects: test; added 2026-10-19)\n' "$LAB/mate" > "$LAB/data/secondmates.md"
for id in one two three; do
  FM_HOME="$LAB" bin/fm-sol-cap-lib.sh record-actual "$id" gpt-6.1-sol "$LAB/state"
done
reserve() (
  export FM_HOME=$1
  . "$ROOT/bin/fm-wake-lib.sh"
  . "$ROOT/bin/fm-secondmate-registry-lib.sh"
  . "$ROOT/bin/fm-sol-cap-lib.sh"
  fm_sol_cap_refuse_and_claim "$2" ship codex gpt-6.1-sol "$FM_HOME/config" "$FM_HOME/state" || { echo "$FM_SOL_CAP_REFUSAL"; exit 1; }
  fm_sol_cap_promote "$2" 0 "$FM_HOME/state"
  printf 'reserved %s in %s\n' "$2" "$FM_HOME"
)
reserve "$LAB" root-racer > "$LAB/root.log" 2>&1 &
a=$!
reserve "$LAB/mate" mate-racer > "$LAB/mate.log" 2>&1 &
b=$!
rca=0; rcb=0
wait "$a" || rca=$?
wait "$b" || rcb=$?
cat "$LAB/root.log" "$LAB/mate.log"
printf 'root exit=%s; mate exit=%s\n' "$rca" "$rcb"
[ "$((rca + rcb))" = 1 ]
cat "$LAB/state/sol-sessions.tsv"
[ ! -f "$LAB/mate/state/sol-sessions.tsv" ] || cat "$LAB/mate/state/sol-sessions.tsv"
printf 'Exactly one local home took the remaining shared slot.\n'
