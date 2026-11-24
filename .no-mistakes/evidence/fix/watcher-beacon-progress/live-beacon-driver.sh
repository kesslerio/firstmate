#!/usr/bin/env bash
# Live driver for the watcher beacon-progress change. Runs the real
# bin/fm-watch.sh, bin/fm-guard.sh, bin/fm-watch-arm.sh and one-shot helpers in
# disposable FM_HOME labs, and additionally replays the same scenario against an
# extracted copy of the base commit as a negative control.
#
# Independent oracle: docs/turnend-guard.md ("Current invariant", "Cycle
# progress keeps the beacon fresh") states a live watcher making progress keeps
# its beacon inside the configured grace while a watcher that stops progressing
# ages, and states the grace derivation is max(300, FM_POLL + 60) with
# FM_GUARD_GRACE winning. A wrong behavior this driver rejects: beacon age
# tracking whole-cycle length (base behavior), or descendants refreshing a
# frozen parent's beacon, or a one-shot helper inventing liveness.
set -u

WT=$1
BASE_TREE=$2
LAB=$3
EVID=$4

REAL_OD=$(command -v od || true)
FAILED=0
BGPID=

note() { printf '\n=== %s ===\n' "$*"; }
ok() { printf 'PASS: %s\n' "$*"; }
bad() { printf 'FAIL: %s\n' "$*"; FAILED=1; }

stop_pid() {
  local pid=$1 i=0
  [ -n "$pid" ] || return 0
  kill -CONT "$pid" 2>/dev/null || true
  kill -TERM "$pid" 2>/dev/null || return 0
  while [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.05
    i=$((i + 1))
  done
  kill -KILL "$pid" 2>/dev/null || true
}

age_of() {
  local now m
  now=$(date +%s)
  m=$(stat -c %Y "$1" 2>/dev/null) || { printf '999999\n'; return 0; }
  printf '%s\n' "$((now - m))"
}

backdate() { local secs=$2; touch -d "@$(( $(date +%s) - secs ))" "$1" 2>/dev/null || true; }

make_home() {  # <name> -> echoes home
  local dir=$LAB/$1/home
  mkdir -p "$dir/state" "$dir/config" "$dir/data" "$LAB/$1/root"
  printf '%s\n' "$dir"
}

register_checks() {  # <tree> <home> <count>
  local tree=$1 home=$2 count=$3 i=0
  while [ "$i" -lt "$count" ]; do
    i=$((i + 1))
    printf '%s\n' '#!/usr/bin/env bash' 'sleep 2' 'exit 0' > "$home/state/slow-$i.check.sh"
    chmod 0700 "$home/state/slow-$i.check.sh"
    FM_HOME="$home" "$tree/bin/fm-check-register.sh" "slow-$i" >/dev/null || return 1
  done
}

start_watcher() {  # <tree> <home> <out> <grace> [path-prefix]
  local tree=$1 home=$2 out=$3 grace=$4 pathpfx=${5:-} i=0 pid
  if [ -n "$pathpfx" ]; then
    PATH="$pathpfx:$PATH" FM_HOME="$home" FM_POLL=1 FM_GUARD_GRACE="$grace" FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=1 FM_CHECK_TIMEOUT=30 FM_HEARTBEAT=999999 \
      "$tree/bin/fm-watch.sh" > "$out" 2>&1 &
  else
    FM_HOME="$home" FM_POLL=1 FM_GUARD_GRACE="$grace" FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=1 FM_CHECK_TIMEOUT=30 FM_HEARTBEAT=999999 \
      "$tree/bin/fm-watch.sh" > "$out" 2>&1 &
  fi
  pid=$!
  while [ "$i" -lt 150 ]; do
    [ "$(cat "$home/state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] \
      && [ -e "$home/state/.last-watcher-beat" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  printf '%s\n' "$pid"
}

run_guard() {  # <root> <home> [env...]
  local root=$1 home=$2
  shift 2
  env FM_ROOT_OVERRIDE="$root" FM_HOME="$home" FM_SUPERVISION_MODEL=persistent "$@" \
    "$WT/bin/fm-guard.sh" 2>&1
}

# ---------------------------------------------------------------- Scenario 1
# A healthy cycle whose check sweep runs well past the grace keeps the beacon
# fresh and the guard silent.
long_sweep_case() {  # <tree> <label> <grace>
  local tree=$1 label=$2 grace=$3 dir home out pid i age max_age=0 guard_out
  dir=$LAB/"$label"
  home=$(make_home "$label")
  out=$dir/watch.out
  mkdir -p "$home/state"
  printf '%s\n' 'kind=ship' 'backend=none' > "$home/state/task-1.meta"
  register_checks "$tree" "$home" 5 || { bad "$label: could not register checks"; return 1; }
  pid=$(start_watcher "$tree" "$home" "$out" "$grace")
  guard_out=$(run_guard "$dir/root" "$home" FM_GUARD_GRACE="$grace")
  i=0
  while [ "$i" -lt 70 ]; do
    age=$(age_of "$home/state/.last-watcher-beat")
    [ "$age" -le "$max_age" ] || max_age=$age
    sleep 0.2
    i=$((i + 1))
  done
  stop_pid "$pid"
  printf '%s: grace=%ss observed max beacon age=%ss guard=[%s]\n' \
    "$label" "$grace" "$max_age" "$(printf '%s' "$guard_out" | head -2 | tr '\n' ' ')"
  if [ "$max_age" -ge "$grace" ]; then
    return 1
  fi
  case "$guard_out" in
    *"WATCHER DOWN"*) return 1 ;;
  esac
  return 0
}

note "Scenario 1: live watcher mid slow check sweep keeps the beacon inside a 4s grace"
if long_sweep_case "$WT" fixed 4; then
  ok "fixed tree: beacon stayed fresh through a ~10s check sweep and the guard stayed silent"
else
  bad "fixed tree: beacon aged past the grace or the guard raised the watcher-down banner"
fi
if [ -n "$BASE_TREE" ] && [ -x "$BASE_TREE/bin/fm-watch.sh" ]; then
  note "Scenario 1 negative control: same sweep on the base commit (beacon only at cycle top)"
  if long_sweep_case "$BASE_TREE" base 4; then
    printf 'NOTE: base tree unexpectedly kept the beacon fresh; scenario may not discriminate\n'
  else
    ok "base tree reproduced the reported failure (stale beacon + watcher-down banner), fixed tree passes"
  fi
fi

# ---------------------------------------------------------------- Scenario 2
# SIGSTOP the watcher while its Rex display-sweep child keeps working: the
# child must not keep the frozen parent's beacon fresh, and the guard must fire.
note "Scenario 2: watcher SIGSTOPped during an active display sweep trips the guard"
dir=$LAB/frozen; mkdir -p "$dir/fakebin" "$dir/task-worktree"
home=$(make_home frozen)
printf 'subtle\n' > "$home/config/rex-tint"
printf 'on\n' > "$home/config/rex-status-marks"
cat > "$dir/fakebin/no-mistakes" <<'EOF'
#!/usr/bin/env bash
[ "$*" = 'axi status' ] || exit 1
printf '%s\n' "$PWD" >> "$FM_HOME/display-reads"
sleep 1 &
printf '%s %s\n' "$$" "$!" >> "$FM_HOME/display-pids"
wait
EOF
chmod +x "$dir/fakebin/no-mistakes"
for i in $(seq 1 20); do
  printf 'kind=ship\nbackend=rex\nwindow=session:fixture/block:%s\nmode=no-mistakes\nworktree=%s\nbranch=fixture\n' \
    "$i" "$dir/task-worktree" > "$home/state/task-$i.meta"
done
pid=$(start_watcher "$WT" "$home" "$dir/watch.out" 4 "$dir/fakebin")
i=0
while [ "$i" -lt 150 ]; do
  [ -f "$home/display-reads" ] && [ "$(wc -l < "$home/display-reads")" -ge 2 ] && break
  sleep 0.1
  i=$((i + 1))
done
if [ "$i" -ge 150 ]; then
  bad "display sweep never processed two tasks: $(cat "$dir/watch.out")"
else
  before=$(wc -l < "$home/display-reads")
  kill -STOP "$pid" || bad "could not SIGSTOP watcher $pid"
  sleep 5
  after=$(wc -l < "$home/display-reads")
  frozen_age=$(age_of "$home/state/.last-watcher-beat")
  guard_out=$(run_guard "$dir/root" "$home" FM_GUARD_GRACE=4)
  printf 'display reads before=%s after=%s; frozen beacon age=%ss; guard=[%s]\n' \
    "$before" "$after" "$frozen_age" "$(printf '%s' "$guard_out" | head -2 | tr '\n' ' ')"
  live_children=0
  [ -f "$home/display-pids" ] && while read -r p c; do
    kill -0 "$p" 2>/dev/null && live_children=$((live_children + 1))
  done < "$home/display-pids"
  stop_pid "$pid"
  sleep 0.5
  leftover=0
  [ -f "$home/display-pids" ] && while read -r p c; do
    kill -0 "$p" 2>/dev/null && leftover=$((leftover + 1))
    kill -0 "$c" 2>/dev/null && leftover=$((leftover + 1))
  done < "$home/display-pids"
  lock_after=$([ -e "$home/state/.watch.lock/pid" ] && echo held || echo released)
  printf 'display children while frozen=%s; leftover after TERM=%s; lock=%s\n' \
    "$live_children" "$leftover" "$lock_after"
  if [ "$after" -lt "$((before + 3))" ]; then
    bad "display sweep child did not continue while the parent was frozen"
  elif [ "$frozen_age" -le 4 ]; then
    bad "descendant activity kept a frozen watcher's beacon fresh"
  elif ! printf '%s' "$guard_out" | grep -q "WATCHER DOWN"; then
    bad "guard did not report a frozen watcher as down"
  elif [ "$leftover" -ne 0 ]; then
    bad "display-sweep children outlived the stopped watcher"
  elif [ "$lock_after" != released ]; then
    bad "watcher lock was not released after TERM"
  else
    ok "child kept working, beacon aged past grace, guard fired, children cleaned up and lock released"
  fi
fi

# ---------------------------------------------------------------- Scenario 3
# A genuinely stalled holder still raises the banner and is replaced past the
# hard bound - the fix must not make every beacon look fresh.
note "Scenario 3: stalled holder still banners and is evicted past the hard bound"
dir=$LAB/stalled; mkdir -p "$dir/root"
# The arm refuses a disposable validation checkout unless it drives a marked
# stock-layout lab home (bin/fm-gate-refuse-lib.sh). Mint one so this scenario
# exercises the real arm without any bypass.
home=$LAB/armlab
"$WT/bin/fm-lab-home.sh" create "$home" >/dev/null || bad "could not mint a lab home"
printf '%s\n' 'kind=ship' > "$home/state/task.meta"
sleep 300 &
holder=$!
identity=$("$WT/bin/fm-pid-identity.sh" "$holder" 2>/dev/null || true)
if [ -z "$identity" ]; then
  identity=$(bash -c '. "$1"; fm_pid_identity "$2"' _ "$WT/bin/fm-wake-lib.sh" "$holder")
fi
mkdir -p "$home/state/.watch.lock"
printf '%s\n' "$holder" > "$home/state/.watch.lock/pid"
printf '%s\n' "$home" > "$home/state/.watch.lock/fm-home"
printf '%s\n' "$WT/bin/fm-watch.sh" > "$home/state/.watch.lock/watcher-path"
printf '%s\n' "$identity" > "$home/state/.watch.lock/pid-identity"
: > "$home/state/.last-watcher-beat"
backdate "$home/state/.last-watcher-beat" 20
guard_out=$(run_guard "$dir/root" "$home" FM_GUARD_GRACE=7)
printf 'guard at 20s-stale beacon, grace 7s: %s\n' "$(printf '%s' "$guard_out" | head -2 | tr '\n' ' ')"
if ! printf '%s' "$guard_out" | grep -q "WATCHER DOWN"; then
  bad "stalled beacon no longer trips the banner"
fi
backdate "$home/state/.last-watcher-beat" 30
env FM_HOME="$home" FM_GUARD_GRACE=7 FM_WATCHER_STALL_BOUND=5 FM_ARM_CONFIRM_TIMEOUT=5 \
  FM_ARM_ATTACH_POLL=0.1 "$WT/bin/fm-watch-arm.sh" > "$dir/arm.out" 2>&1 &
BGPID=$!
i=0
while [ "$i" -lt 200 ]; do
  grep -qF "replaced stalled pid $holder" "$dir/arm.out" 2>/dev/null && break
  grep -qF "watcher: FAILED" "$dir/arm.out" 2>/dev/null && break
  sleep 0.1
  i=$((i + 1))
done
stop_pid "$BGPID"
BGPID=
new_holder=$(cat "$home/state/.watch.lock/pid" 2>/dev/null || true)
[ -n "$new_holder" ] && stop_pid "$new_holder"
printf 'arm output: %s\n' "$(tr '\n' ' ' < "$dir/arm.out" | cut -c1-300)"
if ! printf '%s' "$guard_out" | grep -q "WATCHER DOWN"; then
  bad "stalled beacon did not raise the banner"
elif ! grep -qF "replaced stalled pid $holder" "$dir/arm.out"; then
  bad "arm did not replace the holder past the hard bound"
elif kill -0 "$holder" 2>/dev/null; then
  bad "evicted holder still alive"
else
  ok "banner fired for the stalled beacon and the arm replaced the holder past the hard bound"
fi
stop_pid "$holder"

# ---------------------------------------------------------------- Scenario 4
# Home-configured cadence governs the readers: a long poll makes a 320s-old
# beacon fresh; an explicit short config grace makes the same beacon stale.
note "Scenario 4: home config cadence governs beacon readers"
dir=$LAB/cadence; mkdir -p "$dir"
home=$(make_home cadence)
printf '%s\n' 'kind=ship' > "$home/state/task.meta"
sleep 300 &
holder=$!
identity=$(bash -c '. "$1"; fm_pid_identity "$2"' _ "$WT/bin/fm-wake-lib.sh" "$holder")
mkdir -p "$home/state/.watch.lock"
printf '%s\n' "$holder" > "$home/state/.watch.lock/pid"
printf '%s\n' "$home" > "$home/state/.watch.lock/fm-home"
printf '%s\n' "$WT/bin/fm-watch.sh" > "$home/state/.watch.lock/watcher-path"
printf '%s\n' "$identity" > "$home/state/.watch.lock/pid-identity"
: > "$home/state/.last-watcher-beat"
backdate "$home/state/.last-watcher-beat" 320
printf 'export FM_POLL=600\n' > "$home/config/watch.env"
long_out=$(run_guard "$dir/root" "$home")
printf 'FM_POLL=600 home, 320s beacon, no explicit grace: %s\n' "$(printf '%s' "$long_out" | head -2 | tr '\n' ' ')"
printf 'export FM_POLL=600\nexport FM_GUARD_GRACE=60\n' > "$home/config/watch.env"
short_out=$(run_guard "$dir/root" "$home")
printf 'FM_POLL=600 + FM_GUARD_GRACE=60 home, same beacon: %s\n' "$(printf '%s' "$short_out" | head -2 | tr '\n' ' ')"
stop_pid "$holder"
if printf '%s' "$long_out" | grep -q "WATCHER DOWN"; then
  bad "home-configured long poll still read a 320s beacon as down"
elif ! printf '%s' "$short_out" | grep -q "WATCHER DOWN"; then
  bad "home-configured short grace did not make the same beacon stale"
else
  ok "home config poll raised the grace, and its explicit grace override lowered it"
fi

# ---------------------------------------------------------------- Scenario 5
# One-shot helpers stay inert: the rex marks sync used outside a watcher never
# invents liveness, while the same command proves the progress hook is on its
# executed path when a watcher-scoped marker is provided.
note "Scenario 5: one-shot display helper cannot refresh a stale beacon outside a watcher"
dir=$LAB/oneshot; mkdir -p "$dir"
home=$(make_home oneshot)
printf '%s\n' 'kind=ship' 'backend=rex' 'window=session:fixture/block:1' > "$home/state/task-1.meta"
printf '%s\n' 'working: fixture' > "$home/state/task-1.status"
beat=$home/state/.last-watcher-beat
progress=$home/state/.last-watcher-progress
: > "$beat"
backdate "$beat" 50
backdate_progress_before=$([ -e "$progress" ] && age_of "$progress" || echo none)
probe=$(FM_HOME="$home" FM_WATCH_BEACON_PATH="$beat" FM_WATCH_PROGRESS_PATH="$progress" \
  FM_WATCHER_PID=1 "$WT/bin/fm-rex-marks.sh" sync 2>&1; echo "rc=$?")
probe_age=$(age_of "$progress")
plan=$(FM_HOME="$home" "$WT/bin/fm-rex-marks.sh" plan 2>&1)
realrun=$(env -u FM_WATCH_BEACON_PATH -u FM_WATCH_PROGRESS_PATH -u FM_WATCHER_PID \
  FM_HOME="$home" "$WT/bin/fm-rex-marks.sh" sync 2>&1; echo "rc=$?")
after=$(age_of "$beat")
printf 'plan=[%s]\nprobe run rc/progress marker age=%s (was %s)\nreal one-shot rc=...; beacon age before=50 after=%s\n' \
  "$(printf '%s' "$plan" | tr '\n' ' ')" "$probe_age" "$backdate_progress_before" "$after"
printf 'one-shot output tail: %s\n' "$(printf '%s' "$realrun" | tail -1)"
if ! printf '%s' "$plan" | grep -q "task-1"; then
  bad "one-shot helper collected no rex task, so the inertness check would be vacuous"
elif [ "$probe_age" = 999999 ] || [ "$probe_age" -gt 1 ]; then
  bad "watcher-scoped run did not write the child progress marker, so the hook path is unproven"
elif [ "$after" -lt 50 ]; then
  bad "a one-shot helper refreshed the watcher beacon"
else
  ok "sync reached the progress hook but left the stale beacon untouched outside a watcher"
fi

# ---------------------------------------------------------------- Scenario 6
# A watcher stopped mid-sweep leaves no owned child behind and frees the lock,
# so a successor can take over (TERM during the per-check sweep).
note "Scenario 6: TERM during a check sweep releases the lock with no orphan child"
dir=$LAB/term; mkdir -p "$dir"
home=$(make_home term)
printf '%s\n' 'kind=ship' > "$home/state/task.meta"
for i in 1 2 3 4 5; do
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'sleep 20 &'
    printf '%s\n' 'printf "%s %s\n" "$$" "$!" >> "$FM_HOME/sweep-pids"'
    printf '%s\n' 'wait'
  } > "$home/state/long-$i.check.sh"
  chmod 0700 "$home/state/long-$i.check.sh"
  FM_HOME="$home" "$WT/bin/fm-check-register.sh" "long-$i" >/dev/null
done
pid=$(start_watcher "$WT" "$home" "$dir/watch.out" 4)
i=0
while [ "$i" -lt 100 ]; do
  [ -f "$home/sweep-pids" ] && [ "$(wc -l < "$home/sweep-pids")" -ge 2 ] && break
  sleep 0.1
  i=$((i + 1))
done
recorded=$(wc -l < "$home/sweep-pids" 2>/dev/null || echo 0)
kill -TERM "$pid"
i=0
while [ "$i" -lt 100 ]; do
  kill -0 "$pid" 2>/dev/null || break
  sleep 0.1
  i=$((i + 1))
done
sleep 1
leftover=0
[ -f "$home/sweep-pids" ] && while read -r p c; do
  kill -0 "$p" 2>/dev/null && leftover=$((leftover + 1))
  kill -0 "$c" 2>/dev/null && leftover=$((leftover + 1))
done < "$home/sweep-pids"
lock_after=$([ -e "$home/state/.watch.lock/pid" ] && echo held || echo released)
# A successor must acquire the same home's lock.
successor=$(start_watcher "$WT" "$home" "$dir/watch2.out" 4)
succ_lock=$(cat "$home/state/.watch.lock/pid" 2>/dev/null || true)
stop_pid "$successor"
printf 'recorded sweep pids=%s leftover=%s; lock after TERM=%s; successor acquired=%s\n' \
  "$recorded" "$leftover" "$lock_after" "$([ "$succ_lock" = "$successor" ] && echo yes || echo no)"
if kill -0 "$pid" 2>/dev/null; then
  bad "watcher survived TERM during the sweep"
elif [ "${recorded:-0}" -lt 1 ]; then
  bad "no sweep child pids were recorded, so the cleanup check would be vacuous"
elif [ "$leftover" -ne 0 ]; then
  bad "check-sweep children outlived the TERM ($leftover alive of $recorded pids)"
elif [ "$lock_after" != released ]; then
  bad "lock was not released after TERM"
elif [ "$succ_lock" != "$successor" ]; then
  bad "a successor could not acquire the home after the TERM"
else
  ok "TERM mid-sweep left no children, released the lock, and a successor took over"
fi

printf '\nDRIVER_RESULT failures=%s\n' "$FAILED"
exit "$FAILED"
