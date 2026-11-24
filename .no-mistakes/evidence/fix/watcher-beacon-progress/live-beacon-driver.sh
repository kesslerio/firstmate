#!/usr/bin/env bash
# Live driver: real bin/fm-watch.sh against a disposable lab home with a slow
# check sweep, observed through the real bin/fm-guard.sh operator surface.
set -u
ROOT=$PWD
OUT=${1:?transcript out}
: > "$OUT"
say() { printf '%s\n' "$*" | tee -a "$OUT"; }

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap 'rm -rf "$LAB" "$LAB.tmux"' EXIT
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
say "lab home: $LAB"
say "watcher: $ROOT/bin/fm-watch.sh (FM_GUARD_GRACE=4, FM_POLL=1, 6x 2s checks)"

WATCH_PID=
stop_watch() {
  [ -n "$WATCH_PID" ] || return 0
  kill -CONT "$WATCH_PID" 2>/dev/null || true
  kill -TERM "$WATCH_PID" 2>/dev/null || true
  local i=0
  while [ "$i" -lt 100 ] && kill -0 "$WATCH_PID" 2>/dev/null; do sleep 0.1; i=$((i+1)); done
  kill -KILL "$WATCH_PID" 2>/dev/null || true
}

# Supervision need: one in-flight task record, so the guard judges the beacon.
printf 'kind=ship\n' > "$LAB/state/task.meta"

i=0
while [ "$i" -lt 6 ]; do
  i=$((i+1))
  printf '#!/usr/bin/env bash\n# fixture-check-%s\nsleep 2\nexit 0\n' "$i" > "$LAB/state/slow-$i.check.sh"
  chmod 0700 "$LAB/state/slow-$i.check.sh"
  FM_HOME="$LAB" "$ROOT/bin/fm-check-register.sh" "slow-$i" >/dev/null 2>>"$OUT" \
    || { say "register failed for slow-$i"; exit 1; }
done

beacon_age() {
  local now m
  now=$(date +%s)
  m=$(stat -c %Y "$LAB/state/.last-watcher-beat" 2>/dev/null) || { printf 'absent'; return; }
  printf '%s' "$(( now - m ))"
}

FM_HOME="$LAB" FM_GUARD_GRACE=4 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 \
  FM_CHECK_TIMEOUT=30 FM_HEARTBEAT=999999 \
  "$ROOT/bin/fm-watch.sh" >>"$OUT" 2>&1 &
WATCH_PID=$!

i=0
while [ "$i" -lt 120 ]; do
  [ -e "$LAB/state/.last-watcher-beat" ] && [ -e "$LAB/state/.watch-cycle" ] && break
  sleep 0.1; i=$((i+1))
done
say "watcher pid=$WATCH_PID started"
say "sentinel progress marker: $LAB/state/.last-watcher-progress"

# --- Scenario 1: a working cycle longer than the grace never reads as dead ---
max_age=0; guard_down=0; guard_runs=0; cycles_start=$(wc -c < "$LAB/state/.watch-cycle" 2>/dev/null || echo 0)
i=0
while [ "$i" -lt 80 ]; do
  age=$(beacon_age)
  case "$age" in ''|*[!0-9]*) ;; *) [ "$age" -le "$max_age" ] || max_age=$age ;; esac
  if [ $((i % 8)) -eq 0 ]; then
    g=$(FM_ROOT_OVERRIDE="$LAB" FM_HOME="$LAB" FM_SUPERVISION_MODEL=persistent FM_GUARD_GRACE=4 \
      "$ROOT/bin/fm-guard.sh" 2>&1)
    guard_runs=$((guard_runs+1))
    case "$g" in *"WATCHER DOWN"*) guard_down=$((guard_down+1)) ;; esac
    say "  t=$((i/4))s beacon_age=${age}s guard=$( [ -n "$g" ] && printf 'OUTPUT' || printf 'silent' )"
  fi
  sleep 0.25; i=$((i+1))
done
say "RESULT long-cycle: max_beacon_age=${max_age}s grace=4s guard_runs=$guard_runs guard_down=$guard_down"
say "RESULT long-cycle: cycle_marker_bytes=$cycles_start (cycle boundary is separate from beacon refreshes)"
[ "$max_age" -lt 4 ] && [ "$guard_down" -eq 0 ] && say "ASSERT long-cycle PASS" || say "ASSERT long-cycle FAIL"

# --- Scenario 2: SIGSTOP the watcher mid-sweep; child progress must not save it ---
progress_before=$(stat -c %Y "$LAB/state/.last-watcher-progress" 2>/dev/null || echo 0)
kill -STOP "$WATCH_PID" || say "STOP failed"
sleep 7
frozen_age=$(beacon_age)
progress_after=$(stat -c %Y "$LAB/state/.last-watcher-progress" 2>/dev/null || echo 0)
frozen_guard=$(FM_ROOT_OVERRIDE="$LAB" FM_HOME="$LAB" FM_SUPERVISION_MODEL=persistent FM_GUARD_GRACE=4 \
  "$ROOT/bin/fm-guard.sh" 2>&1)
say "RESULT frozen: beacon_age=${frozen_age}s (grace 4s) progress_advanced=$([ "$progress_after" != "$progress_before" ] && echo yes || echo no)"
say "RESULT frozen: guard reported $(case "$frozen_guard" in *"WATCHER DOWN"*) echo 'WATCHER DOWN' ;; *) echo 'silent' ;; esac)"
case "$frozen_guard" in *"WATCHER DOWN"*) say "ASSERT frozen PASS" ;; *) say "ASSERT frozen FAIL" ;; esac
kill -CONT "$WATCH_PID" 2>/dev/null || true

# --- Scenario 3: TERM mid-sweep cleans owned sweep descendants, releases lock ---
children_before=$(ps -eo pid,args --no-headers | grep -c 'fixture-check-' || true)
stop_watch
sleep 1
children_after=$(ps -eo pid,args --no-headers | grep 'fixture-check-' | grep -v grep || true)
lock_state=$([ -e "$LAB/state/.watch.lock" ] && echo present || echo released)
say "RESULT teardown: fixture sweep processes before TERM=$children_before after TERM=$(printf '%s' "$children_after" | grep -c . || true)"
say "RESULT teardown: watcher alive=$(kill -0 "$WATCH_PID" 2>/dev/null && echo yes || echo no) lock=$lock_state"
if [ -z "$children_after" ] && [ "$lock_state" = released ] && ! kill -0 "$WATCH_PID" 2>/dev/null; then
  say "ASSERT teardown PASS"
else
  say "ASSERT teardown FAIL"
fi
say "lab home removed on exit: $LAB"
