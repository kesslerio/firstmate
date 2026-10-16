#!/usr/bin/env bash
# Behavior tests for the Sol session ceiling: concurrent Sol dispatches stop
# by construction at the four-session ceiling the captain filed (2026-09-29,
# "four-session Sol ceiling"), not by attention (bin/fm-sol-cap-lib.sh owns
# the contract; bin/fm-spawn.sh runs the hook after its model axis resolves).
#
# Every case drives the real bin/fm-spawn.sh against a real project clone
# with an origin, fake tmux and treehouse binaries that log every call, and
# a fake tmux list-panes that hands back a live pane pid. A refused spawn is
# judged by what it left behind - no task record, no rendered launch brief,
# no endpoint, no worktree allocation - and by its refusal naming the active
# sessions and their ages, never by wording alone.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset TASKS_AXI_BACKEND || :

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-sol-cap)
HAVE_TASKS_AXI=0
command -v tasks-axi >/dev/null 2>&1 && HAVE_TASKS_AXI=1

# --- fixture ----------------------------------------------------------------

write_brief() {  # <home> <id>
  mkdir -p "$1/data/$2"
  cat > "$1/data/$2/brief.md" <<IFEOF
# Task
## Captain's intent
Run a Sol-routed task for $2.

## Firstmate spec
Exercise the Sol session ceiling.

# Definition of done
Delivery contract: mode=no-mistakes
IFEOF
}

add_item() {  # <home> <id>
  [ "$HAVE_TASKS_AXI" = 1 ] || return 0
  tasks-axi add "$2" "item for $2" --kind ship --file "$1/data/backlog.md" >/dev/null
}

# A Firstmate home with a dispatch table naming the two Sol rows the fleet
# files under gpt-6, plus one GLM row, and a brief for every named task.
make_home() {  # <home> [task-id...]
  local home=$1 id
  shift
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' codex > "$home/config/crew-harness"
  cat > "$home/config/crew-dispatch.json" <<'J'
{"rules":[
 {"when":"Rated complexity 8.","use":{"harness":"codex","model":"gpt-6.1-sol","effort":"medium"}},
 {"when":"Rated complexity 7 when every GLM lane is working.","use":{"harness":"codex","model":"gpt-6.1-sol","effort":"medium"}},
 {"when":"Rated complexity 6.","use":{"harness":"codex","model":"gpt-6-sol","effort":"medium"}},
 {"when":"GLM lanes route themselves.","use":{"harness":"codex","model":"gpt-5.6-luna","effort":"low"}}
]}
J
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
      > "$home/data/backlog.md"
    cat > "$home/.tasks.toml" <<'TOML'
backend = "markdown"

[markdown]
path = "data/backlog.md"
TOML
  fi
  for id in "$@"; do
    write_brief "$home" "$id"
    add_item "$home" "$id"
  done
}

# A case: one home, a project clone with an origin, and fake tmux/treehouse
# that record every call so a refusal can be proved to have created nothing.
# The fake tmux answers list-panes with a pid the test keeps alive, so a
# launched Sol session's registry row is promoted off its reservation pid.
make_case() {  # <name> [task-id...]
  local name=$1 case_dir fakebin
  shift
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir"
  fakebin=$(fm_fakebin "$case_dir")
  : > "$case_dir/calls.log"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_CALL_LOG"
window_file="$FM_FAKE_CALL_LOG.window"
case "${1:-}" in
  display-message)
    case "$*" in
    *"#{pane_current_path}"*)
      printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
      ;;
    *)
      printf 'firstmate\n'
      ;;
    esac
    ;;
  list-windows) [ ! -s "$window_file" ] || cat "$window_file" ;;
  list-panes) printf '%s\n' "${FM_TEST_PANE_PID:-0}" ;;
  new-window)
    name=
    previous=
    for arg in "$@"; do
      [ "$previous" = -n ] && name=$arg
      previous=$arg
    done
    grep -Fqx -- "$name" "$window_file" 2>/dev/null || printf '%s\n' "$name" >> "$window_file"
    ;;
  kill-window)
    target=
    previous=
    for arg in "$@"; do
      [ "$previous" = -t ] && target=$arg
      previous=$arg
    done
    target=${target##*:}
    target=${target#=}
    grep -Fvx -- "$target" "$window_file" 2>/dev/null > "$window_file.tmp" || true
    mv "$window_file.tmp" "$window_file"
    ;;
  has-session|new-session|send-keys) : ;;
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
  fm_git_init_commit "$case_dir/project"
  fm_git_add_origin "$case_dir/project" "$case_dir/project.origin.git"
  make_home "$case_dir/home" "$@"
  printf '%s\n' "$case_dir"
}

# A live Sol session already in the registry: pid 0 keeps the row age-bound,
# which is exactly the shape a registered remote worker leaves behind.
write_sol_row() {  # <home> <id> <start-epoch> [pid] [model]
  local home=$1 id=$2 start=$3 pid=${4:-0} model=${5:-gpt-6.1-sol}
  printf '%s\t%s\t%s\t%s\n' "$id" "$model" "$start" "$pid" >> "$home/state/sol-sessions.tsv"
}

registry_row_field() {  # <case-dir> <id> <field 2=model 4=pid>
  awk -F'\t' -v id="$2" -v col="$3" '$1 == id {print $col; exit}' \
    "$1/home/state/sol-sessions.tsv"
}

registry_has_row() {  # <case-dir> <id> <model>
  grep -Fq "$(printf '%s\t%s\t' "$2" "$3")" "$1/home/state/sol-sessions.tsv"
}

new_worktree() {  # <case-dir> <name>
  git -C "$1/project" worktree add --quiet -b "wt-$2" "$1/wt-$2"
  printf '%s\n' "$1/wt-$2"
}

run_spawn() {  # <case-dir> <home> <pane-path> <args...>
  local case_dir=$1 home=$2 pane=$3
  shift 3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_BACKEND=tmux FM_TEST_PANE_PID="$FM_SOL_TEST_LIVE_PID" \
    FM_FAKE_PANE_PATH="$pane" FM_FAKE_CALL_LOG="$case_dir/calls.log" \
    PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

spawn_sol_ship() {  # <case-dir> <id> [model] [pane-path]
  local case_dir=$1 id=$2 model=${3:-gpt-6.1-sol} pane=${4:-}
  [ -n "$pane" ] || pane=$(new_worktree "$case_dir" "$id")
  run_spawn "$case_dir" "$case_dir/home" "$pane" \
    "$id" "$case_dir/project" --harness codex --model "$model" --mode no-mistakes --yolo off
}

call_count() { wc -l < "$1/calls.log" | tr -d ' '; }

worktree_list() { git -C "$1/project" worktree list --porcelain; }

# Everything a refused spawn must not have created for <id>; <worktrees-before>
# is worktree_list taken before the spawn.
assert_nothing_created() {  # <case-dir> <id> <calls-before> <worktrees-before>
  local case_dir=$1 id=$2 before=$3 worktrees=$4 after
  assert_absent "$case_dir/home/state/$id.meta" "a refused spawn published a task record for $id"
  assert_absent "$case_dir/home/data/$id/launch-brief.md" "a refused spawn rendered a launch brief for $id"
  after=$(call_count "$case_dir")
  [ "$after" -eq "$before" ] ||
    fail "a refused spawn touched the terminal or worktree pool for $id: $(tail -n +"$((before + 1))" "$case_dir/calls.log")"
  assert_equals "$worktrees" "$(worktree_list "$case_dir")" "a refused spawn left a git worktree for $id"
}

# The test's pane pid: the fake tmux hands it back for list-panes, promoting
# a launched Sol session's registry row off its reservation pid.
FM_SOL_TEST_LIVE_PID=$$

fresh_start() {
  date +%s
}

# --- cases ------------------------------------------------------------------

# A Sol dispatch below the ceiling launches the worker, claims its registry
# row, and promotes that row's pid off the reservation onto the worker's own
# pane shell, so the slot is tied to the live worker, not to the spawn.
test_under_cap_sol_spawn_launches_and_claims_its_slot() {
  local case_dir out pid
  case_dir=$(make_case under-cap task-c)
  write_sol_row "$case_dir/home" live-a "$(fresh_start)"
  write_sol_row "$case_dir/home" live-b "$(fresh_start)"
  write_sol_row "$case_dir/home" live-c "$(fresh_start)"
  out=$(spawn_sol_ship "$case_dir" task-c) || fail "an under-cap Sol spawn was refused: $out"
  assert_contains "$out" "spawned task-c" "an under-cap Sol spawn did not launch the worker"
  kill -0 "$FM_SOL_TEST_LIVE_PID" 2>/dev/null || fail "the test's pane pid is not alive"
  pid=$(registry_row_field "$case_dir" task-c 4)
  [ "$pid" = "$FM_SOL_TEST_LIVE_PID" ] ||
    fail "a launched Sol session's registry row kept its reservation pid: $pid"
  registry_has_row "$case_dir" task-c gpt-6.1-sol ||
    fail "a launched Sol session did not claim its registry row"
  pass "a Sol spawn under the ceiling launches, claims, and promotes its slot"
}

# The ceiling refuses the fifth concurrent Sol dispatch with one actionable
# error naming each active session and its age, and the refusal leaves no
# task record, no rendered brief, no endpoint touch, and no worktree behind.
test_cap_refuses_the_fifth_and_names_its_sessions() {
  local case_dir out before rc=0
  case_dir=$(make_case at-cap task-c)
  write_sol_row "$case_dir/home" s1 "$(fresh_start)"
  write_sol_row "$case_dir/home" s2 "$(fresh_start)"
  write_sol_row "$case_dir/home" s3 "$(fresh_start)"
  write_sol_row "$case_dir/home" s4 "$(fresh_start)" 0 gpt-6-sol
  before=$(call_count "$case_dir")
  worktrees=$(worktree_list "$case_dir")
  out=$(spawn_sol_ship "$case_dir" task-c gpt-6.1-sol "$case_dir/unused") || rc=$?
  expect_code 1 "$rc" "a spawn at the Sol ceiling was not refused: $out"
  assert_contains "$out" "Sol ceiling reached" "the refusal did not name the Sol ceiling"
  assert_contains "$out" "task-c (codex, gpt-6.1-sol) was refused" \
    "the refusal did not name the refused dispatch's task and model"
  assert_contains "$out" "s1 (gpt-6.1-sol" "the refusal did not name active session s1"
  assert_contains "$out" "s4 (gpt-6-sol" "the refusal did not name the gpt-6-sol session"
  assert_contains "$out" "age" "the refusal did not name the active sessions' ages"
  assert_contains "$out" "config/sol-cap" "the refusal did not name the ceiling's override file"
  assert_nothing_created "$case_dir" task-c "$before" "$worktrees"
  pass "a dispatch at the ceiling is refused, naming sessions and ages, and creates nothing"
}

# The two staleness rules are the ceiling's release path: an entry older than
# 6h and an entry whose recorded pid is dead do not count against the cap,
# and a passing spawn prunes both so the registry stays bounded.
test_stale_entries_do_not_count() {
  local case_dir out old sleep_lab
  case_dir=$(make_case stale task-c)
  write_sol_row "$case_dir/home" s1 "$(fresh_start)"
  write_sol_row "$case_dir/home" s2 "$(fresh_start)"
  write_sol_row "$case_dir/home" s3 "$(fresh_start)"
  old=$(( "$(fresh_start)" - 21601 ))
  write_sol_row "$case_dir/home" aged-junk "$old"
  sleep_lab=$(sleep 60 & echo $!)
  kill "$sleep_lab" 2>/dev/null || true
  wait "$sleep_lab" 2>/dev/null || true
  write_sol_row "$case_dir/home" dead-junk "$(fresh_start)" "$sleep_lab"
  out=$(spawn_sol_ship "$case_dir" task-c) || fail "a spawn whose ceiling has stale room was refused: $out"
  assert_contains "$out" "spawned task-c" "a spawn freed by stale entries did not launch"
  # Both stale rows are pruned out; the three live rows plus the new claim
  # are what is left.
  [ ! "$(registry_row_field "$case_dir" aged-junk 1)" ] ||
    fail "a stale-by-age row stayed in the registry"
  [ ! "$(registry_row_field "$case_dir" dead-junk 1)" ] ||
    fail "a stale-by-dead-pid row stayed in the registry"
  [ "$(wc -l < "$case_dir/home/state/sol-sessions.tsv" | tr -d ' ')" -eq 4 ] ||
    fail "the registry did not end with 3 live rows plus the new claim"
  pass "stale entries (older than 6h, or dead pid) do not count and are pruned"
}

# A non-Sol model never touches the ceiling: a GLM-routed dispatch passes a
# full ceiling and leaves the registry byte-identical except for nothing.
test_non_sol_model_never_claims_a_slot() {
  local case_dir out before rc=0
  case_dir=$(make_case glm task-c)
  write_sol_row "$case_dir/home" s1 "$(fresh_start)"
  write_sol_row "$case_dir/home" s2 "$(fresh_start)"
  write_sol_row "$case_dir/home" s3 "$(fresh_start)"
  write_sol_row "$case_dir/home" s4 "$(fresh_start)"
  cp "$case_dir/home/state/sol-sessions.tsv" "$TMP_ROOT/glm-registry-before.tsv"
  out=$(spawn_sol_ship "$case_dir" task-c gpt-5.6-luna) || rc=$?
  expect_code 0 "$rc" "a non-Sol dispatch was refused by the Sol ceiling: $out"
  assert_contains "$out" "spawned task-c" "a non-Sol dispatch did not launch"
  assert_equals "$(cat "$TMP_ROOT/glm-registry-before.tsv")" \
    "$(cat "$case_dir/home/state/sol-sessions.tsv")" \
    "a non-Sol dispatch changed the Sol registry"
  pass "a non-Sol model dispatch passes a full ceiling and touches no registry row"
}

# config/sol-cap in the dispatching home raises or lowers the ceiling without
# a code edit: 2 refuses the third, and removing the file restores the
# captain's filed default of 4.
test_config_sol_cap_overrides_the_filed_default() {
  local case_dir out before rc=0
  case_dir=$(make_case override task-c)
  write_sol_row "$case_dir/home" s1 "$(fresh_start)"
  write_sol_row "$case_dir/home" s2 "$(fresh_start)"
  printf '2\n' > "$case_dir/home/config/sol-cap"
  before=$(call_count "$case_dir")
  worktrees=$(worktree_list "$case_dir")
  out=$(spawn_sol_ship "$case_dir" task-c gpt-6.1-sol "$case_dir/unused") || rc=$?
  expect_code 1 "$rc" "a spawn over its configured ceiling was not refused: $out"
  assert_contains "$out" "this ceiling is 2" "the refusal did not use the overridden ceiling"
  assert_nothing_created "$case_dir" task-c "$before" "$worktrees"
  rm -f -- "$case_dir/home/config/sol-cap"
  out=$(spawn_sol_ship "$case_dir" task-c) || fail "removing the override did not restore the default ceiling: $out"
  assert_contains "$out" "spawned task-c" \
    "the four-session default did not admit the dispatch after the override left"
  pass "config/sol-cap overrides the filed default, and its absence restores it"
}



# --- direct library contract -------------------------------------------------

# The ceiling's session-key semantics and loud-config refusals cannot be
# reached through a single fresh spawn, so these cases drive the same contract
# through bin/fm-sol-cap-lib.sh's CLI seam against the fixture registry the
# spawn cases read.
lib_refuse_claim() {  # <case-dir> <id> <model>
  local case_dir=$1 id=$2 model=$3 out
  if out=$(FM_HOME="$case_dir/home" "$ROOT/bin/fm-sol-cap-lib.sh" \
    refuse-claim "$id" ship codex "$model" "$case_dir/home/config" "$case_dir/home/state"); then
    printf '%s\n' claimed
  else
    printf '%s\n' "$out"
    return 1
  fi
}

# A saved own row (the shape a relaunch replaces) is not counted against its
# task id: three live rows and its own stale row leave room, and the claim
# replaces the row with a fresh start epoch instead of appending a second row
# for one session id.
test_relaunched_session_id_replaces_its_own_row() {
  local case_dir out own_start
  case_dir=$(make_case relaunch task-c)
  write_sol_row "$case_dir/home" task-c "$(( "$(fresh_start)" - 43201 ))"
  write_sol_row "$case_dir/home" live-a "$(fresh_start)"
  write_sol_row "$case_dir/home" live-b "$(fresh_start)"
  write_sol_row "$case_dir/home" live-c "$(fresh_start)"
  out=$(lib_refuse_claim "$case_dir" task-c gpt-6.1-sol) ||
    fail "the replace claim was refused: $out"
  assert_equals "$out" "claimed" "the relaunched task id was counted against its own row"
  [ "$(wc -l < "$case_dir/home/state/sol-sessions.tsv" | tr -d ' ')" -eq 4 ] ||
    fail "the replace claim left two rows for one session id"
  own_start=$(registry_row_field "$case_dir" task-c 3)
  [ "$own_start" -ge "$(( "$(fresh_start)" - 60 ))" ] ||
    fail "the replaced own row kept its old start epoch: $own_start"
  pass "a relaunched task id replaces its own registry row instead of counting itself"
}

# A structured row that cannot prove its session key refuses every dispatch
# with the row named: staleness is release, but a malformed row is a loud
# refusal, because skipping one could free a slot another session holds.
test_malformed_registry_row_refuses_loudly() {
  local case_dir out
  case_dir=$(make_case malformed task-c)
  write_sol_row "$case_dir/home" bad "not-an-epoch"
  out=$(lib_refuse_claim "$case_dir" task-c gpt-6.1-sol) || true
  assert_contains "$out" "malformed row" "a malformed registry row did not refuse loudly"
  assert_contains "$out" "not-an-epoch" "the loud refusal did not name the malformed row"
  pass "a malformed registry row refuses every Sol dispatch and names the row"
}

# A ceiling file that is anything but one positive integer refuses instead of
# guessing, and a dispatch table that cannot be read refuses rather than
# counting nothing.
test_unread_ceiling_or_table_refuses_instead_of_counting_nothing() {
  local case_dir out
  case_dir=$(make_case unreadable task-c)
  write_sol_row "$case_dir/home" fresh "$(fresh_start)"
  printf 'four\n' > "$case_dir/home/config/sol-cap"
  out=$(lib_refuse_claim "$case_dir" task-c gpt-6.1-sol) || true
  assert_contains "$out" "ceiling unavailable" "a malformed ceiling did not refuse"
  printf 'false\n' > "$case_dir/home/config/crew-dispatch.json"
  rm -f -- "$case_dir/home/config/sol-cap"
  out=$(lib_refuse_claim "$case_dir" task-c gpt-6.1-sol) || true
  assert_contains "$out" "cannot be read" "an unread dispatch table did not refuse"
  pass "an unread ceiling or dispatch table refuses instead of counting nothing"
}

test_under_cap_sol_spawn_launches_and_claims_its_slot
test_cap_refuses_the_fifth_and_names_its_sessions
test_stale_entries_do_not_count
test_non_sol_model_never_claims_a_slot
test_config_sol_cap_overrides_the_filed_default
test_relaunched_session_id_replaces_its_own_row
test_malformed_registry_row_refuses_loudly
test_unread_ceiling_or_table_refuses_instead_of_counting_nothing
