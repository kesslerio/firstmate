#!/usr/bin/env bash
set -euo pipefail
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
R=$PWD
E=/home/art/.no-mistakes/evidence/01M4EGNATFWY186FV48C2W9EBR
T=$R/.test-labs/remote
cleanup() { rm -rf "$T"; }
trap cleanup EXIT
P=$T/primary L=$T/local Q=$T/remote D=$T/descendant
for h in "$P" "$L" "$Q" "$D"; do bin/fm-lab-home.sh create "$h" >/dev/null; done
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$P" > "$L/.fm-secondmate-parent"
printf 'local\n' > "$L/.fm-secondmate-home"
printf -- '- local - Local lab. (home: %s; scope: tests; projects: ; added 2026-10-08)\n' "$L" > "$P/data/secondmates.md"
printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=lab\n' > "$Q/.fm-secondmate-parent"
printf 'remote\n' > "$Q/.fm-secondmate-home"
printf -- '- remote - Remote lab. (host: lab-host; root: %s; home: %s; scope: tests; projects: ; added 2026-10-08)\n' "$R" "$Q" > "$L/data/secondmates.md"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$Q" > "$D/.fm-secondmate-parent"
printf 'descendant\n' > "$D/.fm-secondmate-home"
printf -- '- descendant - Descendant lab. (home: %s; scope: tests; projects: ; added 2026-10-08)\n' "$D" > "$Q/data/secondmates.md"
printf 'kind=ship\nmodel=pool-model-a\nharness=claude\n' > "$D/state/existing.meta"
printf '{"pools":[{"name":"shared","capacity":2,"models":["pool-model-a"]}]}\n' > "$P/config/fleet-seats"
# Disposable process transport: fm-on sends its real encoded request and the
# actual public command consumes it. No command output or product is stubbed.
cat > "$T/transport" <<'LOCAL'
#!/usr/bin/env bash
set -euo pipefail
while [ "$1" = -o ]; do shift 2; done
[ "$1" = -- ] && shift
[ "$1" = lab-host ]; [ "$2" = fm-remote-entrypoint.sh ]; shift 2
root=$(printf '%s' "$2" | base64 -d)
home=$(printf '%s' "$3" | base64 -d)
mapfile -d '' -t argv < <(printf '%s' "$4" | base64 -d)
exec env -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME="$home" "$root/bin/${argv[0]}" "${argv[@]:1}"
LOCAL
chmod +x "$T/transport"
export FM_SSH_BIN=$T/transport
S=$R/bin/fm-fleet-seats.sh
FM_HOME="$P" "$S" serve-remotes
cat "$P/state/fleet-seats/remote-remote.cert" > "$E/nested-remote-certificate.json"
jq -e --arg st "$D/state" 'any(.holders[]; .state_dir==$st and .task=="existing")' "$P/state/fleet-seats/remote-remote.cert"
echo 'Observed: root serve reached remote registered only in local secondmate; certificate contains its descendant.'
FM_HOME="$L" "$S" reserve local-worker --generation glocal --kind ship --harness claude --model pool-model-a --holder-pid "$$"
set +e
FM_HOME="$P" "$S" reserve overflow --generation gover --kind ship --harness claude --model pool-model-a --holder-pid "$$"
rc=$?
set -e
[ "$rc" = 4 ]
echo 'Observed: local + remote descendant exhaust shared capacity; overflow refused.'
# Owner-context reconciliation of an unpooled remote candidate.
printf '{"placement":"remote","backend":"herdr","target":null,"spawn_gen":null,"operation":"gremote","host":"lab-host","home":"%s","remote_root":"%s"}\n' "$Q" "$R" > "$T/route"
chmod 600 "$T/route"
FM_HOME="$L" bash -c '"$1" reserve remote --generation gremote --kind secondmate --harness claude --model unpooled --holder-pid "$$" && "$1" dispatch remote --generation gremote --route-file "$2"; rc=$?; exit "$rc"' _ "$S" "$T/route"
printf '{"schema":"fm-remote-seat-operation.v2","task":"remote","operation":"gremote","requested_generation":"gremote","actual_generation":null,"previous_generation":null,"disposition":"prelaunch","startup_confirmed":false,"old_stopped":false,"route":null,"actual_model":null,"complete":true}\n' > "$T/response"
chmod 600 "$T/response"
set +e
FM_HOME="$P" "$S" reconcile-remote remote --generation gremote --response-file "$T/response"
rc=$?
set -e
[ "$rc" != 0 ]
FM_HOME="$L" "$S" reconcile-remote remote --generation gremote --response-file "$T/response"
FM_HOME="$L" "$S" show remote > "$E/nested-owner-reconciliation.json"
jq -e '.incarnations[0].lifecycle=="released"' "$E/nested-owner-reconciliation.json"
echo 'Observed: root cannot reconcile descendant-owned remote; registry owner can, using root ledger.'
# Real host-control validation and same-token replay, stopped before Herdr.
cp "$R/AGENTS.md" "$Q/AGENTS.md"
ln -s "$R/bin" "$Q/bin"
mkdir -p "$Q/state/parent-route"
C=$R/bin/fm-remote-secondmate-control.sh
set +e
FM_HOME="$Q" "$C" launch remote claude pool-model-a - herdr --operation invalidop < /dev/null
rc=$?
set -e
[ "$rc" != 0 ]
[ ! -f "$Q/state/parent-route/remote.seat-reservation.invalidop" ]
echo 'Observed: arbitrary operation token rejected before reservation or lifecycle effects.'
printf '{"placement":"remote","backend":"herdr","target":null,"spawn_gen":null,"operation":"guardop","host":"lab-host","home":"%s","remote_root":"%s"}\n' "$Q" "$R" > "$T/route"
FM_HOME="$L" bash -c '"$1" reserve remote --generation guardop --kind secondmate --harness unverified --model unpooled --holder-pid "$$" && "$1" dispatch remote --generation guardop --route-file "$2"; rc=$?; exit "$rc"' _ "$S" "$T/route"
FM_HOME="$L" "$S" show remote | jq -c '{schema,task,incarnations:[.incarnations[]|select(.generation=="guardop")]}' > "$T/reservation"
for attempt in 1 2; do
 set +e
 FM_HOME="$Q" "$C" launch remote unverified unpooled - herdr --operation guardop < "$T/reservation"
 rc=$?
 set -e
 [ "$rc" != 0 ]
done
[ -f "$Q/state/parent-route/remote.seat-reservation.guardop" ]
# Missing receipt, retained reservation: never replay the launch effect.
rm "$Q/state/parent-route/remote.seat-operation.guardop"
set +e
FM_HOME="$Q" "$C" launch remote claude unpooled - herdr --operation guardop < "$T/reservation"
rc=$?
set -e
[ "$rc" != 0 ]; [ ! -f "$Q/state/parent-route/remote.meta" ]
echo 'Observed: verified reservation claimed once; prelaunch retry and missing-receipt retry refuse to repeat lifecycle effects.'
