#!/usr/bin/env bash
# Live gate driver for the fleet-seat intent:
#  A. the real remote serve boundary (adoption, observing receipt, refusals)
#  B. the real root fleet loop: a pre-pool remote supervisor counted exactly
#     once, and a replacement launch replacing the generation the host records.
# The ssh hop is a local stand-in that execs the real bin/fm-remote-entrypoint.sh
# for a real second remote home; every seat script is the shipped one.
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
newlab() {
  local dir="$BASE/$1"
  "$CODE/bin/fm-lab-home.sh" create "$dir" >/dev/null || { echo "LAB CREATE FAILED" >&2; exit 1; }
  LABS+=("$dir"); printf '%s\n' "$dir"
}
holder() { sleep 300 >/dev/null 2>&1 & HOLDERS="${HOLDERS:-} $!"; LAST_HOLDER=$!; }
seats() {
  local home=$1; shift
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS \
    FM_HOME="$home" "$CODE/bin/fm-fleet-seats.sh" "$@"
}
serve_remotes() {
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS \
    FM_HOME="$1" FM_SSH_BIN="$BASE/ssh-local" "$CODE/bin/fm-fleet-seats.sh" serve-remotes
}
digest() { jq -cS . "$1" | cksum | tr -s ' ' '-' | cut -d- -f1-2; }
remote_pools() { printf '{"pools":[{"name":"shared","capacity":%s,"models":["pool-model-a","pool-model-b"]}]}\n' "$2" > "$1/config/fleet-seats"; }

# The local ssh stand-in for a real remote home: parse fm-on.sh's ssh arguments
# and exec the shipped remote entrypoint.
cat > "$BASE/ssh-local" <<SH
#!/usr/bin/env bash
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    -o) shift 2 ;;
    --) shift; break ;;
    *) echo "unexpected ssh arg \$1" >&2; exit 90 ;;
  esac
done
host=\$1; shift
[ "\$1" = fm-remote-entrypoint.sh ] || { echo "unexpected remote command \$1" >&2; exit 91; }
shift
exec "$CODE/bin/fm-remote-entrypoint.sh" "\$@"
SH
chmod +x "$BASE/ssh-local"

# A real remote home with the shipped host-side record of a supervisor that was
# already running before pools existed.
make_remote() {  # <name> -> prints the remote home
  local dir
  dir=$(newlab "$1")
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=shop-host\n' > "$dir/.fm-secondmate-parent"
  printf 'theshop\n' > "$dir/.fm-secondmate-home"
  mkdir -p "$dir/state/parent-route"
  printf 'kind=secondmate\nmodel=pool-model-a\nspawn_gen=%s\n' "${2:-host.1}" > "$dir/state/parent-route/theshop.meta"
  printf '%s\n' "$dir"
}
register_remote() {  # <root> <remote>
  printf -- '- theshop - Live remote mate. (host: shop-host; root: %s; home: %s; scope: shop work; projects: ; added 2026-11-02)\n' \
    "$CODE" "$2" >> "$1/data/secondmates.md"
}

echo "=== SCENARIO A1: the serve boundary adopts a pre-pool supervisor exactly once ==="
REMOTE=$(make_remote remote-a host.1)
POL="$BASE/policy.json"
remote_pools "$REMOTE" 2
cp "$REMOTE/config/fleet-seats" "$POL"
D=$(digest "$POL")
echo "delivered policy: $(cat "$POL") digest=$D"
seats "$REMOTE" serve --digest "$D" --epoch root.1 --allowance shared=2 < "$POL" > "$BASE/cert-adopt.json" 2>"$BASE/cert-adopt.err"
echo "serve rc=$?"; cat "$BASE/cert-adopt.err"
echo "certificate: $(jq -c . "$BASE/cert-adopt.json")"
echo "adopted rows for theshop: $(jq '[.holders[] | select(.task=="theshop")] | length' "$BASE/cert-adopt.json")"

echo
echo "=== SCENARIO A2: an observing receipt recognizes a supervisor found on another model ==="
printf 'kind=secondmate\nmodel=pool-model-a\nspawn_gen=host.4\n' > "$REMOTE/state/parent-route/theshop4.meta"
printf 'schema=fm-remote-seat-receipt.v1\noperation=op4\nverb=launch\nactual_generation=host.4\nactual_model=pool-model-a\n' \
  > "$REMOTE/state/parent-route/theshop4.seat-operation.op4"
(umask 077; jq -n --arg h "$REMOTE" '{schema:"fm-fleet-seat-holder.v2", task:"theshop4",
  incarnations:[{generation:"op4", kind:"secondmate", lifecycle:"reserved", launch_phase:"dispatching",
    model:"pool-model-b", route:{placement:"remote", operation:"op4", home:$h}}]}' \
  > "$REMOTE/state/parent-route/theshop4.seat-reservation.op4")
echo "replacement launch asked for pool-model-b; host runs pool-model-a (per its receipt)"
seats "$REMOTE" serve --digest "$D" --epoch root.2 --allowance shared=2 < "$POL" > "$BASE/cert-receipt.json" 2>"$BASE/cert-receipt.err"
echo "serve rc=$?"; cat "$BASE/cert-receipt.err"
echo "certificate holders: $(jq -c '[.holders[] | {task, generation, model}]' "$BASE/cert-receipt.json")"
echo "theshop4 adopted (0 means the receipt proved parent accounting): $(jq '[.holders[] | select(.task=="theshop4")] | length' "$BASE/cert-receipt.json")"

echo
echo "--- A2 adversarial: without its receipt the same supervisor is adopted once, never free"
rm -f "$REMOTE/state/parent-route/theshop4.seat-operation.op4"
seats "$REMOTE" serve --digest "$D" --epoch root.3 --allowance shared=2 < "$POL" > "$BASE/cert-noreceipt.json" 2>"$BASE/cert-noreceipt.err"
echo "serve rc=$? (expect 0: an unproven supervisor is adopted)"; cat "$BASE/cert-noreceipt.err"
echo "adopted rows for theshop4: $(jq '[.holders[] | select(.task=="theshop4")] | length' "$BASE/cert-noreceipt.json")"

echo
echo "--- A2 adversarial: a receipt bound to another model refuses instead of mis-counting"
printf 'schema=fm-remote-seat-receipt.v1\noperation=op4\nverb=launch\nactual_generation=host.4\nactual_model=pool-model-b\n' \
  > "$REMOTE/state/parent-route/theshop4.seat-operation.op4"
seats "$REMOTE" serve --digest "$D" --epoch root.4 --allowance shared=2 < "$POL" > "$BASE/cert-bad.receipt.json" 2>"$BASE/cert-badreceipt.err"
echo "serve rc=$? (expect 5)"; cat "$BASE/cert-badreceipt.err"

echo
echo "=== SCENARIO B1: a pre-pool remote supervisor is counted exactly once at the root ==="
ROOTB=$(newlab root-b)
REMOTEB=$(make_remote remote-b host.1)
remote_pools "$ROOTB" 5
register_remote "$ROOTB" "$REMOTEB"
echo "--- root serve pass (publishes the certificate):"
serve_remotes "$ROOTB"; echo "serve-remotes rc=$?"
echo "certificate: $(jq -c '{epoch, holders}' "$ROOTB/state/fleet-seats/remote-theshop.cert")"
holder; PROBE=$LAST_HOLDER
out=$(seats "$ROOTB" reserve probe1 --generation g-probe1 --harness pi --model pool-model-a --holder-pid "$PROBE" 2>&1)
echo "first pooled launch beside the pre-pool supervisor: $out (rc=$?) [used=2 means the supervisor holds exactly one seat]"
seats "$ROOTB" release probe1 --generation g-probe1 --reason prelaunch >/dev/null
echo "--- now the primary also records the same remote route and generation"
printf 'kind=secondmate\nmodel=pool-model-a\nharness=pi\nremote_host=shop-host\nremote_root=%s\nhome=%s\nspawn_gen=host.1\n' \
  "$CODE" "$REMOTEB" > "$ROOTB/state/theshop.meta"
serve_remotes "$ROOTB"; echo "serve-remotes rc=$?"
out=$(seats "$ROOTB" reserve probe2 --generation g-probe2 --harness pi --model pool-model-a --holder-pid "$PROBE" 2>&1)
echo "pooled launch with the parent route record too: $out (rc=$?) [still used=2: one supervisor, one seat]"
seats "$ROOTB" release probe2 --generation g-probe2 --reason prelaunch >/dev/null
echo "--- adversarial: a parent route record naming a different host must stay counted (never free, never doubled)"
printf 'kind=secondmate\nmodel=pool-model-a\nharness=pi\nremote_host=another-host\nremote_root=%s\nhome=%s\nspawn_gen=host.1\n' \
  "$CODE" "$REMOTEB" > "$ROOTB/state/theshop.meta"
serve_remotes "$ROOTB" >/dev/null; echo "serve-remotes rc=$?"
out=$(seats "$ROOTB" reserve probe3 --generation g-probe3 --harness pi --model pool-model-a --holder-pid "$PROBE" 2>&1)
echo "pooled launch beside the unmatched record: $out (rc=$?) [used=2 too: an unmatched record stays counted fail-closed and its charge replaces the certificate row, never adds to it]"

echo
echo "=== SCENARIO B2: a replacement replaces the generation the host records ==="
ROOTC=$(newlab root-c)
REMOTEC=$(make_remote remote-c host.1)
remote_pools "$ROOTC" 4
register_remote "$ROOTC" "$REMOTEC"
serve_remotes "$ROOTC" >/dev/null; echo "serve-remotes rc=$?"
printf 'remote_host=shop-host\nremote_root=%s\nhome=%s\nremote_spawn_gen=host.1\nremote_target=session:p1\n' \
  "$CODE" "$REMOTEC" > "$ROOTC/state/theshop.meta"
remote_route() {  # <generation> <target-json> <file>
  (umask 077; jq -cn --arg g "$1" --arg r "$CODE" --arg h "$REMOTEC" --argjson t "$2" \
    '{placement:"remote", backend:"herdr", target:$t, home:$h, host:"shop-host",
      remote_root:$r, spawn_gen:null, operation:$g}' > "$3")
}
remote_response() {  # <generation> <disposition> <prev|-> <old_stopped> <startup> <actual-json> <route-json> <file>
  (umask 077; jq -cn --arg op "$1" --arg d "$2" --arg prev "$3" --argjson stop "$4" \
    --argjson startup "$5" --argjson actual "$6" --argjson route "$7" \
    '{schema:"fm-remote-seat-operation.v2", complete:true, task:"theshop", operation:$op,
      requested_generation:$op, disposition:$d, actual_generation:$actual,
      previous_generation:(if $prev == "-" then null else $prev end),
      old_stopped:$stop, old_destroyed:$stop, startup_confirmed:$startup,
      actual_model:(if $actual == null then null else "pool-model-a" end),
      route:$route}' > "$8")
}
owner_op() {  # <generation> <previous|-> <route-file> <log>
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS \
    FM_HOME="$ROOTC" CODE="$CODE" ID=theshop GEN="$1" PREV="$2" ROUTE="$3" bash -c '
      "$CODE/bin/fm-fleet-seats.sh" reserve "$ID" --generation "$GEN" --previous-generation "$PREV" \
        --kind secondmate --harness pi --model pool-model-a --holder-pid $$ || exit 1
      "$CODE/bin/fm-fleet-seats.sh" dispatch "$ID" --generation "$GEN" --route-file "$ROUTE" || exit 1
    ' > "$4" 2>&1
  echo "owner $1: $(cat "$4")"
}
predecessor() {
  FM_HOME="$ROOTC" ID=theshop bash -c '. "$1/bin/fm-backend.sh"; . "$1/bin/fm-remote-generation-lib.sh"
    fm_remote_launch_predecessor "$(FM_HOME="$FM_HOME" "$1/bin/fm-fleet-seats.sh" show "$ID")" \
      shop-host "$1" "$2"' _ "$CODE" "$REMOTEC"
}
echo "--- launch 1: generation host.1 dispatched and confirmed by the host"
remote_route host.1 '"session:p1"' "$BASE/route1.json"
owner_op host.1 - "$BASE/route1.json" "$BASE/op1.log"
remote_response host.1 started - false true '"host.1"' \
  '{"placement":"remote","backend":"herdr","target":"session:p1","home":"'"$REMOTEC"'"}' "$BASE/resp1.json"
seats "$ROOTC" reconcile-remote theshop --generation host.1 --response-file "$BASE/resp1.json"; echo "confirm rc=$?"
echo "--- launch 2: replacement op2 dispatched but cancelled before it confirmed a startup"
remote_route op2 'null' "$BASE/route2.json"
owner_op op2 host.1 "$BASE/route2.json" "$BASE/op2.log"
remote_response op2 cancelled host.1 true false 'null' 'null' "$BASE/resp2.json"
seats "$ROOTC" reconcile-remote theshop --generation op2 --response-file "$BASE/resp2.json"; echo "cancel rc=$?"
echo "ledger: $(seats "$ROOTC" show theshop | jq -c '[.incarnations[] | {generation, lifecycle, target: .route.target, reason: .disposition.reason}]')"
echo "host-recorded generation: $(sed -n 's/^remote_spawn_gen=//p' "$ROOTC/state/theshop.meta")"
echo "next launch would replace (--previous): $(predecessor)"
echo "--- launch 3: a candidate whose route reached the host is the recorded generation when cancelled"
remote_route op3 '"session:p3"' "$BASE/route3.json"
owner_op op3 host.1 "$BASE/route3.json" "$BASE/op3.log"
remote_response op3 cancelled host.1 false false 'null' \
  '{"placement":"remote","backend":"herdr","target":"session:p3","home":"'"$REMOTEC"'"}' "$BASE/resp3.json"
seats "$ROOTC" reconcile-remote theshop --generation op3 --response-file "$BASE/resp3.json"; echo "cancel rc=$?"
echo "next launch would replace (--previous): $(predecessor)"
