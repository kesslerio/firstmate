#!/usr/bin/env bash
# Behavior tests for the OpenCode model axis in bin/fm-spawn.sh.
#
# The installed OpenCode build decides how a worker's model can be selected, so
# these tests drive a real spawn against a fake `opencode` whose own CLI output
# describes each build generation, and assert what firstmate launches, writes,
# reports, and refuses. The fake never starts an agent: the fake tmux records
# the launch command instead, and the fake's session record stands in for the
# worker's own published model.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-spawn-opencode-model)
CONTROL_LIB="$ROOT/bin/fm-control-lib.sh"

cleanup_opencode_model() {
  fm_test_remove_tree "$TMP_ROOT"
}
trap cleanup_opencode_model EXIT

# make_opencode_fakebin <dir>
# The fake answers the four surfaces the launcher consults: --version, --help,
# `debug config` (the build's own parse of the project config) and the session
# list/export pair the post-launch assertion reads. Each generation's real shape
# is reproduced, including 2.0.26's missing top-level --model.
make_opencode_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_test_make_spawn_fakebin "$dir")
  mv "$fakebin/tmux" "$fakebin/tmux-fixture"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = kill-window ]; then
  printf '%s\n' "$*" >>"$FM_FAKE_STOP_LOG"
  [ "${FM_FAKE_STOP_FAIL:-0}" != 1 ] || exit 1
  [ "${FM_FAKE_STOP_SURVIVES:-0}" != 1 ] || exit 0
fi
if [ "${1:-}" = list-windows ] && [ -f "$FM_FAKE_STOP_LOG" ] && [ "${FM_FAKE_STOP_UNKNOWN:-0}" = 1 ]; then
  echo 'inventory unavailable' >&2
  exit 1
fi
if [ "${1:-}" = send-keys ]; then
  case "$*" in
    *" -l . "*)
      touch "$(dirname "$0")/launch-sent"
      if [ "${FM_FAKE_SEND_FAILURE:-}" = literal ]; then exit 1; fi
      ;;
    *" Enter"*)
      if [ -f "$(dirname "$0")/launch-sent" ] && [ "${FM_FAKE_SEND_FAILURE:-}" = enter ]; then exit 1; fi
      ;;
  esac
fi
exec "$(dirname "$0")/tmux-fixture" "$@"
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
# Match GNU timeout's option shape from bin/fm-timeout-lib.sh fm_run_timed.
if [ "${1:-}" = -k ]; then
  shift 2
fi
shift
exec "$@"
SH
  cat > "$fakebin/opencode" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"${FM_FAKE_OPENCODE_LOG:-/dev/null}"
shape=${FM_FAKE_OPENCODE_SHAPE:-2x}
case "${1:-}" in
--version)
  case "$shape" in
  noversion) exit 0 ;;
  1x) printf 'opencode v1.18.11\n' ;;
  *) printf 'opencode v2.0.26\n' ;;
  esac
  exit 0
  ;;
--help)
  case "$shape" in
  1x)
    printf '%s\n' 'DESCRIPTION' '  OpenCode command line interface' '' 'FLAGS' \
      '  -m, --model string          Model to use' '  --prompt string         Prompt to use'
    ;;
  *)
    # 2.0.26 has no top-level --model; it advertises --standalone instead.
    printf '%s\n' 'DESCRIPTION' '  OpenCode command line interface' '' 'FLAGS' \
      '  --standalone            Run with a private server instead of the background service' \
      '  --prompt string         Prompt to use'
    ;;
  esac
  exit 0
  ;;
esac
if [ "${1:-}" = debug ] && [ "${2:-}" = config ]; then
  case "$shape" in
  noreport)
    if [ "${FM_FAKE_PIN_CLEANUP_FAIL:-0}" = 1 ]; then
      rm "$PWD/.opencode/opencode.jsonc"
      mkdir "$PWD/.opencode/opencode.jsonc"
      touch "$PWD/.opencode/opencode.jsonc/blocker"
    fi
    printf '[]\n'
    ;;
  *)
    file="$PWD/.opencode/opencode.jsonc"
    if [ -f "$file" ] && model=$(jq -c '.model // empty' "$file" 2>/dev/null) && [ -n "$model" ]; then
      # The real build reports its own parse of the project config, so the fake
      # reports the model object it read out of the fixture file.
      printf '[{"type":"document","path":"%s","info":{"model":%s}}]\n' "$file" "$model"
    else
      printf '[]\n'
    fi
    ;;
  esac
  exit 0
fi
if [ "${1:-}" = session ] && [ "${2:-}" = list ]; then
  if [ -n "${FM_FAKE_OPENCODE_SESSION_MODEL:-}" ]; then
    printf '[{"id":"ses_fixture","directory":"%s","updated":%s}]\n' "$PWD" "$(date +%s)000"
  else
    printf '[]\n'
  fi
  exit 0
fi
if [ "${1:-}" = export ]; then
  [ "$shape" = 1x ] || exit 1
  provider=${FM_FAKE_OPENCODE_SESSION_MODEL%%/*}
  model=${FM_FAKE_OPENCODE_SESSION_MODEL#*/}
  jq -cn --arg provider "$provider" --arg model "$model" \
    --argjson created "${FM_FAKE_OPENCODE_ASSERT_TIME:-9999999999999}" \
    '{messages:[{info:{role:"user",time:{created:1}}},{info:{role:"assistant",time:{created:$created},providerID:$provider,modelID:$model}}]}'
  exit 0
fi
if [ "${1:-}" = session ] && [ "${2:-}" = export ]; then
  [ "$shape" != 1x ] || exit 1
  if [ "${FM_FAKE_PIN_CLEANUP_FAIL:-0}" = 1 ]; then
    rm "$PWD/.opencode/opencode.jsonc"
    mkdir "$PWD/.opencode/opencode.jsonc"
    touch "$PWD/.opencode/opencode.jsonc/blocker"
  fi
  provider=${FM_FAKE_OPENCODE_SESSION_MODEL%%/*}
  model=${FM_FAKE_OPENCODE_SESSION_MODEL#*/}
  printf '{"info":{},"messages":[{"type":"user","time":{"created":1}},{"type":"assistant","time":{"created":%s},"model":{"providerID":"%s","id":"%s"}}]}\n' \
    "${FM_FAKE_OPENCODE_ASSERT_TIME:-9999999999999}" "$provider" "$model"
  exit 0
fi
exit 0
SH
  chmod +x "$fakebin/timeout" "$fakebin/opencode"
  printf '%s\n' "$fakebin"
}

make_case() {  # <name> ; prints "case|home|proj|wt|fakebin|launchlog|id"
  local name=$1 case_dir home proj wt fakebin launchlog id
  id="oc-$name"
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_opencode_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" opencode
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog|$id"
}

read_case() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG ID <<EOF
$1
EOF
}

run_spawn() {  # <rec> [extra args...]
  local rec=$1
  shift
  read_case "$rec"
  : > "$LAUNCH_LOG"
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
    FM_FAKE_STOP_LOG="$CASE_DIR/stop.log" \
    FM_FAKE_OPENCODE_LOG="$CASE_DIR/opencode.log" \
    fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" \
    "$ID" "$PROJ_DIR" --mode direct-PR --yolo off "$@"
}

pin_file() { printf '%s\n' "$WT_DIR/.opencode/opencode.jsonc"; }
pin_record() { printf '%s\n' "$HOME_DIR/state/$ID.opencode-model-config"; }

# A project-owned OpenCode config is a tracked file on the project's default
# branch, so it must live in the fixture's own origin: the spawn freshens its
# worktree from there, and an untracked fixture file would only be read as
# uncommitted work.
seed_project_config() {  # <json>
  local json=$1
  mkdir -p "$PROJ_DIR/.opencode"
  printf '%s\n' "$json" >"$PROJ_DIR/.opencode/opencode.jsonc"
  git -C "$PROJ_DIR" add .opencode/opencode.jsonc
  git -C "$PROJ_DIR" -c user.name='Firstmate Tests' -c user.email=tests@example.invalid \
    commit -qm 'project opencode config'
  git -C "$PROJ_DIR" push -q origin main
  git -C "$WT_DIR" -c advice.detachedHead=false merge --ff-only main >/dev/null
}

test_2x_pins_model_through_project_config() {
  local rec out status pin record launch exclude
  rec=$(make_case two-x)
  read_case "$rec"
  out=$(FM_FAKE_OPENCODE_SHAPE=2x \
    FM_FAKE_OPENCODE_SESSION_MODEL=john-remote/qwen3.8-flash-next \
    run_spawn "$rec" --model john-remote/qwen3.8-flash-next)
  status=$?
  expect_code 0 "$status" "a 2.x OpenCode spawn with a model should succeed"
  pin=$(pin_file)
  record=$(pin_record)
  assert_present "$pin" "the 2.x launch did not write the worktree model pin"
  [ "$(jq -c '.model' "$pin")" = '{"providerID":"john-remote","model":"qwen3.8-flash-next"}' ] \
    || fail "the written pin is not the requested model selection: $(cat "$pin")"
  assert_present "$record" "the pin was not recorded as firstmate's own per task"
  [ "$(cat "$record")" = "$pin" ] || fail "the pin record does not name the pin: $(cat "$record")"
  exclude=$(git -C "$WT_DIR" rev-parse --git-path info/exclude)
  case "$exclude" in /*) ;; *) exclude="$WT_DIR/$exclude" ;; esac
  assert_grep '.opencode/opencode.jsonc' "$exclude" \
    "the pin is not excluded from the worker's git index"
  launch=$(cat "$LAUNCH_LOG")
  assert_not_contains "$launch" '--model' \
    "a 2.x launch must not pass the flag that build rejects: $launch"
  assert_contains "$launch" '--standalone' \
    "a 2.x launch must isolate its environment and plugin ownership: $launch"
  assert_grep 'session list --standalone --format json' "$CASE_DIR/opencode.log" \
    "model readback must not depend on the shared service"
  assert_grep 'session export ses_fixture --standalone' "$CASE_DIR/opencode.log" \
    "model export must use the same standalone session store"
  assert_contains "$launch" "OPENCODE_CONFIG_CONTENT='{\"permission\":{\"*\":\"allow\"}}'" \
    "the captain's blanket permission grant must stay byte-identical"
  assert_contains "$out" 'confirmed the model pin: requested=john-remote/qwen3.8-flash-next observed=john-remote/qwen3.8-flash-next' \
    "the pre-launch pin verification did not report the observed model"
  assert_contains "$out" 'model assertion passed' \
    "the post-launch assertion did not report its result"
  assert_contains "$out" 'requested=john-remote/qwen3.8-flash-next observed=john-remote/qwen3.8-flash-next' \
    "the post-launch assertion did not report the observed effective model"
  assert_contains "$out" "spawned $ID harness=opencode" "the spawn did not report success"
  pass "a 2.x build pins the model through the worktree project config and asserts it"
}

test_1x_keeps_the_model_flag() {
  local rec out status launch pin
  rec=$(make_case one-x)
  read_case "$rec"
  out=$(FM_FAKE_OPENCODE_SHAPE=1x \
    FM_FAKE_OPENCODE_SESSION_MODEL=john-remote/qwen3.8-flash-next \
    run_spawn "$rec" --model john-remote/qwen3.8-flash-next)
  status=$?
  expect_code 0 "$status" "a 1.x OpenCode spawn with a model should succeed"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--model 'john-remote/qwen3.8-flash-next'" \
    "a 1.x launch must keep passing the model on its verified flag"
  assert_no_grep --standalone "$CASE_DIR/opencode.log" \
    "a 1.x session read must not receive the 2.x-only standalone flag"
  pin=$(pin_file)
  assert_absent "$pin" "a 1.x launch must not write a 2.x-era project config pin"
  assert_contains "$out" 'through the top-level --model flag' \
    "the launcher did not report the 1.x mechanism it resolved"
  pass "a clearly older build keeps its verified --model launch and gets no 2.x pin"
}

test_build_that_cannot_report_the_pin_refuses() {
  local rec out status pin
  rec=$(make_case noreport)
  read_case "$rec"
  out=$(FM_FAKE_OPENCODE_SHAPE=noreport \
    FM_FAKE_OPENCODE_SESSION_MODEL=john-remote/qwen3.8-flash-next \
    run_spawn "$rec" --model john-remote/qwen3.8-flash-next)
  status=$?
  expect_code 1 "$status" "a build that cannot report the pinned model must refuse the spawn"
  assert_contains "$out" 'opencode v2.0.26 did not report the pinned model back from' \
    "the refusal must name the exact build version and reason"
  assert_contains "$out" 'refusing to launch a worker that would run on this build'"'"'s default model' \
    "the refusal must state the consequence it prevents"
  pin=$(pin_file)
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused spawn must not deliver a launch command: $(cat "$LAUNCH_LOG")"
  pass "a build whose model surface the launcher cannot verify refuses with its version and reason"
}

test_unreadable_version_refuses() {
  local rec out status
  rec=$(make_case noversion)
  out=$(FM_FAKE_OPENCODE_SHAPE=noversion \
    FM_FAKE_OPENCODE_SESSION_MODEL=john-remote/qwen3.8-flash-next \
    run_spawn "$rec" --model john-remote/qwen3.8-flash-next)
  status=$?
  expect_code 1 "$status" "an unreadable OpenCode version must refuse the spawn"
  assert_contains "$out" "'opencode --version' produced no readable version" \
    "the refusal must name the unreadable surface"
  pass "an unreadable build identity refuses instead of launching on a default model"
}

test_mismatched_effective_model_refuses() {
  local rec out status
  rec=$(make_case mismatch)
  read_case "$rec"
  out=$(FM_FAKE_OPENCODE_SHAPE=2x \
    FM_FAKE_OPENCODE_SESSION_MODEL=opencode/minimax-m3.1-flash-free \
    run_spawn "$rec" --model john-remote/qwen3.8-flash-next)
  status=$?
  expect_code 1 "$status" "a worker whose first message used another model must refuse the spawn"
  assert_contains "$out" "ran $ID's first message on model 'opencode/minimax-m3.1-flash-free', not the requested 'john-remote/qwen3.8-flash-next'" \
    "the refusal must report both the observed and requested models"
  assert_grep 'failed ' "$HOME_DIR/state/$ID.status" \
    "the wrong-model refusal must be recorded as a failed launch"
  assert_grep "kill-window -t =firstmate:=fm-$ID" "$CASE_DIR/stop.log" "must stop only the task endpoint"
  assert_absent "$HOME_DIR/state/$ID.meta" "stopped fresh spawn must roll back its record"
  assert_absent "$(pin_file)" "stopped fresh spawn must retire its pin before slot release"
  assert_absent "$(pin_record)" "stopped fresh spawn must retire its pin ownership record"
  pass "a wrong-model lane surfaces at once instead of looking healthy"
}

test_unreadable_session_record_refuses() {
  local rec out status
  rec=$(make_case unreadable)
  read_case "$rec"
  out=$(FM_FAKE_OPENCODE_SHAPE=2x FM_FAKE_OPENCODE_SESSION_MODEL='' \
    FM_OPENCODE_MODEL_ASSERT_POLLS=2 FM_OPENCODE_MODEL_ASSERT_INTERVAL=1 \
    run_spawn "$rec" --model john-remote/qwen3.8-flash-next)
  status=$?
  expect_code 1 "$status" "an unreadable model assertion must count as a failure"
  assert_contains "$out" 'recorded no model this launcher could read' \
    "the refusal must name the unreadable assertion"
  assert_contains "$out" 'an unread model assertion is a failure' \
    "the refusal must state that an unread result is never a pass"
  assert_grep "kill-window -t =firstmate:=fm-$ID" "$CASE_DIR/stop.log" "unreadable model must stop its task endpoint"
  assert_absent "$HOME_DIR/state/$ID.meta" "stopped fresh spawn must roll back its record"
  assert_absent "$(pin_file)" "stopped fresh spawn must retire its pin before slot release"
  assert_absent "$(pin_record)" "stopped fresh spawn must retire its pin ownership record"
  pass "an unread model assertion refuses rather than passing silently"
}

test_effort_variant_rides_the_model_selection() {
  local rec out status pin
  rec=$(make_case variant)
  read_case "$rec"
  out=$(FM_FAKE_OPENCODE_SHAPE=2x \
    FM_FAKE_OPENCODE_SESSION_MODEL=anthropic/claude-sonnet-4-5 \
    run_spawn "$rec" --model anthropic/claude-sonnet-4-5 --effort high)
  status=$?
  expect_code 0 "$status" "a mapped effort on a 2.x build should succeed"
  pin=$(pin_file)
  [ "$(jq -c '.model' "$pin")" = '{"providerID":"anthropic","model":"claude-sonnet-4-5","variant":"high"}' ] \
    || fail "the effort did not ride the native model selection: $(cat "$pin")"
  assert_contains "$out" 'observed=anthropic/claude-sonnet-4-5#high' \
    "the pin verification did not report the variant it read back"
  pass "a mapped effort rides the same native model selection the model does"
}

test_effort_outside_the_provider_list_is_omitted() {
  local rec status pin
  rec=$(make_case no-variant)
  read_case "$rec"
  FM_FAKE_OPENCODE_SHAPE=2x \
    FM_FAKE_OPENCODE_SESSION_MODEL=john-remote/qwen3.8-flash-next \
    run_spawn "$rec" --model john-remote/qwen3.8-flash-next --effort high >/dev/null
  status=$?
  expect_code 0 "$status" "an unmapped provider effort should still launch"
  pin=$(pin_file)
  [ "$(jq -c '.model' "$pin")" = '{"providerID":"john-remote","model":"qwen3.8-flash-next"}' ] \
    || fail "an unverified provider's variant must be omitted, not guessed: $(cat "$pin")"
  pass "an effort outside a verified provider list is recorded and omitted"
}

test_project_owned_config_is_never_clobbered() {
  local rec out status pin
  rec=$(make_case owned)
  read_case "$rec"
  seed_project_config '{"model":{"providerID":"qualitycorp-glm","model":"GLM-5.3-Flash-oQ4e-mtp"},"permission":{"*":"allow"}}'
  out=$(FM_FAKE_OPENCODE_SHAPE=2x \
    FM_FAKE_OPENCODE_SESSION_MODEL=john-remote/qwen3.8-flash-next \
    run_spawn "$rec" --model john-remote/qwen3.8-flash-next)
  status=$?
  expect_code 1 "$status" "a project-owned pin that names another model must refuse"
  assert_contains "$out" 'already carries an OpenCode project configuration' \
    "the refusal must name the project-owned file"
  assert_contains "$out" 'refusing to overwrite a project-owned file' \
    "the refusal must state that firstmate will not clobber it"
  pin=$(pin_file)
  assert_grep '"qualitycorp-glm"' "$pin" "the project-owned config was modified"
  pass "a project-owned OpenCode config is refused, never overwritten"
}

test_project_config_already_naming_the_model_is_kept() {
  local rec out status pin record
  rec=$(make_case owned-match)
  read_case "$rec"
  seed_project_config '{"model":{"providerID":"john-remote","model":"qwen3.8-flash-next"}}'
  out=$(FM_FAKE_OPENCODE_SHAPE=2x \
    FM_FAKE_OPENCODE_SESSION_MODEL=john-remote/qwen3.8-flash-next \
    run_spawn "$rec" --model john-remote/qwen3.8-flash-next)
  status=$?
  expect_code 0 "$status" "a project config already naming the model should launch"
  pin=$(pin_file)
  record=$(pin_record)
  [ "$(cat "$pin")" = '{"model":{"providerID":"john-remote","model":"qwen3.8-flash-next"}}' ] \
    || fail "an already-correct project config must be left byte-identical: $(cat "$pin")"
  assert_absent "$record" "a pin firstmate did not write must not be recorded as its own"
  assert_contains "$out" "the project's own" "the launcher did not report that it kept the project config"
  pass "a project config that already selects the requested model is kept untouched"
}

test_garbage_model_id_refuses_before_launch() {
  local rec out status
  rec=$(make_case bad-model)
  read_case "$rec"
  out=$(FM_FAKE_OPENCODE_SHAPE=2x \
    FM_FAKE_OPENCODE_SESSION_MODEL=john-remote/qwen3.8-flash-next \
    run_spawn "$rec" --model deepseek-v4.1-flash-free)
  status=$?
  expect_code 1 "$status" "a model without a provider prefix must refuse"
  assert_contains "$out" 'is not a provider/model id' \
    "the refusal must explain OpenCode's own model id shape"
  [ ! -s "$LAUNCH_LOG" ] || fail "a refused model id must not deliver a launch command"
  pass "an OpenCode model id without its provider refuses with the accepted shape"
}

test_pin_retirement_is_scoped_to_firstmate_owned_files() {
  local rec pin record paths
  rec=$(make_case retire)
  read_case "$rec"
  pin=$(pin_file)
  record=$(pin_record)
  mkdir -p "$WT_DIR/.opencode" "$HOME_DIR/state"
  printf '%s\n' '{"model":{"providerID":"john-remote","model":"qwen3.8-flash-next"}}' >"$pin"
  # shellcheck source=bin/fm-control-lib.sh
  . "$CONTROL_LIB"
  paths=$(fm_control_harness_wiring_paths opencode "$WT_DIR" "$HOME_DIR/state" "$ID")
  assert_not_contains "$paths" "$pin" \
    "a pin with no firstmate record must never be listed for removal"
  printf '%s\n' "$pin" >"$record"
  paths=$(fm_control_harness_wiring_paths opencode "$WT_DIR" "$HOME_DIR/state" "$ID")
  assert_contains "$paths" "$pin" \
    "a firstmate-owned pin must be retired with the task"
  assert_contains "$paths" "$record" \
    "the pin's own record must be retired with it"
  pass "pin retirement removes only the file firstmate recorded as its own"
}

test_failed_stop_retains_recovery_records() {
  local rec out status observed name
  for name in wrong unreadable; do
    rec=$(make_case "stop-fails-$name")
    read_case "$rec"
    observed=opencode/other
    [ "$name" != unreadable ] || observed=
    out=$(FM_FAKE_STOP_FAIL=1 FM_FAKE_OPENCODE_SESSION_MODEL="$observed" \
      FM_OPENCODE_MODEL_ASSERT_POLLS=1 FM_OPENCODE_MODEL_ASSERT_INTERVAL=1 \
      run_spawn "$rec" --model john-remote/qwen3.8-flash-next)
    status=$?
    expect_code 1 "$status" "unconfirmed stop must refuse launch"
    assert_present "$HOME_DIR/state/$ID.meta" "unconfirmed stop must retain task metadata"
    assert_present "$HOME_DIR/state/$ID.busy-gen" "unconfirmed stop must retain busy generation"
    assert_present "$HOME_DIR/state/$ID.busy-state" "unconfirmed stop must retain busy ownership"
    assert_contains "$out" 'stop this endpoint before retrying' "failure must provide recovery guidance"
    assert_grep "kill-window -t =firstmate:=fm-$ID" "$CASE_DIR/stop.log" "stop must target only its worker"
  done
  pass "unconfirmed stops preserve supervision for wrong and unreadable models"
}

test_secondmate_config_resolves_before_model_probe() {
  local rec sm out status shape pin
  for shape in 1x 2x; do
    rec=$(make_case "secondmate-$shape")
    read_case "$rec"
    sm="$CASE_DIR/secondmate-home"
    mkdir -p "$sm/bin" "$sm/data"
    printf '# Firstmate\n' >"$sm/AGENTS.md"
    printf '%s\n' "$ID" >"$sm/.fm-secondmate-home"
    printf 'charter\n' >"$sm/data/charter.md"
    git -C "$sm" init -q -b main
    printf 'opencode anthropic/claude-sonnet-4-5 high\n' >"$HOME_DIR/config/secondmate-harness"
    out=$(FM_FAKE_OPENCODE_SHAPE="$shape" \
      FM_FAKE_OPENCODE_SESSION_MODEL=anthropic/claude-sonnet-4-5 \
      FM_FAKE_STOP_LOG="$CASE_DIR/stop.log" FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" \
      fm_test_run_spawn "$HOME_DIR" "$sm" "$FAKEBIN_DIR" "$ID" "$sm" --secondmate)
    status=$?
    expect_code 0 "$status" "configured secondmate must launch: $out"
    assert_contains "$out" 'model assertion passed' "configured model must be verified"
    assert_absent "$CASE_DIR/stop.log" "successful launch must not stop its worker"
    if [ "$shape" = 2x ]; then
      pin="$sm/.opencode/opencode.jsonc"
      [ "$(jq -c '.model' "$pin")" = '{"providerID":"anthropic","model":"claude-sonnet-4-5","variant":"high"}' ] \
        || fail "configured secondmate model and effort were not pinned"
    else
      assert_grep "--model 'anthropic/claude-sonnet-4-5'" "$LAUNCH_LOG" "configured 1.x model must use the flag"
      assert_grep '"variant":"high"' "$LAUNCH_LOG" "configured 1.x effort must use build-agent config"
    fi
  done
  pass "secondmate configured model and effort resolve before either build probe"
}

test_successful_close_without_proven_absence_retains_records() {
  local rec out status mode observed name
  for mode in survives unknown; do
    for name in wrong unreadable; do
      rec=$(make_case "$mode-$name")
      read_case "$rec"
      observed=opencode/other
      [ "$name" != unreadable ] || observed=
      out=$(FM_FAKE_STOP_SURVIVES="$([ "$mode" != survives ] || printf 1)" \
        FM_FAKE_STOP_UNKNOWN="$([ "$mode" != unknown ] || printf 1)" \
        FM_FAKE_OPENCODE_SESSION_MODEL="$observed" \
        FM_OPENCODE_MODEL_ASSERT_POLLS=1 FM_OPENCODE_MODEL_ASSERT_INTERVAL=1 \
        run_spawn "$rec" --model john-remote/qwen3.8-flash-next)
      status=$?
      expect_code 1 "$status" "unproven absence must refuse launch"
      assert_present "$HOME_DIR/state/$ID.meta" "$mode/$name unproven absence must preserve metadata: $out"
      assert_present "$HOME_DIR/state/$ID.busy-gen" "unproven absence must preserve busy generation"
      assert_contains "$out" 'could not confirm stopping task endpoint' "close success alone must not authorize rollback"
    done
  done
  pass "surviving and unreadable endpoints preserve supervision after successful close commands"
}

test_pin_cleanup_failure_preserves_launch_recovery() {
  local rec out status
  rec=$(make_case pin-cleanup-fails)
  read_case "$rec"
  out=$(FM_FAKE_PIN_CLEANUP_FAIL=1 FM_FAKE_OPENCODE_SESSION_MODEL=opencode/other \
    run_spawn "$rec" --model john-remote/qwen3.8-flash-next)
  status=$?
  expect_code 1 "$status" "pin cleanup failure must refuse"
  assert_present "$(pin_record)" "cleanup failure must retain pin ownership"
  assert_present "$HOME_DIR/state/$ID.meta" "cleanup failure must retain task metadata"
  assert_present "$HOME_DIR/state/$ID.busy-gen" "cleanup failure must retain busy ownership"
  assert_absent "$CASE_DIR/stop.log" "slot must not be released before pin retirement"
  assert_contains "$out" 'could not retire task-owned model pin' "cleanup refusal needs recovery context"
  pass "failed pin retirement preserves recovery and prevents slot release"
}

test_pin_retirement_uses_owning_home_and_preserves_project_config() {
  local rec child_state pin record
  rec=$(make_case child-pin-owner)
  read_case "$rec"
  child_state="$CASE_DIR/child-home/state"
  mkdir -p "$child_state" "$WT_DIR/.opencode"
  pin=$(pin_file)
  record="$child_state/$ID.opencode-model-config"
  printf 'project-owned\n' >"$pin"
  # shellcheck source=bin/fm-control-lib.sh
  . "$CONTROL_LIB"
  fm_control_retire_opencode_model_pin "$ID" "$WT_DIR" "$child_state" || fail "project config cleanup refused"
  [ "$(cat "$pin")" = project-owned ] || fail "unowned project config changed"
  printf '%s\n' "$pin" >"$record"
  fm_control_retire_opencode_model_pin "$ID" "$WT_DIR" "$HOME_DIR/state" || fail "parent state cleanup refused"
  assert_present "$pin" "parent state must not claim a child's pin"
  fm_control_retire_opencode_model_pin "$ID" "$WT_DIR" "$child_state" || fail "child pin retirement refused"
  assert_absent "$pin" "child-owned stale pin must be retired"
  assert_absent "$record" "successful retirement must remove child ownership record"
  mkdir "$pin"
  touch "$pin/blocker"
  printf '%s\n' "$pin" >"$record"
  if fm_control_retire_opencode_model_pin "$ID" "$WT_DIR" "$child_state" 2>/dev/null; then
    fail "nonempty pin directory must refuse cleanup"
  fi
  assert_present "$record" "failed child pin retirement must preserve ownership"
  pass "pin retirement uses the owning home and preserves project files and cleanup-failure records"
}

test_1x_rejects_wrong_unreadable_and_stale_models() {
  local rec out status name observed stamp
  for name in wrong unreadable stale; do
    rec=$(make_case "one-x-$name")
    read_case "$rec"
    observed=john-remote/qwen3.8-flash-next
    stamp=9999999999999
    case "$name" in
      wrong) observed=opencode/other ;;
      unreadable) observed= ;;
      stale) stamp=1 ;;
    esac
    out=$(FM_FAKE_OPENCODE_SHAPE=1x FM_FAKE_OPENCODE_SESSION_MODEL="$observed" \
      FM_FAKE_OPENCODE_ASSERT_TIME="$stamp" \
      FM_OPENCODE_MODEL_ASSERT_POLLS=1 FM_OPENCODE_MODEL_ASSERT_INTERVAL=1 \
      run_spawn "$rec" --model john-remote/qwen3.8-flash-next)
    status=$?
    expect_code 1 "$status" "1.x $name model must refuse"
    assert_contains "$out" 'stopped task endpoint' "1.x refusal must stop its worker"
    assert_absent "$HOME_DIR/state/$ID.meta" "confirmed 1.x stop must roll back"
    assert_no_grep 'session export' "$CASE_DIR/opencode.log" "1.x must never use 2.x export"
    if [ "$name" != unreadable ]; then
      assert_grep 'export ses_fixture' "$CASE_DIR/opencode.log" "1.x readback must use top-level export"
    fi
  done
  pass "1.x rejects wrong, absent and stale observations through its native protocol"
}

test_failed_spawn_paths_retire_owned_pin() {
  local rec out status stage shape send turn
  for stage in debug literal enter delivery; do
    rec=$(make_case "abort-$stage")
    read_case "$rec"
    shape=2x send='' turn=auto
    case "$stage" in
      debug) shape=noreport ;;
      literal|enter) send=$stage ;;
      delivery) turn=never ;;
    esac
    out=$(FM_FAKE_OPENCODE_SHAPE="$shape" FM_FAKE_SEND_FAILURE="$send" \
      FM_FAKE_OPENCODE_TURN="$turn" FM_OPENCODE_DELIVERY_POLLS=1 \
      FM_FAKE_OPENCODE_SESSION_MODEL=john-remote/qwen3.8-flash-next \
      run_spawn "$rec" --model john-remote/qwen3.8-flash-next)
    status=$?
    expect_code 1 "$status" "$stage refusal must fail"
    assert_absent "$(pin_file)" "$stage refusal left a stale model pin"
    assert_absent "$(pin_record)" "$stage refusal left a pin ownership record"
    assert_absent "$HOME_DIR/state/$ID.meta" "$stage refusal must roll back after pin cleanup"
  done
  rec=$(make_case abort-debug-cleanup-fails)
  read_case "$rec"
  out=$(FM_FAKE_OPENCODE_SHAPE=noreport FM_FAKE_PIN_CLEANUP_FAIL=1 \
    run_spawn "$rec" --model john-remote/qwen3.8-flash-next)
  status=$?
  expect_code 1 "$status" "failed abort cleanup must refuse"
  assert_present "$(pin_record)" "abort cleanup failure must retain ownership"
  assert_present "$HOME_DIR/state/$ID.meta" "abort cleanup failure must retain recovery metadata"
  assert_present "$HOME_DIR/state/$ID.busy-gen" "abort cleanup failure must retain busy generation"
  assert_contains "$out" 'retained' "abort cleanup failure must explain recovery"
  pass "debug, send and delivery refusals retire pins and failed retirement preserves recovery"
}

test_inline_model_variants_are_refused() {
  local rec out status shape
  for shape in 1x 2x; do
    rec=$(make_case "inline-$shape")
    read_case "$rec"
    out=$(FM_FAKE_OPENCODE_SHAPE="$shape" run_spawn "$rec" \
      --model anthropic/claude-sonnet-4-5#max --effort high)
    status=$?
    expect_code 1 "$status" "inline variant must refuse on $shape"
    assert_contains "$out" 'use provider/model with --effort instead' "inline refusal must explain the supported interface"
    [ ! -s "$LAUNCH_LOG" ] || fail "inline variant launched a worker"
    assert_absent "$(pin_file)" "inline variant must not write a pin"
  done
  pass "both generations refuse inline variants rather than overriding explicit effort"
}

test_live_guard_launches_the_probed_absolute_binary() {
  local lab fakebin decoy out status
  lab="$TMP_ROOT/live-identity"
  fakebin="$lab/installed ' build"
  decoy="$lab/pane-path"
  mkdir -p "$fakebin" "$decoy"
  cat >"$fakebin/opencode" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  --version) printf '2.0.26\n' ;;
  models) printf 'fixture/model\n' ;;
  debug) jq -c --arg path "$PWD/.opencode/opencode.jsonc" '[{path:$path,info:.}]' .opencode/opencode.jsonc ;;
  session)
    case "${2:-}" in
      list) [ -f started ] && jq -cn --arg dir "$PWD" '[{id:"live",directory:$dir,updated:1}]' || printf '[]\n' ;;
      export) printf '{"messages":[{"type":"assistant","model":{"providerID":"fixture","id":"model"}}]}\n' ;;
    esac
    ;;
  --standalone) touch started; printf '%s\n' "$0" >"$FM_LIVE_IDENTITY_LOG" ;;
esac
SH
  cat >"$decoy/opencode" <<'SH'
#!/usr/bin/env bash
printf 'wrong executable\n' >"$FM_LIVE_IDENTITY_LOG"
exit 1
SH
  cat >"$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
shift 2
case "$1" in
  new-session)
    while [ "$#" -gt 0 ]; do
      if [ "$1" = -c ]; then printf '%s\n' "$2" >"$FM_LIVE_PANE_DIR"; break; fi
      shift
    done
    ;;
  send-keys)
    shift 3
    cd "$(cat "$FM_LIVE_PANE_DIR")" || exit 1
    PATH="$FM_LIVE_DECOY:$PATH" bash -c "$1"
    ;;
  kill-server) ;;
esac
SH
  chmod +x "$fakebin/opencode" "$fakebin/tmux" "$decoy/opencode"
  out=$(PATH="$fakebin:$PATH" FM_OPENCODE_MODEL_LIVE=1 \
    FM_LIVE_IDENTITY_LOG="$lab/identity" FM_LIVE_PANE_DIR="$lab/pane-dir" \
    FM_LIVE_DECOY="$decoy" bash "$ROOT/tests/fm-opencode-model-live-e2e.test.sh")
  status=$?
  expect_code 0 "$status" "isolated live-guard identity fixture failed: $out"
  [ "$(cat "$lab/identity")" = "$fakebin/opencode" ] || fail "pane PATH changed the tested executable"
  assert_contains "$out" 'requested=fixture/model observed=fixture/model' "identity fixture must retain model comparison"
  pass "the live guard uses its probed executable despite pane PATH changes and quoted path characters"
}

test_final_commit_failure_retires_pin_or_preserves_recovery() {
  local rec out status fail_cleanup real_tasks
  real_tasks=$(command -v tasks-axi) || fail "tasks-axi is required to verify final commit rollback"
  for fail_cleanup in 0 1 signal; do
    rec=$(make_case "commit-refused-$fail_cleanup")
    read_case "$rec"
    printf 'backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n' >"$HOME_DIR/.tasks.toml"
    printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' >"$HOME_DIR/data/backlog.md"
    (cd "$HOME_DIR" && "$real_tasks" add "$ID" 'model commit rollback' --kind ship --file "$HOME_DIR/data/backlog.md") >/dev/null || fail "could not seed commit fixture"
    cat >"$FAKEBIN_DIR/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = start ]; then
  if [ "$FM_COMMIT_PIN_CLEANUP_FAIL" = signal ]; then
    "$FM_REAL_TASKS_AXI" "$@" || exit 1
    spawn_pid=$(ps -o ppid= -p "$PPID" | tr -d ' ')
    case "$spawn_pid" in ''|*[!0-9]*) exit 1 ;; esac
    kill -TERM "$spawn_pid"
    exit 0
  fi
  if [ "$FM_COMMIT_PIN_CLEANUP_FAIL" = 1 ] && [ -f "$FM_COMMIT_PIN" ]; then
    rm "$FM_COMMIT_PIN"
    mkdir "$FM_COMMIT_PIN"
    touch "$FM_COMMIT_PIN/blocker"
  fi
  echo 'fixture refused backlog commit' >&2
  exit 1
fi
exec "$FM_REAL_TASKS_AXI" "$@"
SH
    chmod +x "$FAKEBIN_DIR/tasks-axi"
    out=$(FM_REAL_TASKS_AXI="$real_tasks" FM_COMMIT_PIN_CLEANUP_FAIL="$fail_cleanup" \
      FM_COMMIT_PIN="$(pin_file)" FM_FAKE_OPENCODE_SESSION_MODEL=john-remote/qwen3.8-flash-next \
      run_spawn "$rec" --model john-remote/qwen3.8-flash-next)
    status=$?
    [ "$status" -ne 0 ] || fail "refused final commit must fail"
    if [ "$fail_cleanup" = signal ]; then
      assert_contains "$out" 'interrupted after launch delivery began' "fixture must reach committed signal preservation"
      assert_present "$(pin_file)" "a committed worker must retain its pin after a signal"
      assert_present "$(pin_record)" "a committed worker must retain pin ownership"
      assert_present "$HOME_DIR/state/$ID.meta" "a committed worker must retain supervision"
      continue
    fi
    assert_contains "$out" 'could not be moved to In flight' "fixture must reach final commit rollback"
    if [ "$fail_cleanup" = 1 ]; then
      assert_present "$(pin_record)" "failed final cleanup must preserve ownership"
      assert_present "$HOME_DIR/state/$ID.meta" "failed final cleanup must preserve recovery metadata"
      assert_present "$HOME_DIR/state/$ID.busy-gen" "failed final cleanup must preserve busy generation"
    else
      assert_absent "$(pin_file)" "final rollback must retire pin"
      assert_absent "$(pin_record)" "final rollback must retire pin ownership"
      assert_absent "$HOME_DIR/state/$ID.meta" "successful final cleanup must permit rollback"
    fi
  done
  pass "final commit refusal retires owned pins and preserves recovery if retirement fails"
}

test_pin_publication_failures_keep_ownership() {
  local rec out status mode reused exclude fault_env
  for reused in fresh ignored; do
    for mode in record-open record partial cleanup; do
      rec=$(make_case "publish-$reused-$mode")
      read_case "$rec"
      if [ "$reused" = ignored ]; then
        exclude=$(git -C "$WT_DIR" rev-parse --git-path info/exclude)
        case "$exclude" in /*) ;; *) exclude="$WT_DIR/$exclude" ;; esac
        printf '.opencode/opencode.jsonc\n' >>"$exclude"
      fi
      if [ "$mode" = record-open ]; then
        mkdir "$(pin_record)"
      fi
      fault_env="$CASE_DIR/publication-fault.sh"
      cat >"$fault_env" <<'SH'
printf() {
  if [ "$#" = 2 ] && [ "$1" = '%s\n' ] && [ "$2" = "$FM_PUBLICATION_PIN" ] && [ "$FM_PUBLICATION_MODE" = record ]; then
    builtin printf 'record write refused\n' >"$FM_PUBLICATION_EVENT"
    return 1
  fi
  if [ "${1:-}" = '{"model":%s}\n' ]; then
    if [ -f "$FM_PUBLICATION_RECORD" ] && [ "$(cat "$FM_PUBLICATION_RECORD")" = "$FM_PUBLICATION_PIN" ]; then
      builtin printf 'ownership established before partial pin write\n' >"$FM_PUBLICATION_EVENT"
    else
      builtin printf 'partial pin write without ownership\n' >"$FM_PUBLICATION_EVENT"
    fi
    builtin printf '{"model":'
    return 1
  fi
  builtin printf "$@"
}
SH
      cat >"$FAKEBIN_DIR/rm" <<'SH'
#!/usr/bin/env bash
if [ "$FM_PUBLICATION_MODE" = cleanup ]; then
  for arg in "$@"; do
    if [ "$arg" = "$FM_PUBLICATION_PIN" ]; then
      echo 'fixture refused pin removal' >&2
      exit 1
    fi
  done
fi
exec "$FM_PUBLICATION_REAL_RM" "$@"
SH
      chmod +x "$FAKEBIN_DIR/rm"
      out=$(BASH_ENV="$fault_env" FM_PUBLICATION_MODE="$mode" \
        FM_PUBLICATION_PIN="$(pin_file)" FM_PUBLICATION_RECORD="$(pin_record)" \
        FM_PUBLICATION_EVENT="$CASE_DIR/publication-event" FM_PUBLICATION_REAL_RM="$(command -v rm)" \
        FM_FAKE_OPENCODE_SESSION_MODEL=john-remote/qwen3.8-flash-next \
        run_spawn "$rec" --model john-remote/qwen3.8-flash-next)
      status=$?
      expect_code 1 "$status" "$reused/$mode publication failure must refuse"
      [ ! -s "$LAUNCH_LOG" ] || fail "publication failure launched a worker"
      case "$mode" in
        record-open|record)
          assert_absent "$(pin_file)" "ownership failure must not create a pin"
          if [ "$mode" = record ]; then
            assert_grep 'record write refused' "$CASE_DIR/publication-event" "record failure injection was not reached"
          fi
          assert_contains "$out" 'could not record ownership' "record refusal needs actionable context"
          ;;
        partial|cleanup)
          assert_grep 'ownership established before partial pin write' "$CASE_DIR/publication-event" "partial pin must already have valid ownership"
          if [ "$mode" = partial ]; then
            assert_absent "$(pin_file)" "partial pin must be removed on abort"
            assert_absent "$(pin_record)" "successful partial-pin cleanup must retire ownership"
            assert_absent "$HOME_DIR/state/$ID.meta" "successful cleanup must allow rollback"
          else
            [ "$(cat "$(pin_file)")" = '{"model":' ] || fail "fixture did not retain the partial write"
            [ "$(cat "$(pin_record)")" = "$(pin_file)" ] || fail "cleanup refusal lost valid pin ownership"
            assert_present "$HOME_DIR/state/$ID.meta" "cleanup refusal must retain recovery metadata"
            assert_present "$HOME_DIR/state/$ID.busy-gen" "cleanup refusal must retain busy generation"
            assert_contains "$out" 'retained' "cleanup refusal must explain recovery"
          fi
          ;;
      esac
    done
  done
  pass "fresh and reused ignored pin paths keep ownership across publication and cleanup failures"
}

test_pin_publication_failures_keep_ownership
test_final_commit_failure_retires_pin_or_preserves_recovery
test_failed_spawn_paths_retire_owned_pin
test_inline_model_variants_are_refused
test_live_guard_launches_the_probed_absolute_binary
test_1x_rejects_wrong_unreadable_and_stale_models
test_successful_close_without_proven_absence_retains_records
test_pin_cleanup_failure_preserves_launch_recovery
test_pin_retirement_uses_owning_home_and_preserves_project_config
test_failed_stop_retains_recovery_records
test_secondmate_config_resolves_before_model_probe
test_2x_pins_model_through_project_config
test_1x_keeps_the_model_flag
test_build_that_cannot_report_the_pin_refuses
test_unreadable_version_refuses
test_mismatched_effective_model_refuses
test_unreadable_session_record_refuses
test_effort_variant_rides_the_model_selection
test_effort_outside_the_provider_list_is_omitted
test_project_owned_config_is_never_clobbered
test_project_config_already_naming_the_model_is_kept
test_garbage_model_id_refuses_before_launch
test_pin_retirement_is_scoped_to_firstmate_owned_files
