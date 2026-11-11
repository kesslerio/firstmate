#!/usr/bin/env bash
# Manual, product-level drive of bin/fm-watch.sh heartbeat triage accounting.
# Each case builds a disposable FM_HOME (its own state/config/data), points the
# watcher at it, and records the wake reason, the durable queue, and the
# post-heartbeat .heartbeat-streak. tmux and the tasks-axi CLI are the only
# stubbed boundaries (no panes exist in the lab home; the tasks-axi shim exists
# only for the unreadable/slow readiness probes).
set -u

ROOT={run-worktree}
EVID=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-rq-lab.XXXXXX") || exit 1
LOG="$EVID/r5-heartbeat-accounting-transcript.log"
: > "$LOG"
trap 'rm -rf "$LAB"' EXIT

say() { printf '%s\n' "$*" | tee -a "$LOG"; }

# Public markdown backlog configuration contract (docs/configuration.md).
write_tasks_toml() {
  cat > "$1/.tasks.toml" <<'TOML'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
TOML
}

# tmux boundary stub: the lab home has no panes, so the fleet scan sees none.
write_tmux_stub() {
  cat > "$1/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
[ "${1:-}" = list-windows ] && exit 0
exit 1
SH
  chmod +x "$1/fakebin/tmux"
}

make_case() {  # <name> <posture: away|attended> <queue: ready|empty|unreadable|slow>
  local name=$1 posture=$2 queue=$3 dir="$LAB/$1"
  mkdir -p "$dir/state" "$dir/config" "$dir/data" "$dir/fakebin" "$dir/home"
  write_tasks_toml "$dir"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/data/backlog.md"
  write_tmux_stub "$dir"
  case "$queue" in
    ready)
      FM_HOME="$dir" "$ROOT/bin/fm-tasks-axi.sh" add candidate 'queued after a cleared restriction' >/dev/null \
        || { say "setup failed: could not queue candidate for $name"; return 1; }
      ;;
    unreadable)
      printf '#!/usr/bin/env bash\nprintf "readiness unavailable\\n" >&2\nexit 2\n' > "$dir/fakebin/tasks-axi"
      chmod +x "$dir/fakebin/tasks-axi"
      ;;
    slow)
      printf '#!/usr/bin/env bash\nsleep 60\nprintf "count: 1\\n"\n' > "$dir/fakebin/tasks-axi"
      chmod +x "$dir/fakebin/tasks-axi"
      ;;
  esac
  [ "$posture" = away ] && printf 'mode: quiet\n' > "$dir/state/.afk"
  printf '3\n' > "$dir/state/.heartbeat-streak"
  printf '%s\n' "$(($(date +%s) - 30))" > "$dir/state/.last-heartbeat"
  # touch the mtime so the heartbeat schedule is already due
  touch -d "@$(( $(date +%s) - 30 ))" "$dir/state/.last-heartbeat" 2>/dev/null || true
  printf '%s\n' "$dir"
}

run_watcher() {  # <dir> [watcher-script]
  local dir=$1 watcher=${2:-$ROOT/bin/fm-watch.sh}
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_POLL=0.2 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 \
    "$watcher" > "$dir/watch.out" 2> "$dir/watch.err"
  return $?
}

report() {  # <name> <dir>
  local name=$1 dir=$2 streak queue drain
  streak=$(cat "$dir/state/.heartbeat-streak" 2>/dev/null || echo 0)
  queue=$([ -s "$dir/state/.wake-queue" ] && sed 's/\t/<TAB>/g' "$dir/state/.wake-queue" || echo '<empty>')
  say "  wake-reason: $(cat "$dir/watch.out" 2>/dev/null | tr '\n' '|')"
  say "  heartbeat-streak-after: $streak"
  say "  durable-wake-queue: $queue"
  [ -s "$dir/watch.err" ] && say "  watcher-stderr: $(head -3 "$dir/watch.err" | tr '\n' '|')"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$ROOT/bin/fm-wake-drain.sh" > "$dir/drain.out" 2> "$dir/drain.err" \
    && drain=$(sed 's/\t/<TAB>/g' "$dir/drain.out" | tr '\n' '|') || drain='DRAIN-FAILED'
  say "  drain-output: $drain"
  return 0
}

# --- ready / unreadable / slow: the watcher exits on the heartbeat wake ------
drive_exiting_case() {  # <name> <posture> <queue> [watcher]
  local name=$1 posture=$2 queue=$3 watcher=${4:-}
  local dir start elapsed rc
  say "== $name (posture=$posture queue=$queue${watcher:+ watcher=$watcher})"
  dir=$(make_case "$name" "$posture" "$queue") || return 0
  start=$(date +%s%N)
  if [ -n "$watcher" ]; then run_watcher "$dir" "$watcher"; rc=$?; else run_watcher "$dir"; rc=$?; fi
  elapsed=$(( ($(date +%s%N) - start) / 1000000 ))
  say "  watcher-exit: $rc after ${elapsed}ms"
  report "$name" "$dir"
}

# --- absorb cases: the watcher keeps blocking, so stop it once accounted -----
drive_absorb_case() {  # <name> <posture> <queue>
  local name=$1 posture=$2 queue=$3 dir pid i rc
  say "== $name (posture=$posture queue=$queue)"
  dir=$(make_case "$name" "$posture" "$queue") || return 0
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_POLL=0.2 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 \
    "$ROOT/bin/fm-watch.sh" > "$dir/watch.out" 2> "$dir/watch.err" &
  pid=$!
  for ((i=0; i<200; i++)); do
    [ "$(cat "$dir/state/.heartbeat-streak" 2>/dev/null || echo 0)" -ge 4 ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null; rc=$?
  say "  watcher-stopped: rc=$rc"
  report "$name" "$dir"
}

say "FM_ROOT=$ROOT"
say "watcher head: $(git -C "$ROOT" log -1 --format='%h %s')"
say "lab: $LAB"
say ""

# S1: away posture, landed dependency makes ready work visible.
drive_exiting_case away-ready away ready
# S2: away posture, readiness cannot be determined (probe refuses).
drive_exiting_case away-unreadable away unreadable
# S7 (adversarial): away posture, readiness probe hangs; the heartbeat must stay bounded.
drive_exiting_case away-slow-probe away slow
# S4: attended posture, same ready queue (control: must not regress).
drive_exiting_case attended-ready attended ready
# S3: away posture, proven-empty queue keeps plain idle accounting.
drive_absorb_case away-empty away empty
# S5: attended posture, proven-empty queue is quiet (no dispatch wake).
drive_absorb_case attended-empty attended empty

# Pre-fix comparison: the parent commit's watcher (before readiness moved ahead
# of the posture split) against the same away cases.
PREFIX="$LAB/prefix"
mkdir -p "$PREFIX"
cp -a "$ROOT/bin" "$PREFIX/bin"
git -C "$ROOT" show e467ad8bb:bin/fm-watch.sh > "$PREFIX/bin/fm-watch.sh"
chmod +x "$PREFIX/bin/fm-watch.sh"
say ""
say "== pre-fix baseline: e467ad8bb bin/fm-watch.sh (afk short-circuit before readiness)"
drive_exiting_case prefix-away-ready away ready "$PREFIX/bin/fm-watch.sh"
drive_absorb_case prefix-away-empty away empty

say ""
say "DONE"
