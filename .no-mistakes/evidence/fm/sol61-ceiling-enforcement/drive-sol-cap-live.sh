#!/usr/bin/env bash
# Live evidence driver for fm/sol61-ceiling-enforcement (Sol session ceiling,
# capped-launch path). Every scenario drives the REAL bin/fm-spawn.sh inside a
# REAL tmux server on a private socket, from a disposable marked lab home
# (bin/fm-lab-home.sh) whose user data, treehouse pool, and git config all live
# inside the lab. The worker each launch starts is a lab-local probe process so
# the run never needs the operator's credentials or home; it records the argv it
# was handed and the interpreter that ran it, then stays alive like a worker.
#
# Usage: drive-sol-cap-live.sh [bash-ceiling|fish-pane|inert-guard]
set -u

ROOT=/home/art/.no-mistakes/worktrees/9f75ec418609/01M68R6X2YXENR6JHC8966QSSJ
EV=/home/art/.no-mistakes/evidence/01M68R6X2YXENR6JHC8966QSSJ
FISH=/tmp/fishlab/bin/fish
SCENARIO=${1:-bash-ceiling}

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'PASS: %s\n' "$1"; }

make_lab() {  # <naive-model-list> -> populates LAB
  LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || exit 1
  "$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
  mkdir -p "$LAB/tmux" "$LAB/bin" "$LAB/user-home"
  if [ "$1" != inert ]; then
    printf 'max=1\nmodels=probe-sol\n' > "$LAB/config/sol-cap"
  fi
  cat > "$LAB/gitconfig" <<'G'
[user]
	name = Lab Test
	email = lab@example.invalid
[init]
	defaultBranch = main
[safe]
	directory = *
G
  cat > "$LAB/bin/worker" <<'W'
#!/usr/bin/env bash
# Lab worker probe: records the argv it was handed and the interpreter that ran
# it, then stays alive exactly like a worker does.
{
  printf 'argv=%s\n' "$*"
  printf 'shell=%s\n' "$(basename -- "$(ps -o comm= -p "$PPID" 2>/dev/null)")"
  printf 'pid=%s ppid=%s\n' "$$" "$PPID"
} >> "$FM_LAB_WORKER_LOG"
exec sleep 600
W
  chmod +x "$LAB/bin/worker"
  GIT_CONFIG_GLOBAL="$LAB/gitconfig" HOME="$LAB/user-home" \
    git init -q --bare "$LAB/proj.origin.git" || exit 1
  GIT_CONFIG_GLOBAL="$LAB/gitconfig" HOME="$LAB/user-home" \
    git init -q "$LAB/proj" || exit 1
  ( cd "$LAB/proj" && printf 'hello\n' > README.md &&
    GIT_CONFIG_GLOBAL="$LAB/gitconfig" git add README.md &&
    GIT_CONFIG_GLOBAL="$LAB/gitconfig" git commit -qm init &&
    GIT_CONFIG_GLOBAL="$LAB/gitconfig" git remote add origin "$LAB/proj.origin.git" &&
    GIT_CONFIG_GLOBAL="$LAB/gitconfig" git push -q -u origin main ) || exit 1
  mkdir -p "$LAB/data/task-a" "$LAB/data/task-b" "$LAB/data/task-c"
  for id in task-a task-b task-c; do
    cat > "$LAB/data/$id/brief.md" <<B
# Task
## Captain's intent
Live Sol ceiling check: launch a worker under the declared ceiling.

## Firstmate spec
Exercise the capped launch path end to end.
B
  done
}

start_lab_tmux() {  # <default-shell> <subshell-shell>
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
    -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE \
    TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s lab -x 220 -y 50 \
    -c "$ROOT" -e FM_HOME="$LAB" -e HOME="$LAB/user-home" \
    -e FM_LAB_WORKER_LOG="$LAB/worker.log" -e GIT_CONFIG_GLOBAL="$LAB/gitconfig" \
    -e SHELL="$2" -e PATH="$LAB/bin:/tmp/fishlab/bin:$PATH" -- bash || exit 1
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab set -g default-shell "$1" || exit 1
}

write_spawn_runner() {  # <id> <raw-command> [model]
  # The raw launch line carries pane-shell syntax, so it is written verbatim
  # inside single quotes and only the launching shell parses it. It contains no
  # single quote of its own.
  cat > "$LAB/spawn.sh" <<S
#!/usr/bin/env bash
cd "$ROOT" || exit 1
RAW='$2'
FM_HOME="$LAB" FM_SPAWN_NO_GUARD=1 \\
  bin/fm-spawn.sh "$1" "$LAB/proj" --harness "\$RAW" --model ${3:-probe-sol} \\
  --mode no-mistakes --yolo off
echo "SPAWNRC=\$?"
S
  chmod +x "$LAB/spawn.sh"
}

driver_pane() {
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab list-panes -a -F '#{pane_id}' | head -1
}

run_spawn_in_pane() {  # <log-file>
  # A marker newer than any stale launch directory another run left in /tmp,
  # so the evidence names the file THIS spawn staged.
  touch "$LAB/.spawn-start"
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab send-keys -t "$(driver_pane)" \
    "bash $LAB/spawn.sh 2>&1 | tee $1" Enter || exit 1
}

wait_for_file() {  # <path> <samples>
  local i=0
  while [ ! -s "$1" ] && [ "$i" -lt "$2" ]; do sleep 0.5; i=$((i + 1)); done
  [ -s "$1" ]
}

# True when <worker> is <claim> itself or one of its descendants, i.e. the
# claimed process is the live launch process that runs the worker.
worker_under_claim() {  # <claim-pid> <worker-pid>
  local cur=$2 i=0 parent
  while [ -n "$cur" ] && [ "$cur" != 0 ] && [ "$i" -lt 20 ]; do
    [ "$cur" = "$1" ] && return 0
    parent=$(ps -o ppid= -p "$cur" 2>/dev/null | tr -d ' ')
    cur=$parent
    i=$((i + 1))
  done
  return 1
}

row_pid() {  # <id>
  awk -F'\t' -v id="$1" '$1 == id {print $4; exit}' "$LAB/state/sol-sessions.tsv" 2>/dev/null
}

task_window() {  # <id>
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab list-windows -a -F '#{window_name}' |
    grep -qx "fm-$1" && printf 'fm-%s' "$1"
}

capture_evidence() {  # <prefix> <id>
  local p=$1 id=$2 pid
  cp "$LAB/spawn.log" "$EV/$p.spawn.log" 2>/dev/null || true
  cp "$LAB/worker.log" "$EV/$p.worker.log" 2>/dev/null || true
  cp "$LAB/state/sol-sessions.tsv" "$EV/$p.registry.tsv" 2>/dev/null || true
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab capture-pane -p -t "$(task_window "$id")" -S -40 \
    > "$EV/$p.task-pane.txt" 2>/dev/null || true
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab list-panes -a \
    -F '#{window_name} pane=#{pane_id} cmd=#{pane_current_command} path=#{pane_current_path}' \
    > "$EV/$p.panes.txt" 2>/dev/null || true
  pid=$(row_pid "$id")
  {
    printf 'registry pid for %s = %s\n' "$id" "${pid:-<none>}"
    ps -o pid,ppid,stat,comm,args -p "$pid" 2>&1
    printf -- '--- process chain from the worker up to the claimed pid:\n'
    cur=$(sed -n 's/^pid=\([0-9]*\).*/\1/p' "$LAB/worker.log" 2>/dev/null)
    i=0
    while [ -n "$cur" ] && [ "$i" -lt 10 ]; do
      ps -o pid,ppid,stat,comm -p "$cur" 2>/dev/null | tail -n +2
      [ "$cur" = "$pid" ] && break
      cur=$(ps -o ppid= -p "$cur" 2>/dev/null | tr -d ' ')
      i=$((i + 1))
    done
  } > "$EV/$p.row-pid-ps.txt"
  local f
  f=$(find /tmp/fm-"$id"+* -maxdepth 1 -name 'launch.*.sh' -newer "$LAB/.spawn-start" \
    2>/dev/null | head -1)
  [ -n "$f" ] && grep -qF "$LAB" "$f" || f='<no launch file staged by this run>'
  {
    printf '### staged launch file: %s\n' "$f"
    [ ! -f "$f" ] || cat "$f"
  } > "$EV/$p.staged-launch.txt"
}

teardown_lab() {
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server >/dev/null 2>&1 || true
  chmod -R u+w "$LAB" 2>/dev/null
  rm -rf "$LAB"
}

# --- bash pane, capped spawn, then the ceiling refusal ----------------------
scenario_bash_ceiling() {
  make_lab capped
  start_lab_tmux /bin/bash /bin/bash
  write_spawn_runner task-a "$LAB/bin/worker --brief \"\$(cat <(printf %s pane-syntax-bash))\""
  run_spawn_in_pane "$LAB/spawn.log"
  wait_for_file "$LAB/worker.log" 180 || fail "the capped bash launch never started its worker"
  sleep 1
  capture_evidence bash-capped task-a
  grep -q 'SPAWNRC=0' "$LAB/spawn.log" || fail "the capped bash spawn did not succeed: $(cat "$LAB/spawn.log")"
  grep -qx 'argv=--brief pane-syntax-bash' "$LAB/worker.log" \
    || fail "the worker did not receive the bash-only process substitution argument: $(cat "$LAB/worker.log")"
  grep -qx 'shell=bash' "$LAB/worker.log" \
    || fail "the capped launch did not run under the pane's bash: $(cat "$LAB/worker.log")"
  local wpid rpid
  wpid=$(sed -n 's/^pid=\([0-9]*\).*/\1/p' "$LAB/worker.log")
  rpid=$(row_pid task-a)
  [ "$rpid" = "$wpid" ] || fail "the reservation did not move to the worker pid (row=$rpid worker=$wpid)"
  kill -0 "$rpid" 2>/dev/null || fail "the reservation's pid is not alive"
  pass "capped bash-pane spawn ran its bash-only launch line and moved the reservation to worker pid $rpid"

  # Adversarial: the ceiling is full (max=1, one live worker), so a second
  # capped dispatch must be refused without creating anything.
  local meta_before wt_before registry_before
  meta_before=$(ls "$LAB/state" | sort)
  wt_before=$(ls "$LAB/user-home/.treehouse" 2>/dev/null)
  registry_before=$(cat "$LAB/state/sol-sessions.tsv")
  write_spawn_runner task-b "$LAB/bin/worker --brief caps"
  : > "$LAB/spawn-refused.log"
  run_spawn_in_pane "$LAB/spawn-refused.log"
  local i=0
  while ! grep -q 'SPAWNRC' "$LAB/spawn-refused.log" && [ "$i" -lt 120 ]; do sleep 0.5; i=$((i + 1)); done
  cp "$LAB/spawn-refused.log" "$EV/ceiling-refused.spawn.log"
  printf '%s\n' "$registry_before" > "$EV/ceiling-refused.registry-before.tsv"
  cp "$LAB/state/sol-sessions.tsv" "$EV/ceiling-refused.registry-after.tsv"
  { printf 'state entries before: %s\nstate entries after: %s\n' "$meta_before" "$(ls "$LAB/state" | sort)"
    printf 'treehouse pool before: %s\ntreehouse pool after: %s\n' "$wt_before" "$(ls "$LAB/user-home/.treehouse" 2>/dev/null)"; } \
    > "$EV/ceiling-refused.untouched.txt"
  grep -q 'SPAWNRC=1' "$LAB/spawn-refused.log" || fail "the ceiling did not refuse the second capped dispatch: $(cat "$LAB/spawn-refused.log")"
  grep -q 'task-a' "$LAB/spawn-refused.log" || fail "the refusal did not name the active session"
  [ ! -e "$LAB/state/task-b.meta" ] || fail "the refused dispatch published a task record"
  [ "$registry_before" = "$(cat "$LAB/state/sol-sessions.tsv")" ] || fail "the refused dispatch changed the registry"
  [ "$wt_before" = "$(ls "$LAB/user-home/.treehouse" 2>/dev/null)" ] || fail "the refused dispatch created a worktree pool entry"
  pass "a capped dispatch at the ceiling was refused, naming task-a, with no claim and nothing created"

  # Scope: the ceiling covers only the declared models. With the Sol slot still
  # occupied, a dispatch of a model the declaration does not cover must proceed
  # and must not take a slot.
  write_spawn_runner task-b "$LAB/bin/worker --brief not-sol" other-model
  : > "$LAB/spawn-other.log"
  run_spawn_in_pane "$LAB/spawn-other.log"
  i=0
  while ! grep -q 'SPAWNRC' "$LAB/spawn-other.log" && [ "$i" -lt 240 ]; do sleep 0.5; i=$((i + 1)); done
  cp "$LAB/spawn-other.log" "$EV/ceiling-other-model.spawn.log"
  cp "$LAB/state/sol-sessions.tsv" "$EV/ceiling-other-model.registry.tsv"
  grep -q 'SPAWNRC=0' "$LAB/spawn-other.log" \
    || fail "a non-capped model was blocked by the full Sol ceiling: $(cat "$LAB/spawn-other.log")"
  grep -qx 'argv=--brief not-sol' "$LAB/worker.log" \
    || fail "the non-capped dispatch did not start its worker"
  [ "$(row_pid task-b)" = '' ] || fail "a non-capped dispatch took a Sol slot"
  [ "$(awk -F'\t' 'END{print NR}' "$LAB/state/sol-sessions.tsv")" = 1 ] \
    || fail "a non-capped dispatch changed the Sol registry"
  pass "with the Sol ceiling full, a non-capped model still dispatched and took no slot"

  # Occupancy is live process occupancy: ending the capped worker's process frees
  # the slot, and the next capped dispatch is admitted.
  rpid=$(row_pid task-a)
  kill -TERM "$rpid" 2>/dev/null
  i=0
  while kill -0 "$rpid" 2>/dev/null && [ "$i" -lt 60 ]; do sleep 0.5; i=$((i + 1)); done
  kill -0 "$rpid" 2>/dev/null && fail "the capped worker $rpid did not exit"
  write_spawn_runner task-c "$LAB/bin/worker --brief after-release"
  : > "$LAB/spawn-readmit.log"
  run_spawn_in_pane "$LAB/spawn-readmit.log"
  i=0
  while ! grep -q 'SPAWNRC' "$LAB/spawn-readmit.log" && [ "$i" -lt 240 ]; do sleep 0.5; i=$((i + 1)); done
  cp "$LAB/spawn-readmit.log" "$EV/readmit.spawn.log"
  cp "$LAB/state/sol-sessions.tsv" "$EV/readmit.registry.tsv"
  grep -q 'SPAWNRC=0' "$LAB/spawn-readmit.log" \
    || fail "the slot was not released when the worker exited: $(cat "$LAB/spawn-readmit.log")"
  [ -n "$(row_pid task-c)" ] || fail "the re-admitted capped dispatch took no slot"
  grep -qx 'argv=--brief after-release' "$LAB/worker.log" || fail "the re-admitted worker did not start"
  pass "ending the capped worker released its slot, and the next capped dispatch was admitted"
  teardown_lab
}

# --- fish pane, capped spawn ----------------------------------------------
scenario_fish_pane() {
  make_lab capped
  start_lab_tmux "$FISH" "$FISH"
  write_spawn_runner task-a "$LAB/bin/worker --brief (printf %s fish-pane)"
  run_spawn_in_pane "$LAB/spawn.log"
  if ! wait_for_file "$LAB/worker.log" 180; then
    capture_evidence fish-capped task-a
    fail "the capped fish launch never started its worker: $(cat "$LAB/spawn.log")"
  fi
  sleep 1
  capture_evidence fish-capped task-a
  grep -q 'SPAWNRC=0' "$LAB/spawn.log" || fail "the capped fish spawn did not succeed: $(cat "$LAB/spawn.log")"
  grep -qx 'argv=--brief fish-pane' "$LAB/worker.log" \
    || fail "the worker did not receive the fish-only command substitution argument: $(cat "$LAB/worker.log")"
  grep -qx 'shell=fish' "$LAB/worker.log" \
    || fail "the capped launch did not run under the pane's fish: $(cat "$LAB/worker.log")"
  local wpid rpid
  wpid=$(sed -n 's/^pid=\([0-9]*\).*/\1/p' "$LAB/worker.log")
  rpid=$(row_pid task-a)
  [ -n "$rpid" ] || fail "the capped fish launch recorded no reservation row"
  kill -0 "$rpid" 2>/dev/null || fail "the reservation's pid $rpid is not alive"
  # fish -c runs the launch line and waits for the worker instead of exec'ing it,
  # so the reservation belongs to that live launching process: assert the worker
  # is the claimed pid or its descendant, and record the chain.
  worker_under_claim "$rpid" "$wpid" || fail "the reservation pid $rpid is not the worker's launching process (worker=$wpid)"
  pass "capped fish-pane spawn ran its fish-only launch line and moved the reservation to the launching process $rpid (worker $wpid)"
  teardown_lab
}

# --- no declaration: the guard stays inert --------------------------------
scenario_inert_guard() {
  make_lab inert
  start_lab_tmux /bin/bash /bin/bash
  write_spawn_runner task-a "$LAB/bin/worker --brief \"\$(cat <(printf %s pane-syntax-bash))\""
  run_spawn_in_pane "$LAB/spawn.log"
  wait_for_file "$LAB/worker.log" 180 || fail "the uncapped launch never started its worker"
  sleep 1
  capture_evidence inert task-a
  grep -q 'SPAWNRC=0' "$LAB/spawn.log" || fail "the uncapped spawn did not succeed: $(cat "$LAB/spawn.log")"
  grep -qx 'argv=--brief pane-syntax-bash' "$LAB/worker.log" || fail "the uncapped worker invocation changed"
  [ ! -e "$LAB/state/sol-sessions.tsv" ] || fail "an undeclared home wrote a Sol registry"
  grep -q 'run-launch' "$EV/inert.staged-launch.txt" && fail "an undeclared home staged an admission handoff"
  pass "with no config/sol-cap the spawn stayed inert: no handoff, no registry, same worker invocation"
  teardown_lab
}

trap teardown_lab EXIT
case "$SCENARIO" in
  bash-ceiling) scenario_bash_ceiling ;;
  fish-pane) scenario_fish_pane ;;
  inert-guard) scenario_inert_guard ;;
  *) echo "unknown scenario: $SCENARIO" >&2; exit 2 ;;
esac
