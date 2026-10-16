#!/usr/bin/env bash
# fm-sol-cap-lib.sh - the mechanical ceiling on concurrent Sol sessions.
#
# The fleet dispatches the gpt-6 Sol models (gpt-6.1-sol and gpt-6-sol) by
# config/crew-dispatch.json's Sol rows, and the no-mistakes gate/review agents
# ride gpt-6.1-sol too. The captain filed a four-session ceiling (2026-09-29,
# "four-session Sol ceiling") on concurrent Sol sessions: a fifth launch must
# stop by construction, not by anyone's attention. This library is the single
# owner of the ceiling's mechanics; bin/fm-spawn.sh owns where the hook runs
# (after the harness/model axis resolves, before any endpoint, worktree, or
# record exists), and docs/configuration.md "Sol session ceiling
# (config/sol-cap)" is the operator reference.
#
# What counts as a Sol session: a worker whose dispatch reaches this guard
# with an explicit or recorded model id in the Sol set. The set is derived at
# call time from config/crew-dispatch.json (its rule profiles' and default
# profile's model ids matching ^gpt-<digits or dots>-sol$), so a future Sol
# row joins the ceiling by editing the dispatch table, not by editing this
# file. The registered Sol session carries the task id as its session key, so
# a relaunch or respawn of the same task id replaces its own entry instead of
# counting itself. A dispatch with no Sol model never claims a slot.
#
# The count: <state-dir>/sol-sessions.tsv, one TSV row per Sol session
#
#   <session-id>	<model>	<start-epoch>	<pid>
#

# The captain's filed four-session Sol ceiling (2026-09-29, "four-session Sol
# ceiling"), overridable by one positive integer in config/sol-cap.
# shellcheck disable=SC2034 # read by bin/fm-spawn.sh after sourcing.
FM_SOL_CAP_DEFAULT=4

# The registry file name and the claim lock name, under each home's state dir.
# shellcheck disable=SC2034 # read by the claim, count, and promotion paths.
FM_SOL_REGISTRY_NAME=sol-sessions.tsv
FM_SOL_LOCK_NAME=.sol-cap.lock

# The refusal message of the refusing call, and FM_SOL_CLAIM_CREATED set to
# the claimed task id after a call that both passed the cap and wrote its
# reserve row.
# shellcheck disable=SC2034 # read by bin/fm-spawn.sh after sourcing.
FM_SOL_CAP_REFUSAL=
FM_SOL_CLAIM_CREATED=

# Set by fm_sol_cap_ceiling (FM_SOL_CAP) and fm_sol_cap_model_set
# (FM_SOL_CAP_MODELS_ERROR, FM_SOL_CEILING_ERROR, FM_SOL_COUNT_ERROR,
# FM_SOL_ACTIVE_LIST, FM_SOL_CAP_NOW, FM_LOCK_HELD_PID) for their caller.
# shellcheck disable=SC2034
FM_SOL_CAP=
FM_SOL_CAP_MODELS_ERROR=
FM_SOL_CEILING_ERROR=
FM_SOL_COUNT_ERROR=

FM_SOL_CAP_MODELS=

fm_sol_cap_age_text() {  # <seconds>
  local s=$1
  if [ "$s" -ge 86400 ]; then
    printf '%dd%dh' $((s / 86400)) $(((s % 86400) / 3600))
  elif [ "$s" -ge 3600 ]; then
    printf '%dh%dm' $((s / 3600)) $(((s % 3600) / 60))
  elif [ "$s" -ge 60 ]; then
    printf '%dm%ds' $((s / 60)) $((s % 60))
  else
    printf '%ds' "$s"
  fi
}

# fm_sol_cap_model_set <config-dir>
# Derive the Sol model ids from <config-dir>/crew-dispatch.json's rule
# profiles and default profile. Sets FM_SOL_CAP_MODELS to a pipe-delimited
# set, empty when the file is absent, so a home whose dispatch table names no
# Sol model keeps this guard inert. Returns 1 with FM_SOL_CAP_MODELS_ERROR
# when jq is missing or the table exists but cannot be read, so the guard
# refuses rather than counts nothing on a machine whose dispatch table it
# cannot read.
fm_sol_cap_model_set() {  # <config-dir>
  local config=$1 file
  FM_SOL_CAP_MODELS=
  FM_SOL_CAP_MODELS_ERROR=
  file=$config/crew-dispatch.json
  [ -e "$file" ] || [ -L "$file" ] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    FM_SOL_CAP_MODELS_ERROR="jq is missing, so the Sol ceiling cannot read $file"
    return 1
  fi
  if ! FM_SOL_CAP_MODELS=$(jq -r --arg re '^gpt-[0-9.]+-sol$' '
    def prof($v): if ($v | type) == "array" then $v else [$v] end;
    ([(.rules // [])[]? | prof(.use?)[]? | (.model? // empty)]
      + (if has("default") then [prof(.default)[]? | (.model? // empty)] else [] end))
    | map(select(type == "string" and test($re)))
    | unique | join("|")' "$file" 2>/dev/null); then
    FM_SOL_CAP_MODELS_ERROR="$file exists but cannot be read"
    return 1
  fi
  return 0
}

# fm_sol_cap_ceiling <config-dir>
# Resolve the concurrent-Sol ceiling. config/sol-cap in the dispatching home,
# one positive integer, overrides FM_SOL_CAP_DEFAULT, and the file's absence
# uses the default. Returns 1 with FM_SOL_CEILING_ERROR when the file is
# present but unreadable or malformed, so the guard refuses instead of
# guessing the ceiling.
fm_sol_cap_ceiling() {  # <config-dir>
  local config=$1 file cap
  FM_SOL_CAP=$FM_SOL_CAP_DEFAULT
  FM_SOL_CEILING_ERROR=
  file=$config/sol-cap
  [ -e "$file" ] || [ -L "$file" ] || return 0
  if [ ! -f "$file" ] || [ ! -r "$file" ]; then
    FM_SOL_CEILING_ERROR="$file is not a readable regular file"
    return 1
  fi
  cap=$(cat "$file")
  case "$cap" in
    1 | 2 | 3 | 4) ;;
    *) FM_SOL_CEILING_ERROR="$file must be one integer from 1 through 4"; return 1 ;;
  esac
  FM_SOL_CAP=$cap
  return 0
}

# fm_sol_cap_entry_shape <start> <pid>
# Zero exit when a registry row is shaped right: integer start epoch and pid.
fm_sol_cap_entry_shape() {  # <start> <pid>
  local start=$1 pid=$2
  case "$start" in '' | *[!0-9]*) return 1 ;; esac
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
}

fm_sol_cap_entry_live() {  # <start> <pid>
  local start=$1 pid=$2
  case "$start" in '' | *[!0-9]*) return 1 ;; esac
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  [ "$pid" = 0 ] || fm_pid_alive "$pid"
}

# fm_sol_cap_active_count <first-state> <own-id>
# Count the live Sol-session registry rows in every local home's state
# directory on this machine, excluding <own-id>. Sets FM_SOL_COUNT to the
# count and FM_SOL_ACTIVE_LIST to a "; "-joined listing "<id> (<model>, age
# N)"; an entry in a state directory other than <first-state> is qualified
# with " in <state-dir>". Returns 1 with FM_SOL_COUNT_ERROR when the local
# homes cannot be enumerated, a registry cannot be read, or a row is
# malformed, because skipping a home could claim a free slot that another
# home holds.
fm_sol_cap_active_count() {  # <first-state> <own-id>
  local first=$1 own=$2 state file id model start pid now age entry
  FM_SOL_COUNT=0
  FM_SOL_ACTIVE_LIST=
  FM_SOL_COUNT_ERROR=
  fm_local_firstmate_state_dirs "$first" || {
    FM_SOL_COUNT_ERROR=$FM_LOCAL_FIRSTMATE_ERROR
    return 1
  }
  fm_epoch_seconds_to FM_SOL_CAP_NOW
  now=$FM_SOL_CAP_NOW
  for state in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    file=$state/$FM_SOL_REGISTRY_NAME
    [ -e "$file" ] || [ -L "$file" ] || continue
    if [ ! -f "$file" ] || [ ! -r "$file" ]; then
      FM_SOL_COUNT_ERROR="Sol registry $file is not a readable regular file"
      return 1
    fi
    while :; do
      # A blank or hand-edited inert line is skipped, so a registry note
      # cannot stop the fleet; anything else that fails the live test is a
      # malformed row with a loud refusal, because silently skipping a
      # home could give away a slot another home holds.
      IFS=$'\t' read -r id model start pid || break
      [ -n "$id" ] || continue
      if [ -z "$model" ] || [ -z "$start" ] || ! fm_sol_cap_entry_shape "$start" "$pid"; then
        FM_SOL_COUNT_ERROR="Sol registry $file has a malformed row: ${id:-<empty>} ${model:-<empty>} ${start:-<empty>} ${pid:-<empty>}"
        return 1
      fi
      fm_sol_cap_entry_live "$start" "$pid" || continue
      [ "$id" != "$own" ] || { [ "$state" != "$first" ] && [ ! "$state" -ef "$first" ]; } || continue
      age=$((now > start ? now - start : 0))
      entry="$id ($model, age $(fm_sol_cap_age_text "$age"))"
      [ "$state" = "$first" ] || entry="$entry in $state"
      FM_SOL_COUNT=$((FM_SOL_COUNT + 1))
      FM_SOL_ACTIVE_LIST="${FM_SOL_ACTIVE_LIST:+$FM_SOL_ACTIVE_LIST; }$entry"
    done < "$file"
  done
  return 0
}

# fm_sol_cap_lock_acquire <lock-dir> <what>
# Ceiling-claim lock contention between two simultaneous dispatches is
# transient, not fleet breakage: retry briefly, then refuse naming the
# problem, because the dispatch contract refuses rather than queues an
# unbounded wait. Sets FM_SOL_CAP_REFUSAL on refusal.
fm_sol_cap_lock_acquire() {  # <lock-dir> <what>
  local lock=$1 what=$2 tries=40 i=0
  while :; do
    fm_lock_try_acquire "$lock" && return 0
    i=$((i + 1))
    [ "$i" -lt "$tries" ] || break
    sleep 0.25
  done
  FM_SOL_CAP_REFUSAL="error: Sol ceiling: another dispatch has held the ceiling claim lock for over 10s$([ -n "${FM_LOCK_HELD_PID:-}" ] && printf ' (pid %s)' "$FM_LOCK_HELD_PID"); $what was not dispatched - retry shortly"
  return 1
}

# fm_sol_cap_registry_claim <registry-file> <id> <model> <now>
# Rewrite <registry-file> in place after the count passed, while the ceiling
# lock is held: drop this task id's own earlier row (a relaunch or respawn
# replaces it), drop no live row, and append the claimed row with the calling
# process's pid as the reservation, which dies with a failed dispatch. The
# rewrite lands in one atomic mv, so a parallel reader never sees a
# half-written file.
fm_sol_cap_registry_claim() {  # <registry-file> <id> <model> <now>
  local file=$1 id=$2 model=$3 now=$4 tmp row rc
  tmp=$file.tmp.$$
  if [ -f "$file" ]; then
    awk -F'\t' -v id="$id" '$1 != id' "$file" > "$tmp" 2>/dev/null
    rc=$?
    [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ] || {
      rm -f -- "$tmp"
      echo "error: Sol ceiling: Sol registry $file could not be read" >&2
      return 1
    }
  elif : >> "$file" 2>/dev/null; then
    : > "$tmp"
  else
    echo "error: Sol ceiling: Sol registry $file cannot be claimed" >&2
    return 1
  fi
  row="${id}"$'\t'"${model}"$'\t'"${now}"$'\t'"$$"
  if ! printf '%s\n' "${row}" >> "$tmp"; then
    rm -f -- "$tmp"
    echo "error: Sol ceiling: Sol registry $file could not record the claim of $id" >&2
    return 1
  fi
  mv -- "$tmp" "$file" || {
    rm -f -- "$tmp"
    echo "error: Sol ceiling: Sol registry $file could not be rewritten" >&2
    return 1
  }
  return 0
}

# fm_sol_cap_refuse_and_claim <id> <kind> <harness> <model> <config-dir> <state-dir>
# The guard bin/fm-spawn.sh calls once a spawn's harness/model axis is fully
# resolved and before any endpoint, worktree, or record exists. A non-Sol or
# unset model never touches the registry and returns 0. A Sol-model dispatch
# at the ceiling is refused with one actionable message in FM_SOL_CAP_REFUSAL
# and return 1, and otherwise claims this task's row atomically in one locked
# critical section (count under the lock, then commit), with the calling
# process's pid as the reservation. An unavailable model set, ceiling, count,
# or claim lock refuses loudly rather than launching possibly uncounted.
fm_sol_cap_refuse_and_claim() {  # <id> <kind> <harness> <model> <config-dir> <state-dir>
  local id=$1 harness=$3 model=$4 config=$5 state=$6 registry now lock root local_home
  FM_SOL_CAP_REFUSAL=
  FM_SOL_CLAIM_CREATED=
  [ -n "$model" ] && [ "$model" != default ] || return 0
  [ -n "$id" ] || return 0
  fm_sol_cap_model_set "$config" || {
    if [[ ! "$model" =~ ^gpt-[0-9.]+-sol$ ]]; then return 0; fi
    FM_SOL_CAP_REFUSAL="error: Sol ceiling unavailable: $FM_SOL_CAP_MODELS_ERROR; task $id with model $model was not dispatched rather than launched possibly uncounted"
    return 1
  }
  case "|$FM_SOL_CAP_MODELS|" in
  *"|$model|"*) ;;
  *) return 0 ;;
  esac
  fm_sol_cap_ceiling "$config" || {
    FM_SOL_CAP_REFUSAL="error: Sol ceiling unavailable: $FM_SOL_CEILING_ERROR; task $id with model $model was not dispatched rather than launched against an unread ceiling"
    return 1
  }
  root=$(fm_firstmate_root_home "$FM_HOME") || return 1
  lock=$root/state/$FM_SOL_LOCK_NAME
  if ! fm_sol_cap_lock_acquire "$lock" "task $id"; then
    return 1
  fi
  registry=$state/$FM_SOL_REGISTRY_NAME
  # The count again under the lock, so two spawns racing the count cannot
  # both take the last slot (active_count is this ceiling's decision pass).
  if ! fm_sol_cap_active_count "$state" "$id"; then
    FM_SOL_CAP_REFUSAL="error: Sol ceiling could not count its sessions: $FM_SOL_COUNT_ERROR; task $id with model $model was not dispatched rather than launched possibly uncounted"
    fm_lock_release "$lock" || true
    return 1
  fi
  if [ "$FM_SOL_COUNT" -ge "$FM_SOL_CAP" ]; then
    FM_SOL_CAP_REFUSAL="error: Sol ceiling reached: $FM_SOL_COUNT concurrent Sol session(s) already active and this ceiling is $FM_SOL_CAP (config/sol-cap may lower it); the dispatch of task $id ($harness, $model) was refused. Active sessions: $FM_SOL_ACTIVE_LIST. A session frees its slot when its worker's process ends; the dispatch contract refuses at the ceiling instead of queueing"
    fm_lock_release "$lock" || true
    return 1
  fi
  now=$(fm_epoch_seconds_to FM_SOL_CAP_NOW; printf '%s' "$FM_SOL_CAP_NOW")
  # Keep every walked registry bounded: stale rows are the release path, and
  # once they are no longer counted they do not need to sit in the file. A
  # malformed row is deliberately left in place for its loud refusal.
  for local_home in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    fm_sol_cap_registry_prune "$local_home/$FM_SOL_REGISTRY_NAME"
  done
  if ! fm_sol_cap_registry_claim "$registry" "$id" "$model" "$now"; then
    FM_SOL_CAP_REFUSAL="error: Sol ceiling: the claim of task $id in $registry could not be written; the dispatch was refused rather than launched uncounted"
    fm_lock_release "$lock" || true
    return 1
  fi
  FM_SOL_CLAIM_CREATED=$id
  fm_lock_release "$lock" || true
  return 0
}

fm_sol_cap_promote() {  # <id> <pid or remove> <state-dir>
  local id=$1 pid=$2 state=$3 registry tmp root lock
  registry=$state/$FM_SOL_REGISTRY_NAME
  [ -f "$registry" ] || return 0
  root=$(fm_firstmate_root_home "$FM_HOME") || return 1
  lock=$root/state/$FM_SOL_LOCK_NAME
  fm_sol_cap_lock_acquire "$lock" "the promotion of task $id" || return 1
  tmp=$registry.tmp.$$
  if ! awk -F'\t' -v OFS='\t' -v id="$id" -v pid="$pid" '
    $1 == id { if (pid == "remove") next; $4 = pid }
    {print}
  ' "$registry" > "$tmp" || ! mv -- "$tmp" "$registry"; then
    rm -f -- "$tmp"
    fm_lock_release "$lock" || true
    return 1
  fi
  fm_lock_release "$lock"
}

# fm_sol_cap_registry_prune <registry-file> <now>
fm_sol_cap_registry_prune() {  # <registry-file>
  local file=$1 tmp rc
  [ -f "$file" ] && [ -r "$file" ] || return 0
  tmp=$file.tmp.prune.$$
  # One pass: malformed rows (kept loud) print first, live rows print, stale
  # rows fall through silently.
  awk -F'\t' '
    $1 == "" {next}
    $2 == "" || $3 !~ /^[0-9]+$/ || ($4 != "" && $4 !~ /^[0-9]+$/) {print; next}
    {
      if ($4 != "" && $4 + 0 > 0 && system("kill -0 " $4 " >/dev/null 2>&1") != 0) next
      print
    }' \
    "$file" 2>/dev/null > "$tmp"
  rc=$?
  [ "$rc" -eq 0 ] || {
    rm -f -- "$tmp"
    echo "error: Sol ceiling: Sol registry $file could not be pruned" >&2
    return 1
  }
  mv -- "$tmp" "$file" || {
    rm -f -- "$tmp"
    echo "error: Sol ceiling: Sol registry $file could not be rewritten during pruning" >&2
    return 1
  }
  return 0
}

# --- CLI ---------------------------------------------------------------------
# Operator and test seam: drive the same contract from a fresh process, so a
# registry or ceiling can be inspected and a refusal reproduced without
# sourcing. Requires FM_HOME to select the dispatching Firstmate home; the
# local-home walk resolves the rest. modes:
#   models <config-dir>
#   ceiling <config-dir>
#   refuse-claim <id> <kind> <harness> <model> <config-dir> <state-dir>
#                prints "claimed" or the refusal, exits 0/1.

fm_sol_cap_cli() {
  local mode=$1
  case "$mode" in
  models)
    fm_sol_cap_model_set "${2:?params: models <config-dir>}" && printf '%s\n' "$FM_SOL_CAP_MODELS"
    ;;
  ceiling)
    fm_sol_cap_ceiling "${2:?params: ceiling <config-dir>}" && printf '%s\n' "$FM_SOL_CAP"
    ;;
  run)
    local id=$2 state=$3
    shift 3
    fm_sol_cap_promote "$id" "$$" "$state" || return 1
    exec "$@"
    ;;
  refuse-claim)
    [ "$#" -eq 7 ] || {
      echo "usage: fm-sol-cap-lib.sh refuse-claim <id> <kind> <harness> <model> <config-dir> <state-dir>" >&2
      return 2
    }
    fm_sol_cap_refuse_and_claim "$2" "$3" "$4" "$5" "$6" "$7" && {
      printf '%s\n' claimed
      return 0
    }
    [ -z "$FM_SOL_CAP_REFUSAL" ] || printf '%s\n' "$FM_SOL_CAP_REFUSAL"
    return 1
    ;;
  *)
    echo "unknown fm-sol-cap-lib.sh mode: $mode (try: models | ceiling | refuse-claim)" >&2
    return 2
    ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if ! [ -n "${FM_HOME:-}" ]; then
    echo "error: fm-sol-cap-lib.sh needs FM_HOME to select the dispatching Firstmate home" >&2
    exit 2
  fi
  # shellcheck source=bin/fm-secondmate-registry-lib.sh
  # shellcheck disable=SC1091 # the CLI resolves its siblings at runtime.
  . "$(cd -- "$(dirname -- "$0")" && pwd)/fm-wake-lib.sh"
  # shellcheck disable=SC1091 # the CLI resolves its sibling at runtime.
  . "$(cd -- "$(dirname -- "$0")" && pwd)/fm-secondmate-registry-lib.sh"
  fm_sol_cap_cli "$@"
  exit $?
fi
