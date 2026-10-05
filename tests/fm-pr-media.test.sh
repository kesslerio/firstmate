#!/usr/bin/env bash
# Behavior tests for bin/fm-pr-media.sh: the exit code a lane gates on, and the
# per-address receipt it is built from.
#
# `gh` is a fixture that answers a table of exact request targets with status lines,
# so each case pins one verdict: the pinned raw form at the published head passes,
# the raw.githubusercontent form fails on a private repository however the token
# answered, an abbreviated commit is refused, a path absent from the published head
# is named, an attachment address is fetched with the credential, and a body naming
# evidence without addressing it fails. The published-github.com fetch that a token
# cannot answer is asserted to stay un-fetched, because treating that 404 as a
# verdict is the same class of mistake this command exists to stop.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CMD="$ROOT/bin/fm-pr-media.sh"
assert_present "$CMD" "bin/fm-pr-media.sh is missing"

TMP_ROOT=$(fm_test_tmproot fm-pr-media)

SHA=0123456789abcdef0123456789abcdef01234567
REPO=tester/widgets

# A fixture pull request: the body under test, the head it was published at, and the
# table of answers the fake forge gives.
#
# Each table row is "<status> <target>": the exact string the command asks the forge
# for, and the status line the forge answers with. A target the table does not name
# is answered 599, which no case may read as a pass.
new_case() {  # <name> -> prints the case directory
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/fakebin" "$dir/cases"
  cat >"$dir/fakebin/gh" <<'SH'
#!/usr/bin/env bash
# Fake gh: answers the request table, and records every target it was asked for.
set -u
table=${FM_FAKE_GH_TABLE:?}
asked=${FM_FAKE_GH_ASKED:?}
sub=$1
shift
target=''
jq=''
field=''
while [ $# -gt 0 ]; do
  case "$1" in
    --method) shift 2 ;;
    --jq) jq=$2; shift 2 ;;
    -i | --include) shift ;;
    -F | --field | -H | --header) shift 2 ;;
    --json) field=$2; shift 2 ;;
    -q) shift 2 ;;
    *) target=$1; shift ;;
  esac
done
printf '%s\n' "$sub $target" >>"$asked"
case "$sub" in
  api)
    if [ -n "$jq" ]; then
      answer=$(awk -v want="$target" '$1 == "PRIVATE" && $2 == want { print $3 }' "$table" | head -n 1)
      [ -n "$answer" ] || answer=unknown
      printf '%s\n' "$answer"
      exit 0
    fi
    code=$(awk -v want="$target" '$1 == "STATUS" && $2 == want { print $3 }' "$table" | head -n 1)
    [ -n "$code" ] || code=599
    # A NONE row stands for a forge that answered nothing parseable at all, which
    # is the shape of an unreadable check rather than a bad code.
    if [ "$code" = NONE ]; then
      exit 1
    fi
    printf 'HTTP/2.0 %s Fake\r\nX-Fake: yes\r\n\r\nfake-body\r\n' "$code"
    case "$code" in
      2??) exit 0 ;;
      *) exit 1 ;;
    esac
    ;;
  *)
    # A case names one pull-request read the forge should refuse, which is how the
    # "cannot verify beats reporting a clean receipt" path is exercised.
    if [ -n "${FM_FAKE_GH_PRVIEW_FAIL:-}" ] && [ "$FM_FAKE_GH_PRVIEW_FAIL" = "$field" ]; then
      printf 'gh: could not resolve the pull request (HTTP 504)\n' >&2
      exit 1
    fi
    # A live read: the body comes from one fixture and the published head plus head
    # repository from another, so a case pins exactly what the forge reports.
    case "$field" in
      *body*) cat "${FM_FAKE_GH_BODY:?}"; exit 0 ;;
    esac
    printf '%s\n' "${FM_FAKE_GH_META:-}"
    exit 0
    ;;
esac
SH
  chmod +x "$dir/fakebin/gh"
  : >"$dir/table"
  : >"$dir/asked"
  printf '%s\n' "$dir"
}

# run_case <dir> [extra args...] -> sets OUT, ERR, CODE
run_case() {
  local dir=$1
  shift
  : >"$dir/asked"
  OUT=$(
    PATH="$dir/fakebin:$PATH" \
      FM_FAKE_GH_TABLE="$dir/table" \
      FM_FAKE_GH_ASKED="$dir/asked" \
      FM_FAKE_GH_PRVIEW_FAIL="${FM_FAKE_GH_PRVIEW_FAIL:-}" \
      "$CMD" --repo "$REPO" "$@" 2>"$dir/err"
  )
  CODE=$?
  ERR=$(cat "$dir/err")
}

body_case() {  # <dir> <body text> -> writes the fixture body
  printf '%s\n' "$2" >"$1/body.md"
}

status_row() { printf 'STATUS %s %s\n' "$2" "$3" >>"$1/table"; }
# The forge answers a private read with `true` or `false`; a case says which shape
# of repository it wants, and the table stores what the real answer looks like.
private_row() {
  local value=$2
  case "$2" in
    yes) value=true ;;
    no) value=false ;;
  esac
  printf 'PRIVATE repos/%s %s\n' "$REPO" "$value" >>"$1/table"
}

test_pinned_raw_address_at_the_published_head_passes() {
  local dir
  dir=$(new_case pinned-pass)
  private_row "$dir" yes
  status_row "$dir" "repos/$REPO/contents/docs/media/a.png?ref=$SHA" 200
  body_case "$dir" '![First screen](https://github.com/tester/widgets/raw/'"$SHA"'/docs/media/a.png)'
  run_case "$dir" --body-file "$dir/body.md" --head "$SHA"
  expect_code 0 "$CODE" "a pinned address that exists at the published head must pass"
  assert_contains "$OUT" "[ok] https://github.com/tester/widgets/raw/$SHA/docs/media/a.png" \
    "the receipt must carry a verdict for the address"
  assert_contains "$OUT" "contents=200" "the receipt must print the code it read"
  assert_contains "$OUT" "direct=session-bound" \
    "the published-web fetch a token cannot answer must be reported as not a check"
  assert_not_contains "$OUT" "[fail]" "nothing failed in this case"
  pass "an address pinned at the published head passes on the contents check"
}

test_raw_githubusercontent_address_fails_on_a_private_repository() {
  local dir
  dir=$(new_case raw-direct-private)
  private_row "$dir" yes
  status_row "$dir" "repos/$REPO/contents/docs/media/a.png?ref=$SHA" 200
  body_case "$dir" '![First screen](https://raw.githubusercontent.com/tester/widgets/'"$SHA"'/docs/media/a.png)'
  run_case "$dir" --body-file "$dir/body.md" --head "$SHA"
  expect_code 1 "$CODE" "a raw.githubusercontent address on a private repository must fail"
  assert_contains "$OUT" "404 to a logged-in browser" \
    "the refusal must name the browser, not just a code"
  assert_contains "$OUT" "use: https://github.com/tester/widgets/raw/$SHA/docs/media/a.png" \
    "the refusal must print the drop-in correction"
  assert_contains "$OUT" "contents=200" \
    "the token answer must still be printed, since a 200 here is the trap"
  pass "the unresolvable address form is refused with its correction"
}

test_abbreviated_commit_is_refused_and_rewritten_to_the_published_head() {
  local dir
  dir=$(new_case abbreviated)
  private_row "$dir" yes
  status_row "$dir" "repos/$REPO/contents/docs/media/a.png?ref=0123456" 200
  body_case "$dir" '![First screen](https://github.com/tester/widgets/raw/0123456/docs/media/a.png)'
  run_case "$dir" --body-file "$dir/body.md" --head "$SHA"
  expect_code 1 "$CODE" "a 7-character commit prefix must be refused, not resolved"
  assert_contains "$OUT" 'abbreviated commit id "0123456"' "the refusal must name the prefix"
  assert_contains "$OUT" "use: https://github.com/tester/widgets/raw/$SHA/docs/media/a.png" \
    "the correction must pin the published head"
  pass "an abbreviated commit id is refused with a pinned correction"
}

test_address_pointing_at_a_path_the_head_does_not_cite_fails_the_run() {
  local dir
  dir=$(new_case absent-path)
  private_row "$dir" yes
  status_row "$dir" "repos/$REPO/contents/docs/media/missing.png?ref=$SHA" 404
  body_case "$dir" '![First screen](https://github.com/tester/widgets/raw/'"$SHA"'/docs/media/missing.png)'
  run_case "$dir" --body-file "$dir/body.md" --head "$SHA"
  expect_code 1 "$CODE" "an address whose path is not in the published head must fail"
  assert_contains "$OUT" "contents=404" "the receipt must print the 404"
  assert_contains "$OUT" "absent from $SHA" "the refusal must name the head it checked"
  pass "an address pointing outside the published head fails"
}

test_relative_path_is_unverifiable_and_shows_the_pinned_form() {
  local dir
  dir=$(new_case relative-path)
  private_row "$dir" yes
  status_row "$dir" "repos/$REPO/contents/docs/media/a.png?ref=$SHA" 200
  body_case "$dir" '![First screen](docs/media/a.png)'
  run_case "$dir" --body-file "$dir/body.md" --head "$SHA"
  expect_code 1 "$CODE" "a relative path resolves against the default branch, so it must not pass"
  assert_contains "$OUT" "resolves against the repository default branch" \
    "the refusal must say why a relative path proves nothing"
  assert_contains "$OUT" "use: https://github.com/tester/widgets/raw/$SHA/docs/media/a.png" \
    "the correction must be the pinned address"
  pass "a relative media path is reported with the pinned address to use"
}

test_attachment_address_is_fetched_with_the_credential() {
  local dir pass_dir fail_dir
  dir=$(new_case asset)
  private_row "$dir" yes
  pass_dir=$dir
  status_row "$pass_dir" "https://github.com/user-attachments/assets/aaaabbbb-0000-1111-2222-333344445555" 200
  body_case "$pass_dir" '![First screen](https://github.com/user-attachments/assets/aaaabbbb-0000-1111-2222-333344445555)'
  run_case "$pass_dir" --body-file "$pass_dir/body.md" --head "$SHA"
  expect_code 0 "$CODE" "an uploaded attachment that the credential can read must pass"
  assert_contains "$OUT" "fetch=200" "the receipt must print the attachment code"

  fail_dir=$(new_case asset-404)
  private_row "$fail_dir" yes
  status_row "$fail_dir" "https://github.com/user-attachments/assets/eeeeeeee-0000-1111-2222-333344445555" 404
  body_case "$fail_dir" '![First screen](https://github.com/user-attachments/assets/eeeeeeee-0000-1111-2222-333344445555)'
  run_case "$fail_dir" --body-file "$fail_dir/body.md" --head "$SHA"
  expect_code 1 "$CODE" "an attachment the credential cannot read must fail"
  assert_contains "$OUT" "fetch=404" "the receipt must print the failed attachment code"
  pass "an attachment address is verified with the credential that uploaded it"
}

test_body_naming_evidence_without_addressing_it_fails() {
  local dir
  dir=$(new_case named-only)
  private_row "$dir" yes
  body_case "$dir" 'Proof: screenshots in data/screens/login-passed.png and data/screens/login-blocked.png'
  run_case "$dir" --body-file "$dir/body.md" --head "$SHA"
  expect_code 1 "$CODE" "naming evidence without an address is the failure this gate exists for"
  assert_contains "$OUT" "data/screens/login-passed.png" "the report must name the file it found"
  assert_contains "$OUT" "not evidence a reviewer can open" "the report must say what is wrong"
  assert_contains "$OUT" "RESULT: 0 address(es), 0 passed, 1 failed, 0 unchecked, 1 body-level failure(s)" \
    "the count must show the failure came from the body, not from a checked address"
  pass "a body that names media but addresses none of it fails"
}

test_body_without_media_passes_and_fails_only_when_embeds_are_required() {
  local dir
  dir=$(new_case no-media)
  private_row "$dir" yes
  body_case "$dir" 'Documentation-only change; see [the guide](docs/guide.md#section).'
  run_case "$dir" --body-file "$dir/body.md" --head "$SHA"
  expect_code 0 "$CODE" "a body with no media has nothing to fail"
  assert_contains "$OUT" "RESULT: 0 address(es), 0 passed, 0 failed" \
    "the receipt must still report what it counted"

  run_case "$dir" --body-file "$dir/body.md" --head "$SHA" --require-embeds
  expect_code 1 "$CODE" "--require-embeds must fail a body carrying no media address"
  assert_contains "$OUT" "REQUIRE-EMBEDS" "the failure must name the requirement it enforced"
  pass "an empty media body passes by default and fails under --require-embeds"
}

test_shape_only_reports_unchecked_and_still_refuses_an_unpinned_address() {
  local dir
  dir=$(new_case shape-only)
  body_case "$dir" '![First screen](https://raw.githubusercontent.com/tester/widgets/'"$SHA"'/docs/media/a.png)'
  run_case "$dir" --body-file "$dir/body.md" --head "$SHA" --shape-only
  expect_code 0 "$CODE" "offline mode must not invent a resolvability verdict"
  assert_contains "$OUT" "mode: --shape-only" "the receipt must say the run was offline"
  assert_contains "$OUT" "[unchecked]" "offline mode must classify what it could not judge"
  assert_not_contains "$OUT" "contents=200" "offline mode must not report a code it never read"

  body_case "$dir" '![First screen](https://github.com/user-attachments/assets/aaaabbbb-0000-1111-2222-333344445555)'
  run_case "$dir" --body-file "$dir/body.md" --head "$SHA" --shape-only
  expect_code 0 "$CODE" "an attachment address needs no verdict to be shape-valid"
  assert_contains "$OUT" "fetch not-checked" "offline mode must print that it fetched nothing"
  assert_contains "$OUT" "SHAPE-ONLY" "a shape pass must say it is not a green receipt"
  grep -q "repos/$REPO/contents" "$dir/asked" \
    && fail "--shape-only still asked the forge for a contents check: $(cat "$dir/asked")"

  body_case "$dir" '![First screen](docs/media/a.png)'
  run_case "$dir" --body-file "$dir/body.md" --head "$SHA" --shape-only
  expect_code 1 "$CODE" "a relative path fails on shape alone, with no network involved"
  pass "--shape-only skips the network without pretending to have passed it"
}

test_upload_refusal_is_reported_with_the_fallback() {
  local dir out err code
  dir=$(new_case attach)
  private_row "$dir" yes
  printf 'not a real png\n' >"$dir/shot.png"
  : >"$dir/asked"
  out=$(
    PATH="$dir/fakebin:$PATH" \
      FM_FAKE_GH_TABLE="$dir/table" \
      FM_FAKE_GH_ASKED="$dir/asked" \
      "$CMD" --repo "$REPO" --body-file "$dir/body.md" --head "$SHA" --attach "$dir/shot.png" 2>&1
  )
  code=$?
  expect_code 1 "$code" "an upload the forge refused cannot be reported as a pass"
  assert_contains "$out" "refused the upload of shot.png" "the refusal must name the file"
  assert_contains "$out" "raw/<full-sha>/<path>" "the refusal must point at the committed-media fallback"
  pass "a refused upload stops with the fallback named instead of a silent pass"
}

test_unreadable_inputs_refuse_with_exit_two() {
  local dir
  dir=$(new_case refuse-two)
  private_row "$dir" yes
  body_case "$dir" '![First screen](docs/media/a.png)'

  run_case "$dir" --body-file "$dir/body.md"
  expect_code 2 "$CODE" "a body without a head is not a published body and must refuse"
  assert_contains "$ERR" "--body-file needs --head" "the refusal must name the missing input"

  run_case "$dir" --body-file "$dir/body.md" --head 0123456
  expect_code 2 "$CODE" "a 7-character head cannot be the published head"
  assert_contains "$ERR" "full 40-character commit id" "the refusal must say what a head must be"
  pass "unreadable inputs refuse loudly rather than reporting a verdict"
}

test_pinned_raw_address_is_never_judged_by_a_published_web_fetch() {
  local dir
  dir=$(new_case no-web-fetch)
  private_row "$dir" yes
  status_row "$dir" "repos/$REPO/contents/docs/media/a.png?ref=$SHA" 200
  body_case "$dir" '![First screen](https://github.com/tester/widgets/raw/'"$SHA"'/docs/media/a.png)'
  run_case "$dir" --body-file "$dir/body.md" --head "$SHA"
  expect_code 0 "$CODE" "the address is good on the contents check"
  if grep -q "https://github.com/tester/widgets/raw/" "$dir/asked"; then
    fail "the command must verify a pinned address through the contents API, not by fetching the session-bound published URL that answers 404 to a token: $(cat "$dir/asked")"
  fi
  pass "the session-bound published-web form is not mistaken for a verdict"
}

test_pinned_raw_githubusercontent_address_passes_on_a_public_repository() {
  local dir
  dir=$(new_case raw-direct-public)
  private_row "$dir" no
  status_row "$dir" "repos/$REPO/contents/docs/media/a.png?ref=$SHA" 200
  body_case "$dir" '![First screen](https://raw.githubusercontent.com/tester/widgets/'"$SHA"'/docs/media/a.png)'
  run_case "$dir" --body-file "$dir/body.md" --head "$SHA"
  expect_code 0 "$CODE" "on a public repository the raw host resolves for a browser too"
  assert_contains "$OUT" "shape: raw-direct   ref=$SHA" "the receipt must still name the shape it read"
  pass "the private-repository refusal is not applied to a public one"
}

test_pinned_raw_githubusercontent_address_reports_both_reasons_once() {
  local dir
  dir=$(new_case raw-direct-abbrev)
  private_row "$dir" yes
  status_row "$dir" "repos/$REPO/contents/docs/media/a.png?ref=0123456" 200
  body_case "$dir" '![First screen](https://raw.githubusercontent.com/tester/widgets/0123456/docs/media/a.png)'
  run_case "$dir" --body-file "$dir/body.md" --head "$SHA"
  expect_code 1 "$CODE" "a prefix on the raw host must fail"
  assert_contains "$OUT" 'abbreviated commit id "0123456"' "the prefix must be named"
  assert_contains "$OUT" 'raw.githubusercontent.com answers the API token' \
    "both failing conditions on one address must be reported, not only the last"
  pass "one address reports all of what is wrong with it"
}

test_pinned_raw_githubusercontent_address_on_an_unknown_repository_is_not_a_pass_by_omission() {
  local dir
  dir=$(new_case raw-direct-unknown-private)
  status_row "$dir" "repos/$REPO/contents/docs/media/a.png?ref=$SHA" 200
  body_case "$dir" '![First screen](https://raw.githubusercontent.com/tester/widgets/'"$SHA"'/docs/media/a.png)'
  run_case "$dir" --body-file "$dir/body.md" --head "$SHA"
  expect_code 2 "$CODE" "not knowing whether the repository is private must stop the run, not pass it"
  assert_contains "$ERR" "could not read whether $REPO is private" \
    "the refusal must name the fact it could not establish"
  pass "an unreadable repository state refuses rather than passing"
}

test_pinned_raw_githubusercontent_address_rejects_a_moving_ref() {
  local dir
  dir=$(new_case raw-direct-ref)
  private_row "$dir" no
  status_row "$dir" "repos/$REPO/contents/docs/media/a.png?ref=main" 200
  body_case "$dir" '![First screen](https://raw.githubusercontent.com/tester/widgets/main/docs/media/a.png)'
  run_case "$dir" --body-file "$dir/body.md" --head "$SHA"
  expect_code 1 "$CODE" "an address at a branch is evidence that can vanish after the review"
  assert_contains "$OUT" 'moving ref "main"' "the refusal must name the ref"
  pass "an address at a moving ref is refused with the pinned correction"
}

test_pinned_raw_githubusercontent_address_reports_an_unexpected_code_as_unproven() {
  local dir
  dir=$(new_case raw-direct-500)
  private_row "$dir" yes
  status_row "$dir" "repos/$REPO/contents/docs/media/a.png?ref=$SHA" 500
  body_case "$dir" '![First screen](https://raw.githubusercontent.com/tester/widgets/'"$SHA"'/docs/media/a.png)'
  run_case "$dir" --body-file "$dir/body.md" --head "$SHA"
  expect_code 1 "$CODE" "a server error is not proof that a path lives in that commit"
  assert_contains "$OUT" "contents=500" "the receipt must print the code it read"
  assert_contains "$OUT" "does not prove the path is in that commit" \
    "a code that proves nothing must be reported as unproven, not as a pass"
  pass "a code that proves nothing fails instead of passing quietly"
}

test_pinned_raw_githubusercontent_address_survices_an_unanswerable_contents_check() {
  local dir
  dir=$(new_case raw-direct-err)
  private_row "$dir" yes
  status_row "$dir" "repos/$REPO/contents/docs/media/a.png?ref=$SHA" NONE
  body_case "$dir" '![First screen](https://raw.githubusercontent.com/tester/widgets/'"$SHA"'/docs/media/a.png)'
  run_case "$dir" --body-file "$dir/body.md" --head "$SHA"
  expect_code 1 "$CODE" "an address the forge would not answer cannot be reported as good"
  assert_contains "$OUT" "contents=ERR" "the receipt must print that the check could not be answered"
  assert_contains "$OUT" "unverified rather than good" "an unreadable check is never a pass"
  pass "an unanswerable contents check is reported as unverified, never as good"
}

test_pinned_raw_githubusercontent_address_with_a_fragment_is_checked_on_its_path() {
  local dir
  dir=$(new_case fragment)
  private_row "$dir" no
  status_row "$dir" "repos/$REPO/contents/docs/media/a.png?ref=$SHA" 200
  body_case "$dir" '![First screen](https://raw.githubusercontent.com/tester/widgets/'"$SHA"'/docs/media/a.png#frame=2)'
  run_case "$dir" --body-file "$dir/body.md" --head "$SHA"
  expect_code 0 "$CODE" "a fragment is navigation, not part of the path in a commit"
  pass "a fragment on a media address does not break its check"
}

test_pinned_raw_githubusercontent_address_ignores_a_documentation_link() {
  local dir
  dir=$(new_case docs-link-only)
  private_row "$dir" yes
  body_case "$dir" 'See [the guide](https://raw.githubusercontent.com/tester/widgets/'"$SHA"'/docs/guide.md) for details.'
  run_case "$dir" --body-file "$dir/body.md" --head "$SHA"
  expect_code 0 "$CODE" "a documentation link is not media and must not be checked as media"
  assert_contains "$OUT" "RESULT: 0 address(es)" "only media addresses may be counted"
  pass "an ordinary documentation link is not mistaken for media evidence"
}

test_pinned_raw_githubusercontent_address_covers_a_recording_and_a_blob_link() {
  local dir
  dir=$(new_case mixed-shapes)
  private_row "$dir" yes
  status_row "$dir" "repos/$REPO/contents/docs/media/clip.mp4?ref=$SHA" 200
  body_case "$dir" '![Recording](https://github.com/tester/widgets/raw/'"$SHA"'/docs/media/clip.mp4)

Watch it here: https://github.com/tester/widgets/blob/'"$SHA"'/docs/media/clip.mp4'
  run_case "$dir" --body-file "$dir/body.md" --head "$SHA"
  expect_code 0 "$CODE" "both published-web forms resolve, so the run is green"
  assert_contains "$OUT" "shape: web-raw" "the embed must be read as the raw form"
  assert_contains "$OUT" "shape: web-blob" "the bare link must be read as the blob form"
  assert_contains "$OUT" "a blob URL is a page" "the receipt must say a blob link is not an inline image"
  pass "both published-web media shapes are verified and labelled"
}

test_pinned_raw_githubusercontent_address_reports_every_address_it_found() {
  local dir
  dir=$(new_case one-green-one-broken)
  private_row "$dir" yes
  status_row "$dir" "repos/$REPO/contents/docs/media/a.png?ref=$SHA" 200
  status_row "$dir" "repos/$REPO/contents/docs/media/b.png?ref=$SHA" 404
  body_case "$dir" '![One](https://github.com/tester/widgets/raw/'"$SHA"'/docs/media/a.png)

![Two](https://raw.githubusercontent.com/tester/widgets/'"$SHA"'/docs/media/b.png)'
  run_case "$dir" --body-file "$dir/body.md" --head "$SHA"
  expect_code 1 "$CODE" "one broken address fails the whole body"
  assert_contains "$OUT" "RESULT: 2 address(es), 1 passed, 1 failed" \
    "the receipt must count both, so a green line cannot hide a broken one"
  pass "one broken address among good ones still fails the run"
}

test_pinned_raw_githubusercontent_address_refuses_an_unreadable_pull_request() {
  local dir err code
  dir=$(new_case live-pr-unreadable)
  private_row "$dir" yes
  FM_FAKE_GH_PRVIEW_FAIL=body
  export FM_FAKE_GH_PRVIEW_FAIL
  err=$(
    PATH="$dir/fakebin:$PATH" \
      FM_FAKE_GH_TABLE="$dir/table" \
      FM_FAKE_GH_ASKED="$dir/asked" \
      FM_FAKE_GH_PRVIEW_FAIL="$FM_FAKE_GH_PRVIEW_FAIL" \
      "$CMD" --repo "$REPO" 42 2>&1 >/dev/null
  )
  code=$?
  unset FM_FAKE_GH_PRVIEW_FAIL
  expect_code 2 "$code" "a pull request the forge would not answer cannot be verified"
  assert_contains "$err" "could not read the published body of PR 42" \
    "the refusal must name the pull request it could not read"
  pass "an unreadable pull request refuses rather than reporting a clean receipt"
}

test_live_pull_request_is_verified_at_the_head_the_forge_published() {
  local dir out code
  dir=$(new_case live-pr)
  private_row "$dir" yes
  status_row "$dir" "repos/$REPO/contents/docs/media/a.png?ref=$SHA" 200
  printf '![First screen](https://github.com/tester/widgets/raw/%s/docs/media/a.png)\n' "$SHA" \
    >"$dir/live-body"
  : >"$dir/asked"
  out=$(
    PATH="$dir/fakebin:$PATH" \
      FM_FAKE_GH_TABLE="$dir/table" \
      FM_FAKE_GH_ASKED="$dir/asked" \
      FM_FAKE_GH_BODY="$dir/live-body" \
      FM_FAKE_GH_META="$(printf 'https://github.com/tester/widgets/pull/7\t%s\twidgets\ttester' "$SHA")" \
      "$CMD" --repo "$REPO" 7 2>&1
  )
  code=$?
  expect_code 0 "$code" "the published body read from the forge is what gets verified"
  assert_contains "$out" "published head: $SHA" \
    "the receipt must name the head read from the forge, not a local branch"
  assert_contains "$out" "pull request: https://github.com/tester/widgets/pull/7" \
    "the receipt must name the pull request it read"
  grep -q "ref=$SHA" "$dir/asked" \
    || fail "the contents check must be answered at the published head: $(cat "$dir/asked")"
  assert_contains "$out" "contents=200" "the check the body's own address needs must be reported"
  pass "a live pull request is verified at the head the forge published"
}


test_pinned_raw_githubusercontent_address_rejects_a_body_file_that_is_not_readable() {
  local dir
  dir=$(new_case body-file-missing)
  private_row "$dir" yes
  run_case "$dir" --body-file "$dir/nope.md" --head "$SHA"
  expect_code 2 "$CODE" "a body file that cannot be read is not an empty body"
  assert_contains "$ERR" "no readable file" "the refusal must name the missing file"
  pass "a missing body file refuses rather than passing vacuously"
}

test_pinned_raw_githubusercontent_address_rejects_an_unnamed_flag() {
  local dir
  dir=$(new_case bad-flag)
  private_row "$dir" yes
  run_case "$dir" --nope --body-file "$dir/body.md" --head "$SHA"
  expect_code 2 "$CODE" "an unknown flag must refuse, not be ignored"
  pass "an unknown flag refuses"
}

test_pinned_raw_githubusercontent_address_reports_a_blob_url_as_a_page_not_an_image_once() {
  local dir
  dir=$(new_case blob-note-once)
  private_row "$dir" yes
  status_row "$dir" "repos/$REPO/contents/docs/media/clip.mp4?ref=$SHA" 200
  body_case "$dir" 'Watch it here: https://github.com/tester/widgets/blob/'"$SHA"'/docs/media/clip.mp4'
  run_case "$dir" --body-file "$dir/body.md" --head "$SHA"
  expect_code 0 "$CODE" "a blob link resolves, so the run is green"
  assert_contains "$OUT" "a blob URL is a page" "the receipt must say a blob link is not an inline image"
  pass "a blob link is verified and labelled for what a reviewer gets"
}

test_pinned_raw_githubusercontent_address_deduplicates_one_address_written_twice() {
  local dir
  dir=$(new_case deduped)
  private_row "$dir" yes
  status_row "$dir" "repos/$REPO/contents/docs/media/a.png?ref=$SHA" 200
  body_case "$dir" '![One](https://github.com/tester/widgets/raw/'"$SHA"'/docs/media/a.png)

Again, the same screen: https://github.com/tester/widgets/raw/'"$SHA"'/docs/media/a.png'
  run_case "$dir" --body-file "$dir/body.md" --head "$SHA"
  expect_code 0 "$CODE" "the same address written twice is one address"
  assert_contains "$OUT" "RESULT: 1 address(es), 1 passed, 0 failed" \
    "one address written twice must be counted and checked once"
  pass "one address written twice is checked once"
}

test_pinned_raw_githubusercontent_address_keeps_trailing_sentence_punctuation_out() {
  local dir
  dir=$(new_case punctuation)
  private_row "$dir" yes
  status_row "$dir" "repos/$REPO/contents/docs/media/a.png?ref=$SHA" 200
  body_case "$dir" 'Recording: https://github.com/tester/widgets/raw/'"$SHA"'/docs/media/a.png.'
  run_case "$dir" --body-file "$dir/body.md" --head "$SHA"
  expect_code 0 "$CODE" "a sentence-ending period is not part of an address"
  assert_contains "$OUT" "contents=200" "the address was checked at the path the body named"
  pass "a bare address keeps a sentence's punctuation out of the check"
}

test_pinned_raw_githubusercontent_address_still_counts_evidence_names_when_embeds_exist() {
  local dir
  dir=$(new_case names-with-address)
  private_row "$dir" yes
  status_row "$dir" "repos/$REPO/contents/docs/media/a.png?ref=$SHA" 200
  body_case "$dir" 'Stills are kept under docs/media as a.png; the reviewer copy is below.

![One](https://github.com/tester/widgets/raw/'"$SHA"'/docs/media/a.png)'
  run_case "$dir" --body-file "$dir/body.md" --head "$SHA"
  expect_code 0 "$CODE" "a body that does address its media passes on the address it wrote"
  assert_contains "$OUT" "RESULT: 1 address(es), 1 passed, 0 failed" \
    "a bare filename next to a real address must not become a second verdict"
  pass "an unaddressed name does not fail a body that did address its evidence"
}

test_pinned_raw_githubusercontent_address_requires_embeds_even_when_names_exist() {
  local dir
  dir=$(new_case require-embeds-with-names)
  private_row "$dir" yes
  body_case "$dir" 'Proof: screenshots in data/screens/login-passed.png'
  run_case "$dir" --body-file "$dir/body.md" --head "$SHA" --require-embeds
  expect_code 1 "$CODE" "--require-embeds must fail a body with no address even when it names files"
  assert_contains "$OUT" "REQUIRE-EMBEDS" "the requirement it enforced must be named"
  assert_contains "$OUT" "login-passed.png" "the names it found must still be reported"
  pass "--require-embeds fails a body that names evidence without addressing it"
}

test_pinned_raw_githubusercontent_address_ignores_a_relative_link_with_a_fragment() {
  local dir
  dir=$(new_case fragment-no-double)
  private_row "$dir" yes
  body_case "$dir" 'Compare [the sheet](docs/media/sheet.png#two).'
  run_case "$dir" --body-file "$dir/body.md" --head "$SHA"
  expect_code 1 "$CODE" "a relative media path fails on shape even when nothing was fetched"
  assert_contains "$OUT" "use: https://github.com/tester/widgets/raw/$SHA/docs/media/sheet.png" \
    "the correction must carry the path without its fragment"
  pass "a fragment is kept out of a relative path's correction too"
}

test_pinned_raw_githubusercontent_address_prints_every_verdict_when_all_are_bad() {
  local dir
  dir=$(new_case all-shapes-bad)
  private_row "$dir" yes
  body_case "$dir" '![One](docs/media/a.png)

![Two](https://raw.githubusercontent.com/tester/widgets/'"$SHA"'/docs/media/b.png)

![Three](https://github.com/tester/widgets/raw/0123456/docs/media/c.png)'
  run_case "$dir" --body-file "$dir/body.md" --head "$SHA"
  expect_code 1 "$CODE" "three unverifiable addresses must not collapse into one line"
  assert_contains "$OUT" "RESULT: 3 address(es), 0 passed, 3 failed" \
    "the receipt must report one verdict per address"
  pass "every failing address is reported"
}

test_pinned_raw_githubusercontent_address_refuses_when_forge_access_is_unknown_even_public() {
  local dir
  dir=$(new_case public-unknown)
  body_case "$dir" '![One](https://github.com/tester/widgets/raw/'"$SHA"'/docs/media/a.png)'
  status_row "$dir" "repos/$REPO/contents/docs/media/a.png?ref=$SHA" 200
  run_case "$dir" --body-file "$dir/body.md" --head "$SHA"
  expect_code 0 "$CODE" "a pinned address needs no knowledge of repository access to be proven"
  assert_contains "$OUT" "shape: web-raw" "the pinned form must still be identified"
  pass "a pinned address is proven without needing the repository's visibility"
}

test_pinned_raw_githubusercontent_address_reads_public_state_only_for_the_head_repository() {
  local dir
  dir=$(new_case other-repo-address)
  private_row "$dir" yes
  status_row "$dir" "repos/other/widgets/contents/docs/media/a.png?ref=$SHA" 200
  body_case "$dir" '![One](https://github.com/other/widgets/raw/'"$SHA"'/docs/media/a.png)'
  run_case "$dir" --body-file "$dir/body.md" --head "$SHA"
  expect_code 0 "$CODE" "a pinned address in another repository is proven on its own contents"
  assert_contains "$OUT" "contents=200" "the check must be answered against the repository named"
  pass "an address in another repository is checked where it points"
}

test_pinned_raw_githubusercontent_address_refuses_a_foreign_private_raw_address() {
  local dir
  dir=$(new_case other-repo-raw-private)
  private_row "$dir" yes
  printf 'PRIVATE repos/other/widgets true\n' >>"$dir/table"
  status_row "$dir" "repos/other/widgets/contents/docs/media/a.png?ref=$SHA" 200
  body_case "$dir" '![One](https://raw.githubusercontent.com/other/widgets/'"$SHA"'/docs/media/a.png)'
  run_case "$dir" --body-file "$dir/body.md" --head "$SHA"
  expect_code 1 "$CODE" "the raw host on someone else's private repository still cannot render"
  assert_contains "$OUT" "404 to a logged-in browser" "the refusal must name the browser"
  pass "repository access is read for the repository the address names"
}

test_pinned_raw_githubusercontent_address_reports_the_receipt_header() {
  local dir
  dir=$(new_case receipt-header)
  private_row "$dir" yes
  body_case "$dir" 'No media here.'
  run_case "$dir" --body-file "$dir/body.md" --head "$SHA"
  assert_contains "$OUT" "fm-pr-media receipt: $REPO" "the receipt must name what it checked"
  assert_contains "$OUT" "published head: $SHA" "the receipt must name the head it checked"
  assert_contains "$OUT" "media addresses found: 0" "the receipt must state its count"
  pass "the receipt says what was checked, at which head, and how much was found"
}

test_pull_request_head_published_from_a_fork_is_verified_in_the_fork() {
  local dir out code
  dir=$(new_case fork-head)
  printf 'PRIVATE repos/contributor/widgets true\n' >>"$dir/table"
  status_row "$dir" "repos/contributor/widgets/contents/docs/media/a.png?ref=$SHA" 200
  printf '![One](https://github.com/contributor/widgets/raw/%s/docs/media/a.png)\n' "$SHA" \
    >"$dir/live-body"
  : >"$dir/asked"
  out=$(
    PATH="$dir/fakebin:$PATH" \
      FM_FAKE_GH_TABLE="$dir/table" \
      FM_FAKE_GH_ASKED="$dir/asked" \
      FM_FAKE_GH_BODY="$dir/live-body" \
      FM_FAKE_GH_META="$(printf 'https://github.com/tester/widgets/pull/9\t%s\twidgets\tcontributor' "$SHA")" \
      "$CMD" --repo "$REPO" 9 2>&1
  )
  code=$?
  expect_code 0 "$code" "a pull request published from a fork is verified in the fork"
  assert_contains "$out" "fm-pr-media receipt: contributor/widgets" \
    "the receipt must name the head repository, where the reviewer's media lives"
  grep -q "repos/contributor/widgets/contents" "$dir/asked" \
    || fail "the contents check must be answered against the fork, not the base: $(cat "$dir/asked")"
  pass "a pull request head published from a fork is verified where it lives"
}


test_pinned_raw_address_at_the_published_head_passes
test_raw_githubusercontent_address_fails_on_a_private_repository
test_abbreviated_commit_is_refused_and_rewritten_to_the_published_head
test_address_pointing_at_a_path_the_head_does_not_cite_fails_the_run
test_relative_path_is_unverifiable_and_shows_the_pinned_form
test_attachment_address_is_fetched_with_the_credential
test_body_naming_evidence_without_addressing_it_fails
test_body_without_media_passes_and_fails_only_when_embeds_are_required
test_shape_only_reports_unchecked_and_still_refuses_an_unpinned_address
test_upload_refusal_is_reported_with_the_fallback
test_unreadable_inputs_refuse_with_exit_two
test_pinned_raw_address_is_never_judged_by_a_published_web_fetch
test_pinned_raw_githubusercontent_address_passes_on_a_public_repository
test_pinned_raw_githubusercontent_address_reports_both_reasons_once
test_pinned_raw_githubusercontent_address_on_an_unknown_repository_is_not_a_pass_by_omission
test_pinned_raw_githubusercontent_address_rejects_a_moving_ref
test_pinned_raw_githubusercontent_address_reports_an_unexpected_code_as_unproven
test_pinned_raw_githubusercontent_address_survices_an_unanswerable_contents_check
test_pinned_raw_githubusercontent_address_with_a_fragment_is_checked_on_its_path
test_pinned_raw_githubusercontent_address_ignores_a_documentation_link
test_pinned_raw_githubusercontent_address_covers_a_recording_and_a_blob_link
test_pinned_raw_githubusercontent_address_reports_every_address_it_found
test_pinned_raw_githubusercontent_address_refuses_an_unreadable_pull_request
test_live_pull_request_is_verified_at_the_head_the_forge_published
test_pinned_raw_githubusercontent_address_rejects_a_body_file_that_is_not_readable
test_pinned_raw_githubusercontent_address_rejects_an_unnamed_flag
test_pinned_raw_githubusercontent_address_reports_a_blob_url_as_a_page_not_an_image_once
test_pinned_raw_githubusercontent_address_deduplicates_one_address_written_twice
test_pinned_raw_githubusercontent_address_keeps_trailing_sentence_punctuation_out
test_pinned_raw_githubusercontent_address_still_counts_evidence_names_when_embeds_exist
test_pinned_raw_githubusercontent_address_requires_embeds_even_when_names_exist
test_pinned_raw_githubusercontent_address_ignores_a_relative_link_with_a_fragment
test_pinned_raw_githubusercontent_address_prints_every_verdict_when_all_are_bad
test_pinned_raw_githubusercontent_address_refuses_when_forge_access_is_unknown_even_public
test_pinned_raw_githubusercontent_address_reads_public_state_only_for_the_head_repository
test_pinned_raw_githubusercontent_address_refuses_a_foreign_private_raw_address
test_pinned_raw_githubusercontent_address_reports_the_receipt_header
test_pull_request_head_published_from_a_fork_is_verified_in_the_fork
