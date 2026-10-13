#!/usr/bin/env bash
# Public seat-snapshot, config propagation, and confirmed-launch behavior.
set -eu
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-liveness)
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
