#!/usr/bin/env bash
# Manual product-level driver for the watcher-beacon progress change.
# Every scenario runs the real bin/fm-watch.sh, bin/fm-guard.sh,
# bin/fm-watch-arm.sh and bin/fm-rex-marks.sh against a disposable marked lab
# home minted by bin/fm-lab-home.sh. Nothing touches the operator's fleet.
set -u

REPO=${REPO:-$PWD}
LAB=
WATCH_PID=
HOLDER=
declare -a WATCHERS=()

banner() { printf '\n===== %s =====\n' "$*"; }
note() { printf '  %s\n' "$*"; }
die() { printf 'DRIVER FAILURE: %s\n' "$*" >&2; teardown; exit 1; }

teardown() {
  local p
  for p in "${WATCHERS[@]}"; do
    [ -n "$p" ] || continue
    kill -CONT "$p" 2>/dev/null || true
    kill -TERM "$p" 2>/dev/null || true
  done
  for p in "${WATCHERS[@]}"; do
    [ -n "$p" ] || continue
    local i=0
    while [ "$i" -lt 100 ] && kill -0 "$p" 2>/dev/null; do sleep 0.05; i=$((i + 1)); done
    kill -KILL "$p" 2>/dev/null || true
  done
  [ -z "${HOLDER:-}" ] || { kill -KILL "$HOLDER" 2>/dev/null || true; }
  [ -z "${LAB:-}" ] || rm -rf "$LAB"
}

mint_lab() {
  LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || die "mktemp failed"
  "$REPO/bin/fm-lab-home.sh" create "$LAB" >/dev/null || die "could not mint lab home"
  mkdir -p "$LAB/root"
}

age_of() {
  local now m
  now=$(date +%s)
  m=$(stat -c %Y "$1" 2>/dev/null) || m=$(stat -f %m "$1" 2>/dev/null) || { printf '999999'; return; }
  printf '%s' "$((now - m))"
}

backdate() { touch -d "@$(( $(date +%s) - $2 ))" "$1" 2>/dev/null || touch -t "$(date -r $(( $(date +%s) - $2 )) +%Y%m%d%H%M)" "$1"; }

stop_pid() {
  local pid=$1 i=0
  kill -CONT "$pid" 2>/dev/null || true
  kill -TERM "$pid" 2>/dev/null || true
  while [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.05; i=$((i + 1)); done
  kill -KILL "$pid" 2>/dev/null || true
}

# ---------------------------------------------------------------- scenario A
# A live watcher working through a cycle longer than the grace keeps its beacon
# fresh, so the guard stays silent.
scenario_long_cycle_progress() {
  local out=$LAB/watch-A.out i=0 j=0 age max_age=0 elapsed cycles beacon_marks last_mark prev_mark path cyc arm_out=$LAB/arm-A.out arm_pid
  banner "A: live watcher, cycle longer than the 4s grace"
  path="$LAB/state/slow-1.check.sh"
  for cyc in 1 2 3 4 5; do
    printf '#!/usr/bin/env bash\nsleep 2\nexit 0\n' > "$LAB/state/slow-$cyc.check.sh"
    chmod 0700 "$LAB/state/slow-$cyc.check.sh"
    FM_HOME="$LAB" "$REPO/bin/fm-check-register.sh" "slow-$cyc" >/dev/null \
      || die "could not register check slow-$cyc"
  done
  env FM_HOME="$LAB" FM_ROOT_OVERRIDE="$LAB" FM_GUARD_GRACE=4 FM_POLL=1 \
    FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 FM_CHECK_TIMEOUT=30 FM_HEARTBEAT=999999 \
    "$REPO/bin/fm-watch.sh" > "$out" 2>&1 &
  WATCH_PID=$!
  WATCHERS+=("$WATCH_PID")
  while [ "$i" -lt 100 ]; do
    [ "$(cat "$LAB/state/.watch.lock/pid" 2>/dev/null || true)" = "$WATCH_PID" ] \
      && [ -e "$LAB/state/.last-watcher-beat" ] && break
    sleep 0.1; i=$((i + 1))
  done
  [ -e "$LAB/state/.last-watcher-beat" ] || die "watcher never took the lock: $(cat "$out")"

  beacon_marks=0 prev_mark= cycle_marks=0 prev_cyc=
  local start=$SECONDS
  i=0
  while [ "$i" -lt 100 ]; do          # ~20s
    age=$(age_of "$LAB/state/.last-watcher-beat")
    [ "$age" -le "$max_age" ] || max_age=$age
    last_mark=$(stat -c %Y "$LAB/state/.last-watcher-beat" 2>/dev/null || stat -f %m "$LAB/state/.last-watcher-beat")
    [ "$last_mark" = "$prev_mark" ] || { beacon_marks=$((beacon_marks + 1)); prev_mark=$last_mark; }
    last_mark=$(stat -c %Y "$LAB/state/.watch-cycle" 2>/dev/null || stat -f %m "$LAB/state/.watch-cycle" 2>/dev/null || echo none)
    [ "$last_mark" = "$prev_cyc" ] || { cycle_marks=$((cycle_marks + 1)); prev_cyc=$last_mark; }
    sleep 0.2; i=$((i + 1))
  done
  elapsed=$((SECONDS - start))
  cycles=$(find "$LAB/state" -maxdepth 1 -name '.watch-cycle' -newermt "@$(( $(date +%s) - elapsed ))" 2>/dev/null | wc -l)
  note "elapsed=${elapsed}s max_beacon_age=${max_age}s beacon_writes=${beacon_marks} completed_cycles=${cycle_marks} (5x2s checks per sweep)"
  note "cycle_marker=$([ -e "$LAB/state/.watch-cycle" ] && echo present || echo absent)"
  [ "$cycle_marks" -le 4 ] || die "fixture cycle was not long: ${cycle_marks} cycles in ${elapsed}s"
  [ "$beacon_marks" -gt "$cycle_marks" ] || die "beacon did not refresh between units inside a cycle"
  note "progress_marker=$([ -e "$LAB/state/.last-watcher-progress" ] && echo present || echo absent)"
  [ "$max_age" -lt 4 ] || die "working cycle aged the beacon ${max_age}s past the 4s grace"
  printf '  guard output (expected none):\n'
  env FM_ROOT_OVERRIDE="$LAB/root" FM_HOME="$LAB" FM_GUARD_GRACE=4 \
    FM_SUPERVISION_MODEL=persistent "$REPO/bin/fm-guard.sh" 2>&1 | sed 's/^/    /'
  guard_rc=${PIPESTATUS[0]}
  note "guard exit=$guard_rc"
  # The successor arm must attach to this working cycle, not refuse or replace it.
  env FM_HOME="$LAB" FM_GUARD_GRACE=4 FM_ARM_ATTACH_POLL=0.1 FM_ARM_CONFIRM_TIMEOUT=5 \
    "$REPO/bin/fm-watch-arm.sh" > "$arm_out" 2>&1 &
  arm_pid=$!
  while [ "$j" -lt 120 ]; do
    grep -qF "watcher: attached pid=$WATCH_PID" "$arm_out" 2>/dev/null && break
    grep -qF "watcher: FAILED" "$arm_out" 2>/dev/null && break
    sleep 0.1; j=$((j + 1))
  done
  stop_pid "$arm_pid"
  printf '  successor arm output:\n'
  sed -n '1,6p' "$arm_out" | sed 's/^/    /'
  grep -qF "watcher: attached pid=$WATCH_PID" "$arm_out" \
    || die "a successor could not attach to the working cycle: $(cat "$arm_out")"
  note "successor arm attached to the live working cycle instead of replacing it"
  stop_pid "$WATCH_PID"; WATCHERS=()
  WATCH_PID=
}

# ---------------------------------------------------------------- scenario B
# A holder that stops progressing still raises the banner and is still evicted
# past the hard bound.
scenario_stalled_holder() {
  local identity out
  banner "B: stalled holder still alarms and is still evicted past the hard bound"
  FM_HOME="$LAB" sleep 300 &
  HOLDER=$!
  identity=$(bash -c '. "$1"; fm_pid_identity "$2"' _ "$REPO/bin/fm-wake-lib.sh" "$HOLDER") \
    || die "could not compute holder identity"
  mkdir -p "$LAB/state/.watch.lock"
  printf '%s\n' "$HOLDER" > "$LAB/state/.watch.lock/pid"
  printf '%s\n' "$LAB" > "$LAB/state/.watch.lock/fm-home"
  printf '%s\n' "$REPO/bin/fm-watch.sh" > "$LAB/state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$LAB/state/.watch.lock/pid-identity"
  printf 'kind=ship\n' > "$LAB/state/task.meta"
  : > "$LAB/state/.last-watcher-beat"
  backdate "$LAB/state/.last-watcher-beat" 20
  note "beacon age=$(age_of "$LAB/state/.last-watcher-beat")s, explicit grace 7s"
  out=$(env FM_ROOT_OVERRIDE="$LAB/root" FM_HOME="$LAB" FM_GUARD_GRACE=7 \
    FM_SUPERVISION_MODEL=persistent "$REPO/bin/fm-guard.sh" 2>&1)
  printf '%s\n' "$out" | sed -n '1,12p;/WATCHER DOWN/p' | sed 's/^/    /'
  case "$out" in *"WATCHER DOWN"*) note "banner fired" ;; *) die "stalled holder raised no banner: $out" ;; esac
  case "$out" in *"grace 7s"*) note "banner names the explicit 7s grace" ;; *) die "banner did not name the explicit grace: $out" ;; esac
  # An explicit 60s hard bound still keeps the merely-slow holder in place.
  out=$(env FM_HOME="$LAB" FM_GUARD_GRACE=7 FM_WATCHER_STALL_BOUND=60 \
    FM_ARM_CONFIRM_TIMEOUT=5 "$REPO/bin/fm-watch-arm.sh" 2>&1) || true
  kill -0 "$HOLDER" 2>/dev/null || die "a holder inside the 60s hard bound was killed"
  case "$out" in *"replaced stalled pid"*) die "holder inside the hard bound was replaced" ;; esac
  note "holder kept inside an explicit 60s hard bound"
  # Past a 5s hard bound the same holder must be evicted and replaced.
  backdate "$LAB/state/.last-watcher-beat" 30
  out=$(env FM_HOME="$LAB" FM_GUARD_GRACE=7 FM_WATCHER_STALL_BOUND=5 \
    FM_ARM_CONFIRM_TIMEOUT=5 "$REPO/bin/fm-watch-arm.sh" 2>&1) || true
  case "$out" in
    *"replaced stalled pid $HOLDER"*) note "evicted: $(printf '%s\n' "$out" | grep -m1 'replaced stalled pid')" ;;
    *) die "stalled holder past the hard bound was not evicted: $out" ;;
  esac
  local leaked
  leaked=$(cat "$LAB/state/.watch.lock/pid" 2>/dev/null || true)
  [ -n "$leaked" ] && stop_pid "$leaked"
  kill -KILL "$HOLDER" 2>/dev/null || true
  HOLDER=
}

# ---------------------------------------------------------------- scenario C
# A home's own configured cadence governs readers that never sourced it, and an
# explicit FM_GUARD_GRACE still wins.
scenario_home_cadence() {
  local out
  banner "C: home config/watch.env cadence (FM_POLL=600) governs the guard without being sourced by it"
  FM_HOME="$LAB" sleep 300 &
  HOLDER=$!
  local identity
  identity=$(bash -c '. "$1"; fm_pid_identity "$2"' _ "$REPO/bin/fm-wake-lib.sh" "$HOLDER") \
    || die "could not compute holder identity"
  mkdir -p "$LAB/state/.watch.lock"
  printf '%s\n' "$HOLDER" > "$LAB/state/.watch.lock/pid"
  printf '%s\n' "$LAB" > "$LAB/state/.watch.lock/fm-home"
  printf '%s\n' "$REPO/bin/fm-watch.sh" > "$LAB/state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$LAB/state/.watch.lock/pid-identity"
  printf 'kind=ship\n' > "$LAB/state/task.meta"
  printf 'export FM_POLL=600\n' > "$LAB/config/watch.env"
  backdate "$LAB/state/.last-watcher-beat" 320
  out=$(env FM_ROOT_OVERRIDE="$LAB/root" FM_HOME="$LAB" FM_SUPERVISION_MODEL=persistent \
    "$REPO/bin/fm-guard.sh" 2>&1)
  [ -z "$out" ] || die "a 320s beacon was read stale under the home's 600s poll: $out"
  note "320s-old beacon read fresh under config/watch.env FM_POLL=600"
  printf '%s\n' 'export FM_GUARD_GRACE=1200' >> "$LAB/config/watch.env"
  backdate "$LAB/state/.last-watcher-beat" 700
  out=$(env FM_ROOT_OVERRIDE="$LAB/root" FM_HOME="$LAB" FM_GUARD_GRACE=300 FM_SUPERVISION_MODEL=persistent \
    "$REPO/bin/fm-guard.sh" 2>&1)
  [ -z "$out" ] || die "configured grace 1200 did not override a 300 reader env: $out"
  note "configured FM_GUARD_GRACE=1200 beats a 300 reader environment at 700s beacon age"
  printf '%s\n' 'export FM_POLL=600' 'export FM_GUARD_GRACE=60' > "$LAB/config/watch.env"
  backdate "$LAB/state/.last-watcher-beat" 100
  out=$(env FM_ROOT_OVERRIDE="$LAB/root" FM_HOME="$LAB" FM_SUPERVISION_MODEL=persistent \
    "$REPO/bin/fm-guard.sh" 2>&1)
  case "$out" in *"WATCHER DOWN"*) note "configured 60s grace at 100s beacon age raised the banner" ;;
    *) die "configured short grace was replaced by the long-poll default: $out" ;; esac
  # Standalone supervision library: source it and call the predicate with no grace.
  out=$(env FM_HOME="$LAB" bash -c '
    . "$1/bin/fm-supervision-lib.sh"
    fm_supervision_status "$FM_HOME/state"
    printf "fresh=%s desc=%s\n" "$FM_SUP_WATCHER_FRESH" "$FM_SUP_BEACON_DESC"
  ' _ "$REPO" 2>&1)
  printf '%s\n' "$out" | sed 's/^/    /'
  case "$out" in
    *"command not found"*) die "standalone supervision lib could not resolve the shared grace: $out" ;;
    *"fresh=false"*) note "standalone fm_supervision_status applied the configured 60s grace" ;;
    *) die "standalone supervision did not judge the beacon stale: $out" ;;
  esac
  # Relay cadence still supersedes the home long poll.
  printf '%s\n' 'export FM_POLL=600' > "$LAB/config/watch.env"
  printf '%s\n' 'export FM_POLL=15' > "$LAB/config/x-mode.env"
  backdate "$LAB/state/.last-watcher-beat" 320
  out=$(env FM_ROOT_OVERRIDE="$LAB/root" FM_HOME="$LAB" FM_SUPERVISION_MODEL=persistent \
    "$REPO/bin/fm-guard.sh" 2>&1)
  case "$out" in
    *"WATCHER DOWN"*|*"watcher still down"*) note "Relay's 15s cadence superseded the home's 600s poll" ;;
    *) die "Relay cadence did not supersede the home poll: $out" ;;
  esac
  rm -f "$LAB/config/x-mode.env" "$LAB/config/watch.env"
  kill -KILL "$HOLDER" 2>/dev/null || true
  HOLDER=
}

# ---------------------------------------------------------------- scenario D
# A watcher frozen mid display sweep: the display child keeps working, but the
# beacon must age and the guard must fire.
scenario_frozen_display_sweep() {
  local out=$LAB/watch-D.out i before after age
  banner "D: SIGSTOP the watcher during a Rex display sweep"
  rm -f "$LAB/state/.guard-watcher-stale-banner"
  printf 'subtle\n' > "$LAB/config/rex-tint"
  printf 'on\n' > "$LAB/config/rex-status-marks"
  mkdir -p "$LAB/fakebin" "$LAB/task-worktree"
  cat > "$LAB/fakebin/no-mistakes" <<'EOF'
#!/usr/bin/env bash
[ "$*" = 'axi status' ] || exit 1
printf '%s\n' "$PWD" >> "$FM_HOME/display-reads"
sleep 1
EOF
  chmod +x "$LAB/fakebin/no-mistakes"
  for i in $(seq 1 20); do
    printf '%s\n' kind=ship backend=rex "window=session:fixture/block:$i" \
      mode=no-mistakes "worktree=$LAB/task-worktree" branch=fixture > "$LAB/state/task-$i.meta"
  done
  PATH="$LAB/fakebin:$PATH" env FM_HOME="$LAB" FM_ROOT_OVERRIDE="$LAB" FM_GUARD_GRACE=4 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 FM_CHECK_TIMEOUT=30 FM_HEARTBEAT=999999 \
    "$REPO/bin/fm-watch.sh" > "$out" 2>&1 &
  WATCH_PID=$!
  WATCHERS+=("$WATCH_PID")
  i=0
  while [ "$i" -lt 150 ]; do
    [ -f "$LAB/display-reads" ] && [ "$(wc -l < "$LAB/display-reads")" -ge 2 ] && break
    sleep 0.1; i=$((i + 1))
  done
  [ "$i" -lt 150 ] || die "display sweep never processed two tasks: $(cat "$out")"
  before=$(wc -l < "$LAB/display-reads")
  note "display child had processed ${before} tasks before the freeze"
  kill -STOP "$WATCH_PID" || die "could not SIGSTOP watcher"
  sleep 5
  after=$(wc -l < "$LAB/display-reads")
  age=$(age_of "$LAB/state/.last-watcher-beat")
  note "display child processed through ${after} tasks while the watcher was frozen"
  note "beacon age while frozen=${age}s (grace 4s), progress marker=$([ -e "$LAB/state/.last-watcher-progress" ] && echo present || echo absent)"
  out2=$(env FM_ROOT_OVERRIDE="$LAB/root" FM_HOME="$LAB" FM_GUARD_GRACE=4 \
    FM_SUPERVISION_MODEL=persistent "$REPO/bin/fm-guard.sh" 2>&1)
  kill -CONT "$WATCH_PID" 2>/dev/null || true
  [ "$after" -ge "$((before + 3))" ] || die "display child stopped progressing while the watcher was frozen"
  [ "$age" -gt 4 ] || die "a frozen watcher's beacon was kept fresh by the display child"
  case "$out2" in *"WATCHER DOWN"*|*"watcher still down"*) note "guard fired: $(printf '%s\n' "$out2" | grep -m1 'WATCHER DOWN')" ;;
    *) die "a frozen watcher during a display sweep did not trip the guard: $out2" ;; esac
  stop_pid "$WATCH_PID"
  WATCH_PID=
}

# ---------------------------------------------------------------- scenario E
# A display sweep run outside a watcher invents no liveness evidence.
scenario_oneshot_display_is_inert() {
  local before
  banner "E: one-shot display sweep outside a watcher creates no liveness evidence"
  rm -f "$LAB/state/.last-watcher-beat" "$LAB/state/.last-watcher-progress"
  PATH="$LAB/fakebin:$PATH" env FM_HOME="$LAB" FM_STATE_OVERRIDE="$LAB/state" \
    FM_CONFIG_OVERRIDE="$LAB/config" "$REPO/bin/fm-rex-marks.sh" sync >/dev/null 2>&1 || true
  note "beacon after one-shot sync: $([ -e "$LAB/state/.last-watcher-beat" ] && echo present || echo absent)"
  note "progress marker after one-shot sync: $([ -e "$LAB/state/.last-watcher-progress" ] && echo present || echo absent)"
  [ ! -e "$LAB/state/.last-watcher-beat" ] \
    || die "a display sweep outside a watcher created a beacon"
}

# ---------------------------------------------------------------- scenario F
# A live watcher running a long Rex display sweep keeps its beacon fresh, which
# is the progress-marker -> beacon propagation the frozen case must not break.
scenario_live_display_sweep_progress() {
  local out=$LAB/watch-F.out i age max_age=0 reads progress_marks=0 prev= last
  banner "F: live watcher during a long Rex display sweep stays fresh"
  rm -f "$LAB/state/.guard-watcher-stale-banner" "$LAB/display-reads" "$LAB/state/.last-watcher-progress"
  PATH="$LAB/fakebin:$PATH" env FM_HOME="$LAB" FM_ROOT_OVERRIDE="$LAB" FM_GUARD_GRACE=4 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_CHECK_TIMEOUT=30 FM_HEARTBEAT=999999 \
    "$REPO/bin/fm-watch.sh" > "$out" 2>&1 &
  WATCH_PID=$!
  WATCHERS+=("$WATCH_PID")
  i=0
  while [ "$i" -lt 150 ]; do
    [ "$(cat "$LAB/state/.watch.lock/pid" 2>/dev/null || true)" = "$WATCH_PID" ] \
      && [ -f "$LAB/display-reads" ] && [ "$(wc -l < "$LAB/display-reads")" -ge 2 ] && break
    sleep 0.1; i=$((i + 1))
  done
  [ "$i" -lt 150 ] || die "display sweep never started: $(cat "$out")"
  i=0
  while [ "$i" -lt 60 ]; do            # ~12s, well past the 4s grace
    age=$(age_of "$LAB/state/.last-watcher-beat")
    [ "$age" -le "$max_age" ] || max_age=$age
    last=$(stat -c %Y "$LAB/state/.last-watcher-progress" 2>/dev/null || true)
    [ -z "$last" ] || [ "$last" = "$prev" ] || { progress_marks=$((progress_marks + 1)); prev=$last; }
    sleep 0.2; i=$((i + 1))
  done
  reads=$(wc -l < "$LAB/display-reads")
  note "display child processed ${reads} tasks over the sample window"
  note "max_beacon_age=${max_age}s (grace 4s), progress_marker_writes=${progress_marks}"
  local guard_out
  guard_out=$(env FM_ROOT_OVERRIDE="$LAB/root" FM_HOME="$LAB" FM_GUARD_GRACE=4 \
    FM_SUPERVISION_MODEL=persistent "$REPO/bin/fm-guard.sh" 2>&1)
  stop_pid "$WATCH_PID"; WATCH_PID=; WATCHERS=()
  [ "$reads" -ge 5 ] || die "display sweep did not process enough tasks"
  [ "$progress_marks" -ge 2 ] || die "child sweeps wrote no progress marker"
  [ "$max_age" -lt 4 ] || die "a live watcher's display sweep aged the beacon to ${max_age}s"
  [ -z "$guard_out" ] || die "a live watcher mid display sweep raised an alarm: $guard_out"
  note "guard stayed silent while the display sweep ran"
}

trap teardown EXIT
mint_lab
printf 'repo=%s\nlab=%s\n' "$REPO" "$LAB"
scenario_long_cycle_progress
scenario_stalled_holder
scenario_home_cadence
scenario_frozen_display_sweep
scenario_live_display_sweep_progress
scenario_oneshot_display_is_inert
banner "ALL MANUAL SCENARIOS PASSED"
