#!/usr/bin/env bash
# Live scenario driver: a REMOTE mate home's own watcher + the captain's drain.
#
# Stands the product up the way a home runs it: the real bin/fm-watch.sh
# supervision loop, re-armed after each wake exactly as the primary re-arms it,
# against a disposable marked lab home whose parent binding is route=remote.
# A captain-facing decision is published onto that home's OWN outbound parent
# channel through the product's own publisher (fm_parent_report, i.e.
# fm_parent_channel_report - the call bin/fm-pr-check.sh, bin/fm-captain-hold.sh
# and bin/fm-inactive-reconcile.sh make), then observed:
#   phase 1  no wake may name parent-replies.status, and the durable wake queue
#            may not gain a row
#   phase 2  control: a genuine task's captain-relevant append MUST wake
#   phase 3  the captain's own bin/fm-wake-drain.sh surface must carry the
#            genuine task and no parent-channel content
#
# Usage: drive-1-remote-mate-watcher.sh <worktree-root> <evidence-dir> <lab-home>
set -u

ROOT=${1:?worktree root}
EV=${2:?evidence dir}
LAB=${3:?lab home dir}
LABEL=${4:-fixed}
LOG="$EV/drive-1-$LABEL-watcher.log"
STREAM="$EV/drive-1-$LABEL-watch-stream.log"

say() { printf '%s\n' "$*"; printf '%s\n' "$*" >> "$LOG"; }
show() { sed 's/^/    /' | tee -a "$LOG"; }

fmenv() {
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
    -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" "$@"
}

: > "$LOG"
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
mkdir -p "$LAB/tmux" "$LAB/state" "$LAB/data"
printf 'mate\n' > "$LAB/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=remote.example\n' \
  > "$LAB/.fm-secondmate-parent"
printf 'note: benchmark results are in\n' > "$LAB/state/real-task.status"

publish_on_channel() {  # <line>  (the product's own publisher)
  fmenv bash -c '. "$1/bin/fm-parent-channel-lib.sh"; fm_parent_channel_report "$2" "$2/state" "$3"' \
    _ "$ROOT" "$LAB" "$1"
}

watch_cycles() {  # <seconds> <stream-file>
  local secs=$1 stream=$2 end=$(( $(date +%s) + $1 ))
  : > "$stream"
  while [ "$(date +%s)" -lt "$end" ]; do
    # wake() exits the watcher after one actionable wake, exactly as in
    # production, where the primary re-arms it: this loop is that re-arm.
    fmenv FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      "$ROOT/bin/fm-watch.sh" >> "$stream" 2>&1
    sleep 1
  done
}

report_stream() {  # <label> <stream-file>
  say "--- $1: wake lines the watcher emitted ---"
  if [ -s "$2" ]; then cat "$2" | show; else
    printf '    (no wake lines: the home stayed quiet)\n' | tee -a "$LOG"
  fi
}

queue_rows() { [ -f "$LAB/state/.wake-queue" ] && wc -l < "$LAB/state/.wake-queue" | tr -d ' ' || printf 0; }

drain_and_ack() {
  local out tok through gen
  out=$(fmenv "$ROOT/bin/fm-wake-drain.sh" 2>&1)
  printf '%s\n' "$out" >> "$LOG"
  tok=$(printf '%s\n' "$out" | sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1 \2/p' | tail -1)
  if [ -n "$tok" ]; then
    through=${tok% *}; gen=${tok#* }
    fmenv "$ROOT/bin/fm-wake-drain.sh" --ack-through "$through" --recovery-generation "$gen" >> "$LOG" 2>&1
  fi
  printf '%s\n' "$out"
}

say "== phase 0: settle a quiet remote mate home, then drain to a clean queue =="
watch_cycles 4 "$STREAM.p0"
report_stream "phase 0" "$STREAM.p0" > /dev/null
drain_and_ack > /dev/null
say "wake-queue rows after settle+ack: $(queue_rows)"
say "channel file before the publish: $(cat "$LAB/state/parent-replies.status" 2>/dev/null || echo '<absent>')"

say
say "== phase 1: publish a captain decision onto the mate's OWN parent channel =="
rows_before=$(queue_rows)
publish_on_channel 'needs-decision [key=captain-hold-pr-7-1]: captain hold pr-7: merge the green PR?' \
  || say "publish failed rc=$?"
watch_cycles 6 "$STREAM.p1"
say "channel file now:"
cat "$LAB/state/parent-replies.status" | show
report_stream "phase 1" "$STREAM.p1"
say "wake-queue rows before/after phase 1: $rows_before / $(queue_rows)"
say "wake-queue content:"
cat "$LAB/state/.wake-queue" 2>/dev/null | show
say "state entries whose name mentions parent-replies:"
ls -a "$LAB/state" | grep -i 'parent-replies' | show

say
say "== phase 2: control - a genuine task gains a captain-relevant line =="
rows_before2=$(queue_rows)
printf 'blocked [key=wedge]: the crew is stuck\n' >> "$LAB/state/real-task.status"
watch_cycles 6 "$STREAM.p2"
report_stream "phase 2" "$STREAM.p2"
say "wake-queue rows before/after phase 2: $rows_before2 / $(queue_rows)"

say
say "== phase 3: the captain's own drain surface (bin/fm-wake-drain.sh) =="
drain_and_ack > "$EV/drive-1-$LABEL-drain.out" 2>&1
say "drain output:"
cat "$EV/drive-1-$LABEL-drain.out" | show
say "presentation manifest (.status-presentation-cursor):"
cat "$LAB/state/.status-presentation-cursor" 2>/dev/null | show

say
say "== assertions =="
rc_all=0
if grep -q 'parent-replies' "$STREAM.p1"; then
  say "FAIL: a wake named the mate's own parent channel"; rc_all=1
else
  say "PASS: no wake named the mate's own parent channel across 6 poll cycles"; fi
if [ "$(queue_rows)" -le "$rows_before" ]; then
  say "PASS: the parent-channel append created no durable wake row"; fi
if grep -q 'real-task.status' "$STREAM.p2"; then
  say "PASS: a genuine task's decision still wakes the home"; fi
if grep -q 'parent-replies' "$EV/drive-1-$LABEL-drain.out"; then
  say "FAIL: the captain drain presented parent-channel content"; rc_all=1
else
  say "PASS: the captain drain presents no parent-channel content"; fi
if grep -q 'wedge' "$EV/drive-1-$LABEL-drain.out"; then
  say "PASS: the genuine task's open decision still reaches the captain"; fi
if ls "$LAB/state" | grep -q 'seen-parent-replies\|parent-replies.open-decisions-cursor'; then
  say "FAIL: a phantom parent-replies task record was created"; rc_all=1
else
  say "PASS: no phantom parent-replies task record in the home state"; fi
say "overall rc=$rc_all"
exit "$rc_all"
