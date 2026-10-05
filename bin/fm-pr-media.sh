#!/usr/bin/env bash
# fm-pr-media.sh - verify every media address in a pull request's PUBLISHED body,
# at its PUBLISHED head, and print a receipt a done claim can be held to.
#
# Why this exists: a PR body can read correctly, pass every local-file check, and
# still show a reviewer broken images. Three distinct causes produced that in one
# day of fleet work, and each one is invisible to a check that only looks at the
# local copy or only asks the API whether a URL answers 200:
#   1. The body names evidence files but gives no address for any of them.
#   2. An address points at a path that does not exist at the head that was pushed.
#   3. An address uses a form that cannot resolve in a browser even though a token
#      gets 200 from it. `raw.githubusercontent.com/<owner>/<repo>/<sha>/<path>` is
#      that form on a private repository: the API token is not the reviewer's
#      session, and a logged-in browser gets 404 for the same string.
#
# WHAT IS VERIFIED, per address, by its shape:
#   Committed media addressed at a pinned commit - the only shapes whose address
#   stays true after the branch is deleted - is verified through the repository
#   contents API at the exact ref the address names. That is the token-honest
#   check: it asks whether the path exists in that commit, which is what the
#   reviewer's browser needs. Existing in the working branch or the local copy
#   proves nothing.
#     https://github.com/<owner>/<repo>/raw/<full-sha>/<path>  renders and plays in
#       a logged-in browser: the required shape for committed media.
#     https://github.com/<owner>/<repo>/blob/<full-sha>/<path>  a page, not an
#       image: acceptable for a recording a reviewer may open, never as `![..]`.
#     https://raw.githubusercontent.com/...  rejected on a private repository,
#       because a browser cannot resolve it whatever the token reports. The
#       correction printed is the `github.com/.../raw/...` form.
#     a relative path such as `docs/media/x.png`  rejected: on a pull-request body
#       a relative path resolves against the repository default branch, not this
#       head, so the only way to verify it at the head is to pin it.
#   An uploaded `user-attachments` asset is fetched with the same credential the
#   upload used. On a private repository an unauthenticated fetch returns 404 for
#   an asset that renders for every reviewer holding repository access, so a
#   token-less probe proves nothing in either direction and is not run.
#   Any other absolute address is fetched with that same credential and must
#   answer 2xx or 3xx.
#
# A direct fetch of the `github.com/.../raw/...` form is deliberately NOT a check:
# that endpoint hands a browser a session-bound redirect, so it answers 404 to an
# API token while rendering for a reviewer. Its path is proven through the contents
# API instead, and the receipt prints `direct=session-bound` rather than letting a
# reader think a 404 had been seen.
#
# Full commit ids only. A 7-character prefix is refused rather than resolved: it
# names whichever commit the forge disambiguates first, it cannot be checked at the
# address as written, and evidence quoted at a prefix cannot be re-fetched once
# another branch introduces the same prefix. The receipt prints the published-head
# form of the address as the drop-in correction.
#
# Exit codes are the contract, so a lane can gate on them:
#   0  every address in the body passed its check, and --require-embeds holds
#   1  at least one address failed its check, or --require-embeds found none, or
#      the body names media files while addressing none of them
#   2  usage error, a missing dependency, or the pull request or repository state
#      could not be read. Nothing is guessed: an unreadable check is a failure to
#      verify, never a pass.
#
# Usage:
#   bin/fm-pr-media.sh <PR> [--repo owner/repo] [--require-embeds] [--shape-only]
#   bin/fm-pr-media.sh --body-file FILE --head <full-sha> [--repo owner/repo]
#                      [--require-embeds] [--shape-only]
#   bin/fm-pr-media.sh <PR> [--repo owner/repo] --attach <file>
#
# Flags:
#   --repo owner/repo   the repository holding the pull request. Defaults to the
#                       repository of the current working directory's gh context.
#   --body-file FILE    verify this body instead of the live pull request's, for
#                       fixtures and dry runs. Needs --head and a repository: an
#                       unpinned body is not a published body.
#   --head <full-sha>   the published head to check against, overriding the read
#                       from the pull request. Must be 40 hex digits.
#   --require-embeds    fail when the body carries no media address. Use it whenever
#                       the PR claims visual evidence: without it a body with zero
#                       addresses passes, because most PRs carry none. Media file
#                       NAMES with no address fail either way, since claiming
#                       evidence by filename is cause 1 above.
#   --shape-only        verify address shapes and skip both network checks, for an
#                       offline dry run. Explicitly opt-in, and it prints
#                       `not-checked` where a verdict needs the network, so a lane
#                       cannot report a green receipt it did not earn.
#   --attach FILE       upload one file to the repository's user-attachments path
#                       and print its address plus a paste-ready markdown embed.
#                       One file per invocation, so a partial upload cannot be
#                       reported as a batch that succeeded. See the caveats below.
#   --help              this text.
#
# --attach caveats, both of which are auth- or egress-bound rather than bugs here:
#   The upload rides the gh credential, so on a private repository the returned
#   asset address is readable by that credential and by every account with
#   repository access, and by nobody else: it is verified through the same
#   credentialed fetch as any other asset address, and an unauthenticated probe of
#   it answers 404. Anyone handed the URL without access sees a dead link.
#   GitHub's uploads endpoint has answered this host's egress with 400 "Multipart
#   form data required" and 422 "Bad Size" for bodies from 4 bytes to 3 MB, so an
#   upload can be refused from a machine whose credential is fine. When it is,
#   commit the file to the branch and use the pinned
#   `github.com/<owner>/<repo>/raw/<full-sha>/<path>` form this command verifies;
#   the refusal is printed verbatim so the lane never has to guess which of the two
#   outcomes it hit.
#
# Reads the pull request with `gh` and never writes to it: this command reports, and
# the lane decides what to change.
set -u

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0" >&2
  exit 2
}

die() {
  printf 'fm-pr-media: %s\n' "$*" >&2
  exit 2
}

PR=''
REPO=''
BODY_FILE=''
HEAD=''
REQUIRE_EMBEDS=0
SHAPE_ONLY=0
ATTACH=''

while [ $# -gt 0 ]; do
  case "$1" in
    --repo|--body-file|--head|--attach)
      [ $# -ge 2 ] || usage
      case "$1" in
        --repo) REPO=$2 ;;
        --body-file) BODY_FILE=$2 ;;
        --head) HEAD=$2 ;;
        --attach) ATTACH=$2 ;;
      esac
      shift 2
      ;;
    --require-embeds)
      REQUIRE_EMBEDS=1
      shift
      ;;
    --shape-only)
      SHAPE_ONLY=1
      shift
      ;;
    -h|--help|-*)
      usage
      ;;
    *)
      [ -z "$PR" ] || usage
      PR=$1
      shift
      ;;
  esac
done

command -v gh >/dev/null 2>&1 || die "gh is required and was not found on PATH"

# The forge host the API calls ride, and the raw host belonging to it, so a
# GH_HOST installation is judged against the host its own addresses name.
WEB_HOST=${GH_HOST:-github.com}
case "$WEB_HOST" in
  github.com) RAW_HOST=raw.githubusercontent.com ;;
  *) RAW_HOST="raw.$WEB_HOST" ;;
esac

MEDIA_EXT='png|jpe?g|gif|webp|svg|bmp|avif|heic|tiff?|ico|mp4|mov|webm|m4v|avi|mkv'

resolve_repo() {
  local out
  [ -n "$REPO" ] && return 0
  out=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) \
    || die "no --repo given and the current directory is not inside a repository gh can resolve"
  [ -n "$out" ] || die "no --repo given and gh resolved no repository for the current directory"
  REPO=$out
}

# --- --attach: one file, one asset, printed address ------------------------------

do_attach() {
  local file=$1 base uploads response asset
  [ -f "$file" ] || die "--attach names no readable file: $file"
  resolve_repo
  case "$WEB_HOST" in
    github.com) uploads=https://uploads.github.com ;;
    *) uploads="https://uploads.$WEB_HOST" ;;
  esac
  base=${file##*/}
  response=$(gh api --method POST "$uploads/repos/$REPO/uploads?name=$base" \
    -F "file=@$file" 2>&1)
  asset=$(printf '%s\n' "$response" | sed -n 's/.*"asset_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
  if [ -z "$asset" ]; then
    printf 'fm-pr-media: %s refused the upload of %s\n' "$uploads" "$base" >&2
    printf '%s\n' "$response" >&2
    printf 'fm-pr-media: fall back to committed media at the head, addressed as https://%s/%s/raw/<full-sha>/<path>\n' \
      "$WEB_HOST" "$REPO" >&2
    return 1
  fi
  printf 'Uploaded %s\n%s\n\nPaste-ready embed:\n![%s](%s)\n' "$base" "$asset" "$base" "$asset"
  printf '\nThat address is bound to the credential that uploaded it: on a private repository it answers 404 to an unauthenticated fetch and renders for every account holding repository access. Run this command without --attach once the body carries it.\n'
}

if [ -n "$ATTACH" ]; then
  do_attach "$ATTACH" || exit 1
  exit 0
fi

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-media.XXXXXX") || die "could not make a work directory"
# shellcheck disable=SC2064
trap "rm -rf '$TMP_DIR'" EXIT INT TERM

# --- the body under verification -------------------------------------------------

PR_URL=''
PUBLISHED_HEAD=''
BODY="$TMP_DIR/body.md"

resolve_repo
HEAD_REPO=$REPO

if [ -n "$BODY_FILE" ]; then
  [ -f "$BODY_FILE" ] || die "--body-file names no readable file: $BODY_FILE"
  [ -n "$HEAD" ] || die "--body-file needs --head: an unpinned body is not a published body"
  cat "$BODY_FILE" >"$BODY"
else
  [ -n "$PR" ] || usage
  gh pr view "$PR" --repo "$REPO" --json body -q .body >"$BODY" 2>"$TMP_DIR/err" \
    || die "could not read the published body of PR $PR in $REPO: $(cat "$TMP_DIR/err")"
  meta=$(gh pr view "$PR" --repo "$REPO" \
    --json url,headRefOid,headRepository,headRepositoryOwner \
    -q '[.url, .headRefOid, (.headRepository.name // ""), (.headRepositoryOwner.login // "")] | @tsv' \
    2>"$TMP_DIR/err") \
    || die "could not read PR $PR in $REPO: $(cat "$TMP_DIR/err")"
  IFS=$'\t' read -r PR_URL PUBLISHED_HEAD HR_NAME HR_OWNER <<EOF
$meta
EOF
  [ -n "$PUBLISHED_HEAD" ] || die "PR $PR in $REPO reported no head commit"
  if [ -n "$HR_NAME" ] && [ -n "$HR_OWNER" ]; then
    # A pull request's published head lives in the head repository, which a fork PR
    # does not share with the base, so contents checks are answered there.
    HEAD_REPO="$HR_OWNER/$HR_NAME"
  fi
fi

[ -z "$HEAD" ] || PUBLISHED_HEAD=$HEAD
case "$PUBLISHED_HEAD" in
  '' | *[!0-9a-fA-F]*)
    die "the published head must be a full 40-character commit id, got: ${PUBLISHED_HEAD:-<none>}"
    ;;
esac
[ ${#PUBLISHED_HEAD} -eq 40 ] \
  || die "the published head must be a full 40-character commit id, got ${#PUBLISHED_HEAD} characters: $PUBLISHED_HEAD"
PUBLISHED_HEAD=$(printf '%s' "$PUBLISHED_HEAD" | tr 'A-F' 'a-f')

# --- extraction ------------------------------------------------------------------

# Trailing sentence punctuation is not part of an address; nothing else is
# rewritten, so the receipt quotes the body verbatim.
strip_sentence_punctuation() {
  local a=$1 trimmed=1
  while [ "$trimmed" -eq 1 ]; do
    trimmed=0
    case "${a: -1}" in
      . | , | ';' | ':' | '!' | '?' | "'" | '"')
        a=${a%"${a: -1}"}
        trimmed=1
        ;;
    esac
  done
  printf '%s\n' "$a"
}

# A target is media when it is embedded with `![..]`, carries a media extension, or
# sits on the attachment host. An ordinary documentation link is not media.
is_media_target() {  # <address>
  case "$1" in
    *user-attachments* | *private-user-*) return 0 ;;
  esac
  printf '%s\n' "$1" | LC_ALL=C grep -qE "\.($MEDIA_EXT)([?#]|$)"
}

# From a stream of candidate targets, print the ones that are media, with any
# sentence punctuation already off them, since "evidence.png." has to read as the
# same address as "evidence.png".
keep_media() {
  local u
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    u=$(strip_sentence_punctuation "$u")
    is_media_target "$u" && printf '%s\n' "$u"
  done
}

# Every media address exactly as written, in body order, deduplicated.
ADDRESSES="$TMP_DIR/addresses.txt"
{
  # Markdown embeds: whatever is embedded is media by definition. The target ends
  # at the first whitespace or closing paren, so a title is not part of it.
  LC_ALL=C grep -oE '!\[[^]]*\]\([^)[:space:]]+' "$BODY" | LC_ALL=C sed -e 's/^[^(]*(//' || true
  # Markdown links: only when the target itself reads as media.
  LC_ALL=C grep -oE '\[[^]]*\]\([^)[:space:]]+' "$BODY" | LC_ALL=C sed -e 's/^[^(]*(//' \
    | keep_media || true
  LC_ALL=C grep -oE '<img[^>]*src="[^"]+"' "$BODY" \
    | LC_ALL=C sed -e 's/.*src="//' -e 's/"$//' || true
  # A bare address standing outside any markup, which is how a recording is often
  # handed over: only a media extension or an attachment host makes it media.
  LC_ALL=C grep -oE 'https?://[^[:space:]<>()"'"'"'`,;]+' "$BODY" | keep_media || true
} | while IFS= read -r a; do
  [ -n "$a" ] || continue
  strip_sentence_punctuation "$a"
done | awk 'NF && !seen[$0]++' >"$ADDRESSES"

ADDR_COUNT=$(wc -l <"$ADDRESSES" | tr -d ' ')

# A body that claims evidence by filename while addressing none of it is cause 1,
# so the names are collected for the report even though they are not addresses.
NAMES="$TMP_DIR/names.txt"
LC_ALL=C grep -oE '[A-Za-z0-9_./@-]+\.(png|jpe?g|gif|webp|svg|bmp|avif|heic|mp4|mov|webm|m4v)' "$BODY" \
  | LC_ALL=C grep -v '//' >"$NAMES" || true

# --- verification ----------------------------------------------------------------

api_status() {  # <endpoint-or-absolute-url> -> 3-digit code, or ERR
  local target=$1 first code
  first=$(gh api -i "$target" 2>/dev/null | head -c 200) || true
  code=$(printf '%s\n' "$first" | head -n 1 | awk '{ print $2 }')
  case "$code" in
    [1-5][0-9][0-9]) printf '%s\n' "$code" ;;
    *) printf 'ERR\n' ;;
  esac
}

contents_status() {  # <owner/repo> <ref> <path>
  local repo=$1 ref=$2 path=$3 enc
  enc=$(printf '%s' "$path" | LC_ALL=C sed -e 's/ /%20/g' -e 's/#/%23/g' -e 's/?/%3F/g')
  api_status "repos/$repo/contents/$enc?ref=$ref"
}

# Whether the repository holding an address is private decides the raw-address
# verdict, so it is read per repository rather than assumed from the base. Prints
# `yes` or `no`, and nothing at all when the forge would not say, which the caller
# must treat as a refusal rather than a pass.
repo_is_private() {  # <owner/repo>
  local repo=$1 mark priv
  mark="$TMP_DIR/private.${repo//\//_}"
  if [ -f "$mark" ]; then
    cat "$mark"
    return 0
  fi
  priv=$(gh api "repos/$repo" --jq .private 2>/dev/null) || priv=''
  case "$priv" in
    true) printf 'yes\n' >"$mark" ;;
    false) printf 'no\n' >"$mark" ;;
    *) return 1 ;;
  esac
  cat "$mark"
}

TOTAL=$ADDR_COUNT
PASSED=0
FAILED=0
UNCHECKED=0
GATE=0
RECEIPT=''
REASON=''

# Every failing condition on an address is reported, never only the last one, so a
# reader sees all of what to fix in one pass.
add_reason() {
  if [ -z "$REASON" ]; then
    REASON=$1
  else
    REASON="$REASON; $1"
  fi
}

record() {  # <ok|fail|unchecked> <address> <detail...>
  local verdict=$1 addr=$2 detail
  shift 2
  case "$verdict" in
    ok) PASSED=$((PASSED + 1)) ;;
    fail) FAILED=$((FAILED + 1)) ;;
    unchecked) UNCHECKED=$((UNCHECKED + 1)) ;;
  esac
  RECEIPT="$RECEIPT$(printf '[%s] %s' "$verdict" "$addr")"$'\n'
  for detail in "$@"; do
    RECEIPT="$RECEIPT    $detail"$'\n'
  done
}

# An abbreviated commit id or a moving ref is corrected to the same path pinned at
# the published head, which is the one address this run can actually verify.
pin_at_head() {  # <owner/repo> <path>
  printf 'https://%s/%s/raw/%s/%s\n' "$WEB_HOST" "$1" "$PUBLISHED_HEAD" "$2"
}

check_address() {  # <address>
  local addr=$1 host rest shape='' owner repo ref path tail codes verdict access fix

  case "$addr" in
    *://*) ;;
    *) shape=relative ;;
  esac

  if [ -z "$shape" ]; then
    host=${addr#*://}
    rest=${host#*/}
    host=${host%%/*}
    case "$addr" in
      *user-attachments* | *private-user-*)
        shape=asset
        ;;
      *://"$RAW_HOST"/*)
        shape=raw-direct
        owner=${rest%%/*}
        rest=${rest#*/}
        repo=${rest%%/*}
        rest=${rest#*/}
        ref=${rest%%/*}
        path=${rest#*/}
        ;;
      *://"$WEB_HOST"/*)
        owner=${rest%%/*}
        rest=${rest#*/}
        repo=${rest%%/*}
        tail=${rest#*/}
        case "$tail" in
          raw/*)
            shape=web-raw
            ref=${tail#raw/}
            path=${ref#*/}
            ref=${ref%%/*}
            ;;
          blob/*)
            shape=web-blob
            ref=${tail#blob/}
            path=${ref#*/}
            ref=${ref%%/*}
            ;;
          *)
            shape=web-other
            ;;
        esac
        ;;
      *)
        shape=remote
        ;;
    esac
  fi

  case "$shape" in
    asset | remote | web-other)
      if [ "$SHAPE_ONLY" -eq 1 ]; then
        record unchecked "$addr" "shape: $shape - fetch not-checked (--shape-only skips the network)"
        return 0
      fi
      codes=$(api_status "$addr")
      case "$codes" in
        2?? | 3??)
          record ok "$addr" "shape: $shape   fetch=$codes"
          ;;
        *)
          record fail "$addr" "shape: $shape   fetch=$codes - the address does not resolve for a reviewer"
          ;;
      esac
      return 0
      ;;
  esac

  # Every shape left names a path in a repository, so the honest check is the
  # contents API at the ref the address itself names.
  if [ "$shape" = relative ]; then
    path=${addr#/}
    owner=${HEAD_REPO%%/*}
    repo=${HEAD_REPO#*/}
    ref=$PUBLISHED_HEAD
  fi

  # A fragment or query is navigation, not part of the path in a commit.
  path=${path%%\#*}
  path=${path%%\?*}

  if [ "$SHAPE_ONLY" -eq 1 ]; then
    codes='contents=not-checked   direct=not-checked'
  else
    codes="contents=$(contents_status "$owner/$repo" "$ref" "$path")   direct=session-bound"
  fi

  verdict=ok
  REASON=''
  case "$ref" in
    '')
      verdict=fail
      add_reason 'no commit could be read from the address'
      ;;
    *[!0-9a-fA-F]*)
      verdict=fail
      add_reason "it names the moving ref \"$ref\" instead of a commit, so the evidence can change or vanish after the review"
      ;;
    *)
      if [ ${#ref} -lt 40 ]; then
        verdict=fail
        add_reason "it pins the abbreviated commit id \"$ref\"; a prefix is not an address a reader can re-fetch"
      fi
      ;;
  esac

  if [ "$shape" = relative ]; then
    verdict=fail
    add_reason 'a relative path on a pull-request body resolves against the repository default branch, not this head'
  fi

  if [ "$shape" = raw-direct ]; then
    if [ "$SHAPE_ONLY" -eq 1 ]; then
      # Whether this form can render depends on the repository being private, and
      # that is a fact only the forge has, so offline mode owns no verdict here.
      record unchecked "$addr" "shape: raw-direct - whether a browser can resolve it depends on repository access, which --shape-only does not read"
      return 0
    fi
    access=$(repo_is_private "$owner/$repo") || access=''
    [ -n "$access" ] \
      || die "could not read whether $owner/$repo is private, which the raw-address verdict depends on"
    if [ "$access" = yes ]; then
      verdict=fail
      add_reason 'raw.githubusercontent.com answers the API token but returns 404 to a logged-in browser on a private repository'
    fi
  fi

  if [ "$SHAPE_ONLY" -eq 0 ]; then
    case "$codes" in
      *contents=2??* | *contents=3??*) ;;
      *contents=404*)
        verdict=fail
        add_reason "the path is absent from $ref, so the address points at something the published head does not contain"
        ;;
      *contents=ERR*)
        verdict=fail
        add_reason 'the contents check could not be answered, so the address is unverified rather than good'
        ;;
      *)
        verdict=fail
        add_reason 'the contents check came back with a code that does not prove the path is in that commit'
        ;;
    esac
  fi

  fix=$(pin_at_head "$owner/$repo" "$path")
  if [ "$verdict" = ok ]; then
    case "$shape" in
      web-blob) record ok "$addr" "shape: $shape   ref=$ref   $codes   note: a blob URL is a page, so it is a link a reviewer opens, never an inline image" ;;
      *) record ok "$addr" "shape: $shape   ref=$ref   $codes" ;;
    esac
    return 0
  fi
  [ -n "$REASON" ] || REASON='the check above failed'
  if [ "$fix" = "$addr" ]; then
    record fail "$addr" "shape: $shape   ref=$ref   $codes" "why: $REASON" "keep the address and re-check it once the head carries the file"
  else
    record fail "$addr" "shape: $shape   ref=$ref   $codes" "why: $REASON" "use: $fix"
  fi
}

while IFS= read -r addr; do
  check_address "$addr"
done <"$ADDRESSES"

# --- receipt ---------------------------------------------------------------------

printf 'fm-pr-media receipt: %s\n' "$HEAD_REPO"
if [ -n "$PR_URL" ]; then
  printf '  pull request: %s\n' "$PR_URL"
else
  printf '  pull request: body read from %s\n' "$BODY_FILE"
fi
printf '  published head: %s\n' "$PUBLISHED_HEAD"
if [ "$SHAPE_ONLY" -eq 1 ]; then
  printf '  mode: --shape-only, so resolvability was not checked for any address\n'
fi
printf '  media addresses found: %s\n\n' "$ADDR_COUNT"

[ -n "$RECEIPT" ] && printf '%s\n' "$RECEIPT"

if [ "$ADDR_COUNT" -eq 0 ]; then
  NAME_COUNT=$(LC_ALL=C sort -u "$NAMES" | grep -c . || true)
  if [ "$NAME_COUNT" -gt 0 ]; then
    printf 'No media address appears in the body, but %s media file name(s) do:\n' "$NAME_COUNT"
    LC_ALL=C sort -u "$NAMES" | sed 's/^/    /'
    printf '\nEvidence named by filename is not evidence a reviewer can open: commit it and address it at the head, or upload it and embed the returned address.\n'
    FAILED=$((FAILED + 1))
    GATE=$((GATE + 1))
  fi
  if [ "$REQUIRE_EMBEDS" -eq 1 ]; then
    printf 'REQUIRE-EMBEDS: the body claims visual evidence but carries no media address.\n'
    FAILED=$((FAILED + 1))
    GATE=$((GATE + 1))
  fi
fi

printf 'RESULT: %s address(es), %s passed, %s failed, %s unchecked' \
  "$TOTAL" "$PASSED" "$FAILED" "$UNCHECKED"
[ "$GATE" -eq 0 ] || printf ', %s body-level failure(s)' "$GATE"
printf '\n'
if [ "$SHAPE_ONLY" -eq 1 ]; then
  printf 'SHAPE-ONLY: no address was fetched or looked up in a commit, so this is a shape pass, not a green receipt.\n'
fi
[ "$FAILED" -eq 0 ] || exit 1
exit 0
