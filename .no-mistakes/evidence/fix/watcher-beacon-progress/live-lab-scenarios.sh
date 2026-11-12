#!/usr/bin/env bash
# live-lab-scenarios.sh - drive the real watcher, arm, and guard in a disposable
# marked lab home (bin/fm-lab-home.sh), per the firstmate live-validation runbook.
# Evidence only; never touches the operator's home or default tmux server.
set -u

ROOT={run-worktree}
EV=~/.no-mistakes/evidence/01M77TT015RB584XQG5V31A01V
CLEAN_ENV=(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE
  -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE
  -u FM_GUARD_GRACE -u FM_POLL -u FM_HEARTBEAT)

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
HOLDER_PID=
ARM_PID=
WATCH_PID=

cleanup() {
  local p
  for p in "$ARM_PID" "$WATCH_PID" "$HOLDER_PID"; do
    [ -n "$p" ] || continue
    kill -CONT "$p" 2>/dev/null || true
    kill -TERM "$p" 2>/dev/null || true
  done
  sleep 0.3
  for p in "$ARM_PID" "$WATCH_PID" "$HOLDER_PID"; do
    [ -n "$p" ] || continue
    kill -KILL "$p" 2>/dev/null || true
  done
  rm -rf "$LAB"
}
trap cleanup EXIT

step() { printf '\n=== %s ===\n' "$*"; }

"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "lab create failed"; exit 1; }
mkdir -p "$LAB/tmux" "$LAB/root"
printf 'lab=%s\n' "$LAB"

# ---------------------------------------------------------------- scenario A
# A live identity-matched holder with a 700s-old beacon: inside the home's
# configured FM_GUARD_GRACE=1200 but far past the legacy 300s default. The arm
# must load config/watch.env (the consolidation the change finishes) and attach;
# a reader that lost settings load would judge 700s stale.
step "A: arm loads home watch.env and attaches to a 700s beacon under configured grace 1200"
printf '%s\n' 'export FM_POLL=600' 'export FM_GUARD_GRACE=1200' > "$LAB/config/watch.env"
sleep 300 &
HOLDER_PID=$!
IDENTITY=$(bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$HOLDER_PID")
mkdir -p "$LAB/state/.watch.lock"
printf '%s\n' "$HOLDER_PID" > "$LAB/state/.watch.lock/pid"
printf '%s\n' "$LAB" > "$LAB/state/.watch.lock/fm-home"
printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$LAB/state/.watch.lock/watcher-path"
printf '%s\n' "$IDENTITY" > "$LAB/state/.watch.lock/pid-identity"
: > "$LAB/state/.last-watcher-beat"
touch -d @$(( $(date +%s) - 700 )) "$LAB/state/.last-watcher-beat"
printf 'holder live pid=%s beacon_age=%ss\n' "$HOLDER_PID" "$(( $(date +%s) - $(stat -c %Y "$LAB/state/.last-watcher-beat") ))"
printf 'fm_beacon_grace in lab home = %s\n' \
  "$("${CLEAN_ENV[@]}" FM_HOME="$LAB" bash -c '. "$1"; fm_beacon_grace' _ "$ROOT/bin/fm-wake-lib.sh" 2>&1)"
"${CLEAN_ENV[@]}" FM_HOME="$LAB" "$ROOT/bin/fm-watch-arm.sh" > "$EV/live-A-arm.log" 2>&1 &
ARM_PID=$!
i=0
while [ "$i" -lt 60 ]; do
  grep -q '^watcher: attached' "$EV/live-A-arm.log" 2>/dev/null && break
  sleep 0.25; i=$((i + 1))
done
cat "$EV/live-A-arm.log"
kill -TERM "$ARM_PID" "$HOLDER_PID" 2>/dev/null || true
HOLDER_PID= ; ARM_PID=
sleep 0.3
rm -rf "$LAB/state/.watch.lock"

step "A2: the guard reads the same configured grace (silent at 700s, warns at 100s with grace 60)"
# A live identity-matched holder whose beacon is old: the guard judges freshness
# against the home-configured grace, not a flat default.
printf '%s\n' 'export FM_POLL=600' 'export FM_GUARD_GRACE=1200' > "$LAB/config/watch.env"
printf 'kind=ship\n' > "$LAB/state/task.meta"
sleep 300 &
HOLDER_PID=$!
IDENTITY=$(bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$HOLDER_PID")
mkdir -p "$LAB/state/.watch.lock"
printf '%s\n' "$HOLDER_PID" > "$LAB/state/.watch.lock/pid"
printf '%s\n' "$LAB" > "$LAB/state/.watch.lock/fm-home"
printf '%s\n' "$ROOT/bin/fm-watch.sh" > "$LAB/state/.watch.lock/watcher-path"
printf '%s\n' "$IDENTITY" > "$LAB/state/.watch.lock/pid-identity"
: > "$LAB/state/.last-watcher-beat"
touch -d @$(( $(date +%s) - 700 )) "$LAB/state/.last-watcher-beat"
"${CLEAN_ENV[@]}" FM_HOME="$LAB" FM_ROOT_OVERRIDE="$LAB/root" FM_POLL=15 \
  FM_SUPERVISION_MODEL=persistent "$ROOT/bin/fm-guard.sh" > "$EV/live-A2-guard-1200.log" 2>&1
printf 'guard with home grace=1200, live holder, beacon 700s -> %s WATCHER DOWN lines, output bytes=%s\n' \
  "$(grep -c 'WATCHER DOWN' "$EV/live-A2-guard-1200.log" || true)" "$(wc -c < "$EV/live-A2-guard-1200.log")"
printf '%s\n' 'export FM_POLL=600' 'export FM_GUARD_GRACE=60' > "$LAB/config/watch.env"
touch -d @$(( $(date +%s) - 100 )) "$LAB/state/.last-watcher-beat"
"${CLEAN_ENV[@]}" FM_HOME="$LAB" FM_ROOT_OVERRIDE="$LAB/root" FM_POLL=15 \
  FM_SUPERVISION_MODEL=persistent "$ROOT/bin/fm-guard.sh" > "$EV/live-A2-guard-60.log" 2>&1
printf 'guard with home grace=60, live holder, beacon 100s -> %s WATCHER DOWN lines\n' \
  "$(grep -c 'WATCHER DOWN' "$EV/live-A2-guard-60.log" || true)"
grep -m1 -A2 'WATCHER DOWN' "$EV/live-A2-guard-60.log" || true
kill -TERM "$HOLDER_PID" 2>/dev/null || true
HOLDER_PID=
rm -rf "$LAB/state/.watch.lock"

# ---------------------------------------------------------------- scenario B
# A real watcher whose single check sweep runs longer than the 8s grace it was
# given: the beacon must stay fresh from inside the sweep while a check child is
# genuinely running, so the guard raises no false alarm.
step "B: a real watcher's 16s check sweep keeps the beacon fresh under grace 8; guard stays silent"
rm -f "$LAB"/state/slow-*.check.sh "$LAB"/state/slow-*.check.json
printf '%s\n' 'export FM_POLL=1' 'export FM_GUARD_GRACE=8' 'export FM_SIGNAL_GRACE=1' \
  'export FM_CHECK_INTERVAL=1' 'export FM_CHECK_TIMEOUT=30' 'export FM_HEARTBEAT=999999' \
  > "$LAB/config/watch.env"
i=0
while [ "$i" -lt 8 ]; do
  i=$((i + 1))
  printf '#!/usr/bin/env bash\nsleep 2\nexit 0\n' > "$LAB/state/slow-$i.check.sh"
  chmod 0700 "$LAB/state/slow-$i.check.sh"
  "${CLEAN_ENV[@]}" FM_HOME="$LAB" "$ROOT/bin/fm-check-register.sh" "slow-$i" >/dev/null \
    || echo "register slow-$i failed"
done
"${CLEAN_ENV[@]}" FM_HOME="$LAB" "$ROOT/bin/fm-watch.sh" > "$EV/live-B-watch.log" 2>&1 &
WATCH_PID=$!
i=0
while [ "$i" -lt 100 ]; do
  [ "$(cat "$LAB/state/.watch.lock/pid" 2>/dev/null || true)" = "$WATCH_PID" ] \
    && [ -e "$LAB/state/.last-watcher-beat" ] && [ -e "$LAB/state/.watch-cycle" ] && break
  sleep 0.1; i=$((i + 1))
done
printf 'watcher pid=%s lock=%s\n' "$WATCH_PID" "$(cat "$LAB/state/.watch.lock/pid" 2>/dev/null || true)"
CYCLE_START=$(stat -c %Y "$LAB/state/.watch-cycle")
# The cycle runs its registered check sweep before the terminal wait: sample the
# beacon while that one cycle is already older than the 8s grace.
samples=0
while :; do
  now=$(date +%s); age=$(( now - CYCLE_START ))
  printf 'sample: cycle_age=%ss beacon_age=%ss (%s checks registered)\n' "$age" \
    "$(( now - $(stat -c %Y "$LAB/state/.last-watcher-beat" 2>/dev/null || echo "$now") ))" \
    "$(ls "$LAB"/state/slow-*.check.sh 2>/dev/null | wc -l)"
  [ "$age" -ge 12 ] && break
  sleep 3; samples=$(( samples + 1 ))
  [ "$samples" -gt 8 ] && break
done
BEACON_AGE=$(( $(date +%s) - $(stat -c %Y "$LAB/state/.last-watcher-beat") ))
printf 'cycle_age=%ss beacon_age=%ss (grace 8s)\n' "$(( $(date +%s) - CYCLE_START ))" "$BEACON_AGE"
"${CLEAN_ENV[@]}" FM_HOME="$LAB" FM_ROOT_OVERRIDE="$LAB/root" FM_POLL=15 \
  FM_SUPERVISION_MODEL=persistent "$ROOT/bin/fm-guard.sh" > "$EV/live-B-guard.log" 2>&1
printf 'guard during the working sweep -> %s WATCHER DOWN lines, output bytes=%s\n' \
  "$(grep -c 'WATCHER DOWN' "$EV/live-B-guard.log" || true)" "$(wc -c < "$EV/live-B-guard.log")"

# ---------------------------------------------------------------- scenario C
# Adversarial: freeze the same real watcher mid-sweep. A frozen parent cannot
# make progress, so the beacon must age and the guard must raise the alarm even
# though its check children keep running.
step "C: SIGSTOP the same working watcher mid-sweep; the guard raises WATCHER DOWN"
kill -STOP "$WATCH_PID"
sleep 11
BEACON_AGE=$(( $(date +%s) - $(stat -c %Y "$LAB/state/.last-watcher-beat") ))
printf 'frozen watcher pid=%s beacon_age=%ss\n' "$WATCH_PID" "$BEACON_AGE"
"${CLEAN_ENV[@]}" FM_HOME="$LAB" FM_ROOT_OVERRIDE="$LAB/root" FM_POLL=15 \
  FM_SUPERVISION_MODEL=persistent "$ROOT/bin/fm-guard.sh" > "$EV/live-C-guard.log" 2>&1
printf 'guard on the frozen watcher -> %s WATCHER DOWN lines\n' \
  "$(grep -c 'WATCHER DOWN' "$EV/live-C-guard.log" || true)"
grep -m1 -A3 'WATCHER DOWN' "$EV/live-C-guard.log" || true
kill -CONT "$WATCH_PID" 2>/dev/null || true
kill -TERM "$WATCH_PID" 2>/dev/null || true
sleep 0.5
kill -KILL "$WATCH_PID" 2>/dev/null || true
WATCH_PID=
printf '\nlab teardown: rm -rf %s\n' "$LAB"
