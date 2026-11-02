#!/usr/bin/env bash
# Disposable-lab drive of the T3 turn-start fleet-seat guard
# (bin/backends/t3code.sh + bin/fm-fleet-seats.sh show-t3), exercised through
# the real bin/fm-send.sh against a throwaway T3 Orchestrator V2 server
# (tests/t3-fake-server.mjs) and a throwaway firstmate home.
set -u
REPO=$1
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-t3seat-lab.XXXXXX")
cleanup() {
  [ -z "${SRV_PID:-}" ] || kill "$SRV_PID" 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT

node "$REPO/tests/t3-fake-server.mjs" --case-file "$LAB/casefile" --port-file "$LAB/port" --parent-pid "$$" >"$LAB/server.out" 2>&1 &
SRV_PID=$!
for _ in $(seq 1 100); do [ -s "$LAB/port" ] && break; sleep 0.05; done
[ -s "$LAB/port" ] || { echo "fake T3 server did not start"; cat "$LAB/server.out"; exit 1; }
URL="http://127.0.0.1:$(cat "$LAB/port")"
CASE=$LAB/case-dir
mkdir -p "$CASE"
printf '%s' "$CASE" > "$LAB/casefile"

HOME_DIR=$LAB/home
MATE=$LAB/mate-home
THREAD='mcp:1a2b3c4d-0000-4000-8000-abcdefabcdef'
"$REPO/bin/fm-lab-home.sh" create "$HOME_DIR" >/dev/null || exit 1
mkdir -p "$MATE" "$LAB/repo"
printf '{"pools":[{"name":"t3pool","capacity":1,"models":["pool-model-a"]}]}\n' > "$HOME_DIR/config/fleet-seats"

TOKEN="tok-lab-$RANDOM$RANDOM"
node -e '
const fs = require("fs");
const [file, token, url, thread, repo] = process.argv.slice(1);
const world = {
  tokens: [token],
  environmentId: "env-lab",
  projects: [{ id: "proj-1", title: "repo", workspaceRoot: repo, deletedAt: null,
    defaultModelSelection: { instanceId: "claudeAgent", model: "claude-sonnet-5" } }],
  threads: {
    [thread]: { threadId: thread, projectId: "proj-1", status: "completed", activeRunId: null,
      archived: false, worktreePath: null, pendingRequestCount: 0, providerInstanceId: "claudeAgent",
      runtimeMode: "full-access", parentThreadId: null,
      items: [{ type: "user_message", status: "completed", text: "do the thing" }],
      runs: [{ runId: "run-1", status: "completed", requestedAt: "2026-09-14T00:00:00.000Z",
        startedAt: "2026-09-14T00:00:00.000Z", completedAt: "2026-09-14T00:00:02.000Z" }] }
  }
};
fs.writeFileSync(file, JSON.stringify(world));
' "$CASE/world.json" "$TOKEN" "$URL" "$THREAD" "$LAB/repo"
: > "$CASE/requests.jsonl"
( umask 077
  printf '{"version":1,"origin":"%s","access_token":"%s","issued_at":0,"expires_at":%s,"access":"full-access","environment_id":"env-lab","server_version":"0.0.46-nightly.fake"}\n' \
    "$URL" "$TOKEN" "$(( ($(date +%s) + 86400) * 1000 ))" > "$HOME_DIR/config/t3code-token" )

SEATS=$REPO/bin/fm-fleet-seats.sh
SERVER=$(node -e 'const c=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(JSON.stringify([c.origin,c.environment_id]))' "$HOME_DIR/config/t3code-token")
echo "lab=$LAB"
echo "t3-server=$URL"
echo "recorded-server-identity=$SERVER"

# The secondmate's host-local record, as bin/fm-spawn.sh writes it.
printf 'window=fm-t3mate\nendpoint_task_id=t3mate\nworktree=%s\nproject=%s\nkind=secondmate\nharness=claude\nbackend=t3code\nt3_server=%s\nt3_thread_id=%s\nt3_project_id=proj-1\nhome=%s\nspawn_gen=g-fail\nmodel=pool-model-a\n' \
  "$MATE" "$LAB/repo" "$SERVER" "$THREAD" "$MATE" > "$HOME_DIR/state/t3mate.meta"

seats() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$HOME_DIR" "$SEATS" "$@"; }
send_count() { grep -c '"tool":"t3_thread_send"' "$CASE/requests.jsonl" 2>/dev/null || true; }

echo
echo "=== 1. reserve + dispatch + confirm the secondmate's pooled T3 generation ==="
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$HOME_DIR" \
  SEATS="$SEATS" TARGET="$THREAD" SERVER="$SERVER" HOME_DIR="$HOME_DIR" bash -c '
    "$SEATS" reserve t3mate --generation g-fail --kind secondmate --harness claude --model pool-model-a --holder-pid "$$" || exit 9
    route="$HOME_DIR/route.json"
    ( umask 077; jq -cn --arg t "$TARGET" --arg server "$SERVER" --arg g g-fail \
      "{placement:\"local\",backend:\"t3code\",target:\$t,spawn_gen:\$g,server_identity:\$server,host:null,remote_root:null}" > "$route" )
    "$SEATS" dispatch t3mate --generation g-fail --route-file "$route" || exit 9
    "$SEATS" confirm t3mate --generation g-fail || exit 9
  '
echo "seat lifecycle: $(seats show t3mate | jq -r '.incarnations[]|select(.generation=="g-fail")|.lifecycle')"
echo "show-t3 finds the guarded endpoint: $(seats show-t3 "$THREAD" "$SERVER" | jq -r '.task' 2>/dev/null)"

echo
echo "=== 2. a confirmed generation still receives its turn (positive control) ==="
before=$(send_count)
out=$(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$HOME_DIR" \
  "$REPO/bin/fm-send.sh" t3mate continue 2>&1); rc=$?
echo "fm-send rc=$rc out=$out"
echo "t3_thread_send calls: before=$before after=$(send_count)"

echo
echo "=== 3. the failed run's recovery resumes the still-counted generation (positive control) ==="
node -e '
const fs = require("fs");
const [file, thread] = process.argv.slice(1);
const w = JSON.parse(fs.readFileSync(file, "utf8"));
w.threads[thread].status = "failed";
w.threads[thread].runs[0].status = "failed";
fs.writeFileSync(file, JSON.stringify(w));
' "$CASE/world.json" "$THREAD"
before=$(send_count)
out=$(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
  FM_HOME="$HOME_DIR" STATE="$HOME_DIR/state" bash -c '
  . "$0/bin/fm-secondmate-liveness-lib.sh"
  fm_secondmate_liveness_probe "$1" t3mate poll
  printf "probe=%s resume=%s\n" "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_RESUME"
  fm_secondmate_liveness_relaunch "$1" t3mate && echo relaunched=yes || echo relaunched=no
' "$REPO" "$HOME_DIR/state/t3mate.meta" 2>&1)
echo "$out" | grep -v '^{' | head -6
echo "t3_thread_send calls: before=$before after=$(send_count)"

echo
echo "=== 4. reconciliation reclaims the failed generation (dead-after-start) ==="
seats reclaim t3mate --generation g-fail; echo "reclaim rc=$?"
echo "seat lifecycle: $(seats show t3mate | jq -r '.incarnations[]|select(.generation=="g-fail")|.lifecycle')"

echo
echo "=== 5. recovery must not resume the reclaimed generation ==="
before=$(send_count)
out=$(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
  FM_HOME="$HOME_DIR" STATE="$HOME_DIR/state" bash -c '
  . "$0/bin/fm-secondmate-liveness-lib.sh"
  fm_secondmate_liveness_probe "$1" t3mate poll
  printf "probe=%s|%s\n" "$FM_SM_LIVE_STATUS" "$FM_SM_LIVE_REASON"
  fm_secondmate_liveness_relaunch "$1" t3mate && echo relaunched=yes || echo relaunched=no
' "$REPO" "$HOME_DIR/state/t3mate.meta" 2>&1)
echo "$out" | grep -v '^{' | head -6
echo "t3_thread_send calls: before=$before after=$(send_count)"

echo
echo "=== 6. the shared T3 turn-start boundary refuses the reclaimed generation ==="
for label in 'send_text_submit' 'resume_failed'; do
  before=$(send_count)
  rc=0
  case "$label" in
    send_text_submit) snippet='fm_backend_t3code_send_text_submit "$1" continue 1 0.01 0.01' ;;
    resume_failed) snippet='fm_backend_t3code_resume_failed "$1"' ;;
  esac
  out=$(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/config" bash -c \
    '. "$0/bin/fm-backend.sh"; fm_backend_source t3code || exit 1; '"$snippet" "$REPO" "$THREAD" 2>&1) || rc=$?
  echo "$label rc=$rc out=$(printf '%s' "$out" | tr '\n' ' ')"
  echo "t3_thread_send calls: before=$before after=$(send_count)"
done

echo
echo "=== 7. removing the task record does not unlock the reclaimed thread ==="
mv "$HOME_DIR/state/t3mate.meta" "$HOME_DIR/state/t3mate.saved"
before=$(send_count); rc=0
out=$(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
  FM_HOME="$HOME_DIR" FM_CONFIG_OVERRIDE="$HOME_DIR/config" bash -c \
  '. "$0/bin/fm-backend.sh"; fm_backend_source t3code || exit 1; fm_backend_t3code_send_text_submit "$1" continue 1 0.01 0.01' "$REPO" "$THREAD" 2>&1) || rc=$?
echo "no-meta send rc=$rc out=$(printf '%s' "$out" | tr '\n' ' ')"
echo "t3_thread_send calls: before=$before after=$(send_count)"
mv "$HOME_DIR/state/t3mate.saved" "$HOME_DIR/state/t3mate.meta"

echo
echo "=== 8. another local caller state cannot bypass the reclaimed thread ==="
OTHER=$LAB/other-home
mkdir -p "$OTHER/state"
printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$HOME_DIR" > "$OTHER/.fm-secondmate-parent"
before=$(send_count); rc=0
out=$(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
  FM_HOME="$OTHER" FM_STATE_OVERRIDE="$OTHER/state" FM_CONFIG_OVERRIDE="$HOME_DIR/config" bash -c \
  '. "$0/bin/fm-backend.sh"; fm_backend_source t3code || exit 1; fm_backend_t3code_send_text_submit "$1" continue 1 0.01 0.01' "$REPO" "$THREAD" 2>&1) || rc=$?
echo "other-home send rc=$rc out=$(printf '%s' "$out" | tr '\n' ' ')"
echo "t3_thread_send calls: before=$before after=$(send_count)"

echo
echo "=== 9. capacity is genuinely free for a replacement seat ==="
seats reserve contender --generation g-other --kind secondmate --harness claude --model pool-model-a --holder-pid "$$" 2>&1
echo "reserve contender rc=$?"
