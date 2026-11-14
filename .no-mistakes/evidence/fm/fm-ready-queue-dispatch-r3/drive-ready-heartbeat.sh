#!/usr/bin/env bash
# Drive the real firstmate watcher CLI (bin/fm-watch.sh) against a disposable
# home per heartbeat posture/readiness case and record observable state.
# Usage: drive-ready-heartbeat.sh <repo-root> <evidence-out-dir>
set -u
ROOT=$(cd "$1" && pwd)
OUT=$(cd "$2" && pwd)
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-hb.XXXXXX")
INERT=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-inert.XXXXXX")   # non-git: keeps guard tangle check quiet
trap 'rm -rf "$LAB" "$INERT"' EXIT
SUMMARY="$OUT/heartbeat-scenarios.txt"
: > "$SUMMARY"

tasks_toml() {
  cat > "$1" <<'TOML'
backend = "markdown"

[markdown]
path = "data/backlog.md"
archive = "data/done-archive.md"
done_keep = 10
TOML
}

# mkcase <name> <posture:attended|away> <queue:ready|empty|held|unreadable>
mkcase() {
  local name=$1 posture=$2 queue=$3 dir="$LAB/$1"
  mkdir -p "$dir/data" "$dir/config" "$dir/state" "$dir/fakebin"
  tasks_toml "$dir/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/data/backlog.md"
  case "$queue" in
    ready)
      FM_HOME="$dir" "$ROOT/bin/fm-tasks-axi.sh" add ship-next 'beyond current spend cap' >/dev/null
      FM_HOME="$dir" "$ROOT/bin/fm-tasks-axi.sh" add landed 'dependency already merged' >/dev/null
      FM_HOME="$dir" "$ROOT/bin/fm-tasks-axi.sh" block ship-next --by landed >/dev/null
      FM_HOME="$dir" "$ROOT/bin/fm-tasks-axi.sh" 'done' landed --pr https://github.com/example/fixture/pull/1 >/dev/null
      ;;
    held)
      FM_HOME="$dir" "$ROOT/bin/fm-tasks-axi.sh" add ship-next 'waiting on captain' >/dev/null
      FM_HOME="$dir" "$ROOT/bin/fm-captain-hold.sh" hold ship-next --reason 'explicit captain hold' >/dev/null
      ;;
    unreadable)
      FM_HOME="$dir" "$ROOT/bin/fm-tasks-axi.sh" add ship-next 'queue present but unreadable' >/dev/null
      printf '#!/usr/bin/env bash\nprintf "readiness unavailable\\n" >&2\nexit 2\n' > "$dir/fakebin/tasks-axi"
      chmod +x "$dir/fakebin/tasks-axi"
      ;;
  esac
  [ "$posture" = away ] && printf 'mode: quiet\n' > "$dir/state/.afk"
  printf '3\n' > "$dir/state/.heartbeat-streak"
  touch -d '@'"$(( $(date +%s) - 30 ))" "$dir/state/.last-heartbeat" 2>/dev/null \
    || touch -t "$(date -v-30S '+%Y%m%d%H%M.%S')" "$dir/state/.last-heartbeat"
  printf '%s\n' "$dir"
}

run_case() {
  local name=$1 posture=$2 queue=$3 dir out rc streak wake triage
  dir=$(mkcase "$name" "$posture" "$queue")
  out="$dir/watch.stdout"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_ROOT_OVERRIDE="$INERT" \
    FM_POLL=0.2 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 \
    timeout 60 "$ROOT/bin/fm-watch.sh" > "$out" 2>"$dir/watch.stderr"
  rc=$?
  streak=$(cat "$dir/state/.heartbeat-streak" 2>/dev/null || echo missing)
  wake=$(cat "$dir/state/.wake-queue" 2>/dev/null || true)
  triage=$(tail -3 "$dir/state/.triage-log" 2>/dev/null || true)
  # Persist the durable delivery proof from the real drain CLI.
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_ROOT_OVERRIDE="$INERT" \
    "$ROOT/bin/fm-wake-drain.sh" > "$dir/drain.out" 2>/dev/null
  {
    printf '=== case %s (posture=%s queue=%s)\n' "$name" "$posture" "$queue"
    printf 'watcher-exit: %s\n' "$rc"
    printf 'watcher-stdout: %s\n' "$(cat "$out")"
    printf 'heartbeat-streak-after: %s\n' "$streak"
    printf 'wake-queue-rows: %s\n' "$(printf '%s' "$wake" | tr '\n' ';')"
    printf 'drain-output: %s\n' "$(cat "$dir/drain.out" | tr '\n' ';')"
    printf 'triage-tail: %s\n\n' "$(printf '%s' "$triage" | tr '\n' ';')"
  } >> "$SUMMARY"
  ls "$dir" >/dev/null
  rm -rf "$LAB/$name"
}

# Held/empty queues never surface, so bound them: kill the loop once the
# absorbed-heartbeat counter moves, then read state.
run_quiet_case() {
  local name=$1 posture=$2 queue=$3 dir pid rc i streak wake
  dir=$(mkcase "$name" "$posture" "$queue")
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_ROOT_OVERRIDE="$INERT" \
    FM_POLL=0.2 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 \
    "$ROOT/bin/fm-watch.sh" > "$dir/watch.stdout" 2>"$dir/watch.stderr" &
  pid=$!
  for ((i=0; i<200; i++)); do
    [ "$(cat "$dir/state/.heartbeat-streak" 2>/dev/null || echo 3)" -gt 3 ] && break
    sleep 0.1
  done
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null
  rc=$?
  streak=$(cat "$dir/state/.heartbeat-streak" 2>/dev/null || echo missing)
  wake=$(cat "$dir/state/.wake-queue" 2>/dev/null || true)
  {
    printf '=== case %s (posture=%s queue=%s)\n' "$name" "$posture" "$queue"
    printf 'watcher-exit: %s (loop stopped once the case state was reached; an away heartbeat exits on its own, an absorbed one is stopped by this driver)\n' "$rc"
    printf 'watcher-stdout: %s\n' "$(cat "$dir/watch.stdout")"
    printf 'heartbeat-streak-after: %s\n' "$streak"
    printf 'wake-queue-rows: %s\n' "$(printf '%s' "$wake" | tr '\n' ';')"
    printf 'triage-tail: %s\n\n' "$(tail -3 "$dir/state/.triage-log" 2>/dev/null | tr '\n' ';')"
  } >> "$SUMMARY"
  rm -rf "$LAB/$name"
}

run_case attended-ready attended ready
run_case away-ready away ready
run_case away-unreadable away unreadable
run_quiet_case away-empty away empty
run_quiet_case attended-held attended held

printf 'driver-lab-cleaned: %s\n' "$([ -z "$(ls -A "$LAB" 2>/dev/null)" ] && echo yes)"
cat "$SUMMARY"
