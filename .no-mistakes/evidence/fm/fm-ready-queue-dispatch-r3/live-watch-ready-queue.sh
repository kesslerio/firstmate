#!/usr/bin/env bash
# Evidence driver: the real always-on watcher process deciding whether a
# heartbeat with queued work becomes supervised, and the real drain delivering
# that wake to MAIN.
#
# Each case runs in its own fresh marked lab home with its own private tmux
# server, so no case inherits another's downtime markers. Disposable: throwaway
# state under /tmp, removed on exit. No model/provider call, no real fleet state.
set -u

ROOT=/home/art/.no-mistakes/worktrees/9f75ec418609/01M68G6B7Q26A53RVVPP9NH5H3
REAL_TMUX=$(command -v tmux)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
RESULT=0
SOCKETS=()

cleanup_all() {
  local socket
  for socket in "${SOCKETS[@]:-}"; do
    [ -n "$socket" ] && "$REAL_TMUX" -L "$socket" kill-server 2>/dev/null || true
  done
  find "$LAB" -maxdepth 2 -name .fm-lab-home -printf '%h\n' 2>/dev/null | while IFS= read -r home; do
    "$ROOT/bin/fm-lab-home.sh" teardown "$home" >/dev/null 2>&1 || true
  done
  rm -rf "$LAB"
}
trap cleanup_all EXIT

fail() { printf 'NOT OK: %s\n' "$1" >&2; RESULT=1; }
ok() { printf 'ok: %s\n' "$1"; }

new_case() {  # <name> [hold]
  local name=$1 hold=${2:-} home state socket shim
  home="$LAB/$name/home"
  state="$home/state"
  "$ROOT/bin/fm-lab-home.sh" create "$home" >/dev/null || { echo "lab home failed" >&2; exit 1; }
  cat > "$home/.tasks.toml" <<'TOML'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
TOML
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  socket="fm-lab-watch-$name-$$"
  SOCKETS+=("$socket")
  TMUX_TMPDIR=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$home") || exit 1
  export TMUX_TMPDIR
  "$REAL_TMUX" -L "$socket" new-session -d -s firstmate -x 200 -y 50 || exit 1
  "$REAL_TMUX" -L "$socket" new-window -d -n fm-c1 -t firstmate || exit 1
  shim="$LAB/$name/shim"
  mkdir -p "$shim"
  printf '#!/usr/bin/env bash\nexec %q -L %q "$@"\n' "$REAL_TMUX" "$socket" > "$shim/tmux"
  chmod +x "$shim/tmux"
  if [ "$hold" = hold ]; then
    FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" add held-unit 'waiting for captain' >/dev/null \
      || { echo 'could not queue held unit' >&2; exit 1; }
    FM_HOME="$home" "$ROOT/bin/fm-captain-hold.sh" hold held-unit --reason 'explicit captain hold' >/dev/null \
      || { echo 'could not hold unit' >&2; exit 1; }
  elif [ "$hold" = ready ]; then
    FM_HOME="$home" "$ROOT/bin/fm-tasks-axi.sh" add queued-unit 'queued unit with no blocker' >/dev/null \
      || { echo 'could not queue ready unit' >&2; exit 1; }
  fi
  CASE_HOME=$home
  CASE_STATE=$state
  CASE_SHIM=$shim
}

run_watcher() {  # <out-file> <seconds>
  local out=$1 limit=$2 pid i
  : > "$out"
  PATH="$CASE_SHIM:$PATH" FM_HOME="$CASE_HOME" FM_STATE_OVERRIDE="$CASE_STATE" \
    FM_CONFIG_OVERRIDE="$CASE_HOME/config" FM_POLL=0.2 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=1 "$ROOT/bin/fm-watch.sh" > "$out" 2>"$out.err" &
  pid=$!
  for ((i = 0; i < limit * 4; i++)); do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.25
  done
  kill -0 "$pid" 2>/dev/null && kill -TERM "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
}

# --- 1. one ready queued unit, no status event, no live worker -------------
new_case ready ready
printf 'ready backlog: %s\n' "$(FM_HOME="$CASE_HOME" "$ROOT/bin/fm-tasks-axi.sh" ready | head -1)"
out="$LAB/ready/watch.out"
run_watcher "$out" 60
echo "watcher stdout (ready queue): [$(tr '\n' ' ' < "$out")]"
grep -qx 'heartbeat' "$out" && ok 'ready queued work produced a heartbeat wake' \
  || fail 'ready queued work was absorbed without a supervision turn'
drained=$(FM_HOME="$CASE_HOME" FM_STATE_OVERRIDE="$CASE_STATE" \
  FM_CONFIG_OVERRIDE="$CASE_HOME/config" "$ROOT/bin/fm-wake-drain.sh" 2>/dev/null)
printf '%s\n' "$drained" | grep -q "$(printf '\theartbeat\t')" \
  && ok 'the heartbeat wake reached MAIN through the real drain' \
  || fail 'the heartbeat wake was not durably delivered'
printf '%s\n' "$drained" | grep -m1 heartbeat || true

# --- 2. empty queue, no status event --------------------------------------
new_case empty
printf 'ready backlog: %s\n' "$(FM_HOME="$CASE_HOME" "$ROOT/bin/fm-tasks-axi.sh" ready | head -1)"
out="$LAB/empty/watch.out"
run_watcher "$out" 15
echo "watcher stdout (empty queue): [$(tr '\n' ' ' < "$out")]"
if [ -s "$out" ] || [ -s "$CASE_STATE/.wake-queue" ]; then
  fail 'an empty queue produced an unnecessary supervision turn'
else
  ok 'an empty queue stayed absorbed while the heartbeat schedule advanced'
fi
[ "$(cat "$CASE_STATE/.heartbeat-streak" 2>/dev/null || echo 0)" -ge 1 ] \
  && ok 'the absorbed heartbeat was still triaged' \
  || fail 'the heartbeat was never triaged'

# --- 3. captain-held ready work stays quiet -------------------------------
new_case held hold
printf 'ready backlog (held unit): %s\n' "$(FM_HOME="$CASE_HOME" "$ROOT/bin/fm-tasks-axi.sh" ready | head -1)"
out="$LAB/held/watch.out"
run_watcher "$out" 15
echo "watcher stdout (held queue): [$(tr '\n' ' ' < "$out")]"
if [ -s "$out" ] || [ -s "$CASE_STATE/.wake-queue" ]; then
  fail 'captain-held work produced an unnecessary supervision turn'
else
  ok 'captain-held work stayed quiet while the heartbeat schedule advanced'
fi

exit "$RESULT"
