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
#   Other absolute addresses are fetched without credentials and must answer
#   a final 2xx after at most five HTTPS redirects. Their addresses are redacted
#   in the receipt. Image positions require image media, including extensionless
#   attachments, checked from fetched bytes rather than the filename.
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
#   bin/fm-pr-media.sh <PR> [--repo owner/repo] [--require-embeds]
#   bin/fm-pr-media.sh <PR> --body-file FILE [--repo owner/repo]
#                      [--require-embeds]
#
# Flags:
#   --repo owner/repo   the repository holding the pull request. Defaults to gh's
#                       current repository context.
#   --body-file FILE    read a fixture body, while still reading the PR head from
#                       the forge. Requires a PR and repository context.
#   --require-embeds    fail when a task owes visual evidence but the body has no
#                       rendered media address. Unaddressed media filenames also
#                       fail when no addresses exist, even without this flag.
#   --help              this text.
#
# Requires gh, python3, and curl. Markdown targets come from the forge's GFM
# renderer; code and comments are excluded from the rendered HTML evidence.
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
REQUIRE_EMBEDS=0

while [ $# -gt 0 ]; do
  case "$1" in
    --repo|--body-file)
      [ $# -ge 2 ] || usage
      case "$1" in
        --repo) REPO=$2 ;;
        --body-file) BODY_FILE=$2 ;;
      esac
      shift 2
      ;;
    --require-embeds)
      REQUIRE_EMBEDS=1
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

for dependency in gh python3 curl; do
  command -v "$dependency" >/dev/null 2>&1 || die "$dependency is required and was not found on PATH"
done

# The forge host the API calls ride, and the raw host belonging to it, so a
# GH_HOST installation is judged against the host its own addresses name.
WEB_HOST=${GH_HOST:-github.com}
case "$WEB_HOST" in
  github.com) RAW_HOST=raw.githubusercontent.com ;;
  *) RAW_HOST="raw.$WEB_HOST" ;;
esac

resolve_repo() {
  local out
  [ -n "$REPO" ] && return 0
  out=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) \
    || die "no --repo given and the current directory is not inside a repository gh can resolve"
  [ -n "$out" ] || die "no --repo given and gh resolved no repository for the current directory"
  REPO=$out
}

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-media.XXXXXX") || die "could not make a work directory"
# shellcheck disable=SC2064
trap "rm -rf '$TMP_DIR'" EXIT INT TERM

# --- the body under verification -------------------------------------------------

PR_URL=''
BODY="$TMP_DIR/body.md"

resolve_repo
HEAD_REPO=$REPO

[ -n "$PR" ] || usage
if [ -n "$BODY_FILE" ]; then
  [ -f "$BODY_FILE" ] || die "--body-file names no readable file: $BODY_FILE"
  cat "$BODY_FILE" >"$BODY"
else
  gh pr view "$PR" --repo "$REPO" --json body -q .body >"$BODY" 2>"$TMP_DIR/err" \
    || die "could not read the published body of PR $PR in $REPO: $(cat "$TMP_DIR/err")"
fi
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
  HEAD_REPO="$HR_OWNER/$HR_NAME"
fi

case "$PUBLISHED_HEAD" in
  '' | *[!0-9a-fA-F]*)
    die "the published head must be a full 40-character commit id, got: ${PUBLISHED_HEAD:-<none>}"
    ;;
esac
[ ${#PUBLISHED_HEAD} -eq 40 ] \
  || die "the published head must be a full 40-character commit id, got ${#PUBLISHED_HEAD} characters: $PUBLISHED_HEAD"
PUBLISHED_HEAD=$(printf '%s' "$PUBLISHED_HEAD" | tr 'A-F' 'a-f')

# --- extraction ------------------------------------------------------------------

ADDRESSES="$TMP_DIR/addresses.txt"
NAMES="$TMP_DIR/names.txt"
gh api markdown --method POST -f mode=gfm -f "context=$REPO" -F "text=@$BODY" \
  >"$TMP_DIR/rendered.html" 2>"$TMP_DIR/err" \
  || die "could not render the pull-request body: $(cat "$TMP_DIR/err")"
python3 - "$TMP_DIR/rendered.html" "$ADDRESSES" "$NAMES" "$WEB_HOST" <<'PYTHON' \
  || die "could not extract rendered media targets"
import re
import sys
from html.parser import HTMLParser
from urllib.parse import urlsplit

media = re.compile(r"\.(png|jpe?g|gif|webp|svg|bmp|avif|heic|tiff?|ico|mp4|mov|webm|m4v|avi|mkv)(?:[?#]|$)", re.I)

class Evidence(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.excluded = []
        self.targets = {}
        self.text = []

    def handle_starttag(self, tag, attrs):
        if tag in ('pre', 'code', 'script', 'style'):
            self.excluded.append(tag)
        if self.excluded:
            return
        attrs = dict(attrs)
        context = 'image' if tag == 'img' else 'link'
        target = (attrs.get('data-canonical-src') or attrs.get('src')) if tag in ('img', 'video', 'source') else attrs.get('href') if tag == 'a' else None
        if not target:
            return
        parts = urlsplit(target)
        if parts.username is not None or parts.password is not None:
            raise ValueError('media target contains URL credentials')
        asset = parts.hostname == sys.argv[4] and parts.path.startswith('/user-attachments/')
        if context != 'image' and not (media.search(target) or asset or tag in ('video', 'source')):
            return
        if any(c in target for c in '\t\r\n'):
            raise ValueError('media target contains a control character')
        if target not in self.targets or context == 'image':
            self.targets[target] = context

    def handle_endtag(self, tag):
        if self.excluded and self.excluded[-1] == tag:
            self.excluded.pop()

    def handle_data(self, data):
        if not self.excluded:
            self.text.append(data)

parser = Evidence()
with open(sys.argv[1]) as source:
    parser.feed(source.read())
with open(sys.argv[2], 'w') as output:
    for target, context in parser.targets.items():
        output.write(f'{context}\t{target}\n')
with open(sys.argv[3], 'w') as output:
    for name in re.findall(r'[A-Za-z0-9_./@-]+\.(?:png|jpe?g|gif|webp|svg|bmp|avif|heic|mp4|mov|webm|m4v)\b', ' '.join(parser.text)):
        output.write(name + '\n')
PYTHON
ADDR_COUNT=$(wc -l <"$ADDRESSES" | tr -d ' ')

# --- verification ----------------------------------------------------------------

authenticated_target() {
  case "$1" in
    repos/* | https://github.com/* | https://raw.githubusercontent.com/* | https://"${GH_HOST:-api.github.com}"/*) return 0 ;;
    *) return 1 ;;
  esac
}

api_status() {  # <endpoint-or-absolute-url> [image] -> 3-digit code, or ERR
  local target=$1 context=${2:-link} code
  : >"$TMP_DIR/media-body"
  if ! authenticated_target "$target"; then
    code=$(curl --disable --silent --output "$TMP_DIR/media-body" --write-out '%{http_code}' \
      --location --max-redirs 5 --max-time 30 --proto '=https' --proto-redir '=https' \
      -- "$target") || code=ERR
    printf '%s\n' "$code"
    return 0
  fi
  if [ "$context" = image ] && [[ "$target" = repos/*/contents/* ]]; then
    gh api -i -H 'Accept: application/vnd.github.raw+json' "$target" >"$TMP_DIR/response" 2>/dev/null || true
  else
    gh api -i "$target" >"$TMP_DIR/response" 2>/dev/null || true
  fi
  python3 - "$TMP_DIR/response" "$TMP_DIR/media-body" <<'PYTHON'
import re
import sys
from pathlib import Path
response = Path(sys.argv[1]).read_bytes()
parts = re.split(rb'\r?\n\r?\n', response, maxsplit=1)
header = parts[0]
body = parts[1] if len(parts) == 2 else b''
match = re.match(rb'HTTP/\S+ ([1-5][0-9][0-9])', header)
Path(sys.argv[2]).write_bytes(body)
print(match[1].decode() if match and len(parts) == 2 else 'ERR')
PYTHON
}

is_image_media() {
  python3 - "$TMP_DIR/media-body" <<'PYTHON'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
body = Path(sys.argv[1]).read_bytes()
image = body.startswith((b'\x89PNG\r\n\x1a\n', b'\xff\xd8\xff', b'GIF87a', b'GIF89a', b'BM', b'II*\x00', b'MM\x00*', b'\x00\x00\x01\x00'))
image |= body[:4] == b'RIFF' and body[8:12] == b'WEBP'
image |= body[4:8] == b'ftyp' and body[8:12] in (b'avif', b'avis', b'heic', b'heix', b'hevc', b'hevx', b'mif1', b'msf1')
if not image:
    try:
        image = ET.fromstring(body).tag in ('svg', '{http://www.w3.org/2000/svg}svg')
    except ET.ParseError:
        pass
sys.exit(0 if image else 1)
PYTHON
}

contents_status() {  # <owner/repo> <ref> <path> [image]
  local repo=$1 ref=$2 path=$3 context=${4:-link} enc
  enc=$(printf '%s' "$path" | LC_ALL=C sed -e 's/ /%20/g' -e 's/#/%23/g' -e 's/?/%3F/g')
  api_status "repos/$repo/contents/$enc?ref=$ref" "$context"
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

record() {  # <ok|fail> <address> <detail...>
  local verdict=$1 addr=$2 detail
  shift 2
  case "$addr" in
    *://*) authenticated_target "$addr" || addr='https://[external-host]/[redacted]' ;;
  esac
  case "$verdict" in
    ok) PASSED=$((PASSED + 1)) ;;
    fail) FAILED=$((FAILED + 1)) ;;
  esac
  RECEIPT="$RECEIPT$(printf '[%s] %s' "$verdict" "$addr")"$'\n'
  for detail in "$@"; do
    RECEIPT="$RECEIPT    $detail"$'\n'
  done
}

# An abbreviated commit id or a moving ref is corrected to the same path pinned at
# the published head, which is the one address this run can actually verify.
pin_at_head() {  # <owner/repo> <path>
  [ "$1" = "$HEAD_REPO" ] || return 0
  printf 'https://%s/%s/raw/%s/%s\n' "$WEB_HOST" "$1" "$PUBLISHED_HEAD" "$2"
}

check_address() {  # <address>
  local addr=$1 context=$2 host rest shape='' owner repo ref path tail codes verdict access fix image_mismatch=0

  case "$addr" in
    *://*) ;;
    *) shape=relative ;;
  esac

  if [ -z "$shape" ]; then
    host=${addr#*://}
    rest=${host#*/}
    host=${host%%/*}
    case "$addr" in
      https://"$WEB_HOST"/user-attachments/*)
        shape=asset
        ;;
      https://"$RAW_HOST"/*)
        shape=raw-direct
        owner=${rest%%/*}
        rest=${rest#*/}
        repo=${rest%%/*}
        rest=${rest#*/}
        ref=${rest%%/*}
        path=${rest#*/}
        ;;
      https://"$WEB_HOST"/*)
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
      codes=$(api_status "$addr" "$context")
      if [ "$context" = image ]; then
        case "$addr" in
          https://github.com/*/*/blob/*)
            record fail "$addr" "a blob URL is an HTML page and cannot render in an image position; use a raw image address"
            return 0
            ;;
        esac
      fi
      if [ "$context" = image ] && printf '%s\n' "$1" | LC_ALL=C grep -qiE '\.(mp4|mov|webm|m4v|avi|mkv)([?#]|$)'; then
        record fail "$addr" "a recording cannot render in an image position; use a recording link"
        return 0
      fi
      case "$codes" in
        2??)
          if [ "$context" = image ] && ! is_image_media; then
            record fail "$addr" "shape: $shape   fetch=$codes" "the fetched media is not an image; use a recording link for video media"
            return 0
          fi
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

  codes="contents=$(contents_status "$owner/$repo" "$ref" "$path" "$context")   direct=session-bound"

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
      if [ ${#ref} -ne 40 ]; then
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
    access=$(repo_is_private "$owner/$repo") || access=''
    [ -n "$access" ] \
      || die "could not read whether $owner/$repo is private, which the raw-address verdict depends on"
    if [ "$access" = yes ]; then
      verdict=fail
      add_reason 'raw.githubusercontent.com answers the API token but returns 404 to a logged-in browser on a private repository'
    fi
  fi

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

  if [ "$context" = image ]; then
    if [ "$verdict" = ok ] && ! is_image_media; then
      verdict=fail
      image_mismatch=1
      add_reason "the fetched repository media is not an image; use a recording link for video media"
    fi
    if [ "$shape" = web-blob ]; then
      verdict=fail
      add_reason "a blob URL is an HTML page and cannot render in an image position"
    fi
    if printf '%s\n' "$path" | LC_ALL=C grep -qiE '\.(mp4|mov|webm|m4v|avi|mkv)$'; then
      verdict=fail
      image_mismatch=1
      add_reason "a recording cannot render in an image position; use a recording link"
    fi
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
  if [ -z "$fix" ]; then
    record fail "$addr" "shape: $shape   ref=$ref   $codes" "why: $REASON" "use a valid full commit and path from the address's own repository"
  elif [ "$image_mismatch" -eq 1 ]; then
    record fail "$addr" "shape: $shape   ref=$ref   $codes" "why: $REASON" "use a recording link instead of an image embed"
  elif [ "$fix" = "$addr" ]; then
    record fail "$addr" "shape: $shape   ref=$ref   $codes" "why: $REASON" "keep the address and re-check it once the head carries the file"
  else
    record fail "$addr" "shape: $shape   ref=$ref   $codes" "why: $REASON" "use: $fix"
  fi
}

while IFS=$'\t' read -r context addr; do
  check_address "$addr" "$context"
done <"$ADDRESSES"

# --- receipt ---------------------------------------------------------------------

printf 'fm-pr-media receipt: %s\n' "$HEAD_REPO"
if [ -n "$PR_URL" ]; then
  printf '  pull request: %s\n' "$PR_URL"
else
  printf '  pull request: body read from %s\n' "$BODY_FILE"
fi
printf '  published head: %s\n' "$PUBLISHED_HEAD"
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

printf 'RESULT: %s address(es), %s passed, %s failed' \
  "$TOTAL" "$PASSED" "$FAILED"
[ "$GATE" -eq 0 ] || printf ', %s body-level failure(s)' "$GATE"
printf '\n'
[ "$FAILED" -eq 0 ] || exit 1
exit 0
