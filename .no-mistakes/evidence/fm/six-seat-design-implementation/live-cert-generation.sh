#!/usr/bin/env bash
# Live driver: a generation that only the remote's serve certificate names must
# never be read as a generation the seat ledger failed to issue; a generation
# the record claims that no ledger incarnation issued must still fail closed.
set -u
ROOT=/home/art/.no-mistakes/worktrees/9f75ec418609/01M6DDN8CWC4PFXJKN77TZ98SJ
SEATS="$ROOT/bin/fm-fleet-seats.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || exit 1
PRIMARY="$LAB/primary"; REMOTE="$LAB/theshop"; JOBS="$LAB/remote-jobs"; HOST=live-shop-host
PIDS=
cleanup() {
  local pid
  for pid in $PIDS; do kill "$pid" 2>/dev/null || true; done
  if [ -f "$JOBS/worker.pid" ]; then
    ( . "$ROOT/bin/fm-remote-job-lib.sh" && fm_remote_job_stop_worker_tree "$(cat "$JOBS/worker.pid")" ) || true
  fi
  rm -rf "$LAB"
}
trap cleanup EXIT
holder() { sleep 600 >/dev/null 2>&1 & PIDS="$PIDS $!"; LAST=$!; }
for h in "$PRIMARY" "$REMOTE"; do "$ROOT/bin/fm-lab-home.sh" create "$h" >/dev/null || exit 1; done
printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=primary\n' > "$REMOTE/.fm-secondmate-parent"
printf 'theshop\n' > "$REMOTE/.fm-secondmate-home"
mkdir -p "$REMOTE/state/parent-route"
printf -- '- theshop - live remote secondmate. (host: %s; root: %s; home: %s; scope: live; projects: ; added 2026-11-02)\n' \
  "$HOST" "$ROOT" "$REMOTE" >> "$PRIMARY/data/secondmates.md"
cat > "$PRIMARY/config/fleet-seats" <<'JSON'
{"pools":[{"name":"shared","capacity":5,"models":["live-model-a","live-model-b"]}]}
JSON
mkdir -p "$LAB/bin"
cat > "$LAB/bin/ssh" <<SH
#!/usr/bin/env bash
while [ "\$#" -gt 0 ]; do
  case "\$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
[ "\${1:-}" = $HOST ] || exit 91
[ "\${2:-}" = fm-remote-entrypoint.sh ] || exit 92
shift 2
exec "$ROOT/bin/fm-remote-entrypoint.sh" "\$@"
SH
chmod +x "$LAB/bin/ssh"
# The remote host's own supervisor record: a second mate launched before pools
# existed. It reports the generation its endpoint was created with, which the
# parent's ledger never issued.
fm_write_meta() { local file=$1; shift; : > "$file"; local kv; for kv in "$@"; do printf '%s\n' "$kv" >> "$file"; done; }
fm_write_meta "$REMOTE/state/parent-route/theshop.meta" \
  window=theshop:live.p1 backend=herdr endpoint_task_id=theshop herdr_session=fm-remote \
  "home=$REMOTE" "worktree=$REMOTE" "project=$ROOT" harness=claude model=live-model-a kind=secondmate \
  mode=secondmate spawn_gen=cert-only.4104.1

seats() { local home=$1; shift; env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$home" "$SEATS" "$@"; }
serve() {
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$PRIMARY" FM_SSH_BIN="$LAB/bin/ssh" \
    FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_STATE_ROOT="$JOBS" \
    FM_FLEET_SEATS_TEST_BACKOFF=0 "$SEATS" serve-remotes
}
reserve() { local id=$1 model=$2; holder; seats "$PRIMARY" reserve "$id" --generation "g-$id" --harness claude --model "$model" --holder-pid "$LAST"; }

echo "== lab: $LAB"
echo "== 5a: real serve pass publishes the certificate"
serve; echo "rc=$?"
jq -c '{holders: [.holders[] | {task, generation, model}]}' "$PRIMARY/state/fleet-seats/remote-theshop.cert"
echo "== 5b: the parent's own route record for that remote names no generation"
fm_write_meta "$PRIMARY/state/theshop.meta" kind=secondmate model=live-model-a harness=claude \
  remote_host="$HOST" remote_root="$ROOT" "home=$REMOTE" "worktree=$REMOTE" route=remote
echo "== 5c: the certificate-derived generation is admitted, not read as a failed issue"
reserve p1 live-model-a; echo "rc=$?"
echo "== 5d: the same remote now holds a real ledger seat of its own"
reserve theshop live-model-a; echo "rc=$?"
echo "== 5e: adversarial - a generation no ledger incarnation issued still fails closed"
printf 'spawn_gen=never-issued.1\n' >> "$PRIMARY/state/theshop.meta"
reserve p2 live-model-a; echo "rc=$?"
echo "== done"
