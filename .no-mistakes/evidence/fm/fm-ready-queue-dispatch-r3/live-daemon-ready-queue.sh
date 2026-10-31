#!/usr/bin/env bash
# Evidence driver: the real away-mode daemon process, on a private tmux socket,
# deciding whether a heartbeat with queued work reaches the supervisor.
#
# Disposable: marked lab home, private tmux server, throwaway state under /tmp,
# everything removed on exit. No model/provider call, no real fleet state.
set -u

ROOT=/home/art/.no-mistakes/worktrees/9f75ec418609/01M68G6B7Q26A53RVVPP9NH5H3
DAEMON="$ROOT/bin/fm-supervise-daemon.sh"
REAL_TMUX=$(command -v tmux)
SOCKET=fm-lab-readyq-$$
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
HOME_DIR="$LAB/home"
STATE="$HOME_DIR/state"
LOG="$LAB/submitted.log"
DAEMON_PID=
RESULT=0

cleanup_all() {
  if [ -n "${DAEMON_PID:-}" ]; then
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
    DAEMON_PID=
  fi
  if [ -n "${SOCKET:-}" ]; then
    "$REAL_TMUX" -L "$SOCKET" kill-server 2>/dev/null || true
  fi
  "$ROOT/bin/fm-lab-home.sh" teardown "$HOME_DIR" >/dev/null 2>&1 || true
  rm -rf "$LAB"
}
trap cleanup_all EXIT

fail() { printf 'NOT OK: %s\n' "$1" >&2; RESULT=1; }
ok() { printf 'ok: %s\n' "$1"; }

# --- disposable home --------------------------------------------------------
"$ROOT/bin/fm-lab-home.sh" create "$HOME_DIR" >/dev/null || { echo "lab home failed"; exit 1; }
cat > "$HOME_DIR/.tasks.toml" <<'TOML'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
TOML
printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
mkdir -p "$STATE"
printf 'mode: quiet\n' > "$STATE/.afk"
: > "$LOG"

# --- private tmux with a composer pane --------------------------------------
TMUX_TMPDIR=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$HOME_DIR") || exit 1
export TMUX_TMPDIR
"$REAL_TMUX" -L "$SOCKET" new-session -d -s supervisor -x 200 -y 50 || exit 1
PANE=$("$REAL_TMUX" -L "$SOCKET" display-message -p -t supervisor '#{pane_id}')

LOOP="$LAB/composer.sh"
cat > "$LOOP" <<'LOOP'
#!/usr/bin/env bash
MARK=$'\xE2\x81\xA3'
LOG="$1"
OLD_STTY=$(stty -g 2>/dev/null || true)
[ -z "$OLD_STTY" ] || stty -echo -icanon min 1 time 0 2>/dev/null || true
cleanup() { [ -z "$OLD_STTY" ] || stty "$OLD_STTY" 2>/dev/null || true; }
trap cleanup EXIT INT TERM
_buf=
redraw() { printf '\r\033[K\xe2\x9d\xaf %s' "$_buf"; }
submit_line() {
  local _line=$_buf _c _hex
  if [ "${_line:0:1}" = "$MARK" ]; then _c="injection"; else _c="user"; fi
  _hex=$(printf '%s' "$_line" | od -An -tx1 | tr -d ' \n')
  printf '%s\t%s\t%s\n' "$_hex" "$_line" "$_c" >> "$LOG"
  _buf=
  printf '\r\033[K\n'
  redraw
}
redraw
while IFS= read -r -n 1 _ch; do
  if [ -z "$_ch" ]; then submit_line; continue; fi
  case "$_ch" in
    $'\r'|$'\n') submit_line ;;
    $'\177'|$'\b') _buf=${_buf%?}; redraw ;;
    *) _buf="${_buf}${_ch}"; redraw ;;
  esac
done
LOOP
chmod +x "$LOOP"
"$REAL_TMUX" -L "$SOCKET" send-keys -t "$PANE" "bash '$LOOP' '$LOG'" Enter
sleep 1
"$REAL_TMUX" -L "$SOCKET" new-window -d -n fm-fake-c1 -t supervisor

# tmux shim so the daemon's bare `tmux` reaches this private server.
SHIM="$LAB/shim"
mkdir -p "$SHIM"
cat > "$SHIM/tmux" <<SHIM
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SHIM
chmod +x "$SHIM/tmux"

# tasks-axi shim: passes through, or fails readiness on demand.
cat > "$SHIM/tasks-axi" <<'SHIM'
#!/usr/bin/env bash
if [ -f "$FM_LAB_UNREADABLE_FLAG" ] && [ "${1:-}" = ready ]; then
  printf 'readiness unavailable\n' >&2
  exit 2
fi
exec /home/art/.npm-packages/bin/tasks-axi "$@"
SHIM
chmod +x "$SHIM/tasks-axi"
export FM_LAB_UNREADABLE_FLAG="$LAB/unreadable"

queue_heartbeat() {
  FM_STATE_OVERRIDE="$STATE" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_wake_append heartbeat heartbeat heartbeat
  ' _ "$ROOT" || fail 'could not enqueue heartbeat'
}

wake_queue_lines() {
  if [ -f "$STATE/.wake-queue" ]; then
    wc -l < "$STATE/.wake-queue" | tr -d ' '
  else
    printf '0'
  fi
}

wait_for_log() {  # <pattern> <seconds>
  local pattern=$1 limit=$2 i
  for ((i = 0; i < limit * 4; i++)); do
    if grep -qF -- "$pattern" "$LOG"; then return 0; fi
    sleep 0.25
  done
  return 1
}

# --- real daemon process ----------------------------------------------------
PATH="$SHIM:$PATH" \
FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
FM_DAEMON_PRIMARY_HARNESS=unknown \
FM_SUPERVISOR_TARGET="$PANE" FM_SUPERVISOR_BACKEND=tmux \
FM_INJECT_SKIP=heartbeat \
FM_ESCALATE_BATCH_SECS=0 FM_HOUSEKEEPING_TICK=1 FM_POLL=1 FM_SIGNAL_GRACE=1 \
FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 FM_STALE_ESCALATE_SECS=999999 \
nohup "$DAEMON" >"$LAB/daemon.out" 2>"$LAB/daemon.err" &
DAEMON_PID=$!
for ((i = 0; i < 150; i++)); do
  [ -f "$STATE/.supervise-daemon.pid" ] && break
  sleep 0.2
done
if [ ! -f "$STATE/.supervise-daemon.pid" ]; then
  echo "daemon startup failed:" >&2
  cat "$LAB/daemon.err" >&2
  exit 1
fi
echo "daemon started pid=$(cat "$STATE/.supervise-daemon.pid") target=$PANE socket=$SOCKET"
grep -m1 'daemon starting' "$LAB/daemon.out" || true

# --- 1. ready queued work is not skip-suppressed ----------------------------
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-tasks-axi.sh" add next-unit 'queued unit with no blocker' >/dev/null \
  || fail 'could not queue a ready unit'
printf 'ready backlog: %s\n' "$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-tasks-axi.sh" ready | tr '\n' ' ')"
: > "$LOG"
queue_heartbeat
if wait_for_log 'ready-queue fleet check:' 40; then
  ok 'ready queued work reached the supervisor pane despite FM_INJECT_SKIP=heartbeat'
else
  fail 'ready queued work was suppressed with no digest'
fi
sleep 1
[ "$(wake_queue_lines)" = 0 ] && ok 'the handled heartbeat was acknowledged' \
  || fail "the ready heartbeat stayed in the durable queue ($(wake_queue_lines) lines)"

# --- 2. an empty queue stays silent ----------------------------------------
printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
printf 'empty backlog ready: %s\n' "$(FM_HOME="$HOME_DIR" "$ROOT/bin/fm-tasks-axi.sh" ready | tr '\n' ' ')"
: > "$LOG"
queue_heartbeat
sleep 8
if grep -qF 'ready-queue fleet check:' "$LOG"; then
  fail 'an empty queue produced an unnecessary dispatch wake'
else
  ok 'an empty queue produced no dispatch wake'
fi
[ "$(wake_queue_lines)" = 0 ] && ok 'the absorbed heartbeat was acknowledged' \
  || fail "the empty-queue heartbeat stayed queued ($(wake_queue_lines) lines)"

# --- 3. unreadable readiness fails closed ----------------------------------
: > "$FM_LAB_UNREADABLE_FLAG"
: > "$LOG"
queue_heartbeat
if wait_for_log 'ready-queue fleet check:' 40; then
  ok 'unreadable readiness escalated instead of reading as an empty queue'
else
  fail 'unreadable readiness was silently absorbed'
fi
grep -m1 'ready-queue fleet check:' "$LOG" | cut -f2- || true

exit "$RESULT"
