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
  awk '
    /^\[/ {
      current = ""
      if ($0 ~ /^\[projects\."/) {
        line = $0
        sub(/^\[projects\."/, "", line)
        sub(/"\][[:space:]]*$/, "", line)
        current = line
      }
      next
    }
    current != "" && /^[[:space:]]*trust_level[[:space:]]*=[[:space:]]*"trusted"/ { print current }
  ' "$store"
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

test_missing_node_is_refused() {
  local rec dir out tool
  rec=$(make_case no-node)
  read_case "$rec"
  dir="$CASE_DIR/nonode-bin"
  mkdir -p "$dir"
  for tool in bash env git mkdir cat; do
    ln -sf "$(command -v "$tool")" "$dir/$tool"
  done
  out=$(env -i PATH="$dir" CODEX_HOME="$CODEX_HOME" HOME="$CODEX_HOME" \
    "$TRUST" "$WT" "$PROJ" 2>&1)
  expect_code 1 $? "a missing node must refuse rather than launch a worker into the dialog: $out"
  assert_contains "$out" "node" "the refusal did not name the missing tool"
  pass "fm-codex-trust.sh: a missing node interpreter refuses the registration"
}

# --- secondmate homes -------------------------------------------------------

test_secondmate_standalone_clone_home_is_trusted() {
  local rec home out
  rec=$(make_case sm-clone)
  read_case "$rec"
  home="$CASE_DIR/home"
  seed_secondmate_home "$home" "android"
  out=$(run_home_trust "$CODEX_HOME" "$home" android)
  expect_code 0 $? "a seeded standalone-clone secondmate home must be trusted: $out"
  assert_trusted_root "$CODEX_HOME" "$home" "the home itself was not recorded as trusted"
  pass "fm-codex-trust.sh: a seeded secondmate home that is a standalone clone is trusted"
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

# A refused registration must degrade to the pre-existing behavior - a dialog a
# human can answer, with codex's own affirmative already selected - rather than
# fail a spawn over a config file the operator may be editing.
test_codex_spawn_launches_when_registration_is_refused() {
  local case_dir=$TMP_ROOT/spawn-codex-refused fakebin out
  mkdir -p "$case_dir"
  fakebin=$(make_launch_home "$case_dir" codex codex)
  out=$(CODEX_HOME=relative-codex-home \
    spawn_with_fakebin "$case_dir" "$case_dir/home" spawn-codex-2 "$case_dir/project" \
    "$case_dir/wt" "$fakebin")
  expect_code 0 $? "a codex spawn whose trust registration was refused must still launch: $out"
  assert_contains "$out" "could not pre-register codex folder trust" \
    "the spawn did not report the refused registration"
  assert_contains "$(cat "$case_dir/launch.log")" "codex" "the refused registration stopped the launch"
  pass "fm-spawn.sh: a refused codex trust registration warns and launches anyway"
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
  seed_secondmate_home "$home" spawn-pi-2
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
test_missing_node_is_refused
test_secondmate_standalone_clone_home_is_trusted
test_secondmate_leased_worktree_home_is_trusted
test_secondmate_home_refuses_everything_unseeded
test_codex_spawn_pretrusts_the_repository_root
test_codex_spawn_launches_when_registration_is_refused
test_pi_spawn_launches_with_the_trust_flag
test_pi_secondmate_launch_carries_the_trust_flag
test_pi_launch_flag_reaches_the_pi_process
