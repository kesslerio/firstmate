#!/usr/bin/env bash
# Drive the real away-mode supervision daemon (bin/fm-supervise-daemon.sh) with
# its own watcher child against a disposable lab home and a private tmux socket,
# then read what actually reached the supervisor pane.
# Usage: drive-daemon-heartbeat.sh <repo-root> <evidence-out-dir> <ready|empty>
set -u
ROOT=$(cd "$1" && pwd)
OUT=$(cd "$2" && pwd)
MODE=${3:-ready}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
INERT=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-inert.XXXXXX")
TMDIR=''
cleanup() {
  [ -z "$TMDIR" ] || TMUX_TMPDIR="$TMDIR" tmux kill-server 2>/dev/null || true
  [ -z "$TMDIR" ] || "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1 || true
  rm -rf "$LAB" "$INERT"
}
trap cleanup EXIT

"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null
cat > "$LAB/.tasks.toml" <<'TOML'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
TOML
printf '## In flight\n\n## Queued\n\n## Done\n' > "$LAB/data/backlog.md"
printf 'mode: quiet\n' > "$LAB/state/.afk"
if [ "$MODE" = ready ]; then
  FM_HOME="$LAB" "$ROOT/bin/fm-tasks-axi.sh" add ship-next 'beyond current spend cap' >/dev/null
  FM_HOME="$LAB" "$ROOT/bin/fm-tasks-axi.sh" add landed 'dependency merged' >/dev/null
  FM_HOME="$LAB" "$ROOT/bin/fm-tasks-axi.sh" block ship-next --by landed >/dev/null
  FM_HOME="$LAB" "$ROOT/bin/fm-tasks-axi.sh" 'done' landed --pr https://github.com/example/fixture/pull/1 >/dev/null
fi

TMDIR=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$LAB")
export TMUX_TMPDIR="$TMDIR"
TMUX_TMPDIR="$TMDIR" tmux new-session -d -s primary -c "$PWD" -x 200 -y 50
TMUX_TMPDIR="$TMDIR" tmux send-keys -t primary 'export PS1="lab$ "; clear' C-m
sleep 1
PANE=$(TMUX_TMPDIR="$TMDIR" tmux display -p -t primary '#{pane_id}')
echo "lab=$LAB pane=$PANE mode=$MODE"

# FM_INJECT_SKIP=heartbeat is the default suppression; this run proves readiness
# outranks it.
env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
  FM_HOME="$LAB" FM_ROOT_OVERRIDE="$INERT" \
  FM_SUPERVISOR_BACKEND=tmux FM_SUPERVISOR_TARGET="$PANE" \
  FM_INJECT_SKIP=heartbeat FM_ESCALATE_BATCH_SECS=1 FM_HEARTBEAT=1 \
  FM_STALE_ESCALATE_SECS=999999 \
  timeout 20 "$ROOT/bin/fm-supervise-daemon.sh" > "$OUT/daemon-$MODE.stdout" 2>&1 &
DPID=$!
sleep 20
TMUX_TMPDIR="$TMDIR" tmux capture-pane -p -t primary > "$OUT/daemon-$MODE-pane.txt"
kill -TERM "$DPID" 2>/dev/null || true
wait "$DPID" 2>/dev/null
echo "daemon-exit=$?"

{
  echo "=== daemon mode=$MODE (lab home $LAB, private tmux socket, FM_INJECT_SKIP=heartbeat)"
  echo "--- daemon log ---"
  cat "$LAB/state/.supervise-daemon.log" 2>/dev/null
  echo "--- escalation buffer after run ---"
  cat "$LAB/state/.subsuper-escalations" 2>/dev/null
  echo "--- wake queue / heartbeat streak / triage ---"
  cat "$LAB/state/.wake-queue" 2>/dev/null
  echo "streak=$(cat "$LAB/state/.heartbeat-streak" 2>/dev/null || echo none)"
  tail -5 "$LAB/state/.triage-log" 2>/dev/null
  echo "--- watcher stderr ---"
  tail -20 "$LAB/state/.supervise-daemon.watcher.err" 2>/dev/null
  echo "--- supervisor pane capture ---"
  cat "$OUT/daemon-$MODE-pane.txt"
} > "$OUT/daemon-$MODE-transcript.txt"
cat "$OUT/daemon-$MODE-transcript.txt"
