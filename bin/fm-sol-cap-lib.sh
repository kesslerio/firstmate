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
# counting itself. A dispatch with no Sol model never claims a slot and passes
# untouched.
#
# The count: <state-dir>/sol-sessions.tsv, one TSV row per Sol session
#
#   <session-id>	<model>	<start-epoch>	<pid>
#
# <pid> is the pid of the worker's pane shell on the default tmux session
# provider, filled in by this file's promotion step after the launch, and 0
# when no backend surface answers one. A fresh spawn reserves its row under
# <state-dir>/.sol-cap.lock with the spawning fm-spawn process's own pid,
# which dies with a failed dispatch, so an aborted spawn cannot hold a slot;
# reserve, prune, and promotion all mutate a registry under that lock.
#
# Staleness: an entry does not count when it is older than
# FM_SOL_STALE_SECONDS (6h, so a registered remote worker this machine cannot
# inspect ages out instead of holding a slot forever) or when its recorded pid
# is not alive. Teardown-time release is a deliberately unwritten future
# boundary; these two rules are the ceiling's current release path, and the
# release usually arrives for free, because a tmux pane shell dies when its
# worker exits.
#
# Home scope: bin/fm-spawn.sh counts live entries in every local Firstmate
# home's state directory on this machine (bin/fm-wake-lib.sh's
# fm_local_firstmate_state_dirs, the same surface
# bin/fm-project-capacity-lib.sh counts through), not through a shared
# hostname registry, so the guard follows one existing machine-scope precedent
# instead of inventing a second one. Registered remote homes are never
# walked, because their workers run on another machine; a remote secondmate
# is counted in the dispatching home. The no-mistakes daemon's internal
# gate/review agent spawns are one documented boundary: the shared daemon is
# installed fleet infrastructure whose global config owns its agent surface
# (agent:, agent_config:, agent_path_override in the operating no-mistakes
# config.yaml), its binary lives outside this repository, and a task must not
# administer it, so those spawns stay outside this count until whoever owns
# that instance wires a hook to conform to this contract.
#
# Refusal, not queueing: a dispatch at the cap refuses with one actionable
# error naming the active sessions and their ages, and leaves the task
# unlaunched. The dispatch contract refuses rather than queues a wait with no
# bounded end.
#
# Requires bin/fm-wake-lib.sh (fm_pid_alive, fm_lock_try_acquire, and the
# local-home enumeration), bin/fm-secondmate-registry-lib.sh to be sourced
# first (as bin/fm-spawn.sh already does), and jq. No side effects on source.

# The captain's filed four-session Sol ceiling (2026-09-29, "four-session Sol
# ceiling"), overridable by one positive integer in config/sol-cap.
# shellcheck disable=SC2034 # read by bin/fm-spawn.sh after sourcing.
FM_SOL_CAP_DEFAULT=4

# An entry older than this is stale by age even when its pid cannot be
# checked (0) or when the worker this machine cannot inspect still runs.
# shellcheck disable=SC2034 # read by fm_sol_cap_entry_live below and the
# prune-style callers of it.
FM_SOL_STALE_SECONDS=21600

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
  cap=$(sed -n 's/^[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p' "$file" | head -n1)
  [ -n "$cap" ] || {
    FM_SOL_CEILING_ERROR="$file is not a single positive integer"
    return 1
  }
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

# fm_sol_cap_entry_live <start> <pid> <now>
# Zero exit when a registry row still holds a live Sol session: a start epoch
# no more than one hour in the future, younger than FM_SOL_STALE_SECONDS by
# age, and carrying either no recorded pid (0, age-bound only) or an alive
# pid. A start more than one hour in the future reads as a bogus clock rather
# than a live session, because refusing every dispatch on one bad row would
# let a registry line stop the whole fleet.
fm_sol_cap_entry_live() {  # <start> <pid> <now>
  local start=$1 pid=$2 now=$3
  case "$start" in '' | *[!0-9]*) return 1 ;; esac
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  if [ "$pid" -gt 0 ] && ! fm_pid_alive "$pid"; then
    return 1
  fi
  if [ "$start" -gt "$now" ]; then
    [ $((start - now)) -le 3600 ]
    return
  fi
  [ $((now - start)) -lt "$FM_SOL_STALE_SECONDS" ]
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
      # A stale row is legal release, not a refusal: old entries do not count.
      fm_sol_cap_entry_live "$start" "$pid" "$now" || continue
      [ "$id" != "$own" ] || continue
      age=$((now > start ? now - start : 0))
      local entry
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
    grep -Fv -e "${id}$(printf '\t')" "$file" > "$tmp" 2>/dev/null
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
  local id=$1 kind=$2 harness=$3 model=$4 config=$5 state=$6 registry now
  FM_SOL_CAP_REFUSAL=
  FM_SOL_CLAIM_CREATED=
  [ -n "$model" ] && [ "$model" != default ] || return 0
  [ -n "$id" ] || return 0
  fm_sol_cap_model_set "$config" || {
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
  if ! fm_sol_cap_lock_acquire "$state/$FM_SOL_LOCK_NAME" "task $id"; then
    return 1
  fi
  registry=$state/$FM_SOL_REGISTRY_NAME
  # The count again under the lock, so two spawns racing the count cannot
  # both take the last slot (active_count is this ceiling's decision pass).
  if ! fm_sol_cap_active_count "$state" "$id"; then
    FM_SOL_CAP_REFUSAL="error: Sol ceiling could not count its sessions: $FM_SOL_COUNT_ERROR; task $id with model $model was not dispatched rather than launched possibly uncounted"
    fm_lock_release "$state/$FM_SOL_LOCK_NAME" || true
    return 1
  fi
  if [ "$FM_SOL_COUNT" -ge "$FM_SOL_CAP" ]; then
    FM_SOL_CAP_REFUSAL="error: Sol ceiling reached: $FM_SOL_COUNT concurrent Sol session(s) already active and this ceiling is $FM_SOL_CAP (config/sol-cap in this home raises it); the dispatch of task $id ($harness, $model) was refused. Active sessions: $FM_SOL_ACTIVE_LIST. A session frees its slot when its worker's process ends, or after 6h by age; the dispatch contract refuses at the ceiling instead of queueing"
    fm_lock_release "$state/$FM_SOL_LOCK_NAME" || true
    return 1
  fi
  now=$(fm_epoch_seconds_to FM_SOL_CAP_NOW; printf '%s' "$FM_SOL_CAP_NOW")
  # Keep every walked registry bounded: stale rows are the release path, and
  # once they are no longer counted they do not need to sit in the file. A
  # malformed row is deliberately left in place for its loud refusal.
  for local_home in "${FM_LOCAL_FIRSTMATE_STATES[@]}"; do
    fm_sol_cap_registry_prune "$local_home/$FM_SOL_REGISTRY_NAME" "$now"
  done
  if ! fm_sol_cap_registry_claim "$registry" "$id" "$model" "$now"; then
    FM_SOL_CAP_REFUSAL="error: Sol ceiling: the claim of task $id in $registry could not be written; the dispatch was refused rather than launched uncounted"
    fm_lock_release "$state/$FM_SOL_LOCK_NAME" || true
    return 1
  fi
  FM_SOL_CLAIM_CREATED=$id
  fm_lock_release "$state/$FM_SOL_LOCK_NAME" || true
  return 0
}

# fm_sol_cap_promote <id> <backend> <target> <state-dir>
# After a successful launch, replace the reservation pid with the worker's
# own liveness surface: the tmux pane shell's pid for the default tmux
# backend, and 0 for every backend that does not expose one (age-bound only).
# A claimed row for <id> exists only for Sol models, so promotion of any
# other dispatch is a no-op. Atomicity rides the same ceiling lock as the
# claim, so a parallel dispatch cannot corrupt the rewrite; a failed
# promotion returns 1 for its caller to warn about, and the row then decays
# by its stale reservation pid instead.
fm_sol_cap_promote() {  # <id> <backend> <target> <state-dir>
  local id=$1 backend=$2 target=$3 state=$4 registry file tmp pid pane model start rc
  FM_SOL_CAP_PROMOTED=
  registry=$state/$FM_SOL_REGISTRY_NAME
  if [ ! -f "$registry" ] || [ ! -r "$registry" ]; then
    return 0
  fi
  grep -Fq -e "${id}$(printf '\t')" "$registry" || return 0
  fm_sol_cap_lock_acquire "$state/$FM_SOL_LOCK_NAME" "the promotion of task $id" || return 1
  pid=0
  if [ "$backend" = tmux ]; then
    pane=$(tmux list-panes -t "$target" -F '#{pane_pid}' 2>/dev/null | head -n1)
    case "$pane" in
    '' | *[!0-9]* | 0) ;;
    *) pid=$pane ;;
    esac
  fi
  tmp=$registry.tmp.$$
  grep -Fv -e "${id}$(printf '\t')" "$registry" > "$tmp" 2>/dev/null
  rc=$?
  [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ] || {
    rm -f -- "$tmp"
    FM_SOL_CAP_REFUSAL="error: Sol ceiling: the promotion of task $id could not rewrite $registry"
    fm_lock_release "$state/$FM_SOL_LOCK_NAME" || true
    return 1
  }
  model=$(awk -F'\t' -v id="$id" '$1 == id {print $2; exit}' "$registry")
  start=$(awk -F'\t' -v id="$id" '$1 == id {print $3; exit}' "$registry")
  if ! printf '%s\t%s\t%s\t%s\n' "$id" "$model" "$start" "$pid" >> "$tmp"; then
    rm -f -- "$tmp"
    FM_SOL_CAP_REFUSAL="error: Sol ceiling: the promotion of task $id could not rewrite $registry"
    fm_lock_release "$state/$FM_SOL_LOCK_NAME" || true
    return 1
  fi
  mv -- "$tmp" "$registry" || {
    rm -f -- "$tmp"
    FM_SOL_CAP_REFUSAL="error: Sol ceiling: the promotion of task $id could not rewrite $registry"
    fm_lock_release "$state/$FM_SOL_LOCK_NAME" || true
    return 1
  }
  FM_SOL_CAP_PROMOTED=$id
  fm_lock_release "$state/$FM_SOL_LOCK_NAME" || true
  return 0
}

# fm_sol_cap_registry_prune <registry-file> <now>
# Drop the registry rows that no longer hold a live session (stale by their
# age or by their dead pid, the ceiling's current release path), so old rows
# do not accumulate forever. Every otherwise live row stays, and so does
# every malformed row, because pruning it silently would hide a disruption
# from fm_sol_cap_active_count's loud refusal. Called under the ceiling
# claim lock; the rewrite lands in one atomic mv.
fm_sol_cap_registry_prune() {  # <registry-file> <now>
  local file=$1 now=$2 tmp rc
  [ -f "$file" ] && [ -r "$file" ] || return 0
  tmp=$file.tmp.prune.$$
  # One pass: malformed rows (kept loud) print first, live rows print, stale
  # rows fall through silently.
  awk -F'\t' -v now="$now" -v max="$FM_SOL_STALE_SECONDS" '
    $1 == "" {next}
    $2 == "" || $3 !~ /^[0-9]+$/ || ($4 != "" && $4 !~ /^[0-9]+$/) {print; next}
    {
      start = $3 + 0
      if (start > now && start - now > 3600) next
      if ((start <= now ? now - start : 0) >= max) next
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
