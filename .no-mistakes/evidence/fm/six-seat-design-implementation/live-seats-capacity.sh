#!/usr/bin/env bash
# Live driver: disposable lab homes -> real bin/fm-fleet-seats.sh verbs.
# Scenario 1: one generation-bound capacity shared by a primary and a local
# secondmate (no over-dispatch), pre-existing agents counted.
set -u
ROOT=/home/art/.no-mistakes/worktrees/9f75ec418609/01M6DDN8CWC4PFXJKN77TZ98SJ
SEATS="$ROOT/bin/fm-fleet-seats.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || exit 1
PIDS=
cleanup() {
  local pid
  for pid in $PIDS; do kill "$pid" 2>/dev/null || true; done
  rm -rf "$LAB"
}
trap cleanup EXIT
holder() { sleep 600 >/dev/null 2>&1 & PIDS="$PIDS $!"; LAST=$!; }
mkdir -p "$LAB/primary" "$LAB/mate" "$LAB/grandchild"
# Marked lab homes are the gate's authorised disposable fixtures.
"$ROOT/bin/fm-lab-home.sh" create "$LAB/primary" >/dev/null || exit 1
"$ROOT/bin/fm-lab-home.sh" create "$LAB/mate" >/dev/null || exit 1
"$ROOT/bin/fm-lab-home.sh" create "$LAB/grandchild" >/dev/null || exit 1
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$LAB/primary" > "$LAB/mate/.fm-secondmate-parent"
printf 'mate\n' > "$LAB/mate/.fm-secondmate-home"
printf -- '- mate - live local secondmate. (home: %s; scope: live; projects: ; added 2026-11-02)\n' "$LAB/mate" >> "$LAB/primary/data/secondmates.md"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$LAB/mate" > "$LAB/grandchild/.fm-secondmate-parent"
printf 'grandchild\n' > "$LAB/grandchild/.fm-secondmate-home"

cat > "$LAB/primary/config/fleet-seats" <<'JSON'
{"pools":[{"name":"shared","capacity":2,"models":["live-model-a","live-model-b"]}]}
JSON

seats() { local home=$1; shift; env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$home" "$SEATS" "$@"; }
reserve() { local home=$1 id=$2 model=$3; holder; seats "$home" reserve "$id" --generation "g-$id" --harness claude --model "$model" --holder-pid "$LAST"; }

echo "== lab: $LAB"
echo "== 1a: primary reserves seat 1 (capacity 2)"
reserve "$LAB/primary" p1 live-model-a; echo "rc=$?"
echo "== 1b: local secondmate reserves seat 2 from its own home"
reserve "$LAB/mate" m1 live-model-b; echo "rc=$?"
echo "== 1c: nested secondmate's third launch must be refused at capacity"
reserve "$LAB/grandchild" g1 live-model-a; echo "rc=$?"
echo "== 1d: ledger at the root (authority) and in the secondmate home"
seats "$LAB/primary" show p1; echo "--"
seats "$LAB/primary" show m1; echo "--"
echo "secondmate-home p1 record: [$(seats "$LAB/mate" show p1 2>&1)]"
echo "== 1e: same-generation retry of the secondmate's own seat"
holder
seats "$LAB/mate" reserve m1 --generation g-m1 --harness claude --model live-model-b --holder-pid "$LAST"; echo "rc=$?"
echo "== 1f: a pre-existing (unmanaged) agent in the secondmate home is counted"
holder
printf 'kind=ship\nmodel=live-model-a\nharness=claude\n' > "$LAB/mate/state/legacy.meta"
seats "$LAB/primary" reserve p2 --generation g-p2 --harness claude --model live-model-a --holder-pid "$LAST"; echo "rc=$?"
echo "== done: $LAB"
