#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob
state=$(mktemp -d /tmp/stream-protocol.XXXXXX)
EV="$WORK/bin/fm-busy-event.sh"
gen=$(bash "$EV" arm "$state" worker)
bash "$EV" apply "$state" worker busy --gen "$gen" --source pi-ext --event agent-start
before=$(cat "$state/worker.busy-state")
show() { printf '\n%s\n' "$1"; for f in "$state"/*; do printf '%s: ' "${f##*/}"; cat "$f"; done; }
refuse() { local rc=0; "$@" || rc=$?; printf 'refusal exit=%s\n' "$rc"; [ "$rc" -eq 1 ]; }
bash "$EV" stream "$state" worker open --gen "$gen" --request 1
bash "$EV" stream "$state" worker progress --gen "$gen" --request 1
show 'Current request accepted; model progress is separate from semantic state'
[ "$before" = "$(cat "$state/worker.busy-state")" ]
[ ! -e "$state/worker.progress" ] && [ ! -e "$state/worker.turn-ended" ]
bash "$EV" stream "$state" worker close --gen "$gen" --request 1
refuse bash "$EV" stream "$state" worker progress --gen "$gen" --request 1
refuse bash "$EV" stream "$state" worker open --gen "$gen" --request 1
show 'Closed request rejects progress and replay; active marker absent'
[ ! -e "$state/worker.model-stream" ]
bash "$EV" stream "$state" worker open --gen "$gen" --request 2
current=$(cat "$state/worker.model-stream")
refuse bash "$EV" stream "$state" worker close --gen "$gen" --request 1
[ "$current" = "$(cat "$state/worker.model-stream")" ]
next=$(bash "$EV" arm "$state" worker)
refuse bash "$EV" stream "$state" worker open --gen "$gen" --request 3
[ ! -e "$state/worker.model-stream" ] && [ ! -e "$state/worker.model-progress" ]
bash "$EV" apply "$state" worker busy --gen "$next" --source pi-ext --event agent-start
bash "$EV" stream "$state" worker open --gen "$next" --request 1
bash "$EV" retire "$state" worker --gen "$next"
refuse bash "$EV" stream "$state" worker open --gen "$next" --request 2
[ -z "$(ls -A "$state")" ]
show 'Replacement rejects old generation; retirement removes all observations and rejects late open'
