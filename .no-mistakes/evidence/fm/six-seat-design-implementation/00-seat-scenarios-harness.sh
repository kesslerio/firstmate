#!/usr/bin/env bash
# Disposable live drive of fleet seat accounting through the real CLIs.
# ROOT=<code root> bash seat-scenarios.sh <flow>
set -u
ROOT=${ROOT:?}
FLOW=${1:?flow}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-seat-${FLOW}.XXXXXX")
HOLDERS=
cleanup() {
  for p in $HOLDERS; do kill "$p" 2>/dev/null || true; done
  rm -rf "$LAB"
}
trap cleanup EXIT
PARENT=$LAB/parent
SHOP=$LAB/shop
BIN="$ROOT/bin"
SEATS="$BIN/fm-fleet-seats.sh"
CAP=${CAP:-6}
"$BIN/fm-lab-home.sh" create "$PARENT" >/dev/null || exit 1
"$BIN/fm-lab-home.sh" create "$SHOP" >/dev/null || exit 1
printf -- '- theshop - Fixture remote mate. (host: shop-host; root: %s; home: %s; scope: shop; projects: ; added 2026-10-01)\n' \
  "$ROOT" "$SHOP" >> "$PARENT/data/secondmates.md"
printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=primary\n' > "$SHOP/.fm-secondmate-parent"
printf '%s\n' theshop > "$SHOP/.fm-secondmate-home"
printf '{"pools":[{"name":"main","capacity":%s,"models":["pool-model-a","pool-model-b"]}]}\n' "$CAP" > "$PARENT/config/fleet-seats"
cat > "$LAB/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    --) shift; break ;;
    *) exit 90 ;;
  esac
done
host=$1; entry=$2; proto=$3; root_b64=$4; home_b64=$5; argv_b64=$6
payload=$(cat)
argv=$(printf '%s' "$argv_b64" | base64 -d | tr '\0' '\n')
cmd=$(printf '%s\n' "$argv" | sed -n 1p)
verb=$(printf '%s\n' "$argv" | sed -n 2p)
case "$cmd" in
  fm-remote-doctor.sh) printf 'ready\n'; exit 0 ;;
  fm-remote-inherit.sh) exit 0 ;;
  fm-fleet-seats.sh)
    [ "$verb" = serve ] || exit 0
    digest=; epoch=; prev=
    for w in $(printf '%s\n' "$argv" | tr '\n' ' '); do
      case "$prev" in
        --digest) digest=$w ;;
        --epoch) epoch=$w ;;
      esac
      prev=$w
    done
    jq -cn --arg d "$digest" --arg e "$epoch" \
      '{schema:"fm-fleet-seats-serve.v2", policy_digest:$d, epoch:$e, complete:true, holders:[]}'
    exit 0 ;;
  fm-remote-secondmate-control.sh)
    case "$verb" in
      sync) exit 0 ;;
      launch)
        task=$(printf '%s\n' "$argv" | sed -n 3p)
        harness=$(printf '%s\n' "$argv" | sed -n 4p)
        model=$(printf '%s\n' "$argv" | sed -n 5p)
        op=; prev_gen=-; prev=
        for w in $(printf '%s\n' "$argv" | tr '\n' ' '); do
          case "$prev" in
            --operation) op=$w ;;
            --previous) prev_gen=$w ;;
          esac
          prev=$w
        done
        printf 'schema=fm-remote-secondmate-control.v1\n'
        printf 'backend=rex\n'
        printf 'target=00000001-0000-7000-8000-000000000002:00000002-0000-7000-8000-000000000003\n'
        printf 'rex_session_id=session:00000001-0000-7000-8000-000000000002\n'
        case "${FM_TEST_REPLY_SERVER:-unix:///tmp/fake-rex.sock}" in
          bad) printf 'rex_server=tcp://127.0.0.1:7299\n' ;;
          *) printf 'rex_server=unix:///tmp/fake-rex.sock\n' ;;
        esac
        printf 'harness=%s\n' "$harness"
        printf 'model=%s\n' "$model"
        case "${FM_TEST_DISPOSITION:-}" in
          started)
            jq -cnr --arg t "$task" --arg op "$op" --arg p "$prev_gen" --arg m "$model" '
              {schema:"fm-remote-seat-operation.v2", complete:true, task:$t, operation:$op,
               requested_generation:$op, disposition:"started", actual_generation:$op,
               previous_generation:(if $p == "-" then null else $p end), old_stopped:false,
               startup_confirmed:true, actual_model:$m,
               route:{placement:"remote", backend:"rex",
                 target:"00000001-0000-7000-8000-000000000002:00000002-0000-7000-8000-000000000003"}}
              | "seat_disposition=\(tojson)"' ;;
          existing)
            jq -cnr --arg t "$task" --arg op "$op" --arg am "${FM_TEST_ACTUAL_MODEL:-pool-model-b}" '
              {schema:"fm-remote-seat-operation.v2", complete:true, task:$t, operation:$op,
               requested_generation:$op, disposition:"existing", actual_generation:"host.1",
               previous_generation:null, old_stopped:false,
               startup_confirmed:true, actual_model:$am,
               route:{placement:"remote", backend:"rex",
                 target:"00000001-0000-7000-8000-000000000002:00000002-0000-7000-8000-000000000003"}}
              | "seat_disposition=\(tojson)"' ;;
          prelaunch)
            jq -cnr --arg t "$task" --arg op "$op" '
              {schema:"fm-remote-seat-operation.v2", complete:true, task:$t, operation:$op,
               requested_generation:$op, disposition:"prelaunch", actual_generation:null,
               previous_generation:null, old_stopped:false, startup_confirmed:false,
               actual_model:null, route:null}
              | "seat_disposition=\(tojson)"' ;;
        esac
        exit 0 ;;
      state) printf 'dead\n'; exit 0 ;;
      *) exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac
SH
chmod +x "$LAB/fake-ssh"
served=0
serve() {
  [ "$served" -eq 0 ] || return 0
  served=1
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE -u FM_GATE_REFUSE_BYPASS -u NO_MISTAKES_GATE \
    FM_HOME="$PARENT" FM_SSH_BIN="$LAB/fake-ssh" FM_FLEET_SEATS_TEST_BACKOFF=0 \
    "$SEATS" serve-remotes
}
new_holder() { sleep 600 >/dev/null 2>&1 & HOLDERS="$HOLDERS $!"; LAST_HOLDER=$!; }
reserve() {  # <id> [model]
  new_holder
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE -u FM_GATE_REFUSE_BYPASS -u NO_MISTAKES_GATE \
    FM_HOME="$PARENT" "$SEATS" reserve "$1" --generation "g-$1" --harness pi \
      --model "${2:-pool-model-a}" --holder-pid "$LAST_HOLDER"
}
show() {
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE -u FM_GATE_REFUSE_BYPASS -u NO_MISTAKES_GATE \
    FM_HOME="$PARENT" "$SEATS" show "$1"
}
seatcount() {
  listed=0
  for f in "$PARENT"/state/fleet-seats/holders/*.json; do
    [ -f "$f" ] || continue
    n=$(jq '[.incarnations[] | select(.lifecycle == "reserved" or .lifecycle == "confirmed")] | length' "$f")
    listed=$((listed + n))
  done
  echo "$listed"
}
spawn_remote() {  # <disposition> [server]
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE -u FM_GATE_REFUSE_BYPASS -u NO_MISTAKES_GATE \
    FM_HOME="$PARENT" FM_SSH_BIN="$LAB/fake-ssh" \
    FM_TEST_DISPOSITION="${1:-}" FM_TEST_REPLY_SERVER="${2:-ok}" \
    "$BIN/fm-spawn.sh" theshop --secondmate --backend rex --harness codex --model pool-model-a
}
rc_of() { printf 'exit=%s\n' "$1"; }

case "$FLOW" in
  malformed)
    serve > "$LAB/serve.out" 2>&1
    echo "== serve: $(cat "$LAB/serve.out")"
    spawn_remote "" bad > "$LAB/spawn.out" 2>&1
    rc=$?
    echo "== spawn with a non-local Rex server: exit=$rc"
    cat "$LAB/spawn.out"
    echo "== holders after the refused reply: $(seatcount) live"
    gen=$(show theshop | jq -r '[.incarnations[] | select(.lifecycle == "reserved")][-1].generation')
    echo "== the refused candidate is retained as $gen until the host accounts for it"
    echo "== retry before host evidence"
    spawn_remote started > "$LAB/retry.out" 2>&1
    rc=$?
    echo "== retry: exit=$rc"
    cat "$LAB/retry.out"
    echo "== host evidence: the host reports the malformed operation never launched"
    (umask 077 && jq -cn --arg t theshop --arg op "$gen" '
      {schema:"fm-remote-seat-operation.v2", complete:true, task:$t, operation:$op,
       requested_generation:$op, disposition:"prelaunch", actual_generation:null,
       previous_generation:null, old_stopped:false, startup_confirmed:false,
       actual_model:null, route:null}' > "$LAB/prelaunch.json")
    env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
      -u FM_PROJECTS_OVERRIDE -u FM_GATE_REFUSE_BYPASS -u NO_MISTAKES_GATE \
      FM_HOME="$PARENT" "$SEATS" reconcile-remote theshop --generation "$gen" --response-file "$LAB/prelaunch.json"
    echo "== live holders after host evidence: $(seatcount)"
    echo "== retry with a good reply after reconciliation"
    spawn_remote started > "$LAB/retry2.out" 2>&1
    rc=$?
    echo "== retry: exit=$rc"
    cat "$LAB/retry2.out"
    echo "== holders after the retry"
    show theshop | jq -c '{task, incarnations:[.incarnations[]|{generation, lifecycle, launch_phase, model, startup_confirmed}]}'
    echo "== live holders: $(seatcount)"
    ;;
  adopted)
    serve > /dev/null 2>&1
    spawn_remote existing > "$LAB/spawn.out" 2>&1
    rc=$?
    echo "== spawn adopting a running host supervisor on another model: exit=$rc"
    cat "$LAB/spawn.out"
    echo "== parent holder record for theshop"
    show theshop | jq -c '{task, incarnations:[.incarnations[]|{generation, lifecycle, launch_phase, model, requested_model, startup_confirmed}]}'
    echo "== parent live holders"; seatcount
    echo "== parent task record"; cat "$PARENT/state/theshop.meta"
    ;;
  refused)
    serve > /dev/null 2>&1
    spawn_remote prelaunch > "$LAB/spawn.out" 2>&1
    rc=$?
    echo "== spawn refused by the host before launch: exit=$rc"
    cat "$LAB/spawn.out"
    echo "== parent holder record after the prelaunch refusal"
    show theshop | jq -c '{task, incarnations:[.incarnations[]|{generation, lifecycle, disposition, startup_confirmed}]}'
    echo "== parent live holders"; seatcount
    echo "== retry after the refusal"
    spawn_remote started > "$LAB/retry.out" 2>&1
    rc=$?
    echo "== retry: exit=$rc"
    cat "$LAB/retry.out"
    echo "== parent holder record after the retry"
    show theshop | jq -c '{task, incarnations:[.incarnations[]|{generation, lifecycle, launch_phase, model, startup_confirmed}]}'
    seatcount
    ;;
  capacity)
    serve > /dev/null 2>&1
    i=1
    while [ "$i" -le "$CAP" ]; do
      out=$(reserve "seat$i" pool-model-a 2>&1); rc=$?
      echo "reserve seat$i: exit=$rc ${out}"
      i=$((i + 1))
    done
    echo "== live holders after filling the pool: $(seatcount) of $CAP"
    out=$(reserve overflow pool-model-a 2>&1); rc=$?
    echo "reserve overflow: exit=$rc ${out}"
    echo "== live holders after the overflow refusal: $(seatcount) of $CAP"
    # retire one seat and prove capacity returns
    env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
      -u FM_GATE_REFUSE_BYPASS -u NO_MISTAKES_GATE \
      FM_HOME="$PARENT" "$SEATS" release seat1 --generation g-seat1 --reason teardown
    echo "== live holders after retiring seat1: $(seatcount) of $CAP"
    out=$(reserve seat7 pool-model-a 2>&1); rc=$?
    echo "reserve seat7 after retirement: exit=$rc ${out}"
    echo "== live holders: $(seatcount) of $CAP"
    ;;
  *) echo "unknown flow" >&2; exit 2 ;;
esac
exit 0
