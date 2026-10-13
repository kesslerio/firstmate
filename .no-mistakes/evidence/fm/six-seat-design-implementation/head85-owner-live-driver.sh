#!/usr/bin/env bash
set -euo pipefail
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
H=$(mktemp -d "$PWD/.test-labs/owner.XXXXXX")
trap 'rm -rf "$H"' EXIT
bin/fm-lab-home.sh create "$H" >/dev/null
export FM_HOME=$H
printf '{"pools":[{"name":"shared","capacity":2,"models":["pool-model-a"]}]}\n' > "$H/config/fleet-seats"
S=$PWD/bin/fm-fleet-seats.sh
"$S" reserve matching --generation gm --harness claude --model pool-model-a --holder-pid "$$"
"$S" reserve reused --generation gr --harness claude --model pool-model-a --holder-pid "$$"
for f in "$H/state/fleet-seats/holders/"*.json; do
 [ "$(jq -r .task "$f")" = reused ] || continue
 jq '.incarnations[0].owner_pid_identity="previous-process-identity"' "$f" > "$f.new"
 mv "$f.new" "$f"
done
"$S" reconcile --limit 2
"$S" show matching
"$S" show reused
[ "$("$S" show matching | jq -r '.incarnations[0].lifecycle')" = reserved ]
[ "$("$S" show reused | jq -r '.incarnations[0].lifecycle')" = reclaimed ]
kill -0 "$$"
echo 'Observed: matching live owner retains its seat; stale process identity with an existing PID is reclaimed; unrelated process survives.'
