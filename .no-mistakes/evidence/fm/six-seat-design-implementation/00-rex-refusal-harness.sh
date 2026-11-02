#!/usr/bin/env bash
# Disposable live drive: a malformed Rex route reply at remote launch admission.
# Usage: ROOT=<code root to drive> bash rex-refusal.sh <reply-mode>
set -u
ROOT=${ROOT:?}
REPLY_MODE=${1:-bad-server}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-rex-refusal.XXXXXX")
cleanup() { rm -rf "$LAB"; }
trap cleanup EXIT
PARENT=$LAB/parent
SHOP=$LAB/shop
BIN="$ROOT/bin"
"$BIN/fm-lab-home.sh" create "$PARENT" >/dev/null || exit 1
"$BIN/fm-lab-home.sh" create "$SHOP" >/dev/null || exit 1
printf -- '- theshop - Fixture remote mate. (host: shop-host; root: %s; home: %s; scope: shop; projects: ; added 2026-10-01)\n' \
  "$ROOT" "$SHOP" >> "$PARENT/data/secondmates.md"
printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=primary\n' > "$SHOP/.fm-secondmate-parent"
printf '%s\n' theshop > "$SHOP/.fm-secondmate-home"
printf '{"pools":[{"name":"main","capacity":2,"models":["pool-model-a"]}]}\n' > "$PARENT/config/fleet-seats"
case "$REPLY_MODE" in
  bad-server)
    cat > "$LAB/reply" <<'EOF'
backend=rex
target=00000001-0000-7000-8000-000000000002:00000002-0000-7000-8000-000000000003
rex_session_id=session:00000001-0000-7000-8000-000000000002
rex_server=tcp://127.0.0.1:7299
harness=codex
EOF
    ;;
  mismatch)
    cat > "$LAB/reply" <<'EOF'
backend=rex
target=99999999-0000-7000-8000-000000000009:00000002-0000-7000-8000-000000000003
rex_session_id=session:00000001-0000-7000-8000-000000000002
rex_server=unix:///tmp/fake-rex.sock
harness=codex
EOF
    ;;
  good)
    cat > "$LAB/reply" <<'EOF'
backend=rex
target=00000001-0000-7000-8000-000000000002:00000002-0000-7000-8000-000000000003
rex_session_id=session:00000001-0000-7000-8000-000000000002
rex_server=unix:///tmp/fake-rex.sock
harness=codex
EOF
    ;;
  *) echo "unknown reply mode $REPLY_MODE" >&2; exit 2 ;;
esac
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
printf 'fake-ssh host=%s cmd=%s verb=%s\n' "$host" "$cmd" "$verb" >> "$FM_TEST_SSH_LOG"
case "$cmd" in
  fm-remote-doctor.sh) printf 'ready\n'; exit 0 ;;
  fm-remote-inherit.sh) exit 0 ;;
  fm-fleet-seats.sh)
    [ "$verb" = serve ] || exit 0
    digest=; epoch=
    rest=$(printf '%s\n' "$argv" | tr '\n' ' ')
    for w in $rest; do
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
        printf 'schema=fm-remote-secondmate-control.v1\n'
        cat "$FM_TEST_REPLY"
        if [ -n "${FM_TEST_SEAT_DISPOSITION:-}" ]; then printf 'seat_disposition=%s\n' "$FM_TEST_SEAT_DISPOSITION"; fi
        exit 0 ;;
      state) printf 'dead\n'; exit 0 ;;
      *) exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac
SH
chmod +x "$LAB/fake-ssh"
serve() {
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE -u FM_GATE_REFUSE_BYPASS -u NO_MISTAKES_GATE \
    FM_HOME="$PARENT" FM_SSH_BIN="$LAB/fake-ssh" FM_TEST_SSH_LOG="$LAB/ssh-serve.log" \
    FM_TEST_REPLY="$LAB/reply" FM_FLEET_SEATS_TEST_BACKOFF=0 \
    "$BIN/fm-fleet-seats.sh" serve-remotes
}
run_spawn() {
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE -u FM_GATE_REFUSE_BYPASS -u NO_MISTAKES_GATE \
    FM_HOME="$PARENT" FM_SSH_BIN="$LAB/fake-ssh" FM_TEST_SSH_LOG="$LAB/ssh-spawn.log" \
    FM_TEST_REPLY="$LAB/reply" FM_TEST_SEAT_DISPOSITION="${SEAT_DISPOSITION:-}" \
    "$BIN/fm-spawn.sh" theshop --secondmate --backend rex --harness codex ${MODEL_ARGS:-}
}
set +e
echo "== serve-remotes"
serve > "$LAB/serve.out" 2>&1
echo "serve_rc=$?"
cat "$LAB/serve.out"
echo "== spawn ($REPLY_MODE)"
run_spawn > "$LAB/spawn.out" 2>&1
echo "spawn_rc=$?"
cat "$LAB/spawn.out"
echo "== seat holder records"
for f in "$PARENT"/state/fleet-seats/holders/*.json; do
  [ -f "$f" ] || continue
  echo "-- $f"
  jq -c '{task, incarnations:[.incarnations[]|{generation, lifecycle, launch_phase, model, disposition, startup_confirmed}]}' "$f"
done
echo "== parent task record"
cat "$PARENT/state/theshop.meta" 2>/dev/null || echo '(none)'
echo "== ssh log"
cat "$LAB/ssh-spawn.log" 2>/dev/null | tail -8
exit 0
