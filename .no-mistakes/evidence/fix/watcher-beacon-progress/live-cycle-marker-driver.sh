#!/usr/bin/env bash
# Live check: with a cycle far longer than the poll, the liveness beacon advances
# many times inside one cycle while the observer-facing cycle boundary
# (state/.watch-cycle) advances exactly once per completed poll.
set -u
ROOT=$PWD
OUT=${1:?out}
: > "$OUT"
say() { printf '%s\n' "$*" | tee -a "$OUT"; }

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
trap '[ -z "${WATCH_PID:-}" ] || { kill -TERM "$WATCH_PID" 2>/dev/null; sleep 0.5; kill -KILL "$WATCH_PID" 2>/dev/null; }; rm -rf "$LAB"' EXIT
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
printf 'kind=ship\n' > "$LAB/state/task.meta"
i=0
while [ "$i" -lt 6 ]; do
  i=$((i+1))
  printf '#!/usr/bin/env bash\nsleep 2\nexit 0\n' > "$LAB/state/slow-$i.check.sh"
  chmod 0700 "$LAB/state/slow-$i.check.sh"
  FM_HOME="$LAB" "$ROOT/bin/fm-check-register.sh" "slow-$i" >/dev/null 2>>"$OUT" || exit 1
done
FM_HOME="$LAB" FM_POLL=2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 FM_CHECK_TIMEOUT=30 \
  FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" >>"$OUT" 2>&1 &
WATCH_PID=$!
i=0
while [ "$i" -lt 120 ]; do
  [ -e "$LAB/state/.watch-cycle" ] && [ -e "$LAB/state/.last-watcher-beat" ] && break
  sleep 0.1; i=$((i+1))
done
mt() { stat -c %Y.%N "$1" 2>/dev/null | cut -d. -f1,2; }
prev_cycle=$(mt "$LAB/state/.watch-cycle"); prev_beat=$(mt "$LAB/state/.last-watcher-beat")
cycle_changes=0; beat_changes=0; samples=0; start=$(date +%s)
while [ $(( $(date +%s) - start )) -lt 32 ]; do
  c=$(mt "$LAB/state/.watch-cycle"); b=$(mt "$LAB/state/.last-watcher-beat")
  [ "$c" = "$prev_cycle" ] || { cycle_changes=$((cycle_changes+1)); prev_cycle=$c; }
  [ "$b" = "$prev_beat" ] || { beat_changes=$((beat_changes+1)); prev_beat=$b; }
  samples=$((samples+1))
  sleep 0.2
done
say "RESULT 32s observation, FM_POLL=2, one cycle ~12s (6 x 2s checks): cycle_boundary_advances=$cycle_changes beacon_refreshes=$beat_changes"
if [ "$beat_changes" -gt "$cycle_changes" ] && [ "$cycle_changes" -ge 1 ]; then
  say "ASSERT cycle-marker PASS (beacon tracks progress inside a cycle; boundary stays one-per-poll)"
else
  say "ASSERT cycle-marker FAIL"
fi
kill -TERM "$WATCH_PID" 2>/dev/null || true
i=0; while [ "$i" -lt 100 ] && kill -0 "$WATCH_PID" 2>/dev/null; do sleep 0.1; i=$((i+1)); done
say "RESULT teardown: watcher alive=$(kill -0 "$WATCH_PID" 2>/dev/null && echo yes || echo no) lock=$([ -e "$LAB/state/.watch.lock" ] && echo present || echo released)"
WATCH_PID=
