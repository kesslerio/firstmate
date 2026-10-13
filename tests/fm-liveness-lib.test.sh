#!/usr/bin/env bash
# Public seat-snapshot, config propagation, and confirmed-launch behavior.
# Optional R1, R1race, R2, R3 or R4 argument runs that public review regression alone.
set -eu
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-liveness)

liveness_relaunch_tools() { # <directory>
  local dir=$1 tools
  tools=$(fm_test_make_spawn_fakebin "$dir/tools" gh)
  fm_test_fake_no_mistakes "$tools"
  mkdir -p "$dir/endpoint"
  printf zsh > "$dir/endpoint/command"
  cat > "$tools/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message)
    case "$*" in
      *pane_current_command*) cat "$FM_FAKE_DIR/command"; echo ;;
      *pane_current_path*) echo "$FM_FAKE_PANE_PATH" ;;
      *cursor_y*) echo 1 ;;
      *) echo fakepane ;;
    esac ;;
  list-windows) echo fm-worker ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n' ;;
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in -t) shift 2 ;; -l) literal=1; shift ;; *) break ;; esac
    done
    [ "$literal" = 1 ] || exit 0
    payload=${1:-}
    case "$payload" in ". '"*"'") staged=${payload#". '"}; staged=${staged%"'"}; payload=$(cat "$staged") ;; esac
    printf '%s\n' "$payload" >> "$FM_FAKE_DIR/delivery"
    case "$payload" in /exit|/quit) printf zsh > "$FM_FAKE_DIR/command" ;; *'encode launch-brief'*) printf claude > "$FM_FAKE_DIR/command" ;; esac ;;
esac
SH
  chmod +x "$tools/tmux"
  printf '%s\n' "$tools"
}

test_relaunch_withdraws_previous_ready_handoff() {
  local dir home project worktree tools extra_tools out before contract records stamp state pr head
  dir="$TMP_ROOT/relaunch"; home="$dir/home"
  project="$dir/project"; worktree="$dir/worker"
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$project" "$worktree" replacement-worker
  fm_test_spawn_brief "$home" worker
  tools=$(liveness_relaunch_tools "$dir")
  pr=https://github.com/example/project/pull/7
  head=0123456789abcdef0123456789abcdef01234567
  fm_write_meta "$home/state/worker.meta" window=fmses:fm-worker endpoint_task_id=worker \
    "worktree=$worktree" "project=$project" harness=claude kind=ship mode=no-mistakes yolo=off \
    "tasktmp=$dir/tasktmp" model=default effort=default "pr=$pr" "pr_head=$head"
  # A legitimate legacy ready handoff frees its seat before replacement.
  . "$ROOT/bin/fm-liveness-lib.sh"
  PATH="$tools:$PATH" fm_liveness_snapshot "$home"
  assert_equals 0 "$FM_LIVENESS_LIVE" 'ordinary canonical legacy handoff releases its seat'
  out=$(FM_FAKE_DIR="$dir/endpoint" fm_test_run_spawn "$home" "$worktree" "$tools" worker --relaunch) \
    || fail "primary relaunch failed: $out"
  assert_equals claude "$(cat "$dir/endpoint/command")" 'replacement was delivered to the stopped endpoint'
  [ -s "$dir/endpoint/delivery" ] || fail 'replacement has no launch delivery'
  assert_equals "$pr" "$(fm_meta_get "$home/state/worker.meta" pr)" 'replacement retains lifecycle PR association'
  assert_equals "$head" "$(fm_meta_get "$home/state/worker.meta" pr_head)" 'replacement retains review head association'
  fm_pr_metadata_identity_parse "$home/state/worker.meta" || fail 'replacement PR association must remain canonically valid'
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" worker busy --current-gen --source claude-hook --event user-prompt-submit >/dev/null
  out=$(FM_HOME="$home" FM_CREW_STATE_NO_FORGE=1 FM_FAKE_DIR="$dir/endpoint" \
    FM_FAKE_PANE_PATH="$worktree" PATH="$tools:$PATH" "$ROOT/bin/fm-crew-state.sh" worker)
  assert_contains "$out" 'state: working' 'real current generation is working'
  FM_FAKE_DIR="$dir/endpoint" FM_FAKE_PANE_PATH="$worktree" PATH="$tools:$PATH" fm_liveness_snapshot "$home"
  assert_equals '1:3' "$FM_LIVENESS_LIVE:$FM_LIVENESS_FREE" 'R1: new working incarnation must occupy a seat'
  assert_contains "$FM_LIVENESS_LANES" $'worker\tship\tworking\t' 'replacement lane reports native working state'
  assert_contains "$FM_LIVENESS_WARNINGS" 'prior incarnation' 'old handoff is visibly withdrawn'
  for state in paused unknown; do
    "$ROOT/bin/fm-busy-event.sh" apply "$home/state" worker idle --current-gen --source claude-hook --event stop >/dev/null
    if [ "$state" = paused ]; then printf 'paused: wait for external input\n' > "$home/state/worker.status"; else rm -f "$home/state/worker.busy-state"; fi
    FM_FAKE_DIR="$dir/endpoint" FM_FAKE_PANE_PATH="$worktree" PATH="$tools:$PATH" fm_liveness_snapshot "$home"
    assert_equals 1 "$FM_LIVENESS_LIVE" "replacement $state occupies its seat"
    assert_contains "$FM_LIVENESS_LANES" "$(printf 'worker\tship\t%s\t' "$state")" 'native lane state remains accurate'
  done
  "$ROOT/bin/fm-busy-event.sh" arm "$home/state" worker --state busy --source claude-hook --event user-prompt-submit >/dev/null
  FM_HOME="$home" "$ROOT/bin/fm-afk-contract.sh" propose --words 'continue authorized work' --spend 1 >/dev/null
  FM_HOME="$home" "$ROOT/bin/fm-afk-contract.sh" confirm >/dev/null
  fm_test_spawn_brief "$home" extra
  before=$(cksum "$home/state/worker.meta")
  contract=$(cksum "$home/state/.afk-contract"); stamp=$(cksum "$home/state/.last-launch")
  records=$(find "$home/state" -name '*.meta' -type f -exec cksum {} \; | sort)
  if out=$(FM_FAKE_DIR="$dir/endpoint" fm_test_run_spawn "$home" "$worktree" "$tools" extra "$project" --mode no-mistakes --yolo off); then fail 'R1: replacement admitted an extra worker at cap 1'; fi
  assert_contains "$out" 'caps concurrent workers at 1 and 1 ordinary task(s) are live' 'actual away cap denies the extra launch'
  assert_equals "$records" "$(find "$home/state" -name '*.meta' -type f -exec cksum {} \; | sort)" 'denial preserves task records'
  assert_equals "$contract" "$(cksum "$home/state/.afk-contract")" 'denial preserves away authority'
  assert_equals "$stamp" "$(cksum "$home/state/.last-launch")" 'denial preserves stamp'
  # Use the real handoff publisher, with forge reads confined to a fake CLI.
  out=$(FM_HOME="$home" HOME="$home/user-home" FM_GUARD_READ_ONLY=1 PATH="$tools:$PATH" \
    "$ROOT/bin/fm-pr-check.sh" worker "$pr" 2>&1) || fail "new handoff publication failed: $out"
  [ "$before" != "$(cksum "$home/state/worker.meta")" ] || fail 'new handoff did not republish metadata'
  PATH="$tools:$PATH" fm_liveness_snapshot "$home"
  assert_equals 0 "$FM_LIVENESS_LIVE" 'new valid ready handoff frees replacement capacity'
  extra_tools=$(fm_test_make_spawn_fakebin "$dir/extra-tools" no-mistakes)
  out=$(FM_FAKE_LAUNCH_LOG="$dir/extra-delivery" fm_test_run_spawn "$home" "$worktree" "$extra_tools" extra "$project" --mode no-mistakes --yolo off) \
    || fail "new handoff did not permit authorized within-cap launch: $out"
  [ -s "$dir/extra-delivery" ] && [ -f "$home/state/extra.meta" ] || fail 'allowed extra launch was not delivered and published'
  assert_equals "$contract" "$(cksum "$home/state/.afk-contract")" 'allowed launch preserves authority'
  FM_HOME="$home" "$ROOT/bin/fm-afk-contract.sh" archive >/dev/null
  out=$(FM_HOME="$home" HOME="$home/user-home" CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
    FM_FAKE_DIR="$dir/endpoint" FM_FAKE_PANE_PATH="$worktree" PATH="$tools:$PATH" \
    FM_CONTROL_POLL=0.1 FM_CONTROL_EXIT_WAIT=5 FM_CONTROL_LAUNCH_WAIT=5 \
    "$ROOT/bin/fm-control.sh" worker relaunch --note 'continue authorized work' 2>&1) || fail "operator relaunch failed: $out"
  fm_pr_metadata_identity_parse "$home/state/worker.meta" || fail 'operator relaunch must preserve valid association deliberately'
  "$ROOT/bin/fm-busy-event.sh" apply "$home/state" worker busy --current-gen --source claude-hook --event user-prompt-submit >/dev/null
  FM_FAKE_DIR="$dir/endpoint" FM_FAKE_PANE_PATH="$worktree" PATH="$tools:$PATH" fm_liveness_snapshot "$home"
  assert_equals 2 "$FM_LIVENESS_LIVE" 'operator replacement and extra worker occupy two seats'
  assert_contains "$FM_LIVENESS_WARNINGS" 'prior incarnation' 'operator path invalidates readiness at source'
  pass 'R1: primary and operator relaunch withdraw prior readiness, retain association, and enforce the away cap'
}

test_delayed_handoff_case() (
  # Each probe is a child of this shell. Every exit releases its external
  # response barrier and reaps it before the suite removes its fixture.
  local variant=$1 dir home project worktree tools pr head probe='' rc out old new
  local before polls records contract stamp extra_tools fields
  dir="$TMP_ROOT/delayed-$variant"; home="$dir/home"
  project="$dir/project"; worktree="$dir/worker"
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$project" "$worktree" delayed-worker
  fm_test_spawn_brief "$home" worker
  tools=$(liveness_relaunch_tools "$dir")
  trap ': > "$dir/endpoint/probe-release"; [ -z "$probe" ] || wait "$probe" || true' EXIT
  trap 'exit 1' HUP INT TERM
  cat > "$tools/gh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = pr ] && [ "${2:-}" = view ]; then
  if [ "${FM_FAKE_PROBE_HOLD:-0}" = 1 ]; then
    : > "$FM_FAKE_DIR/probe-entered"
    for ((i=0;i<300;i++)); do
      [ ! -f "$FM_FAKE_DIR/probe-release" ] || break
      sleep 0.1
    done
    [ -f "$FM_FAKE_DIR/probe-release" ] || exit 1
  fi
  printf '%s\n' "${FM_FAKE_HEAD:-0123456789abcdef0123456789abcdef01234567}"
  exit 0
fi
exit 1
SH
  chmod +x "$tools/gh"
  pr=https://github.com/example/project/pull/7
  head=0123456789abcdef0123456789abcdef01234567
  fields=spawn_gen=s1700000000.1.1
  case "$variant" in legacy-*) fields=fixture=legacy ;; esac
  fm_write_meta "$home/state/worker.meta" window=fmses:fm-worker endpoint_task_id=worker \
    "worktree=$worktree" "project=$project" harness=claude kind=ship mode=no-mistakes yolo=off \
    "tasktmp=$dir/tasktmp" model=default effort=default "$fields"
  # Establish real durable PR and poll artifacts before the delayed call.
  out=$(FM_HOME="$home" HOME="$home/user-home" FM_GUARD_READ_ONLY=1 PATH="$tools:$PATH" \
    "$ROOT/bin/fm-pr-check.sh" worker "$pr" 2>&1) || fail "initial handoff failed: $out"
  # shellcheck source=bin/fm-liveness-lib.sh
  . "$ROOT/bin/fm-liveness-lib.sh"
  old=$(fm_meta_get "$home/state/worker.meta" spawn_gen)
  FM_HOME="$home" HOME="$home/user-home" FM_GUARD_READ_ONLY=1 PATH="$tools:$PATH" \
    FM_FAKE_DIR="$dir/endpoint" FM_FAKE_PROBE_HOLD=1 \
    FM_FAKE_HEAD=89abcdef89abcdef89abcdef89abcdef89abcdef \
    "$ROOT/bin/fm-pr-check.sh" worker "$pr" > "$dir/probe.log" 2>&1 &
  probe=$!
  for ((i=0;i<200;i++)); do [ ! -f "$dir/endpoint/probe-entered" ] || break; sleep 0.1; done
  [ -f "$dir/endpoint/probe-entered" ] || fail 'delayed forge probe never entered'
  case "$variant" in
    replacement|legacy-replacement)
      out=$(FM_FAKE_DIR="$dir/endpoint" fm_test_run_spawn "$home" "$worktree" "$tools" worker --relaunch) \
        || fail "public replacement failed: $out"
      assert_equals claude "$(cat "$dir/endpoint/command")" 'replacement actually delivered'
      [ -s "$dir/endpoint/delivery" ] || fail 'replacement launch delivery absent'
      new=$(fm_meta_get "$home/state/worker.meta" spawn_gen)
      [ -n "$new" ] && [ "$new" != "$old" ] || fail 'replacement did not change incarnation'
      "$ROOT/bin/fm-busy-event.sh" apply "$home/state" worker busy --current-gen --source claude-hook --event user-prompt-submit >/dev/null
      FM_HOME="$home" "$ROOT/bin/fm-afk-contract.sh" propose --words 'continue authorized work' --spend 1 >/dev/null
      FM_HOME="$home" "$ROOT/bin/fm-afk-contract.sh" confirm >/dev/null
      ;;
    legacy-unchanged|unchanged) new=$old ;;
    removed|duplicate|malformed|empty)
      # Corrupt only fixture input, using the existing metadata lock owner.
      . "$ROOT/bin/fm-wake-lib.sh"
      local lock
      lock=$(fm_meta_lock_path "$home/state/worker.meta")
      fm_lock_acquire_wait "$lock"
      sed '/^spawn_gen=/d' "$home/state/worker.meta" > "$dir/meta"
      case "$variant" in
        duplicate) printf 'spawn_gen=%s\nspawn_gen=%s\n' "$old" "$old" >> "$dir/meta" ;;
        malformed) printf 'spawn_gen=broken\n' >> "$dir/meta" ;;
        empty) printf 'spawn_gen=\n' >> "$dir/meta" ;;
      esac
      chmod 0600 "$dir/meta"; mv "$dir/meta" "$home/state/worker.meta"
      fm_lock_release "$lock"
      new=$(fm_meta_get "$home/state/worker.meta" spawn_gen)
      ;;
  esac
  before=$(cksum "$home/state/worker.meta")
  polls=$(find "$home/state" -type f \( -name '*.pr-poll*' -o -name '*.check.sh' \) -exec cksum {} \; | sort)
  records=$(find "$home/state" -name '*.meta' -type f -exec cksum {} \; | sort)
  if [ "$variant" = replacement ] || [ "$variant" = legacy-replacement ]; then
    contract=$(cksum "$home/state/.afk-contract"); stamp=$(cksum "$home/state/.last-launch")
    out=$(FM_HOME="$home" FM_CREW_STATE_NO_FORGE=1 FM_FAKE_DIR="$dir/endpoint" FM_FAKE_PANE_PATH="$worktree" \
      PATH="$tools:$PATH" "$ROOT/bin/fm-crew-state.sh" worker)
    assert_contains "$out" 'state: working' 'current replacement works before old probe returns'
    FM_FAKE_DIR="$dir/endpoint" FM_FAKE_PANE_PATH="$worktree" PATH="$tools:$PATH" fm_liveness_snapshot "$home"
    assert_equals '1:3' "$FM_LIVENESS_LIVE:$FM_LIVENESS_FREE" 'replacement occupies seat before stale publication'
  fi
  printf 'R1race %s before: observed=%s current=%s ready=%s\n' "$variant" "${old:-ABSENT}" "${new:-ABSENT}" "$(fm_meta_get "$home/state/worker.meta" pr_spawn_gen)"
  : > "$dir/endpoint/probe-release"
  rc=0; wait "$probe" || rc=$?; probe=
  printf 'R1race %s probe rc=%s\n' "$variant" "$rc"
  cat "$dir/probe.log"
  if [ "$variant" = legacy-unchanged ] || [ "$variant" = unchanged ]; then
    assert_equals 0 "$rc" 'unchanged observed incarnation permits legitimate handoff'
    if [ "$variant" = legacy-unchanged ]; then
      assert_not_contains "$(cat "$home/state/worker.meta")" 'pr_spawn_gen=' 'legacy publication stays unbound'
    else
      assert_equals "$old" "$(fm_meta_get "$home/state/worker.meta" pr_spawn_gen)" 'unchanged handoff binds observed generation'
    fi
    assert_equals 89abcdef89abcdef89abcdef89abcdef89abcdef "$(fm_meta_get "$home/state/worker.meta" pr_head)" 'legitimate delayed result records its observed head'
    fm_pr_poll_artifacts_valid "$home/state" worker "$ROOT/bin/fm-pr-poll.sh" || fail 'unchanged poll association is invalid'
    PATH="$tools:$PATH" fm_liveness_snapshot "$home"
    assert_equals 0 "$FM_LIVENESS_LIVE" 'legitimate unchanged handoff releases seat'
  else
    [ "$rc" -ne 0 ] || fail "R1race: $variant stale or invalid invocation published readiness"
    assert_contains "$(cat "$dir/probe.log")" 'PR readiness refused' 'refusal names failed publication'
    assert_equals "$before" "$(cksum "$home/state/worker.meta")" 'stale denial preserves current record and association'
    assert_equals "$polls" "$(find "$home/state" -type f \( -name '*.pr-poll*' -o -name '*.check.sh' \) -exec cksum {} \; | sort)" 'stale denial preserves registered poll artifacts'
    [ -z "$(find "$home/state" -name '.fm-pr-*' -type f -print)" ] || fail 'stale denial leaked prepared artifacts'
  fi
  if [ "$variant" = replacement ] || [ "$variant" = legacy-replacement ]; then
    assert_contains "$(cat "$dir/probe.log")" 'changed incarnation' 'old observed generation refuses explicitly'
    assert_equals "$head" "$(fm_meta_get "$home/state/worker.meta" pr_head)" 'old probe cannot replace durable head'
    FM_FAKE_DIR="$dir/endpoint" FM_FAKE_PANE_PATH="$worktree" PATH="$tools:$PATH" fm_liveness_snapshot "$home"
    assert_equals '1:3' "$FM_LIVENESS_LIVE:$FM_LIVENESS_FREE" 'stale denial retains current working seat'
    assert_contains "$FM_LIVENESS_LANES" $'worker\tship\tworking\t' 'current worker remains working'
    assert_contains "$FM_LIVENESS_WARNINGS" 'prior incarnation' 'prior ready binding stays visible'
    fm_test_spawn_brief "$home" extra
    extra_tools=$(fm_test_make_spawn_fakebin "$dir/extra-tools" no-mistakes)
    if out=$(FM_FAKE_DIR="$dir/endpoint" FM_FAKE_PANE_PATH="$worktree" \
      FM_FAKE_LAUNCH_LOG="$dir/extra-delivery" fm_test_run_spawn "$home" "$worktree" "$extra_tools" extra "$project" --mode no-mistakes --yolo off); then
      fail 'stale denial admitted extra worker at cap 1'
    fi
    assert_contains "$out" 'caps concurrent workers at 1 and 1 ordinary task(s) are live' 'actual public cap refuses extra worker'
    assert_equals "$records" "$(find "$home/state" -name '*.meta' -type f -exec cksum {} \; | sort)" 'cap denial preserves current tasks'
    assert_equals "$contract" "$(cksum "$home/state/.afk-contract")" 'stale/cap denial preserves authority'
    assert_equals "$stamp" "$(cksum "$home/state/.last-launch")" 'stale/cap denial preserves stamp'
    [ ! -s "$dir/extra-delivery" ] && [ ! -e "$home/state/extra.meta" ] || fail 'denied extra worker delivered'
    out=$(FM_HOME="$home" HOME="$home/user-home" FM_GUARD_READ_ONLY=1 PATH="$tools:$PATH" \
      "$ROOT/bin/fm-pr-check.sh" worker "$pr" 2>&1) || fail "fresh current handoff refused: $out"
    assert_equals "$new" "$(fm_meta_get "$home/state/worker.meta" pr_spawn_gen)" 'fresh handoff binds actual new incarnation'
    fm_pr_poll_artifacts_valid "$home/state" worker "$ROOT/bin/fm-pr-poll.sh" || fail 'fresh poll association invalid'
    PATH="$tools:$PATH" fm_liveness_snapshot "$home"
    assert_equals '0:4' "$FM_LIVENESS_LIVE:$FM_LIVENESS_FREE" 'fresh current handoff releases seat'
    out=$(FM_FAKE_LAUNCH_LOG="$dir/extra-delivery" fm_test_run_spawn "$home" "$worktree" "$extra_tools" extra "$project" --mode no-mistakes --yolo off) \
      || fail "fresh handoff failed authorized cap allowance: $out"
    [ -s "$dir/extra-delivery" ] && [ -f "$home/state/extra.meta" ] || fail 'fresh allowed worker absent'
    assert_equals "$contract" "$(cksum "$home/state/.afk-contract")" 'fresh allowed launch preserves authority'
    printf 'R1race %s: stale live=1 cap denied; fresh live=0 cap allowed\n' "$variant"
  fi
)

test_delayed_handoff_refuses_replacement() {
  local variant home tools out before
  for variant in replacement legacy-replacement legacy-unchanged unchanged removed duplicate malformed empty; do
    test_delayed_handoff_case "$variant"
  done
  # Invalid initial observations must refuse before reaching the external probe.
  home="$TMP_ROOT/invalid-initial/home"
  fm_test_spawn_home "$home"
  mkdir -p "$home/worker"
  tools=$(fm_test_make_spawn_fakebin "$TMP_ROOT/invalid-initial/tools" gh)
  cat > "$tools/gh" <<'SH'
#!/usr/bin/env bash
: > "$FM_FAKE_PROBE_ENTERED"
printf '0123456789abcdef0123456789abcdef01234567\n'
SH
  chmod +x "$tools/gh"
  for variant in 'spawn_gen=broken' 'spawn_gen=' 'spawn_gen=s0.1.1' 'spawn_gen=s1700000000.1.1\nspawn_gen=s1700000000.1.1'; do
    printf 'kind=ship\nworktree=%s\n%b\n' "$home/worker" "$variant" > "$home/state/worker.meta"
    before=$(cksum "$home/state/worker.meta")
    if out=$(FM_HOME="$home" HOME="$home/user-home" FM_GUARD_READ_ONLY=1 PATH="$tools:$PATH" \
      FM_FAKE_PROBE_ENTERED="$home/probe-entered" "$ROOT/bin/fm-pr-check.sh" worker https://github.com/example/project/pull/7 2>&1); then
      fail 'invalid initial generation published readiness'
    fi
    assert_contains "$out" 'PR readiness refused' 'invalid initial generation diagnoses publication refusal'
    [ ! -e "$home/probe-entered" ] || fail 'invalid initial generation reached slow forge probe'
    assert_equals "$before" "$(cksum "$home/state/worker.meta")" 'invalid initial generation preserves record'
    [ ! -e "$home/state/worker.check.sh" ] || fail 'invalid initial generation published poll'
  done
  pass 'R1race: delayed predecessor and invalid generations refuse; unchanged legacy and fresh current handoffs release capacity'
}

test_native_muse_snapshot_never_writes_home() {
  local dir home tools worktree sessions log variant before cache verdict other
  dir="$TMP_ROOT/muse"; home="$dir/home"; worktree="$dir/worker"; sessions="$dir/sessions"
  fm_test_spawn_home "$home"
  mkdir -p "$worktree"
  tools=$(fm_test_make_spawn_fakebin "$dir/tools" no-mistakes)
  fm_write_meta "$home/state/worker.meta" kind=ship mode=direct-PR harness=muse window=fm-worker "worktree=$worktree"
  log="$sessions/$(date +%Y/%m/%d)/native-session/session.jsonl"
  mkdir -p "${log%/*}"
  printf '{"schema_version":1,"payload_type":"runtime.session.metadata","payload":{"kind":"metadata","record":{"workspace_root":"%s"}}}\n' "$worktree" > "$log"
  printf '{"schema_version":1,"payload_type":"runtime.session","payload":{"kind":"run","run_id":"native-run","event":{"kind":"started"}}}\n' >> "$log"
  printf 'sessions_root=%s\nworkspace_root=%s\nbinding_id=fixture-incarnation\n' "$sessions" "$worktree" > "$home/state/worker.muse-session"
  cache="$home/state/worker.muse-session-current"
  . "$ROOT/bin/fm-liveness-lib.sh"
  . "$ROOT/bin/fm-busy-lib.sh"
  for variant in missing stale valid; do
    case "$variant" in
      missing) rm -f "$cache" ;;
      stale) printf 'binding_id=old-incarnation\nsession_log=untrusted\n' > "$cache" ;;
      valid)
        # Direct cache-owner default behavior remains available to its callers.
        verdict=$(FM_BUSY_CACHE_READ_ONLY=0 fm_busy_muse_session_log "$home/state" worker) || fail 'default cache-owner discovery failed'
        assert_equals "$log" "$verdict" 'default cache owner selects the native owned log'
        [ -f "$cache" ] || fail 'default cache owner did not publish its cache' ;;
    esac
    before=$(find "$home" -exec ls -ld {} \; -type f -exec cksum {} \; | sort)
    PATH="$tools:$PATH" fm_liveness_snapshot "$home"
    assert_equals 1 "$FM_LIVENESS_LIVE" "native Muse $variant cache reports working capacity"
    assert_contains "$FM_LIVENESS_LANES" $'worker\tship\tworking\t' 'real native run lifecycle is used'
    assert_equals "$before" "$(find "$home" -exec ls -ld {} \; -type f -exec cksum {} \; | sort)" "R2: $variant cache snapshot preserves every home path and byte"
    verdict=$(FM_HOME="$home" PATH="$tools:$PATH" "$ROOT/bin/fm-crew-state.sh" worker)
    assert_contains "$verdict" 'state: working' 'public current-state also observes without cache writes'
    assert_equals "$before" "$(find "$home" -exec ls -ld {} \; -type f -exec cksum {} \; | sort)" 'current-state preserves home bytes'
  done
  # New matching logs make even a formerly valid cache ambiguous.
  other="${log%/*}/../other/session.jsonl"; mkdir -p "${other%/*}"; cp "$log" "$other"
  for variant in ambiguous foreign malformed prior missing; do
    case "$variant" in
      foreign) rm "$other"; sed "s|$worktree|$dir/foreign|" "$log" > "$dir/foreign-log"; cp "$dir/foreign-log" "$log" ;;
      malformed) printf 'not native JSON\n' > "$log" ;;
      prior)
        printf '{"payload":{"record":{"workspace_root":"%s"}}}\n' "$worktree" > "$log"
        printf 'prior_log=%s\n' "$log" >> "$home/state/worker.muse-session" ;;
      missing) rm "$log" ;;
    esac
    before=$(find "$home" -exec ls -ld {} \; -type f -exec cksum {} \; | sort)
    PATH="$tools:$PATH" fm_liveness_snapshot "$home"
    assert_equals 1 "$FM_LIVENESS_LIVE" "untrusted $variant native inputs retain capacity"
    assert_contains "$FM_LIVENESS_WARNINGS" 'current state unknown; seat retained' 'native observation failure is visible'
    assert_equals "$before" "$(find "$home" -exec ls -ld {} \; -type f -exec cksum {} \; | sort)" 'failed observation preserves home bytes and stale cache'
  done
  pass 'R2: native Muse cache miss, stale, valid and failed reads preserve the operational home'
}

test_postlaunch_stamp_failure_reports_confirmed_work() {
  local finding=$1 dir home project worktree tools variant variants out rc contract real_mktemp real_perl real_date stamp destination_before
  real_mktemp=$(command -v mktemp); real_perl=$(command -v perl); real_date=$(command -v date)
  export FM_STAMP_REAL_MKTEMP="$real_mktemp" FM_STAMP_REAL_PERL="$real_perl" FM_STAMP_REAL_DATE="$real_date"
  dir="$TMP_ROOT/stamp-$finding"; project="$dir/project"; worktree="$dir/worker"
  fm_git_worktree "$project" "$worktree" stamp-worker
  if [ "$finding" = R3 ]; then variants='directory symlink-directory symlink-file fifo rename race normal'; else variants='mktemp date write invalid-epoch'; fi
  for variant in $variants; do
    home="$dir/$variant/home"
    fm_test_spawn_home "$home" codex
    fm_test_spawn_brief "$home" worker
    tools=$(fm_test_make_spawn_fakebin "$dir/$variant/tools" no-mistakes)
    mv "$tools/tmux" "$tools/tmux-subject"
    cat > "$tools/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_STAMP_ENDPOINT_LOG"
exec "$(dirname "$0")/tmux-subject" "$@"
SH
    chmod +x "$tools/tmux"
    printf 'backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n' > "$home/.tasks.toml"
    printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
    TASKS_AXI_BACKEND=markdown tasks-axi add worker 'stamp behavior' --kind ship --file "$home/data/backlog.md" >/dev/null
    FM_HOME="$home" "$ROOT/bin/fm-afk-contract.sh" propose --words 'continue authorized work' --spend 1 >/dev/null
    FM_HOME="$home" "$ROOT/bin/fm-afk-contract.sh" confirm >/dev/null
    contract=$(cksum "$home/state/.afk-contract")
    stamp="$home/state/.last-launch"
    case "$variant" in
      directory) mkdir "$stamp" ;;
      symlink-directory) mkdir "$home/destination"; ln -s "$home/destination" "$stamp" ;;
      symlink-file) printf '1234567890\n' > "$home/destination"; ln -s "$home/destination" "$stamp" ;;
      fifo) mkfifo "$stamp" ;;
      rename|date|write|invalid-epoch) printf '1234567890\n' > "$stamp" ;;
    esac
    destination_before=
    [ ! -f "$home/destination" ] || destination_before=$(cksum "$home/destination")
    if [ "$variant" = mktemp ] || [ "$variant" = write ]; then
      cat > "$tools/mktemp" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  */.last-launch.XXXXXX)
    if [ "$FM_STAMP_FAULT" = mktemp ]; then echo 'fixture: stamp mktemp refused' >&2; exit 1; fi
    # A directory returned at the source path forces the epoch write to fail.
    path="$FM_HOME/state/.last-launch.source-directory"; mkdir "$path"; echo "$path"; exit 0 ;;
esac
exec "$FM_STAMP_REAL_MKTEMP" "$@"
SH
      chmod +x "$tools/mktemp"
    fi
    if [ "$variant" = date ] || [ "$variant" = invalid-epoch ]; then
      cat > "$tools/date" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = +%s ] && [ -f "$FM_HOME/state/worker.meta" ]; then
  if [ "$FM_STAMP_FAULT" = date ]; then echo 'fixture: stamp date refused' >&2; exit 1; fi
  printf '0\n'; exit 0
fi
exec "$FM_STAMP_REAL_DATE" "$@"
SH
      chmod +x "$tools/date"
    fi
    if [ "$variant" = rename ] || [ "$variant" = race ]; then
      cat > "$tools/perl" <<'SH'
#!/usr/bin/env bash
case "${*: -1}" in
  */.last-launch)
    if [ "$FM_STAMP_FAULT" = rename ]; then echo 'fixture: stamp exact rename refused' >&2; exit 1; fi
    exec "$FM_STAMP_REAL_PERL" -I "$(dirname "$0")" -MStampRace "$@" ;;
esac
exec "$FM_STAMP_REAL_PERL" "$@"
SH
      # Inject only at rename(2), after the production destination check.
      cat > "$tools/StampRace.pm" <<'PERL'
package StampRace;
BEGIN {
  *CORE::GLOBAL::rename = sub {
    my ($source, $destination) = @_;
    mkdir($destination) or die "fixture: directory race failed: $!";
    open my $receipt, '>', "$ENV{FM_HOME}/rename-race" or die $!;
    print {$receipt} "destination replaced immediately before rename\n";
    close $receipt;
    return CORE::rename($source, $destination);
  };
}
1;
PERL
      chmod +x "$tools/perl"
    fi
    if out=$(FM_STAMP_FAULT="$variant" FM_STAMP_ENDPOINT_LOG="$dir/$variant/endpoint-log" FM_FAKE_LAUNCH_LOG="$dir/$variant/delivery" \
      fm_test_run_spawn "$home" "$worktree" "$tools" worker "$project" --mode no-mistakes --yolo off); then rc=0; else rc=$?; fi
    [ -f "$home/state/worker.meta" ] && [ -s "$dir/$variant/delivery" ] || fail "$variant did not reach confirmed publication and delivery"
    assert_contains "$(TASKS_AXI_BACKEND=markdown tasks-axi show worker --file "$home/data/backlog.md")" 'state: in_flight' 'confirmed worker stays owned by the real backlog'
    assert_not_contains "$(cat "$dir/$variant/endpoint-log")" 'kill-window' 'postlaunch failure must never kill confirmed work'
    if [ -f "$home/data/done-archive.md" ]; then
      assert_not_contains "$(cat "$home/data/done-archive.md")" 'worker' 'confirmed worker must never be archived'
    fi
    assert_equals "$contract" "$(cksum "$home/state/.afk-contract")" 'postlaunch bookkeeping preserves away authority'
    if [ "$variant" = normal ]; then
      assert_equals 0 "$rc" 'ordinary launch succeeds'
      [ -f "$stamp" ] && [ ! -L "$stamp" ] || fail 'stamp is not an ordinary exact-path file'
      perl -e 'local $/; open my $f,"<",$ARGV[0] or die; my $v=<$f>; $v =~ /\A[1-9][0-9]*\n\z/ or die "bad epoch"' "$stamp" || fail 'stamp must be one positive epoch and newline'
    else
      assert_equals 1 "$rc" "$finding: $variant stamp failure returns an error after preserving launch"
      assert_contains "$out" 'task worker launched, but state/.last-launch could not be published; task record preserved' "$finding: $variant names confirmed work truthfully"
      assert_not_contains "$out" 'spawned worker' 'failed bookkeeping cannot report normal success'
      case "$variant" in
        directory|race)
          [ -d "$stamp" ] && [ -z "$(ls -A "$stamp")" ] || fail 'exact rename must never move the temporary stamp into a directory'
          [ "$variant" != race ] || [ -f "$home/rename-race" ] || fail 'test did not reach the production rename boundary' ;;
        symlink-directory|symlink-file)
          [ -L "$stamp" ] || fail 'unsafe symlink was replaced'
          [ -z "$(find "$home/destination" -name '.last-launch.*')" ] || fail 'publication followed the symlink'
          [ -z "$destination_before" ] || assert_equals "$destination_before" "$(cksum "$home/destination")" 'unsafe destination bytes remain unchanged' ;;
        fifo) [ -p "$stamp" ] || fail 'unsafe FIFO was replaced' ;;
        mktemp) [ ! -e "$stamp" ] || fail 'failed temporary creation left a stamp' ;;
        *) assert_equals 1234567890 "$(cat "$stamp")" 'failed replacement retains the prior epoch' ;;
      esac
    fi
  done
  pass "$finding: exact-path stamp publication and every postlaunch failure preserve confirmed work"
}

case "${1:-all}" in
  R1) test_relaunch_withdraws_previous_ready_handoff; exit ;;
  R1race)
    case "${2:-all}" in
      all) test_delayed_handoff_refuses_replacement ;;
      replacement|legacy-replacement|legacy-unchanged|unchanged|removed|duplicate|malformed|empty) test_delayed_handoff_case "$2" ;;
      *) fail 'invalid R1race case' ;;
    esac
    exit ;;
  R2) test_native_muse_snapshot_never_writes_home; exit ;;
  R3|R4) test_postlaunch_stamp_failure_reports_confirmed_work "$1"; exit ;;
  all) test_relaunch_withdraws_previous_ready_handoff; test_delayed_handoff_refuses_replacement; test_native_muse_snapshot_never_writes_home
    test_postlaunch_stamp_failure_reports_confirmed_work R3; test_postlaunch_stamp_failure_reports_confirmed_work R4 ;;
  *) fail 'usage: fm-liveness-lib.test.sh [R1|R1race|R2|R3|R4]' ;;
esac

fixture="$TMP_ROOT/code"
home="$TMP_ROOT/home"
mkdir -p "$fixture/bin" "$home/state" "$home/config"
for file in "$ROOT/bin"/*; do ln -s "$file" "$fixture/bin/${file##*/}"; done
rm "$fixture/bin/fm-crew-state.sh"
cat > "$fixture/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FM_HOME/reads"
case "$(cat "$FM_STATE_OVERRIDE/$1.current")" in
  timeout) sleep 30 ;;
  error) exit 1 ;;
  malformed) printf 'unreadable response\n' ;;
  *) printf 'state: %s · source: run-step · fixture\n' "$(cat "$FM_STATE_OVERRIDE/$1.current")" ;;
esac
SH
chmod +x "$fixture/bin/fm-crew-state.sh"
# shellcheck source=/dev/null
. "$fixture/bin/fm-liveness-lib.sh"

fm_liveness_snapshot "$home"
assert_equals '4:0:4:0' "$FM_LIVENESS_TARGET:$FM_LIVENESS_LIVE:$FM_LIVENESS_FREE:$FM_LIVENESS_OVER_TARGET" 'primary default seats'
: > "$home/.fm-secondmate-home"
fm_liveness_snapshot "$home"
assert_equals 6 "$FM_LIVENESS_TARGET" 'secondmate default'
rm "$home/.fm-secondmate-home"

printf '6\n' > "$home/config/worker-target"
stamp=$(($(date +%s) - 120))
for id in pause-a pause-b pause-c active; do
  fm_write_meta "$home/state/$id.meta" kind=ship "spawn_gen=s$stamp.1.1"
  printf 'paused\n' > "$home/state/$id.current"
  printf 'done: stale event\n' > "$home/state/$id.status"
done
printf 'working\n' > "$home/state/active.current"
fm_write_meta "$home/state/ready.meta" kind=ship pr=https://github.com/example/project/pull/1 \
  pr_head=0123456789abcdef0123456789abcdef01234567 x_request=fixture
fm_write_meta "$home/state/mate.meta" kind=secondmate
fm_write_meta "$home/state/finished.meta" kind=scout
printf 'done\n' > "$home/state/finished.current"
fm_write_meta "$home/state/failed.meta" kind=ship
printf 'failed\n' > "$home/state/failed.current"
fm_liveness_snapshot "$home"
assert_equals '6:4:2:0' "$FM_LIVENESS_TARGET:$FM_LIVENESS_LIVE:$FM_LIVENESS_FREE:$FM_LIVENESS_OVER_TARGET" 'three paused and one working lane occupy four seats'
assert_equals 3 "$(printf '%s' "$FM_LIVENESS_LANES" | awk -F '\t' '$3 == "paused" && $4 >= 120 && $4 < 150 { n++ } END { print n+0 }')" 'paused lanes retain measured ages'
assert_not_contains "$(cat "$home/reads")" ready 'ready PR must bypass crew-state'
assert_not_contains "$(cat "$home/reads")" mate 'parent must not probe secondmate'
pass 'AE8: current-state seats include paused lanes and release terminal and ready-PR lanes'

rm "$home/state/pause-c.meta"
printf '2\n' > "$home/config/worker-target"
fm_liveness_snapshot "$home"
assert_equals '3:0:1' "$FM_LIVENESS_LIVE:$FM_LIVENESS_FREE:$FM_LIVENESS_OVER_TARGET" 'over-target seats clamp to zero'
fm_write_meta "$home/state/active.meta" kind=scout "spawn_gen=s$stamp.1.2"
fm_liveness_snapshot "$home"
assert_contains "$FM_LIVENESS_LANES" $'active\tscout\tworking\t' 'scouts occupy seats and are listed'
pass 'scouts and over-target homes use the same count'

invalid_home="$TMP_ROOT/invalid-pr-home"
mkdir -p "$invalid_home/state" "$invalid_home/config"
# A lower-level terminal verdict must not launder an invalid ready handoff.
printf 'done\n' > "$invalid_home/state/worker.current"
for fields in \
  'pr=not-a-url' \
  'pr=https://example.invalid/repo/pull/1' \
  'pr=https://github.com/example/project/pull/1\npr=https://github.com/example/project/pull/1' \
  'pr=\npr=https://github.com/example/project/pull/1' \
  'pr=https://github.com/example/project/pull/1\npr=not-a-url' \
  'pr=https://github.com/example/project/pull/1\npr_head=invalid' \
  'pr=https://github.com/example/project/pull/1\nkind=ship'; do
  printf 'kind=ship\n%b\n' "$fields" > "$invalid_home/state/worker.meta"
  fm_liveness_snapshot "$invalid_home"
  assert_equals '1:3:0' "$FM_LIVENESS_LIVE:$FM_LIVENESS_FREE:$FM_LIVENESS_OVER_TARGET" 'invalid or duplicate PR data must retain capacity'
  assert_contains "$FM_LIVENESS_WARNINGS" "$invalid_home/state/worker.meta" 'invalid PR warning names the repair path'
  assert_contains "$FM_LIVENESS_WARNINGS" 'invalid PR metadata; seat retained' 'invalid PR warning explains retained seat'
  assert_contains "$FM_LIVENESS_LANES" $'worker\tship\tunknown\t' 'untrusted PR completion stays uncertain'
done
fm_write_meta "$invalid_home/state/worker.meta" kind=ship
for current in working paused unknown 'done' failed; do
  printf '%s\n' "$current" > "$invalid_home/state/worker.current"
  fm_liveness_snapshot "$invalid_home"
  case "$current" in done|failed) expected=0 ;; *) expected=1 ;; esac
  assert_equals "$expected" "$FM_LIVENESS_LIVE" 'no-PR worker follows current terminal state'
done
pass 'invalid ready metadata retains seats despite lower-level completion; ordinary terminal states still release them'

for value in '' '0\n' '01\n' '2' '2\n\n' '2 3\n' '-1\n' '2\r\n' '99999999999999999999\n'; do
  printf '%b' "$value" > "$home/config/worker-target"
  if fm_liveness_snapshot "$home"; then fail "malformed target accepted: $value"; fi
  assert_contains "$FM_LIVENESS_ERROR" "$home/config/worker-target" 'config error names the repair path'
done
rm "$home/config/worker-target"
ln -s "$home/missing" "$home/config/worker-target"
if fm_liveness_snapshot "$home"; then fail 'dangling target link defaulted'; fi
rm "$home/config/worker-target"
pass 'malformed and unsafe targets are actionable errors'

bad_state="$TMP_ROOT/bad-state"
ln -s "$TMP_ROOT/missing-state" "$bad_state"
if fm_liveness_snapshot "$home" "$bad_state"; then fail 'dangling state directory released all seats'; fi
assert_contains "$FM_LIVENESS_ERROR" "$bad_state" 'invalid state directory names its repair path'
rm "$bad_state"
printf 'not a directory\n' > "$bad_state"
if fm_liveness_snapshot "$home" "$bad_state"; then fail 'ordinary state file released all seats'; fi
pass 'unreadable state roots cannot masquerade as an empty home'


mate="$TMP_ROOT/mate"
mkdir -p "$mate/config" "$mate/state"
: > "$mate/.fm-secondmate-home"
fm_write_meta "$mate/state/own.meta" kind=scout
printf 'paused\n' > "$mate/state/own.current"
fm_liveness_snapshot "$mate"
assert_equals '6:1:5' "$FM_LIVENESS_TARGET:$FM_LIVENESS_LIVE:$FM_LIVENESS_FREE" 'secondmate counts only its own workers'
printf '2\n' > "$home/config/worker-target"
printf '7\n' > "$mate/config/worker-target"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-config-inherit-lib.sh"
propagate_inheritable_config "$home/config" "$mate/config"
fm_liveness_snapshot "$mate"
assert_equals 7 "$FM_LIVENESS_TARGET" 'inherited config preserves local target'
rm "$mate/config/worker-target"
propagate_inheritable_config "$home/config" "$mate/config"
fm_liveness_snapshot "$mate"
assert_equals 6 "$FM_LIVENESS_TARGET" 'parent target is never inherited into an absent local setting'
pass 'secondmate targets and worker records remain home-local'

for value in malformed error timeout; do
  printf '%s\n' "$value" > "$mate/state/own.current"
  fm_liveness_snapshot "$mate"
  assert_equals 1 "$FM_LIVENESS_LIVE" 'uncertain state must retain its seat'
  assert_contains "$FM_LIVENESS_WARNINGS" 'own: current state unknown; seat retained' 'uncertainty is visible'
done
pass 'failed, malformed, and ten-second-bounded reads retain seats visibly'

# Exercise the real spawn interface with the shared isolated-worktree fixture.
launch_home="$TMP_ROOT/launch-home"
project="$TMP_ROOT/project"
worktree="$TMP_ROOT/worker"
fm_test_spawn_home "$launch_home" codex
fm_git_worktree "$project" "$worktree" fixture-worker
fm_test_spawn_brief "$launch_home" task-launch
fakebin=$(fm_test_make_spawn_fakebin "$TMP_ROOT/launch-tools")
before=$(date +%s)
out=$(fm_test_run_spawn "$launch_home" "$worktree" "$fakebin" task-launch "$project" --mode no-mistakes --yolo off) || fail "spawn failed: $out"
after=$(date +%s)
last=$(cat "$launch_home/state/.last-launch")
[ "$last" -ge "$before" ] && [ "$last" -le "$after" ] || fail 'confirmed launch stamp is not current'
[ -f "$launch_home/state/task-launch.meta" ] || fail 'launch stamp lacks published task'
if out=$(fm_test_run_spawn "$launch_home" "$worktree" "$fakebin" task-invalid "$project" --mode no-mistakes --yolo off); then
  fail 'spawn without a brief unexpectedly succeeded'
fi
assert_equals "$last" "$(cat "$launch_home/state/.last-launch")" 'refused spawn must not advance stamp'
pass 'only a confirmed worker launch publishes the durable last-launch stamp'

# A backend refusal must not stamp an attempted launch or change owned records.
fm_test_spawn_brief "$launch_home" task-failure
FM_HOME="$launch_home" "$ROOT/bin/fm-afk-contract.sh" propose --words 'continue authorized work' --spend 4 >/dev/null
FM_HOME="$launch_home" "$ROOT/bin/fm-afk-contract.sh" confirm >/dev/null
contract=$(cat "$launch_home/state/.afk-contract")
records=$(find "$launch_home/state" -name '*.meta' -type f -exec cksum {} \; | sort)
cp "$fakebin/tmux" "$fakebin/tmux-ok"
cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = new-window ]; then
  printf 'fixture endpoint creation refused\n' >&2
  exit 1
fi
exec "$(dirname "$0")/tmux-ok" "$@"
SH
chmod +x "$fakebin/tmux"
if out=$(fm_test_run_spawn "$launch_home" "$worktree" "$fakebin" task-failure "$project" --mode no-mistakes --yolo off); then
  fail 'backend refusal unexpectedly launched a worker'
fi
assert_contains "$out" 'fixture endpoint creation refused' 'failure must reach the backend boundary'
assert_equals "$records" "$(find "$launch_home/state" -name '*.meta' -type f -exec cksum {} \; | sort)" 'failed launch preserves all worker records'
assert_equals "$last" "$(cat "$launch_home/state/.last-launch")" 'failed launch preserves stamp'
assert_equals "$contract" "$(cat "$launch_home/state/.afk-contract")" 'failed launch preserves away contract'
pass 'backend failure changes no worker records, launch stamp, or away authority'

# Exercise native current-state and canonical PR identity consumers together.
# The earlier fake reader owns malformed response and timeout fault injection.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-liveness-lib.sh"
native_home="$TMP_ROOT/native-home"
mkdir -p "$native_home/state" "$native_home/config"
native_tools=$(fm_test_make_spawn_fakebin "$TMP_ROOT/native-tools")
for id in active paused 'done' failed ready duplicate; do
  fm_write_meta "$native_home/state/$id.meta" kind=ship mode=direct-PR "worktree=$worktree" \
    backend=tmux "window=fm-$id" harness=claude
  printf '%s: native fixture\n' "$id" > "$native_home/state/$id.status"
  busy=idle
  [ "$id" != active ] || busy=busy
  "$ROOT/bin/fm-busy-event.sh" arm "$native_home/state" "$id" --state "$busy" --source claude-hook --event stop >/dev/null
  case "$id" in
    ready) printf 'pr=https://github.com/example/project/pull/1\n' >> "$native_home/state/$id.meta" ;;
    duplicate) printf 'pr=https://github.com/example/project/pull/1\npr=https://github.com/example/project/pull/1\n' >> "$native_home/state/$id.meta" ;;
  esac
done
printf 'done: stale event\n' > "$native_home/state/active.status"
printf 'done: recorded PR\n' > "$native_home/state/duplicate.status"
fm_write_meta "$native_home/state/mate.meta" kind=secondmate
printf 'working: orphan event\n' > "$native_home/state/orphan.status"
before=$(find "$native_home" -type f -exec cksum {} \; | sort)
PATH="$native_tools:$PATH" fm_liveness_snapshot "$native_home"
assert_equals '4:3:1:0' "$FM_LIVENESS_TARGET:$FM_LIVENESS_LIVE:$FM_LIVENESS_FREE:$FM_LIVENESS_OVER_TARGET" 'native worker accounting excludes terminal workers, handoffs, secondmates, and status-only events'
assert_contains "$FM_LIVENESS_LANES" $'active\tship\tworking\t' 'native busy worker outranks stale done event'
assert_contains "$FM_LIVENESS_LANES" $'paused\tship\tpaused\t' 'native paused worker retains its seat'
assert_contains "$FM_LIVENESS_LANES" $'duplicate\tship\tunknown\t' 'duplicate PR retains its seat through native consumers'
assert_equals "$before" "$(find "$native_home" -type f -exec cksum {} \; | sort)" 'capacity observation is read-only'
pass 'native crew-state and canonical identity parser prove shared read-only accounting'
