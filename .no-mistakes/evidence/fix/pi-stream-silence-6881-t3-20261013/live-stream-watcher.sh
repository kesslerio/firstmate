#!/usr/bin/env bash
# Live drive of the opt-in Pi model-stream inspection against the real product:
# real bin/fm-watch.sh, real bin/fm-busy-event.sh writer, real tmux on a private
# TMUX_TMPDIR socket namespace (never the operator's default tmux server), and a
# disposable isolated FM_HOME/state dir. No fakes stand in for the product.
set -u
ROOT=/home/art/.no-mistakes/worktrees/9f75ec418609/01M6887Z23FZWJH5G08X3RAKPH
OUT=/home/art/.no-mistakes/evidence/01M6887Z23FZWJH5G08X3RAKPH/live
WATCH="$ROOT/bin/fm-watch.sh"
BUSY="$ROOT/bin/fm-busy-event.sh"
mkdir -p "$OUT"
fails=0
say() { printf '%s\n' "$*"; }
ok() { say "ok   - $*"; }
bad() { say "FAIL - $*"; fails=$((fails + 1)); }

# tmux on the lab's private socket namespace
lab_tmux() {  # <lab> <args...>
  local lab=$1
  shift
  env -u TMUX TMUX_TMPDIR="$lab/tmux" tmux "$@"
}

new_lab() {  # <name>
  local name=$1 lab
  lab=$(mktemp -d "${TMPDIR:-/tmp}/fm-stream-live-${name}.XXXXXX")
  mkdir -p "$lab/state" "$lab/config" "$lab/tmux"
  printf '%s' "$lab"
}

setup_stream_lab() {  # <lab> <task> <harness>
  local lab=$1 task=$2 harness=$3 state="$1/state" gen
  mkdir -p "$state"
  lab_tmux "$lab" new-session -d -s live -n "fm-$task" -x 120 -y 40 "sleep 900"
  printf 'Working...' > "$lab/pane.txt"
  printf 'window=live:fm-%s\nkind=ship\nharness=%s\n' "$task" "$harness" > "$state/$task.meta"
  gen=$(FM_STATE_OVERRIDE="$state" "$BUSY" arm "$state" "$task")
  FM_STATE_OVERRIDE="$state" "$BUSY" apply "$state" "$task" busy --gen "$gen" --source pi-ext --event agent-start
  FM_STATE_OVERRIDE="$state" "$BUSY" stream "$state" "$task" open --gen "$gen" --request 1
  printf '%s' "$gen" > "$lab/gen"
}

stop_lab() {  # <lab>
  local lab=$1 pids pid
  # A batch-mode pane command (top) can outlive the server's SIGHUP, so stop the
  # recorded pane processes explicitly before removing the disposable lab.
  pids=$(lab_tmux "$lab" list-panes -a -F '#{pane_pid}' 2>/dev/null || true)
  lab_tmux "$lab" kill-server 2>/dev/null || true
  for pid in $pids; do kill "$pid" 2>/dev/null || true; done
  rm -rf "$lab"
}

# run_watch <lab> <state> <out> <timeout-secs> [env assignments...]
run_watch() {
  local lab=$1 state=$2 out=$3 secs=$4
  shift 4
  env -u TMUX TMUX_TMPDIR="$lab/tmux" FM_HOME="$lab" FM_STATE_OVERRIDE="$state" \
    FM_CONFIG_OVERRIDE="$lab/config" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$@" \
    timeout "$secs" "$WATCH" > "$out" 2>&1
}

# Wait until the watcher has completed at least <n> poll cycles, or it exited.
wait_cycles() {  # <lab> <pid> <n> [limit-ticks]
  local lab=$1 pid=$2 want=$3 limit=${4:-300} seen=0 i=0 last
  last=$(cat "$lab/state/.last-watcher-beat" 2>/dev/null || true)
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    local now
    now=$(cat "$lab/state/.last-watcher-beat" 2>/dev/null || true)
    if [ -n "$now" ] && [ "$now" != "$last" ]; then
      seen=$((seen + 1))
      last=$now
      [ "$seen" -ge "$want" ] && return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

wait_until_file() {  # <path> [limit-ticks]
  local path=$1 limit=${2:-300} i=0
  while [ "$i" -lt "$limit" ]; do
    [ -e "$path" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# ---------------------------------------------------------------------------
say '=== case 1: opted-in following stream silence escalates through the real inspection cadence'
lab=$(new_lab case1)
setup_stream_lab "$lab" stream pi
sleep 4
run_watch "$lab" "$lab/state" "$lab/watch.out" 40 \
  FM_STREAM_SILENT_MAX_SECS=2 FM_BUSY_TURN_MAX_SECS=99999 FM_STALE_ESCALATE_SECS=1 FM_WEDGE_MAX_ESCALATIONS=0
say "watch exit=$?  output:"; sed 's/^/    /' "$lab/watch.out"
if grep -F 'model stream silent for' "$lab/watch.out" >/dev/null; then
  ok 'escalation reason names model-stream silence'
else
  bad 'escalation reason does not name model-stream silence'
fi
if grep -F 'possible wedge' "$lab/watch.out" >/dev/null; then
  ok 'escalation used the existing inspection wording (no new recovery path)'
else
  bad 'escalation bypassed the existing inspection wording'
fi
if grep -Eq 'model stream silent for [0-9]+s' "$lab/watch.out"; then
  ok 'reason carries the observed silence duration'
else
  bad 'reason omitted the observed silence duration'
fi
if lab_tmux "$lab" list-windows -a -F '#{session_name}:#{window_name}' | grep -Fqx 'live:fm-stream'; then
  ok 'worker endpoint still alive after the notification (inspection only)'
else
  bad 'worker endpoint disappeared'
fi
say '--- wake queue rows:'; sed 's/^/    /' "$lab/state/.wake-queue" 2>/dev/null || say '    (none)'
cp "$lab/watch.out" "$OUT/case1-optin-escalation.out"
cp "$lab/state/.wake-queue" "$OUT/case1-optin-escalation.wake-queue" 2>/dev/null || true
cp "$lab/state/.watch-triage.log" "$OUT/case1-optin-escalation.triage.log" 2>/dev/null || true
stop_lab "$lab"

# ---------------------------------------------------------------------------
say '=== case 2c: an unset, zero, negative, malformed, or out-of-range option is off'
for opt in '' 0 -5 abc 1000000000; do
  lab=$(new_lab "case2c-${opt:-unset}")
  setup_stream_lab "$lab" stream pi
  sleep 2.5
  run_watch "$lab" "$lab/state" "$lab/watch.out" 6 \
    FM_STREAM_SILENT_MAX_SECS="$opt" FM_BUSY_TURN_MAX_SECS=99999 FM_STALE_ESCALATE_SECS=1 FM_WEDGE_MAX_ESCALATIONS=0
  if grep -Eq '^(stale|check|signal|heartbeat):' "$lab/watch.out" || [ -e "$lab/state/.stale-since-live_fm-stream" ]; then
    bad "option '${opt:-unset}' did not leave stream observation off"
  else
    ok "option '${opt:-unset}' stays off (no timer, no wake)"
  fi
  stop_lab "$lab"
done

# ---------------------------------------------------------------------------
say '=== case 1b: the same opt-in silence escalates while the pane display keeps changing'
lab=$(new_lab case1b)
state="$lab/state"
mkdir -p "$state"
lab_tmux "$lab" new-session -d -s live -n fm-stream -x 120 -y 40 "top -b -d 1"
printf 'window=live:fm-stream\nkind=ship\nharness=pi\n' > "$state/stream.meta"
gen=$(FM_STATE_OVERRIDE="$state" "$BUSY" arm "$state" stream)
FM_STATE_OVERRIDE="$state" "$BUSY" apply "$state" stream busy --gen "$gen" --source pi-ext --event agent-start
FM_STATE_OVERRIDE="$state" "$BUSY" stream "$state" stream open --gen "$gen" --request 1
sleep 4
h1=$(lab_tmux "$lab" capture-pane -p -t live:fm-stream -S -40 | cksum)
sleep 1.2
h2=$(lab_tmux "$lab" capture-pane -p -t live:fm-stream -S -40 | cksum)
[ "$h1" != "$h2" ] && ok 'the worker pane really is changing between polls' \
  || bad 'the worker pane was static, so the changing-pane path was not exercised'
run_watch "$lab" "$state" "$lab/watch.out" 40 \
  FM_STREAM_SILENT_MAX_SECS=2 FM_BUSY_TURN_MAX_SECS=99999 FM_STALE_ESCALATE_SECS=1 FM_WEDGE_MAX_ESCALATIONS=0
say "watch exit=$?  output:"; sed 's/^/    /' "$lab/watch.out"
if grep -F 'model stream silent for' "$lab/watch.out" >/dev/null; then
  ok 'changing-pane path still names model-stream silence'
else
  bad 'changing-pane path did not surface model-stream silence'
fi
cp "$lab/watch.out" "$OUT/case1b-changing-pane.out"
stop_lab "$lab"

# ---------------------------------------------------------------------------
say '=== case 2a: default-off (option unset) keeps the general busy bound - no stream timer, no wake'
lab=$(new_lab case2a)
setup_stream_lab "$lab" stream pi
sleep 3
run_watch "$lab" "$lab/state" "$lab/watch.out" 8 \
  FM_BUSY_TURN_MAX_SECS=99999 FM_STALE_ESCALATE_SECS=1 FM_WEDGE_MAX_ESCALATIONS=0
say "watch exit=$? (124 = still supervising, i.e. nothing surfaced)"
say '--- output:'; sed 's/^/    /' "$lab/watch.out"
if [ -s "$lab/state/.hash-live_fm-stream" ]; then
  ok 'the poll really processed the worker window'
else
  bad 'the poll never processed the worker window (vacuous assertion)'
fi
if ! grep -Eq '^(stale|check|signal|heartbeat):' "$lab/watch.out" && [ ! -e "$lab/state/.stale-since-live_fm-stream" ]; then
  ok 'no model-silence timer or wake with the option unset'
else
  bad 'default-off worker still entered stream inspection'
fi
cp "$lab/watch.out" "$OUT/case2a-default-off.out"
stop_lab "$lab"

say '=== case 2b: default-off still enforces the pre-existing general busy bound, without stream wording'
lab=$(new_lab case2b)
setup_stream_lab "$lab" stream pi
# Age the worker record past a 60s general busy bound; the stream option is unset.
touch -t 202001010000 "$lab/state/stream.meta"
run_watch "$lab" "$lab/state" "$lab/watch.out" 40 \
  FM_BUSY_TURN_MAX_SECS=60 FM_STALE_ESCALATE_SECS=1 FM_WEDGE_MAX_ESCALATIONS=0
say "watch exit=$?  output:"; sed 's/^/    /' "$lab/watch.out"
if grep -F 'possible wedge' "$lab/watch.out" >/dev/null; then
  ok 'general busy bound still escalates with the option unset'
else
  bad 'general busy bound stopped working with the option unset'
fi
if grep -F 'model stream silent' "$lab/watch.out" >/dev/null; then
  bad 'default-off escalation claimed model-stream observation'
else
  ok 'default-off escalation carries no model-stream claim'
fi
cp "$lab/watch.out" "$OUT/case2b-default-off-general-bound.out"
stop_lab "$lab"

# ---------------------------------------------------------------------------
# Adversarial: the observation must be revalidated at publication time. The
# operator guard hook (config/wedge-evidence-guards) is a real product extension
# point that runs after the deferral/endpoint reads and immediately before the
# stream revalidation, so a guard that changes the request there reproduces a
# close/progress/replacement arriving during publication preparation.
adversarial_case() {  # <mode: close|progress|replace>
  local mode=$1 lab state gen key guard pid i
  lab=$(new_lab "case3-$mode")
  state="$lab/state"
  setup_stream_lab "$lab" stream pi
  gen=$(cat "$lab/gen")
  key=live_fm-stream
  # Install a trusted operator guard that mutates the request while the real
  # watcher prepares the notification, then answers non-CRITICAL (no deferral).
  # This is the product's own guard hook, which runs after the deferral/endpoint
  # reads and immediately before the stream revalidation, so the mutation lands
  # where a real close/progress/replacement during preparation would.
  guard="$lab/guard.sh"
  cat > "$guard" <<SH
#!/usr/bin/env bash
case "$mode" in
  close) FM_STATE_OVERRIDE="$state" "$BUSY" stream "$state" stream close --gen "$gen" --request 1 ;;
  progress) FM_STATE_OVERRIDE="$state" "$BUSY" stream "$state" stream progress --gen "$gen" --request 1 ;;
  replace) FM_STATE_OVERRIDE="$state" "$BUSY" stream "$state" stream open --gen "$gen" --request 2 ;;
esac
touch "$lab/guard-fired"
printf '{"status":"OK","recommendation":"no operator objection"}\n'
SH
  chmod 700 "$guard"
  printf '%s\n' "$guard" > "$lab/config/wedge-evidence-guards"
  chmod 600 "$lab/config/wedge-evidence-guards"
  # Opt-in threshold 3s with a 5s-old request: the observed request is expired,
  # while a replacement opened by the guard stays fresh for the rest of this
  # observation window, so any wake here can only come from the obsolete one.
  sleep 5
  env -u TMUX TMUX_TMPDIR="$lab/tmux" FM_HOME="$lab" FM_STATE_OVERRIDE="$state" \
    FM_CONFIG_OVERRIDE="$lab/config" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_STREAM_SILENT_MAX_SECS=3 FM_BUSY_TURN_MAX_SECS=99999 FM_STALE_ESCALATE_SECS=1 \
    FM_WEDGE_MAX_ESCALATIONS=0 "$WATCH" > "$lab/watch.out" 2>&1 &
  pid=$!
  # Wait for the guard to run (the request changes mid-preparation), then let one
  # further poll complete and stop, so a replacement's own fresh silence cannot
  # age into a legitimate new episode inside this check.
  i=0
  while [ "$i" -lt 400 ] && [ ! -e "$lab/guard-fired" ]; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  if [ -e "$lab/guard-fired" ]; then
    ok "$mode: request changed during publication preparation (guard hook fired)"
  else
    bad "$mode: the race was never exercised"
  fi
  sleep 1.5
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  say "  $mode watcher output: $(tr '\n' ' ' < "$lab/watch.out")"
  if grep -Eq '^(stale|check|signal|heartbeat):' "$lab/watch.out"; then
    bad "$mode: obsolete observation still published a wake: $(tr '\n' ' ' < "$lab/watch.out")"
  elif [ -e "$state/.stale-since-$key" ]; then
    bad "$mode: obsolete observation retained its inspection timer"
  else
    ok "$mode: obsolete observation published no model-silence wake and cleared its timer"
  fi
  if [ ! -e "$state/.wedge-escalations-$key" ] && [ ! -e "$state/.wedge-permanent-$key" ] \
     && [ ! -e "$state/.wedge-terminal-queued-$key" ]; then
    ok "$mode: no escalation count or cap marker committed for the cancelled wake"
  else
    bad "$mode: escalation bookkeeping survived the cancelled wake"
  fi
  case "$mode" in
    close) [ ! -e "$state/stream.model-stream" ] || bad 'close: active evidence survived the close' ;;
    progress) [ -e "$state/stream.model-stream" ] || bad 'progress: evidence vanished instead of refreshing' ;;
    replace) grep -F 'request=2' "$state/stream.model-stream" >/dev/null \
               || bad 'replace: evidence did not move to the new request' ;;
  esac
  cp "$lab/watch.out" "$OUT/case3-$mode.out"
  cp "$lab/guard-fired" "$OUT/case3-$mode.guard-fired" 2>/dev/null || true
  stop_lab "$lab"
}

adversarial_case close
adversarial_case progress
adversarial_case replace

say '=== summary'
if [ "$fails" -eq 0 ]; then
  say 'ALL CHECKS PASSED'
else
  say "FAILURES: $fails"
fi
exit "$fails"
