#!/usr/bin/env bash
# Live drive: the real bin/fm-watch.sh against a disposable fleet home.
# Usage: drive-watcher.sh <case-name> <status-log-content> <status-age-secs> [<wedge-timer-age>]
# Prints the watcher's own triage lines, the durable wake queue, and the wedge
# escalation marker, so every claim below is an observable product artifact.
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
ROOT=/Users/kesslerio/.no-mistakes/worktrees/8036f35f7c08/01M3VPK3RDXETQSJYZNQ716E37
case_name=$1; log=$2; age=$3; timer=${4:-}
dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-drive.$case_name.XXXXXX")
state=$dir/state; fakebin=$dir/fakebin
mkdir -p "$state" "$dir/config" "$fakebin"
cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "list-windows" ]; then printf '%s\n' "${FM_FAKE_TMUX_WINDOW#*:}"; exit 0; fi
if [ "${1:-}" = "capture-pane" ]; then cat "$FM_FAKE_TMUX_CAPTURE"; exit 0; fi
if [ "${1:-}" = "display-message" ]; then printf '%s\n' "${FM_FAKE_TMUX_CURRENT_COMMAND:-}"; exit 0; fi
exit 1
SH
chmod +x "$fakebin/tmux"
cat > "$fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$FM_FAKE_CREW_STATE"
SH
chmod +x "$fakebin/fm-crew-state.sh"

window="lab:fm-drive"; key=$(printf '%s' "$window" | tr ':/.' '___')
printf 'waiting at the gate' > "$dir/pane.txt"
printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/drive.meta"
printf '%s\n' "$log" > "$state/drive.status"
back=$(( $(date +%s) - age ))
touch -t "$(date -r "$back" +%Y%m%d%H%M.%S)" "$state/drive.status"

# Prime "already surfaced" through the PRODUCTION signature owner, then plant the
# settled-stale bookkeeping a lane has after its supervision turn.
FM_STATE_OVERRIDE="$state" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_status_mark_current "$2" "$3"' _ "$ROOT" "$state" "$state/drive.status" \
  || { echo "DRIVE: could not prime the seen signature"; exit 2; }
hash=$(printf '%s' 'waiting at the gate' | md5 -q)
printf '%s' "$hash" > "$state/.hash-$key"
printf '1\n' > "$state/.count-$key"
printf '%s' "$hash" > "$state/.stale-$key"
[ -n "$timer" ] && printf '%s\n' "$(( $(date +%s) - timer ))" > "$state/.stale-since-$key"

out=$dir/watch.out
PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
  FM_CONFIG_OVERRIDE="$dir/config" FM_FAKE_TMUX_CURRENT_COMMAND=grok \
  FM_CLASSIFY_PAUSED_VERB="${DRIVE_PAUSED_VERB:-}" \
  FM_FAKE_CREW_STATE='state: working · source: run-step · ci running' \
  FM_WATCH_HANDLING_SUCCESSOR=1 FM_STATE_OVERRIDE="$state" \
  FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
  FM_PAUSE_RESURFACE_SECS="${DRIVE_RESURFACE:-999}" FM_STALE_ESCALATE_SECS=1 \
  FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
  "$ROOT/bin/fm-watch.sh" >> "$out" &
pid=$!
# Watcher marks one full poll by touching the liveness beacon; a lane with no
# pre-armed wedge timer needs one poll to publish it before the threshold can
# be reached, so the drive waits for N beacon advances.
i=0; beat="$state/.last-watcher-beat"; first=; cycles=${DRIVE_CYCLES:-2}; seen=0
while [ "$i" -lt 240 ]; do
  kill -0 "$pid" 2>/dev/null || break
  if [ -e "$beat" ]; then
    now=$(stat -f '%m' "$beat")
    [ -n "$first" ] || first=$now
    if [ "$now" != "$first" ]; then seen=$((seen + 1)); first=$now; fi
    [ "$seen" -ge "$cycles" ] && break
  fi
  sleep 0.2; i=$((i + 1))
done
if kill -0 "$pid" 2>/dev/null; then mode="ABSORBED (watcher still supervising)"; kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; else mode="EXITED (it surfaced a wake)"; fi
echo "=== case: $case_name"
echo "=== newest status line: $log"
echo "=== watcher outcome: $mode"
echo "=== watcher output:"; cat "$out"
echo "=== watcher triage log:"; cat "$state/.watch-triage.log" 2>/dev/null || echo "(none)"
echo "=== durable wake queue:"; cat "$state/.wake-queue" 2>/dev/null || echo "(empty)"
echo "=== wedge escalation count:"; cat "$state/.wedge-escalations-$key" 2>/dev/null || echo "(none)"
echo "=== wait recheck throttle:"; cat "$state/.waiting-resurfaced-$key" 2>/dev/null || echo "(none)"
rm -rf "$dir"
