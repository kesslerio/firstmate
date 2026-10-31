#!/usr/bin/env bash
# Live publication-lock revalidation drive: REAL tmux panes, REAL bin/fm-watch.sh,
# REAL bin/fm-busy-event.sh, and a REAL held lock (a live pid in the state lock).
# The worker changes the stream observation while the watcher is blocked in the
# lock wait, so the observation it captured must not survive to publication.
set -u
ROOT=/home/art/.no-mistakes/worktrees/9f75ec418609/01M691BS1E935R4G6VD0D4CGR1
# shellcheck source=/dev/null
. "$ROOT/tests/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-live-lock)
# shellcheck source=/dev/null
. "$ROOT/tests/watch-triage-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
BUSY="$ROOT/bin/fm-busy-event.sh"

TMUXDIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-lock-tmux.XXXXXX")
export TMUX_TMPDIR="$TMUXDIR"
AGENTBIN="$TMUXDIR/agentbin"
mkdir -p "$AGENTBIN"
cat > "$AGENTBIN/pi" <<'PI'
#!/usr/bin/env bash
while :; do sleep 1; done
PI
chmod +x "$AGENTBIN/pi"
tmux new-session -d -s firstmate -n fm-pub-queue-close "$AGENTBIN/pi"
tmux new-window -d -t firstmate -n fm-pub-queue-progress "$AGENTBIN/pi"
tmux new-window -d -t firstmate -n fm-pub-queue-replace "$AGENTBIN/pi"
tmux new-window -d -t firstmate -n fm-pub-recovery-close "$AGENTBIN/pi"
tmux new-window -d -t firstmate -n fm-pub-recovery-progress "$AGENTBIN/pi"
tmux new-window -d -t firstmate -n fm-pub-recovery-replace "$AGENTBIN/pi"
cleanup() {
  tmux kill-server 2>/dev/null || true
  chmod -R u+w "$TMUXDIR" 2>/dev/null || true
  rm -rf "$TMUXDIR" 2>/dev/null || true
}
trap cleanup EXIT

for lock_kind in queue recovery; do
  for action in close progress replace; do
    mode="$lock_kind-$action"
    printf '\n### %s: worker %s during the %s lock wait\n' "$mode" "$action" "$lock_kind"
    dir=$(make_case "live-lock-$mode"); state="$dir/state"; fakebin="$dir/fakebin"
    out="$dir/watch.out"; window="firstmate:fm-pub-$mode"
    key=$(printf '%s' "$window" | tr ':/.' '___')
    printf 'window=%s\nkind=ship\nharness=pi\n' "$window" > "$state/stream.meta"
    printf 'working: setup complete\n' > "$state/stream.status"
    seen_sig "$state/stream.status" > "$state/.seen-stream_status"
    gen=$("$BUSY" arm "$state" stream)
    "$BUSY" apply "$state" stream busy --gen "$gen" --source pi-ext --event agent-start
    "$BUSY" stream "$state" stream open --gen "$gen" --request 1
    printf 'v1 gen=%s request=1 rev=1 ts=%s\n' "$gen" "$(( $(date +%s) - 600 ))" > "$state/stream.model-stream"
    # The observation has already crossed its bound, so the next poll reaches
    # publication immediately: the held lock is the only thing stopping it.
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    if [ "$lock_kind" = recovery ]; then
      lock="$state/.watcher-down.lock"
      prior=$(cat "$state/.watcher-down" 2>/dev/null || true)
    else
      lock="$state/.wake-queue.lock"
      prior=''
    fi
    # Real held lock: a directory carrying the live driver's pid, exactly the
    # shape the production claim/steal logic recognizes as a live holder.
    mkdir "$lock"
    printf '%s\n' "$$" > "$lock/pid"
    PATH="$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
      FM_FAKE_CREW_STATE='state: working · source: live · publication lock drive' \
      env FM_STREAM_SILENT_MAX_SECS=300 FM_BUSY_TURN_MAX_SECS=99999 \
      FM_WEDGE_MAX_ESCALATIONS=1 FM_STALE_ESCALATE_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" 2>&1 &
    pid=$!
    sleep 3
    blocked=no
    [ -s "$out" ] || [ -s "$state/.wake-queue" ] || blocked=yes
    printf -- '--- held the %s lock with live pid %s before publication: blocked=%s\n' \
      "$lock_kind" "$$" "$blocked"
    case "$action" in
      close) "$BUSY" stream "$state" stream close --gen "$gen" --request 1 ;;
      progress) "$BUSY" stream "$state" stream progress --gen "$gen" --request 1 ;;
      replace) "$BUSY" stream "$state" stream open --gen "$gen" --request 2 ;;
    esac
    sleep 1
    rm -f "$lock/pid"
    rmdir "$lock"
    if ! wait_poll_cycle "$state" "$pid" 200; then
      reap "$pid"
      echo "FAIL $mode watcher exited before revalidating: $(cat "$out")"
      exit 1
    fi
    wait_poll_cycle "$state" "$pid" 200 || true
    [ "$blocked" = yes ] || { reap "$pid"; echo "FAIL $mode never blocked before publication"; exit 1; }
    [ ! -s "$out" ] || { reap "$pid"; echo "FAIL $mode published obsolete silence: $(cat "$out")"; exit 1; }
    [ ! -s "$state/.wake-queue" ] || { reap "$pid"; echo 'FAIL obsolete wake survived'; exit 1; }
    [ ! -e "$state/.stale-since-$key" ] || { reap "$pid"; echo 'FAIL rejected publication retained escalation timer'; exit 1; }
    [ ! -e "$state/.wedge-escalations-$key" ] || { reap "$pid"; echo 'FAIL rejected publication retained escalation count'; exit 1; }
    [ ! -e "$state/.wedge-permanent-$key" ] && [ ! -e "$state/.wedge-terminal-queued-$key" ] || { reap "$pid"; echo 'FAIL obsolete terminal append retained cap'; exit 1; }
    if [ "$lock_kind" = recovery ]; then
      [ "$(cat "$state/.watcher-down" 2>/dev/null || true)" = "$prior" ] || { reap "$pid"; echo 'FAIL rejected append changed the prior recovery marker'; exit 1; }
    fi
    printf -- '--- watcher alive after release: %s\n' "$(kill -0 "$pid" 2>/dev/null && echo yes || echo no)"
    printf -- '--- watch stdout: '; cat "$out"; [ -s "$out" ] || echo '(empty)'
    printf -- '--- wake queue: '; cat "$state/.wake-queue" 2>/dev/null || echo '(none)'
    printf -- '--- escalation count: '; cat "$state/.wedge-escalations-$key" 2>/dev/null || echo '(none)'
    printf -- '--- triage log: '; cat "$state/.watch-triage.log" 2>/dev/null || echo '(none)'
    reap "$pid"
    echo "PASS $mode"
  done
done

printf '\nALL LIVE PUBLICATION LOCK CHECKS PASSED\n'
