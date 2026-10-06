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
#       a logged-in browser: the required raw shape for private committed media.
#     https://github.com/<owner>/<repo>/blob/<full-sha>/<path>  a page, not an
#       image: acceptable for a recording a reviewer may open, never as `![..]`.
#     https://raw.githubusercontent.com/...  rejected on a private repository,
#       because a browser cannot resolve it whatever the token reports. The
#       correction printed is the `github.com/.../raw/...` form.
#       Public repositories may use a pinned raw.githubusercontent.com address.
#     a relative path such as `docs/media/x.png`  rejected: on a pull-request body
#       a relative path resolves against the repository default branch, not this
#       head, so the only way to verify it at the head is to pin it.
#   A `user-attachments` asset on the configured forge host is fetched with the
#   current gh credential for that host. On a private repository an unauthenticated
#   fetch returns 404 for an asset that renders for reviewers holding repository access, so a
#   token-less probe proves nothing in either direction and is not run.
#   Redirects to another origin never receive the Authorization header.
#   An incomplete transfer is unverified even when it started with HTTP 200.
#   Other absolute addresses are fetched without credentials and must answer
#   a final 2xx after at most five HTTPS redirects. Their addresses are redacted
#   in the receipt. Image positions require image media, including extensionless
#   attachments, checked from fetched bytes rather than the filename.
#   All rendered img and picture source srcset candidates are checked as images.
#   Fetched bodies must meet Content-Length when declared. PNG, JPEG, and GIF
#   require their closing IEND, end-of-image, and trailer markers respectively.
#   Recording bytes must match the container claimed by the address and response
#   Content-Type when it identifies a supported recording container.
#   Recordings require at least 1024 bytes and a leading ISO file type box
#   followed by a moov or mdat box for mp4/mov, a leading EBML marker for webm/mkv,
#   or a complete first RIFF/AVI container with an AVI LIST chunk for avi.
#   ISO boxes and RIFF chunks are walked by declared size, including padding;
#   ISO brands are unrestricted, and AVI may have OpenDML continuation containers.
#   These container checks reject truncation and disguised text;
#   they do not prove codec decoding.
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
# another branch introduces the same prefix. For this PR's head repository, the
# receipt prints the published-head form as the correction. For another repository,
# it asks for a valid full commit and path from that repository instead.
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
  cat "$BODY_FILE" >"$BODY" || die "could not read --body-file: $BODY_FILE"
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
        if target:
            self.add_target(target, context, tag)
        if tag in ('img', 'source'):
            # HTML srcset collects a non-space URL, then descriptors until the
            # next comma. Commas within a URL (e.g. a data URL) stay in the URL.
            remaining = attrs.get('srcset', '')
            while remaining:
                remaining = remaining.lstrip(' \t\r\n\f,')
                candidate = re.match(r'[^ \t\r\n\f]+', remaining)
                if not candidate:
                    break
                url = candidate[0]
                remaining = remaining[len(url):]
                if url.endswith(','):
                    url = url.rstrip(',')
                else:
                    _, separator, remaining = remaining.partition(',')
                    if not separator:
                        remaining = ''
                if url:
                    self.add_target(url, 'image', tag)

    def add_target(self, target, context, tag):
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

api_status() {  # <endpoint-or-absolute-url> -> 3-digit code, or ERR
  local target=$1 code host token=''
  local -a headers=()
  : >"$TMP_DIR/media-body"
  : >"$TMP_DIR/media-headers"
  if authenticated_target "$target"; then
    case "$target" in
      repos/*)
        if [ "$WEB_HOST" = github.com ]; then
          target="https://api.github.com/$target"
        else
          target="https://$WEB_HOST/api/v3/$target"
        fi
        host=$WEB_HOST
        ;;
      https://github.com/* | https://raw.githubusercontent.com/* | https://api.github.com/*)
        host=github.com
        ;;
      *) host=$WEB_HOST ;;
    esac
    token=$(gh auth token --hostname "$host" 2>/dev/null) || {
      printf 'ERR\n'
      return 0
    }
    [ -n "$token" ] || { printf 'ERR\n'; return 0; }
    headers=(--header @-)
  fi
  if [[ "$target" = */repos/*/contents/* ]]; then
    headers+=(--header 'Accept: application/vnd.github.raw+json')
  fi
  code=$( { [ -z "$token" ] || printf 'Authorization: Bearer %s\n' "$token"; } | \
    curl --disable --silent --output "$TMP_DIR/media-body" --dump-header "$TMP_DIR/media-headers" --write-out '%{http_code}' \
      --location --max-redirs 5 --max-time 30 --proto '=https' --proto-redir '=https' \
      "${headers[@]}" -- "$target") || code=ERR
  printf '%s\n' "$code"
}

media_error() {  # <image|link> <address> -> empty on success, otherwise reason
  python3 - "$TMP_DIR/media-body" "$TMP_DIR/media-headers" "$1" "$2" <<'PYTHON'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import urlsplit

path = Path(sys.argv[1])
size = path.stat().st_size
with path.open('rb') as source:
    start = source.read(4096)
    source.seek(max(0, size - 12))
    end = source.read(12)
# Reset at every response, so redirect lengths cannot describe the final body.
length = None
content_type = ''
for line in Path(sys.argv[2]).read_text(encoding='latin1').splitlines():
    if line.startswith('HTTP/'):
        length = None
        content_type = ''
    elif line.lower().startswith('content-length:'):
        length = int(line.split(':', 1)[1].strip())
    elif line.lower().startswith('content-type:'):
        content_type = line.split(':', 1)[1].split(';', 1)[0].strip().lower()
if length is not None and size < length:
    print('the fetched media body is shorter than its declared Content-Length')
    sys.exit(0)

image = False
closing = None
if start.startswith(b'\x89PNG\r\n\x1a\n'):
    image, closing = True, b'\x00\x00\x00\x00IEND\xaeB`\x82'
elif start.startswith(b'\xff\xd8\xff'):
    image, closing = True, b'\xff\xd9'
elif start.startswith((b'GIF87a', b'GIF89a')):
    image, closing = True, b';'
else:
    image = start.startswith((b'BM', b'II*\x00', b'MM\x00*', b'\x00\x00\x01\x00'))
    image |= start[:4] == b'RIFF' and start[8:12] == b'WEBP'
    image |= start[4:8] == b'ftyp' and start[8:12] in (b'avif', b'avis', b'heic', b'heix', b'hevc', b'hevx', b'mif1', b'msf1')
    if not image:
        try:
            image = ET.parse(path).getroot().tag in ('svg', '{http://www.w3.org/2000/svg}svg')
        except ET.ParseError:
            pass
if closing is not None and not end.endswith(closing):
    print('the fetched image media is truncated or corrupt: container closing marker is absent')
elif sys.argv[3] == 'image':
    if not image:
        print('the fetched media is not an image; use a recording link for video media')
else:
    # Seek between declared boundaries instead of searching inside payload bytes.
    ftyp = iso = avi = False
    with path.open('rb') as source:
        offset = 0
        while offset + 8 <= size:
            source.seek(offset)
            header = source.read(8)
            box_size = int.from_bytes(header[:4], 'big')
            kind = header[4:8]
            header_size = 8
            if box_size == 1:
                if offset + 16 > size:
                    break
                box_size = int.from_bytes(source.read(8), 'big')
                header_size = 16
            elif box_size == 0:
                box_size = size - offset
            if box_size < header_size or box_size > size - offset:
                break
            if offset == 0:
                # Major brand, minor version, then any four-byte compatible brands.
                brand_size = box_size - header_size
                ftyp = kind == b'ftyp' and brand_size >= 8 and brand_size % 4 == 0
                if not ftyp:
                    break
            elif kind in (b'moov', b'mdat'):
                iso = True
                break
            offset += box_size

        if start[:4] == b'RIFF' and start[8:12] == b'AVI ':
            riff_end = int.from_bytes(start[4:8], 'little') + 8
            offset = 12
            # The first RIFF may be followed by OpenDML continuation containers.
            while 12 <= riff_end <= size and offset + 8 <= riff_end:
                source.seek(offset)
                header = source.read(8)
                chunk_size = int.from_bytes(header[4:8], 'little')
                chunk_end = offset + 8 + chunk_size
                next_offset = chunk_end + chunk_size % 2
                if next_offset > riff_end:
                    break
                if header[:4] == b'LIST' and chunk_size >= 4 and source.read(4) in (b'hdrl', b'movi'):
                    avi = True
                    break
                offset = next_offset
    ebml = start.startswith(b'\x1a\x45\xdf\xa3')
    ext = Path(urlsplit(sys.argv[4]).path).suffix.lower()
    recording = iso if ext in ('.mp4', '.mov', '.m4v') else ebml if ext in ('.webm', '.mkv') else avi if ext == '.avi' else iso or ebml or avi
    claimed_container = {
        'video/mp4': iso, 'video/quicktime': iso, 'video/x-m4v': iso,
        'video/webm': ebml, 'video/x-matroska': ebml,
        'video/avi': avi, 'video/x-msvideo': avi,
    }.get(content_type)
    if ext in ('.mp4', '.mov', '.webm', '.m4v', '.avi', '.mkv') or not image or claimed_container is not None:
        if claimed_container is False:
            print('the fetched recording media does not match its declared Content-Type: ' + content_type)
        elif not recording:
            if ext in ('.mp4', '.mov', '.m4v'):
                missing = 'leading ISO file type box' if not ftyp else 'moov or mdat box'
            elif ext == '.avi':
                missing = 'complete RIFF/AVI container with an AVI LIST chunk'
            elif ext in ('.webm', '.mkv'):
                missing = 'EBML container marker'
            else:
                missing = 'ISO file type box and moov/mdat box, EBML, or RIFF/AVI container marker'
            print('the fetched recording media lacks the required ' + missing)
        elif size < 1024:
            print('the fetched recording media is too small: at least 1024 bytes are required')
PYTHON
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

# Only this PR's head repository can use its published head as a correction;
# another repository needs a commit from its own history.
pin_at_head() {  # <owner/repo> <path>
  [ "$1" = "$HEAD_REPO" ] || return 0
  printf 'https://%s/%s/raw/%s/%s\n' "$WEB_HOST" "$1" "$PUBLISHED_HEAD" "$2"
}

check_address() {  # <address>
  local addr=$1 context=$2 host rest shape='' owner repo ref path tail codes verdict access fix error image_mismatch=0

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
      codes=$(api_status "$addr")
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
          error=$(media_error "$context" "$addr") || error='the fetched media could not be checked'
          if [ -n "$error" ]; then
            record fail "$addr" "shape: $shape   fetch=$codes" "$error"
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

  codes="contents=$(contents_status "$owner/$repo" "$ref" "$path")   direct=session-bound"

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
      *contents=2??*) ;;
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

  if [ "$verdict" = ok ]; then
    error=$(media_error "$context" "$addr") || error='the fetched media could not be checked'
    if [ -n "$error" ]; then
      verdict=fail
      add_reason "$error"
    fi
  fi
  if [ "$context" = image ]; then
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
