#!/usr/bin/env bash
# Live combined drive for the opt-in Pi model-stream silence capability.
#
# Chain exercised end to end with REAL product code:
#   real fm-spawn.sh + real Pi 1.2.0 -> generated worker extension
#   real Pi 1.2.0 SDK agent loop -> real generated extension -> real bin/fm-busy-event.sh
#   real tmux window + real bin/fm-watch.sh poll -> published inspection wake naming model silence
# Stand-ins: the spawn's pane multiplexer (a stub that only records the window it
# would have created; the window itself is a REAL tmux window driven below), the
# hermetic crew-state verdict, and the synthetic local provider transport.
# No network, no credentials, no fleet state.
set -u
export PATH="/tmp/fm-pi120/node_modules/.bin:$PATH"
ROOT=/home/art/.no-mistakes/worktrees/9f75ec418609/01M691BS1E935R4G6VD0D4CGR1
EVID=/home/art/.no-mistakes/evidence/01M691BS1E935R4G6VD0D4CGR1
# shellcheck source=/dev/null
. "$ROOT/tests/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-combined-live)
# shellcheck source=/dev/null
. "$ROOT/tests/watch-triage-helpers.sh"

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-combined-lab.XXXXXX")
TMUXDIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-combined-tmux.XXXXXX")
export TMUX_TMPDIR="$TMUXDIR"
cleanup() {
  [ -z "${WATCH_PID:-}" ] || kill "$WATCH_PID" 2>/dev/null || true
  [ -z "${NODE_PID:-}" ] || kill "$NODE_PID" 2>/dev/null || true
  tmux kill-server 2>/dev/null || true
  chmod -R u+w "$LAB" "$TMUXDIR" 2>/dev/null || true
  rm -rf "$LAB" "$TMUXDIR" 2>/dev/null || true
}
trap cleanup EXIT

home="$LAB/home"
project="$LAB/project"
wt="$LAB/wt"
cmd="$LAB/cmd"
mkdir -p "$cmd" "$home/agent"
cap="$LAB/pane.txt"
printf 'Working...\n' > "$cap"

say() { printf '\n### %s\n' "$*"; }
prime_turnend_seen() {  # <file>
  local f=$1 base
  base=$(basename "$f" | tr '.' '_')
  printf '%s' "$(seen_sig "$f")" > "$(dirname "$f")/.seen-$base"
}

say "1. spawn a Pi worker with the opt-in option set (real fm-spawn + real pi $(pi --version))"
fm_test_spawn_home "$home" pi
fm_git_worktree "$project" "$wt" "stream-combined"
fm_test_spawn_brief "$home" stream
spawn_fakebin=$(make_spawn_fakebin "$LAB/fake-spawn")
spawn_out=$(FM_STREAM_SILENT_MAX_SECS=8 fm_test_run_spawn "$home" "$wt" "$spawn_fakebin" \
  stream "$project" pi --mode no-mistakes --yolo off) || {
  printf 'spawn failed: %s\n' "$spawn_out" >&2
  exit 1
}
printf '%s\n' "$spawn_out" | tail -1
if printf '%s\n' "$spawn_out" | grep -F 'model-stream observation unavailable' >/dev/null; then
  echo "verified pi $(pi --version) produced an unverified-version warning" >&2
  exit 1
fi
[ -s "$home/state/stream.pi-ext.ts" ] || { echo "spawn did not generate the worker extension" >&2; exit 1; }
win=$(grep '^window=' "$home/state/stream.meta" | cut -d= -f2-)
echo "recorded meta window: $win"
echo "recorded harness: $(grep '^harness=' "$home/state/stream.meta")"
echo "busy record after spawn: $(cat "$home/state/stream.busy-state")"

say "2. stand the spawned window up as a REAL tmux window on a private server"
mkdir -p "$TMUXDIR/agentbin"
# A live foreground process for the real pane. The watcher never asks this
# process for a verdict: the busy/model-phase evidence comes from the real
# writer above. It only has to be a real long-lived process in a real pane.
printf '#!/usr/bin/env bash\nwhile :; do sleep 1; done\n' > "$TMUXDIR/agentbin/pi"
chmod +x "$TMUXDIR/agentbin/pi"
session=${win%%:*}
wshort=${win#*:}
tmux new-session -d -s "$session" -n "$wshort" "$TMUXDIR/agentbin/pi"
tmux list-windows -t "$session"
echo "foreground command: $(tmux display-message -p -t "$win" '#{pane_current_command}')"

say "3. drive the spawned extension through the real Pi 1.2.0 SDK, holding a stalled stream"
cat > "$home/agent/models.json" <<'JSON'
{"providers":{"fm-combined":{"baseUrl":"https://fm-combined.invalid/v1","api":"openai-completions","apiKey":"synthetic-local-only","models":[{"id":"stream","name":"stream","contextWindow":8192,"maxTokens":512}]}}}
JSON
PI_PACKAGE_DIR=$(node -e 'const fs=require("node:fs"),p=require("node:path");console.log(p.resolve(p.dirname(fs.realpathSync(process.argv[1])),"../.."));' "$(command -v pi)")
env -i PATH="$PATH" HOME="$home/user-home" NODE_NO_WARNINGS=1 \
  PI_PACKAGE_DIR="$PI_PACKAGE_DIR" PI_CODING_AGENT_DIR="$home/agent" \
  STREAM_STATE="$home/state" STREAM_EXTENSION="$home/state/stream.pi-ext.ts" \
  STREAM_CWD="$wt" CMD_DIR="$cmd" \
  node "$EVID/combined-worker.mjs" > "$EVID/combined-worker.log" 2>&1 &
NODE_PID=$!
for _ in $(seq 1 400); do
  [ -e "$home/state/stream.model-progress" ] && [ -s "$home/state/stream.model-stream" ] && break
  kill -0 "$NODE_PID" 2>/dev/null || { echo "worker died:"; cat "$EVID/combined-worker.log"; exit 1; }
  sleep 0.1
done
[ -s "$home/state/stream.model-stream" ] || { echo "live stream evidence never appeared" >&2; exit 1; }
echo "live foreground stream evidence: $(cat "$home/state/stream.model-stream")"
echo "model progress anchor:          $(cat "$home/state/stream.model-progress")"
echo "busy record:                    $(cat "$home/state/stream.busy-state")"

# Watcher world: REAL tmux window, REAL fm-watch.sh, hermetic crew-state verdict.
dir=$(make_case watch)
watch_fakebin="$dir/fakebin"

run_watch() {  # <out-file>
  local out=$1
  PATH="/usr/bin:/bin:/run/current-system/sw/bin" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" FM_CREW_STATE_BIN="$watch_fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: hermetic · combined drive' \
    FM_STREAM_SILENT_MAX_SECS=8 FM_BUSY_TURN_MAX_SECS=99999 FM_WEDGE_MAX_ESCALATIONS=0 \
    FM_STALE_ESCALATE_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch.sh" > "$out" 2>&1 &
  WATCH_PID=$!
}

req1=$(sed -n 's/^v1 gen=[^ ]* request=\([0-9][0-9]*\) .*/\1/p' "$home/state/stream.model-stream")

say "4. sustained live silence: the real watcher must escalate early naming model-stream silence"
run_watch "$EVID/combined-phase1-watch.out"
rc=0
wait_for_exit "$WATCH_PID" 400 || rc=$?
WATCH_PID=
[ "$rc" -eq 0 ] || { echo "watcher did not surface (rc=$rc)"; cat "$EVID/combined-phase1-watch.out"; exit 1; }
cat "$EVID/combined-phase1-watch.out"
grep -F 'model stream silent for' "$EVID/combined-phase1-watch.out" >/dev/null \
  || { echo "escalation did not name model-stream silence" >&2; exit 1; }
grep -F 'possible wedge' "$EVID/combined-phase1-watch.out" >/dev/null \
  || { echo "escalation bypassed the inspection reason" >&2; exit 1; }
grep -F 'escalation 1' "$EVID/combined-phase1-watch.out" >/dev/null \
  || { echo "escalation did not use the existing escalation cadence" >&2; exit 1; }
echo "wake-queue row: $(cat "$home/state/.wake-queue")"
key=$(printf '%s' "$win" | tr ':/.' '___')
echo "escalation count: $(cat "$home/state/.wedge-escalations-$key" 2>/dev/null)"

say "5. settle phase one through the real extension, then acknowledge the wake"
: > "$cmd/finish-1"
for _ in $(seq 1 400); do
  [ -e "$cmd/phase1-settled" ] && break
  sleep 0.1
done
[ ! -e "$home/state/stream.model-stream" ] || { echo "settled phase one retained stream evidence" >&2; exit 1; }
echo "after assistant completion: model-stream marker absent, busy record $(cat "$home/state/stream.busy-state")"
prime_turnend_seen "$home/state/stream.turn-ended"
ack_stopped_cycle "$home/state" || { echo "wake acknowledgement failed" >&2; exit 1; }
echo "wake acknowledged through the real drain"

say "6. adversarial: live progress during the watcher's silence window must prevent the escalation"
: > "$cmd/go2"
for _ in $(seq 1 400); do
  req2=$(sed -n 's/^v1 gen=[^ ]* request=\([0-9][0-9]*\) .*/\1/p' "$home/state/stream.model-stream" 2>/dev/null)
  [ -n "$req2" ] && [ "$req2" != "$req1" ] && break
  sleep 0.1
done
if [ -z "${req2:-}" ] || [ "${req2:-}" = "$req1" ]; then
  echo "second foreground request never opened"
  echo "--- worker.log"; cat "$EVID/combined-worker.log"
  echo "--- state"; ls "$home/state"
  exit 1
fi
echo "second request evidence: $(cat "$home/state/stream.model-stream")"
run_watch "$EVID/combined-phase2-watch.out"
sleep 2
: > "$cmd/chunk-2"
for _ in $(seq 1 200); do
  n=$(sed -n 's/.*rev=\([0-9][0-9]*\).*/\1/p' "$home/state/stream.model-stream" 2>/dev/null)
  [ "${n:-0}" -ge 2 ] && break
  sleep 0.1
done
echo "progress refreshed mid-window: $(cat "$home/state/stream.model-stream")"
sleep 4
if [ -s "$EVID/combined-phase2-watch.out" ]; then
  echo "watcher published despite fresh progress:"; cat "$EVID/combined-phase2-watch.out"; exit 1
fi
if [ -s "$home/state/.stale-since-$key" ]; then
  echo "obsolete stream episode armed the wedge timer: $(cat "$home/state/.stale-since-$key") (now $(date +%s))"
  echo "--- triage log"; tail -20 "$home/state/.watch-triage.log" 2>/dev/null
  exit 1
fi
[ ! -e "$home/state/.wedge-escalations-$key" ] || { echo "obsolete stream episode counted an escalation" >&2; exit 1; }
echo "watcher output empty; no inspection timer, no escalation count for the silent-while-progressing request"
kill "$WATCH_PID" 2>/dev/null || true
wait_for_exit "$WATCH_PID" 100 || true
WATCH_PID=

say "7. close phase two through the real extension and confirm clean settle"
: > "$cmd/finish-2"
for _ in $(seq 1 400); do
  [ -e "$cmd/phase2-settled" ] && break
  sleep 0.1
done
wait "$NODE_PID" 2>/dev/null || true
NODE_PID=
cat "$EVID/combined-worker.log"
[ -e "$cmd/phase2-settled" ] || { echo "phase two did not settle"; exit 1; }
[ ! -e "$home/state/stream.model-stream" ] || { echo "settled phase two retained stream evidence" >&2; exit 1; }
echo "final busy record: $(cat "$home/state/stream.busy-state")"
echo
echo "ALL COMBINED LIVE CHECKS PASSED"
