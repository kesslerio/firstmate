#!/usr/bin/env bash
# Live drive of certificate-proved generation accounting in bin/fm-fleet-seats.sh.
#
# A remote secondmate 'shop' already runs on the host as generation host.1: its
# serve certificate proves it, and the parent record names the same generation.
# A failed earlier spawn left only a released ledger candidate for that holder.
#  1. A pre-pool/remote supervisor proved by the certificate is counted exactly
#     once (one record + one certificate row for the same agent), so a fist
#     worker fills the second seat of a two-seat pool and the next is refused.
#  2. A relaunch that persists the certificate-proved generation into the parent
#     record is admitted instead of being refused as an identity the ledger never
#     issued.
#  3. An invented generation no certificate proves is still refused.
set -u
REPO=${1:?repo}
cd "$REPO" || exit 1

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || exit 1
bin/fm-lab-home.sh create "$LAB" >/dev/null || exit 1
REMOTE="$LAB/remote-shop"
mkdir -p "$REMOTE/state" "$REMOTE/config" "$REMOTE/data"
SEATS=$REPO/bin/fm-fleet-seats.sh
seats() { local home=$1; shift
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$home" "$SEATS" "$@"; }
sleep 600 >/dev/null 2>&1 & H1=$!
sleep 600 >/dev/null 2>&1 & H2=$!
cleanup() { kill "$H1" "$H2" 2>/dev/null; rm -rf "$LAB"; }
trap cleanup EXIT
say() { printf '\n### %s\n' "$*"; }

say "LAB=$LAB (disposable marked lab home)"

say "Register remote secondmate 'shop' on host shop-host; declare a two-seat pool"
printf -- '- shop - Shop mate. (host: shop-host; root: /srv/fm; home: %s; scope: shop; projects: ; added 2026-11-02)\n' \
  "$REMOTE" > "$LAB/data/secondmates.md"
printf '{"pools":[{"name":"shared","capacity":2,"models":["pool-model-a"]}]}\n' > "$LAB/config/fleet-seats"
digest=$(jq -cS . "$LAB/config/fleet-seats" | cksum | tr -s ' ' '-' | cut -d- -f1-2)
mkdir -p "$LAB/state/fleet-seats"
printf '{"schema":"fm-fleet-seats-serve.v2","policy_digest":"%s","epoch":"live.1","complete":true,"holders":[{"state_dir":"%s/state/parent-route","task":"shop","generation":"host.1","model":"pool-model-a"}]}\n' \
  "$digest" "$REMOTE" > "$LAB/state/fleet-seats/remote-shop.cert"
echo "\$ durable serve certificate published by an earlier serve pass:"
jq -S . "$LAB/state/fleet-seats/remote-shop.cert"

say "Seed state: shop runs host.1 on the host, and an earlier spawn of shop failed after reserving"
seats "$LAB" reserve shop --generation g-abandoned --harness pi --model pool-model-a --kind secondmate --holder-pid "$H1"
seats "$LAB" release shop --generation g-abandoned --reason prelaunch
printf 'kind=secondmate\nmodel=pool-model-a\nharness=pi\nremote_host=shop-host\nremote_root=/srv/fm\nhome=%s\nremote_spawn_gen=host.1\n' \
  "$REMOTE" > "$LAB/state/shop.meta"
echo "\$ state/shop.meta (the parent record) names remote_spawn_gen=host.1 - the generation the certificate proves"

say "Scenario 1: the certificate-proved supervisor occupies exactly one of the two seats"
out=$(seats "$LAB" reserve worker-a --generation g-worker-a --harness pi --model pool-model-a --holder-pid "$H2" 2>&1); rc=$?
printf '%s\nexit=%s   <- used=2 capacity=2 means the adopted supervisor counted once, not twice\n' "$out" "$rc"
out=$(seats "$LAB" reserve worker-b --generation g-worker-b --harness pi --model pool-model-a --holder-pid "$H2" 2>&1); rc=$?
printf '%s\nexit=%s   <- the full pool refuses: no over-dispatch\n' "$out" "$rc"

say "Scenario 2: the relaunch that persists the certificate-proved generation is admitted"
seats "$LAB" release worker-a --generation g-worker-a --reason prelaunch >/dev/null
out=$(seats "$LAB" reserve shop --generation g-relaunch --harness pi --model pool-model-a --kind secondmate --holder-pid "$H1" 2>&1); rc=$?
printf '%s\nexit=%s   <- expected 0: the certificate, not a ledger row, issued host.1\n' "$out" "$rc"

say "Scenario 3 (adversarial): an invented generation no certificate proves is still refused"
seats "$LAB" release shop --generation g-relaunch --reason prelaunch >/dev/null
sed -i 's/^remote_spawn_gen=host.1$/remote_spawn_gen=host.unissued/' "$LAB/state/shop.meta"
out=$(seats "$LAB" reserve shop --generation g-invented --harness pi --model pool-model-a --kind secondmate --holder-pid "$H1" 2>&1); rc=$?
printf '%s\nexit=%s   <- expected 5: ledger history cannot be bypassed by an unproved identity\n' "$out" "$rc"
sed -i 's/^remote_spawn_gen=host.unissued$/remote_spawn_gen=host.1/' "$LAB/state/shop.meta"
out=$(seats "$LAB" reserve shop --generation g-relaunch2 --harness pi --model pool-model-a --kind secondmate --holder-pid "$H1" 2>&1); rc=$?
printf '%s\nexit=%s   <- the proved generation is admitted again once the record is truthful\n' "$out" "$rc"
