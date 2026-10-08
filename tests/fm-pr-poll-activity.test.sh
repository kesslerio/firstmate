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
REAL_MV=$(command -v mv)
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
[ "${1:-} ${2:-}" = "api graphql" ] || exit 2
shift 2
prog=
query=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --hostname) [ "${2:-}" = github.com ] || exit 2 ;;
    -f)
      case "${2:-}" in
        query=*) query=${2#query=} ;;
        owner=o|repo=r) ;;
        *) exit 2 ;;
      esac
      ;;
    -F) [ "${2:-}" = number=1 ] || exit 2 ;;
    --jq) prog=${2:-} ;;
    *) exit 2 ;;
  esac
  shift 2
done
case "$query" in
  *after:*|*endCursor*) exit 2 ;;
esac
case "$query" in
  *"comments(first: 100)"*"pageInfo { hasNextPage }"*"reviews(first: 100)"*"pageInfo { hasNextPage }"*) ;;
  *) exit 2 ;;
esac
[ -n "$prog" ] || exit 2
if [ -n "${FM_TEST_GH_UNFRAMED:-}" ]; then
  printf '%s\n' "$FM_TEST_GH_UNFRAMED"
  exit 0
fi
if [ "${FM_TEST_GH_RAW_JSON:-0}" = 1 ]; then
  jq -r "$prog" "$FM_TEST_GH_JSON_FILE"
else
  jq '{data:{repository:{pullRequest:{state:.state, comments:{nodes:.comments[:100],pageInfo:{hasNextPage:(.comments|length>100)}}, reviews:{nodes:.reviews[:100],pageInfo:{hasNextPage:(.reviews|length>100)}}}}}}' "$FM_TEST_GH_JSON_FILE" | jq -r "$prog"
fi
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
    FM_TEST_GH_UNFRAMED="${FM_TEST_GH_UNFRAMED:-}" \
    FM_TEST_GH_RAW_JSON="${FM_TEST_GH_RAW_JSON:-0}" \
    PATH="$dir/fakebin:$BASE_PATH" \
    bash "$dir/home/state/task-a.check.sh"
}

run_validated() {
  local dir=$1 check=${2:-}
  if [ -n "$check" ]; then
    FM_TEST_GH_JSON_FILE="$dir/pr.json" FM_TEST_GH_LOG="$dir/gh.log" \
      FM_TEST_GH_FAIL="${FM_TEST_GH_FAIL:-0}" \
      FM_TEST_GH_TRUNCATED="${FM_TEST_GH_TRUNCATED:-0}" \
      FM_TEST_GH_UNFRAMED="${FM_TEST_GH_UNFRAMED:-}" \
      FM_TEST_GH_RAW_JSON="${FM_TEST_GH_RAW_JSON:-0}" \
      PATH="$dir/fakebin:$BASE_PATH" \
      bash "$POLL" --validated github "$URL" github.com o/r 1 "$check"
  else
    FM_TEST_GH_JSON_FILE="$dir/pr.json" FM_TEST_GH_LOG="$dir/gh.log" \
      FM_TEST_GH_FAIL="${FM_TEST_GH_FAIL:-0}" \
      FM_TEST_GH_TRUNCATED="${FM_TEST_GH_TRUNCATED:-0}" \
      FM_TEST_GH_UNFRAMED="${FM_TEST_GH_UNFRAMED:-}" \
      FM_TEST_GH_RAW_JSON="${FM_TEST_GH_RAW_JSON:-0}" \
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
  grep -q -- '^api graphql ' "$dir/gh.log" || fail "seed did not make a GraphQL request"
  grep -qF -- 'comments(first: 100)' "$dir/gh.log" || fail "comments request was not bounded"
  grep -qF -- 'reviews(first: 100)' "$dir/gh.log" || fail "reviews request was not bounded"
  if grep -qE -- '--paginate|endCursor' "$dir/gh.log"; then
    fail "seed requested pagination"
  fi
  : > "$dir/gh.log"
  out=$(run_direct "$dir")
  assert_silent "$out" "replaying the seeded comment woke"
  write_json "$dir/pr.json" OPEN \
    '[{"id":"C1","author":{"login":"alice"},"createdAt":"2026-10-01T00:00:00Z","body":"please rebase"},{"id":"C2","author":{"login":"maint"},"createdAt":"2026-10-03T00:00:00Z","body":"please look at the failure"}]' \
    '[]'
  out=$(run_direct "$dir")
  assert_one_line "$out" "pr-activity: $URL comment maint: please look at the failure"
  if grep -qx 'C2' "$cursor"; then fail "unqueued activity advanced the cursor"; fi
  grep -qx 'C2' "$cursor.pending" || fail "activity did not stage the next cursor"
  [ "$(file_mode "$cursor.pending")" = 600 ] || fail "staged cursor mode was not 0600"
  out=$(run_direct "$dir")
  assert_one_line "$out" "pr-activity: $URL comment maint: please look at the failure"
  pass "unqueued activity is staged and repeats until committed"
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
  out=$(FM_TEST_GH_FAIL=1 run_direct "$dir")
  assert_silent "$out" "gh failure woke"
  [ ! -e "$cursor" ] || fail "gh failure created a cursor"
  out=$(FM_TEST_GH_TRUNCATED=1 run_direct "$dir")
  assert_silent "$out" "truncated activity output woke"
  [ ! -e "$cursor" ] || fail "truncated output created a cursor"
  out=$(FM_TEST_GH_UNFRAMED=MERGED run_direct "$dir")
  [ "$out" = merged ] || fail "an unframed merge was not recognized"
  [ ! -e "$cursor" ] || fail "an unframed response seeded a cursor"
  out=$(run_direct "$dir")
  assert_silent "$out" "recovery seed woke"
  before=$(cat "$cursor")
  out=$(FM_TEST_GH_UNFRAMED=OPEN run_direct "$dir")
  assert_silent "$out" "an unframed open response after seed woke"
  [ "$(cat "$cursor")" = "$before" ] || fail "an unframed response changed the cursor"
  [ ! -e "$cursor.pending" ] || fail "an unframed response staged a cursor"
  out=$(FM_TEST_GH_FAIL=1 run_direct "$dir")
  assert_silent "$out" "gh failure after seed woke"
  [ "$(cat "$cursor")" = "$before" ] || fail "gh failure advanced the cursor"
  out=$(FM_TEST_GH_TRUNCATED=1 run_direct "$dir")
  assert_silent "$out" "truncated output after seed woke"
  [ "$(cat "$cursor")" = "$before" ] || fail "truncated output advanced the cursor"
  printf 'staged-sentinel\n' > "$cursor.pending"
  chmod 0600 "$cursor.pending"
  write_json "$dir/pr.json" MERGED \
    '[{"id":"C9","author":{"login":"alice"},"createdAt":"2026-10-05T00:00:00Z","body":"landed"}]' \
    '[]'
  out=$(run_direct "$dir")
  [ "$out" = merged ] || fail "merged wording was '$out'"
  printf '%s\n' "$out" > "$dir/got"
  printf '%s\n' merged > "$dir/want"
  cmp -s "$dir/got" "$dir/want" || fail "merged wording was not byte-stable"
  [ "$(cat "$cursor")" = "$before" ] || fail "a merged sweep changed the activity cursor"
  [ "$(cat "$cursor.pending")" = staged-sentinel ] || fail "a merged sweep changed the staged cursor"
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

run_watcher() {
  local dir=$1
  set +e
  WATCH_OUT=$(perl -MPOSIX=WNOHANG -MTime::HiRes=time,sleep -e 'my $left=25; my $pid=fork; die unless defined $pid; if (!$pid) { exec @ARGV } my $last=time; while (waitpid($pid, WNOHANG) == 0) { my $now=time; $left -= $now - $last; $last=$now; if ($left <= 0) { kill "TERM", $pid; waitpid $pid, 0; exit 124 } sleep 0.02 } exit(($? & 127) ? 128 + ($? & 127) : $? >> 8)' \
    env FM_HOME="$dir/home" FM_ROOT_OVERRIDE="$ROOT" FM_CHECK_INTERVAL=0 \
      FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 \
      FM_TEST_GH_JSON_FILE="$dir/pr.json" FM_TEST_GH_LOG="$dir/gh.log" \
      FM_WAKE_QUEUE="$dir/home/state/.wake-queue" \
      FM_TEST_REAL_MV="$REAL_MV" \
      PATH="$dir/fakebin:$BASE_PATH" "$WATCH")
  WATCH_RC=$?
  set -e
}

make_activity_watcher_case() {
  local dir state
  dir=$(make_case "$1")
  state="$dir/home/state"
  fm_write_meta "$state/task-a.meta" "window=fm-task-a" "worktree=$dir/wt" "pr=$URL"
  if ! fm_pr_poll_prepare "$state" task-a github "$URL" github.com o/r 1 "$POLL" \
    || ! fm_pr_poll_publish_prepared; then
    fail "could not publish the watcher fixture"
  fi
  write_json "$dir/pr.json" OPEN \
    '[{"id":"C1","author":{"login":"alice"},"createdAt":"2026-10-01T00:00:00Z","body":"seed"}]' '[]'
  run_direct "$dir" >/dev/null
  write_json "$dir/pr.json" OPEN \
    '[{"id":"C1","author":{"login":"alice"},"createdAt":"2026-10-01T00:00:00Z","body":"seed"},{"id":"C2","author":{"login":"maint"},"createdAt":"2026-10-03T00:00:00Z","body":"watcher note"}]' '[]'
  printf '%s\n' "$dir"
}

test_failed_delivery_keeps_activity_retryable() {
  local dir cursor before out
  dir=$(make_activity_watcher_case append-failure)
  cursor="$dir/home/state/task-a.pr-activity"
  before=$(cat "$cursor")
  mkdir "$dir/home/state/.wake-queue.seq"
  fm_test_track_watcher_state "$dir/home/state"
  run_watcher "$dir"
  [ "$WATCH_RC" -ne 0 ] || fail "watcher accepted a failed queue append"
  [ "$(cat "$cursor")" = "$before" ] || fail "failed queue append committed activity"
  grep -qx C2 "$cursor.pending" || fail "failed queue append lost the staged activity"
  out=$(run_direct "$dir")
  assert_one_line "$out" "pr-activity: $URL comment maint: watcher note"

  dir=$(make_activity_watcher_case interrupted-commit)
  cursor="$dir/home/state/task-a.pr-activity"
  before=$(cat "$cursor")
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
for last in "$@"; do :; done
case "$last" in
  *.pr-activity)
    grep -qF 'pr-activity:' "$FM_WAKE_QUEUE" || exit 2
    kill -TERM "$PPID"
    exit 1
    ;;
esac
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$dir/fakebin/mv"
  fm_test_track_watcher_state "$dir/home/state"
  run_watcher "$dir"
  [ "$WATCH_RC" -ne 0 ] || fail "watcher was not interrupted before cursor commit"
  grep -qF 'pr-activity:' "$dir/home/state/.wake-queue" || fail "interruption did not reach the queued activity"
  [ "$(cat "$cursor")" = "$before" ] || fail "interruption committed undelivered activity"
  grep -qx C2 "$cursor.pending" || fail "interruption lost staged activity"
  rm -f "$dir/fakebin/mv"
  out=$(run_direct "$dir")
  assert_one_line "$out" "pr-activity: $URL comment maint: watcher note"
  pass "failed append and interrupted commit leave activity retryable"
}

test_unsafe_cursor_siblings_are_refused() {
  local dir cursor file target before kind suffix out
  for suffix in '' .pending; do
    for kind in symlink hardlink mode directory; do
      dir=$(make_case "unsafe${suffix}-$kind")
      cursor="$dir/home/state/task-a.pr-activity"
      file="$cursor$suffix"
      write_json "$dir/pr.json" OPEN '[]' '[]'
      out=$(run_direct "$dir")
      assert_silent "$out" "unsafe-file fixture seed woke"
      before=$(cat "$cursor")
      target="$dir/outside/target"
      printf 'sentinel\n' > "$target"
      chmod 0600 "$target"
      rm -f "$file"
      case "$kind" in
        symlink) ln -s "$target" "$file" ;;
        hardlink) ln "$target" "$file" ;;
        mode) printf 'sentinel\n' > "$file"; chmod 0644 "$file" ;;
        directory) mkdir "$file" ;;
      esac
      write_json "$dir/pr.json" OPEN \
        '[{"id":"C2","author":{"login":"a"},"createdAt":"2026-10-03T00:00:00Z","body":"new"}]' '[]'
      out=$(run_direct "$dir")
      assert_silent "$out" "an unsafe $kind cursor$suffix woke"
      [ "$(cat "$target")" = sentinel ] || fail "an unsafe cursor changed another file"
      if [ -n "$suffix" ]; then
        [ "$(cat "$cursor")" = "$before" ] || fail "an unsafe staged cursor changed the committed cursor"
      fi
      case "$kind" in
        symlink) [ -L "$file" ] || fail "unsafe symlink was replaced" ;;
        hardlink|mode) [ "$(cat "$file")" = sentinel ] || fail "unsafe file was replaced" ;;
        directory) [ -d "$file" ] || fail "unsafe directory was replaced" ;;
      esac
    done
  done
  pass "committed and staged cursors enforce the same file protections"
}

test_bounded_activity_stays_unread() {
  local dir out
  dir=$(make_case bounded)
  jq -n '{state:"OPEN", comments:[range(0;101) | {id:("C"+tostring), author:{login:"a"}, createdAt:"2026-10-01T00:00:00Z", body:"old"}], reviews:[range(0;101) | {id:("R"+tostring), author:{login:"b"}, state:"COMMENTED", submittedAt:"2026-10-01T00:00:00Z", body:"old"}]}' > "$dir/pr.json"
  out=$(run_direct "$dir")
  assert_silent "$out" "bounded fixture seed woke"
  jq '.comments[100].id="Cnew" | .reviews[100].id="Rnew"' "$dir/pr.json" > "$dir/next.json"
  mv "$dir/next.json" "$dir/pr.json"
  out=$(run_direct "$dir")
  assert_silent "$out" "activity beyond the 100-item bounds woke"
  if grep -qE 'C100|R100|Cnew|Rnew' "$dir/home/state/task-a.pr-activity"; then
    fail "the cursor recorded unread activity"
  fi
  pass "comments and reviews past the request bounds stay unread"
}

test_truncated_activity_marks_either_collection() {
  local dir out paged kind count summary cursor
  for paged in comment review; do
    for kind in comment review; do
      dir=$(make_case "truncated-$paged-$kind")
      cursor="$dir/home/state/task-a.pr-activity"
      jq -n --arg paged "$paged" \
        '{state:"OPEN", comments:[], reviews:[]} | (if $paged == "comment" then .comments else .reviews end) = [range(0;101) | {id:("OLD"+tostring), author:{login:"a"}, createdAt:"2026-10-01T00:00:00Z", submittedAt:"2026-10-01T00:00:00Z", state:"COMMENTED", body:"old"}]' > "$dir/pr.json"
      out=$(run_direct "$dir")
      assert_silent "$out" "a bounded seed with unread pages woke"
      out=$(run_validated "$dir" "$dir/home/state/task-a.check.sh")
      assert_silent "$out" "unread pages alone woke on replay"
      count=1
      [ "$paged" = "$kind" ] || count=2
      jq --arg kind "$kind" --argjson count "$count" \
        '(if $kind == "comment" then .comments else .reviews end)[0:$count] = [range(0;$count) | {id:("NEW"+tostring), author:{login:"a"}, createdAt:"2026-10-03T00:00:00Z", submittedAt:"2026-10-03T00:00:00Z", state:"COMMENTED", body:"new note"}]' "$dir/pr.json" > "$dir/next.json"
      mv "$dir/next.json" "$dir/pr.json"
      : > "$dir/gh.log"
      out=$(run_validated "$dir" "$dir/home/state/task-a.check.sh")
      summary='new note'
      [ "$count" -eq 1 ] || summary='2 new: new note'
      assert_one_line "$out" "pr-activity: $URL $kind a: truncated: $summary"
      [ "$(wc -l < "$dir/gh.log" | tr -d ' ')" = 1 ] || fail "truncation made another forge request"
      grep -qx NEW0 "$cursor.pending" || fail "truncated activity was not staged"
      if grep -qx NEW0 "$cursor"; then fail "truncated activity committed before queueing"; fi
    done
  done
  pass "either unread collection marks single and batch activity as truncated"
}

test_malformed_pagination_metadata_stays_silent() {
  local dir cursor before out state mutation
  for state in OPEN MERGED; do
    for mutation in missing-comment-page missing-review-page wrong-comment-page wrong-review-page missing-nodes short-json invalid-json; do
      dir=$(make_case "metadata-$state-$mutation")
      cursor="$dir/home/state/task-a.pr-activity"
      jq -n --arg state "$state" \
        '{data:{repository:{pullRequest:{state:$state, comments:{nodes:[{id:"NEW",author:{login:"a"},createdAt:"2026-10-03T00:00:00Z",body:"new"}],pageInfo:{hasNextPage:true}},reviews:{nodes:[],pageInfo:{hasNextPage:false}}}}}}' > "$dir/full.json"
      case "$mutation" in
        missing-comment-page) jq 'del(.data.repository.pullRequest.comments.pageInfo)' "$dir/full.json" > "$dir/bad.json" ;;
        missing-review-page) jq 'del(.data.repository.pullRequest.reviews.pageInfo)' "$dir/full.json" > "$dir/bad.json" ;;
        wrong-comment-page) jq '.data.repository.pullRequest.comments.pageInfo.hasNextPage="true"' "$dir/full.json" > "$dir/bad.json" ;;
        wrong-review-page) jq '.data.repository.pullRequest.reviews.pageInfo.hasNextPage=null' "$dir/full.json" > "$dir/bad.json" ;;
        missing-nodes) jq 'del(.data.repository.pullRequest.comments.nodes)' "$dir/full.json" > "$dir/bad.json" ;;
        short-json) jq 'del(.data.repository.pullRequest.comments,.data.repository.pullRequest.reviews)' "$dir/full.json" > "$dir/bad.json" ;;
        invalid-json) printf '{"data":' > "$dir/bad.json" ;;
      esac
      cp "$dir/bad.json" "$dir/pr.json"
      out=$(FM_TEST_GH_RAW_JSON=1 run_direct "$dir")
      assert_silent "$out" "malformed pagination metadata woke before seed"
      if [ -e "$cursor" ] || [ -e "$cursor.pending" ]; then
        fail "malformed metadata wrote a cursor before seed"
      fi
      write_json "$dir/pr.json" OPEN '[]' '[]'
      out=$(run_direct "$dir")
      assert_silent "$out" "metadata fixture seed woke"
      before=$(cat "$cursor")
      cp "$dir/bad.json" "$dir/pr.json"
      out=$(FM_TEST_GH_RAW_JSON=1 run_validated "$dir" "$dir/home/state/task-a.check.sh")
      assert_silent "$out" "malformed pagination metadata woke after seed"
      [ "$(cat "$cursor")" = "$before" ] || fail "malformed metadata changed the cursor"
      [ ! -e "$cursor.pending" ] || fail "malformed metadata staged activity"
    done
  done
  pass "missing, malformed, and short JSON never become truncated activity or merges"
}

test_bare_state_compatibility() {
  local dir cursor before state out expected
  for state in MERGED OPEN CLOSED; do
    dir=$(make_case "bare-$state")
    cursor="$dir/home/state/task-a.pr-activity"
    write_json "$dir/pr.json" OPEN '[]' '[]'
    expected=
    [ "$state" != MERGED ] || expected=merged
    out=$(FM_TEST_GH_UNFRAMED="$state" run_direct "$dir")
    [ "$out" = "$expected" ] || fail "bare $state direct response was not compatible"
    [ ! -e "$cursor" ] || fail "bare $state seeded activity"
    out=$(run_direct "$dir")
    assert_silent "$out" "bare-state fixture seed woke"
    before=$(cat "$cursor")
    out=$(FM_TEST_GH_UNFRAMED="$state" run_validated "$dir" "$dir/home/state/task-a.check.sh")
    [ "$out" = "$expected" ] || fail "bare $state validated response was not compatible"
    [ "$(cat "$cursor")" = "$before" ] || fail "bare $state changed the cursor"
    [ ! -e "$cursor.pending" ] || fail "bare $state staged activity"
  done
  for state in $'MERGED\nextra' $'OPEN\ntruncated=true' ' MERGED' 'state=OPEN'; do
    dir=$(make_case "bare-invalid-$RANDOM")
    write_json "$dir/pr.json" OPEN '[]' '[]'
    out=$(FM_TEST_GH_UNFRAMED="$state" run_direct "$dir")
    assert_silent "$out" "a short or malformed state response woke"
    [ ! -e "$dir/home/state/task-a.pr-activity" ] || fail "a short or malformed state response seeded activity"
  done
  pass "bare MERGED, OPEN, and CLOSED remain compatible while malformed responses stay silent"
}

test_unicode_and_author_rendering() {
  local dir out kind author expected body
  for kind in comment review; do
    for author in a 'bad!' -bad missing long legal39; do
      dir=$(make_case "$kind-author-$author")
      write_json "$dir/pr.json" OPEN '[]' '[]'
      out=$(run_direct "$dir")
      assert_silent "$out" "rendering fixture seed woke"
      case "$author" in
        a) expected=a ;;
        legal39) author=$(printf '%039d' 0); expected=$author ;;
        long) author=$(printf '%040d' 0); expected=unknown ;;
        *) expected=unknown ;;
      esac
      body=$(printf '%0199d' 0)😀
      jq -n --arg kind "$kind" --arg author "$author" --arg body "${body}discard" \
        '{state:"OPEN", comments:[], reviews:[]} | (if $kind == "comment" then .comments else .reviews end) = [{id:"NEW", author:(if $author == "missing" then null else {login:$author} end), createdAt:"2026-10-03T00:00:00Z", submittedAt:"2026-10-03T00:00:00Z", state:"COMMENTED", body:$body}]' > "$dir/pr.json"
      out=$(run_direct "$dir")
      assert_one_line "$out" "pr-activity: $URL $kind $expected: $body"
    done
  done
  pass "comments and reviews preserve Unicode and validate all author lengths"
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
  run_watcher "$dir"
  out=$WATCH_OUT
  rc=$WATCH_RC
  [ "$rc" -eq 0 ] || fail "watcher did not surface the activity wake (rc=$rc)"
  printf '%s\n' "$out" | grep -F "pr-activity: $URL comment maint: watcher note" >/dev/null \
    || fail "watcher did not relay the activity line"
  [ "$(printf '%s\n' "$out" | grep -c -F "pr-activity: $URL comment maint: watcher note")" -eq 1 ] \
    || fail "watcher relayed the activity line more than once"
  grep -qx 'C2' "$state/task-a.pr-activity" || fail "queued activity did not commit the cursor"
  [ ! -e "$state/task-a.pr-activity.pending" ] || fail "committed activity left a staged cursor"
  grep -F "pr-activity: $URL comment maint: watcher note" "$state/.wake-queue" >/dev/null \
    || fail "cursor advanced without a queued activity wake"
  out=$(run_direct "$dir")
  assert_silent "$out" "queued activity woke on replay"
  pass "the sweep queues activity before committing and replay stays silent"
}

test_seed_comment_replay_and_one_wake
test_review_batch_and_pending_are_one_line
test_comment_text_stays_data
test_errors_and_merged_wording_stay_silent
test_legacy_sidecar_seeds_and_validated_anchor
test_cursor_symlink_and_path_escape_refused
test_url_mismatch_reseeds_without_a_wake
test_watcher_passes_the_anchor
test_failed_delivery_keeps_activity_retryable
test_unsafe_cursor_siblings_are_refused
test_bounded_activity_stays_unread
test_unicode_and_author_rendering
test_truncated_activity_marks_either_collection
test_malformed_pagination_metadata_stays_silent
test_bare_state_compatibility
