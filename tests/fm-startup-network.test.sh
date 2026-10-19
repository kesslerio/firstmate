#!/usr/bin/env bash
# tests/fm-startup-network.test.sh - behavior tests for bin/fm-startup-network.sh,
# the deferred startup stage a session start launches instead of running its
# network work or inactive-outcome scan on the blocking path.
#
# The session-start suite proves the digest no longer waits and that the deferred
# sweeps still land. This suite pins the stage's own contract, whose whole job is
# to make deferral safe:
#   - `start` returns immediately and does not hold the caller's stdout open,
#     which is what would strand a session-open hook behind the worker
#   - a durable acknowledgement after harvest prints a finished result suppresses
#     the wake, while an unacknowledged result always produces one
#   - mutating sweeps are refused when the fleet lock no longer names the session
#     that requested them, and the refusal is reported rather than silent
#   - the aggregate bound turns a wedged sweep into an actionable line
#   - an abandoned `running` record is reported as needing a rerun rather than
#     staying "in progress" forever
#   - phase-aware single-flight: a covering worker is reused, while a later
#     locked request supersedes an in-flight probe-only worker
#   - a publish lock a live process holds past the budget ends the worker with a
#     failed-rerun record instead of an unbounded wait
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$ROOT/bin/fm-timeout-lib.sh"

FM_TEST_REAL_PS=$(command -v ps)
export FM_TEST_REAL_PS
TMP_ROOT=$(fm_test_tmproot fm-startup-network-tests)
DRAIN="$ROOT/bin/fm-wake-drain.sh"
FM_TEST_CLEANUP_DIRS+=("$TMP_ROOT")
FM_TEST_CHILD_REGISTRY="$TMP_ROOT/children"
export FM_TEST_CHILD_REGISTRY
trap fm_test_cleanup EXIT

# new_world <name>: an FM_HOME plus a fake code root whose bin/ is a real
# firstmate bin/ except for fm-bootstrap.sh, which is replaced by a scriptable
# stand-in. The stage's contract is about WHEN and WHETHER the network half runs
# and how its result is published; bin/fm-bootstrap.sh's own behavior is owned by
# tests/fm-bootstrap.test.sh, so pinning it here would duplicate that owner and
# make these assertions depend on unrelated tool detection.
new_world() {
  local name=$1 w home root
  w="$TMP_ROOT/$name"
  home="$w/home"
  root="$w/root"
  mkdir -p "$home/state" "$root/bin"
  for f in "$ROOT"/bin/*.sh; do
    ln -s "$f" "$root/bin/$(basename "$f")"
  done
  rm -f "$root/bin/fm-bootstrap.sh"
  cat > "$root/bin/fm-bootstrap.sh" <<'SH'
#!/usr/bin/env bash
# Scriptable stand-in: records how it was invoked, then behaves as the test asks.
set -u
printf 'network=%s detect_only=%s\n' \
  "${FM_BOOTSTRAP_NETWORK:-all}" "${FM_BOOTSTRAP_DETECT_ONLY:-0}" \
  >> "${FM_FAKE_BOOTSTRAP_LOG:?}"
# The real sweeps record their elapsed times through fm-timing-lib.sh, which
# reaches them as an exported FM_TIMING_LOG. Recording the same way here proves
# the stage actually hands that channel to its child and publishes what the child
# wrote - the part of the contract this suite owns. What the real sweeps measure
# is owned by tests/fm-bootstrap.test.sh.
if [ -n "${FM_TIMING_LOG:-}" ]; then
  . "$(dirname "$0")/fm-timing-lib.sh"
  fm_timing_record phase "${FM_FAKE_TIMING_PHASE:-gh-auth}" \
    "$(( $(fm_timing_now_ms) - 1500 ))" "${FM_FAKE_TIMING_DETAIL:-}"
fi
[ -z "${FM_FAKE_BOOTSTRAP_SLEEP:-}" ] || sleep "$FM_FAKE_BOOTSTRAP_SLEEP"
[ -z "${FM_FAKE_BOOTSTRAP_OUT:-}" ] || printf '%s\n' "$FM_FAKE_BOOTSTRAP_OUT"
exit "${FM_FAKE_BOOTSTRAP_RC:-0}"
SH
  chmod +x "$root/bin/fm-bootstrap.sh"
  cat > "$root/bin/ps" <<'SH'
#!/usr/bin/env bash
pid=
previous=
for argument in "$@"; do
  [ "$previous" = -p ] && pid=$argument
  previous=$argument
done
if [ "$pid" = "${FM_FAKE_HARNESS_PID:-}" ]; then
  case "$*" in
    *comm=*) printf '/usr/local/bin/claude\n' ;;
    *args=*) printf 'claude\n' ;;
    *ppid=*) "$FM_TEST_REAL_PS" -o ppid= -p "$pid" ;;
  esac
else
  "$FM_TEST_REAL_PS" "$@"
fi
SH
  chmod +x "$root/bin/ps"
  printf '%s|%s|%s\n' "$home" "$root" "$w/bootstrap.log"
}

# The detached worker records itself a moment after `start` returns - that gap is
# the whole point of not blocking - so a test that wants to observe the worker
# waits for its record rather than assuming instant publication.
await_worker_record() {  # <home>
  local home=$1 waited=0
  while [ ! -s "$home/state/.startup-network.status" ] && [ "$waited" -lt 100 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -s "$home/state/.startup-network.status" ] || fail "the detached worker never recorded itself"
}

test_wait_fails_without_a_published_stage() {
  local rec home root log
  rec=$(new_world wait-without-stage)
  IFS='|' read -r home root log <<EOF
$rec
EOF

  if run_stage "$home" "$root" wait 1 >/dev/null; then
    fail "wait reported success even though no deferred stage had published"
  fi

  pass "fm-startup-network: wait fails when no deferred stage publishes before its deadline"
}

run_stage() {  # <home> <root> <args...>
  local home=$1 root=$2
  shift 2
  PATH="$root/bin:$PATH" FM_FAKE_HARNESS_PID="${FM_FAKE_HARNESS_PID_OVERRIDE:-$$}" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$root/bin/fm-startup-network.sh" "$@"
}

wait_for_startup_network_wake() {  # <home> [tenths]
  local home=$1 limit=${2:-50} waited=0
  while ! grep -Fq $'check\tstartup-network' "$home/state/.wake-queue" 2>/dev/null \
    && [ "$waited" -lt "$limit" ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  grep -Fq $'check\tstartup-network' "$home/state/.wake-queue" 2>/dev/null
}

# hold_publish_lock <home>: take the stage's publish lock from a separate live
# process, the way a harvest wedged on a stalled stdout holds it, and print that
# holder's pid. The holder keeps the pid the lock records, so the lock's
# stale-owner recovery never reclaims it while the test runs.
hold_publish_lock() {  # <home>
  local lock="$1/state/${2:-.startup-network.lock}" holder waited=0
  FM_STATE_OVERRIDE="$1/state" FM_ROOT_OVERRIDE="$ROOT" bash -c '
    . "$1/fm-wake-lib.sh"
    fm_lock_try_acquire "$2" || exit 1
    exec sleep 120' _ "$ROOT/bin" "$lock" >/dev/null 2>&1 </dev/null &
  holder=$!
  fm_test_track_child "$holder"
  while [ "$(cat "$lock/pid" 2>/dev/null || true)" != "$holder" ] && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ "$(cat "$lock/pid" 2>/dev/null || true)" = "$holder" ] \
    || fail "could not hold the publish lock from a second process"
  HOLDER_PID=$holder
}

# await_pid_exit <pid> <tenths>: true when the process exits inside the bound.
await_pid_exit() {  # <pid> <tenths>
  local waited=0
  while kill -0 "$1" 2>/dev/null && [ "$waited" -lt "$2" ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  ! kill -0 "$1" 2>/dev/null
}

# --- tests -------------------------------------------------------------------

# `start` is called from inside a session-open hook whose stdout the harness
# reads to EOF. A worker that inherited that pipe would hold the session open for
# exactly as long as the network work it was supposed to get off the critical
# path, so this asserts both halves: start returns fast, AND the pipe closes
# while the worker is still running.
test_start_returns_without_holding_the_callers_stdout() {
  local rec home root log started elapsed pending
  rec=$(new_world start-nonblocking)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  printf '%s\n' $$ > "$home/state/.lock"

  started=$(date +%s)
  # Command substitution reads to EOF, exactly like a hook harvesting hook output.
  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=10 \
    run_stage "$home" "$root" start --locked 1 --harvest-pid $$ >/dev/null
  elapsed=$(( $(date +%s) - started ))

  [ "$elapsed" -lt 4 ] || fail "start blocked for ${elapsed}s behind a 10s worker"
  await_worker_record "$home"
  pending=$(run_stage "$home" "$root" report)
  [ "$(printf '%s\n' "$pending" | head -1)" = "IN PROGRESS - the deferred network checks have not finished yet." ] \
    || fail "the worker was not actually still running: $pending"
  assert_contains "$pending" "Only a FAILED or otherwise actionable result arrives as a \`check: startup-network\` wake; a clean success stays silent." \
    "the pending guidance still promised a wake for clean success"
  assert_contains "$pending" "$root/bin/fm-startup-network.sh report" \
    "the pending guidance omitted the durable on-demand report path"
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the worker never published"
  assert_grep 'network=only' "$log" "the worker did not run bootstrap's network-only phase"
  pass "fm-startup-network: start returns immediately and never holds the caller's stdout open"
}

test_harvest_acknowledgement_suppresses_the_wake_and_no_claim_produces_it() {
  local rec home root log claimant output waited=0 worker_pid
  rec=$(new_world claim-handshake)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  printf '%s\n' $$ > "$home/state/.lock"

  sleep 30 &
  claimant=$!
  FM_SESSION_START_TIMEOUT=15 FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_OUT='acknowledged result' \
    run_stage "$home" "$root" start --locked 0 --harvest-pid "$claimant"
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the claimed worker never published"
  worker_pid=$(sed -n 's/^pid=//p' "$home/state/.startup-network.status")
  output=$(run_stage "$home" "$root" harvest --pid "$claimant")
  assert_contains "$output" "acknowledged result" \
    "harvest did not print the finished result it acknowledged"
  [ -s "$home/state/.startup-network.delivered" ] \
    || fail "harvest did not durably acknowledge the result it printed"
  kill "$claimant" 2>/dev/null || true
  wait "$claimant" 2>/dev/null || true
  while kill -0 "$worker_pid" 2>/dev/null && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  ! kill -0 "$worker_pid" 2>/dev/null \
    || fail "the worker did not settle after harvest acknowledged its result"
  [ ! -s "$home/state/.wake-queue" ] \
    || fail "a result harvest acknowledged also queued a wake: $(cat "$home/state/.wake-queue")"

  # Harvest releases that claim, so the NEXT publication has nobody to print it.
  # An actionable result (not a clean success) is used here so the assertion
  # stays about the claim mechanism; test_a_successful_result_never_queues_a_wake
  # below owns the separate "a clean success never wakes" contract.
  assert_absent "$home/state/.startup-network.claim" "harvest did not release its own claim"
  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_OUT='MISSING: some-tool (install: brew install some-tool)' \
    run_stage "$home" "$root" run --locked 0
  assert_grep 'check	startup-network' "$home/state/.wake-queue" \
    "an unclaimed actionable result never reached the wake queue"

  : > "$home/state/.wake-queue"
  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_OUT='MISSING: some-tool (install: brew install some-tool)' \
    run_stage "$home" "$root" start --locked 0 --harvest-pid 999999999
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the dead-claim worker never published"
  wait_for_startup_network_wake "$home" || fail "the dead-claim worker never settled delivery"
  assert_grep 'check	startup-network' "$home/state/.wake-queue" \
    "a dead session's stale claim swallowed the result"
  assert_absent "$home/state/.startup-network.claim" "a dead claim was not reaped"
  pass "fm-startup-network: exactly one of the digest and the wake reports each actionable result"
}

test_a_claimant_crash_after_publish_still_queues_the_wake() {
  local rec home root log claimant
  rec=$(new_world claimant-crash)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  sleep 10 &
  claimant=$!
  # Actionable output: a clean success in this same crash window must stay
  # silent (test_a_successful_result_never_queues_a_wake owns that case).
  FM_SESSION_START_TIMEOUT=4 FM_FAKE_BOOTSTRAP_LOG="$log" \
    FM_FAKE_BOOTSTRAP_OUT='MISSING: some-tool (install: brew install some-tool)' \
    run_stage "$home" "$root" start --locked 0 --harvest-pid "$claimant"
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the crash-window worker never published"
  kill -0 "$claimant" 2>/dev/null \
    || fail "the claimant died before the worker published"
  kill "$claimant" 2>/dev/null || true
  wait "$claimant" 2>/dev/null || true
  wait_for_startup_network_wake "$home" || fail "the crash-window worker never settled delivery"
  assert_grep 'check	startup-network' "$home/state/.wake-queue" \
    "a claimant crash after publication silently lost the result"
  assert_absent "$home/state/.startup-network.delivered" \
    "an unharvested result was recorded as delivered"
  pass "fm-startup-network: a claimant crash after publication still surfaces the result"
}

test_a_report_publication_failure_is_failed_and_still_wakes() {
  local rec home root log claimant output state
  rec=$(new_world report-publication-failure)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  mkdir "$home/state/.startup-network.report"
  chmod 500 "$home/state/.startup-network.report"
  sleep 10 &
  claimant=$!

  FM_SESSION_START_TIMEOUT=4 FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_OUT='unpublishable result' \
    run_stage "$home" "$root" start --locked 0 --harvest-pid "$claimant"
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the report-publication failure never settled"
  state=$(sed -n 's/^state=//p' "$home/state/.startup-network.status")
  [ "$state" = failed ] || fail "a report-publication failure was published as $state"

  output=$(run_stage "$home" "$root" report)
  assert_contains "$output" "NETWORK_CHECKS: could not publish the deferred check report" \
    "report did not surface the report-publication failure: $output"
  output=$(run_stage "$home" "$root" harvest --pid "$claimant")
  assert_contains "$output" "NETWORK_CHECKS: could not publish the deferred check report" \
    "harvest did not surface the report-publication failure: $output"
  assert_absent "$home/state/.startup-network.delivered" \
    "harvest acknowledged a result whose report was not published"
  wait_for_startup_network_wake "$home" || fail "the report-publication failure suppressed the wake"
  assert_grep 'check	startup-network' "$home/state/.wake-queue" \
    "the report-publication failure did not reach the wake queue"

  kill "$claimant" 2>/dev/null || true
  wait "$claimant" 2>/dev/null || true
  chmod 700 "$home/state/.startup-network.report"
  pass "fm-startup-network: a report-publication failure is failed, diagnosed, and still wakes"
}

# A clean success is not captain-facing progress (AGENTS.md section 8): it must
# never become a main-blocking wake row, whether or not a session was there to
# claim and harvest it inline. The result stays durable and readable through
# `report` either way.
test_a_successful_result_never_queues_a_wake() {
  local rec home root log claimant report
  rec=$(new_world successful-result-silent)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  sleep 10 &
  claimant=$!
  FM_SESSION_START_TIMEOUT=4 FM_FAKE_BOOTSTRAP_LOG="$log" \
    run_stage "$home" "$root" start --locked 0 --harvest-pid "$claimant"
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the unclaimed successful worker never published"
  kill "$claimant" 2>/dev/null || true
  wait "$claimant" 2>/dev/null || true

  # Give the same settling window the crash-window test uses, then confirm no
  # wake ever lands - not a race that just hasn't finished yet.
  sleep 1
  [ ! -s "$home/state/.wake-queue" ] \
    || fail "a clean successful network-checks result queued a main-blocking wake: $(cat "$home/state/.wake-queue")"
  report=$(run_stage "$home" "$root" report)
  assert_contains "$report" "(silent - no problems found)" \
    "a successful result was not durably readable through report: $report"

  # Bootstrap itself explicitly types completed benign work as BOOTSTRAP_INFO.
  # That producer-owned no-action record is durable but must remain just as
  # quiet as a fully silent success.
  FM_FAKE_BOOTSTRAP_LOG="$log" \
    FM_FAKE_BOOTSTRAP_OUT='BOOTSTRAP_INFO: fixture completed benign work' \
    run_stage "$home" "$root" run --locked 0
  [ ! -s "$home/state/.wake-queue" ] \
    || fail "a BOOTSTRAP_INFO-only success queued a main-blocking wake: $(cat "$home/state/.wake-queue")"
  report=$(run_stage "$home" "$root" report)
  assert_contains "$report" "BOOTSTRAP_INFO: fixture completed benign work" \
    "the completed no-action fact was not retained in the durable report"

  pass "fm-startup-network: silent and explicitly informational successes never queue a main-blocking wake"
}

# The FAILED/actionable half of the same contract, paired with the success
# test above: an actionable report (here, a MISSING: line bootstrap-diagnostics
# would load a skill for) still reaches the wake queue even when unclaimed.
test_an_actionable_successful_result_still_queues_a_wake() {
  local rec home root log claimant
  rec=$(new_world actionable-result-wakes)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  sleep 10 &
  claimant=$!
  FM_SESSION_START_TIMEOUT=4 FM_FAKE_BOOTSTRAP_LOG="$log" \
    FM_FAKE_BOOTSTRAP_OUT='MISSING: some-tool (install: brew install some-tool)' \
    run_stage "$home" "$root" start --locked 0 --harvest-pid "$claimant"
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the unclaimed actionable worker never published"
  kill "$claimant" 2>/dev/null || true
  wait "$claimant" 2>/dev/null || true

  wait_for_startup_network_wake "$home" \
    || fail "an actionable successful (state=done) result never queued a wake"
  assert_grep 'check	startup-network' "$home/state/.wake-queue" \
    "an actionable result did not reach the wake queue"

  pass "fm-startup-network: an actionable state=done report still queues a wake"
}

test_deferred_invalid_secondmate_markers_queue_durable_findings() {
  local kind rec home root log target report err seq generation
  for kind in malformed symlink; do
    rec=$(new_world "deferred-invalid-marker-$kind")
    IFS='|' read -r home root log <<EOF
$rec
EOF
    printf '%s\n' $$ > "$home/state/.lock"
    if [ "$kind" = malformed ]; then
      printf '../other-home\n' > "$home/.fm-secondmate-home"
    else
      target="$TMP_ROOT/deferred-invalid-marker-$kind/marker-target"
      printf 'mate\n' > "$target"
      ln -s "$target" "$home/.fm-secondmate-home"
    fi

    FM_FAKE_BOOTSTRAP_LOG="$log" run_stage "$home" "$root" run --locked 1
    assert_grep $'check\tinactive-reconcile-diagnostic:invalid-secondmate-home\t' "$home/state/.wake-queue" \
      "$kind marker finding was swallowed by the deferred startup stage"
    report=$(run_stage "$home" "$root" report)
    assert_contains "$report" "(silent - no problems found)" \
      "$kind marker fixture unexpectedly depended on the network report"

    err="$home/drain.err"
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$DRAIN" >/dev/null 2> "$err"
    seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$err")
    generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
    [ -n "$seq" ] && [ -n "$generation" ] \
      || fail "$kind marker wake did not issue a durable acknowledgement"
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$DRAIN" \
      --ack-through "$seq" --recovery-generation "$generation" >/dev/null
    assert_no_grep 'inactive-reconcile-diagnostic:invalid-secondmate-home' "$home/state/.wake-queue" \
      "$kind marker wake could not be acknowledged"
  done
  pass "fm-startup-network: deferred invalid secondmate markers produce durable wakes"
}

# The worker outlives the command that launched it. If another session took the
# lock meanwhile, running the mutating sweeps would sweep underneath that
# session, so they are refused - and the refusal is reported, not silent.
test_mutating_sweeps_are_refused_when_the_lock_changed_hands() {
  local rec home root log report
  rec=$(new_world lock-changed)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  printf '222222\n' > "$home/state/.lock"

  FM_FAKE_BOOTSTRAP_LOG="$log" run_stage "$home" "$root" run --locked 1 --lock-pid 111111
  assert_grep 'network=only detect_only=1' "$log" \
    "the worker ran mutating sweeps for a lock it no longer held"
  report=$(run_stage "$home" "$root" report)
  assert_contains "$report" "NETWORK_CHECKS: the fleet lock was no longer held" \
    "the downgrade to a read-only probe was not reported"

  # A detached start captures the lock itself and may run the mutating phase.
  : > "$log"
  printf '%s\n' $$ > "$home/state/.lock"
  FM_FAKE_BOOTSTRAP_LOG="$log" run_stage "$home" "$root" start --locked 1 --harvest-pid $$
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the lock-authorized worker never published"
  assert_grep 'network=only detect_only=0' "$log" \
    "the worker refused sweeps for the very session that still holds the lock"
  pass "fm-startup-network: manual callers cannot forge mutation authority"
}

# The unbounded per-call network work is exactly what could wedge a startup. The
# stage carries one aggregate bound, and hitting it is an actionable line.
test_the_stage_bound_is_reported_not_swallowed() {
  local rec home root log report
  rec=$(new_world stage-bound)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  printf '%s\n' $$ > "$home/state/.lock"

  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=20 FM_STARTUP_NETWORK_TIMEOUT=2 \
    run_stage "$home" "$root" start --locked 1 --harvest-pid $$
  run_stage "$home" "$root" harvest --pid $$ >/dev/null
  FM_STARTUP_NETWORK_TIMEOUT=2 run_stage "$home" "$root" wait 10 >/dev/null \
    || fail "the bounded worker never settled"
  report=$(run_stage "$home" "$root" report)
  assert_contains "$report" "NETWORK_CHECKS: hit the 2s bound before finishing" \
    "a wedged deferred stage was not reported: $report"
  assert_contains "$report" "fm-startup-network.sh run --locked 1" \
    "the timeout line did not say how to rerun the stage"
  wait_for_startup_network_wake "$home" || fail "the timed-out worker never settled delivery"
  assert_grep 'check	startup-network' "$home/state/.wake-queue" \
    "a timed-out stage did not surface to the agent"
  pass "fm-startup-network: an aggregate bound turns a wedged sweep into an actionable line"
}

# A worker killed before publication leaves a `running` record behind.
# That record must read as work to redo, not as work still in flight.
test_an_abandoned_run_reads_as_needing_a_rerun() {
  local rec home root log report
  rec=$(new_world abandoned)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  cat > "$home/state/.startup-network.status" <<EOF
state=running
pid=999999999
started=$(date +%s)
locked=1
phases=probe,sweeps
EOF

  report=$(run_stage "$home" "$root" report)
  assert_contains "$report" "NETWORK_CHECKS: the deferred check worker stopped before publishing" \
    "an abandoned run still read as in progress: $report"
  assert_contains "$report" "dead-secondmate relaunch" \
    "the abandoned run did not name the checks that never completed"

  # A record older than the whole aggregate bound is abandoned even when its pid
  # happens to be alive again, so "in progress" can never become permanent.
  cat > "$home/state/.startup-network.status" <<EOF
state=running
pid=$$
started=$(( $(date +%s) - 400 ))
locked=1
phases=probe,sweeps
EOF
  assert_contains "$(FM_STARTUP_NETWORK_TIMEOUT=10 run_stage "$home" "$root" report)" \
    "NETWORK_CHECKS: the deferred check worker stopped before publishing" \
    "a record that outlived the stage bound still read as in progress"
  pass "fm-startup-network: an abandoned run reports as needing a rerun, never as in progress forever"
}

test_locked_start_is_not_satisfied_by_an_inflight_probe() {
  local rec home root log waited=0
  rec=$(new_world probe-then-locked)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  printf '%s\n' $$ > "$home/state/.lock"
  printf '../other-home\n' > "$home/.fm-secondmate-home"

  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=6 \
    run_stage "$home" "$root" start --locked 0 --harvest-pid $$
  while ! grep -Fq 'detect_only=1' "$log" 2>/dev/null && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  assert_grep 'network=only detect_only=1' "$log" \
    "the probe-only worker was not in flight before the locked request"

  FM_FAKE_BOOTSTRAP_LOG="$log" \
    run_stage "$home" "$root" start --locked 1 --harvest-pid $$
  run_stage "$home" "$root" wait 30 >/dev/null \
    || fail "the locked request never published"
  assert_grep 'network=only detect_only=0' "$log" \
    "the in-flight probe-only worker suppressed the locked sweeps"
  assert_grep $'check\tinactive-reconcile-diagnostic:invalid-secondmate-home\t' "$home/state/.wake-queue" \
    "the in-flight probe-only worker suppressed the locked inactive scan"
  pass "fm-startup-network: locked requests supersede in-flight probe-only workers"
}

# Two session opens in quick succession must not run the same mutating sweeps
# concurrently against each other.
test_start_is_single_flight() {
  local rec home root log runs
  rec=$(new_world single-flight)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  printf '%s\n' $$ > "$home/state/.lock"

  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=6 \
    run_stage "$home" "$root" start --locked 1 --harvest-pid $$
  await_worker_record "$home"
  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=6 \
    run_stage "$home" "$root" start --locked 1 --harvest-pid $$
  run_stage "$home" "$root" wait 40 >/dev/null || fail "the worker never published"

  runs=$(grep -c 'network=only' "$log" || true)
  [ "$runs" -eq 1 ] || fail "a second start launched a competing worker ($runs runs): $(cat "$log")"
  pass "fm-startup-network: a second start never launches a competing worker"
}

test_start_reserves_its_generation_before_returning() {
  local rec home root log report
  rec=$(new_world generation-reservation)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  cat > "$home/state/.startup-network.status" <<EOF
state=done
pid=999999999
started=1
finished=2
rc=0
locked=0
phases=probe
generation=old
lock_pid=
EOF
  printf 'old result\n' > "$home/state/.startup-network.report"

  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=5 \
    run_stage "$home" "$root" start --locked 0 --harvest-pid $$
  report=$(run_stage "$home" "$root" harvest --pid $$)
  assert_contains "$report" "IN PROGRESS" \
    "harvest exposed the previous generation after a new start returned: $report"
  assert_not_contains "$report" "old result" \
    "harvest printed a stale generation's report"
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the reserved generation never published"
  pass "fm-startup-network: start atomically reserves the generation harvest observes"
}

test_new_lock_owner_does_not_reuse_the_previous_owners_worker() {
  local rec home root log generation_one generation_two next_owner
  rec=$(new_world owner-handoff)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  printf '%s\n' $$ > "$home/state/.lock"
  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=6 \
    run_stage "$home" "$root" start --locked 1 --harvest-pid $$
  generation_one=$(sed -n 's/^generation=//p' "$home/state/.startup-network.status")

  next_owner=$("$FM_TEST_REAL_PS" -o ppid= -p $$ | tr -d ' ')
  printf '%s\n' "$next_owner" > "$home/state/.lock"
  FM_FAKE_HARNESS_PID_OVERRIDE="$next_owner" FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=1 \
    run_stage "$home" "$root" start --locked 1 --harvest-pid $$
  generation_two=$(sed -n 's/^generation=//p' "$home/state/.startup-network.status")
  [ "$generation_one" != "$generation_two" ] \
    || fail "the new lock owner reused the previous owner's generation"
  run_stage "$home" "$root" wait 30 >/dev/null || fail "the new owner's generation never published"
  pass "fm-startup-network: a new lock owner gets a distinct worker generation"
}

test_lock_takeover_stays_read_only_while_a_sweep_holds_the_lease() {
  local rec home root log next_owner new_owner out rc started elapsed waited=0
  rec=$(new_world sweep-lease)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  printf '%s\n' $$ > "$home/state/.lock"
  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=6 \
    run_stage "$home" "$root" start --locked 1 --harvest-pid $$
  while [ ! -s "$log" ] && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -s "$log" ] || fail "the mutating sweep never started"

  next_owner=$("$FM_TEST_REAL_PS" -o ppid= -p $$ | tr -d ' ')
  started=$(date +%s)
  rc=0
  out=$(PATH="$root/bin:$PATH" FM_FAKE_HARNESS_PID="$next_owner" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$root/bin/fm-lock.sh" 2>&1) || rc=$?
  elapsed=$(( $(date +%s) - started ))
  [ "$rc" -ne 0 ] || fail "lock takeover succeeded while the prior sweep was mutating"
  [ "$elapsed" -lt 4 ] || fail "lock takeover blocked ${elapsed}s behind deferred network work"
  assert_contains "$out" "operate read-only" \
    "a lease-blocked takeover did not fail closed to read-only: $out"
  [ "$(cat "$home/state/.lock")" = "$$" ] \
    || fail "the lease-blocked takeover replaced the prior owner"

  run_stage "$home" "$root" wait 30 >/dev/null || fail "the leased sweep never settled"
  out=$(PATH="$root/bin:$PATH" FM_FAKE_HARNESS_PID="$next_owner" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$root" "$root/bin/fm-lock.sh" 2>&1) \
    || fail "lock takeover still failed after the sweep released its lease"
  new_owner=$(cat "$home/state/.lock")
  assert_contains "$out" "lock acquired: harness pid $new_owner" \
    "the fleet lock did not record the harness owner reported by acquisition"
  [ "$new_owner" != "$$" ] || fail "the prior harness still owned the lock after takeover"
  pass "fm-startup-network: fleet-lock takeover cannot overlap a mutating sweep"
}

# Every record carries a start offset from ONE origin, so the artifact reads as a
# timeline and not just a bag of durations. The origin is normally exported by the
# stage, but a process that starts recording without one has to adopt an origin
# and KEEP it: recomputing it per record would silently flatten every offset to
# zero and lose the ordering the artifact exists to show. Driven with explicit
# start stamps so the assertion does not depend on the host clock's resolution.
test_records_share_one_origin_so_offsets_form_a_timeline() {
  local dir log offsets count second third
  dir="$TMP_ROOT/timing-origin"
  mkdir -p "$dir"
  log="$dir/timings.tsv"

  (
    # shellcheck source=bin/fm-timing-lib.sh
    . "$ROOT/bin/fm-timing-lib.sh"
    unset FM_TIMING_EPOCH_MS
    FM_TIMING_LOG=$log
    export FM_TIMING_LOG
    base=$(fm_timing_now_ms)
    fm_timing_record phase first "$base"
    fm_timing_record phase second "$(( base + 5000 ))"
    fm_timing_record phase third "$(( base + 9000 ))"
  )

  # The origin lands within the first record, so that record's own offset rounds
  # to zero; what proves the origin was KEPT is that the later records are spaced
  # by exactly the interval they were given. Recomputing the origin per record
  # would report every one of them as zero.
  offsets=$(awk -F'\t' '$1 == "v1" { print $4 }' "$log")
  count=$(printf '%s\n' "$offsets" | grep -c .)
  second=$(printf '%s\n' "$offsets" | sed -n 2p)
  third=$(printf '%s\n' "$offsets" | sed -n 3p)
  [ "$count" -eq 3 ] || fail "expected three records, got: $offsets"
  [ "$second" -gt 0 ] && [ "$third" -gt "$second" ] \
    || fail "records did not share one origin - offsets were: $offsets"
  [ "$(( third - second ))" -eq 4000 ] \
    || fail "offsets did not preserve the interval between records: $offsets"
  pass "fm-startup-network: timing records share one origin so their offsets form a timeline"
}

# The whole point of the artifact is that it is FREE until someone asks for it.
# `harvest` is what composes a session start's NETWORK CHECKS section, so a
# timing line leaking into it would be a change to every startup's output; only
# the on-demand `report` may print them.
test_timings_are_published_and_only_the_on_demand_report_prints_them() {
  local rec home root log report_out harvest_out
  rec=$(new_world timings-published)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  printf '%s\n' $$ > "$home/state/.lock"

  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_OUT='sweep finding' \
    FM_FAKE_TIMING_PHASE=fleet-sync FM_FAKE_TIMING_DETAIL=dotfiles-private \
    run_stage "$home" "$root" run --locked 1

  assert_present "$home/state/.startup-network.timings" \
    "a finished run published no timing record"
  assert_grep 'fleet-sync' "$home/state/.startup-network.timings" \
    "the stage did not publish what the sweep recorded"
  assert_grep 'stage	network-checks' "$home/state/.startup-network.timings" \
    "the stage did not record its own bounded total"

  report_out=$(run_stage "$home" "$root" report)
  assert_contains "$report_out" "sweep finding" "report stopped printing the sweep result"
  assert_contains "$report_out" "TIMINGS" "report did not print the per-step timings"
  assert_contains "$report_out" "fleet-sync dotfiles-private" \
    "report did not attribute the elapsed time to the clone that spent it"
  assert_contains "$report_out" "slowest:" "report did not surface the slowest steps"

  harvest_out=$(run_stage "$home" "$root" harvest --pid $$)
  assert_contains "$harvest_out" "sweep finding" "harvest stopped printing the sweep result"
  assert_not_contains "$harvest_out" "TIMINGS" \
    "the timings leaked into the session-start digest section"
  assert_not_contains "$harvest_out" "slowest:" \
    "the timings leaked into the session-start digest section"
  pass "fm-startup-network: timings are durable and printed only on demand"
}

# A run that hit the bound is exactly the run worth attributing, so whatever the
# killed sweeps managed to record must survive rather than being discarded with
# them.
test_a_bounded_run_still_publishes_the_timings_it_managed_to_record() {
  local rec home root log report_out
  rec=$(new_world timings-partial)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  printf '%s\n' $$ > "$home/state/.lock"

  FM_STARTUP_NETWORK_TIMEOUT=1 FM_SESSION_START_TIMEOUT=2 \
    FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=20 \
    FM_FAKE_TIMING_PHASE=secondmate-liveness FM_FAKE_TIMING_DETAIL='mate-a@host-one' \
    run_stage "$home" "$root" run --locked 1

  [ "$(sed -n 's/^state=//p' "$home/state/.startup-network.status")" = timeout ] \
    || fail "the bounded run did not record itself as timed out"
  report_out=$(run_stage "$home" "$root" report)
  assert_contains "$report_out" "hit the 1s bound" "the bound stopped being reported"
  assert_contains "$report_out" "secondmate-liveness mate-a@host-one" \
    "a timed-out run discarded the partial timings its sweeps had already recorded"
  pass "fm-startup-network: a timed-out run still publishes the partial timings it recorded"
}

# The artifact is read by a human looking at a slow startup, so it must be
# incapable of carrying an argv or a credential out of a sweep, and incapable of
# being broken by one either: a detail with tabs or newlines would otherwise
# forge extra records.
test_the_timing_artifact_cannot_carry_a_command_line_or_forge_records() {
  local rec home root log lines report_out
  rec=$(new_world timings-sanitized)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  printf '%s\n' $$ > "$home/state/.lock"

  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_TIMING_PHASE=secondmate-sync \
    FM_FAKE_TIMING_DETAIL="ssh -i /key host	v1	forged	0	9999
GITHUB_TOKEN=ghp_supersecretvalue" \
    run_stage "$home" "$root" run --locked 1

  assert_no_grep 'ghp_supersecretvalue' "$home/state/.startup-network.timings" \
    "the timing artifact carried a credential-shaped value through"
  assert_no_grep 'forged' "$home/state/.startup-network.timings" \
    "a detail containing tabs forged an extra timing record"
  assert_no_grep 'ssh' "$home/state/.startup-network.timings" \
    "the timing artifact carried a command line through"
  assert_grep 'unrecordable' "$home/state/.startup-network.timings" \
    "free text was silently dropped instead of being marked unrecordable"
  lines=$(grep -c . "$home/state/.startup-network.timings")
  [ "$lines" -eq 2 ] \
    || fail "one sweep record plus the stage total should be 2 lines, got $lines"

  # The step itself is still measured - only its untrustworthy label is refused,
  # so a sweep that mislabels itself still shows up as time spent.
  assert_grep 'secondmate-sync' "$home/state/.startup-network.timings" \
    "refusing the label also discarded the measurement"

  report_out=$(run_stage "$home" "$root" report)
  assert_not_contains "$report_out" "ghp_supersecretvalue" \
    "the rendered report printed a credential-shaped value"
  pass "fm-startup-network: the timing artifact cannot carry a command line or forge records"
}

# A live holder of the publish lock used to keep the worker spinning for as long
# as the lock stayed held - hours, when a harvest wedged on a stalled stdout -
# with every result discarded at the end. Both the wait before the sweeps and
# the publication wait after them must give up inside the worker's own budget,
# record the failure the way `report` already reads a failed stage, and wake.
test_a_held_publish_lock_cannot_keep_the_worker_alive_past_its_budget() {
  local rec home root log holder began took rc report worker waited before queued watcher
  rec=$(new_world held-lock)
  IFS='|' read -r home root log <<EOF
$rec
EOF

  # Before the sweeps: the lock is held before the worker even registers.
  hold_publish_lock "$home"
  holder=$HOLDER_PID
  began=$(date +%s)
  rc=0
  report=$(fm_run_timed 15 env PATH="$root/bin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    FM_STARTUP_NETWORK_TIMEOUT=2 FM_SESSION_START_TIMEOUT=2 FM_FAKE_BOOTSTRAP_LOG="$log" \
    "$root/bin/fm-startup-network.sh" run --locked 0 2>&1) || rc=$?
  took=$(( $(date +%s) - began ))
  [ "$rc" -ne 124 ] || fail "the worker was still waiting on the held publish lock 15s past a 2s budget"
  [ "$rc" -ne 0 ] || fail "the worker reported success without ever taking the publish lock"
  [ "$took" -le 6 ] || fail "the worker took ${took}s to give up on a 2s budget"
  [ ! -f "$log" ] || fail "the sweeps ran even though the worker could not register itself"
  assert_absent "$home/state/.startup-network.status" "an unregistered worker published a generation it never owned"
  assert_contains "$report" "still held by pid $holder" \
    "the failed record did not name the process holding the lock: $report"
  assert_contains "$report" "fm-startup-network.sh run --locked 0" \
    "the failed record did not say how to rerun the stage"
  assert_absent "$home/state/.wake-queue" "an unregistered worker queued an unowned result"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  await_pid_exit "$holder" 50 || fail "could not release the first lock holder"

  # After the sweeps: the worker registers and sweeps freely, then finds the
  # lock held when it comes to publish. What the sweeps produced must survive.
  rm -f "$home/state/.wake-queue" "$log"
  FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=2 FM_FAKE_BOOTSTRAP_OUT='PROBE_RAN' \
    FM_STARTUP_NETWORK_TIMEOUT=10 FM_SESSION_START_TIMEOUT=2 \
    run_stage "$home" "$root" start --locked 0 --harvest-pid 999999999
  await_worker_record "$home"
  worker=$(sed -n 's/^pid=//p' "$home/state/.startup-network.status")
  waited=0
  while [ ! -f "$log" ] && [ "$waited" -lt 50 ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -f "$log" ] || fail "the detached worker never started its sweep"
  hold_publish_lock "$home"
  holder=$HOLDER_PID
  before=$(cksum "$home/state/.startup-network.status")
  await_pid_exit "$worker" 100 \
    || fail "the worker was still alive 10s after its sweep finished against a held publish lock (2s delivery budget)"
  assert_equals "$before" "$(cksum "$home/state/.startup-network.status")" 'publication timeout wrote shared status without its lock'
  assert_absent "$home/state/.startup-network.report" 'publication timeout wrote a shared report without its lock'
  assert_absent "$home/state/.wake-queue" 'publication timeout queued a result without its lock'
  report=$(run_stage "$home" "$root" report)
  assert_contains "$report" "PROBE_RAN" \
    "the sweep output was discarded when publication found the lock held: $report"
  assert_contains "$report" "still held by pid $holder" \
    "the unpublished result did not name the process holding the lock"
  assert_contains "$report" 'publication is pending' 'the retained failure did not explain its unpublished state'
  run_stage "$home" "$root" reconcile || fail 'busy publication reconciliation failed'
  assert_equals "$before" "$(cksum "$home/state/.startup-network.status")" 'busy reconciliation changed the current status'
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  printf '#!/usr/bin/env bash\nexit 1\n' > "$root/bin/tmux"
  chmod +x "$root/bin/tmux"
  fm_test_track_watcher_state "$home/state"
  PATH="$root/bin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_BACKEND=tmux \
    FM_WATCH_HANDLING_SUCCESSOR=1 FM_POLL=.1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch.sh" > "$home/watch.out" 2> "$home/watch.err" &
  watcher=$!
  fm_test_track_child "$watcher" kill
  await_pid_exit "$watcher" 100 || fail "watcher did not reconcile the retained result: $(cat "$home/watch.err")"
  wait "$watcher" || fail "watcher could not deliver the retained result: $(cat "$home/watch.err")"
  assert_contains "$(cat "$home/watch.out")" 'check: startup-network' 'watcher did not deliver the retained startup failure'
  [ "$(sed -n 's/^state=//p' "$home/state/.startup-network.status")" = failed ] \
    || fail "a worker that could not publish did not record a failed stage"
  assert_grep 'check	startup-network' "$home/state/.wake-queue" \
    "a result that could not be published under the lock did not surface to the agent"
  report=$(run_stage "$home" "$root" report)
  assert_contains "$report" PROBE_RAN 'promotion lost the failed sweep output'
  queued=$(cksum "$home/state/.wake-queue")
  run_stage "$home" "$root" reconcile || fail 'completed reconciliation was not idempotent'
  assert_equals "$queued" "$(cksum "$home/state/.wake-queue")" 'reconciliation duplicated its failure notification'
  pass "fm-startup-network: a held publish lock bounds the worker, retains its failure, and delivers once after release"
}

test_publication_timeout_cannot_write_after_generation_observation() {
  local rec home root log worker holder before real_sed i rc
  rec=$(new_world publication-observation-race)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  real_sed=$(command -v sed)
  cat > "$root/bin/sed" <<'SH'
#!/usr/bin/env bash
if [ "$#" -eq 3 ] && [ "$2" = 's/^generation=//p' ] && [ -e "$FM_HOME/block-generation-read" ]; then
  observed=$("$FM_TEST_REAL_SED" "$@")
  if mkdir "$FM_HOME/generation-read-claimed" 2>/dev/null; then
    : > "$FM_HOME/generation-read-ready"
    for ((i=0;i<750;i++)); do
      if [ -e "$FM_HOME/generation-read-release" ]; then
        printf '%s\n' "$observed"
        exit 0
      fi
      sleep .02
    done
    exit 74
  fi
fi
exec "$FM_TEST_REAL_SED" "$@"
SH
  chmod +x "$root/bin/sed"
  FM_TEST_REAL_SED="$real_sed" FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_SLEEP=1 \
    FM_SESSION_START_TIMEOUT=1 run_stage "$home" "$root" run --locked 0 > "$home/old.out" 2>&1 &
  worker=$!
  fm_test_track_child "$worker" kill
  for ((i=0;i<150;i++)); do [ ! -s "$log" ] || break; sleep .02; done
  [ -s "$log" ] || fail 'old publication probe never entered its sweep'
  hold_publish_lock "$home"
  holder=$HOLDER_PID
  : > "$home/block-generation-read"
  for ((i=0;i<250;i++)); do [ ! -e "$home/generation-read-ready" ] || break; sleep .02; done
  [ -e "$home/generation-read-ready" ] || fail 'old publication did not reach its generation observation barrier'
  kill -TERM "$holder"
  wait "$holder" 2>/dev/null || true
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$STATE/.startup-network.lock" || exit 1
    trap '\''fm_lock_release "$STATE/.startup-network.lock"'\'' EXIT
    printf "state=done\ngeneration=replacement\npid=0\n" > "$STATE/.startup-network.status"
    for name in report timings delivered; do printf "replacement-%s\n" "$name" > "$STATE/.startup-network.$name"; done
  ' _ "$ROOT" || fail 'replacement could not publish under its lock'
  before=$(cksum "$home/state/.startup-network.status" "$home/state/.startup-network.report" "$home/state/.startup-network.timings" "$home/state/.startup-network.delivered")
  : > "$home/generation-read-release"
  rc=0
  wait "$worker" || rc=$?
  [ "$rc" -ne 0 ] || fail 'old blocked publication reported success'
  assert_equals "$before" "$(cksum "$home/state/.startup-network.status" "$home/state/.startup-network.report" "$home/state/.startup-network.timings" "$home/state/.startup-network.delivered")" 'old publication overwrote replacement after its generation observation'
  assert_absent "$home/state/.wake-queue" 'old publication queued an obsolete failure after replacement'
  pass 'publication timeout cannot mutate a replacement installed after its generation observation'
}

test_harvest_does_not_inline_a_packet_completed_after_its_promotion_check() {
  local rec home root log generation started pending real_cat harvest i
  rec=$(new_world late-inline-packet)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  generation=late-inline-packet
  started=$(date +%s)
  printf 'state=running\ngeneration=%s\npid=%s\nstarted=%s\nphases=probe\nlocked=0\n' "$generation" "$$" "$started" > "$home/state/.startup-network.status"
  printf '%s\t%s\n' "$generation" "$$" > "$home/state/.startup-network.claim"
  pending="$home/state/.startup-network-unpublished-$generation"
  mkdir -m 700 "$pending"
  printf 'LATE_PRIVATE_ACTIONABLE\n' > "$pending/report"
  printf 'failed\nprobe\n0\n%s\n124\n' "$started" > "$pending/metadata"
  real_cat=$(command -v cat)
  FM_REAL_CAT=$real_cat
  export FM_REAL_CAT
  cat > "$root/bin/cat" <<'SH'
#!/usr/bin/env bash
if [ "$#" -eq 1 ] && [ "$1" = "$FM_HOME/state/.startup-network.claim" ]; then
  : > "$FM_HOME/harvest-claim-read"
  for ((i=0;i<750;i++)); do
    [ ! -e "$FM_HOME/harvest-claim-release" ] || exec "$FM_TEST_REAL_CAT" "$@"
    sleep .02
  done
  exit 74
fi
exec "$FM_TEST_REAL_CAT" "$@"
SH
  chmod +x "$root/bin/cat"
  FM_TEST_REAL_CAT="$real_cat" run_stage "$home" "$root" harvest --pid "$$" > "$home/harvest.out" 2> "$home/harvest.err" &
  harvest=$!
  fm_test_track_child "$harvest" kill
  for ((i=0;i<150;i++)); do [ ! -e "$home/harvest-claim-read" ] || break; sleep .02; done
  [ -e "$home/harvest-claim-read" ] || fail 'harvest never reached its locked claim-read barrier'
  : > "$pending/ready"
  : > "$home/harvest-claim-release"
  wait "$harvest" || fail "harvest failed at the packet handoff: $(cat "$home/harvest.err")"
  rm -f "$root/bin/cat"
  assert_not_contains "$(cat "$home/harvest.out")" LATE_PRIVATE_ACTIONABLE 'harvest printed a private result it could not acknowledge'
  assert_absent "$home/state/.startup-network.delivered" 'unfinished harvest acknowledged an unpromoted result'
  run_stage "$home" "$root" reconcile || fail 'late completed packet did not reconcile'
  [ -f "$home/state/.wake-queue" ] || fail "late packet missing wake: state=$(cat "$home/state/.startup-network.status"); packet=$(ls "$pending" 2>/dev/null); harvest=$(cat "$home/harvest.out")"
  assert_grep $'check\tstartup-network' "$home/state/.wake-queue" 'late private result was not delivered after harvest'
  assert_contains "$(run_stage "$home" "$root" report)" LATE_PRIVATE_ACTIONABLE 'late promotion lost the actionable private result'
  pass 'harvest never prints an unpromoted private packet that completes after its locked check'
}

test_watcher_ignores_superseded_private_packets() {
  local rec home root log pending started before watcher i count real_bash
  rec=$(new_world obsolete-private-packet)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  started=$(date +%s)
  printf 'state=done\ngeneration=replacement\npid=0\n' > "$home/state/.startup-network.status"
  for name in report timings delivered; do printf 'replacement-%s\n' "$name" > "$home/state/.startup-network.$name"; done
  pending="$home/state/.startup-network-unpublished-obsolete"
  mkdir -m 700 "$pending"
  printf 'OBSOLETE_PRIVATE_FAILURE\n' > "$pending/report"
  printf 'failed\nprobe\n0\n%s\n124\n' "$started" > "$pending/metadata"
  : > "$pending/ready"
  before=$(cksum "$home/state/.startup-network.status" "$home/state/.startup-network.report" "$home/state/.startup-network.timings" "$home/state/.startup-network.delivered" "$pending/report" "$pending/metadata")
  real_bash=$(command -v bash)
  cat > "$root/bin/bash" <<'PY'
#!/usr/bin/env python3
import os,sys
with open(os.environ['FM_TEST_SHELL_CALLS'],'a') as stream:
    stream.write(os.path.basename(sys.argv[1])+'\n' if len(sys.argv)>1 else '\n')
os.execv(os.environ['FM_TEST_REAL_BASH'],[os.environ['FM_TEST_REAL_BASH'],*sys.argv[1:]])
PY
  printf '#!/usr/bin/env bash\nexit 1\n' > "$root/bin/tmux"
  chmod +x "$root/bin/bash" "$root/bin/tmux"
  fm_test_track_watcher_state "$home/state"
  PATH="$root/bin:$PATH" FM_TEST_REAL_BASH="$real_bash" FM_TEST_SHELL_CALLS="$home/shell-calls" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_BACKEND=tmux FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_POLL=.1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch.sh" > "$home/watch.out" 2> "$home/watch.err" &
  watcher=$!
  fm_test_track_child "$watcher" kill
  count=0
  for ((i=0;i<100;i++)); do
    count=$(grep -c '^fm-ready-review.sh$' "$home/shell-calls" 2>/dev/null || true)
    [ "${count:-0}" -lt 3 ] || break
    sleep .1
  done
  [ "${count:-0}" -ge 3 ] || fail "watcher did not complete repeated observations: $(cat "$home/watch.err")"
  kill -TERM "$watcher"
  wait "$watcher" 2>/dev/null || true
  assert_no_grep fm-startup-network.sh "$home/shell-calls" 'watcher repeatedly launched publication for a superseded private packet'
  assert_equals "$before" "$(cksum "$home/state/.startup-network.status" "$home/state/.startup-network.report" "$home/state/.startup-network.timings" "$home/state/.startup-network.delivered" "$pending/report" "$pending/metadata")" 'obsolete packet polling changed replacement results or retained evidence'
  assert_absent "$home/state/.wake-queue" 'obsolete private failure queued a replacement wake'
  pass 'watcher keeps obsolete packet evidence without promoting it or repeatedly starting a publisher'
}

test_nested_wake_locks_share_delivery_deadline() {
  local lock rec home root log worker holder report generation pending before
  for lock in .wake-queue.lock .watcher-down.lock; do
    rec=$(new_world "nested-$lock")
    IFS='|' read -r home root log <<EOF
$rec
EOF
    hold_publish_lock "$home" "$lock"
    holder=$HOLDER_PID
    FM_FAKE_BOOTSTRAP_LOG="$log" FM_FAKE_BOOTSTRAP_OUT=ACTIONABLE FM_STARTUP_NETWORK_TIMEOUT=10 FM_SESSION_START_TIMEOUT=2 \
      run_stage "$home" "$root" start --locked 0 --harvest-pid 999999999
    await_worker_record "$home"
    worker=$(sed -n 's/^pid=//p' "$home/state/.startup-network.status")
    generation=$(sed -n 's/^generation=//p' "$home/state/.startup-network.status")
    await_pid_exit "$worker" 100 || fail "nested $lock exceeded delivery deadline"
    report=$(run_stage "$home" "$root" report)
    assert_contains "$report" ACTIONABLE "nested contention discarded pending output"
    assert_absent "$home/state/.startup-network.delivered" "contention falsely acknowledged output"
    pending="$home/state/.startup-network-unpublished-$generation"
    assert_present "$pending/ready" "nested $lock lost the original generation's retry packet"
    before=$(cksum "$log" "$home/state/.startup-network.report")
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    run_stage "$home" "$root" reconcile || fail "released $lock prevented original-generation reconciliation"
    wait_for_startup_network_wake "$home" 100 || fail "released $lock prevented wake publication"
    assert_equals "$generation" "$(sed -n 's/^generation=//p' "$home/state/.startup-network.status")" 'reconciliation replaced the original generation'
    assert_equals "$before" "$(cksum "$log" "$home/state/.startup-network.report")" 'reconciliation reran the stage or changed its report'
    assert_absent "$pending" 'successful retry retained a completed packet'
    run_stage "$home" "$root" reconcile || fail 'idempotent reconciliation failed'
    assert_equals 1 "$(awk -F '\t' '$3 == "check" && $4 == "startup-network" {n++} END {print n+0}' "$home/state/.wake-queue")" 'original result did not deliver exactly once'
    mkdir -p "$pending"
    printf 'done\nprobe\n0\n1\n0\n' > "$pending/metadata"
    printf obsolete > "$pending/report"
    : > "$pending/ready"
    printf 'state=done\ngeneration=replacement\nreport_published=1\n' > "$home/state/.startup-network.status"
    before=$(cksum "$home/state/.startup-network.status" "$home/state/.startup-network.report" "$home/state/.wake-queue")
    run_stage "$home" "$root" reconcile || fail 'stale-packet reconciliation failed'
    assert_equals "$before" "$(cksum "$home/state/.startup-network.status" "$home/state/.startup-network.report" "$home/state/.wake-queue")" 'obsolete packet changed the replacement or queued another wake'
  done
  pass 'startup wake queue and recovery locks share the remaining delivery deadline'
}

test_admission_observation_preserves_worker() {
  local mode=$1 rec home root log starter worker i rc real_cat FM_REAL_CAT
  rec=$(new_world "admission-$mode")
  IFS='|' read -r home root log <<< "$rec"
  real_cat=$(command -v cat)
  cat > "$root/bin/cat" <<'SH'
#!/usr/bin/env bash
if [ "$#" = 1 ] && [ "$1" = "$FM_HOME/state/.startup-network.status" ] && [ -f "$FM_HOME/starter" ]; then
  IFS= read -r starter < "$FM_HOME/starter"
  if [ "$PPID" = "$starter" ] && mkdir "$FM_HOME/ack-read" 2>/dev/null; then
    : > "$FM_HOME/ack-ready"
    exec 9<> "$FM_HOME/ack-gate"
    read -r -t 15 _ <&9 || exit 74
    case "$FM_ACK_MODE" in unreadable|unknown) exit 74 ;; esac
  fi
fi
exec "$FM_REAL_CAT" "$@"
SH
  chmod +x "$root/bin/cat"
  cat > "$root/bin/fm-bootstrap.sh" <<'SH'
#!/usr/bin/env bash
kind=${FM_BOOTSTRAP_DETECT_ONLY:-0}
printf '%s\n' "$$" > "$FM_HOME/bootstrap-$kind.pid"
printf 'entered %s\n' "$kind" >> "$FM_FAKE_BOOTSTRAP_LOG"
exec 9<> "$FM_HOME/bootstrap-$kind.gate"
read -r -t 15 _ <&9 || exit 74
: > "$FM_HOME/bootstrap-$kind.settled"
SH
  chmod +x "$root/bin/fm-bootstrap.sh"
  mkfifo "$home/ack-gate" "$home/bootstrap-1.gate" "$home/bootstrap-0.gate"
  FM_REAL_CAT="$real_cat" FM_ACK_MODE="$mode" FM_FAKE_BOOTSTRAP_LOG="$log" \
    PATH="$root/bin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" FM_SESSION_START_TIMEOUT=8 \
    bash -c 'printf "%s\n" "$$" > "$FM_HOME/starter"; exec "$1" start --locked 0' _ "$root/bin/fm-startup-network.sh" > "$home/start.out" 2>&1 &
  starter=$!
  fm_test_track_child "$starter" kill
  for ((i=0;i<150;i++)); do [ ! -s "$log" ] || break; sleep .02; done
  [ -s "$log" ] || fail 'admission: bootstrap never entered'
  worker=$(sed -n 's/^pid=//p' "$home/state/.startup-network.status")
  fm_test_track_child "$worker" kill
  fm_test_track_child "$(cat "$home/bootstrap-1.pid")" kill
  [ -e "$home/ack-ready" ] || fail 'admission: caller did not reach acknowledgment barrier'
  assert_grep 'worker_started=1' "$home/state/.startup-network.status" 'admission: worker entry was not recorded before acknowledgment failure'
  if [ "$mode" = unknown ]; then
    sed '/^worker_started=/d' "$home/state/.startup-network.status" > "$home/status-without-entry"
    mv "$home/status-without-entry" "$home/state/.startup-network.status"
  fi
  if [ "$mode" = superseded ]; then
    printf '%s\n' "$$" > "$home/state/.lock"
    FM_REAL_CAT="$real_cat" FM_ACK_MODE="$mode" FM_FAKE_BOOTSTRAP_LOG="$log" run_stage "$home" "$root" start --locked 1 || fail 'admission: locked upgrade failed'
  fi
  exec 9<> "$home/ack-gate"
  printf 'release\n' >&9
  exec 9>&-
  rc=0
  wait "$starter" || rc=$?
  [ "$rc" -ne 0 ] || fail 'admission: unconfirmed entry reported success'
  kill -0 "$worker" 2>/dev/null || fail 'admission: failed acknowledgment killed an admitted cleanup owner'
  exec 9<> "$home/bootstrap-1.gate"
  printf 'release\n' >&9
  exec 9>&-
  if [ "$mode" = superseded ]; then
    for ((i=0;i<150;i++)); do [ ! -s "$home/bootstrap-0.pid" ] || break; sleep .02; done
    [ -s "$home/bootstrap-0.pid" ] || fail 'admission: upgraded bootstrap did not enter'
    fm_test_track_child "$(cat "$home/bootstrap-0.pid")" kill
    exec 9<> "$home/bootstrap-0.gate"
    printf 'release\n' >&9
    exec 9>&-
  fi
  for ((i=0;i<250;i++)); do
    [ "$(ps -o stat= -p "$worker" 2>/dev/null | tr -d ' ')" != Z ] || break
    kill -0 "$worker" 2>/dev/null || break
    sleep .02
  done
  case "$(ps -o stat= -p "$worker" 2>/dev/null)" in ''|*Z*) ;; *) fail 'admission: worker did not settle its bounded checks' ;; esac
  [ -e "$home/bootstrap-1.settled" ] || fail 'admission: probe checks were orphaned'
  if [ "$mode" = superseded ]; then
    run_stage "$home" "$root" wait 10 >/dev/null || fail 'admission: upgraded worker did not publish'
    [ -e "$home/bootstrap-0.settled" ] || fail 'admission: upgraded checks were orphaned'
  fi
  pass "startup $mode acknowledgment preserves admitted execution custody"
}

case ${FM_STARTUP_NETWORK_TEST_GROUP:-all} in
  admission-superseded|admission-unreadable|admission-unknown)
    test_admission_observation_preserves_worker "${FM_STARTUP_NETWORK_TEST_GROUP#admission-}"
    exit 0 ;;
  admission-custody)
    test_admission_observation_preserves_worker superseded
    test_admission_observation_preserves_worker unreadable
    test_admission_observation_preserves_worker unknown
    test_start_is_single_flight
    test_locked_start_is_not_satisfied_by_an_inflight_probe
    test_lock_takeover_stays_read_only_while_a_sweep_holds_the_lease
    exit 0 ;;
  nested-delivery)
    test_nested_wake_locks_share_delivery_deadline
    exit 0 ;;
  inline-packet)
    test_harvest_does_not_inline_a_packet_completed_after_its_promotion_check
    test_watcher_ignores_superseded_private_packets
    exit 0 ;;
  publication-race)
    test_publication_timeout_cannot_write_after_generation_observation
    exit 0 ;;
  pending-publication)
    test_a_held_publish_lock_cannot_keep_the_worker_alive_past_its_budget
    test_publication_timeout_cannot_write_after_generation_observation
    test_harvest_does_not_inline_a_packet_completed_after_its_promotion_check
    test_watcher_ignores_superseded_private_packets
    exit 0 ;;
esac

test_admission_observation_preserves_worker superseded
test_admission_observation_preserves_worker unreadable
test_admission_observation_preserves_worker unknown
test_wait_fails_without_a_published_stage
test_start_returns_without_holding_the_callers_stdout
test_harvest_acknowledgement_suppresses_the_wake_and_no_claim_produces_it
test_a_claimant_crash_after_publish_still_queues_the_wake
test_a_report_publication_failure_is_failed_and_still_wakes
test_a_successful_result_never_queues_a_wake
test_an_actionable_successful_result_still_queues_a_wake
test_deferred_invalid_secondmate_markers_queue_durable_findings
test_mutating_sweeps_are_refused_when_the_lock_changed_hands
test_the_stage_bound_is_reported_not_swallowed
test_an_abandoned_run_reads_as_needing_a_rerun
test_locked_start_is_not_satisfied_by_an_inflight_probe
test_start_is_single_flight
test_start_reserves_its_generation_before_returning
test_new_lock_owner_does_not_reuse_the_previous_owners_worker
test_lock_takeover_stays_read_only_while_a_sweep_holds_the_lease
test_records_share_one_origin_so_offsets_form_a_timeline
test_timings_are_published_and_only_the_on_demand_report_prints_them
test_a_bounded_run_still_publishes_the_timings_it_managed_to_record
test_the_timing_artifact_cannot_carry_a_command_line_or_forge_records
test_a_held_publish_lock_cannot_keep_the_worker_alive_past_its_budget
test_publication_timeout_cannot_write_after_generation_observation
test_harvest_does_not_inline_a_packet_completed_after_its_promotion_check
test_watcher_ignores_superseded_private_packets
echo "# fm-startup-network.test.sh: all assertions passed"


test_nested_wake_locks_share_delivery_deadline


test_superseded_worker_cannot_replace_a_completed_result() {
  local rec home root log worker holder i before rc
  rec=$(new_world completed-replacement)
  IFS='|' read -r home root log <<EOF
$rec
EOF
  env PATH="$root/bin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$root" \
    FM_STARTUP_NETWORK_TIMEOUT=5 FM_SESSION_START_TIMEOUT=1 FM_FAKE_BOOTSTRAP_SLEEP=1 \
    FM_FAKE_BOOTSTRAP_LOG="$log" "$root/bin/fm-startup-network.sh" run --locked 0 > "$home/old.out" 2>&1 &
  worker=$!
  fm_test_track_child "$worker" kill
  for ((i=0;i<100;i++)); do [ ! -s "$log" ] || break; sleep .02; done
  [ -s "$log" ] || fail 'old probe never entered the sweep'
  hold_publish_lock "$home"
  holder=$HOLDER_PID
  printf 'state=finished\ngeneration=replacement\npid=0\n' > "$home/state/.startup-network.status"
  printf replacement-report > "$home/state/.startup-network.report"
  printf replacement-timings > "$home/state/.startup-network.timings"
  printf replacement-delivery > "$home/state/.startup-network.delivered"
  before=$(cksum "$home/state/.startup-network.status" "$home/state/.startup-network.report" "$home/state/.startup-network.timings" "$home/state/.startup-network.delivered")
  rc=0
  wait "$worker" || rc=$?
  [ "$rc" -ne 0 ] || fail 'superseded probe reported successful publication'
  assert_equals "$before" "$(cksum "$home/state/.startup-network.status" "$home/state/.startup-network.report" "$home/state/.startup-network.timings" "$home/state/.startup-network.delivered")" 'superseded probe changed completed replacement files'
  assert_absent "$home/state/.wake-queue" 'superseded probe queued obsolete failure'
  kill -TERM "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  pass 'publication timeout preserves completed replacement generation, results and delivery'
}
test_superseded_worker_cannot_replace_a_completed_result
