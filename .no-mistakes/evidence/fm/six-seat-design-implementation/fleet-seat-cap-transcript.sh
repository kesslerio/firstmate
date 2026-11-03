#!/usr/bin/env bash
# Reviewer-facing transcript: drive the real bin/fm-fleet-seats.sh CLI in a
# disposable home and show the pool cap admitting, refusing, then releasing.
set -u
REPO=${1:?repo}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-seat-transcript.XXXXXX")
trap 'kill $HOLDER 2>/dev/null; rm -rf "$LAB"' EXIT
HOME1=$LAB/primary; mkdir -p "$HOME1/state" "$HOME1/config" "$HOME1/data"
printf '{"pools":[{"name":"shared","capacity":1,"models":["pool-model-a"]}]}\n' > "$HOME1/config/fleet-seats"
seats() { env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$HOME1" "$REPO/bin/fm-fleet-seats.sh" "$@"; }
sleep 300 >/dev/null 2>&1 & HOLDER=$!
echo '$ fm-fleet-seats.sh reserve worker-a --generation g-a --model pool-model-a   # holder pid 1st'
seats reserve worker-a --generation g-a --harness pi --model pool-model-a --holder-pid "$HOLDER"; echo "exit=$?"
echo
echo '$ fm-fleet-seats.sh show worker-a'
seats show worker-a
echo
echo '$ fm-fleet-seats.sh reserve worker-b --generation g-b --model pool-model-a   # same pool, still held'
out=$(seats reserve worker-b --generation g-b --harness pi --model pool-model-a --holder-pid "$HOLDER" 2>&1); rc=$?
printf '%s\nexit=%s\n' "$out" "$rc"
echo
echo '$ fm-fleet-seats.sh show worker-b   # the refused launch left no record'
seats show worker-b; echo "(empty above)"
echo
echo '$ fm-fleet-seats.sh release worker-a --generation g-a --reason prelaunch'
seats release worker-a --generation g-a --reason prelaunch; echo "exit=$?"
echo
echo '$ fm-fleet-seats.sh reserve worker-b --generation g-b --model pool-model-a   # capacity now free'
seats reserve worker-b --generation g-b --harness pi --model pool-model-a --holder-pid "$HOLDER"; echo "exit=$?"
