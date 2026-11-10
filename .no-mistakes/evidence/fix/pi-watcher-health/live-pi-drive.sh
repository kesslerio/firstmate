#!/usr/bin/env bash
# Live driver: real `pi` primary in a disposable fm-lab home with the tracked
# .pi/extensions/fm-primary-pi-watch.ts. Exercises the 30s health monitor's
# repair of a stalled identity-verified watcher, and the poll-derived grace
# boundary (a long-poll watcher with a 400s-old beacon must not be replaced).
set -u
ROOT=${ROOT:?}
EVID=${EVID:?}
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux"
printf 'export FM_POLL=600\n' > "$LAB/config/watch.env"
touch "$LAB/config/supervision-host"
cat > "$LAB/launch.sh" <<'SH'
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
exec pi -a -nc --no-session
SH
T() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab "$@"; }
cleanup() {
  T kill-server 2>/dev/null
  sleep 1
  pkill -f "FM_HOME=$LAB" 2>/dev/null
  pkill -f "$LAB" 2>/dev/null
  "$ROOT/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1
  rm -rf "$LAB"
}
trap cleanup EXIT

env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -c "$ROOT" \
    -e FM_HOME="$LAB" -e FM_WATCH_EXTENSION_LOG_KEEP_LINES=200 -x 200 -y 50 bash "$LAB/launch.sh" || { echo "launch failed"; exit 1; }

echo "LAB=$LAB"
echo "== state before any tool call =="
{
  echo "lock=$(cat "$LAB/state/.lock" 2>/dev/null)"
  echo "files:"; ls -a "$LAB/state"
} > "$EVID/pi-start-state.txt" 2>&1

wait_for() { # wait_for <grep-pattern> <seconds>
  local pat=$1 secs=$2 i
  for ((i = 0; i < secs * 2; i++)); do
    T capture-pane -p -t primary 2>/dev/null > "$EVID/pi-pane-now.txt"
    grep -qE "$pat" "$EVID/pi-pane-now.txt" && return 0
    sleep 0.5
  done
  return 1
}

# Wait for the TUI to be ready for input (composer/status line present).
for i in $(seq 1 120); do
  T capture-pane -p -t primary 2>/dev/null > "$EVID/pi-pane-now.txt"
  grep -qE "no-mistakes/worktrees|TPS:|auto\)" "$EVID/pi-pane-now.txt" && break
  sleep 1
done
T capture-pane -p -t primary > "$EVID/pi-boot-pane.txt" 2>&1

echo "== prompt 1: arm the watcher =="
T send-keys -t primary -l "Run the fm_watch_arm_pi tool exactly once, then quote its full output verbatim. Do not run bash."
sleep 1
T send-keys -t primary Enter
wait_for "watcher: (started|attached)" 120
T capture-pane -p -t primary > "$EVID/pi-pane-after-arm.txt" 2>&1
echo "arm pane captured"

watch_pid=$(cat "$LAB/state/.watch.lock/pid" 2>/dev/null)
{
  echo "watch_lock_pid=$watch_pid"
  echo "watch_lock_watcher_path=$(cat "$LAB/state/.watch.lock/watcher-path" 2>/dev/null)"
  echo "watch_lock_home=$(cat "$LAB/state/.watch.lock/fm-home" 2>/dev/null)"
  echo "beat_age_s=$(( $(date +%s) - $(stat -c %Y "$LAB/state/.last-watcher-beat" 2>/dev/null || echo 0) ))"
  echo "process:"; ps -o pid,ppid,args -p "$watch_pid" 2>/dev/null
  echo "children:"; ps -o pid,ppid,args --ppid "$watch_pid" 2>/dev/null
} > "$EVID/pi-arm-state.txt" 2>&1

echo "== step 2: beacon 400s old, inside the FM_POLL=600 derived grace (660s) =="
touch -d '-400 seconds' "$LAB/state/.last-watcher-beat"
sleep 40
pid_after_inside=$(cat "$LAB/state/.watch.lock/pid" 2>/dev/null)
{
  echo "pid_before=$watch_pid"
  echo "pid_after_400s_beacon=$pid_after_inside"
  echo "extension_log:"
  cat "$LAB/state/.watch-extension.log" 2>/dev/null
  echo "monitor_rows=$(grep -c 'health monitor' "$LAB/state/.watch-extension.log" 2>/dev/null || echo 0)"
} > "$EVID/pi-grace-inside.txt" 2>&1

echo "== prompt 2: report status with the 400s beacon =="
T send-keys -t primary -l "Run the fm_watch_arm_pi tool exactly once again, then quote its full output verbatim. Do not run bash."
sleep 1
T send-keys -t primary Enter
sleep 20
T capture-pane -p -t primary > "$EVID/pi-pane-inside-grace.txt" 2>&1

echo "== step 3: beacon 700s old, past the derived grace: monitor must repair =="
touch -d '-700 seconds' "$LAB/state/.last-watcher-beat"
sleep 45
pid_after_outside=$(cat "$LAB/state/.watch.lock/pid" 2>/dev/null)
{
  echo "pid_before_outside=$pid_after_inside"
  echo "pid_after_outside=$pid_after_outside"
  echo "extension_log:"
  cat "$LAB/state/.watch-extension.log" 2>/dev/null
  echo "beat_age_s=$(( $(date +%s) - $(stat -c %Y "$LAB/state/.last-watcher-beat" 2>/dev/null || echo 0) ))"
  echo "process:"; ps -o pid,ppid,args -p "$pid_after_outside" 2>/dev/null
  echo "children:"; ps -o pid,ppid,args --ppid "$pid_after_outside" 2>/dev/null
  echo "retired_pid_alive:"; ps -o pid,args -p "$pid_after_inside" 2>/dev/null || echo "no (retired)"
  echo "all_lab_watchers:"; ps -eo pid,ppid,args | grep -F "$LAB" | grep -v grep || true
  echo "watchers_for_tracked_script:"
  ps -eo pid,args | grep -F "bin/fm-watch.sh" | grep -v grep || true
} > "$EVID/pi-health-replacement.txt" 2>&1

echo "== prompt 3: report status after automatic repair =="
T send-keys -t primary -l "Run the fm_watch_arm_pi tool exactly once more, then quote its full output verbatim. Do not run bash."
sleep 1
T send-keys -t primary Enter
sleep 20
T capture-pane -p -t primary > "$EVID/pi-pane-after-repair.txt" 2>&1

{
  echo "final_lock_pid=$(cat "$LAB/state/.watch.lock/pid" 2>/dev/null)"
  echo "final_beat_age_s=$(( $(date +%s) - $(stat -c %Y "$LAB/state/.last-watcher-beat" 2>/dev/null || echo 0) ))"
  echo "lab_pids:"
  ps -eo pid,ppid,args | grep -F "$ROOT/bin/fm-watch" | grep -v grep
} > "$EVID/pi-final-state.txt" 2>&1

echo "== done =="
