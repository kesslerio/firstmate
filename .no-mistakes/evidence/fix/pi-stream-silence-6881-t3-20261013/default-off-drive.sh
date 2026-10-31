#!/usr/bin/env bash
# Live default-off drive for the opt-in Pi model-stream silence capability.
#
# Part 1: REAL tmux pane + REAL bin/fm-watch.sh with FM_STREAM_SILENT_MAX_SECS
#   UNSET, against a home that carries a backdated "current" stream observation
#   written by the REAL bin/fm-busy-event.sh. The unset option must leave the
#   general busy bound in force: no escalation, no inspection timer, no wake.
# Part 2: REAL fm-spawn.sh with FM_STREAM_SILENT_MAX_SECS UNSET and real Pi
#   1.2.0, then the spawned extension driven through the real Pi SDK with a
#   foreground stream held open. No stream warning, no model-stream evidence,
#   while the semantic busy/idle record still moves.
set -u
export PATH="/tmp/fm-pi120/node_modules/.bin:$PATH"
ROOT=/home/art/.no-mistakes/worktrees/9f75ec418609/01M691BS1E935R4G6VD0D4CGR1
EVID=/home/art/.no-mistakes/evidence/01M691BS1E935R4G6VD0D4CGR1
# shellcheck source=/dev/null
. "$ROOT/tests/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-default-off-live)
# shellcheck source=/dev/null
. "$ROOT/tests/watch-triage-helpers.sh"
BUSY="$ROOT/bin/fm-busy-event.sh"
WATCH="$ROOT/bin/fm-watch.sh"

say() { printf '\n### %s\n' "$*"; }

say "1. watcher with FM_STREAM_SILENT_MAX_SECS unset ignores a backdated stream observation (real tmux pane)"
TMUXDIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-default-off-tmux.XXXXXX")
export TMUX_TMPDIR="$TMUXDIR"
mkdir -p "$TMUXDIR/agentbin"
printf '#!/usr/bin/env bash\nwhile :; do sleep 1; done\n' > "$TMUXDIR/agentbin/pi"
chmod +x "$TMUXDIR/agentbin/pi"
tmux new-session -d -s firstmate -n fm-stream-off "$TMUXDIR/agentbin/pi"
PART1_OK=0
cleanup1() {
  [ -z "${WATCH_PID:-}" ] || kill -9 "$WATCH_PID" 2>/dev/null || true
  tmux kill-server 2>/dev/null || true
  chmod -R u+w "$TMUXDIR" 2>/dev/null || true
  rm -rf "$TMUXDIR" 2>/dev/null || true
}
trap cleanup1 EXIT

dir=$(make_case live-off); state="$dir/state"; fakebin="$dir/fakebin"
out="$dir/watch.out"; window="firstmate:fm-stream-off"
key=$(printf '%s' "$window" | tr ':/.' '___')
printf 'working: setup complete\n' > "$state/stream.status"
seen_sig "$state/stream.status" > "$state/.seen-stream_status"
printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/stream.meta"
gen=$("$BUSY" arm "$state" stream)
"$BUSY" apply "$state" stream busy --gen "$gen" --source pi-ext --event agent-start
"$BUSY" stream "$state" stream open --gen "$gen" --request 1
printf 'v1 gen=%s request=1 rev=1 ts=%s\n' "$gen" "$(( $(date +%s) - 600 ))" > "$state/stream.model-stream"
echo "backdated stream evidence: $(cat "$state/stream.model-stream")"
env -u FM_STREAM_SILENT_MAX_SECS PATH="$PATH" FM_STATE_OVERRIDE="$state" \
  FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
  FM_FAKE_CREW_STATE='state: working · source: live · default-off drive' \
  FM_BUSY_TURN_MAX_SECS=99999 FM_STALE_ESCALATE_SECS=2 FM_POLL=1 FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>&1 &
WATCH_PID=$!
if ! wait_poll_cycle "$state" "$WATCH_PID" 200; then
  reap "$WATCH_PID"; echo "FAIL unset-option watcher exited: $(cat "$out")"; exit 1
fi
wait_poll_cycle "$state" "$WATCH_PID" 200 || true
echo "--- watcher alive after two polls: $(kill -0 "$WATCH_PID" 2>/dev/null && echo yes || echo no)"
echo "--- watch stdout:"; cat "$out"; [ -s "$out" ] || echo '(empty)'
echo "--- wake queue:"; cat "$state/.wake-queue" 2>/dev/null || echo '(none)'
echo "--- inspection timer:"; cat "$state/.stale-since-$key" 2>/dev/null || echo '(none)'
echo "--- escalation count:"; cat "$state/.wedge-escalations-$key" 2>/dev/null || echo '(none)'
echo "--- triage log:"; cat "$state/.watch-triage.log" 2>/dev/null || echo '(none)'
[ ! -s "$out" ] || { reap "$WATCH_PID"; echo 'FAIL unset option published a wake'; exit 1; }
[ ! -e "$state/.wake-queue" ] || { reap "$WATCH_PID"; echo 'FAIL unset option queued a wake'; exit 1; }
[ ! -e "$state/.stale-since-$key" ] || { reap "$WATCH_PID"; echo 'FAIL unset option armed the inspection timer'; exit 1; }
[ ! -e "$state/.wedge-escalations-$key" ] || { reap "$WATCH_PID"; echo 'FAIL unset option counted an escalation'; exit 1; }
reap "$WATCH_PID"
PART1_OK=1
echo 'PASS unset option leaves the general busy bound in force'
cleanup1
trap - EXIT

say "2. spawn with FM_STREAM_SILENT_MAX_SECS unset: no warning, and the spawned extension records no stream evidence"
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-default-off-lab.XXXXXX")
cleanup2() {
  [ -z "${NODE_PID:-}" ] || kill -9 "$NODE_PID" 2>/dev/null || true
  chmod -R u+w "$LAB" 2>/dev/null || true
  rm -rf "$LAB" 2>/dev/null || true
}
trap cleanup2 EXIT
home="$LAB/home"; project="$LAB/project"; wt="$LAB/wt"; cmd="$LAB/cmd"
mkdir -p "$cmd" "$home/agent"
fm_test_spawn_home "$home" pi
fm_git_worktree "$project" "$wt" "default-off"
fm_test_spawn_brief "$home" stream
spawn_fakebin=$(make_spawn_fakebin "$LAB/fake-spawn")
spawn_out=$(
  unset FM_STREAM_SILENT_MAX_SECS
  fm_test_run_spawn "$home" "$wt" "$spawn_fakebin" stream "$project" pi --mode no-mistakes --yolo off
) || { echo "spawn failed: $spawn_out"; exit 1; }
printf '%s\n' "$spawn_out" | tail -1
if printf '%s\n' "$spawn_out" | grep -F 'model-stream observation unavailable' >/dev/null; then
  echo 'FAIL unset option produced a version warning' >&2; exit 1
fi
if printf '%s\n' "$spawn_out" | grep -Ei 'warning:[^\n]*(model-stream|stream observation)' >/dev/null; then
  echo 'FAIL unset option produced a stream-observation warning' >&2; exit 1
fi
printf '%s\n' "$spawn_out" | grep -Ei 'warning:' || echo '(spawn output carried no warning)'
echo "spawn output carried no model-stream warning for documented default-off"
cat > "$home/agent/models.json" <<'JSON'
{"providers":{"fm-combined":{"baseUrl":"https://fm-combined.invalid/v1","api":"openai-completions","apiKey":"synthetic-local-only","models":[{"id":"stream","name":"stream","contextWindow":8192,"maxTokens":512}]}}}
JSON
PI_PACKAGE_DIR=$(node -e 'const fs=require("node:fs"),p=require("node:path");console.log(p.resolve(p.dirname(fs.realpathSync(process.argv[1])),"../.."));' "$(command -v pi)")
env -i PATH="$PATH" HOME="$home/user-home" NODE_NO_WARNINGS=1 \
  PI_PACKAGE_DIR="$PI_PACKAGE_DIR" PI_CODING_AGENT_DIR="$home/agent" \
  STREAM_STATE="$home/state" STREAM_EXTENSION="$home/state/stream.pi-ext.ts" \
  STREAM_CWD="$wt" CMD_DIR="$cmd" \
  node "$EVID/combined-worker.mjs" > "$EVID/default-off-worker.log" 2>&1 &
NODE_PID=$!
for _ in $(seq 1 400); do [ -e "$cmd/sdk-ready" ] && break; sleep 0.1; done
sleep 4
echo "busy record while the foreground request is held: $(cat "$home/state/stream.busy-state")"
echo "model-stream marker present: $( [ -e "$home/state/stream.model-stream" ] && echo yes || echo no )"
echo "model-progress marker present: $( [ -e "$home/state/stream.model-progress" ] && echo yes || echo no )"
grep -F 'state=busy source=pi-ext' "$home/state/stream.busy-state" >/dev/null \
  || { echo 'FAIL default-off worker lost its semantic busy record' >&2; exit 1; }
[ ! -e "$home/state/stream.model-stream" ] || { echo 'FAIL default-off worker recorded stream evidence' >&2; exit 1; }
[ ! -e "$home/state/stream.model-progress" ] || { echo 'FAIL default-off worker recorded model progress' >&2; exit 1; }
: > "$cmd/finish-1"
for _ in $(seq 1 400); do [ -e "$cmd/phase1-settled" ] && break; sleep 0.1; done
[ ! -e "$home/state/stream.model-stream" ] || { echo 'FAIL settled default-off worker retained stream evidence' >&2; exit 1; }
grep -F 'state=idle source=pi-ext' "$home/state/stream.busy-state" >/dev/null \
  || { echo 'FAIL default-off worker never settled to idle' >&2; exit 1; }
: > "$cmd/go2"; sleep 0.2; : > "$cmd/finish-2"
for _ in $(seq 1 400); do [ -e "$cmd/phase2-settled" ] && break; sleep 0.1; done
wait "$NODE_PID" 2>/dev/null || true
NODE_PID=
cat "$EVID/default-off-worker.log"
[ ! -e "$home/state/stream.model-stream" ] && [ ! -e "$home/state/stream.model-progress" ] \
  || { echo 'FAIL default-off worker left model evidence behind' >&2; exit 1; }
echo 'PASS default-off spawn instruments nothing while semantic busy/idle still moves'
cleanup2
trap - EXIT

[ "$PART1_OK" -eq 1 ] || exit 1
echo
echo 'ALL LIVE DEFAULT-OFF CHECKS PASSED'
