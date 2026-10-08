#!/usr/bin/env bash
# Activity wakes from the static pull-request poll: one new group, one line,
# seeded cursors, and silent failures.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"

POLL="$ROOT/bin/fm-pr-poll.sh"
WATCH="$ROOT/bin/fm-watch.sh"
URL=https://github.com/o/r/pull/1
TMP_ROOT=$(fm_test_tmproot fm-pr-poll-activity)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
REAL_JQ=$(command -v jq) || fail "these tests run gh's query with the real jq, which was not found"

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1"
  else
    stat -c %a "$1"
  fi
}

make_case() {
  local name=$1 dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/home/config" "$dir/fakebin" "$dir/wt" "$dir/outside"
  ln -sf "$REAL_JQ" "$dir/fakebin/jq"
  cat > "$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -o pipefail
printf '%s\n' "$*" >> "${FM_TEST_GH_LOG:-/dev/null}"
if [ "${FM_TEST_GH_FAIL:-0}" = 1 ]; then
  exit 1
fi
if [ "${FM_TEST_GH_TRUNCATED:-0}" = 1 ]; then
  printf '%s\n' 'state=OPEN'
  printf '%s\n' 'comment	broken'
  exit 0
fi
[ -n "${FM_TEST_GH_JSON_FILE:-}" ] && [ -f "$FM_TEST_GH_JSON_FILE" ] || exit 2
prog=
prev=
for arg in "$@"; do
  [ "$prev" != --jq ] || prog=$arg
  prev=$arg
done
[ -n "$prog" ] || exit 2
jq -r "$prog" "$FM_TEST_GH_JSON_FILE"
SH
  chmod +x "$dir/fakebin/gh"
  cp "$POLL" "$dir/home/state/task-a.check.sh"
  printf '%s\n' github "$URL" github.com o/r 1 > "$dir/home/state/task-a.pr-poll"
  chmod 0600 "$dir/home/state/task-a.check.sh" "$dir/home/state/task-a.pr-poll"
  printf '%s\n' "$dir"
}

write_json() {
  local file=$1 state=$2 comments=${3:-[]} reviews=${4:-[]}
  jq -n --arg state "$state" --argjson comments "$comments" --argjson reviews "$reviews" \
    '{state:$state, comments:$comments, reviews:$reviews}' > "$file"
}

run_direct() {
  local dir=$1
  FM_TEST_GH_JSON_FILE="$dir/pr.json" FM_TEST_GH_LOG="$dir/gh.log" \
    FM_TEST_GH_FAIL="${FM_TEST_GH_FAIL:-0}" \
    FM_TEST_GH_TRUNCATED="${FM_TEST_GH_TRUNCATED:-0}" \
    PATH="$dir/fakebin:$BASE_PATH" \
    bash "$dir/home/state/task-a.check.sh"
}

run_validated() {
  local dir=$1 check=${2:-}
  if [ -n "$check" ]; then
    FM_TEST_GH_JSON_FILE="$dir/pr.json" FM_TEST_GH_LOG="$dir/gh.log" \
      FM_TEST_GH_FAIL="${FM_TEST_GH_FAIL:-0}" \
      FM_TEST_GH_TRUNCATED="${FM_TEST_GH_TRUNCATED:-0}" \
      PATH="$dir/fakebin:$BASE_PATH" \
      bash "$POLL" --validated github "$URL" github.com o/r 1 "$check"
  else
    FM_TEST_GH_JSON_FILE="$dir/pr.json" FM_TEST_GH_LOG="$dir/gh.log" \
      FM_TEST_GH_FAIL="${FM_TEST_GH_FAIL:-0}" \
      FM_TEST_GH_TRUNCATED="${FM_TEST_GH_TRUNCATED:-0}" \
      PATH="$dir/fakebin:$BASE_PATH" \
      bash "$POLL" --validated github "$URL" github.com o/r 1
  fi
}

assert_silent() {
  local out=$1 why=$2
  [ -z "$out" ] || fail "$why"
}

assert_one_line() {
  local out=$1 expected=$2
  case "$out" in
    *$'\n'*) fail "activity wake was not one line: $out" ;;
  esac
  [ "$out" = "$expected" ] || fail "activity wake was '$out', expected '$expected'"
}

test_seed_comment_replay_and_one_wake() {
  local dir out cursor sidecar_before sidecar_after
  dir=$(make_case seed-comment)
  cursor="$dir/home/state/task-a.pr-activity"
  write_json "$dir/pr.json" OPEN \
    '[{"id":"C1","author":{"login":"alice"},"createdAt":"2026-10-01T00:00:00Z","body":"please rebase\nsecond line"}]' \
    '[]'
  sidecar_before=$(cat "$dir/home/state/task-a.pr-poll")
  : > "$dir/gh.log"
  out=$(run_direct "$dir")
  assert_silent "$out" "first sight of an existing comment woke"
  [ -f "$cursor" ] && [ ! -L "$cursor" ] || fail "seed did not create a cursor"
  [ "$(file_mode "$cursor")" = 600 ] || fail "cursor mode was not 0600"
  grep -qx 'C1' "$cursor" || fail "seed cursor did not record the existing comment"
  grep -qx "$URL" "$cursor" || fail "seed cursor did not record the pull request URL"
  sidecar_after=$(cat "$dir/home/state/task-a.pr-poll")
  [ "$sidecar_after" = "$sidecar_before" ] || fail "activity polling rewrote the sidecar"
  [ "$(wc -l < "$dir/gh.log" | tr -d ' ')" = 1 ] || fail "seed sweep did not use exactly one forge read"
  grep -q -- '--json state,comments,reviews' "$dir/gh.log" || fail "seed sweep did not ask for comments and reviews"
  : > "$dir/gh.log"
  out=$(run_direct "$dir")
  assert_silent "$out" "replaying the seeded comment woke"
  write_json "$dir/pr.json" OPEN \
    '[{"id":"C1","author":{"login":"alice"},"createdAt":"2026-10-01T00:00:00Z","body":"please rebase"},{"id":"C2","author":{"login":"maint"},"createdAt":"2026-10-03T00:00:00Z","body":"please look at the failure"}]' \
    '[]'
  out=$(run_direct "$dir")
  assert_one_line "$out" "pr-activity: $URL comment maint: please look at the failure"
  grep -qx 'C2' "$cursor" || fail "wake did not advance the cursor"
  out=$(run_direct "$dir")
  assert_silent "$out" "replaying the advanced cursor woke again"
  pass "a fresh comment wakes once and a replay stays silent"
}

test_review_batch_and_pending_are_one_line() {
  local dir out
  dir=$(make_case review-batch)
  write_json "$dir/pr.json" OPEN '[]' '[]'
  out=$(run_direct "$dir")
  assert_silent "$out" "empty history woke on seed"
  write_json "$dir/pr.json" OPEN '[]' \
    '[{"id":"Rpend","author":{"login":"maint"},"state":"PENDING","submittedAt":"2026-10-02T00:00:00Z","body":"draft notes"}]'
  out=$(run_direct "$dir")
  assert_silent "$out" "a pending review woke"
  write_json "$dir/pr.json" OPEN \
    '[{"id":"C1","author":{"login":"alice"},"createdAt":"2026-10-01T00:00:00Z","body":"older note\nignored"}]' \
    '[{"id":"R1","author":{"login":"bob"},"state":"CHANGES_REQUESTED","submittedAt":"2026-10-02T00:00:00Z","body":""}]'
  out=$(run_direct "$dir")
  assert_one_line "$out" "pr-activity: $URL review bob: 2 new: CHANGES_REQUESTED"
  pass "submitted reviews wake, pending reviews do not, and a sweep is one line"
}

test_comment_text_stays_data() {
  local dir out marker
  dir=$(make_case comment-data)
  marker="$dir/outside/executed"
  write_json "$dir/pr.json" OPEN '[]' '[]'
  out=$(run_direct "$dir")
  assert_silent "$out" "seed woke"
  jq -n --arg body "hello \$(touch ${marker})" \
    '{state:"OPEN", comments:[{id:"Cbad", author:null, createdAt:"2026-10-04T00:00:00Z", body:$body}], reviews:[]}' \
    > "$dir/pr.json"
  out=$(run_direct "$dir")
  assert_one_line "$out" "pr-activity: $URL comment unknown: hello \$(touch ${marker})"
  [ ! -e "$marker" ] || fail "a comment body was executed"
  pass "comment text is relayed as data and a missing author is unknown"
}

test_errors_and_merged_wording_stay_silent() {
  local dir out cursor before
  dir=$(make_case errors)
  cursor="$dir/home/state/task-a.pr-activity"
  write_json "$dir/pr.json" OPEN \
    '[{"id":"C1","author":{"login":"alice"},"createdAt":"2026-10-01T00:00:00Z","body":"seed me"}]' \
    '[]'
  FM_TEST_GH_FAIL=1 out=$(run_direct "$dir")
  assert_silent "$out" "gh failure woke"
  [ ! -e "$cursor" ] || fail "gh failure created a cursor"
  FM_TEST_GH_TRUNCATED=1 out=$(run_direct "$dir")
  assert_silent "$out" "truncated activity output woke"
  [ ! -e "$cursor" ] || fail "truncated output created a cursor"
  unset FM_TEST_GH_FAIL FM_TEST_GH_TRUNCATED
  out=$(run_direct "$dir")
  assert_silent "$out" "recovery seed woke"
  before=$(cat "$cursor")
  FM_TEST_GH_FAIL=1 out=$(run_direct "$dir")
  assert_silent "$out" "gh failure after seed woke"
  [ "$(cat "$cursor")" = "$before" ] || fail "gh failure advanced the cursor"
  FM_TEST_GH_TRUNCATED=1 out=$(run_direct "$dir")
  assert_silent "$out" "truncated output after seed woke"
  [ "$(cat "$cursor")" = "$before" ] || fail "truncated output advanced the cursor"
  unset FM_TEST_GH_FAIL FM_TEST_GH_TRUNCATED
  write_json "$dir/pr.json" MERGED \
    '[{"id":"C9","author":{"login":"alice"},"createdAt":"2026-10-05T00:00:00Z","body":"landed"}]' \
    '[]'
  out=$(run_direct "$dir")
  [ "$out" = merged ] || fail "merged wording was '$out'"
  printf '%s\n' "$out" > "$dir/got"
  printf '%s\n' merged > "$dir/want"
  cmp -s "$dir/got" "$dir/want" || fail "merged wording was not byte-stable"
  [ "$(cat "$cursor")" = "$before" ] || fail "a merged sweep changed the activity cursor"
  rm -f "$cursor"
  out=$(run_direct "$dir")
  [ "$out" = merged ] || fail "merged wording without a cursor was '$out'"
  [ ! -e "$cursor" ] || fail "a merged sweep seeded an activity cursor"
  pass "errors stay silent and merged wording is unchanged"
}

test_legacy_sidecar_seeds_and_validated_anchor() {
  local dir out cursor
  dir=$(make_case legacy)
  cursor="$dir/home/state/task-a.pr-activity"
  write_json "$dir/pr.json" OPEN \
    '[{"id":"C1","author":{"login":"alice"},"createdAt":"2026-10-01T00:00:00Z","body":"already there"}]' \
    '[]'
  out=$(run_validated "$dir")
  assert_silent "$out" "a read with no cursor anchor woke"
  [ ! -e "$cursor" ] || fail "a read with no cursor anchor wrote a cursor"
  [ ! -e "$ROOT/bin/fm-pr-poll.pr-activity" ] || fail "the poll wrote a cursor next to its own script"
  out=$(run_validated "$dir" "$dir/home/state/task-a.check.sh")
  assert_silent "$out" "validated anchor seeded with a wake"
  [ -f "$cursor" ] || fail "validated anchor did not seed the sibling cursor"
  write_json "$dir/pr.json" OPEN \
    '[{"id":"C1","author":{"login":"alice"},"createdAt":"2026-10-01T00:00:00Z","body":"already there"},{"id":"C2","author":{"login":"maint"},"createdAt":"2026-10-03T00:00:00Z","body":"new note"}]' \
    '[]'
  out=$(run_validated "$dir" "$dir/home/state/task-a.check.sh")
  assert_one_line "$out" "pr-activity: $URL comment maint: new note"
  pass "a legacy sidecar seeds from the check path and a missing anchor stays silent"
}

test_cursor_symlink_and_path_escape_refused() {
  local dir out cursor escape
  dir=$(make_case escape)
  cursor="$dir/home/state/task-a.pr-activity"
  printf 'sentinel\n' > "$dir/outside/secret"
  write_json "$dir/pr.json" OPEN \
    '[{"id":"C1","author":{"login":"alice"},"createdAt":"2026-10-01T00:00:00Z","body":"do not follow"}]' \
    '[]'
  ln -s "$dir/outside/secret" "$cursor"
  out=$(run_direct "$dir")
  assert_silent "$out" "a symlink cursor woke"
  [ -L "$cursor" ] || fail "a symlink cursor was replaced"
  [ "$(cat "$dir/outside/secret")" = sentinel ] || fail "a symlink cursor wrote through to its target"
  rm -f "$cursor"
  out=$(run_direct "$dir")
  assert_silent "$out" "seed after removing the symlink woke"
  ln -sf "$dir/outside/secret" "$cursor"
  write_json "$dir/pr.json" OPEN \
    '[{"id":"C1","author":{"login":"alice"},"createdAt":"2026-10-01T00:00:00Z","body":"do not follow"},{"id":"C2","author":{"login":"maint"},"createdAt":"2026-10-03T00:00:00Z","body":"new"}]' \
    '[]'
  out=$(run_direct "$dir")
  assert_silent "$out" "a replaced symlink cursor woke"
  [ -L "$cursor" ] || fail "a replaced symlink cursor was removed"
  [ "$(cat "$dir/outside/secret")" = sentinel ] || fail "a replaced symlink cursor changed its target"
  cp "$POLL" "$dir/outside/evil.check.sh"
  printf '%s\n' github "$URL" github.com o/r 1 > "$dir/outside/evil.pr-poll"
  escape="$dir/home/state/../../$(basename "$dir")/outside/evil.check.sh"
  out=$(run_validated "$dir" "$escape")
  assert_silent "$out" "a dot-dot cursor anchor woke"
  [ ! -e "$dir/outside/evil.pr-activity" ] || fail "a dot-dot anchor wrote a cursor outside"
  ln -s "$dir/outside" "$dir/home/state/linked"
  cp "$POLL" "$dir/outside/task.check.sh"
  printf '%s\n' github "$URL" github.com o/r 1 > "$dir/outside/task.pr-poll"
  out=$(run_validated "$dir" "$dir/home/state/linked/task.check.sh")
  assert_silent "$out" "a symlink directory anchor woke"
  [ ! -e "$dir/outside/task.pr-activity" ] || fail "a symlink directory anchor wrote a cursor outside"
  pass "symlink and path-escape cursors are refused"
}

test_url_mismatch_reseeds_without_a_wake() {
  local dir out cursor
  dir=$(make_case reseed)
  cursor="$dir/home/state/task-a.pr-activity"
  write_json "$dir/pr.json" OPEN \
    '[{"id":"C1","author":{"login":"alice"},"createdAt":"2026-10-01T00:00:00Z","body":"hello"}]' \
    '[]'
  printf '%s\n' fm-pr-activity-v1 'https://github.com/o/r/pull/9' > "$cursor"
  chmod 0600 "$cursor"
  out=$(run_direct "$dir")
  assert_silent "$out" "a cursor for another pull request woke"
  grep -qx "$URL" "$cursor" || fail "a mismatched cursor was not reseeded"
  grep -qx 'C1' "$cursor" || fail "reseed did not record the current comment"
  out=$(run_direct "$dir")
  assert_silent "$out" "the reseeded cursor woke on replay"
  pass "a cursor for another pull request is reseeded without a wake"
}

test_watcher_passes_the_anchor() {
  local dir state out rc
  dir=$(make_case watcher)
  state="$dir/home/state"
  fm_write_meta "$state/task-a.meta" \
    "window=fm-task-a" \
    "worktree=$dir/wt" \
    "pr=$URL"
  fm_pr_poll_prepare "$state" task-a github "$URL" github.com o/r 1 "$POLL" \
    || fail "could not prepare the watcher poll"
  fm_pr_poll_publish_prepared || fail "could not publish the watcher poll"
  write_json "$dir/pr.json" OPEN \
    '[{"id":"C1","author":{"login":"alice"},"createdAt":"2026-10-01T00:00:00Z","body":"seed"}]' \
    '[]'
  out=$(FM_TEST_GH_JSON_FILE="$dir/pr.json" FM_TEST_GH_LOG="$dir/gh.log" \
    PATH="$dir/fakebin:$BASE_PATH" bash "$state/task-a.check.sh")
  assert_silent "$out" "watcher fixture seed woke"
  write_json "$dir/pr.json" OPEN \
    '[{"id":"C1","author":{"login":"alice"},"createdAt":"2026-10-01T00:00:00Z","body":"seed"},{"id":"C2","author":{"login":"maint"},"createdAt":"2026-10-03T00:00:00Z","body":"watcher note"}]' \
    '[]'
  rm -f "$state/.last-check"
  fm_test_track_watcher_state "$state"
  set +e
  out=$(perl -MPOSIX=WNOHANG -MTime::HiRes=time,sleep -e 'my $left=25; my $pid=fork; die unless defined $pid; if (!$pid) { exec @ARGV } my $last=time; while (waitpid($pid, WNOHANG) == 0) { my $now=time; $left -= $now - $last; $last=$now; if ($left <= 0) { kill "TERM", $pid; waitpid $pid, 0; exit 124 } sleep 0.02 } exit($? >> 8)' \
    env FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_CHECK_INTERVAL=0 \
      FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
      FM_TEST_GH_JSON_FILE="$dir/pr.json" FM_TEST_GH_LOG="$dir/gh.log" \
      PATH="$dir/fakebin:$BASE_PATH" "$WATCH")
  rc=$?
  set -e
  [ "$rc" -eq 0 ] || fail "watcher did not surface the activity wake (rc=$rc)"
  printf '%s\n' "$out" | grep -F "pr-activity: $URL comment maint: watcher note" >/dev/null \
    || fail "watcher did not relay the activity line"
  [ "$(printf '%s\n' "$out" | grep -c -F "pr-activity: $URL comment maint: watcher note")" -eq 1 ] \
    || fail "watcher relayed the activity line more than once"
  pass "the sweep relays one activity line for a new comment"
}

test_seed_comment_replay_and_one_wake
test_review_batch_and_pending_are_one_line
test_comment_text_stays_data
test_errors_and_merged_wording_stay_silent
test_legacy_sidecar_seeds_and_validated_anchor
test_cursor_symlink_and_path_escape_refused
test_url_mismatch_reseeds_without_a_wake
test_watcher_passes_the_anchor
