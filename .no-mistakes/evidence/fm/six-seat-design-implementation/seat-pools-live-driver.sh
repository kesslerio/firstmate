#!/usr/bin/env bash
# Live gate driver: drive the real bin/fm-fleet-seats.sh CLI against disposable
# marked lab homes. No fixtures stand in for the seat accounting itself.
set -u
CODE=${CODE:?}
BASE=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
LABS=()
cleanup() {
  local p
  for p in ${HOLDERS:-}; do kill "$p" 2>/dev/null; done
  for d in "${LABS[@]}"; do rm -rf "$d"; done
  rm -rf "$BASE"
}
trap cleanup EXIT

newlab() {  # <name> -> prints home
  local dir="$BASE/$1"
  "$CODE/bin/fm-lab-home.sh" create "$dir" >/dev/null || { echo "LAB CREATE FAILED $1" >&2; exit 1; }
  LABS+=("$dir")
  printf '%s\n' "$dir"
}
holder() { sleep 300 >/dev/null 2>&1 & HOLDERS="${HOLDERS:-} $!"; LAST_HOLDER=$!; }
seats() {  # <home> <args...>
  local home=$1; shift
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS \
    FM_HOME="$home" "$CODE/bin/fm-fleet-seats.sh" "$@"
}
pools() { printf '{"pools":[{"name":"shared","capacity":%s,"models":["pool-model-a","pool-model-b"]}]%s}\n' "$2" "${3:-}" > "$1/config/fleet-seats"; }
reserve() { holder; seats "$1" reserve "$2" --generation "g-$2" --harness pi --model "$3" --holder-pid "$LAST_HOLDER"; }

echo "=== SCENARIO 1: primary + local secondmate share one capacity ==="
ROOT=$(newlab root-s1); MATE=$(newlab mate-s1)
pools "$ROOT" 2
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$ROOT" > "$MATE/.fm-secondmate-parent"
printf 'mate\n' > "$MATE/.fm-secondmate-home"
printf -- '- mate - Live local mate. (home: %s; scope: tests; projects: ; added 2026-11-02)\n' "$MATE" >> "$ROOT/data/secondmates.md"
echo "--- primary home reserves the first seat (capacity 2)"
reserve "$ROOT" primary-worker pool-model-a; echo "rc=$?"
echo "--- local secondmate home reserves the second seat"
reserve "$MATE" mate-worker pool-model-b; echo "rc=$?"
echo "--- primary home asks for a third seat"
reserve "$ROOT" overflow-worker pool-model-a; echo "rc=$?"

echo
echo "=== SCENARIO 2: supervisor already running before pools existed counted once ==="
ROOT2=$(newlab root-s2); SUPHOME=$(newlab mate-s2)
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$ROOT2" > "$SUPHOME/.fm-secondmate-parent"
printf 'prepool\n' > "$SUPHOME/.fm-secondmate-home"
printf -- '- prepool - Live pre-pool mate. (home: %s; scope: tests; projects: ; added 2026-11-02)\n' "$SUPHOME" >> "$ROOT2/data/secondmates.md"
# The supervisor was launched BEFORE the pool existed: its task record and live
# session lock already exist and no seat reservation was ever written.
printf 'kind=secondmate\nmodel=pool-model-a\nharness=pi\nhome=%s\n' "$SUPHOME" > "$ROOT2/state/prepool.meta"
holder; SUP_PID=$LAST_HOLDER
printf '%s\n' "$SUP_PID" > "$SUPHOME/state/.lock"
echo "--- pre-pool supervisor record (no ledger holder):"
cat "$ROOT2/state/prepool.meta"; echo "live session lock pid=$SUP_PID"
echo "--- enable pools at capacity 2, then reserve one new launch"
pools "$ROOT2" 2
reserve "$ROOT2" new-worker pool-model-a; echo "rc=$?"
echo "--- show the ledger has exactly one holder record (the new launch)"
ls "$ROOT2/state/fleet-seats/holders"
echo "--- release the new launch, then ask for two more seats"
seats "$ROOT2" release new-worker --generation g-new-worker --reason prelaunch; echo "rc=$?"
reserve "$ROOT2" next-worker pool-model-a; echo "rc=$?"
reserve "$ROOT2" third-worker pool-model-a; echo "rc=$?"
echo "--- full-pool refusal holder list (pre-pool supervisor must appear once):"
seats "$ROOT2" reserve fourth-worker --generation g-fourth --harness pi --model pool-model-a --holder-pid "$SUP_PID" 2>&1 | tee "$BASE/s2-refusal.txt"
echo "rc=${PIPESTATUS[0]}"
echo "occurrences of prepool in the refusal: $(grep -c 'prepool' "$BASE/s2-refusal.txt")"

echo
echo "=== SCENARIO 1b: simultaneous launches from both homes cannot oversubscribe ==="
ROOT3=$(newlab root-s1b); MATE3=$(newlab mate-s1b)
pools "$ROOT3" 2
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$ROOT3" > "$MATE3/.fm-secondmate-parent"
printf 'mate\n' > "$MATE3/.fm-secondmate-home"
printf -- '- mate - Live local mate. (home: %s; scope: tests; projects: ; added 2026-11-02)\n' "$MATE3" >> "$ROOT3/data/secondmates.md"
holder; RACE_PID=$LAST_HOLDER
i=0
RACE_JOBS=
while [ "$i" -lt 8 ]; do
  i=$((i + 1))
  if [ $((i % 2)) -eq 0 ]; then home=$ROOT3; else home=$MATE3; fi
  ( seats "$home" reserve "race$i" --generation "g-race$i" --harness pi --model pool-model-a \
      --holder-pid "$RACE_PID" > "$BASE/race$i.out" 2>&1; echo "$?" > "$BASE/race$i.rc" ) &
  RACE_JOBS="$RACE_JOBS $!"
done
for p in $RACE_JOBS; do wait "$p"; done
granted=0
i=0
while [ "$i" -lt 8 ]; do
  i=$((i + 1))
  echo "race$i rc=$(cat "$BASE/race$i.rc") $(head -1 "$BASE/race$i.out")"
  [ "$(cat "$BASE/race$i.rc")" = 0 ] && granted=$((granted + 1))
done
echo "granted=$granted refused=$((8 - granted)) at capacity 2"

echo
echo "=== SCENARIO 5 (adversarial): no declaration keeps dispatch uncapped ==="
OFF=$(newlab root-off)
holder
seats "$OFF" reserve uncapped --generation g-uncapped --harness pi --model pool-model-a --holder-pid "$LAST_HOLDER"; echo "rc=$? (no output above == inert seat guard)"
echo "--- a harness default model is also allowed while unpooled"
seats "$OFF" reserve defaulted --generation g-defaulted --harness claude --model default --holder-pid "$LAST_HOLDER"; echo "rc=$?"
echo "--- ledger directories written for the unpooled home: $(ls -d "$OFF"/state/fleet-seats 2>/dev/null || echo none)"
