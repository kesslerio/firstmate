#!/usr/bin/env bash
# fm-startup-network.sh - the deferred startup stage of a session start.
#
# WHY THIS EXISTS. Every external-network call a session start makes used to run
# BEFORE the digest printed, on a hook that blocks session initialization: `gh
# auth status`, the secondmate liveness and convergence sweeps (per-secondmate
# remote probes, which bootstrap runs concurrently), pending remote
# handoff delivery, and the fleet-sync fetch of every project clone. None of
# those calls is individually bounded, so one unreachable host could consume the
# whole FM_SESSION_START_TIMEOUT budget and truncate the digest outright, turning
# a slow network into a startup that never printed the work queue at all.
# This script runs exactly that work OFF the blocking path: the digest is
# composed from bounded local reads while these checks run concurrently in a
# detached worker, and their result is reported back inline when it finishes in
# time, or as a durable wake when it does not. The locked startup's bounded
# inactive-outcome scan also runs here because its local current-state reads can
# be just as slow; that scan publishes its own findings to the durable wake queue.
#
# WHAT IS PRESERVED. Nothing is dropped. bin/fm-bootstrap.sh remains the single
# owner of every network sweep and still runs all of them, unchanged, via its
# FM_BOOTSTRAP_NETWORK=only phase. bin/fm-inactive-reconcile.sh remains the
# owner of the startup scan and its separate watcher cadence. Deferral changes
# WHEN they run, not WHETHER, and three properties make the later run safe:
#   - The work is idempotent detection. A run whose report is lost (killed
#     worker, truncated digest, crashed session) loses no finding: the next run
#     re-derives the same inactive terminal child, dead secondmate, stuck clone,
#     or undelivered handoff. There is no once-only signal to miss.
#   - Results are durable and always surface. Network sweep output lands in
#     state/.startup-network.report and reaches the agent either inline in the
#     digest or, when it finishes too late for the digest to inline it, as a
#     `check: startup-network` wake. Inactive-scan findings land directly in the
#     ordinary durable wake queue. The report wakes only when the late result is
#     itself actionable (state is not "done", or bootstrap emitted something
#     other than its explicit BOOTSTRAP_INFO no-action record;
#     report_requires_wake owns that transport test). A late-finishing clean run is not captain-facing progress
#     (AGENTS.md section 8) and never becomes a wake row; it is still durable
#     in the report file for `... report` to read on demand. Only a durable
#     acknowledgement written after harvest prints the finished result
#     suppresses the wake, so a claimant that exits first cannot lose the
#     result. While the worker is still running the digest states by name what
#     is not yet confirmed.
#   - Mutation authority is leased. The worker outlives the command that launched
#     it, so it takes the same acquisition lease a new session must hold before
#     replacing a dead owner, re-checks the captured owner under that lease, and
#     holds it through the bounded mutating run. A takeover stays read-only until
#     that run settles, so old and new owners can never sweep concurrently.
#
# Usage: fm-startup-network.sh start --locked <0|1> --harvest-pid <pid>
#          Launch the detached worker and confirm command entry without waiting
#          for its checks to finish. Single-flight: a
#          running worker is reused only when its phases cover this request and,
#          for locked work, it belongs to the same lock owner. A probe-only
#          worker therefore cannot satisfy a later locked request; the later
#          request gets a distinct generation and runs the locked phases. A new
#          owner also gets a distinct generation. Entry confirmation shares the
#          bounded publication-lock budget; an unconfirmed start returns nonzero.
#          A superseded or unreadable acknowledgement is not proof of non-entry:
#          retirement requires the same current generation, worker PID, explicit
#          worker_started=0, and captured process start identity under the lock.
#          An admitted worker retains its cleanup and mutation lease until settled.
#          --locked 1 asks
#          for the inactive-outcome scan and mutating sweeps as well as the
#          read-only probe; --locked 0 asks for the probe only. --harvest-pid
#          names the session-start process
#          that will try to print the result inline, so the worker can tell
#          whether a wake is still needed.
#        fm-startup-network.sh run --locked <0|1>
#          Run the checks in the foreground and publish the result. This is what
#          `start` detaches with its private generation reservation; run it
#          directly to redo the stage by hand from the lock-owning harness.
#          Exits non-zero when the stage was refused or could not publish,
#          including a lock a live process still held at its deadline.
#        fm-startup-network.sh harvest --pid <pid>
#          Print the digest's NETWORK CHECKS section and release the inline-print
#          claim. Called by bin/fm-session-start.sh, not by hand.
#        fm-startup-network.sh report
#          Print the current state and report without changing anything, then the
#          last run's per-step elapsed times. This is the ONLY command that prints
#          those timings: `harvest` composes the session-start digest, and adding
#          diagnostic detail there would make every startup pay for a question
#          only a slow run raises.
#        fm-startup-network.sh reconcile
#          Retry a generation-owned unpublished result without waiting for a
#          busy publication lock. The watcher calls this after lock contention.
#          Prints a check wake only after its current result is durably queued.
#        fm-startup-network.sh wait [<seconds>]
#          Block until the report is published, up to <seconds> (default 120).
#          For operators and tests only; session start confirms entry but never
#          waits for the checks to finish.
#
# STATE, all under this home's state/ and gitignored with it:
#   .startup-network.status   key=value record - generation, lock_pid, state,
#                             pid, started, finished, rc, locked, phases,
#                             worker_started, and whether the report was published.
#                             The single source of truth for the current generation and
#                             its published outcome; a deferred outcome remains
#                             in that generation's private packet until promoted.
#   .startup-network.report   the sweep output, byte for byte as
#                             bin/fm-bootstrap.sh produced it, plus a
#                             NETWORK_CHECKS: line whenever the stage itself
#                             could not complete or had to downgrade.
#   .startup-network.claim    the generation and pid of a session start that
#                             intends to print the result inline; a matching live
#                             claimant gives harvest a bounded chance to finish.
#   .startup-network.delivered
#                             a durable acknowledgement that harvest printed the
#                             current finished result; only this suppresses its
#                             wake.
#   .startup-network.timings  per-step elapsed times for the last run, in
#                             bin/fm-timing-lib.sh's tab-separated format: the
#                             stage total, one record per network phase (gh auth,
#                             secondmate liveness, secondmate convergence, handoff
#                             delivery, fleet sync), one per secondmate for the
#                             remote-touching steps (id and host), and one per
#                             project clone. Published for a timed-out or failed
#                             run too, where a partial record is the answer.
#                             Diagnostic only: nothing reads it to make a
#                             decision, and losing it never downgrades a run.
#   .startup-network.lock     serializes publication, harvest acknowledgement,
#                             and the wake decision; every wait on it is bounded.
#   .startup-network-unpublished-<generation>/
#                             private report, timings and metadata retained until
#                             publication and wake delivery finish. Only the
#                             still-current generation may later publish them.
#
# The whole stage is bounded by FM_STARTUP_NETWORK_TIMEOUT (default 120s), one
# aggregate deadline covering both the inactive-outcome scan and network sweeps
# plus every lock the worker waits on before them.
# Publication and delivery are bounded the same way by FM_SESSION_START_TIMEOUT.
# A lock that a live process still holds at either deadline ends the worker with
# a failed record naming that holder and the rerun command, never a wait that
# outlives the budget with its output discarded.
# Hitting the bound is reported as an actionable NETWORK_CHECKS: line, never as
# silence. bin/fm-timeout-lib.sh remains the single owner of bounded execution.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

STATUS_FILE="$STATE/.startup-network.status"
REPORT_FILE="$STATE/.startup-network.report"
CLAIM_FILE="$STATE/.startup-network.claim"
DELIVERED_FILE="$STATE/.startup-network.delivered"
TIMINGS_FILE="$STATE/.startup-network.timings"
PUBLISH_LOCK="$STATE/.startup-network.lock"

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# fm-timing-lib.sh owns the per-step elapsed record this stage publishes beside
# its report. Recording is opt-in per run: it stays inert until cmd_run points
# FM_TIMING_LOG at a file, so nothing else that sources these scripts pays for it.
# shellcheck source=bin/fm-timing-lib.sh
. "$SCRIPT_DIR/fm-timing-lib.sh"
# fm-wake-lib.sh owns both the portable lock helpers used below and the durable
# wake queue this stage publishes into.
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"

usage() {
  sed -n '2,/^set -u$/p' "$SCRIPT_DIR/fm-startup-network.sh" | sed 's/^# \{0,1\}//; $d'
}

status_get() {  # <key>
  [ -f "$STATUS_FILE" ] || return 0
  sed -n "s/^$1=//p" "$STATUS_FILE" 2>/dev/null | tail -1
}

write_atomic() {  # <dest>, content on stdin
  local dest=$1 tmp
  tmp=$(mktemp "$dest.XXXXXX" 2>/dev/null) || return 1
  if cat > "$tmp" 2>/dev/null && mv -f "$tmp" "$dest" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  return 1
}

now() { date +%s; }

age_of() {  # <epoch> - seconds since, or empty when unreadable
  local then=$1
  case "$then" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$(( $(now) - then ))"
}

stage_budget() {
  local budget=${FM_STARTUP_NETWORK_TIMEOUT:-120}
  case "$budget" in ''|*[!0-9]*|0) budget=120 ;; esac
  printf '%s' "$budget"
}

delivery_budget() {
  local budget=${FM_SESSION_START_TIMEOUT:-120}
  case "$budget" in ''|*[!0-9]*|0) budget=120 ;; esac
  printf '%s' "$budget"
}

# Seconds left before <deadline-epoch>, never less than 1 so a bounded acquire
# still gets one real attempt after the budget is spent.
seconds_until() {  # <deadline-epoch>
  local left=$(( $1 - $(now) ))
  [ "$left" -ge 1 ] || left=1
  printf '%s' "$left"
}

# Every lock this script takes goes through here: bounded by the caller's
# remaining budget, 124 when a live holder still owns it at the deadline
# (FM_LOCK_HELD_PID names it). An unbounded wait here is what let a wedged
# harvest keep the detached worker alive for hours past its own timeout.
take_lock() {  # <lockdir> <seconds>
  fm_lock_acquire_wait_bounded "$1" "$2"
}

held_by() {  # human-readable holder of the lock the last take_lock refused
  printf 'pid %s' "${FM_LOCK_HELD_PID:-unknown}"
}

# Is a `running` record a stage that is genuinely still in flight? Two
# independent proofs are required, because either one alone can lie: a recorded
# pid can be reused by an unrelated process, and a worker killed with its process
# group (which is what a truncated digest does) leaves the record behind
# untouched. A record that outlives the stage's own aggregate bound is therefore
# treated as abandoned no matter what its pid says, which keeps "in progress"
# from becoming a permanent state.
worker_alive() {
  local pid started age
  pid=$(status_get pid)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  started=$(status_get started)
  age=$(age_of "$started")
  case "$age" in ''|*[!0-9]*) return 0 ;; esac
  [ "$age" -le "$(( $(stage_budget) + 30 ))" ]
}

# The exact phase names the digest and the report use, so "what has not been
# confirmed yet" is always answerable from the status record alone.
phase_label() {  # <phases>
  case "$1" in
    probe) printf 'GitHub authentication' ;;
    probe,sweeps) printf 'GitHub authentication, dead-secondmate relaunch, secondmate convergence, pending handoff delivery, project clone refresh with its drift reporting, and inactive terminal-outcome reconciliation' ;;
    *) printf 'the deferred network checks' ;;
  esac
}

# --- start -------------------------------------------------------------------

worker_covers_request() {  # <locked> <lock-pid>
  local locked=$1 lock_pid=$2
  [ "$locked" != 1 ] && return 0
  [ "$(status_get lock_pid)" = "$lock_pid" ] \
    && [ "$(status_get phases)" = probe,sweeps ]
}

await_worker_start() {
  local generation=$1 worker_pid=$2 deadline=$3 record key value current_generation current_pid state entered
  while :; do
    record=$(cat "$STATUS_FILE") || return 1
    current_generation='' current_pid='' state='' entered=''
    while IFS='=' read -r key value; do
      case "$key" in
        generation) current_generation=$value ;;
        pid) current_pid=$value ;;
        state) state=$value ;;
        worker_started) entered=$value ;;
      esac
    done <<< "$record"
    [ "$current_generation" = "$generation" ] && [ "$current_pid" = "$worker_pid" ] || return 1
    case "$state" in done|failed|timeout) [ "$entered" != 0 ]; return $? ;; esac
    [ "$entered" != 1 ] || return 0
    kill -0 "$worker_pid" 2>/dev/null || return 1
    [ "$(now)" -lt "$deadline" ] || return 1
    sleep .05
  done
}

retire_unentered_worker() {
  local generation=$1 worker_pid=$2 worker_start=$3 registered
  take_lock "$PUBLISH_LOCK" 1 || return 1
  if [ "$(status_get generation)" = "$generation" ] && [ "$(status_get pid)" = "$worker_pid" ] \
    && [ "$(status_get state)" = running ] && [ "$(status_get worker_started)" = 0 ] \
    && registered=$(cat "$STATUS_FILE") && write_atomic "$STATUS_FILE" <<EOF
$registered
state=failed
worker_started=0
rc=1
report_published=0
EOF
  then
    if [ -n "$worker_start" ] && [ "$(LC_ALL=C TZ=UTC ps -o lstart= -p "$worker_pid" 2>/dev/null)" = "$worker_start" ]; then
      kill "$worker_pid" 2>/dev/null || true
      wait "$worker_pid" 2>/dev/null || true
    fi
  fi
  fm_lock_release "$PUBLISH_LOCK"
}

cmd_start() {  # <locked> <harvest-pid>
  local locked=$1 harvest_pid=$2 lock_pid generation worker_pid phases started deadline worker_start
  local -a command=("$SCRIPT_DIR/fm-startup-network.sh")
  [ -z "${FM_LAB_LAUNCH_ROOT:-}" ] || command=(python3 "${FM_LAB_LAUNCH_HELPER:?lab launch helper binding is missing}" detached "$FM_LAB_LAUNCH_ROOT" "${command[@]}")
  mkdir -p "$STATE" 2>/dev/null || return 1
  # Captured HERE, at the moment the caller still holds the lock, and carried to
  # the worker: re-reading the lock later would only prove that SOME session
  # holds it, which is exactly the case this guard exists to reject.
  lock_pid=$(cat "$STATE/.lock" 2>/dev/null || true)
  if [ "$locked" = 1 ] && ! fm_session_lock_owned_by_self "$STATE"; then
    return 1
  fi

  deadline=$(( $(now) + $(delivery_budget) ))
  take_lock "$PUBLISH_LOCK" "$(seconds_until "$deadline")" || return 1
  if [ "$(status_get state)" = running ] && worker_alive \
    && worker_covers_request "$locked" "$lock_pid"; then
    # A worker whose phases cover this request is still going. Starting another
    # would duplicate its work and, for a locked request, race the same mutating
    # sweeps, so leave it alone and let harvest report its real state.
    generation=$(status_get generation)
    worker_pid=$(status_get pid)
    printf '%s\t%s\n' "$generation" "$harvest_pid" > "$CLAIM_FILE" 2>/dev/null || true
    fm_lock_release "$PUBLISH_LOCK"
    await_worker_start "$generation" "$worker_pid" "$deadline"
    return $?
  fi

  generation="$(now).$$.$harvest_pid"
  started=$(now)
  phases=probe
  [ "$locked" != 1 ] || phases=probe,sweeps
  if ! write_atomic "$STATUS_FILE" <<EOF
state=running
worker_started=0
pid=0
started=$started
locked=$locked
phases=$phases
generation=$generation
lock_pid=$lock_pid
EOF
  then
    fm_lock_release "$PUBLISH_LOCK"
    return 1
  fi

  # Detached three ways, each closing a different failure:
  #   - stdio to /dev/null, because the digest's stdout is a pipe the harness
  #     reads to EOF; a worker holding that pipe open would strand session
  #     initialization behind the very work this stage exists to take off the
  #     blocking path.
  #   - nohup, so the worker outlives the shell that launched it.
  #   - its OWN process group (monitor mode), because the caller runs inside the
  #     digest's bounded child and that bound terminates its whole process group.
  #     Sharing the group would kill the worker on a truncated startup and, worse,
  #     orphan the bootstrap child it had already launched into a separate group -
  #     leaving unbounded network work running with nothing left to bound it. Its
  #     own group means a truncated digest leaves this stage running under its own
  #     deadline, which is exactly the independence deferral is for.
  local monitor_was_on=0
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  nohup "${command[@]}" run --locked "$locked" --lock-pid "$lock_pid" \
    --generation "$generation" \
    >/dev/null 2>&1 </dev/null &
  worker_pid=$!
  worker_start=$(LC_ALL=C TZ=UTC ps -o lstart= -p "$worker_pid" 2>/dev/null || true)
  if ! write_atomic "$STATUS_FILE" <<EOF
state=running
worker_started=0
pid=$worker_pid
started=$started
locked=$locked
phases=$phases
generation=$generation
lock_pid=$lock_pid
EOF
  then
    if [ -n "$worker_start" ] && [ "$(LC_ALL=C TZ=UTC ps -o lstart= -p "$worker_pid" 2>/dev/null)" = "$worker_start" ]; then
      kill "$worker_pid" 2>/dev/null || true
      wait "$worker_pid" 2>/dev/null || true
    fi
    fm_lock_release "$PUBLISH_LOCK"
    [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
    return 1
  fi
  printf '%s\t%s\n' "$generation" "$harvest_pid" > "$CLAIM_FILE" 2>/dev/null || true
  fm_lock_release "$PUBLISH_LOCK"
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
  if ! await_worker_start "$generation" "$worker_pid" "$deadline"; then
    retire_unentered_worker "$generation" "$worker_pid" "$worker_start" || true
    printf 'NETWORK_CHECKS: deferred worker did not confirm command entry; inspect %s/bin/fm-startup-network.sh report\n' "$FM_ROOT" >&2
    return 1
  fi
  return 0
}

# --- run ---------------------------------------------------------------------

# Re-verify mutation authority immediately before the mutating sweeps: "my
# session held the lock a moment ago" is not enough for a worker that outlives
# the command which launched it.
#
# The question is deliberately "does the lock still name the session that asked
# for this work?", not "is that session still alive". The hazard being closed is
# a SECOND session sweeping concurrently. A different session can take the lock
# only after the recorded holder is dead, when bin/fm-lock.sh rewrites that pid
# with its own anchor. An unchanged value therefore proves no one else owns the sweeps, which is
# the whole guarantee. Requiring liveness instead would refuse to finish work
# nobody else has claimed, and the sweeps are idempotent, so finishing it is
# strictly better than abandoning it. A missing, unreadable, or replaced lock all
# fail closed to the read-only probe.
lock_unchanged() {  # <expected-pid>
  local expected=$1 current
  case "$expected" in ''|*[!0-9]*) return 1 ;; esac
  [ -f "$STATE/.lock" ] && [ ! -L "$STATE/.lock" ] || return 1
  current=$(cat "$STATE/.lock" 2>/dev/null) || return 1
  [ "$current" = "$expected" ]
}

# Bootstrap owns the meaning of its output protocol: silence is success,
# BOOTSTRAP_INFO is an explicit completed no-action fact, and every other line
# is a diagnostic. This delivery layer does not maintain a second semantic
# prefix list or decide what a diagnostic means; it only applies that producer-
# supplied transport type. Unknown non-empty output fails safe by waking.
report_requires_wake() {  # <state> [report-file]
  local state=$1 report=${2:-$REPORT_FILE}
  [ "$state" = "done" ] || return 0
  [ -s "$report" ] || return 1
  awk 'NF && $0 !~ /^BOOTSTRAP_INFO:/ { found=1; exit } END { exit !found }' \
    "$report" 2>/dev/null
}

queue_result_wake() {  # <state>
  FM_WAKE_APPEND_DEADLINE="$DELIVERY_DEADLINE" fm_wake_append check startup-network \
    "check: startup-network: deferred startup network checks finished ($1); read them with $FM_ROOT/bin/fm-startup-network.sh report"
}

# Bounded by DELIVERY_DEADLINE, which publish() sets from the delivery budget.
# Once the deadline passes, a still-live claimant is no longer waited for: the
# wake decision is made as if it were gone, exactly as the old iteration cap did.
await_delivery() {  # <generation> <state> <phases> <locked> <started> <rc> <output> <timings>
  local generation=$1 state=$2 claim_record claim_generation claim_pid claim_live
  while :; do
    claim_live=0
    if ! take_lock "$PUBLISH_LOCK" "$(seconds_until "$DELIVERY_DEADLINE")"; then
      # Keep this run's bytes, never a replacement's shared report. The next
      # lock owner reconciles the generation before any shared publication.
      ! report_requires_wake "$state" "$7" || defer_result "$@"
      return 1
    fi
    if [ "$(status_get generation)" != "$generation" ]; then
      fm_lock_release "$PUBLISH_LOCK"
      return 0
    fi
    if [ -f "$DELIVERED_FILE" ]; then
      fm_lock_release "$PUBLISH_LOCK"
      return 0
    fi
    if [ -f "$CLAIM_FILE" ] && [ "$(now)" -lt "$DELIVERY_DEADLINE" ]; then
      claim_record=$(cat "$CLAIM_FILE" 2>/dev/null || true)
      IFS=$'\t' read -r claim_generation claim_pid <<EOF
$claim_record
EOF
      if [ "$claim_generation" = "$generation" ]; then
        case "$claim_pid" in
          ''|*[!0-9]*) ;;
          *) kill -0 "$claim_pid" 2>/dev/null && claim_live=1 ;;
        esac
      fi
      [ "$claim_live" -eq 1 ] || rm -f "$CLAIM_FILE" 2>/dev/null || true
    fi
    if [ "$claim_live" -eq 0 ]; then
      local delivery_status=0
      ! report_requires_wake "$state" || queue_result_wake "$state" || delivery_status=$?
      [ "$delivery_status" -eq 0 ] || defer_result "$@" || delivery_status=$?
      fm_lock_release "$PUBLISH_LOCK"
      return "$delivery_status"
    fi
    fm_lock_release "$PUBLISH_LOCK"
    sleep 0.1
  done
}

# Write the result files. Prints the final state, which differs from the
# requested one only when the report itself could not be written.
record_result() {  # <generation> <state> <phases> <locked> <started> <rc> <output-file> <timing-file>
  local generation=$1 state=$2 phases=$3 locked=$4 started=$5 rc=$6 out=$7 timings=${8:-} report_published=1
  # Timings are published for EVERY outcome, including timeout and failure: a run
  # that hit the bound is exactly the run whose per-step record is worth having,
  # and whatever the killed sweeps managed to append is a real partial answer.
  # A timing record is diagnostic only, so a failure to publish it is discarded
  # rather than downgrading the run - the report itself is the contract.
  if [ -n "$timings" ] && [ -f "$timings" ]; then
    write_atomic "$TIMINGS_FILE" < "$timings" || true
  fi
  if ! write_atomic "$REPORT_FILE" < "$out"; then
    state=failed
    rc=1
    report_published=0
  fi
  rm -f "$DELIVERED_FILE" 2>/dev/null || true
  write_atomic "$STATUS_FILE" <<EOF || true
state=$state
pid=$$
started=$started
finished=$(now)
rc=$rc
locked=$locked
phases=$phases
generation=$generation
lock_pid=$(status_get lock_pid)
report_published=$report_published
EOF
  printf '%s' "$state"
}

publish() {  # <generation> <state> <phases> <locked> <started> <rc> <output-file> <timing-file>
  local generation=$1 state=$2 phases=$3 locked=$4 started=$5 rc=$6 out=$7 timings=${8:-}
  DELIVERY_DEADLINE=$(( $(now) + $(delivery_budget) ))
  if ! take_lock "$PUBLISH_LOCK" "$(seconds_until "$DELIVERY_DEADLINE")"; then
    publish_lock_held "$generation" "$phases" "$locked" "$started" "$PUBLISH_LOCK" "$out" "$timings"
    return 1
  fi
  if [ "$(status_get generation)" != "$generation" ]; then
    fm_lock_release "$PUBLISH_LOCK"
    return 0
  fi
  state=$(record_result "$generation" "$state" "$phases" "$locked" "$started" "$rc" "$out" "$timings")
  fm_lock_release "$PUBLISH_LOCK"
  await_delivery "$generation" "$state" "$phases" "$locked" "$started" "$rc" "$out" "$timings"
}

# This directory belongs to one registered generation, not to whoever owns the
# shared status later. A ready marker publishes the complete private packet.
defer_result() {  # same operands as record_result
  local generation=$1 pending
  [ "$(status_get generation)" = "$generation" ] || return 1
  pending_path "$generation" || return 1
  pending=$PENDING_RESULT
  (umask 077; mkdir "$pending") || return 1
  cp "$7" "$pending/report" || return 1
  if [ -n "${8:-}" ] && [ -f "$8" ]; then
    cp "$8" "$pending/timings" || return 1
  fi
  printf '%s\n' "$2" "$3" "$4" "$5" "$6" > "$pending/metadata" || return 1
  : > "$pending/ready"
}

pending_path() {  # <generation>; sets PENDING_RESULT
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  PENDING_RESULT="$STATE/.startup-network-unpublished-$1"
}

pending_result() {  # sets PENDING_RESULT for a complete current packet
  local generation
  generation=$(status_get generation)
  pending_path "$generation" || return 1
  [ -d "$PENDING_RESULT" ] && [ ! -L "$PENDING_RESULT" ] || return 1
  local name
  for name in ready report metadata; do
    [ -f "$PENDING_RESULT/$name" ] && [ ! -L "$PENDING_RESULT/$name" ] || return 1
  done
  if [ -e "$PENDING_RESULT/timings" ] || [ -L "$PENDING_RESULT/timings" ]; then
    [ -f "$PENDING_RESULT/timings" ] && [ ! -L "$PENDING_RESULT/timings" ] || return 1
  fi
  [ "$(status_get generation)" = "$generation" ]
}

# Caller holds PUBLISH_LOCK. Old generations are never promoted, and a result
# already printed by harvest keeps its acknowledgement when delivery resumes.
promote_pending() {  # <notify:0|1>
  local notify=$1 generation pending state phases locked started rc queued=0
  pending_result || return 0
  pending=$PENDING_RESULT
  generation=$(status_get generation)
  state=$(sed -n '1p' "$pending/metadata")
  phases=$(sed -n '2p' "$pending/metadata")
  locked=$(sed -n '3p' "$pending/metadata")
  started=$(sed -n '4p' "$pending/metadata")
  rc=$(sed -n '5p' "$pending/metadata")
  case "$state" in done|timeout|failed) ;; *) return 1 ;; esac
  case "$phases" in probe|probe,sweeps) ;; *) return 1 ;; esac
  case "$locked" in 0|1) ;; *) return 1 ;; esac
  case "$started" in ''|*[!0-9]*) return 1 ;; esac
  case "$rc" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$(status_get state)" = running ] || [ ! -f "$DELIVERED_FILE" ]; then
    state=$(record_result "$generation" "$state" "$phases" "$locked" "$started" "$rc" "$pending/report" "$pending/timings")
    [ "$(status_get state)" = "$state" ] && [ "$(status_get report_published)" = 1 ] || return 1
    if [ "$notify" -eq 1 ] && report_requires_wake "$state"; then
      queue_result_wake "$state" || return 1
      queued=1
    fi
  fi
  rm -f "$pending/ready" "$pending/report" "$pending/metadata" "$pending/timings"
  rmdir "$pending" || return 1
  [ "$queued" -eq 0 ] || printf 'check: startup-network\n'
  return 0
}

cmd_reconcile() {
  pending_result || return 0
  fm_lock_try_acquire "$PUBLISH_LOCK" || return 0
  local rc=0
  DELIVERY_DEADLINE=$(( $(now) + 1 ))
  promote_pending 1 || rc=$?
  fm_lock_release "$PUBLISH_LOCK"
  return "$rc"
}

publish_lock_held() {  # <generation> <phases> <locked> <started> <lockdir> <output-file> <timing-file>
  local generation=$1 phases=$2 locked=$3 started=$4 lockdir=$5 out=$6 timings=${7:-}
  printf 'NETWORK_CHECKS: the deferred check worker gave up because %s was still held by %s at its deadline, so %s may be incomplete; rerun %s/bin/fm-startup-network.sh run --locked %s once that lock is released\n' \
    "$lockdir" "$(held_by)" "$(phase_label "$phases")" "$FM_ROOT" "$locked" >> "$out"
  if [ "$(status_get generation)" != "$generation" ]; then
    cat "$out" >&2
    return 1
  fi
  defer_result "$generation" failed "$phases" "$locked" "$started" 124 "$out" "$timings"
}

cmd_run() {  # <locked> <lock-pid> <generation>
  local locked=$1 lock_pid=$2 generation=$3 phases started budget out rc sweep_locked=0 downgraded=0 internal=0 lease_held=0 timings stage_started stage_deadline DELIVERY_DEADLINE registered
  mkdir -p "$STATE" 2>/dev/null || return 1
  started=$(now)
  budget=$(stage_budget)
  # One deadline for everything before publication: the lock waits below and
  # the sweeps share it, so the worker's stage never outlives its budget.
  stage_deadline=$(( started + budget ))
  DELIVERY_DEADLINE=$stage_deadline
  phases=probe
  out=$(mktemp "${TMPDIR:-/tmp}/fm-startup-network.XXXXXX" 2>/dev/null) || return 1
  # Recorded into a temp file rather than straight into state/ so a run that is
  # killed mid-sweep cannot leave a half-written artifact where the previous
  # run's complete one used to be; publish() promotes it atomically at the end.
  # Sweeps run in child processes (bin/fm-bootstrap.sh, and bin/fm-fleet-sync.sh
  # below it), so FM_TIMING_LOG is exported and appended to by all of them.
  timings=$(mktemp "${TMPDIR:-/tmp}/fm-startup-network-timings.XXXXXX" 2>/dev/null) || timings=
  [ -z "$timings" ] || fm_timing_start "$timings"
  if [ -n "$generation" ]; then
    if ! take_lock "$PUBLISH_LOCK" "$(seconds_until "$stage_deadline")"; then
      publish_lock_held "$generation" "$phases" "$locked" "$started" "$PUBLISH_LOCK" "$out" "$timings"
      run_cleanup "$out" "$timings"
      return 1
    fi
    if [ "$(status_get generation)" = "$generation" ] && [ "$(status_get pid)" = "$$" ] \
      && [ "$(status_get state)" = running ]; then
      internal=1
      started=$(status_get started)
      if ! registered=$(cat "$STATUS_FILE") || ! write_atomic "$STATUS_FILE" <<EOF
$registered
worker_started=1
EOF
      then
        fm_lock_release "$PUBLISH_LOCK"
        run_cleanup "$out" "$timings"
        return 1
      fi
    fi
    fm_lock_release "$PUBLISH_LOCK"
    [ "$internal" -eq 1 ] || { run_cleanup "$out" "$timings"; return 1; }
  elif [ "$locked" = 1 ] && ! fm_session_lock_owned_by_self "$STATE"; then
    downgraded=1
    locked=0
  fi
  if [ "$locked" = 1 ]; then
    [ "$internal" -eq 1 ] || lock_pid=$(cat "$STATE/.lock" 2>/dev/null || true)
    if lock_unchanged "$lock_pid"; then
      sweep_locked=1
      phases=probe,sweeps
    else
      downgraded=1
    fi
  fi

  if [ "$internal" -eq 0 ]; then
    generation="$(now).$$.manual"
    if ! take_lock "$PUBLISH_LOCK" "$(seconds_until "$stage_deadline")"; then
      publish_lock_held "$generation" "$phases" "$sweep_locked" "$started" "$PUBLISH_LOCK" "$out" "$timings"
      run_cleanup "$out" "$timings"
      return 1
    fi
    if [ "$(status_get state)" = running ] && worker_alive; then
      fm_lock_release "$PUBLISH_LOCK"
      run_cleanup "$out" "$timings"
      return 1
    fi
    write_atomic "$STATUS_FILE" <<EOF || true
state=running
worker_started=1
pid=$$
started=$started
locked=$sweep_locked
phases=$phases
generation=$generation
lock_pid=$lock_pid
EOF
    fm_lock_release "$PUBLISH_LOCK"
  fi

  stage_started=$(fm_timing_now_ms)
  rc=0
  if [ "$sweep_locked" -eq 1 ]; then
    if ! take_lock "$STATE/.lock.acquire" "$(seconds_until "$stage_deadline")"; then
      # The lease is what makes a takeover wait for a settled sweep; a live
      # holder past the budget means no sweep can safely start, so this is a
      # failed stage to rerun, published through the ordinary bounded path.
      printf 'NETWORK_CHECKS: the deferred check worker gave up because %s was still held by %s at its deadline, so %s did not run; rerun %s/bin/fm-startup-network.sh run --locked 1 once that lease is released\n' \
        "$STATE/.lock.acquire" "$(held_by)" "$(phase_label "$phases")" "$FM_ROOT" >> "$out"
      publish "$generation" failed "$phases" "$sweep_locked" "$started" 124 "$out" "$timings"
      run_cleanup "$out" "$timings"
      return 1
    fi
    lease_held=1
    if ! lock_unchanged "$lock_pid"; then
      sweep_locked=0
      phases=probe
      downgraded=1
    fi
  fi
  # One aggregate deadline covers both deferred operations. The inactive scan
  # retains its own tighter per-scan bound inside this outer bound. Findings
  # need no report translation: the scan writes its ordinary durable
  # inactive-outcome wakes directly. A child shell composes the two executable
  # owners only so fm_run_timed can govern them as one process group.
  # The sweeps get whatever the lock waits above left of the stage budget.
  budget=$(seconds_until "$stage_deadline")
  if [ "$sweep_locked" -eq 1 ]; then
    # shellcheck disable=SC2016  # Child-shell variables expand inside the bound.
    fm_run_timed "$budget" env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      FM_BOOTSTRAP_NETWORK=only FM_BOOTSTRAP_NETWORK_LOCK_PID="$lock_pid" \
      bash -c '
        script_dir=$1
        "$script_dir/fm-inactive-reconcile.sh" scan --startup >/dev/null 2>&1 || true
        exec "$script_dir/fm-bootstrap.sh"
      ' _ "$SCRIPT_DIR" >"$out" 2>&1 || rc=$?
  else
    fm_run_timed "$budget" env FM_BOOTSTRAP_NETWORK=only FM_BOOTSTRAP_DETECT_ONLY=1 \
      "$SCRIPT_DIR/fm-bootstrap.sh" >"$out" 2>&1 || rc=$?
  fi
  [ "$lease_held" -eq 0 ] || fm_lock_release "$STATE/.lock.acquire"
  # The bounded run as a whole, so the per-phase records can be read against the
  # total even when the bound cut some of them off.
  fm_timing_record stage network-checks "$stage_started" "$phases"

  if [ "$downgraded" -eq 1 ]; then
    printf 'NETWORK_CHECKS: the fleet lock was no longer held by the session that requested these, so dead-secondmate relaunch, secondmate convergence, pending handoff delivery, and project clone refresh were skipped; they belong to whichever session holds the lock now\n' >> "$out"
  fi
  case "$rc" in
    0) publish "$generation" 'done' "$phases" "$sweep_locked" "$started" "$rc" "$out" "$timings" ;;
    124)
      printf 'NETWORK_CHECKS: hit the %ss bound before finishing, so %s may be incomplete; rerun %s/bin/fm-startup-network.sh run --locked %s\n' \
        "$(stage_budget)" "$(phase_label "$phases")" "$FM_ROOT" "$sweep_locked" >> "$out"
      publish "$generation" timeout "$phases" "$sweep_locked" "$started" "$rc" "$out" "$timings"
      ;;
    *)
      printf 'NETWORK_CHECKS: the deferred check worker exited %s, so %s may be incomplete; rerun %s/bin/fm-startup-network.sh run --locked %s\n' \
        "$rc" "$(phase_label "$phases")" "$FM_ROOT" "$sweep_locked" >> "$out"
      publish "$generation" failed "$phases" "$sweep_locked" "$started" "$rc" "$out" "$timings"
      ;;
  esac
  rc=$?
  run_cleanup "$out" "$timings"
  return "$rc"
}

run_cleanup() {  # <output-file> <timing-file>
  rm -f "$1" 2>/dev/null || true
  [ -z "${2:-}" ] || rm -f "$2" 2>/dev/null || true
}

# --- harvest / report --------------------------------------------------------

print_finished() {  # <state>
  local state=$1 phases started finished took=unknown report_published
  phases=$(status_get phases)
  started=$(status_get started)
  finished=$(status_get finished)
  report_published=$(status_get report_published)
  case "$started$finished" in
    ''|*[!0-9]*) ;;
    *) took=$((finished - started)) ;;
  esac
  printf 'completed off the startup path in %ss: %s.\n' "$took" "$(phase_label "$phases")"
  [ "$state" = 'done' ] || printf 'The stage itself did not finish cleanly (%s) - the NETWORK_CHECKS line below names what to rerun.\n' "$state"
  if [ "$report_published" = 0 ]; then
    printf 'NETWORK_CHECKS: could not publish the deferred check report, so %s results are unavailable; rerun %s/bin/fm-startup-network.sh run --locked %s\n' \
      "$(phase_label "$phases")" "$FM_ROOT" "$(status_get locked)"
  elif [ -s "$REPORT_FILE" ]; then
    cat "$REPORT_FILE"
    printf 'These ran AFTER the sections above were composed, so re-read any record a line here names.\n'
  else
    printf '(silent - no problems found)\n'
  fi
}

# Deliberately NOT part of print_state, and so deliberately not part of harvest:
# harvest composes the digest's NETWORK CHECKS section, and this record is
# diagnostic detail nobody needs on an ordinary session start. It is printed only
# by the on-demand `report` command, so the timings cost a reader nothing until
# a run is actually slow enough to ask about.
print_timings() {
  if pending_result; then
    fm_timing_render "$PENDING_RESULT/timings"
  else
    fm_timing_render "$TIMINGS_FILE"
  fi
}

print_pending() {
  local phases started age
  phases=$(status_get phases)
  started=$(status_get started)
  age=$(age_of "$started")
  printf 'IN PROGRESS - the deferred network checks have not finished yet.\n'
  printf 'NOT yet confirmed: %s.\n' "$(phase_label "$phases")"
  [ -z "$age" ] || printf 'Started %ss ago, bounded at %ss.\n' "$age" "$(stage_budget)"
  # shellcheck disable=SC2016  # The backticked wake name is literal digest text.
  printf 'Only a FAILED or otherwise actionable result arrives as a `check: startup-network` wake; a clean success stays silent.\n'
  printf 'The durable result is readable on demand with %s/bin/fm-startup-network.sh report; until it finishes, treat none of it as confirmed.\n' "$FM_ROOT"
}

print_state() {
  if [ "${1:-1}" -eq 1 ] && pending_result; then
    printf 'NETWORK_CHECKS: result publication is pending; the current run could not finish publication or wake delivery.\n'
    cat "$PENDING_RESULT/report"
    return
  fi
  case "$(status_get state)" in
    done|timeout|failed) print_finished "$(status_get state)" ;;
    running)
      if worker_alive; then
        print_pending
      else
        printf 'NETWORK_CHECKS: the deferred check worker stopped before publishing, so %s did not complete; rerun %s/bin/fm-startup-network.sh run --locked %s\n' \
          "$(phase_label "$(status_get phases)")" "$FM_ROOT" "$(status_get locked)"
      fi
      ;;
    *) printf 'not started - no deferred network checks have run for this home yet.\n' ;;
  esac
}

cmd_harvest() {  # <pid>
  local pid=$1 generation state claim_record claim_generation claim_pid
  if ! take_lock "$PUBLISH_LOCK" "$(delivery_budget)"; then
    printf 'NETWORK_CHECKS: the deferred check record is locked by %s, so %s could not be confirmed; read %s/bin/fm-startup-network.sh report once that lock is released\n' \
      "$(held_by)" "$(phase_label "$(status_get phases)")" "$FM_ROOT"
    return 1
  fi
  generation=$(status_get generation)
  if ! promote_pending 0; then
    fm_lock_release "$PUBLISH_LOCK"
    return 1
  fi
  # Another session's live claim is left alone; the worker reaps a dead one.
  if [ -f "$CLAIM_FILE" ]; then
    claim_record=$(cat "$CLAIM_FILE" 2>/dev/null || true)
    IFS=$'\t' read -r claim_generation claim_pid <<EOF
$claim_record
EOF
    if [ "$claim_generation" = "$generation" ] \
      && { [ -z "$pid" ] || [ "$claim_pid" = "$pid" ]; }; then
      rm -f "$CLAIM_FILE" 2>/dev/null || true
    fi
  fi
  state=$(status_get state)
  # Only the locked shared result can be acknowledged below. A private packet
  # completed after promotion waits for reconciliation and its own delivery.
  print_state 0
  case "$state" in
    done|timeout|failed) [ "$(status_get report_published)" = 0 ] || write_atomic "$DELIVERED_FILE" <<EOF || true
delivered
EOF
      ;;
  esac
  fm_lock_release "$PUBLISH_LOCK"
}

cmd_wait() {  # <seconds>
  local limit=$1 waited=0
  case "$limit" in ''|*[!0-9]*) limit=120 ;; esac
  while [ "$waited" -lt "$limit" ]; do
    case "$(status_get state)" in
      done|timeout|failed) return 0 ;;
      running) worker_alive || return 1 ;;
    esac
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}

# --- entry -------------------------------------------------------------------

LOCKED=0
HARVEST_PID=
LOCK_PID=
GENERATION=
MODE=${1:-}
[ $# -eq 0 ] || shift
while [ $# -gt 0 ]; do
  case "$1" in
    --locked) LOCKED=${2:-0}; shift; [ $# -eq 0 ] || shift ;;
    --harvest-pid|--pid) HARVEST_PID=${2:-}; shift; [ $# -eq 0 ] || shift ;;
    --lock-pid) LOCK_PID=${2:-}; shift; [ $# -eq 0 ] || shift ;;
    --generation) GENERATION=${2:-}; shift; [ $# -eq 0 ] || shift ;;
    -h|--help) usage; exit 0 ;;
    *) break ;;
  esac
done
case "$LOCKED" in 0|1) ;; *) LOCKED=0 ;; esac

case "$MODE" in
  start) cmd_start "$LOCKED" "${HARVEST_PID:-0}" ;;
  run) cmd_run "$LOCKED" "$LOCK_PID" "$GENERATION" || exit $? ;;
  harvest) cmd_harvest "${HARVEST_PID:-}" ;;
  report) print_state; print_timings ;;
  reconcile) cmd_reconcile || exit $? ;;
  wait) cmd_wait "${1:-120}" || exit $? ;;
  -h|--help) usage ;;
  *)
    printf 'fm-startup-network: unknown mode: %s\n' "${MODE:-<none>}" >&2
    printf 'usage: fm-startup-network.sh start|run|harvest|report|wait\n' >&2
    exit 2
    ;;
esac
