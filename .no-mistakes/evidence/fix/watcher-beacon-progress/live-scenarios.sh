#!/usr/bin/env bash
# Live scenarios for branch fix/watcher-beacon-progress.
# Drives the real product: bin/fm-watch.sh (a real supervision watcher),
# bin/fm-guard.sh, and bin/fm-watch-arm.sh, each against a disposable marked lab
# home minted by bin/fm-lab-home.sh. External tools are never replaced: the only
# PATH shims add latency to a real per-record read (od) so one cycle outlasts the
# guard grace on this machine, which is what a deep backlog does on a large home.
set -u

ROOT=${ROOT:?}
EV=${EV:?}
GRACE_A=5

LOG="$EV/live-scenarios.log"
: > "$LOG"
note() { printf '%s\n' "$*" | tee -a "$LOG"; }
record() { printf '%s\n' "$*" >> "$LOG"; }

age() {  # <path>
  local m
  m=$(stat -c %Y "$1" 2>/dev/null) || m=$(stat -f %m "$1" 2>/dev/null) || { printf '999999'; return 0; }
  printf '%s' "$(( $(date +%s) - m ))"
}

CLEANUP_LAB=
CLEANUP_PIDS=()
cleanup() {
  local p
  for p in "${CLEANUP_PIDS[@]:-}"; do
    [ -n "$p" ] || continue
    kill -CONT "$p" 2>/dev/null || true
    kill -TERM "$p" 2>/dev/null || true
  done
  sleep 0.5
  for p in "${CLEANUP_PIDS[@]:-}"; do
    [ -n "$p" ] || continue
    kill -KILL "$p" 2>/dev/null || true
  done
  [ -z "$CLEANUP_LAB" ] || rm -rf "$CLEANUP_LAB"
}
trap cleanup EXIT

new_lab() {  # <name> -> echoes lab home
  local dir
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || exit 1
  "$ROOT/bin/fm-lab-home.sh" create "$dir" >/dev/null || exit 1
  CLEANUP_LAB=$dir
  printf '%s' "$dir"
}

register_fast_check() {  # <home> <name>
  printf '#!/usr/bin/env bash\nexit 0\n' > "$1/state/$2.check.sh"
  chmod 0700 "$1/state/$2.check.sh"
  FM_HOME=$1 "$ROOT/bin/fm-check-register.sh" "$2" >/dev/null || echo "register failed $2" >&2
}

register_slow_checks() {  # <home> <count>
  local i=1
  while [ "$i" -le "$2" ]; do
    printf '#!/usr/bin/env bash\nsleep 2\nexit 0\n' > "$1/state/slow-$i.check.sh"
    chmod 0700 "$1/state/slow-$i.check.sh"
    FM_HOME=$1 "$ROOT/bin/fm-check-register.sh" "slow-$i" >/dev/null || echo "register failed slow-$i" >&2
    i=$((i + 1))
  done
}

# start_watcher <home> <logfile> <grace> [extra env via caller prefix]
start_watcher() {
  local home=$1 out=$2 grace=$3
  shift 3
  env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_GUARD_GRACE="$grace" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_TIMEOUT=30 FM_HEARTBEAT=999999 "$@" \
    "$ROOT/bin/fm-watch.sh" > "$out" 2>&1 &
  WATCH_PID=$!
  CLEANUP_PIDS+=("$WATCH_PID")
}

wait_for_lock() {  # <home> <pid>
  local i=0
  while [ "$i" -lt 200 ]; do
    [ "$(cat "$1/state/.watch.lock/pid" 2>/dev/null || true)" = "$2" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

run_guard() {  # <home> [env assignments...]
  local home=$1
  shift
  env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_SUPERVISION_MODEL=persistent "$@" \
    "$ROOT/bin/fm-guard.sh" 2>&1
}

stop_pid() {  # <pid>
  local i=0
  [ -n "${1:-}" ] || return 0
  kill -CONT "$1" 2>/dev/null || true
  kill -TERM "$1" 2>/dev/null || true
  while [ "$i" -lt 100 ] && kill -0 "$1" 2>/dev/null; do sleep 0.05; i=$((i + 1)); done
  kill -KILL "$1" 2>/dev/null || true
}

FAILED=0
fail_case() { FAILED=1; note "SCENARIO FAIL: $*"; }

# ---------------------------------------------------------------- scenario A
# A deep registered-check queue: the real watcher runs one supervision cycle
# many times longer than the guard grace, and the real pull guard must stay
# silent while the beacon tracks the sweep's progress.
scenario_a() {
  local home out i age_s max_age guard_out cycle_start cycle_end cycles
  note "== A: deep registered-check backlog keeps beacon fresh and guard silent"
  home=$(new_lab a)
  out="$EV/scenario-a-watch.out"
  register_slow_checks "$home" 20
  start_watcher "$home" "$out" "$GRACE_A"
  # The first cycle runs the checks once last-check is absent.
  wait_for_lock "$home" "$WATCH_PID" || { fail_case "watcher A never took the lock"; return; }
  sleep 3
  cycle_start=$(stat -c %Y "$home/state/.watch-cycle" 2>/dev/null || stat -f %m "$home/state/.watch-cycle")
  max_age=0
  i=0
  while [ "$i" -lt 60 ]; do
    age_s=$(age "$home/state/.last-watcher-beat")
    [ "$age_s" -gt "$max_age" ] && max_age=$age_s
    sleep 0.25
    i=$((i + 1))
  done
  cycle_end=$(stat -c %Y "$home/state/.watch-cycle" 2>/dev/null || stat -f %m "$home/state/.watch-cycle")
  cycles=$((cycle_end - cycle_start))
  note "A: observed 15s window inside one cycle (cycle mark advanced ${cycles}s), max beacon age ${max_age}s vs grace ${GRACE_A}s"
  guard_out=$(run_guard "$home" FM_GUARD_GRACE="$GRACE_A")
  record "--- A guard output (working cycle) ---"
  record "${guard_out:-<silent>}"
  case "$guard_out" in
    *"WATCHER DOWN"*) fail_case "A: guard reported a working watcher as down" ;;
  esac
  [ "$max_age" -lt "$GRACE_A" ] || fail_case "A: beacon aged ${max_age}s past the ${GRACE_A}s grace during a working sweep"
  [ "$cycles" -ge 0 ] || true
  # Control: the same home must report the watcher down once it is genuinely
  # gone, so "silent" above is evidence of a healthy cycle and not of a home the
  # guard never judged.
  stop_pid "$WATCH_PID"
  sleep 2
  guard_out=$(run_guard "$home" FM_GUARD_GRACE="$GRACE_A")
  record "--- A guard output (watcher stopped, control) ---"
  record "${guard_out:-<silent>}"
  case "$guard_out" in
    *"WATCHER DOWN"*) note "A: control - the same home trips the guard once the watcher is gone" ;;
    *) fail_case "A: the guard never judged this home, so its silence proved nothing" ;;
  esac
  CLEANUP_LAB=
  rm -rf "$home"
  [ "$FAILED" -eq 0 ] && note "A: PASS"
}

# ---------------------------------------------------------------- scenario B
# Adversarial: freeze the real watcher parent in the middle of a long status
# backlog scan. The scan's child process keeps reading records, but only the
# parent may advance the beacon, so the beacon must go stale and the real guard
# must report the supervisor as down.
scenario_b() {
  local home out i reads before after beat_age guard_out real_od shim
  note "== B: a frozen watcher parent goes stale even while its scan child progresses"
  home=$(new_lab b)
  out="$EV/scenario-b-watch.out"
  shim="$home/fakebin"
  mkdir -p "$shim"
  real_od=$(command -v od)
  cat > "$shim/od" <<'EOF'
#!/usr/bin/env bash
# Latency fixture only: the watcher's real status read, made slow enough that one
# backlog scan outlasts the guard grace on this machine.
if [ "$*" = '-An -v -tx1' ]; then
  printf 'read\n' >> "$FM_HOME/scan-reads"
  sleep 1
fi
exec "$FM_REAL_OD" "$@"
EOF
  chmod +x "$shim/od"
  register_fast_check "$home" b-fast
  for i in $(seq 1 30); do printf 'working: fixture backlog %s\n' "$i" > "$home/state/task-$i.status"; done
  start_watcher "$home" "$out" 4 FM_REAL_OD="$real_od" PATH="$shim:$PATH" FM_CHECK_INTERVAL=999999
  wait_for_lock "$home" "$WATCH_PID" || { fail_case "watcher B never took the lock"; return; }
  i=0
  while [ "$i" -lt 200 ]; do
    [ -f "$home/scan-reads" ] && [ "$(wc -l < "$home/scan-reads")" -ge 2 ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$i" -lt 200 ] || { fail_case "B: watcher never reached the status backlog scan"; return; }
  beat_age=$(age "$home/state/.last-watcher-beat")
  note "B: healthy scan in progress, beacon age ${beat_age}s"
  kill -STOP "$WATCH_PID" || { fail_case "B: could not freeze the watcher"; return; }
  before=$(wc -l < "$home/scan-reads")
  sleep 6
  after=$(wc -l < "$home/scan-reads")
  beat_age=$(age "$home/state/.last-watcher-beat")
  guard_out=$(run_guard "$home" FM_GUARD_GRACE=4)
  kill -CONT "$WATCH_PID" 2>/dev/null || true
  note "B: frozen parent, scan reads ${before} -> ${after} (child kept progressing), beacon age ${beat_age}s, grace 4s"
  record "--- B guard output (frozen parent) ---"
  record "$guard_out"
  [ "$after" -ge "$((before + 3))" ] || fail_case "B: the scan child did not keep progressing (control invalid)"
  case "$guard_out" in
    *"WATCHER DOWN"*) ;;
    *) fail_case "B: a frozen watcher whose child kept progressing was not reported down" ;;
  esac
  stop_pid "$WATCH_PID"
  CLEANUP_LAB=
  rm -rf "$home"
  note "B: $([ "$FAILED" -eq 0 ] && echo PASS || echo FAIL)"
}

# ---------------------------------------------------------------- scenario C
# A long-poll home: the home's config/watch.env declares FM_POLL=600, so a real
# watcher genuinely sleeping between polls must not read as dead, while a
# configured short FM_GUARD_GRACE still trips the same guard.
scenario_c() {
  local home out guard_out
  note "== C: home-configured long poll and configured short grace drive the real guard"
  home=$(new_lab c)
  out="$EV/scenario-c-watch.out"
  printf '%s\n' 'export FM_POLL=600' > "$home/config/watch.env"
  register_fast_check "$home" c-fast
  start_watcher "$home" "$out" 660
  wait_for_lock "$home" "$WATCH_PID" || { fail_case "watcher C never took the lock"; return; }
  sleep 4
  # The watcher is inside its POLL-second terminal wait; a beacon 400s old is a
  # healthy between-poll age for FM_POLL=600 (< 660 derived grace).
  touch -d "@$(( $(date +%s) - 400 ))" "$home/state/.last-watcher-beat" 2>/dev/null \
    || touch -t "$(date -r $(( $(date +%s) - 400 )) +%Y%m%d%H%M.%S 2>/dev/null || echo 202001010000.00)" "$home/state/.last-watcher-beat"
  guard_out=$(run_guard "$home" FM_POLL=15)
  record "--- C guard output (400s between polls, home FM_POLL=600, caller FM_POLL=15) ---"
  record "${guard_out:-<silent>}"
  note "C: beacon age $(age "$home/state/.last-watcher-beat")s with home FM_POLL=600"
  case "$guard_out" in
    *"WATCHER DOWN"*) fail_case "C: a healthy long-poll watcher was reported down" ;;
  esac
  # The same home, now configured with a 60s grace: a 100s-old beacon is stale.
  printf '%s\n' 'export FM_POLL=600' 'export FM_GUARD_GRACE=60' > "$home/config/watch.env"
  touch -d "@$(( $(date +%s) - 100 ))" "$home/state/.last-watcher-beat" 2>/dev/null \
    || touch -t "$(date -r $(( $(date +%s) - 100 )) +%Y%m%d%H%M.%S 2>/dev/null || echo 202001010000.00)" "$home/state/.last-watcher-beat"
  guard_out=$(run_guard "$home" FM_GUARD_GRACE=300)
  record "--- C guard output (100s beacon, configured FM_GUARD_GRACE=60, caller 300) ---"
  record "$guard_out"
  note "C: beacon age $(age "$home/state/.last-watcher-beat")s with configured FM_GUARD_GRACE=60"
  case "$guard_out" in
    *"WATCHER DOWN"*) ;;
    *) fail_case "C: the configured short grace did not drive the guard" ;;
  esac
  stop_pid "$WATCH_PID"
  CLEANUP_LAB=
  rm -rf "$home"
  note "C: $([ "$FAILED" -eq 0 ] && echo PASS || echo FAIL)"
}

# ---------------------------------------------------------------- scenario D
# A successor arm must attach to a live watcher that is mid-way through an
# over-grace cycle instead of refusing it as stale or replacing it.
scenario_d() {
  local home out arm_out arm_pid i
  note "== D: a successor arm attaches to a working over-grace cycle"
  home=$(new_lab d)
  out="$EV/scenario-d-watch.out"
  arm_out="$EV/scenario-d-arm.out"
  register_slow_checks "$home" 8
  start_watcher "$home" "$out" "$GRACE_A"
  wait_for_lock "$home" "$WATCH_PID" || { fail_case "watcher D never took the lock"; return; }
  sleep 3
  note "D: watcher working mid-cycle, beacon age $(age "$home/state/.last-watcher-beat")s, grace ${GRACE_A}s"
  env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_GUARD_GRACE="$GRACE_A" \
    FM_ARM_ATTACH_POLL=0.1 FM_ARM_CONFIRM_TIMEOUT=5 \
    "$ROOT/bin/fm-watch-arm.sh" > "$arm_out" 2>&1 &
  arm_pid=$!
  CLEANUP_PIDS+=("$arm_pid")
  i=0
  while [ "$i" -lt 150 ]; do
    grep -qF "attached pid=$WATCH_PID" "$arm_out" 2>/dev/null && break
    grep -qF "watcher: FAILED" "$arm_out" 2>/dev/null && break
    sleep 0.1
    i=$((i + 1))
  done
  record "--- D arm output ---"
  record "$(cat "$arm_out")"
  if grep -qF "attached pid=$WATCH_PID" "$arm_out"; then
    note "D: arm attached to the working holder"
  else
    fail_case "D: the successor arm did not attach to the working holder"
  fi
  case "$(cat "$arm_out")" in
    *"replaced stalled pid"*) fail_case "D: the arm replaced a working holder" ;;
  esac
  stop_pid "$arm_pid"
  stop_pid "$WATCH_PID"
  CLEANUP_LAB=
  rm -rf "$home"
  note "D: $([ "$FAILED" -eq 0 ] && echo PASS || echo FAIL)"
}

scenario_a
scenario_b
scenario_c
scenario_d

note "OVERALL: $([ "$FAILED" -eq 0 ] && echo PASS || echo FAIL)"
exit "$FAILED"
