#!/usr/bin/env bash
# Disposable-home drive of the operator-facing fleet seat contract
# (docs/configuration.md "Fleet seat pools") through the real
# bin/fm-fleet-seats.sh CLI. Nothing here reads or writes a real firstmate home.
set -u
REPO=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-seat-lab.XXXXXX")
PIDS=
cleanup() {
  local p
  for p in $PIDS; do kill "$p" 2>/dev/null || true; done
  rm -rf "$LAB"
}
trap cleanup EXIT
SEATS=$REPO/bin/fm-fleet-seats.sh
holder() { sleep 300 >/dev/null 2>&1 & PIDS="$PIDS $!"; LAST=$!; }
run() { local h=$1; shift; env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$h" "$@"; }
mkhome() { mkdir -p "$1/state" "$1/config" "$1/data"; }
seats() { local h=$1; shift; run "$h" "$SEATS" "$@"; }

R=$LAB/primary
mkhome "$R"
printf '%s\n' '{"pools":[{"name":"endpoint","capacity":1,"models":["provider-a/model-x","provider-b/model-x"]}]}' > "$R/config/fleet-seats"

echo "=== A. one shared seat: the second pooled launch is refused and the holder is named ==="
holder; seats "$R" reserve crew-a --generation g-a --harness claude --model provider-a/model-x --holder-pid "$LAST"; echo "rc=$?"
holder; seats "$R" reserve crew-b --generation g-b --harness claude --model provider-b/model-x --holder-pid "$LAST"; echo "rc=$?"

echo
echo "=== B. a prefix of the model string is not the pooled model (exact match only) ==="
seats "$R" reserve crew-c --generation g-c --harness claude --model provider-a/model --holder-pid "$LAST"; echo "rc=$?"

echo
echo "=== C. the unpooled model is recorded and takes no seat ==="
seats "$R" reserve crew-d --generation g-d --harness claude --model other/model-z --holder-pid "$LAST"; echo "rc=$?"

echo
echo "=== D. releasing the WRONG generation leaves the held seat counted ==="
seats "$R" release crew-a --generation g-wrong --reason prelaunch; echo "rc=$?"
seats "$R" reserve crew-b --generation g-b --harness claude --model provider-b/model-x --holder-pid "$LAST"; echo "rc=$?"

echo
echo "=== E. releasing the exact generation frees the seat for the next launch ==="
seats "$R" release crew-a --generation g-a --reason prelaunch; echo "rc=$?"
seats "$R" reserve crew-b --generation g-b --harness claude --model provider-b/model-x --holder-pid "$LAST"; echo "rc=$?"
seats "$R" show crew-a | jq -c '.incarnations[] | select(.generation=="g-a") | {generation,lifecycle}'
seats "$R" show crew-b | jq -c '.incarnations[] | select(.generation=="g-b") | {generation,lifecycle}'

echo
echo "=== F. a same-generation retry is idempotent, a different generation is not granted ==="
seats "$R" reserve crew-b --generation g-b --harness claude --model provider-b/model-x --holder-pid "$LAST"; echo "rc=$?"

echo
echo "=== G. while pools exist a harness default model is refused before any endpoint work ==="
M=$LAB/primary2
mkhome "$M"
printf '%s\n' '{"pools":[{"name":"endpoint","capacity":2,"models":["provider-a/model-x"]}]}' > "$M/config/fleet-seats"
seats "$M" reserve crew-e --generation g-e --harness claude --model default --holder-pid "$LAST"; echo "rc=$?"
seats "$M" reserve crew-f --generation g-f --harness claude --model '' --raw-launch --holder-pid "$LAST"; echo "rc=$?"
echo "holders written: $(ls "$M/state/fleet-seats/holders" 2>/dev/null | wc -l)"
echo "no declaration means no model requirement:"
rm -f "$M/config/fleet-seats"
seats "$M" reserve crew-g --generation g-g --harness claude --model default --holder-pid "$LAST"; echo "rc=$?"

echo
echo "=== H. an unreadable, symlinked, duplicated, or fractional policy refuses instead of launching uncapped ==="
for bad in \
  '{"pools":[{"name":"a","capacity":1,"models":["m"]},{"name":"b","capacity":1,"models":["m"]}]}' \
  '{"pools":[{"name":"a","capacity":1.5,"models":["m"]}]}' \
  '{"pools":[{"name":"..","capacity":1,"models":["m"]}]}'; do
  printf '%s\n' "$bad" > "$M/config/fleet-seats"
  seats "$M" reserve crew-h --generation g-h --harness claude --model m --holder-pid "$LAST"; echo "policy=$bad rc=$?"
done
printf '%s\n' '{"pools":[{"name":"a","capacity":1,"models":["m"]}]}' > "$LAB/policy.json"
rm -f "$M/config/fleet-seats"; ln -s "$LAB/policy.json" "$M/config/fleet-seats"
seats "$M" reserve crew-h --generation g-h --harness claude --model m --holder-pid "$LAST"; echo "symlinked policy rc=$?"
echo "holders written: $(ls "$M/state/fleet-seats/holders" 2>/dev/null | wc -l)"
rm -f "$M/config/fleet-seats"

echo
echo "=== I. capacity 0 refuses every launch instead of granting one ==="
printf '%s\n' '{"pools":[{"name":"a","capacity":0,"models":["m"]}]}' > "$M/config/fleet-seats"
seats "$M" reserve crew-i --generation g-i --harness claude --model m --holder-pid "$LAST"; echo "rc=$?"

echo
echo "=== I2. an empty pools list is a valid declaration that caps nothing ==="
printf '%s\n' '{"pools":[]}' > "$M/config/fleet-seats"
seats "$M" reserve crew-i2 --generation g-i2 --harness claude --model m --holder-pid "$LAST"; echo "rc=$?"

echo
echo "=== J. a local secondmate home spends the primary's seat, never its own ledger ==="
seats "$R" release crew-b --generation g-b --reason prelaunch >/dev/null
S=$LAB/mate
mkhome "$S"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$R" > "$S/.fm-secondmate-parent"
printf 'mate\n' > "$S/.fm-secondmate-home"
printf -- '- mate - Test mate. (home: %s; scope: tests; projects: ; added 2026-09-28)\n' "$S" >> "$R/data/secondmates.md"
seats "$R" reserve crew-j --generation g-j --harness claude --model provider-b/model-x --holder-pid "$LAST"; echo "primary seat rc=$?"
holder; seats "$S" reserve mate-job --generation g-m --harness claude --model provider-b/model-x --holder-pid "$LAST"; echo "mate launch rc=$?"
echo "mate ledger: $(ls "$S/state/fleet-seats/holders" 2>/dev/null | wc -l)"
echo "mate authority record: $(cat "$S/state/.fm-fleet-seats-authority" 2>/dev/null)"
seats "$R" release crew-j --generation g-j --reason prelaunch >/dev/null
seats "$S" reserve mate-job --generation g-m --harness claude --model provider-b/model-x --holder-pid "$LAST"; echo "mate launch after release rc=$?"
echo "primary holders: $(jq -r .task "$R"/state/fleet-seats/holders/*.json | tr '\n' ' ')"

echo
echo "=== K. a marked home whose parent binding vanished still counts against its recorded root ==="
rm -f "$S/.fm-secondmate-parent"
holder; seats "$S" reserve mate-job-2 --generation g-m2 --harness claude --model provider-b/model-x --holder-pid "$LAST"; echo "with authority record rc=$?"
rm -f "$S/state/.fm-fleet-seats-authority"
seats "$S" reserve mate-job-3 --generation g-m3 --harness claude --model provider-b/model-x --holder-pid "$LAST"; echo "without authority record rc=$?"
echo "mate ledger: $(ls "$S/state/fleet-seats/holders" 2>/dev/null | wc -l)"
