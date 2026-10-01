#!/usr/bin/env bash
# Producer-side live check: run the REAL watcher (bin/fm-watch.sh) against a
# disposable lab home whose only task record is an Orca endpoint
# (backend=orca, terminal=<handle>), with the external Orca app stood in for by
# a stub `orca` CLI on PATH. Assert the stale wake row the watcher itself queues
# is keyed by the Orca TERMINAL HANDLE (not a window) - the key the supervision
# branch dispatch has to resolve - and that the product's dispatch entry then
# hands that wake to the supervision branch instead of main.
set -u
WORKTREE="$1"; LAB="$2"
export FM_HOME="$LAB"
unset NO_MISTAKES_GATE FM_ROOT_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE \
  FM_PROJECTS_OVERRIDE TMUX TMUX_PANE
STATE="$LAB/state"; Q="$STATE/.wake-queue"
BIN="$LAB/bin"; mkdir -p "$BIN"

cat > "$BIN/orca" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  status) printf '{"ok":true,"result":{"runtime":{"reachable":true,"state":"ready"}}}\n' ;;
  terminal) printf '{"ok":true,"result":{"terminal":{"tail":["lab orca pane","captain@lab ~/work","$ "]}}}\n' ;;
esac
exit 0
SH
cat > "$BIN/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: unknown · source: lab · no run-step evidence\n'
exit 0
SH
chmod +x "$BIN/orca" "$BIN/fm-crew-state.sh"

# One Orca task only, so every wake row in this home belongs to it.
rm -rf "$STATE" "$LAB/config"
mkdir -p "$STATE" "$LAB/config" "$LAB/projects/approved" "$BIN"
printf 'project=%s/projects/approved\nterminal=term-lab-orca-1\nwindow=fm-orca-task\nbackend=orca\nharness=claude\nkind=ship\nendpoint_task_id=orca-task\n' "$LAB" > "$STATE/orca-task.meta"
printf 'working: lab scenario step\n' > "$STATE/orca-task.status"
# A wake surfaced by the previous watcher cycle is re-announced as one
# `check: rearm-resurface` row on the next arm. Consume it as main would, so the
# runs below exercise only the pane-staleness backbone.
FM_SUPERVISION_ACTOR=main "$WORKTREE/bin/fm-wake-drain.sh" --ack-through 2 --recovery-generation "$(cat "$STATE/.watcher-downtime-token" 2>/dev/null | awk -F: '{print $NF}')" >/dev/null 2>&1 || true
rm -f "$Q"

run_watcher() {  # one bounded watcher run
  PATH="$BIN:$PATH" FM_STATE_OVERRIDE="$STATE" FM_CREW_STATE_BIN="$BIN/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_SECONDMATE_LIVENESS_SECS=99999999 FM_WATCH_HANDLING_SUCCESSOR=1 \
    "$WORKTREE/bin/fm-watch.sh" > "$LAB/watch.$1" 2>&1 &
  local wpid=$! i=0
  while [ "$i" -lt 60 ]; do
    kill -0 "$wpid" 2>/dev/null || break
    sleep 0.5; i=$((i + 1))
  done
  kill -TERM "$wpid" 2>/dev/null || true
  wait "$wpid" 2>/dev/null || true
}

echo "### watcher run 1 (first poll: the new status log surfaces as a signal):"
run_watcher 1
sed -n '1,8p' "$LAB/watch.1"
for n in 2 3 4; do
  echo "### watcher run $n (pane and log unchanged -> the pane-stale path owns this poll):"
  run_watcher "$n"
  sed -n '1,8p' "$LAB/watch.$n"
  awk -F '\t' '$3=="stale"{found=1} END{exit !found}' "$Q" 2>/dev/null && break
done

echo
echo "--- wake rows the watcher itself wrote (tab shown as <TAB>):"
sed 's/\t/<TAB>/g' "$Q"
echo "--- keys the watcher queued, by kind:"
awk -F '\t' '{ print $3 "\tkey=" $4 }' "$Q" | sort -u

echo
echo "--- bin/fm-branch-dispatch.mjs scope on the watcher-written queue:"
node "$WORKTREE/bin/fm-branch-dispatch.mjs" scope
echo "--- bin/fm-branch-dispatch.mjs offer for the watcher's own reason line:"
reason=$(grep -m1 '^stale:' "$LAB/watch.2" "$LAB/watch.1" 2>/dev/null | sed 's/^[^:]*://' | head -n 1)
[ -n "$reason" ] || reason="stale: term-lab-orca-1"
printf '%s\n' "$reason" | node "$WORKTREE/bin/fm-branch-dispatch.mjs" offer
echo
echo "--- pre-fix dispatch entry (base commit 549e07f) on the same watcher-written queue:"
node "${TMPDIR:-/tmp}/fm-orca-test/control/bin/fm-branch-dispatch.mjs" scope
