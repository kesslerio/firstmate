#!/usr/bin/env bash
# Live validation harness for fix/watcher-beacon-progress.
# Drives the real bin/fm-watch.sh, bin/fm-guard.sh and bin/fm-turnend-guard.sh
# against disposable marked lab homes (bin/fm-lab-home.sh) and records what a
# reviewer can see: beacon age across a long working cycle, the real guard's
# banner (or silence), and the real turn-end guard's allow/block verdict.
set -u
ROOT={run-worktree}
EVID=~/.no-mistakes/evidence/01M76N3KAZ1W7ZQQQ0NFQ372KE
LOG=$EVID/live-scenarios.log
: > "$LOG"
say() { printf '%s\n' "$*" | tee -a "$LOG"; }
section() { printf '\n===== %s =====\n' "$*" | tee -a "$LOG"; }

new_lab() {  # <tag> -> path
  local lab
  lab=$(mktemp -d "/tmp/fm-live-${1}.XXXXXX") || exit 1
  "$ROOT/bin/fm-lab-home.sh" create "$lab" >/dev/null || exit 1
  mkdir -p "$lab/config"
  printf '%s\n' "$lab"
}

register_slow_checks() {  # <lab> <count>
  local lab=$1 n=$2 i=0
  while [ "$i" -lt "$n" ]; do
    i=$((i + 1))
    printf '#!/usr/bin/env bash\nsleep 2\nexit 0\n' > "$lab/state/slow-$i.check.sh"
    chmod 700 "$lab/state/slow-$i.check.sh"
    FM_HOME="$lab" "$ROOT/bin/fm-check-register.sh" "slow-$i" >/dev/null || {
      say "FAIL: could not register slow-$i"; return 1; }
  done
}

wait_for_watcher() {  # <lab> <pid>
  local lab=$1 pid=$2 i=0
  while [ "$i" -lt 150 ]; do
    [ "$(cat "$lab/state/.watch.lock/pid" 2>/dev/null || true)" = "$pid" ] \
      && [ -e "$lab/state/.last-watcher-beat" ] && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

stop_pid() {
  local pid=$1 i=0
  kill -CONT "$pid" 2>/dev/null || true
  kill -TERM "$pid" 2>/dev/null || true
  while [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.05; i=$((i + 1)); done
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

mtime() { stat -c %Y "$1" 2>/dev/null || echo 0; }

# --------------------------------------------------------------------------
section "A. real watcher mid long multi-sweep cycle keeps the beacon fresh"
LAB_A=$(new_lab cycle) || exit 1
register_slow_checks "$LAB_A" 8 || exit 1
say "lab: $LAB_A  (8 registered checks x 2s = 16s sweep, explicit grace 6s)"
env -u NO_MISTAKES_GATE -u FM_GUARD_GRACE -u FM_POLL \
  FM_HOME="$LAB_A" FM_GUARD_GRACE=6 FM_POLL=1 FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=1 FM_CHECK_TIMEOUT=30 FM_HEARTBEAT=999999 \
  "$ROOT/bin/fm-watch.sh" > "$LAB_A/watch.out" 2>&1 &
WA=$!
if wait_for_watcher "$LAB_A" "$WA"; then say "real watcher took lock: pid=$WA"; else say "FAIL: watcher never took the lock"; fi
max_age=0; beacon_changes=0; cycle_changes=0; prev_b=; prev_c=; i=0; guard_ran=0
while [ "$i" -lt 120 ]; do
  b=$(mtime "$LAB_A/state/.last-watcher-beat")
  c=$(mtime "$LAB_A/state/.watch-cycle")
  now=$(date +%s); age=$((now - b)); [ "$age" -gt "$max_age" ] && max_age=$age
  [ -n "$prev_b" ] && [ "$b" != "$prev_b" ] && beacon_changes=$((beacon_changes + 1))
  [ -n "$prev_c" ] && [ "$c" != "$prev_c" ] && cycle_changes=$((cycle_changes + 1))
  prev_b=$b; prev_c=$c
  if [ "$i" -eq 48 ]; then
    say "--- real fm-guard.sh at sample $i: beacon age ${age}s, grace 6s ---"
    out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$LAB_A" FM_GUARD_GRACE=6 \
      FM_SUPERVISION_MODEL=persistent "$ROOT/bin/fm-guard.sh" 2>&1)
    rc=$?
    say "guard_exit=$rc output=[${out:-<empty>}]"
    guard_ran=1
    case "$out" in *"WATCHER DOWN"*) say "FAIL: working watcher raised WATCHER DOWN" ;; esac
  fi
  printf 'sample=%s beacon_age=%ss beacon_mtime=%s cycle_mtime=%s\n' "$i" "$age" "$b" "$c" >> "$LOG"
  sleep 0.25; i=$((i + 1))
done
say "RESULT_A max_beacon_age=${max_age}s grace=6s beacon_mtime_changes=$beacon_changes cycle_advances=$cycle_changes guard_ran=$guard_ran"
stop_pid "$WA"
say "watcher stopped; tail of watch output:"; tail -3 "$LAB_A/watch.out" 2>/dev/null | tee -a "$LOG"
rm -rf "$LAB_A"

# --------------------------------------------------------------------------
section "B. adversarial: a frozen watcher mid-cycle still raises WATCHER DOWN"
LAB_B=$(new_lab frozen) || exit 1
register_slow_checks "$LAB_B" 8 || exit 1
say "lab: $LAB_B"
env -u NO_MISTAKES_GATE -u FM_GUARD_GRACE -u FM_POLL \
  FM_HOME="$LAB_B" FM_GUARD_GRACE=6 FM_POLL=1 FM_SIGNAL_GRACE=1 \
  FM_CHECK_INTERVAL=1 FM_CHECK_TIMEOUT=30 FM_HEARTBEAT=999999 \
  "$ROOT/bin/fm-watch.sh" > "$LAB_B/watch.out" 2>&1 &
WB=$!
if wait_for_watcher "$LAB_B" "$WB"; then say "real watcher took lock: pid=$WB"; else say "FAIL: watcher never took the lock"; fi
# Let it get into its slow check sweep, then freeze the process exactly as a
# wedged cycle would stop making progress.
sleep 4
kill -STOP "$WB" 2>/dev/null || true
say "froze watcher pid=$WB with SIGSTOP at beacon age $(( $(date +%s) - $(mtime "$LAB_B/state/.last-watcher-beat") ))s"
sleep 9
age=$(( $(date +%s) - $(mtime "$LAB_B/state/.last-watcher-beat") ))
say "beacon age now ${age}s (grace 6s)"
out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$LAB_B" FM_GUARD_GRACE=6 \
  FM_SUPERVISION_MODEL=persistent "$ROOT/bin/fm-guard.sh" 2>&1); rc=$?
say "guard_exit=$rc"
printf '%s\n' "$out" | tee -a "$LOG"
case "$out" in
  *"WATCHER DOWN"*) say "RESULT_B PASS: frozen watcher still trips the banner" ;;
  *) say "RESULT_B FAIL: frozen watcher did not trip the banner" ;;
esac
stop_pid "$WB"
rm -rf "$LAB_B"

# --------------------------------------------------------------------------
section "C. home-configured cadence and grace govern the real readers"
# A disposable secondmate-primary fixture root whose bin/ is this worktree's
# product code: the watcher and every reader below run the SAME script path, so
# the identity-matched lock check is exercised for real instead of failing on a
# path mismatch.
FX=$(mktemp -d /tmp/fm-live-fx.XXXXXX) || exit 1
cp -a "$ROOT/bin" "$FX/bin" && cp -a "$ROOT/AGENTS.md" "$FX/AGENTS.md"
printf 'fixture-primary\n' > "$FX/.fm-secondmate-home"
LAB_C=$(new_lab cadence) || exit 1
register_slow_checks "$LAB_C" 2 || exit 1
printf 'export FM_POLL=600\n' > "$LAB_C/config/watch.env"
say "lab: $LAB_C  config/watch.env: export FM_POLL=600 (derived grace 660s)"
say "product code: $FX/bin (copy of this worktree's bin)"
env -u NO_MISTAKES_GATE -u FM_GUARD_GRACE -u FM_POLL \
  FM_HOME="$LAB_C" "$FX/bin/fm-watch.sh" > "$LAB_C/watch.out" 2>&1 &
WC=$!
if wait_for_watcher "$LAB_C" "$WC"; then say "real watcher took lock: pid=$WC path=$FX/bin/fm-watch.sh"; else say "FAIL: watcher never took the lock"; fi
kill -STOP "$WC" 2>/dev/null || true
fm_touch_back() { local secs=$1 path=$2; touch -d "@$(( $(date +%s) - secs ))" "$path" 2>/dev/null; }
fm_touch_back 320 "$LAB_C/state/.last-watcher-beat"
say "froze watcher; backdated beacon to 320s (inside the 600s-poll derived 660s grace)"
out=$(FM_ROOT_OVERRIDE="$FX" FM_HOME="$LAB_C" FM_SUPERVISION_MODEL=persistent \
  "$FX/bin/fm-guard.sh" 2>&1); rc=$?
say "guard (home FM_POLL=600, no explicit grace) exit=$rc output=[${out:-<empty>}]"
case "$out" in
  *"WATCHER DOWN"*) say "RESULT_C1 FAIL: 320s beacon alarmed under the configured long poll" ;;
  *) say "RESULT_C1 PASS: 320s beacon stayed fresh under the configured 600s poll" ;;
esac
payload='{"session_id":"live-scenario","stop_hook_active":false,"hook_event_name":"Stop"}'
out=$(printf '%s' "$payload" | FM_ROOT_OVERRIDE="$FX" FM_HOME="$LAB_C" "$FX/bin/fm-turnend-guard.sh" 2>&1); rc=$?
say "turnend guard (home FM_POLL=600, 320s beacon) exit=$rc output=[${out:-<empty>}]"
if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
  say "RESULT_C2 PASS: turn-end guard allowed the turn under the configured long poll"
else
  say "RESULT_C2 FAIL: turn-end guard did not allow the 320s beacon under the 660s grace"
fi
printf 'export FM_POLL=600\nexport FM_GUARD_GRACE=60\n' > "$LAB_C/config/watch.env"
fm_touch_back 100 "$LAB_C/state/.last-watcher-beat"
out=$(FM_ROOT_OVERRIDE="$FX" FM_HOME="$LAB_C" FM_SUPERVISION_MODEL=persistent \
  "$FX/bin/fm-guard.sh" 2>&1); rc=$?
say "guard (config FM_GUARD_GRACE=60, 100s beacon) exit=$rc"
printf '%s\n' "$out" | tee -a "$LOG"
case "$out" in
  *"WATCHER DOWN"*) say "RESULT_C3 PASS: configured 60s grace alarmed on the 100s beacon" ;;
  *) say "RESULT_C3 FAIL: configured short grace was ignored" ;;
esac
out=$(printf '%s' "$payload" | FM_ROOT_OVERRIDE="$FX" FM_HOME="$LAB_C" "$FX/bin/fm-turnend-guard.sh" 2>&1); rc=$?
say "turnend guard (config grace 60, 100s beacon) exit=$rc"
printf '%s\n' "$out" | tee -a "$LOG"
case "$rc" in 2) say "RESULT_C4 PASS: turn-end guard blocked with the configured short grace" ;;
  *) say "RESULT_C4 FAIL: turn-end guard did not block (exit $rc)" ;; esac
stop_pid "$WC"
rm -rf "$LAB_C" "$FX"

section "done"
