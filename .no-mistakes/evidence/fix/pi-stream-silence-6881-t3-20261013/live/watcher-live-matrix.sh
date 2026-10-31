#!/usr/bin/env bash
# Live watcher drive for the opt-in Pi model-stream silence capability.
# Uses the REAL tmux server (private socket dir), the REAL bin/fm-watch.sh, and
# the REAL bin/fm-busy-event.sh writer. The only fixtures are the hermetic
# crew-state verdict and the synthetic busy/stream records the real writer
# produces.
set -u
ROOT=/home/art/.no-mistakes/worktrees/9f75ec418609/01M68XQCZ7Y153TTH4XC5XR9V4
# shellcheck source=/dev/null
. "$ROOT/tests/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-live)
# shellcheck source=/dev/null
. "$ROOT/tests/watch-triage-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
BUSY="$ROOT/bin/fm-busy-event.sh"

# Private real tmux server. TMUX_TMPDIR keeps its socket out of the operator's
# default server; no fake tmux is anywhere on PATH.
TMUXDIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-tmux.XXXXXX")
export TMUX_TMPDIR="$TMUXDIR"
# The pane's foreground process must be a real agent process name so the
# watcher's liveness probe sees a live harness. This is a live stand-in binary,
# not a fake multiplexer: tmux, the watcher, and the writer are all real.
AGENTBIN="$TMUXDIR/agentbin"
mkdir -p "$AGENTBIN"
cat > "$AGENTBIN/pi" <<'PI'
#!/usr/bin/env bash
while :; do sleep 1; done
PI
chmod +x "$AGENTBIN/pi"
tmux new-session -d -s firstmate -n fm-stream-enabled "$AGENTBIN/pi"
tmux new-window -d -t firstmate -n fm-stream-disabled "$AGENTBIN/pi"
tmux new-window -d -t firstmate -n fm-stream-invalid "$AGENTBIN/pi"
tmux new-window -d -t firstmate -n fm-stream-fresh "$AGENTBIN/pi"
tmux new-window -d -t firstmate -n fm-stream-close "$AGENTBIN/pi"
tmux new-window -d -t firstmate -n fm-stream-replace "$AGENTBIN/pi"
tmux new-window -d -t firstmate -n fm-stream-cap "$AGENTBIN/pi"
tmux new-window -d -t firstmate -n fm-stream-counterfault "$AGENTBIN/pi"
cleanup() {
  tmux kill-server 2>/dev/null || true
  mt=$(command -v mount 2>/dev/null || true)
  chmod -R u+w "$TMUXDIR" 2>/dev/null || true
  rm -rf "$TMUXDIR" 2>/dev/null || true
  [ -z "$mt" ] || true
}
trap cleanup EXIT

say() { printf '\n### %s\n' "$*"; }

fixture() {  # <mode> -> sets dir state fakebin out window key gen
  mode=$1
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
}

run_watch() {  # <out> <extra env...>
  local o=$1; shift
  PATH="$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: live · model stream drive' \
    env "$@" "$WATCH" > "$o" 2>&1 &
  WATCH_PID=$!
}

common_env() { printf '%s\n' "$@"; }

show() {  # <label> <state> <out> <window>
  local label=$1 st=$2 o=$3 win=$4 k
  k=$(printf '%s' "$win" | tr ':/.' '___')
  printf -- '--- %s watcher_alive_after_wait=%s exit=%s\n' "$label" \
    "$(kill -0 "$WATCH_PID" 2>/dev/null && echo yes || echo no)" "${LAST_RC:-n/a}"
  printf -- '--- %s watch stdout:\n' "$label"; cat "$o"
  printf -- '--- %s wake queue:\n' "$label"; cat "$st/.wake-queue" 2>/dev/null || echo '(none)'
  printf -- '--- %s escalation count:\n' "$label"; cat "$st/.wedge-escalations-$k" 2>/dev/null || echo '(none)'
  printf -- '--- %s cap markers:\n' "$label"
  ls "$st/.wedge-permanent-$k" "$st/.wedge-terminal-queued-$k" 2>/dev/null || echo '(none)'
  printf -- '--- %s episode marker:\n' "$label"; cat "$st/.model-stream-episode-$k" 2>/dev/null || echo '(none)'
  printf -- '--- %s triage log:\n' "$label"; cat "$st/.watch-triage.log" 2>/dev/null || echo '(none)'
}

# 1. enabled: sustained silence escalates early while the pane keeps changing.
say "mode=enabled (real tmux pane changing each poll; verify escalation names model-stream silence)"
fixture enabled
( for i in 1 2 3 4 5 6 7 8 9 10; do sleep 0.4; tmux send-keys -t "$window" "tick $i" Enter 2>/dev/null || true; done ) &
CHANGER=$!
run_watch "$out" FM_STREAM_SILENT_MAX_SECS=300 FM_BUSY_TURN_MAX_SECS=99999 FM_STALE_ESCALATE_SECS=2 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999
LAST_RC=n/a
wait_for_exit "$WATCH_PID" 200 || LAST_RC=$?
wait "$CHANGER" 2>/dev/null || true
show enabled "$state" "$out" "$window"
grep -F 'model stream silent for' "$out" >/dev/null || { echo 'FAIL enabled did not name stream silence'; exit 1; }
grep -F 'possible wedge' "$out" >/dev/null || { echo 'FAIL enabled bypassed inspection reason'; exit 1; }
echo 'PASS mode=enabled'

# 2/3. disabled and invalid option: parity, no escalation, watcher stays alive.
for m in disabled:0 invalid:invalid; do
  mode=${m%%:*}; opt=${m#*:}
  say "mode=$mode (FM_STREAM_SILENT_MAX_SECS=$opt must leave the general busy bound in force)"
  fixture "$mode"
  run_watch "$out" FM_STREAM_SILENT_MAX_SECS="$opt" FM_BUSY_TURN_MAX_SECS=99999 FM_STALE_ESCALATE_SECS=2 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999
  LAST_RC=n/a
  wait_poll_cycle "$state" "$WATCH_PID" 200 || { reap "$WATCH_PID"; echo "FAIL $mode surfaced: $(cat "$out")"; exit 1; }
  [ ! -s "$out" ] || { reap "$WATCH_PID"; echo "FAIL $mode produced a wake"; exit 1; }
  [ ! -e "$state/.stale-since-$key" ] || { reap "$WATCH_PID"; echo "FAIL $mode armed inspection timer"; exit 1; }
  show "$mode" "$state" "$out" "$window"
  reap "$WATCH_PID"
  echo "PASS mode=$mode"
done

# 4. fresh progress cancels the pending escalation.
say 'mode=fresh (live foreground progress during the silence window cancels publication)'
fixture fresh
run_watch "$out" FM_STREAM_SILENT_MAX_SECS=300 FM_BUSY_TURN_MAX_SECS=99999 FM_STALE_ESCALATE_SECS=2 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999
LAST_RC=n/a
wait_poll_cycle "$state" "$WATCH_PID" 200 || { reap "$WATCH_PID"; echo "FAIL fresh never polled: $(cat "$out")"; exit 1; }
[ -s "$state/.stale-since-$key" ] || { reap "$WATCH_PID"; echo 'FAIL fresh did not enter inspection timer'; exit 1; }
"$BUSY" stream "$state" stream progress --gen "$gen" --request 1
wait_poll_cycle "$state" "$WATCH_PID" 200 || { reap "$WATCH_PID"; echo 'FAIL fresh watcher stopped early'; }
[ ! -s "$out" ] || { reap "$WATCH_PID"; echo "FAIL fresh published stale silence: $(cat "$out")"; exit 1; }
show fresh "$state" "$out" "$window"
reap "$WATCH_PID"
echo 'PASS mode=fresh'

# 5. close cancels the pending escalation.
say 'mode=close (live close during the silence window cancels publication)'
fixture close
run_watch "$out" FM_STREAM_SILENT_MAX_SECS=300 FM_BUSY_TURN_MAX_SECS=99999 FM_STALE_ESCALATE_SECS=2 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999
LAST_RC=n/a
wait_poll_cycle "$state" "$WATCH_PID" 200 || { reap "$WATCH_PID"; echo 'FAIL close never polled'; exit 1; }
[ -s "$state/.stale-since-$key" ] || { reap "$WATCH_PID"; echo 'FAIL close did not enter inspection timer'; exit 1; }
"$BUSY" stream "$state" stream close --gen "$gen" --request 1
wait_poll_cycle "$state" "$WATCH_PID" 200 || { reap "$WATCH_PID"; echo 'FAIL close watcher stopped early'; }
[ ! -s "$out" ] || { reap "$WATCH_PID"; echo "FAIL close published stale silence: $(cat "$out")"; exit 1; }
show close "$state" "$out" "$window"
reap "$WATCH_PID"
echo 'PASS mode=close'

# 6. replacement cancels the pending escalation.
say 'mode=replace (a new foreground request during the silence window cancels publication)'
fixture replace
run_watch "$out" FM_STREAM_SILENT_MAX_SECS=300 FM_BUSY_TURN_MAX_SECS=99999 FM_STALE_ESCALATE_SECS=2 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999
LAST_RC=n/a
wait_poll_cycle "$state" "$WATCH_PID" 200 || { reap "$WATCH_PID"; echo 'FAIL replace never polled'; exit 1; }
[ -s "$state/.stale-since-$key" ] || { reap "$WATCH_PID"; echo 'FAIL replace did not enter inspection timer'; exit 1; }
"$BUSY" stream "$state" stream open --gen "$gen" --request 2
wait_poll_cycle "$state" "$WATCH_PID" 200 || { reap "$WATCH_PID"; echo 'FAIL replace watcher stopped early'; }
[ ! -s "$out" ] || { reap "$WATCH_PID"; echo "FAIL replace published stale silence: $(cat "$out")"; exit 1; }
show replace "$state" "$out" "$window"
reap "$WATCH_PID"
echo 'PASS mode=replace'

# 7. cap: one terminal wake with the model-stream evidence.
say 'mode=cap (FM_WEDGE_MAX_ESCALATIONS=1 publishes one terminal model-stream wake)'
fixture cap
run_watch "$out" FM_STREAM_SILENT_MAX_SECS=300 FM_BUSY_TURN_MAX_SECS=99999 FM_WEDGE_MAX_ESCALATIONS=1 FM_STALE_ESCALATE_SECS=2 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999
LAST_RC=n/a
wait_for_exit "$WATCH_PID" 200 || LAST_RC=$?
show cap "$state" "$out" "$window"
grep -F 'PERMANENTLY-WEDGED' "$out" >/dev/null || { echo 'FAIL cap did not publish terminal wake'; exit 1; }
grep -F 'model stream silent for' "$out" >/dev/null || { echo 'FAIL cap terminal wake lost stream evidence'; exit 1; }
[ -s "$state/.wedge-permanent-$key" ] && [ -s "$state/.wedge-terminal-queued-$key" ] || { echo 'FAIL cap markers missing'; exit 1; }
echo 'PASS mode=cap'

# 8. counter fault: the uncapped count write is refused; delivery still happens.
say 'mode=counterfault (refused count-file write; uncapped route still delivers one wake)'
fixture counterfault
mkdir "$state/.wedge-escalations-$key"
run_watch "$out" FM_STREAM_SILENT_MAX_SECS=300 FM_BUSY_TURN_MAX_SECS=99999 FM_WEDGE_MAX_ESCALATIONS=0 FM_STALE_ESCALATE_SECS=2 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999
LAST_RC=n/a
wait_for_exit "$WATCH_PID" 200 || LAST_RC=$?
show counterfault "$state" "$out" "$window"
[ -d "$state/.wedge-escalations-$key" ] || { echo 'FAIL counter fault not exercised'; exit 1; }
grep -F 'model stream silent for' "$state/.wake-queue" >/dev/null || { echo 'FAIL counterfault lost stream wake'; exit 1; }
grep -F 'escalation counter write FAILED' "$state/.watch-triage.log" >/dev/null || { echo 'FAIL counterfault did not report failure'; exit 1; }
echo 'PASS mode=counterfault'

printf '\nALL LIVE WATCHER MATRIX CHECKS PASSED\n'
