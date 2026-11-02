#!/usr/bin/env bash
# Live drive of bin/fm-fleet-seats.sh in a disposable lab home.
# Scenario 1: one capacity shared by the primary and a registered local secondmate.
# Scenario 2: a supervisor running before pools existed is counted exactly once.
# Adversarial: a full pool refuses without writing a holder; an undeclared home stays inert.
set -u
REPO=${1:?repo}
EVID=${2:?evidence dir}
cd "$REPO" || exit 1

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || exit 1
bin/fm-lab-home.sh create "$LAB" >/dev/null || exit 1
MATE="$LAB/mate1"
mkdir -p "$MATE/state" "$MATE/config" "$MATE/data"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$LAB" > "$MATE/.fm-secondmate-parent"
printf 'mate1\n' > "$MATE/.fm-secondmate-home"
printf -- '- mate1 - Test mate. (home: %s; scope: tests; projects: ; added 2026-11-02)\n' "$MATE" >> "$LAB/data/secondmates.md"

SEATS=$REPO/bin/fm-fleet-seats.sh
seats() { local home=$1; shift
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$home" "$SEATS" "$@"; }

sleep 600 >/dev/null 2>&1 & H1=$!
sleep 600 >/dev/null 2>&1 & H2=$!
cleanup() { kill "$H1" "$H2" 2>/dev/null; rm -rf "$LAB"; }
trap cleanup EXIT

say() { printf '\n### %s\n' "$*"; }

say "LAB=$LAB (disposable marked lab home; removed at end)"

say "Scenario 1: capacity=1 declared only in the primary; primary and mate1 share it"
printf '{"pools":[{"name":"shared","capacity":1,"models":["pool-model-a"]}]}\n' > "$LAB/config/fleet-seats"
echo '$ fm-fleet-seats.sh reserve mate-one (FM_HOME=mate1, the local secondmate home)'
seats "$MATE" reserve mate-one --generation g-mate-one --harness pi --model pool-model-a --holder-pid "$H1"; echo "exit=$?"
echo '$ fm-fleet-seats.sh reserve primary-one (FM_HOME=primary)'
out=$(seats "$LAB" reserve primary-one --generation g-primary-one --harness pi --model pool-model-a --holder-pid "$H2" 2>&1); rc=$?
printf '%s\nexit=%s\n' "$out" "$rc"
echo '$ holder record written for primary-one? (must be none: no over-dispatch)'
seats "$LAB" show primary-one; echo "show exit=$?"
echo '$ ledger holder files:'
ls "$LAB/state/fleet-seats/holders"

say "Scenario 1b: releasing the mate generation frees the one seat for the primary"
seats "$MATE" release mate-one --generation g-mate-one --reason prelaunch; echo "exit=$?"
seats "$LAB" reserve primary-one --generation g-primary-one --harness pi --model pool-model-a --holder-pid "$H2"; echo "exit=$?"

say "Scenario 2: a ship that ran before the pool existed is counted exactly once, and its home refuses the next launch"
rm -rf "$LAB/state/fleet-seats" "$LAB/state/.fleet-seats-lock"
printf '{"pools":[{"name":"shared","capacity":2,"models":["pool-model-a"]}]}\n' > "$LAB/config/fleet-seats"
printf 'kind=ship\nmodel=pool-model-a\nharness=pi\nowner_pid=%s\n' "$H1" > "$LAB/state/legacy-ship.meta"
echo '$ unmanaged pre-pool record seeded: state/legacy-ship.meta model=pool-model-a'
seats "$LAB" show legacy-ship
echo '$ reserve after the pool was enabled (used must be 2 of 2: the legacy ship counted once + this launch)'
seats "$LAB" reserve primary-two --generation g-primary-two --harness pi --model pool-model-a --holder-pid "$H2"; echo "exit=$?"
echo '$ a third launch must be refused as full'
out=$(seats "$LAB" reserve primary-three --generation g-primary-three --harness pi --model pool-model-a --holder-pid "$H2" 2>&1); rc=$?
printf '%s\nexit=%s\n' "$out" "$rc"

say "Adversarial: a home with no pool declaration stays inert and writes no ledger"
INERT="$LAB/inert-home"
mkdir -p "$INERT/state" "$INERT/config" "$INERT/data"
out=$(seats "$INERT" reserve inert-one --generation g-inert --harness pi --model pool-model-a --holder-pid "$H1" 2>&1); rc=$?
printf '%s\nexit=%s\n' "$out" "$rc"
echo '$ ledger directory in the undeclared home (must not exist):'
ls -d "$INERT/state/fleet-seats" 2>&1 || echo "absent"

say "Adversarial: an unreachable/unconfirmed authority refuses rather than granting a seat"
printf '{"pools":[{"name":"shared","capacity":5,"models":["pool-model-a"]}]}\n' > "$LAB/config/fleet-seats"
printf -- '- ghost - Ghost mate. (host: nowhere; root: /srv/x; home: /srv/x-home; scope: x; projects: ; added 2026-11-02)\n' >> "$LAB/data/secondmates.md"
rm -rf "$LAB/state/fleet-seats" "$LAB/state/.fleet-seats-lock"
out=$(seats "$LAB" reserve after-ghost --generation g-after-ghost --harness pi --model pool-model-a --holder-pid "$H1" 2>&1); rc=$?
printf '%s\nexit=%s\n' "$out" "$rc"
seats "$LAB" show after-ghost; echo "show exit=$? (no holder published)"

say "teardown"
