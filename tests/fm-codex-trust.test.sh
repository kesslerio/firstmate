#!/usr/bin/env bash
# Behavior tests for bin/fm-codex-trust.sh and the codex and pi spawns that keep
# a fresh worktree from parking on a trust prompt.
#
# Three halves of one contract are load-bearing and all three are proven here:
# a legitimate fresh task worktree's repository is registered in the operator's
# own Codex config so a codex worker reaches its brief with no human; a seeded
# secondmate home is registered the same way; every out-of-scope path is REFUSED
# rather than warned about or quietly skipped. And the pi launch carries pi's own
# per-run trust flag, because pi's trust decision belongs on the launch, not in
# a store this repo would have to hand-edit.
#
# What the store key must be is a vendor fact, not a guess: answering Codex's own
# dialog inside a linked worktree persists the entry for the REPOSITORY ROOT, and
# an entry for the worktree's parent ABOVE that root does not suppress the
# dialog. The live guard tests/fm-folder-trust-live-e2e.test.sh refreshes that
# fact against an installed codex; this script pins the mechanics around it.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-codex-trust)
printf '{}\n' > "$TMP_ROOT/treehouse-state.json"

TRUST="$ROOT/bin/fm-codex-trust.sh"

# make_case <name>: a project with one linked worktree plus a throwaway Codex
# home. Echoes "<case>|<proj>|<wt>|<codex-home>".
make_case() {
  local name=$1 case_dir proj wt codex_home
  case_dir="$TMP_ROOT/$name"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  codex_home="$case_dir/codex-home"
  mkdir -p "$codex_home"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  printf '%s|%s|%s|%s\n' "$case_dir" "$proj" "$wt" "$codex_home"
}

read_case() {
  IFS='|' read -r CASE_DIR PROJ WT CODEX_HOME <<EOF
$1
EOF
}

# run_trust <codex-home> <worktree> <project> [user-home]: invoke with an
# isolated store. The store location must come from CODEX_HOME, the same variable
# the launched worker reads, so the fixture never needs a HOME of its own.
run_trust() {
  local codex_home=$1 wt=$2 proj=$3 user_home=${4:-$1}
  CODEX_HOME="$codex_home" HOME="$user_home" "$TRUST" "$wt" "$proj" 2>&1
}

run_home_trust() {
  local codex_home=$1 home=$2 id=$3 user_home=${4:-$1}
  CODEX_HOME="$codex_home" HOME="$user_home" "$TRUST" --secondmate-home "$home" "$id" 2>&1
}

store_of() { printf '%s\n' "$1/config.toml"; }

# trusted_roots <store>: every path whose entry records trust_level = "trusted".
trusted_roots() {
  local store
  store=$(store_of "${1:-}")
  [ -f "$store" ] || return 0
  python3 - "$store" <<'PY'
import sys
import tomllib
with open(sys.argv[1], "rb") as stream:
    config = tomllib.load(stream)
for root, entry in config.get("projects", {}).items():
    if entry.get("trust_level") == "trusted":
        print(root)
PY
}

assert_trusted_root() {  # <codex-home> <path> <msg>
  trusted_roots "$1" | grep -Fqx "$2" || fail "$3"
}

assert_not_trusted_root() {  # <codex-home> <path> <msg>
  if trusted_roots "$1" | grep -Fqx "$2"; then
    fail "$3"
  fi
}

# entry_count <codex-home> <path>: how many [projects."<path>"] tables exist, so
# an update can be shown not to declare the same table twice.
entry_count() {
  local store
  store=$(store_of "$1")
  [ -f "$store" ] || { printf '0\n'; return; }
  grep -c -F "[projects.\"$2\"]" "$store" || true
}

# seed_secondmate_home <home> <id> [shape]: the on-disk shape
# bin/fm-home-seed.sh leaves behind - the identity marker, the firstmate
# instance files, and the four operational directories. "clone" (the default) is
# a standalone-clone home, a primary checkout; "worktree" is a linked worktree a
# treehouse lease produces.
seed_secondmate_home() {
  local home=$1 id=$2 shape=${3:-clone} src
  case "$shape" in
    worktree)
      src="$home.src"
      fm_git_worktree "$src" "$home" "sm-$id"
      ;;
    *)
      mkdir -p "$home"
      fm_git_init_commit "$home"
      ;;
  esac
  mkdir -p "$home/bin" "$home/data" "$home/state" "$home/config" "$home/projects" \
    "$home/.pi/extensions"
  printf '# Firstmate\n' > "$home/AGENTS.md"
  printf 'charter\n' > "$home/data/charter.md"
  printf 'export default 1\n' > "$home/.pi/extensions/fm-primary-turnend-guard.ts"
  printf 'export default 1\n' > "$home/.pi/extensions/fm-primary-pi-watch.ts"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
}

# spawn_with_fakebin <case-dir> <home> <id> <project> <worktree> <fakebin> [args]
# A ship spawn against a throwaway invoking HOME, with the launch logged.
spawn_with_fakebin() {
  local case_dir=$1 home=$2 id=$3 proj=$4 wt=$5 fakebin=$6
  shift 6
  : > "$case_dir/launch.log"
  fm_test_spawn_brief "$home" "$id"
  FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" --mode no-mistakes --yolo off "$@"
}

# spawn_secondmate_with_fakebin <case-dir> <home> <id> <fakebin>
# The same, for a --secondmate launch, which records its own posture and so takes
# no delivery contract.
spawn_secondmate_with_fakebin() {
  local case_dir=$1 home=$2 id=$3 fakebin=$4
  : > "$case_dir/launch.log"
  FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    fm_test_run_spawn "$case_dir/home" "$home" "$fakebin" "$id" "$home" --secondmate
}

# make_launch_home <case-dir> <harness> <fakebin-tools...>: a spawn home whose
# crew harness is <harness>, a project with one linked worktree at the case's own
# project and wt paths for the spawn to launch into, and stub executables so the
# case cannot depend on what happens to be installed on the machine running it.
# Callers name those paths literally, because this runs inside a command
# substitution and cannot export fixture variables to them.
make_launch_home() {
  local case_dir=$1 harness=$2
  shift 2
  local fakebin
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake" "$@")
  fm_test_spawn_home "$case_dir/home" "$harness"
  fm_git_worktree "$case_dir/project" "$case_dir/wt" "wt-$(basename "$case_dir")"
  printf '%s\n' "$fakebin"
}

# --- worktree mode ----------------------------------------------------------

test_fresh_worktree_registers_the_repository_root() {
  local rec out store
  rec=$(make_case fresh)
  read_case "$rec"
  out=$(run_trust "$CODEX_HOME" "$WT" "$PROJ")
  expect_code 0 $? "a fresh linked worktree must be trusted: $out"
  assert_contains "$out" "trusted:" "registration did not report what it trusted"
  assert_contains "$out" "$PROJ" "registration did not report the repository root it trusted"
  store=$(store_of "$CODEX_HOME")
  assert_trusted_root "$CODEX_HOME" "$PROJ" "the repository root was not recorded as trusted"
  [ -z "$(find "$CODEX_HOME" -maxdepth 1 -name '.config.toml.fm-trust.*' -print -quit)" ] \
    || fail "a temporary store file was left behind in the Codex directory"
  pass "fm-codex-trust.sh: a fresh task worktree registers its repository root"
}

# The scope is a vendor fact: codex persists the repository root for an answer
# given inside a worktree, so the worktree path is NOT the key and registering it
# would add a store entry per pool slot for a decision codex never asks twice.
test_registration_keys_on_the_root_not_the_worktree() {
  local rec
  rec=$(make_case root-key)
  read_case "$rec"
  run_trust "$CODEX_HOME" "$WT" "$PROJ" >/dev/null || fail "registration failed"
  assert_not_trusted_root "$CODEX_HOME" "$WT" \
    "the worktree path was registered, so every new pool slot would need its own entry"
  pass "fm-codex-trust.sh: the entry is the repository root, not the per-worktree path"
}

# The store is the operator's own interactive Codex config, usually already
# populated with hooks, model settings, and other projects' trust. The write is
# stanza-scoped, so every unrelated byte must survive it verbatim.
test_unrelated_config_content_is_preserved() {
  local rec store before size
  rec=$(make_case preserve)
  read_case "$rec"
  store=$(store_of "$CODEX_HOME")
  cat > "$store" <<TOML
model = "gpt-6.1-sol"

[projects."/some/other/repo"]
trust_level = "trusted"

[hooks.state."$HOME/.codex/hooks.json:pre_tool_use:0:0"]
trusted_hash = "sha256:0000000000000000000000000000000000000000000000000000000000000000"

[tui]
screen_reader_detection_done = true
TOML
  before="$CASE_DIR/before.toml"
  cp "$store" "$before"
  size=$(wc -c < "$before" | tr -d ' ')
  run_trust "$CODEX_HOME" "$WT" "$PROJ" >/dev/null || fail "registration failed against an existing config"
  assert_trusted_root "$CODEX_HOME" "/some/other/repo" "an unrelated project lost its trust entry"
  assert_trusted_root "$CODEX_HOME" "$PROJ" "the new entry is missing"
  # The write only appends a stanza, so the operator's own bytes must survive as
  # the exact prefix they were - hook entries, other projects, and settings alike.
  cmp -s "$before" <(head -c "$size" "$store") \
    || fail "the registration changed the operator's existing config bytes: $(cat "$store")"
  pass "fm-codex-trust.sh: preserves every unrelated line of the operator's config"
}

test_registration_is_idempotent() {
  local rec store first second
  rec=$(make_case idempotent)
  read_case "$rec"
  store=$(store_of "$CODEX_HOME")
  run_trust "$CODEX_HOME" "$WT" "$PROJ" >/dev/null || fail "first registration failed"
  first=$(cat "$store")
  run_trust "$CODEX_HOME" "$WT" "$PROJ" >/dev/null || fail "second registration failed"
  second=$(cat "$store")
  [ "$first" = "$second" ] || fail "a second registration rewrote the store again:
$first
---
$second"
  [ "$(entry_count "$CODEX_HOME" "$PROJ")" = 1 ] \
    || fail "the entry for the repository root was declared more than once"
  pass "fm-codex-trust.sh: registering the same repository twice changes nothing"
}

test_missing_store_is_created() {
  local rec out store fresh
  rec=$(make_case create-store)
  read_case "$rec"
  fresh=$CODEX_HOME
  store=$(store_of "$fresh")
  rm -rf "$fresh"
  out=$(CODEX_HOME="$fresh" HOME="$fresh" "$TRUST" "$WT" "$PROJ" 2>&1)
  expect_code 0 $? "registration must create an absent store directory: $out"
  assert_trusted_root "$fresh" "$PROJ" "a freshly created store did not carry the entry"
  pass "fm-codex-trust.sh: creates the Codex directory and store when absent"
}

# An empty table for the path is a partial write of the same shape, and appending
# a second table of that name would make the whole file a TOML parse error -
# which would break codex for the operator, not just this spawn.
test_existing_empty_entry_gains_the_decision_once() {
  local rec store
  rec=$(make_case empty-entry)
  read_case "$rec"
  store=$(store_of "$CODEX_HOME")
  printf '[projects."%s"]\n\n[tui]\ntheme = "dark"\n' "$PROJ" > "$store"
  run_trust "$CODEX_HOME" "$WT" "$PROJ" >/dev/null || fail "registration against an empty entry failed"
  assert_trusted_root "$CODEX_HOME" "$PROJ" "the empty entry did not gain trust_level"
  [ "$(entry_count "$CODEX_HOME" "$PROJ")" = 1 ] \
    || fail "the existing entry was duplicated instead of filled in: $(cat "$store")"
  assert_contains "$(cat "$store")" 'theme = "dark"' "the section after the entry was lost"
  pass "fm-codex-trust.sh: fills in an existing empty entry instead of redeclaring it"
}

# A recorded decision that is not "trusted" is the operator's own, and flipping it
# would grant every future interactive session of that repository what the
# operator declined.
test_a_recorded_non_trusted_decision_is_not_overridden() {
  local rec store before out
  rec=$(make_case declined)
  read_case "$rec"
  store=$(store_of "$CODEX_HOME")
  printf '[projects."%s"]\ntrust_level = "untrusted"\n' "$PROJ" > "$store"
  before=$(cat "$store")
  out=$(run_trust "$CODEX_HOME" "$WT" "$PROJ")
  expect_code 1 $? "a recorded non-trusted decision must refuse rather than flip: $out"
  assert_contains "$out" "refusing to overwrite" "the refusal did not name the reason"
  [ "$(cat "$store")" = "$before" ] || fail "the refused write still modified the store"
  pass "fm-codex-trust.sh: refuses to overwrite an operator's recorded non-trusted decision"
}

test_an_inline_projects_table_is_refused() {
  local rec store out
  rec=$(make_case inline-table)
  read_case "$rec"
  store=$(store_of "$CODEX_HOME")
  printf 'projects = { "/x" = { trust_level = "trusted" } }\n' > "$store"
  out=$(run_trust "$CODEX_HOME" "$WT" "$PROJ")
  expect_code 1 $? "an inline projects table must refuse rather than be appended to: $out"
  assert_contains "$(cat "$store")" 'projects = {' "a refused write replaced the inline table"
  pass "fm-codex-trust.sh: refuses a projects table written in a form it does not own"
}

test_a_dotted_key_entry_is_refused() {
  local rec store out
  rec=$(make_case dotted-key)
  read_case "$rec"
  store=$(store_of "$CODEX_HOME")
  printf 'projects."%s".trust_level = "trusted"\n' "$PROJ" > "$store"
  out=$(run_trust "$CODEX_HOME" "$WT" "$PROJ")
  expect_code 1 $? "a dotted-key entry must refuse rather than be duplicated: $out"
  assert_contains "$out" "dotted key" "the refusal did not name the form"
  pass "fm-codex-trust.sh: refuses a trust entry written as a dotted key"
}

# --- refusals ---------------------------------------------------------------

test_primary_checkout_is_refused() {
  local rec out
  rec=$(make_case primary)
  read_case "$rec"
  out=$(run_trust "$CODEX_HOME" "$PROJ" "$PROJ")
  expect_code 1 $? "a primary checkout must be refused: $out"
  assert_contains "$out" "primary checkout" "the refusal did not name the reason"
  assert_not_trusted_root "$CODEX_HOME" "$PROJ" "a refused primary checkout was registered anyway"
  pass "fm-codex-trust.sh: a primary checkout is refused"
}

test_home_directory_is_refused() {
  local rec home out
  rec=$(make_case home-dir)
  read_case "$rec"
  home="$CASE_DIR/fake-home"
  mkdir -p "$home"
  out=$(CODEX_HOME="$CODEX_HOME" HOME="$home" "$TRUST" "$home" "$PROJ" 2>&1)
  expect_code 1 $? "the home directory must be refused: $out"
  assert_contains "$out" "home directory" "the refusal did not name the reason"
  pass "fm-codex-trust.sh: a home directory is refused"
}

test_relative_codex_home_is_refused() {
  local rec out
  rec=$(make_case relative-store)
  read_case "$rec"
  out=$(CODEX_HOME="relative-codex" HOME="$CASE_DIR" "$TRUST" "$WT" "$PROJ" 2>&1)
  expect_code 1 $? "a relative CODEX_HOME must be refused: $out"
  assert_contains "$out" "relative" "the refusal did not name the reason"
  pass "fm-codex-trust.sh: a relative CODEX_HOME is refused rather than guessed at"
}

test_non_git_and_missing_directories_are_refused() {
  local rec plain out
  rec=$(make_case non-git)
  read_case "$rec"
  plain="$CASE_DIR/plain"
  mkdir -p "$plain"
  out=$(run_trust "$CODEX_HOME" "$plain" "$PROJ")
  expect_code 1 $? "a plain directory must be refused: $out"
  out=$(run_trust "$CODEX_HOME" "$CASE_DIR/nope" "$PROJ")
  expect_code 1 $? "a missing directory must be refused: $out"
  pass "fm-codex-trust.sh: a plain directory and a missing directory are refused"
}

test_foreign_worktree_and_subdirectory_are_refused() {
  local rec other other_wt subdir out
  rec=$(make_case foreign)
  read_case "$rec"
  other="$CASE_DIR/other-project"
  other_wt="$CASE_DIR/other-wt"
  fm_git_worktree "$other" "$other_wt" foreign-wt
  out=$(run_trust "$CODEX_HOME" "$other_wt" "$PROJ")
  expect_code 1 $? "a worktree of an unrelated project must be refused: $out"
  subdir="$WT/empty-sub"
  mkdir -p "$subdir"
  out=$(run_trust "$CODEX_HOME" "$subdir" "$PROJ")
  expect_code 1 $? "a subdirectory of a worktree must be refused: $out"
  pass "fm-codex-trust.sh: a foreign worktree and a worktree subdirectory are refused"
}

# A secondmate home spawned FROM a worktree rather than as a standalone clone is
# the case bin/fm-claude-trust.sh had to solve the same way: the registered root
# is derived structurally from the common dir and verified, never assumed.
test_project_argument_that_is_itself_a_worktree_registers_the_primary_checkout() {
  local rec nested nested_wt out
  rec=$(make_case nested-project)
  read_case "$rec"
  # The shape bin/fm-spawn.sh presents when the <project> it is handed is itself
  # a leased worktree rather than the primary checkout: a worktree of a worktree,
  # all three sharing one common dir.
  nested="$CASE_DIR/nested"
  nested_wt="$CASE_DIR/nested-wt"
  fm_git_init_commit "$CASE_DIR/primary"
  git -C "$CASE_DIR/primary" worktree add --quiet -b nested-proj "$nested"
  git -C "$nested" worktree add --quiet -b nested-wt "$nested_wt"
  out=$(run_trust "$CODEX_HOME" "$nested_wt" "$nested")
  expect_code 0 $? "a worktree of a project that is itself a worktree must be trusted: $out"
  assert_trusted_root "$CODEX_HOME" "$CASE_DIR/primary" \
    "the registration did not resolve to the primary checkout: $(cat "$(store_of "$CODEX_HOME")")"
  pass "fm-codex-trust.sh: a project that is itself a worktree resolves to the primary checkout"
}

test_missing_python_is_refused() {
  local rec dir out tool
  rec=$(make_case no-python)
  read_case "$rec"
  dir="$CASE_DIR/nopython-bin"
  mkdir -p "$dir"
  for tool in bash env git mkdir cat dirname; do
    ln -sf "$(command -v "$tool")" "$dir/$tool"
  done
  out=$(env -i PATH="$dir" CODEX_HOME="$CODEX_HOME" HOME="$CODEX_HOME" \
    "$TRUST" "$WT" "$PROJ" 2>&1)
  expect_code 1 $? "a missing Python must refuse rather than launch a worker into the dialog: $out"
  assert_contains "$out" "python3" "the refusal did not name the missing tool"
  pass "fm-codex-trust.sh: a missing Python interpreter refuses the registration"
}

# --- secondmate homes -------------------------------------------------------

test_secondmate_standalone_clone_home_requires_attended_trust() {
  local rec home shape out
  rec=$(make_case sm-clone)
  read_case "$rec"
  for shape in standalone separate; do
    home="$CASE_DIR/$shape"
    seed_secondmate_home "$home" "android"
    if [ "$shape" = separate ]; then
      git -C "$home" init --separate-git-dir "$CASE_DIR/primary-git" >/dev/null 2>&1 || fail "could not seed separate git metadata"
    fi
    out=$(run_home_trust "$CODEX_HOME" "$home" android)
    expect_code 1 $? "a $shape secondmate home must not be pre-trusted: $out"
    assert_contains "$out" "attended provisioning" "the refusal did not name the attended approval step"
    assert_absent "$(store_of "$CODEX_HOME")" "the primary home gained automatic trust"
  done
  pass "fm-codex-trust.sh: standalone secondmate homes keep attended folder trust"
}

test_secondmate_leased_worktree_home_is_trusted() {
  local rec home out
  rec=$(make_case sm-worktree)
  read_case "$rec"
  home="$CASE_DIR/home"
  seed_secondmate_home "$home" "android" worktree
  out=$(run_home_trust "$CODEX_HOME" "$home" android)
  expect_code 0 $? "a seeded leased-worktree secondmate home must be trusted: $out"
  assert_trusted_root "$CODEX_HOME" "$CASE_DIR/home.src" \
    "a leased home did not register the checkout codex keys on"
  pass "fm-codex-trust.sh: a seeded secondmate home that is a leased worktree is trusted"
}

test_secondmate_home_refuses_everything_unseeded() {
  local rec home other out
  rec=$(make_case sm-refuse)
  read_case "$rec"
  home="$CASE_DIR/home"
  seed_secondmate_home "$home" "android"
  out=$(run_home_trust "$CODEX_HOME" "$home" other-domain)
  expect_code 1 $? "a home marked for another secondmate must be refused: $out"
  other="$CASE_DIR/unseeded"
  mkdir -p "$other"
  fm_git_init_commit "$other"
  out=$(run_home_trust "$CODEX_HOME" "$other" android)
  expect_code 1 $? "an unseeded checkout must be refused: $out"
  assert_contains "$out" "marker" "the refusal did not name the missing seed evidence"
  pass "fm-codex-trust.sh: secondmate-home mode refuses an unseeded or foreign home"
}

# --- spawn wiring -----------------------------------------------------------

# The launch command is what the pane runs, so the two spawn cases below read it
# from a fake tmux exactly as the worker's terminal would receive it.
test_codex_spawn_pretrusts_the_repository_root() {
  local case_dir=$TMP_ROOT/spawn-codex fakebin out store
  mkdir -p "$case_dir"
  fakebin=$(make_launch_home "$case_dir" codex codex)
  out=$(spawn_with_fakebin "$case_dir" "$case_dir/home" spawn-codex-1 "$case_dir/project" \
    "$case_dir/wt" "$fakebin")
  expect_code 0 $? "a codex crewmate spawn should succeed: $out"
  # fm_test_run_spawn runs the spawn under a throwaway invoking HOME, and a
  # codex launch with no CODEX_HOME set resolves to $HOME/.codex, exactly as the
  # pane will.
  store="$case_dir/home/user-home/.codex/config.toml"
  [ -f "$store" ] || fail "the spawn wrote no Codex config for the pane to read"
  assert_contains "$(cat "$store")" "[projects.\"$case_dir/project\"]" \
    "the codex spawn did not pre-register its repository root: $(cat "$store")"
  assert_contains "$(cat "$case_dir/launch.log")" "codex" \
    "the codex spawn did not launch"
  pass "fm-spawn.sh: a codex crewmate pre-registers folder trust and launches"
}

test_codex_spawn_stops_when_registration_is_refused() {
  local kind case_dir fakebin home id out status
  for kind in ship scout secondmate; do
    case_dir="$TMP_ROOT/spawn-codex-refused-$kind"
    id="codex-refused-$kind"
    mkdir -p "$case_dir"
    fakebin=$(make_launch_home "$case_dir" codex codex)
    if [ "$kind" = secondmate ]; then
      home="$case_dir/secondmate"
      seed_secondmate_home "$home" "$id" worktree
      out=$(FM_TEST_CODEX_HOME=relative-codex-home spawn_secondmate_with_fakebin "$case_dir" "$home" "$id" "$fakebin")
    elif [ "$kind" = scout ]; then
      fm_test_spawn_brief "$case_dir/home" "$id"
      : > "$case_dir/launch.log"
      out=$(FM_TEST_CODEX_HOME=relative-codex-home FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
        fm_test_run_spawn "$case_dir/home" "$case_dir/wt" "$fakebin" "$id" "$case_dir/project" --scout)
    else
      out=$(FM_TEST_CODEX_HOME=relative-codex-home \
        spawn_with_fakebin "$case_dir" "$case_dir/home" "$id" "$case_dir/project" "$case_dir/wt" "$fakebin")
    fi
    status=$?
    expect_code 1 "$status" "a $kind Codex spawn whose trust registration was refused must stop: $out"
    assert_contains "$out" "could not pre-register codex folder trust" "the spawn did not report the refused registration"
    assert_contains "$out" "relative path" "the refusal did not identify the registration cause"
    assert_equals '' "$(cat "$case_dir/launch.log")" "a worker launched after trust refusal"
    assert_absent "$case_dir/home/state/$id.meta" "refused trust published a worker record"
  done
  pass "fm-spawn.sh: a refused codex trust registration stops before worker launch"
}

test_pi_spawn_launches_with_the_trust_flag() {
  local case_dir=$TMP_ROOT/spawn-pi fakebin out launch
  mkdir -p "$case_dir"
  fakebin=$(make_launch_home "$case_dir" pi pi)
  out=$(spawn_with_fakebin "$case_dir" "$case_dir/home" spawn-pi-1 "$case_dir/project" \
    "$case_dir/wt" "$fakebin")
  expect_code 0 $? "a pi crewmate spawn should succeed: $out"
  launch=$(cat "$case_dir/launch.log")
  assert_contains "$launch" "--approve" \
    "the pi launch did not carry pi's own per-run trust flag: $launch"
  [ "$(printf '%s' "$launch" | grep -o -F -- '--approve' | wc -l | tr -d ' ')" = 1 ] \
    || fail "the pi launch passed the trust flag more than once: $launch"
  pass "fm-spawn.sh: a pi crewmate launch carries pi's per-run project-trust flag"
}

test_pi_secondmate_launch_carries_the_trust_flag() {
  local case_dir=$TMP_ROOT/spawn-pi-secondmate fakebin home out launch
  mkdir -p "$case_dir"
  home="$case_dir/sm-home"
  seed_secondmate_home "$home" spawn-pi-2 worktree
  fakebin=$(make_launch_home "$case_dir" pi pi)
  out=$(spawn_secondmate_with_fakebin "$case_dir" "$home" spawn-pi-2 "$fakebin")
  expect_code 0 $? "a pi secondmate spawn should succeed: $out"
  launch=$(cat "$case_dir/launch.log")
  assert_contains "$launch" "--approve" \
    "the pi secondmate launch did not carry the trust flag: $launch"
  pass "fm-spawn.sh: a pi secondmate launch carries pi's per-run project-trust flag"
}

# The flag has to survive the pane's shell, not just appear in the string.
test_pi_launch_flag_reaches_the_pi_process() {
  local case_dir=$TMP_ROOT/spawn-pi-pane fakebin piworker launch
  mkdir -p "$case_dir"
  fakebin=$(make_launch_home "$case_dir" pi pi)
  cat > "$fakebin/pi" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$*" > '$case_dir/pi-worker'
SH
  chmod +x "$fakebin/pi"
  spawn_with_fakebin "$case_dir" "$case_dir/home" spawn-pi-3 "$case_dir/project" \
    "$case_dir/wt" "$fakebin" >/dev/null || fail "a pi crewmate spawn should succeed"
  launch=$(cat "$case_dir/launch.log")
  env -i HOME="$case_dir/user-home" PATH="$fakebin:$PATH" TERM=xterm \
    bash -c "$launch" || fail "the recorded pi launch failed in the synthetic pane"
  piworker="$case_dir/pi-worker"
  assert_contains "$(cat "$piworker")" "--approve" \
    "the pi process did not receive the trust flag: $(cat "$piworker")"
  pass "fm-spawn.sh: the pi trust flag survives the pane shell into pi's own argv"
}

test_equivalent_toml_entries_preserve_operator_decisions() {
  local rec store style decision out status before
  rec=$(make_case semantic-entries)
  read_case "$rec"
  store=$(store_of "$CODEX_HOME")
  for style in commented literal escaped quoted; do
    for decision in empty trusted untrusted; do
      python3 - "$store" "$PROJ" "$style" "$decision" <<'PY'
import json
import pathlib
import sys
store, root, style, decision = sys.argv[1:]
key = json.dumps(root)
if style == "literal":
    header = f"[projects.'{root}']"
elif style == "escaped":
    header = '[projects.' + key.replace("/", "\\u002f") + ']'
elif style == "quoted":
    header = f'["projects" . {key}]'
else:
    header = f"[projects.{key}] # operator decision"
body = "" if decision == "empty" else f"'trust_level' = '{decision}' # operator decision\n"
pathlib.Path(store).write_text(header + "\n" + body + '\n[tui]\ntheme = "dark"\n')
PY
      before=$(cat "$store")
      out=$(run_trust "$CODEX_HOME" "$WT" "$PROJ")
      status=$?
      if [ "$decision" = untrusted ]; then
        expect_code 1 "$status" "equivalent TOML denial must be preserved: $out"
        assert_equals "$before" "$(cat "$store")" "denied entry was changed"
      else
        expect_code 0 "$status" "equivalent TOML entry must be recognised: $out"
        assert_trusted_root "$CODEX_HOME" "$PROJ" "the semantic entry was not trusted"
        if [ "$decision" = trusted ]; then
          assert_equals "$before" "$(cat "$store")" "trusted entry was unnecessarily rewritten"
        fi
      fi
    done
  done
  pass "fm-codex-trust.sh: equivalent TOML keys and trust values preserve decisions"
}

test_unsupported_and_malformed_toml_is_unchanged() {
  local rec store form out before
  rec=$(make_case semantic-refusals)
  read_case "$rec"
  store=$(store_of "$CODEX_HOME")
  for form in inline dotted nested duplicate malformed; do
    python3 - "$store" "$PROJ" "$form" <<'PY'
import json
import pathlib
import sys
store, root, form = sys.argv[1:]
key = json.dumps(root).replace("/", "\\u002f")
configs = {
    "inline": f'"projects" = {{ {key} = {{ trust_level = "untrusted" }} }}\n',
    "dotted": f'"projects".{key}."trust_level" = "untrusted"\n',
    "nested": f'[projects]\n{key} = {{ trust_level = "untrusted" }}\n',
    "duplicate": f'[projects.{key}]\ntrust_level = "trusted"\n[projects.{key}]\n',
    "malformed": 'model = "unterminated\n',
}
pathlib.Path(store).write_text(configs[form])
PY
    before=$(cat "$store")
    out=$(run_trust "$CODEX_HOME" "$WT" "$PROJ")
    expect_code 1 $? "unsupported or malformed TOML must refuse: $out"
    assert_equals "$before" "$(cat "$store")" "refused TOML changed"
  done
  pass "fm-codex-trust.sh: unsupported and malformed TOML is refused without writes"
}

test_concurrent_store_writers_keep_both_projects() {
  local rec first_proj first_wt shared second_proj second_wt p1 p2 status1 status2
  rec=$(make_case concurrent-first)
  read_case "$rec"
  first_proj=$PROJ first_wt=$WT shared=$CODEX_HOME
  rec=$(make_case concurrent-second)
  read_case "$rec"
  second_proj=$PROJ second_wt=$WT
  printf 'model = "test-model"\n' > "$shared/config.toml"
  mkdir -p "$CASE_DIR/store-alias"
  ln -s "$shared/config.toml" "$CASE_DIR/store-alias/config.toml"
  run_trust "$shared" "$first_wt" "$first_proj" >"$TMP_ROOT/first-writer.log" &
  p1=$!
  run_trust "$CASE_DIR/store-alias" "$second_wt" "$second_proj" >"$TMP_ROOT/second-writer.log" &
  p2=$!
  wait "$p1"; status1=$?
  wait "$p2"; status2=$?
  expect_code 0 "$status1" "first concurrent writer failed"
  expect_code 0 "$status2" "second concurrent writer failed"
  assert_trusted_root "$shared" "$first_proj" "first project was lost"
  assert_trusted_root "$shared" "$second_proj" "second project was lost"
  pass "fm-codex-trust.sh: concurrent writers sharing a resolved store retain both projects"
}

test_codex_launch_reads_the_registered_store() {
  local kind case_dir fakebin worker_home expected_root launch selected override out
  for kind in ship scout secondmate; do
    case_dir="$TMP_ROOT/store-launch-$kind"
    mkdir -p "$case_dir"
    fakebin=$(make_launch_home "$case_dir" codex codex)
    selected="$case_dir/selected store"
    override=$selected
    if [ "$kind" = ship ]; then
      selected="$case_dir/home/user-home/.codex"
      override=''
    fi
    cat > "$fakebin/codex" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$CODEX_HOME" > "$FM_CODEX_STORE_RESULT"
python3 - "$CODEX_HOME/config.toml" "$FM_CODEX_EXPECT_ROOT" <<'PY'
import sys
import tomllib
with open(sys.argv[1], "rb") as stream:
    config = tomllib.load(stream)
assert config["projects"][sys.argv[2]]["trust_level"] == "trusted"
PY
SH
    chmod +x "$fakebin/codex"
    printf 'FM_CODEX_STORE_RESULT\nFM_CODEX_EXPECT_ROOT\n' > "$case_dir/home/config/launch-env-allowlist"
    if [ "$kind" = secondmate ]; then
      worker_home="$case_dir/secondmate"
      seed_secondmate_home "$worker_home" store-launch-secondmate worktree
      expected_root="$worker_home.src"
      out=$(FM_TEST_CODEX_HOME="$override" spawn_secondmate_with_fakebin "$case_dir" "$worker_home" store-launch-secondmate "$fakebin")
    else
      worker_home="$case_dir/project"
      expected_root=$worker_home
      if [ "$kind" = scout ]; then
        fm_test_spawn_brief "$case_dir/home" "store-launch-$kind"
        : > "$case_dir/launch.log"
        out=$(FM_TEST_CODEX_HOME="$override" FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
          fm_test_run_spawn "$case_dir/home" "$case_dir/wt" "$fakebin" "store-launch-$kind" "$worker_home" --scout)
      else
        out=$(FM_TEST_CODEX_HOME="$override" spawn_with_fakebin "$case_dir" "$case_dir/home" "store-launch-$kind" "$worker_home" "$case_dir/wt" "$fakebin")
      fi
    fi
    expect_code 0 $? "store-pinned $kind spawn failed: $out"
    launch=$(cat "$case_dir/launch.log")
    env -i HOME="$case_dir/destination-home" CODEX_HOME="$case_dir/wrong-store" \
      FM_CODEX_STORE_RESULT="$case_dir/worker-store" FM_CODEX_EXPECT_ROOT="$expected_root" \
      PATH="$fakebin:$PATH" TERM=xterm bash -c "$launch" || fail "worker did not consume the registered store"
    assert_equals "$selected" "$(cat "$case_dir/worker-store")" "worker selected a different Codex store"
    assert_absent "$case_dir/wrong-store/config.toml" "registration wrote a second store"
  done
  pass "fm-spawn.sh: all Codex launch kinds read the single registered store"
}

test_spawn_fixture_isolates_an_exported_codex_home() {
  local mode case_dir fakebin selected
  for mode in default empty explicit; do
    case_dir="$TMP_ROOT/store-isolation-$mode"
    mkdir -p "$case_dir/operator-store"
    printf 'model = "operator-model"\n' > "$case_dir/operator-store/config.toml"
    fakebin=$(make_launch_home "$case_dir" codex codex)
    selected="$case_dir/home/user-home/.codex"
    (
      export CODEX_HOME="$case_dir/operator-store"
      unset FM_TEST_CODEX_HOME
      case "$mode" in
        empty) export FM_TEST_CODEX_HOME='' ;;
        explicit) export FM_TEST_CODEX_HOME="$case_dir/selected-store" ;;
      esac
      spawn_with_fakebin "$case_dir" "$case_dir/home" "store-isolation-$mode" "$case_dir/project" "$case_dir/wt" "$fakebin" >/dev/null || exit 1
      [ "$CODEX_HOME" = "$case_dir/operator-store" ]
    ) || fail "isolated fixture spawn changed its caller environment or failed"
    [ "$mode" != explicit ] || selected="$case_dir/selected-store"
    assert_equals 'model = "operator-model"' "$(cat "$case_dir/operator-store/config.toml")" "fixture changed the inherited operator store"
    assert_trusted_root "$selected" "$case_dir/project" "fixture did not use its selected throwaway store"
  done
  pass "spawn fixture: exported Codex profiles remain untouched"
}

test_secondmate_automatic_trust_is_limited_to_linked_pool_homes() {
  local harness shape case_dir fakebin home out launch status argv store
  for harness in codex pi pi-signed; do
    for shape in standalone separate nonpool pool; do
      case_dir="$TMP_ROOT/scope-$harness-$shape"
      mkdir -p "$case_dir"
      fakebin=$(make_launch_home "$case_dir" "$harness" "$harness")
      home="$case_dir/secondmate"
      if [ "$shape" = standalone ] || [ "$shape" = separate ]; then
        seed_secondmate_home "$home" "scope-$harness-$shape"
        if [ "$shape" = separate ]; then
          git -C "$home" init --separate-git-dir "$case_dir/primary-git" >/dev/null 2>&1 || fail "could not seed a primary checkout with separate git metadata"
        fi
      else
        if [ "$shape" = nonpool ]; then
          home="$case_dir/attended/secondmate"
        fi
        seed_secondmate_home "$home" "scope-$harness-$shape" worktree
      fi
      cat > "$fakebin/$harness" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --help) exit 0 ;;
  --version) printf '0.99.2\n'; exit 0 ;;
esac
printf '%s\n' "$@" > "$FM_FOLDER_ARGV"
SH
      chmod +x "$fakebin/$harness"
      out=$(spawn_secondmate_with_fakebin "$case_dir" "$home" "scope-$harness-$shape" "$fakebin")
      status=$?
      expect_code 0 "$status" "$harness $shape secondmate launch failed: $out"
      launch=$(cat "$case_dir/launch.log")
      env -i HOME="$case_dir/destination" PATH="$fakebin:$PATH" TERM=xterm \
        FM_FOLDER_ARGV="$case_dir/argv" bash -c "$launch" || fail "secondmate launch did not reach $harness"
      argv="$case_dir/argv"
      store="$case_dir/home/user-home/.codex"
      if [ "$harness" = codex ]; then
        if [ "$shape" = pool ]; then
          assert_trusted_root "$store" "$home.src" "pooled Codex home was not registered"
        else
          assert_absent "$store/config.toml" "attended Codex home gained automatic trust"
        fi
      elif [ "$shape" = pool ]; then
        grep -Fxq -- --approve "$argv" || fail "pooled Pi home lost its per-run approval"
      else
        if grep -Fxq -- --approve "$argv"; then
          fail "attended Pi home gained automatic approval"
        fi
      fi
    done
  done
  pass "fm-spawn.sh: Codex and both Pi identities automate only linked pool secondmate homes"
}

test_direct_registration_refuses_linked_homes_outside_the_pool() {
  local rec home out
  rec=$(make_case sm-nonpool)
  read_case "$rec"
  home="$CASE_DIR/attended/home"
  seed_secondmate_home "$home" nonpool worktree
  out=$(run_home_trust "$CODEX_HOME" "$home" nonpool)
  expect_code 1 $? "direct registration trusted a linked home outside the pool: $out"
  assert_contains "$out" "qualifying linked pool" "the refusal did not identify the scope"
  assert_absent "$(store_of "$CODEX_HOME")" "nonpool secondmate trust was persisted"
  out=$(run_trust "$CODEX_HOME" "$home" "$home.src")
  expect_code 1 $? "worktree mode trusted a linked home outside the pool: $out"
  assert_absent "$(store_of "$CODEX_HOME")" "worktree mode persisted nonpool trust"
  pass "fm-codex-trust.sh: both registration modes refuse linked paths outside the pool"
}

test_live_guard_requires_editor_and_owns_cleanup() {
  local case_dir="$TMP_ROOT/live-guard" fakebin tool scenario screen signal expected ancestor_trust out status socket root
  mkdir -p "$case_dir/home/.codex"
  printf '{}\n' > "$case_dir/home/.codex/auth.json"
  fakebin=$(fm_fakebin "$case_dir")
  fm_fake_exit0 "$fakebin" sleep
  for tool in codex pi; do
    cat > "$fakebin/$tool" <<'SH'
#!/usr/bin/env bash
exec python3 - "${0##*/}" "$@" <<'PY'
import argparse
import json
import os
import sys
harness, *argv = sys.argv[1:]
if argv == ["--version"]:
    print(harness + "-test")
    sys.exit(0)
parser = argparse.ArgumentParser()
if harness == "codex":
    parser.add_argument("--dangerously-bypass-approvals-and-sandbox", action="store_true")
    parser.add_argument("--disable", action="append")
    parser.add_argument("-c", action="append")
    parser.add_argument("--model")
else:
    parser.add_argument("--tui-mode")
    parser.add_argument("--approve", action="store_true")
    parser.add_argument("--model")
    parser.add_argument("--thinking")
    parser.add_argument("-e", action="append")
parser.parse_args(argv)
assert argv and argv[0].startswith("-")
with open(os.environ["FM_LIVE_CLI_LOG"], "a") as stream:
    stream.write(json.dumps({"harness": harness, "argv": argv}) + "\n")
PY
SH
    chmod +x "$fakebin/$tool"
  done
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -eu
[ "$1" = -S ] || exit 2
socket=$2
shift 2
printf '%s\t%s\n' "$socket" "$*" >> "$FM_LIVE_TMUX_LOG"
case "$1" in
  new-session)
    mkdir -p "$(dirname "$socket")"
    : > "$socket"
    dir=''
    for ((i=1; i<=$#; i++)); do
      if [ "${!i}" = -c ]; then
        i=$((i + 1))
        dir=${!i}
        break
      fi
    done
    [ -n "$dir" ]
    (cd "$dir" && bash -c "${@: -1}")
    if [ -n "${FM_LIVE_TEST_SIGNAL:-}" ]; then
      kill -s "$FM_LIVE_TEST_SIGNAL" "$(cat "$FM_LIVE_TEST_PID_FILE")"
    fi
    if [ "$4" = fmft-codex-above ]; then
      python3 - "$dir" "${@: -1}" <<'PY'
import shlex
import subprocess
import sys
from pathlib import Path
worktree = Path(sys.argv[1])
words = shlex.split(sys.argv[2])
codex_home = Path(next(word.split("=", 1)[1] for word in words if word.startswith("CODEX_HOME=")))
import tomllib
with open(codex_home / "config.toml", "rb") as stream:
    ancestor = Path(next(iter(tomllib.load(stream)["projects"])))
common = subprocess.check_output(["git", "-C", str(worktree), "rev-parse", "--path-format=absolute", "--git-common-dir"], text=True).strip()
assert ancestor in worktree.parents
assert ancestor in Path(common).parent.parents
PY
    fi
    ;;
  capture-pane)
    case "$3" in
      fmft-codex-control) printf 'Trust this folder?\n' ;;
      fmft-codex-above)
        if [ "$FM_LIVE_ANCESTOR_TRUST" = 1 ]; then
          printf '› Ask Codex to do anything\n'
        else
          printf 'Trust this folder?\n'
        fi
        ;;
      fmft-codex-registered) printf '%s\n' "$FM_LIVE_REGISTERED_SCREEN" ;;
      fmft-pi-control) printf 'Trust project folder?\n' ;;
      fmft-pi-approved) printf 'ctrl+o\n' ;;
      *) exit 2 ;;
    esac
    ;;
  kill-session)
    [ -e "$socket" ]
    ;;
  kill-server)
    [ -e "$socket" ]
    printf '%s\n' "$socket" > "$FM_LIVE_TMUX_STOPPED"
    rm "$socket"
    ;;
  *) exit 2 ;;
esac
SH
  chmod +x "$fakebin/tmux"
  for scenario in empty crashed banner dialog editor shortcuts ancestor int term hup quit; do
    signal=''
    ancestor_trust=0
    case "$scenario" in
      empty) screen=''; expected=1 ;;
      crashed) screen='sh: codex: command not found'; expected=1 ;;
      banner) screen='Ask Codex to do anything'; expected=1 ;;
      dialog) screen='Trust this folder? › Ask Codex to do anything'; expected=1 ;;
      editor) screen='› Ask Codex to do anything'; expected=0 ;;
      shortcuts) screen='›  ? for shortcuts'; expected=0 ;;
      ancestor) screen='› Ask Codex to do anything'; ancestor_trust=1; expected=1 ;;
      int) screen=''; signal=INT; expected=130 ;;
      term) screen=''; signal=TERM; expected=143 ;;
      hup) screen=''; signal=HUP; expected=129 ;;
      quit) screen=''; signal=QUIT; expected=131 ;;
    esac
    : > "$case_dir/tmux.log"
    : > "$case_dir/cli.log"
    rm -f "$case_dir/stopped"
    out=$(HOME="$case_dir/home" FM_FOLDER_TRUST_LIVE=1 FM_LIVE_TMUX_LOG="$case_dir/tmux.log" \
      FM_LIVE_TMUX_STOPPED="$case_dir/stopped" FM_LIVE_TEST_SIGNAL="$signal" \
      FM_LIVE_TEST_PID_FILE="$case_dir/live.pid" \
      FM_LIVE_ANCESTOR_TRUST="$ancestor_trust" FM_LIVE_CLI_LOG="$case_dir/cli.log" \
      FM_LIVE_REGISTERED_SCREEN="$screen" PATH="$fakebin:$PATH" \
      python3 - "$ROOT/tests/fm-folder-trust-live-e2e.test.sh" "$case_dir/live.pid" 2>&1 <<'PY'
import os
import pathlib
import signal
import sys
pathlib.Path(sys.argv[2]).write_text(str(os.getpid()))
signal.signal(signal.SIGHUP, signal.SIG_DFL)
signal.signal(signal.SIGQUIT, signal.SIG_DFL)
signal.signal(signal.SIGINT, signal.SIG_DFL)
signal.signal(signal.SIGTERM, signal.SIG_DFL)
os.execvp("bash", ["bash", sys.argv[1]])
PY
)
    status=$?
    expect_code "$expected" "$status" "live guard failed the $scenario exit contract: $out"
    socket=$(head -1 "$case_dir/tmux.log" | cut -f1)
    root=${socket%/*}
    assert_equals "$socket" "$(cat "$case_dir/stopped")" "live guard removed its socket before stopping tmux"
    assert_absent "$root" "live guard leaked its registered fixture root"
    python3 - "$case_dir/tmux.log" "$socket" "$case_dir/cli.log" "$expected" <<'PY' || fail "live guard violated its pane ownership or prompt-free replay contract"
import json
import pathlib
import shlex
import sys
rows = [line.split("\t", 1) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
assert all(socket == sys.argv[2] for socket, command in rows)
assert rows[-1][1] == "kill-server"
created, closed = [], []
for _, command in rows:
    words = shlex.split(command)
    if words[0] == "new-session":
        created.append(words[words.index("-s") + 1])
    elif words[0] == "kill-session":
        closed.append(words[words.index("-t") + 1])
assert len(created) == len(set(created))
assert len(closed) == len(set(closed))
assert set(closed) <= set(created)
replays = [json.loads(line) for line in pathlib.Path(sys.argv[3]).read_text().splitlines()]
assert replays and all(row["argv"][0].startswith("-") for row in replays)
if sys.argv[4] == "0":
    assert created == closed and len(created) == 5
    pi = [row["argv"] for row in replays if row["harness"] == "pi"]
    assert len(pi) == 2
    assert "--approve" not in pi[0] and "--approve" in pi[1]
PY
  done
  pass "live guard: prompt-free replay, editor evidence, ancestor scope and owned cleanup"
}

test_live_guard_requires_editor_and_owns_cleanup
test_secondmate_automatic_trust_is_limited_to_linked_pool_homes
test_direct_registration_refuses_linked_homes_outside_the_pool
test_equivalent_toml_entries_preserve_operator_decisions
test_unsupported_and_malformed_toml_is_unchanged
test_concurrent_store_writers_keep_both_projects
test_codex_launch_reads_the_registered_store
test_spawn_fixture_isolates_an_exported_codex_home
test_fresh_worktree_registers_the_repository_root
test_registration_keys_on_the_root_not_the_worktree
test_unrelated_config_content_is_preserved
test_registration_is_idempotent
test_missing_store_is_created
test_existing_empty_entry_gains_the_decision_once
test_a_recorded_non_trusted_decision_is_not_overridden
test_an_inline_projects_table_is_refused
test_a_dotted_key_entry_is_refused
test_primary_checkout_is_refused
test_home_directory_is_refused
test_relative_codex_home_is_refused
test_non_git_and_missing_directories_are_refused
test_foreign_worktree_and_subdirectory_are_refused
test_project_argument_that_is_itself_a_worktree_registers_the_primary_checkout
test_missing_python_is_refused
test_secondmate_standalone_clone_home_requires_attended_trust
test_secondmate_leased_worktree_home_is_trusted
test_secondmate_home_refuses_everything_unseeded
test_codex_spawn_pretrusts_the_repository_root
test_codex_spawn_stops_when_registration_is_refused
test_pi_spawn_launches_with_the_trust_flag
test_pi_secondmate_launch_carries_the_trust_flag
test_pi_launch_flag_reaches_the_pi_process
