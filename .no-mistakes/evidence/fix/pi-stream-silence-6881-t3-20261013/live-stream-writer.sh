#!/usr/bin/env bash
# Live drive of the Pi stream writer's fencing contract through the real product
# CLI (bin/fm-busy-event.sh) in a disposable isolated state dir: a closed,
# superseded, or previous-generation observation can never recreate evidence.
set -u
ROOT=/home/art/.no-mistakes/worktrees/9f75ec418609/01M6887Z23FZWJH5G08X3RAKPH
BUSY="$ROOT/bin/fm-busy-event.sh"
STATE=$(mktemp -d "${TMPDIR:-/tmp}/fm-stream-writer-live.XXXXXX")
export FM_STATE_OVERRIDE="$STATE"
fails=0
ok() { printf 'ok   - %s\n' "$*"; }
bad() { printf 'FAIL - %s\n' "$*"; fails=$((fails + 1)); }
run() { printf '$ fm-busy-event.sh %s\n' "$*"; "$BUSY" "$@"; printf '  exit=%s\n' "$?"; }
marker() { cat "$STATE/stream.model-stream" 2>/dev/null || printf '(no active evidence)'; }

gen=$($BUSY arm "$STATE" stream)
$BUSY apply "$STATE" stream busy --gen "$gen" --source pi-ext --event agent-start
$BUSY stream "$STATE" stream open --gen "$gen" --request 1
printf '\n== open current request\n'; marker

printf '\n== close the request (assistant completion / tool start)\n'
run stream "$STATE" stream close --gen "$gen" --request 1
[ ! -e "$STATE/stream.model-stream" ] && ok 'close removed active evidence' || bad 'close left active evidence'
[ "$(cat "$STATE/stream.model-stream-order")" = "v1 gen=$gen request=1 phase=closed" ] \
  && ok 'closed ordering retained' || bad 'closed ordering missing'

printf '\n== delayed progress for the closed request\n'
run stream "$STATE" stream progress --gen "$gen" --request 1
[ ! -e "$STATE/stream.model-stream" ] && ok 'late progress could not recreate closed evidence' \
  || bad 'late progress resurrected closed evidence'

printf '\n== duplicate open of the same request\n'
run stream "$STATE" stream open --gen "$gen" --request 1
[ ! -e "$STATE/stream.model-stream" ] && ok 'duplicate open refused' || bad 'duplicate open recreated evidence'

printf '\n== newer request opens, then stale request 1 activity\n'
$BUSY stream "$STATE" stream open --gen "$gen" --request 2
before=$(marker)
run stream "$STATE" stream progress --gen "$gen" --request 1
[ "$(marker)" = "$before" ] && ok 'superseded request left the replacement untouched' \
  || bad 'superseded request mutated the replacement observation'
run stream "$STATE" stream close --gen "$gen" --request 1
[ "$(marker)" = "$before" ] && ok 'superseded close left the replacement untouched' \
  || bad 'superseded close cleared the replacement observation'

printf '\n== re-armed worker rejects its previous generation\n'
old_gen=$gen
gen=$($BUSY arm "$STATE" stream)
$BUSY apply "$STATE" stream busy --gen "$gen" --source pi-ext --event agent-start
[ ! -e "$STATE/stream.model-stream" ] && ok 'arm cleared the previous incarnation evidence' \
  || bad 'arm kept the previous incarnation evidence'
run stream "$STATE" stream open --gen "$old_gen" --request 3
[ ! -e "$STATE/stream.model-stream" ] && ok 'old-generation open refused' || bad 'old-generation open applied'

printf '\n== unarmed task\n'
mkdir -p "$STATE/unarmed"
run stream "$STATE" unarmed open --gen "$gen" --request 1
[ ! -e "$STATE/unarmed.model-stream" ] && ok 'unarmed task cannot open evidence' \
  || bad 'unarmed task opened evidence'

printf '\n== retire clears everything for the incarnation\n'
$BUSY retire "$STATE" stream --gen "$gen"
ls "$STATE"/stream.model-* >/dev/null 2>&1 && bad 'retire left stream files behind' \
  || ok 'retire removed the incarnation stream files'

rm -rf "$STATE"
printf '\n'
[ "$fails" -eq 0 ] && printf 'ALL CHECKS PASSED\n' || printf 'FAILURES: %s\n' "$fails"
exit "$fails"
