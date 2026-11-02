#!/usr/bin/env bash
# Live driver: a real primary watcher serve pass over the real remote
# transport stack (fm-on -> fm-remote-entrypoint -> remote job worker). Only
# ssh itself is replaced by a local-exec shim so the "remote host" is a
# disposable lab home on this machine.
set -u
ROOT=/home/art/.no-mistakes/worktrees/9f75ec418609/01M6DDN8CWC4PFXJKN77TZ98SJ
SEATS="$ROOT/bin/fm-fleet-seats.sh"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || exit 1
PRIMARY="$LAB/primary"
MATE="$LAB/mate"
REMOTE="$LAB/theshop"
JOBS="$LAB/remote-jobs"
HOST=live-shop-host
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
for h in "$PRIMARY" "$MATE" "$REMOTE"; do "$ROOT/bin/fm-lab-home.sh" create "$h" >/dev/null || exit 1; done
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$PRIMARY" > "$MATE/.fm-secondmate-parent"
printf 'mate\n' > "$MATE/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=primary\n' > "$REMOTE/.fm-secondmate-parent"
printf 'theshop\n' > "$REMOTE/.fm-secondmate-home"
printf -- '- mate - live local secondmate. (home: %s; scope: live; projects: ; added 2026-11-02)\n' "$MATE" >> "$PRIMARY/data/secondmates.md"
printf -- '- theshop - live remote secondmate. (host: %s; root: %s; home: %s; scope: live; projects: ; added 2026-11-02)\n' \
  "$HOST" "$ROOT" "$REMOTE" >> "$PRIMARY/data/secondmates.md"
cat > "$PRIMARY/config/fleet-seats" <<'JSON'
{"pools":[{"name":"shared","capacity":3,"models":["live-model-a","live-model-b"]}]}
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

seats() { local home=$1; shift; env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$home" "$SEATS" "$@"; }
serve() {
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$PRIMARY" FM_SSH_BIN="$LAB/bin/ssh" \
    FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_STATE_ROOT="$JOBS" \
    FM_FLEET_SEATS_TEST_BACKOFF=0 "$SEATS" serve-remotes
}
reserve() { local id=$1 model=$2; holder; seats "$PRIMARY" reserve "$id" --generation "g-$id" --harness claude --model "$model" --holder-pid "$LAST"; }

echo "== lab: $LAB"
echo "== 2-pre: an agent already running on the remote before pools were enabled"
printf 'kind=ship\nmodel=live-model-a\nharness=claude\n' > "$REMOTE/state/shop-legacy.meta"
echo "== 2a: primary grant before the remote confirmed the policy must refuse"
reserve p-early live-model-a; echo "rc=$?"
echo "== 2b: first real serve pass"
serve; echo "rc=$?"
echo "== 2c: the certificate the root published"
jq -c '{epoch, complete, holders}' "$PRIMARY/state/fleet-seats/remote-theshop.cert"
echo "== 2d: a primary launch now sees the pre-pool supervisor exactly once"
reserve p1 live-model-a; echo "rc=$?"
echo "== 2e: a second serve pass does not double-charge that supervisor"
serve; echo "rc=$?"
jq -c '{epoch, holders: (.holders | length)}' "$PRIMARY/state/fleet-seats/remote-theshop.cert"
reserve p2 live-model-a; echo "rc=$?"
echo "== 2f: the full pool refuses the next launch across all three homes"
reserve p3 live-model-b; echo "rc=$?"
echo "== done"
