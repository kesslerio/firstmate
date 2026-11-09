#!/usr/bin/env bash
# Lab fixture arm for the Pi watch extension boundary.
# Mirrors bin/fm-watch-arm.sh's contract: --restart starts one arm cycle and
# reports readiness plus its recovery generation; --handling-delivered
# confirms a successor handoff (dead watcher pid rejected first, then a moved
# recovery generation reported as superseded).
set -u
CTL="${FM_LAB_CTL:?}"
MARKER="$CTL/watcher-down"
ARM_LOG="$CTL/arms.log"
LOCK="$CTL/arms.lock"

marker_generation() { sed -n 's/^pending:downtime://p' "$MARKER" 2>/dev/null | tail -1; }

case "${1:-}" in
  --restart) ;;
  --handling-delivered)
    gen=${2:-}
    [ "${3:-}" = --watcher-pid ] || { echo "watcher: invalid handling delivery confirmation" >&2; exit 2; }
    pid=${4:-}
    if ! kill -0 "$pid" 2>/dev/null; then
      printf 'watcher: handling delivery confirmation rejected: successor watcher pid=%s is not alive\n' "$pid" >&2
      exit 1
    fi
    current=$(marker_generation)
    if [ "$current" != "$gen" ]; then
      printf 'watcher: handling delivery confirmation superseded: marker generation=%s requested=%s\n' "$current" "$gen" >&2
      exit 3
    fi
    printf 'handled:handling:%s\n' "$gen" > "$MARKER"
    printf 'confirm-ok gen=%s pid=%s ts=%s\n' "$gen" "$pid" "$(date +%s%N)" >> "$CTL/confirm.log"
    exit 0
    ;;
  *) echo "usage: fm-watch-arm.sh --restart | --handling-delivered GENERATION --watcher-pid PID" >&2; exit 2 ;;
esac

# One arm index per start, under a lock: the successor numbering is the
# observable order this lab asserts on.
n=$(flock "$LOCK" bash -c 'i=$(cat "$0/counter" 2>/dev/null || echo 0); i=$((i+1)); printf "%s\n" "$i" > "$0/counter"; printf "%s\n" "$i"' "$CTL")
gen="gen$n"
[ -f "$CTL/no-ready-$n" ] || printf 'watcher: started pid=%s (beacon fresh) recovery-generation=%s\n' "$$" "$gen"
printf 'pending:downtime:%s\n' "$gen" > "$MARKER"
printf 'start arm=%s gen=%s arm_pid=%s watcher_pid=%s ts=%s release_seen=%s\n' \
  "$n" "$gen" "$$" "$$" "$(date +%s%N)" "$([ -e "$CTL/released-1" ] && echo yes || echo no)" >> "$ARM_LOG"

if [ -f "$CTL/no-ready-$n" ]; then
  # An unready successor: never reports readiness, so restoration must time out
  # and hand a typed failure to main.
  printf 'watcher: FAILED - lab arm %s never established a watcher cycle\n' "$n"
  exit 1
fi

while [ ! -e "$CTL/close-$n" ] && [ -e "$0" ]; do sleep 0.02; done
if [ ! -e "$0" ]; then exit 1; fi
printf 'signal: lab-project/task-%s (wake %s from arm %s)\n' "$n" "$n" "$n"
exit 0
