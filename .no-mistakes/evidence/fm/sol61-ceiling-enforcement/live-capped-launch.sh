#!/usr/bin/env bash
# Live driver: real fm-spawn.sh, real tmux pane, real bash and fish pane shells,
# real fm-sol-cap-lib.sh run-launch handoff, real Sol registry.
#
# Scenarios:
#   bash-pane     a capped Sol spawn in a bash pane whose launch command uses
#                 bash-only process substitution
#   fish-pane     a capped Sol spawn in a fish pane whose launch command uses
#                 fish-only command substitution
#   inert         the same dispatch with no config/sol-cap: no handoff, no row
#   ceiling       a capped dispatch refused at max=1 by a live worker, then
#                 admitted again once that worker exits
#
# Everything disposable lives under $LAB and is removed at exit. Only the
# transcript and this script under the evidence directory survive.
set -u

ROOT=/home/art/.no-mistakes/worktrees/9f75ec418609/01M691VDGDB84JYENPMK2271TZ
SPAWN=$ROOT/bin/fm-spawn.sh
FISH_BIN_DIR=/nix/store/djgc45v1n9lq05kr5vvg4z03xjj2yqwd-fish-4.2.1/bin
FISH=$FISH_BIN_DIR/fish
EVID=/home/art/.no-mistakes/evidence/01M691VDGDB84JYENPMK2271TZ
LOG=$EVID/live-capped-launch.transcript

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || exit 1
TMUX_DIR=$LAB/tmux
export TMUX_TMPDIR=$TMUX_DIR
LAUNCH_DIRS=()

say() { printf '%s\n' "$*" | tee -a "$LOG"; }
hr() { printf '\n===== %s =====\n' "$*" | tee -a "$LOG"; }
tm() { TMUX_TMPDIR=$TMUX_DIR tmux "$@"; }

cleanup() {
  tm kill-server >/dev/null 2>&1 || true
  local d
  for d in "${LAUNCH_DIRS[@]:-}"; do
    [ -n "$d" ] && rm -rf -- "$d"
  done
  chmod -R u+rwX "$LAB" 2>/dev/null || true
  rm -rf -- "$LAB"
}
trap cleanup EXIT

: >"$LOG"
say "date: $(date -Is)"
say "lab: $LAB"
say "fish: $FISH ($($FISH --version 2>&1))"
say "tmux: $(tmux -V)"

mkdir -p "$TMUX_DIR"
chmod 700 "$TMUX_DIR"

BASE_PATH=/usr/bin:/bin:/usr/sbin:/sbin:/run/current-system/sw/bin

# --- fixture ----------------------------------------------------------------

make_case() {  # <name> -> prints the case dir
  local name=$1 case
  case=$LAB/$name
  mkdir -p "$case"
  # A marked disposable lab home: the gate allowance, per the runbook.
  "$ROOT/bin/fm-lab-home.sh" create "$case/home" >/dev/null || return 1
  cat >"$case/home/config/sol-cap" <<'SOL'
max=4
models=gpt-6.1-sol|gpt-6-sol
SOL
  mkdir -p "$case/home/data/task-c"
  cat >"$case/home/data/task-c/brief.md" <<'BRIEF'
# Task
## Captain's intent
Run a Sol-routed task for task-c.

## Firstmate spec
Exercise the Sol session ceiling.

# Definition of done
Delivery contract: mode=no-mistakes
BRIEF
  # A disposable project with an origin, so spawn's own checks are satisfied.
  git init -q "$case/project" || return 1
  git -C "$case/project" config user.email lab@example.invalid
  git -C "$case/project" config user.name lab
  printf 'lab\n' >"$case/project/README.md"
  git -C "$case/project" add -A
  git -C "$case/project" commit -qm init
  git clone -q --bare "$case/project" "$case/project.origin.git"
  git -C "$case/project" remote add origin "$case/project.origin.git"
  git -C "$case/project" fetch -q origin
  # The worktree the fake treehouse enters.
  git -C "$case/project" worktree add -q -b wt-task-c "$case/wt-task-c" >/dev/null || return 1
  mkdir -p "$case/fakebin"
  # Out-of-scope externals, unchanged by this change: forge tooling.
  local t
  for t in gh gh-axi no-mistakes; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$case/fakebin/$t"
    chmod +x "$case/fakebin/$t"
  done
  printf '%s\n' "$case"
}

add_pane_shell() {  # <case-dir> <pane-shell-path>
  local case=$1 shell=$2
  # `treehouse get`, typed into the pane exactly as spawn does: enter the
  # prepared worktree, then hand the pane back to the same shell spawn found.
  cat >"$case/fakebin/treehouse" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  get)
    cd "$case/wt-task-c" || exit 1
    exec env PATH="$case/fakebin:\$PATH" $shell
    ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$case/fakebin/treehouse"
  # The worker the raw launch command names (addressed by absolute path, so the
  # pane shell's own PATH ordering cannot pick a different binary): records who
  # started it, how its command line was parsed, and where it runs, then holds
  # its slot until it is killed.
  cat >"$case/fakebin/codex" <<SH
#!/usr/bin/env bash
{
  printf 'argv: %s\n' "\$*"
  printf 'argc: %s\n' "\$#"
  printf 'worker_pid: %s\n' "\$\$"
  printf 'worker_ppid: %s\n' "\$PPID"
  printf 'worker_ppid_comm: %s\n' "\$(ps -o comm= -p "\$PPID" 2>/dev/null)"
  printf 'worker_cwd: %s\n' "\$PWD"
  printf 'FM_HOME: %s\n' "\${FM_HOME:-}"
  printf 'started: %s\n' "\$(date -Is)"
} >"$case/worker.txt"
  exec sleep 300
SH
  chmod +x "$case/fakebin/codex"
}

start_server() {  # <pane-shell-path>
  local shell=$1 i=0
  # Recycle only the session, so the private server stays up between scenarios.
  tm has-session -t firstmate 2>/dev/null && tm kill-session -t firstmate >/dev/null 2>&1
  while ! tm has-session -t firstmate 2>/dev/null; do
    tm new-session -d -s firstmate >/dev/null 2>&1 && break
    i=$((i + 1))
    [ "$i" -lt 20 ] || return 1
    sleep 0.2
  done
  # spawn creates its own window, and that window runs default-command, whose
  # PATH is what the pane keeps (a login profile would otherwise reset it) and
  # whose program is the pane shell under test.
  tm set -g default-shell "$shell" || return 1
  tm set -g default-command "env PATH=$CASE/fakebin:$BASE_PATH:$FISH_BIN_DIR $shell" || return 1
  tm set -g status off
  tm show -g default-shell
  tm show -g default-command
}

spawn_args() {  # <case-dir> <task-id> <capped|uncapped> <raw-launch> [<model>]
  local case=$1 id=$2 mode=$3 raw=$4 model=${5:-gpt-6.1-sol}
  [ "$mode" = capped ] || rm -f "$case/home/config/sol-cap"
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
    -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    -u TMUX FM_SPAWN_NO_GUARD=1 \
    FM_HOME="$case/home" FM_BACKEND=tmux TMUX_TMPDIR="$TMUX_DIR" \
    PATH="$case/fakebin:$BASE_PATH:$FISH_BIN_DIR" \
    "$SPAWN" "$id" "$case/project" --harness "$raw" --model "$model" \
    --mode no-mistakes --yolo off 2>&1
}

launch_file() {  # [<not-before-epoch>]
  local limit=${1:-0} f newest= mtime newest_mtime=0
  for f in /tmp/fm-task-c+*/launch.*.sh; do
    [ -f "$f" ] || continue
    mtime=$(stat -c %Y "$f" 2>/dev/null) || continue
    [ "$mtime" -ge "$limit" ] || continue
    if [ "$mtime" -ge "$newest_mtime" ]; then
      newest=$f
      newest_mtime=$mtime
    fi
  done
  [ -n "$newest" ] && printf '%s\n' "$newest"
}

registry_rows() { cat "$1/home/state/sol-sessions.tsv" 2>/dev/null || echo '(no registry file)'; }

row_pid() { awk -F'\t' -v id="$2" '$1 == id {print $4; exit}' "$1/home/state/sol-sessions.tsv" 2>/dev/null; }

describe_pid() { ps -o pid=,ppid=,comm=,args= -p "${1:-0}" 2>/dev/null | cut -c1-170; }

# The row pid, the worker pid, and the worker's parent, in one place.
process_tree() {  # <case-dir>
  local row worker
  row=$(row_pid "$1" task-c)
  worker=$(field "$1" worker_pid)
  say "pid|ppid|comm|args for the row pid and the worker:"
  ps -o pid=,ppid=,comm=,args= -p "${row:-0},${worker:-0},$(field "$1" worker_ppid)" 2>/dev/null |
    cut -c1-170 | tee -a "$LOG"
}

alive() { [ -n "${1:-}" ] && kill -0 "$1" 2>/dev/null && echo yes || echo no; }

pane_capture() { local n=${1:-24}; tm capture-pane -p -t firstmate:fm-task-c 2>/dev/null | grep -v '^$' | tail -"$n"; }

wait_for_worker() {  # <case-dir> <timeout-seconds>
  local case=$1 limit=$2 i=0
  while [ "$i" -lt $((limit * 5)) ]; do
    [ -s "$case/worker.txt" ] && return 0
    sleep 0.2
    i=$((i + 1))
  done
  return 1
}

field() { awk -F': ' -v k="$2" '$1 == k {print $2; exit}' "$1/worker.txt" 2>/dev/null; }

# --- scenario: bash pane -----------------------------------------------------
scenario_bash() {
  local case out pid started lf
  hr "scenario: capped spawn in a bash pane (bash-only process substitution)"
  case=$(make_case bash-pane) || { say "fixture failed"; return 1; }
  CASE=$case
  add_pane_shell "$case" /bin/bash
  start_server /bin/bash || { say "tmux server failed"; return 1; }
  started=$(date +%s)
  # bash-only syntax: process substitution, which /bin/sh cannot parse.
  # shellcheck disable=SC2016
  out=$(spawn_args "$case" task-c capped "$case/fakebin/codex --brief \"\$(cat <(printf %s pane-syntax))\"")
  say "spawn output:"
  say "$out"
  wait_for_worker "$case" 20 || say "!! the worker never started"
  say ""
  say "pane foreground command: $(tm display-message -p -t firstmate:fm-task-c '#{pane_current_command}' 2>/dev/null)"
  if lf=$(launch_file "$started"); then
    LAUNCH_DIRS+=("$(dirname "$lf")")
    say "staged launch line the bash pane sourced:"
    say "  $(cat "$lf")"
  else
    say "staged launch line: <none found>"
  fi
  say ""
  say "worker record:"
  cat "$case/worker.txt" 2>/dev/null | tee -a "$LOG" || say "  <no worker record>"
  pid=$(row_pid "$case" task-c)
  say ""
  say "registry rows while the worker runs:"
  registry_rows "$case" | tee -a "$LOG"
  say "row pid for task-c: ${pid:-<none>}"
  say "row pid alive: $(alive "${pid:-}")"
  process_tree "$case"
  say ""
  say "pane tail:"
  pane_capture 20 | tee -a "$LOG"
  BASH_ROW_PID=$pid
  BASH_WORKER_PID=$(field "$case" worker_pid)
  SCEN_BASH_ARGV=$(field "$case" argv)
  BASH_PPID_COMM=$(field "$case" worker_ppid_comm)
  BASH_CASE=$case
}

# --- scenario: fish pane -----------------------------------------------------
scenario_fish() {
  local case out pid started lf
  hr "scenario: capped spawn in a fish pane (fish-only command substitution)"
  case=$(make_case fish-pane) || { say "fixture failed"; return 1; }
  CASE=$case
  add_pane_shell "$case" "$FISH"
  start_server "$FISH" || { say "tmux server failed"; return 1; }
  started=$(date +%s)
  # fish-only syntax: parenthesised command substitution, which /bin/sh rejects.
  # shellcheck disable=SC2016
  out=$(spawn_args "$case" task-c capped "$case/fakebin/codex --brief (printf %s fish-pane)")
  say "spawn output:"
  say "$out"
  wait_for_worker "$case" 20 || say "!! the worker never started"
  say ""
  say "pane foreground command: $(tm display-message -p -t firstmate:fm-task-c '#{pane_current_command}' 2>/dev/null)"
  if lf=$(launch_file "$started"); then
    LAUNCH_DIRS+=("$(dirname "$lf")")
    say "staged launch line the fish pane sourced:"
    say "  $(cat "$lf")"
  else
    say "staged launch line: <none found>"
  fi
  say ""
  say "worker record:"
  cat "$case/worker.txt" 2>/dev/null | tee -a "$LOG" || say "  <no worker record>"
  pid=$(row_pid "$case" task-c)
  say ""
  say "registry rows while the worker runs:"
  registry_rows "$case" | tee -a "$LOG"
  say "row pid for task-c: ${pid:-<none>}"
  say "row pid alive: $(alive "${pid:-}")"
  process_tree "$case"
  say "row pid == worker pid: $([ "${pid:-none}" = "$(field "$case" worker_pid)" ] && echo yes || echo no)"
  say "row pid == worker's parent: $([ "${pid:-none}" = "$(field "$case" worker_ppid)" ] && echo yes || echo no)"
  say ""
  say "pane tail:"
  pane_capture 20 | tee -a "$LOG"
  FISH_ROW_PID=$pid
  FISH_WORKER_PID=$(field "$case" worker_pid)
  SCEN_FISH_ARGV=$(field "$case" argv)
  FISH_PPID_COMM=$(field "$case" worker_ppid_comm)
  FISH_CASE=$case
}

# --- scenario: inert (no declaration) ---------------------------------------
scenario_inert() {
  local case out lf started
  hr "scenario: the same dispatch with no config/sol-cap stays inert"
  case=$(make_case inert) || { say "fixture failed"; return 1; }
  CASE=$case
  add_pane_shell "$case" /bin/bash
  start_server /bin/bash || { say "tmux server failed"; return 1; }
  started=$(date +%s)
  # shellcheck disable=SC2016
  out=$(spawn_args "$case" task-c uncapped "$case/fakebin/codex --brief \"\$(cat <(printf %s pane-syntax))\"")
  say "spawn output:"
  say "$out"
  wait_for_worker "$case" 20 || say "!! the worker never started"
  say ""
  say "declaration present: $([ -e "$case/home/config/sol-cap" ] && echo yes || echo no)"
  if lf=$(launch_file "$started"); then
    LAUNCH_DIRS+=("$(dirname "$lf")")
    say "staged launch line the bash pane sourced:"
    say "  $(cat "$lf")"
  else
    say "staged launch line: <none found>"
  fi
  say ""
  say "worker record:"
  cat "$case/worker.txt" 2>/dev/null | tee -a "$LOG" || say "  <no worker record>"
  say ""
  say "registry rows:"
  registry_rows "$case" | tee -a "$LOG"
  say "row pid for task-c: $(row_pid "$case" task-c)"
  SCEN_INERT_ARGV=$(field "$case" argv)
}

# --- scenario: ceiling refusal and release ----------------------------------
scenario_ceiling() {
  local case out pid before out2 pid2
  hr "scenario: a second capped dispatch is refused at the ceiling, then admitted once the worker exits"
  case=$(make_case ceiling) || { say "fixture failed"; return 1; }
  CASE=$case
  printf 'max=1\nmodels=gpt-6.1-sol\n' >"$case/home/config/sol-cap"
  cp -r "$case/home/data/task-c" "$case/home/data/task-d"
  add_pane_shell "$case" /bin/bash
  start_server /bin/bash || { say "tmux server failed"; return 1; }
  # shellcheck disable=SC2016
  out=$(spawn_args "$case" task-c capped "$case/fakebin/codex --brief \"\$(cat <(printf %s pane-syntax))\"")
  say "first spawn:"
  say "$out"
  wait_for_worker "$case" 20 || say "!! the first worker never started"
  pid=$(row_pid "$case" task-c)
  say ""
  say "registry rows (max=1):"
  registry_rows "$case" | tee -a "$LOG"
  say "live worker row pid: ${pid:-<none>} alive: $(alive "${pid:-}")"
  say ""
  before=$(git -C "$case/project" worktree list | wc -l)
  # shellcheck disable=SC2016
  out=$(spawn_args "$case" task-d capped "$case/fakebin/codex --brief \"\$(cat <(printf %s pane-syntax))\"")
  say "second capped spawn at the ceiling:"
  say "$out"
  say ""
  say "task-d record after the refusal: $(ls "$case/home/state/task-d.meta" 2>/dev/null || echo absent)"
  say "task-d launch brief after the refusal: $(ls "$case/home/data/task-d/launch-brief.md" 2>/dev/null || echo absent)"
  say "git worktree count before/after the refusal: $before/$(git -C "$case/project" worktree list | wc -l)"
  say ""
  say "now stop the live worker and retry the same capped dispatch:"
  kill "$(field "$case" worker_pid)" 2>/dev/null || true
  kill "${pid:-0}" 2>/dev/null || true
  sleep 1
  say "row pid alive after the worker exit: $(alive "${pid:-}")"
  out2=$(spawn_args "$case" task-d capped "$case/fakebin/codex --brief \"\$(cat <(printf %s pane-syntax))\"")
  say "$out2"
  local i=0
  pid2=$(row_pid "$case" task-d)
  while { [ -z "$pid2" ] || [ "$pid2" = 0 ]; } && [ "$i" -lt 50 ]; do
    sleep 0.2
    pid2=$(row_pid "$case" task-d)
    i=$((i + 1))
  done
  say "task-d row pid: ${pid2:-<none>} alive: $(alive "${pid2:-}")"
  say ""
  say "registry rows after the release and the admitted retry:"
  registry_rows "$case" | tee -a "$LOG"
}



# --- scenario: busy admission boundary --------------------------------------
scenario_busy_boundary() {
  local case out holder marker lf i pid2
  hr "scenario: a busy admission boundary keeps the invalidation pending, and the next admission applies it"
  case=$(make_case busy-boundary) || { say "fixture failed"; return 1; }
  printf 'max=2\nmodels=gpt-6.1-sol\n' >"$case/home/config/sol-cap"
  # This task id owns a row that claims no slot: a confirmed stop marker, kept
  # as evidence because the task record is still published.
  printf 'model=gpt-6.1-sol\nkind=ship\n' >"$case/home/state/task-c.meta"
  printf 'task-c\tgpt-6.1-sol\t%s\t-1\n' "$(date +%s)" >"$case/home/state/sol-sessions.tsv"
  mkdir -p "$case/home/data/task-d"
  cp "$case/home/data/task-c/brief.md" "$case/home/data/task-d/brief.md"
  CASE=$case
  add_pane_shell "$case" /bin/bash
  start_server /bin/bash || { say "tmux server failed"; return 1; }
  # A live holder keeps the admission boundary busy past the brief wait.
  mkdir -p "$case/home/state/.sol-cap.lock" || { say "could not stage the busy boundary"; return 1; }
  sleep 300 &
  holder=$!
  printf '%s\n' "$holder" >"$case/home/state/.sol-cap.lock/pid"
  say "admission boundary held by pid $holder: $(alive "$holder")"
  say ""
  # An uncapped model on a task id that already has a row: this dispatch
  # reserves no slot, so the ceiling must never refuse it.
  # shellcheck disable=SC2016
  out=$(spawn_args "$case" task-c capped "$case/fakebin/codex --brief \"\$(cat <(printf %s pane-syntax))\"" gpt-5.6-luna)
  say "spawn output with the boundary busy:"
  say "$out"
  say ""
  say "registry rows while the boundary is still busy (the prior row must be untouched):"
  registry_rows "$case" | tee -a "$LOG"
  marker=$case/home/state/.sol-cap-supersede-task-c
  say "pending marker $marker: $([ -f "$marker" ] && echo present || echo absent)"
  [ -f "$marker" ] && say "  marker content (start<TAB>pid): $(cat "$marker")"
  say "staging leftovers: $(ls -d "$case"/home/state/.sol-cap-supersede.tmp.* 2>/dev/null | wc -l)"
  say ""
  kill "$holder" 2>/dev/null || true
  rm -rf -- "$case/home/state/.sol-cap.lock"
  say "boundary released; the next admission is an ordinary capped dispatch for task-d:"
  # shellcheck disable=SC2016
  out=$(spawn_args "$case" task-d capped "$case/fakebin/codex --brief \"\$(cat <(printf %s pane-syntax))\"")
  say "$out"
  i=0
  while [ -z "$(row_pid "$case" task-d)" ] || [ "$(row_pid "$case" task-d)" = 0 ]; do
    sleep 0.2
    i=$((i + 1))
    [ "$i" -lt 50 ] || break
  done
  say ""
  say "registry rows after that admission:"
  registry_rows "$case" | tee -a "$LOG"
  say "marker after that admission: $([ -f "$marker" ] && echo present || echo absent)"
  say "task-c prior row pid after that admission: $(row_pid "$case" task-c) (empty means resolution removed a row whose record names no live incarnation; -3 means it is held as superseded)"
  say "task-d new row pid: $(row_pid "$case" task-d) alive: $(alive "$(row_pid "$case" task-d)")"
}

# --- scenario: storage failure on the pending marker -------------------------
scenario_storage_failure() {
  local case out holder
  hr "scenario: a state-directory failure refuses the dispatch instead of launching it uncounted"
  case=$(make_case storage-failure) || { say "fixture failed"; return 1; }
  printf 'max=2\nmodels=gpt-6.1-sol\n' >"$case/home/config/sol-cap"
  # The task id already owns a row that claims no slot (a confirmed stop).
  printf 'task-c\tgpt-6.1-sol\t%s\t-1\n' "$(date +%s)" >"$case/home/state/sol-sessions.tsv"
  # A live holder keeps the admission boundary busy past the brief wait.
  mkdir -p "$case/home/state/.sol-cap.lock" || { say "could not stage the busy boundary"; return 1; }
  sleep 300 &
  holder=$!
  printf '%s\n' "$holder" >"$case/home/state/.sol-cap.lock/pid"
  say "admission boundary held by pid $holder: $(alive "$holder")"
  # The state directory can no longer publish the pending marker.
  chmod 0555 "$case/home/state"
  # shellcheck disable=SC2016
  out=$(spawn_args "$case" task-c capped "$case/fakebin/codex --brief \"\$(cat <(printf %s pane-syntax))\"" gpt-5.6-luna)
  chmod 0755 "$case/home/state"
  kill "$holder" 2>/dev/null || true
  rm -rf -- "$case/home/state/.sol-cap.lock"
  say "spawn output:"
  say "$out"
  say ""
  say "registry rows after the refused dispatch:"
  registry_rows "$case" | tee -a "$LOG"
  say "task record after the refusal: $(ls "$case/home/state/task-c.meta" 2>/dev/null || echo absent)"
  say "worker record after the refusal: $(ls "$case/worker.txt" 2>/dev/null || echo absent)"
  STORAGE_OUT=$out
  say ""
  say "the same failure at the guard CLI seam (bin/fm-sol-cap-lib.sh refuse-claim),"
  say "which is the runtime entry point docs/configuration.md publishes:"
  local holder2 rc=0 cli
  mkdir -p "$case/home/state/.sol-cap.lock"
  sleep 300 &
  holder2=$!
  printf '%s\n' "$holder2" >"$case/home/state/.sol-cap.lock/pid"
  chmod 0555 "$case/home/state"
  cli=$(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
    -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$case/home" PATH="$case/fakebin:$BASE_PATH:$FISH_BIN_DIR" \
    bash "$ROOT/bin/fm-sol-cap-lib.sh" refuse-claim task-c ship codex gpt-5.6-luna \
    "$case/home/config" "$case/home/state" 2>&1) || rc=$?
  chmod 0755 "$case/home/state"
  kill "$holder2" 2>/dev/null || true
  rm -rf -- "$case/home/state/.sol-cap.lock"
  say "exit status: $rc"
  say "$cli"
  say "registry rows after the CLI refusal:"
  registry_rows "$case" | tee -a "$LOG"
  say "pending marker files left behind: $(ls -d "$case"/home/state/.sol-cap-supersede-* 2>/dev/null | wc -l)"
  say "staging leftovers: $(ls -d "$case"/home/state/.sol-cap-supersede.tmp.* 2>/dev/null | wc -l)"
}

scenario_bash
scenario_fish
scenario_inert
scenario_ceiling
scenario_busy_boundary
scenario_storage_failure

hr "summary"
say "bash pane: row pid=${BASH_ROW_PID:-<none>} worker pid=${BASH_WORKER_PID:-<none>} worker argv=[${SCEN_BASH_ARGV:-}] worker's parent shell=${BASH_PPID_COMM:-}"
say "fish pane: row pid=${FISH_ROW_PID:-<none>} worker pid=${FISH_WORKER_PID:-<none>} worker argv=[${SCEN_FISH_ARGV:-}] worker's parent shell=${FISH_PPID_COMM:-}"
say "inert run: worker argv=[${SCEN_INERT_ARGV:-}]"
say "capped bash worker argv == inert worker argv: $([ "${SCEN_BASH_ARGV:-x}" = "${SCEN_INERT_ARGV:-y}" ] && echo yes || echo no)"
say "lab removed at exit: $LAB"
