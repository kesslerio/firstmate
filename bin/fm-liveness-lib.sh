# shellcheck shell=bash
# fm-liveness-lib.sh - read-only, per-home worker seats.
# Usage: source bin/fm-liveness-lib.sh; fm_liveness_snapshot <home> [state-dir]
#
# config/worker-target belongs only to this home, never its parent's inherited
# config. An absent file defaults to 4, or 6 when .fm-secondmate-home exists.
# A present file follows fm-startup-memory-budget-lib.sh's strict positive
# single-integer format and must fit signed 64-bit arithmetic.
#
# A live worker has a task record here, is not kind=secondmate, has no canonical
# PR-ready handoff for this incarnation, and is not currently done or failed.
# fm-pr-check.sh owns the readiness binding; replacement launches retain PR
# association but withdraw the prior incarnation's handoff. Legacy unbound
# canonical handoffs remain ready until a replacement pins their generation.
# Invalid PR metadata
# retains a seat as unknown until repaired, even if crew-state reports done.
# fm-crew-state.sh owns current state for every backend and harness; each read
# is bounded to 10s.
# Unknown, malformed, failed, or timed-out reads retain the seat, with the
# uncertainty exposed in FM_LIVENESS_WARNINGS, never inferred as completion.
#
# On success sets FM_LIVENESS_LIVE, TARGET, FREE, OVER_TARGET and LANES.
# LANES is newline-separated TSV: task id, kind, current state, age seconds.
# Every live lane is listed, including paused lanes and scouts. Age is since
# spawn_gen's epoch, or metadata mtime for legacy records; unknown when neither
# can be read. Future stamps clamp to zero. No status-event tail is used to
# infer current state. On invalid config/records returns 1 with
# FM_LIVENESS_ERROR; callers must not consume a partial snapshot.
#
# state/.last-launch is an atomic single-line Unix epoch written by fm-spawn.sh
# after confirmed ordinary worker publication, delivery and backlog commit,
# including relaunch. It is an ordinary single-link positive decimal epoch
# with exactly one newline; unsafe destinations or publication failures report
# the started task and preserved record without rolling back confirmed work.
# Secondmates are homes, not worker launches. Teardown does not remove the stamp.

FM_LIVENESS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-startup-memory-budget-lib.sh
. "$FM_LIVENESS_LIB_DIR/fm-startup-memory-budget-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$FM_LIVENESS_LIB_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$FM_LIVENESS_LIB_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$FM_LIVENESS_LIB_DIR/fm-pr-lib.sh"

fm_liveness_target() { # <home>
  local home=$1 path="$1/config/worker-target"
  FM_LIVENESS_ERROR=
  FM_LIVENESS_TARGET=
  if [ -e "$home/config" ] || [ -L "$home/config" ]; then
    if ! fm_startup_memory_budget_config_dir_safe "$home/config"; then
      FM_LIVENESS_ERROR="$path: $FM_STARTUP_MEMORY_BUDGET_ERROR"
      return 1
    fi
  fi
  if [ ! -e "$path" ] && [ ! -L "$path" ]; then
    FM_LIVENESS_TARGET=4
    if [ -e "$home/.fm-secondmate-home" ] || [ -L "$home/.fm-secondmate-home" ]; then
      FM_LIVENESS_TARGET=6
    fi
    return 0
  fi
  if ! fm_startup_memory_budget_file_valid "$path"; then
    FM_LIVENESS_ERROR="$path: $FM_STARTUP_MEMORY_BUDGET_ERROR"
    return 1
  fi
  if ! fm_startup_memory_decimal_le "$FM_STARTUP_MEMORY_BUDGET_VALUE" 9223372036854775807; then
    FM_LIVENESS_ERROR="$path: value exceeds signed 64-bit integer range"
    return 1
  fi
  FM_LIVENESS_TARGET=$FM_STARTUP_MEMORY_BUDGET_VALUE
}

# shellcheck disable=SC2034 # Public snapshot globals are consumed by callers.
fm_liveness_snapshot() { # <home> [state-dir]
  local home=$1 state_dir=${2:-$1/state} meta id kind raw current stamp age now prior_handoff invalid_pr
  local deadline=$((SECONDS + ${3:-10})) remaining
  FM_LIVENESS_LIVE=0
  FM_LIVENESS_FREE=0
  FM_LIVENESS_OVER_TARGET=0
  FM_LIVENESS_LANES=
  FM_LIVENESS_WARNINGS=
  fm_liveness_target "$home" || return 1
  if { [ -e "$state_dir" ] || [ -L "$state_dir" ]; } \
    && { [ ! -d "$state_dir" ] || [ ! -r "$state_dir" ] || [ ! -x "$state_dir" ]; }; then
    FM_LIVENESS_ERROR="state directory cannot be read: $state_dir"
    return 1
  fi
  now=$(date +%s)
  for meta in "$state_dir"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    if [ -L "$meta" ] || [ ! -f "$meta" ] || [ ! -r "$meta" ]; then
      FM_LIVENESS_ERROR="task record is not a readable ordinary file: $meta"
      return 1
    fi
    kind=$(fm_meta_get "$meta" kind)
    [ "$kind" != secondmate ] || continue
    kind=${kind:-ship}
    id=${meta##*/}; id=${id%.meta}
    current=unknown
    prior_handoff=0
    invalid_pr=0
    if grep -q '^pr=' "$meta"; then
      if ! fm_pr_metadata_identity_parse "$meta"; then
        invalid_pr=1
        # Crew-state's completion can itself rely on PR metadata. An invalid
        # handoff must not release capacity through that lower-level verdict.
        FM_LIVENESS_WARNINGS="${FM_LIVENESS_WARNINGS}${meta}: invalid PR metadata; seat retained; repair the ready handoff with bin/fm-pr-check.sh"$'\n'
      elif fm_pr_current_handoff "$meta"; then
        continue
      else
        prior_handoff=1
        FM_LIVENESS_WARNINGS="${FM_LIVENESS_WARNINGS}${meta}: prior incarnation or invalid PR readiness binding; seat retained; renew the handoff with bin/fm-pr-check.sh"$'\n'
      fi
    fi
    remaining=$((deadline - SECONDS))
    [ "$remaining" -le 10 ] || remaining=10
    if [ "$invalid_pr" = 0 ] && [ "$remaining" -gt 0 ] && raw=$(fm_run_timed "$remaining" env FM_HOME="$home" FM_STATE_OVERRIDE="$state_dir" \
      FM_CONFIG_OVERRIDE="$home/config" FM_DATA_OVERRIDE="$home/data" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_CREW_STATE_META_OVERRIDE="$meta" \
      FM_CREW_STATE_STATUS_OVERRIDE="$state_dir/$id.status" \
      FM_CREW_STATE_NO_FORGE=1 FM_BUSY_CACHE_READ_ONLY=1 "$FM_LIVENESS_LIB_DIR/fm-crew-state.sh" "$id" 2>/dev/null); then
      case "$raw" in
        'state: '*' · source: '*)
          current=${raw#state: }; current=${current%% · *}
          case "$current" in working|parked|done|blocked|paused|failed|unknown) ;; *) current=unknown ;; esac
          ;;
      esac
    fi
    case "$current" in
      done|failed)
        # This base retains predecessor status/run evidence on replacement.
        # A superseded handoff cannot be laundered through that terminal read.
        if [ "$prior_handoff" = 1 ]; then current=unknown; else continue; fi ;;
    esac
    if [ "$current" = unknown ]; then
      FM_LIVENESS_WARNINGS="${FM_LIVENESS_WARNINGS}${id}: current state unknown; seat retained"$'\n'
    fi
    stamp=$(fm_meta_get "$meta" spawn_gen)
    stamp=${stamp#s}; stamp=${stamp%%.*}
    case "$stamp" in
      ''|*[!0-9]*|0*)
        if [ "$(uname)" = Darwin ]; then
          stamp=$(/usr/bin/stat -f %m "$meta" 2>/dev/null || true)
        else
          stamp=$(stat -c %Y "$meta" 2>/dev/null || true)
        fi
        ;;
    esac
    age=unknown
    case "$stamp" in
      ''|*[!0-9]*|0*) ;;
      *)
        if fm_startup_memory_decimal_le "$stamp" 9223372036854775807; then
          age=$((now - stamp))
          [ "$age" -ge 0 ] || age=0
        fi
        ;;
    esac
    FM_LIVENESS_LIVE=$((FM_LIVENESS_LIVE + 1))
    FM_LIVENESS_LANES="${FM_LIVENESS_LANES}${id}"$'\t'"${kind}"$'\t'"${current}"$'\t'"${age}"$'\n'
  done
  if [ "$FM_LIVENESS_LIVE" -gt "$FM_LIVENESS_TARGET" ]; then
    FM_LIVENESS_OVER_TARGET=$((FM_LIVENESS_LIVE - FM_LIVENESS_TARGET))
  else
    FM_LIVENESS_FREE=$((FM_LIVENESS_TARGET - FM_LIVENESS_LIVE))
  fi
}
