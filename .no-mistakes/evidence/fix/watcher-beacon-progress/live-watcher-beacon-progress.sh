#!/usr/bin/env bash
# Live scenarios for fix/watcher-beacon-progress: drive the real firstmate
# watcher, arm, pull guard, turn-end guard, inbox readiness projection, and
# pending-reply sweep against disposable homes built in a throwaway temp dir.
# Usage: live-watcher-beacon-progress.sh <repo-root>
set -u

ROOT=$(cd "$1" && pwd) || exit 1
WATCH="$ROOT/bin/fm-watch.sh"
WATCH_ARM="$ROOT/bin/fm-watch-arm.sh"
GUARD="$ROOT/bin/fm-guard.sh"
TURNEND="$ROOT/bin/fm-turnend-guard.sh"
INBOX="$ROOT/bin/fm-inbox.sh"

# The arm and tar-pit paths refuse a disposable validation checkout unless the
# repo's own test-harness hatch is set (bin/fm-gate-refuse-lib.sh header). This
# is the same exemption tests/lib.sh exports for firstmate's own suites.
export FM_GATE_REFUSE_BYPASS=1
unset NO_MISTAKES_GATE FM_TEST_SEAM

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-beacon.XXXXXX") || exit 1
CHILD_PIDS=()
cleanup() {
  local pid f
  for pid in ${CHILD_PIDS[@]+"${CHILD_PIDS[@]}"}; do kill -TERM "$pid" 2>/dev/null || true; done
  for pid in ${CHILD_PIDS[@]+"${CHILD_PIDS[@]}"}; do kill -KILL "$pid" 2>/dev/null || true; done
  while IFS= read -r f; do
    kill -TERM "$(cat "$f" 2>/dev/null || true)" 2>/dev/null || true
  done < <(find "$WORK" -name pid -path '*/.watch.lock/*' 2>/dev/null)
  rm -rf "$WORK"
}
trap cleanup EXIT

FAILED=0
begin() { printf '\n=========== SCENARIO: %s\n' "$1"; }
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; FAILED=$((FAILED + 1)); }
assert_test() {  # <label> <detail> <test args...>
  local label=$1 detail=$2
  shift 2
  if test "$@"; then ok "$label"; else bad "$label :: $detail"; fi
}
assert_cmd() {  # <label> <detail> <command...>
  local label=$1 detail=$2
  shift 2
  if "$@" >/dev/null 2>&1; then ok "$label"; else bad "$label :: $detail"; fi
}
age_of() {
  local now m
  now=$(date +%s)
  m=$(stat -c %Y "$1" 2>/dev/null) || { printf 999999; return; }
  printf '%s' "$(( now - m ))"
}
touch_at() { touch -d "@$1" "$2"; }

make_case() {  # <name> -> echoes case dir
  local dir="$WORK/$1"
  mkdir -p "$dir/home/state" "$dir/home/config" "$dir/home/data" "$dir/root/bin"
  : > "$dir/root/AGENTS.md"
  git -C "$dir/root" init -q 2>/dev/null || true
  printf '%s' "$dir"
}
stop_pid() {
  local pid=${1:-} i=0
  [ -n "$pid" ] || return 0
  kill -TERM "$pid" 2>/dev/null || return 0
  while [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null; do sleep 0.05; i=$((i + 1)); done
  kill -KILL "$pid" 2>/dev/null || true
}
register_slow_checks() {  # <home> <count> <seconds>
  local home=$1 count=$2 secs=$3 i=1
  while [ "$i" -le "$count" ]; do
    printf '#!/usr/bin/env bash\nsleep %s\nexit 0\n' "$secs" > "$home/state/slow-$i.check.sh"
    chmod 0700 "$home/state/slow-$i.check.sh"
    FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" "slow-$i" >/dev/null
    i=$((i + 1))
  done
}
record_live_holder() {  # <home> <pid>
  local home=$1 pid=$2 identity
  identity=$(bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$pid")
  mkdir -p "$home/state/.watch.lock"
  printf '%s\n' "$pid" > "$home/state/.watch.lock/pid"
  printf '%s\n' "$home" > "$home/state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$home/state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$home/state/.watch.lock/pid-identity"
}
HOLDER_PID=
start_stalled_holder() {  # <home> <beacon-age-seconds>; sets HOLDER_PID
  local home=$1 age=$2
  printf 'kind=ship\n' > "$home/state/task.meta"
  sleep 300 >/dev/null 2>&1 &
  HOLDER_PID=$!
  CHILD_PIDS+=("$HOLDER_PID")
  record_live_holder "$home" "$HOLDER_PID"
  : > "$home/state/.last-watcher-beat"
  touch_at "$(( $(date +%s) - age ))" "$home/state/.last-watcher-beat"
}
run_guard() {  # <case-dir> [explicit-grace]
  local dir=$1 grace=${2:-}
  env -u FM_POLL -u FM_GUARD_GRACE \
    FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" \
    ${grace:+FM_GUARD_GRACE=$grace} FM_SUPERVISION_MODEL=persistent \
    "$GUARD" 2>&1
}

# ---------------------------------------------------------------------------
begin "live watcher mid-sweep keeps the beacon fresh and raises no watcher-down"
d=$(make_case long-cycle); home=$d/home; beat=$home/state/.last-watcher-beat
printf 'kind=ship\n' > "$home/state/task.meta"
register_slow_checks "$home" 5 2
FM_HOME="$home" FM_GUARD_GRACE=4 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 \
  FM_CHECK_TIMEOUT=30 FM_HEARTBEAT=999999 "$WATCH" > "$d/watch.out" 2>&1 &
W=$!; CHILD_PIDS+=("$W")
i=0
while [ "$i" -lt 150 ]; do
  [ "$(cat "$home/state/.watch.lock/pid" 2>/dev/null || true)" = "$W" ] && [ -e "$beat" ] && break
  sleep 0.1; i=$((i + 1))
done
if [ "$(cat "$home/state/.watch.lock/pid" 2>/dev/null || true)" = "$W" ]; then
  ok "fixture watcher took the lock (pid $W)"
else
  bad "fixture watcher did not take the lock: pid=$(cat "$home/state/.watch.lock/pid" 2>/dev/null) out=$(cat "$d/watch.out")"
fi
maxage=0
cycles=' '
i=0
while [ "$i" -lt 60 ]; do
  a=$(age_of "$beat"); [ "$a" -le "$maxage" ] || maxage=$a
  cm=$(stat -c %Y "$home/state/.watch-cycle" 2>/dev/null || true)
  case "$cycles" in *" $cm "*) ;; *) cycles="$cycles$cm " ;; esac
  sleep 0.2; i=$((i + 1))
done
ncycles=$(set -- $cycles; printf '%s' "$#")
guard_out=$(run_guard "$d" 4)
printf 'sampled 12s with %s completed cycle(s) (~%ss each), max beacon age under the 4s grace: %ss\n' \
  "$ncycles" "$(( 12 / (ncycles > 0 ? ncycles : 1) ))" "$maxage"
assert_test "the watched cycle itself outlasted the 4s grace" "cycle interval observed over 12s: ${ncycles} cycle(s)" \
  "$ncycles" -le 2
printf 'guard(grace=4s) during the working cycle: %s\n' "${guard_out:-<silent>}"
assert_test "beacon never aged past the 4s grace while the watcher worked" "max age ${maxage}s" "$maxage" -lt 4
assert_test "pull guard stayed silent during the long working cycle" "$guard_out" -z "$guard_out"
assert_test "cycle boundary marker exists" "missing $home/state/.watch-cycle" -e "$home/state/.watch-cycle"

# ---------------------------------------------------------------------------
begin "successor arm attaches to the working watcher instead of replacing it"
env FM_HOME="$home" FM_GUARD_GRACE=4 FM_ARM_ATTACH_POLL=0.1 FM_ARM_CONFIRM_TIMEOUT=5 \
  "$WATCH_ARM" > "$d/arm.out" 2>&1 &
A=$!; CHILD_PIDS+=("$A")
i=0
while [ "$i" -lt 150 ]; do
  grep -qF "watcher: attached pid=$W" "$d/arm.out" 2>/dev/null && break
  grep -qF "watcher: FAILED" "$d/arm.out" 2>/dev/null && break
  sleep 0.1; i=$((i + 1))
done
stop_pid "$A"
printf 'arm output: %s\n' "$(tr '\n' '|' < "$d/arm.out")"
assert_cmd "arm attached to the working watcher pid $W" "$(cat "$d/arm.out")" \
  grep -qF "watcher: attached pid=$W" "$d/arm.out"
stop_pid "$W"

# ---------------------------------------------------------------------------
begin "adversarial: a wedged beacon still trips WATCHER DOWN and is evicted"
d=$(make_case wedged); home=$d/home
start_stalled_holder "$home" 20
H=$HOLDER_PID
printf 'fixture holder pid %s, beacon age %ss\n' "$H" "$(age_of "$home/state/.last-watcher-beat")"
out=$(run_guard "$d" 7)
printf 'guard(grace=7s) on a 20s-old beacon: %s\n' "$(printf '%s' "$out" | sed -n 2p)"
assert_cmd "wedged beacon raised WATCHER DOWN" "$out" \
  bash -c 'printf "%s" "$1" | grep -q "WATCHER DOWN"' _ "$out"
assert_cmd "banner judged the explicit 7s grace" "$out" \
  bash -c 'printf "%s" "$1" | grep -q "grace 7s"' _ "$out"
out=$(env FM_HOME="$home" FM_GUARD_GRACE=7 FM_WATCHER_STALL_BOUND=60 \
  FM_ARM_CONFIRM_TIMEOUT=5 "$WATCH_ARM" 2>&1)
if kill -0 "$H" 2>/dev/null; then
  ok "holder inside the 60s hard bound was left in place"
else
  bad "holder inside the hard bound was killed: $out"
fi
assert_test "no replacement attempted inside the hard bound" "$out" \
  "${out#*replaced stalled pid}" = "$out"
touch_at "$(( $(date +%s) - 30 ))" "$home/state/.last-watcher-beat"
printf 'holder beacon backdated to %ss, hard bound now 5s\n' "$(age_of "$home/state/.last-watcher-beat")"
env FM_HOME="$home" FM_GUARD_GRACE=7 FM_WATCHER_STALL_BOUND=5 FM_ARM_CONFIRM_TIMEOUT=5 \
  FM_ARM_ATTACH_POLL=0.1 "$WATCH_ARM" > "$d/evict.out" 2>&1 &
A=$!; CHILD_PIDS+=("$A")
i=0
while [ "$i" -lt 200 ]; do
  grep -qF "replaced stalled pid $H" "$d/evict.out" 2>/dev/null && break
  grep -qF 'watcher: FAILED' "$d/evict.out" 2>/dev/null && break
  sleep 0.1; i=$((i + 1))
done
stop_pid "$A"
printf 'arm(hard bound 5s) output: %s\n' "$(tr '\n' '|' < "$d/evict.out")"
assert_cmd "wedged holder past the hard bound was evicted and replaced" "$(cat "$d/evict.out")" \
  grep -qF "replaced stalled pid $H" "$d/evict.out"
assert_test "the evicted holder process is gone" "holder $H still alive" ! -e "/proc/$H"
if [ -e "$home/state/.watch.lock/pid" ]; then
  reap=$(cat "$home/state/.watch.lock/pid" 2>/dev/null || true)
  CHILD_PIDS+=("$reap"); stop_pid "$reap"
fi

# ---------------------------------------------------------------------------
begin "adversarial: progress refresh is inert outside a watcher and throttled"
d=$(make_case inert); home=$d/home; beat=$home/state/.last-watcher-beat
: > "$beat"; touch_at "$(( $(date +%s) - 25 ))" "$beat"
out=$(bash -c '
  . "$1"
  beat=$2
  unset FM_WATCH_BEACON_PATH
  before=$(fm_path_age "$beat")
  fm_watch_beacon_progress
  after=$(fm_path_age "$beat")
  printf "%s %s\n" "$before" "$after"
' _ "$ROOT/bin/fm-wake-lib.sh" "$beat")
printf 'outside a watcher, beacon age before/after a refresh call: %s\n' "$out"
set -- $out
assert_test "a non-watcher call left the stale beacon stale" "before=$1 after=$2" "$1" -ge 25 -a "$2" -ge 25
out=$(bash -c '
  . "$1"
  beat=$2
  unset SECONDS
  SECONDS=100
  FM_WATCH_BEACON_PATH=$beat
  fm_watch_beacon_progress
  touch -t 200001010000 "$beat"
  before=$(fm_path_mtime "$beat")
  fm_watch_beacon_progress
  same=$(fm_path_mtime "$beat")
  SECONDS=101
  fm_watch_beacon_progress
  later=$(fm_path_mtime "$beat")
  printf "%s %s %s\n" "$before" "$same" "$later"
' _ "$ROOT/bin/fm-wake-lib.sh" "$beat")
set -- $out
printf 'inside a watcher: beacon mtime before repeat, after repeat, after next second: %s %s %s\n' "$1" "$2" "$3"
assert_test "a repeat call in the same second did not rewrite the beacon" "mtime $1 -> $2" "$1" = "$2"
assert_test "the next second's call did refresh the beacon" "mtime stuck at $2" "$3" -gt "$2"
assert_test "the refreshed beacon is fresh" "age $(age_of "$beat")s" "$(age_of "$beat")" -le 1

# ---------------------------------------------------------------------------
begin "configured home cadence governs the guard, inbox readiness, and supervision lib"
d=$(make_case configured); home=$d/home
printf 'export FM_POLL=600\n' > "$home/config/watch.env"
start_stalled_holder "$home" 320
H=$HOLDER_PID
printf 'home config: FM_POLL=600 (derived grace 660); beacon age %ss\n' "$(age_of "$home/state/.last-watcher-beat")"
out=$(run_guard "$d")
printf 'guard with home config 660s and caller env FM_POLL unset: %s\n' "${out:-<silent>}"
assert_test "a 320s beacon is fresh under the configured 660s cadence" "$out" -z "$out"
out=$(FM_POLL=15 run_guard "$d")
printf 'guard with caller FM_POLL=15 but home config 600: %s\n' "${out:-<silent>}"
assert_test "a caller FM_POLL=15 did not shrink the home-configured window" "$out" -z "$out"
grace=$(bash -c '. "$1"; FM_POLL=15; fm_beacon_grace' _ "$ROOT/bin/fm-wake-lib.sh")
printf 'fm_beacon_grace with caller FM_POLL=15 and no home: %s\n' "$grace"
assert_test "an explicit caller poll still derives the max(300, poll+60) floor" "$grace" "$grace" = 300
printf 'export FM_GUARD_GRACE=1200\n' >> "$home/config/watch.env"
out=$(run_guard "$d")
printf 'guard with home config grace 1200 on the 320s beacon: %s\n' "${out:-<silent>}"
assert_test "a configured 1200s grace hears the 320s beacon as fresh" "$out" -z "$out"
out=$(env -u FM_POLL FM_ROOT_OVERRIDE="$d/root" FM_HOME="$home" \
  FM_SUPERVISION_MODEL=persistent "$INBOX" ready 2>&1)
printf 'fm-inbox ready under configured 1200s grace: %s\n' "$(printf '%s' "$out" | tr -d '\n' | cut -c1-260)"
assert_cmd "inbox readiness reports a supervised consumer, not a down one" "$out" \
  bash -c 'printf "%s" "$1" | grep -q "\"state\":\"healthy\""' _ "$out"
printf 'export FM_POLL=600\nexport FM_GUARD_GRACE=60\n' > "$home/config/watch.env"
touch_at "$(( $(date +%s) - 100 ))" "$home/state/.last-watcher-beat"
out=$(run_guard "$d")
printf 'guard with home config poll 600 + grace 60 on a 100s beacon: %s\n' "$(printf '%s' "$out" | sed -n 2p)"
assert_cmd "a configured short grace is not replaced by the long poll default" "$out" \
  bash -c 'printf "%s" "$1" | grep -q "WATCHER DOWN"' _ "$out"
out=$(env -u FM_POLL FM_ROOT_OVERRIDE="$d/root" FM_HOME="$home" \
  FM_SUPERVISION_MODEL=persistent "$INBOX" ready 2>&1)
printf 'fm-inbox ready under configured 60s grace: %s\n' "$(printf '%s' "$out" | tr -d '\n' | cut -c1-220)"
assert_cmd "inbox readiness reports the consumer down under the configured short grace" "$out" \
  bash -c 'printf "%s" "$1" | grep -q "\"state\":\"down\""' _ "$out"
fresh=$(FM_HOME="$home" bash -c '. "$1"; fm_supervision_status "$2"; printf "%s" "$FM_SUP_WATCHER_FRESH"' \
  _ "$ROOT/bin/fm-supervision-lib.sh" "$home/state")
printf 'standalone fm_supervision_status FM_SUP_WATCHER_FRESH on the same home: %s\n' "$fresh"
assert_test "standalone supervision agrees with the guard's configured grace" "fresh=$fresh" "$fresh" = false
stop_pid "$H"

# ---------------------------------------------------------------------------
begin "turn-end guard blocks or allows a stop using the configured cadence"
d=$(make_case turnend); home=$d/home
printf 'export FM_POLL=600\n' > "$home/config/watch.env"
start_stalled_holder "$home" 320
H=$HOLDER_PID
payload='{"session_id":"live-fixture","stop_hook_active":false,"hook_event_name":"Stop"}'
rc=0
out=$(printf '%s' "$payload" | env -u FM_GUARD_GRACE -u FM_POLL \
  FM_ROOT_OVERRIDE="$d/root" FM_HOME="$home" FM_SUPERVISION_MODEL=persistent \
  "$TURNEND" 2>&1) || rc=$?
printf 'turn-end guard, home poll 600 (grace 660) on a 320s beacon: exit %s, output %s\n' "$rc" "${out:-<silent>}"
assert_test "a working supervised home lets the turn end" "exit $rc: $out" "$rc" -eq 0
printf 'export FM_POLL=600\nexport FM_GUARD_GRACE=60\n' > "$home/config/watch.env"
touch_at "$(( $(date +%s) - 100 ))" "$home/state/.last-watcher-beat"
rc=0
out=$(printf '%s' "$payload" | env -u FM_GUARD_GRACE -u FM_POLL \
  FM_ROOT_OVERRIDE="$d/root" FM_HOME="$home" FM_SUPERVISION_MODEL=persistent \
  "$TURNEND" 2>&1) || rc=$?
printf 'turn-end guard, home poll 600 + grace 60 on a 100s beacon: exit %s\n%s\n' "$rc" "$(printf '%s' "$out" | sed -n 1,3p)"
assert_test "a configured 60s grace blocks the stop" "exit $rc" "$rc" -eq 2
assert_cmd "the block carries the repair banner" "$out" \
  bash -c 'printf "%s" "$1" | grep -q "TURN WOULD END BLIND"' _ "$out"
stop_pid "$H"

# ---------------------------------------------------------------------------
begin "pending-reply sweep refreshes the watcher beacon between records"
d=$(make_case pending-reply); home=$d/home; beat=$home/state/.last-watcher-beat
mkdir -p "$home/state/pending-replies"
n=1
while [ "$n" -le 3 ]; do
  printf 'corr_id=corr-%s\ntask_id=task-%s\nphase=resolved\nescalated_epoch=1\n' "$n" "$n" \
    > "$home/state/pending-replies/corr-$n"
  n=$((n + 1))
done
: > "$beat"; touch_at "$(( $(date +%s) - 40 ))" "$beat"
out=$(bash -c '
  set -u
  . "$1/bin/fm-wake-lib.sh"
  . "$1/bin/fm-pending-reply-lib.sh"
  unset SECONDS
  SECONDS=100
  FM_WATCH_BEACON_PATH=$3
  before=$(fm_path_age "$3")
  fm_pending_reply_tick "$2"
  after=$(fm_path_age "$3")
  printf "%s %s\n" "$before" "$after"
' _ "$ROOT" "$home/state" "$beat" 2>&1)
printf 'pending-reply tick over 3 records, beacon age before/after: %s\n' "$(printf '%s' "$out" | tail -1)"
set -- $(printf '%s' "$out" | tail -1)
assert_test "a deep pending-reply sweep refreshed the beacon between records" "ages: $*" "$1" -ge 40 -a "$2" -le 1

# ---------------------------------------------------------------------------
begin "Herdr per-task display sweep refreshes the beacon and keeps its plan output"
d=$(make_case herdr-plan); home=$d/home; beat=$home/state/.last-watcher-beat
printf 'on\n' > "$home/config/herdr-project-groups"
t=1
while [ "$t" -le 3 ]; do
  printf 'kind=ship\nbackend=herdr\nproject=/work/repo-%s\nherdr_session=fm-lab-fixture\nherdr_workspace_id=w%s\nherdr_pane_id=p%s\n' \
    "$t" "$t" "$t" > "$home/state/task$t.meta"
  t=$((t + 1))
done
: > "$beat"; touch_at "$(( $(date +%s) - 40 ))" "$beat"
printf 'beacon age before the Herdr plan sweep: %ss\n' "$(age_of "$beat")"
out=$(env FM_HOME="$home" FM_WATCH_BEACON_PATH="$beat" \
  "$ROOT/bin/fm-herdr-groups.sh" plan 2>&1)
printf 'fm-herdr-groups.sh plan output:\n%s\n' "$out"
printf 'beacon age after the Herdr plan sweep: %ss\n' "$(age_of "$beat")"
set -- $out
assert_cmd "the plan sweep still emitted one row per recorded Herdr task" "$out" \
  bash -c 'printf "%s\n" "$1" | wc -l | grep -qx 3' _ "$out"
assert_cmd "each planned row still resolves a running state" "$out" \
  bash -c '[ "$(printf "%s\n" "$1" | grep -c running)" -eq 3 ]' _ "$out"
assert_test "the Herdr per-task sweep refreshed the watcher beacon" "age $(age_of "$beat")s" "$(age_of "$beat")" -le 1

printf '\nGATE_RESULT failed_assertions=%s\n' "$FAILED"
[ "$FAILED" -eq 0 ]
