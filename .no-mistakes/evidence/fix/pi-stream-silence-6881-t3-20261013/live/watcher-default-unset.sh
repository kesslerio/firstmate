#!/usr/bin/env bash
# Live check that the model-stream capability is OFF when the option is simply
# unset (the default home): REAL tmux pane, REAL bin/fm-watch.sh, REAL
# bin/fm-busy-event.sh. A backdated live stream record must not cross the busy
# bound, arm the inspection timer, or publish a wake.
set -u
ROOT=/home/art/.no-mistakes/worktrees/9f75ec418609/01M68XQCZ7Y153TTH4XC5XR9V4
# shellcheck source=/dev/null
. "$ROOT/tests/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-live-default)
# shellcheck source=/dev/null
. "$ROOT/tests/watch-triage-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
BUSY="$ROOT/bin/fm-busy-event.sh"

TMUXDIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-default-tmux.XXXXXX")
export TMUX_TMPDIR="$TMUXDIR"
AGENTBIN="$TMUXDIR/agentbin"
mkdir -p "$AGENTBIN"
cat > "$AGENTBIN/pi" <<'PI'
#!/usr/bin/env bash
while :; do sleep 1; done
PI
chmod +x "$AGENTBIN/pi"
tmux new-session -d -s firstmate -n fm-stream-default "$AGENTBIN/pi"
cleanup() {
  tmux kill-server 2>/dev/null || true
  chmod -R u+w "$TMUXDIR" 2>/dev/null || true
  rm -rf "$TMUXDIR" 2>/dev/null || true
}
trap cleanup EXIT

mode=default
dir=$(make_case "live-$mode"); state="$dir/state"; fakebin="$dir/fakebin"
out="$dir/watch.out"; window="firstmate:fm-stream-$mode"
key=$(printf '%s' "$window" | tr ':/.' '___')
printf 'working: setup complete\n' > "$state/stream.status"
seen_sig "$state/stream.status" > "$state/.seen-stream_status"
printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/stream.meta"
gen=$("$BUSY" arm "$state" stream)
"$BUSY" apply "$state" stream busy --gen "$gen" --source pi-ext --event agent-start
"$BUSY" stream "$state" stream open --gen "$gen" --request 1
printf 'v1 gen=%s request=1 rev=1 ts=%s\n' "$gen" "$(( $(date +%s) - 600 ))" > "$state/stream.model-stream"

PATH="$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
  FM_FAKE_CREW_STATE='state: working · source: live · default-off drive' \
  env -u FM_STREAM_SILENT_MAX_SECS FM_BUSY_TURN_MAX_SECS=99999 FM_STALE_ESCALATE_SECS=2 \
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>&1 &
pid=$!
printf 'option in environment: %s\n' "${FM_STREAM_SILENT_MAX_SECS-unset}"
wait_poll_cycle "$state" "$pid" 200 || { reap "$pid"; echo "FAIL default-off watcher exited: $(cat "$out")"; exit 1; }
wait_poll_cycle "$state" "$pid" 200 || { reap "$pid"; echo "FAIL default-off watcher stopped early"; exit 1; }
printf -- '--- watch stdout: '; cat "$out"; [ -s "$out" ] || echo '(empty)'
printf -- '--- wake queue: '; cat "$state/.wake-queue" 2>/dev/null || echo '(none)'
printf -- '--- inspection timer: '; cat "$state/.stale-since-$key" 2>/dev/null || echo '(none)'
printf -- '--- escalation count: '; cat "$state/.wedge-escalations-$key" 2>/dev/null || echo '(none)'
[ ! -s "$out" ] || { reap "$pid"; echo 'FAIL default home published a stream wake'; exit 1; }
[ ! -e "$state/.stale-since-$key" ] || { reap "$pid"; echo 'FAIL default home armed the inspection timer'; exit 1; }
[ ! -e "$state/.wedge-escalations-$key" ] || { reap "$pid"; echo 'FAIL default home counted an escalation'; exit 1; }
[ -s "$state/stream.model-stream" ] || { reap "$pid"; echo 'FAIL live stream record was not present'; exit 1; }
reap "$pid"
echo 'PASS mode=default (unset option leaves the general busy bound in force)'
