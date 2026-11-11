#!/usr/bin/env bash
# Independent live driver for the project-capacity change under validation.
# It drives the REAL bin/fm-spawn.sh executable end-to-end against a disposable
# Firstmate home, a real git project clone with a real origin, and real
# state/<id>.meta + state/<id>.status records. Only the terminal multiplexer,
# the worktree pool, gh and no-mistakes are simple boundary shims (the product
# never exercises mux semantics here; admission decisions, records, status
# history, reservations and backlog files are all real files).
#
# Independent oracle: docs/configuration.md "Project capacity" and
# bin/fm-spawn.sh --help state the contract used for every expectation:
#   - a scout or local-only ship that records `done` frees its place,
#   - a no-mistakes ship keeps its place after `done`,
#   - a relaunch of a completed scout/local-only ship reserves its place until
#     its status log records `working` or `done` after the reservation offset,
#   - bookkeeping alone never expires a reservation,
#   - a proven non-launch removes the reservation; an unreadable reservation
#     holds a place.
# A wrong implementation that still leaves `done` as an occupant, that treats
# any log growth as expiry, or that releases an aborted relaunch would fail
# these assertions.
set -u
REPO=${FM_DRIVER_REPO:-$(git rev-parse --show-toplevel)}
# shellcheck source=/dev/null
. "$REPO/tests/lib.sh"
unset TASKS_AXI_BACKEND || :
SPAWN="$ROOT/bin/fm-spawn.sh"
DEFER_EXIT=75
TMP=$(fm_test_tmproot fm-capacity-live)
FAILS=0

say() { printf '\n== %s\n' "$*"; }
ok() { printf 'PASS - %s\n' "$*"; }
bad() { printf 'FAIL - %s\n' "$*" >&2; FAILS=$((FAILS + 1)); }
expect_rc() { [ "$2" = "$1" ] && ok "$3 (exit $2)" || bad "$3: expected exit $1, got $2: $4"; }
contains() { case "$1" in *"$2"*) ok "$3";; *) bad "$3: output lacks [$2]: $1";; esac; }

brief() {  # <home> <id> [mode]
  mkdir -p "$1/data/$2"
  cat > "$1/data/$2/brief.md" <<EOF
# Task
## Captain's intent
Run the project's heavy suite for $2.

## Firstmate spec
Exercise project capacity admission.

# Definition of done
Delivery contract: mode=${3:-no-mistakes}
EOF
}

home_init() {  # <home> <id...>
  local home=$1 id
  shift
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' codex > "$home/config/crew-harness"
  if command -v tasks-axi >/dev/null 2>&1; then
    printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' > "$home/data/backlog.md"
    printf 'backend = "markdown"\n\n[markdown]\npath = "data/backlog.md"\n' > "$home/.tasks.toml"
  fi
  for id in "$@"; do
    brief "$home" "$id"
    if command -v tasks-axi >/dev/null 2>&1; then
      tasks-axi add "$id" "item for $id" --kind ship --file "$home/data/backlog.md" >/dev/null
    fi
  done
}

case_init() {  # <name> [ids...]
  local name=$1 dir fakebin
  shift
  dir="$TMP/$name"
  mkdir -p "$dir"
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_CALL_LOG"
w="$FM_FAKE_CALL_LOG.window"
case "$*" in
  *'#{pane_current_command}'*) printf 'bash\n'; exit 0 ;;
  *'#{pane_current_path}')
    if [ -n "${FM_FAKE_HOLD:-}" ]; then
      : > "$FM_FAKE_HOLD.reached"
      i=0
      while [ ! -f "$FM_FAKE_HOLD.release" ]; do
        i=$((i + 1)); [ "$i" -lt 600 ] || exit 1; sleep 0.05
      done
    fi
    printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  send-keys)
    case "${5:-}" in '. '*) : > "$FM_FAKE_CALL_LOG.launch-text" ;; esac
    if [ -f "$FM_FAKE_CALL_LOG.launch-text" ] && [ -n "${FM_FAKE_SEND_HOLD:-}" ] && [ "${4:-}" = -l ]; then
      : > "$FM_FAKE_SEND_HOLD.reached"
      i=0
      while [ ! -f "$FM_FAKE_SEND_HOLD.release" ]; do
        i=$((i + 1)); [ "$i" -lt 600 ] || exit 1; sleep 0.05
      done
    fi ;;
  display-message) printf 'firstmate\n' ;;
  list-windows) [ ! -s "$w" ] || cat "$w" ;;
  new-window)
    name=; prev=
    for a in "$@"; do [ "$prev" = -n ] && name=$a; prev=$a; done
    grep -Fqx -- "$name" "$w" 2>/dev/null || printf '%s\n' "$name" >> "$w" ;;
  kill-window)
    t=; prev=
    for a in "$@"; do [ "$prev" = -t ] && t=$a; prev=$a; done
    t=${t##*:}; t=${t#=}
    grep -Fvx -- "$t" "$w" 2>/dev/null > "$w.tmp" || true; mv "$w.tmp" "$w" ;;
esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse %s\n' "$*" >> "$FM_FAKE_CALL_LOG"
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" gh gh-axi no-mistakes
  : > "$dir/calls.log"
  fm_git_init_commit "$dir/project"
  fm_git_add_origin "$dir/project" "$dir/project.origin.git"
  home_init "$dir/home" "$@"
  printf '%s\n' "$dir"
}

declare_capacity() { local h=$1; shift; printf '%s\n' "$@" > "$h/config/project-capacity"; }

live_worker() {  # <dir> <id> [kind] [mode] [status...]
  local dir=$1 id=$2 kind=${3:-ship} mode=${4:-no-mistakes}
  shift 4
  fm_write_meta "$dir/home/state/$id.meta" \
    "window=firstmate:fm-$id" "endpoint_task_id=$id" \
    "worktree=$dir/wt-$id" "project=$dir/project" "harness=codex" \
    "kind=$kind" "mode=$mode" "yolo=off" "spawn_gen=s-$id"
  : > "$dir/home/state/$id.status"
  printf '%s\n' "$@" >> "$dir/home/state/$id.status"
}

worktree_for() {  # <dir> <name>: one isolated worktree per task, created once
  [ -d "$1/wt-$2" ] || git -C "$1/project" worktree add --quiet -b "wt-$2" "$1/wt-$2"
  printf '%s\n' "$1/wt-$2"
}

spawn() {  # <dir> <pane> <args...>
  local dir=$1 pane=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$dir/home" FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' FM_SPAWN_NO_GUARD=1 \
    TMUX="fake,1,0" FM_BACKEND=tmux FM_FAKE_PANE_PATH="$pane" \
    FM_FAKE_CALL_LOG="$dir/calls.log" PATH="$dir/fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

fresh_ship() {  # <dir> <id>
  local dir=$1 id=$2 pane
  pane=$(worktree_for "$dir" "$id")
  spawn "$dir" "$pane" "$id" "$dir/project" --mode no-mistakes --yolo off
}

# --- scenarios --------------------------------------------------------------

say 'S1: a scout that reports done frees its project place for the next worker'
d=$(case_init s1-scout-done task-e)
declare_capacity "$d/home" 'project 1'
live_worker "$d" live-s scout '' 'working [at=1791700000]: scanning'
rc=0; out=$(fresh_ship "$d" task-e "$d/unused") || rc=$?
expect_rc "$DEFER_EXIT" "$rc" 'a working scout holds its place' "$out"
contains "$out" 'already hold a place (live-s)' 'the deferral names the working scout holder'
[ -e "$d/home/state/task-e.meta" ] && bad 'a deferred spawn published a record' || ok 'a deferred spawn left no record'
printf '%s\n' 'done [at=1791700200]: scan finished' >> "$d/home/state/live-s.status"
rc=0; out=$(fresh_ship "$d" task-e) || rc=$?
expect_rc 0 "$rc" 'a done scout releases its place for the next spawn' "$out"
contains "$out" 'spawned task-e' 'the next worker launched after the scout finished'
[ -f "$d/home/state/task-e.meta" ] && ok 'the admitted spawn published its task record' || bad 'the admitted spawn published no record'

say 'S2: a no-mistakes ship keeps its place after done (guard)'
d=$(case_init s2-ship-done task-e)
declare_capacity "$d/home" 'project 1'
live_worker "$d" live-p ship no-mistakes 'working [at=1791700000]: coding' 'done [at=1791700100]: code done' 'captain-held [at=1791700200]: decision transferred'
rc=0; out=$(fresh_ship "$d" task-e "$d/unused") || rc=$?
expect_rc "$DEFER_EXIT" "$rc" 'a shipped-mode worker still holds its place after done' "$out"
contains "$out" 'already hold a place (live-p)' 'the no-mistakes holder is named'

say 'S3: relaunching a finished scout reserves the place until the replacement reports'
d=$(case_init s3-relaunch task-a task-b)
declare_capacity "$d/home" 'project 1'
worktree_for "$d" task-a >/dev/null
live_worker "$d" task-a scout '' 'done [at=1791700000]: finished'
printf 'fm-task-a\n' > "$d/calls.log.window"
printf '%s\n' 'captain-held [at=1791700100]: decision transferred' >> "$d/home/state/task-a.status"
cp "$d/home/state/task-a.status" "$d/prior.status"
live_worker "$d" live-b ship no-mistakes 'working [at=1791700000]: busy'
rc=0; out=$(spawn "$d" "$d/wt-task-a" task-a --relaunch) || rc=$?
expect_rc "$DEFER_EXIT" "$rc" 'a relaunch is deferred while another worker holds the only place' "$out"
[ -e "$d/home/state/task-a.capacity-reservation" ] && bad 'a refused relaunch wrote a reservation' || ok 'a refused relaunch wrote no reservation'
printf 'pr=123\n' >> "$d/home/state/live-b.meta"
hold="$d/send-hold"
FM_FAKE_SEND_HOLD="$hold" spawn "$d" "$d/wt-task-a" task-a --relaunch > "$d/relaunch.out" 2>&1 &
pid=$!
i=0
while [ ! -f "$hold.reached" ]; do i=$((i+1)); [ "$i" -lt 600 ] || { bad 'relaunch never reached delivery'; break; }; sleep 0.05; done
[ -f "$d/home/state/task-a.capacity-reservation" ] && ok 'the in-flight relaunch reserved the released place' || bad 'no reservation during relaunch'
cmp -s "$d/prior.status" "$d/home/state/task-a.status" && ok 'the reservation left prior status history byte-identical' || bad 'the relaunch rewrote status history'
rc=0; out=$(fresh_ship "$d" task-b "$d/unused") || rc=$?
expect_rc "$DEFER_EXIT" "$rc" 'another spawn cannot take the place of the in-flight relaunch' "$out"
printf '%s\n' 'note [at=1791700150]: bookkeeping only' 'captain-held [at=1791700160]: bookkeeping only' >> "$d/home/state/task-a.status"
rc=0; out=$(fresh_ship "$d" task-b "$d/unused") || rc=$?
expect_rc "$DEFER_EXIT" "$rc" 'bookkeeping alone does not expire the reservation' "$out"
: > "$hold.release"
wait "$pid"; rrc=$?
expect_rc 0 "$rrc" 'the relaunch succeeded' "$(cat "$d/relaunch.out")"
[ -f "$d/home/state/task-a.capacity-reservation" ] && ok 'a successful relaunch keeps its reservation' || bad 'a successful relaunch dropped its reservation'
printf '%s\n' 'working [at=1791700300]: replacement active' >> "$d/home/state/task-a.status"
rc=0; out=$(fresh_ship "$d" task-b "$d/unused") || rc=$?
expect_rc "$DEFER_EXIT" "$rc" 'the running replacement still holds its place' "$out"
printf '%s\n' 'done [at=1791700400]: replacement finished' >> "$d/home/state/task-a.status"
rc=0; out=$(fresh_ship "$d" task-b) || rc=$?
expect_rc 0 "$rc" 'the replacement reporting done frees the place again' "$out"

say 'S4: an aborted relaunch releases its reservation'
d=$(case_init s4-abort task-a task-b)
declare_capacity "$d/home" 'project 1'
worktree_for "$d" task-a >/dev/null
live_worker "$d" task-a scout '' 'done [at=1791700000]: finished'
printf 'fm-task-a\n' > "$d/calls.log.window"
rc=0; out=$(spawn "$d" "$d/wt-task-a" task-a --relaunch --backend invalid-backend) || rc=$?
[ "$rc" -ne 0 ] && [ "$rc" -ne "$DEFER_EXIT" ] && ok "a relaunch refused before launch fails (exit $rc)" || bad "refused relaunch exit $rc: $out"
[ -e "$d/home/state/task-a.capacity-reservation" ] && bad 'a proven non-launch kept its reservation' || ok 'a proven non-launch removed the reservation'
rc=0; out=$(fresh_ship "$d" task-b) || rc=$?
expect_rc 0 "$rc" 'the place of an aborted relaunch is free for the next worker' "$out"

d=$(case_init s4-malformed task-c)
declare_capacity "$d/home" 'project 1'
live_worker "$d" task-m scout '' 'done [at=1791700000]: finished'
printf '%s\n' 'gen=stale' 'status_offset=not-a-number' > "$d/home/state/task-m.capacity-reservation"
rc=0; out=$(fresh_ship "$d" task-c "$d/unused") || rc=$?
expect_rc "$DEFER_EXIT" "$rc" 'a malformed reservation holds a place instead of undercounting' "$out"
printf 'garbage\n' > "$d/home/state/task-m.capacity-reservation"
rc=0; out=$(fresh_ship "$d" task-c "$d/unused") || rc=$?
expect_rc "$DEFER_EXIT" "$rc" 'an unparseable reservation holds a place too' "$out"

say "result: $([ "$FAILS" -eq 0 ] && echo PASS || echo "FAIL ($FAILS)")"
exit "$FAILS"
