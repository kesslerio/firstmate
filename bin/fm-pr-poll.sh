#!/usr/bin/env bash
# Static watcher program for a validated PR/MR poll sidecar.
# It emits one merged line for a merged PR or MR, one activity line for a group
# of genuinely new GitHub pull-request comments or submitted reviews, and stays
# silent otherwise, including on every error, so a failed lookup can never be
# read as a merge or as a conversation. The provider-tagged identity is data in
# the sidecar and is never interpolated into this source: these bytes are
# identical for every task.
# Each provider is read through its own standard CLI, gh for GitHub and glab
# for GitLab, so an upstream checkout needs no extra tooling to follow either.
#
# Usage:
#   fm-pr-poll.sh --validated <provider> <url> <host> <path> <number> [sidecar]
#   <id>.check.sh                     (the armed copy, run with no arguments)
#
# Activity needs one more path than the merge verdict does: its cursor is the
# sidecar's sibling <id>.pr-activity. The armed copy derives both paths from $0,
# and the watcher passes the sidecar it has already validated as the seventh
# argument. The six-argument form has no sidecar, so it keeps the historical
# merged-only verdict and reports no activity, which is why a missing cursor is
# silence rather than a wake.
#
# Activity costs no extra forge call: one gh read carries the state, the
# top-level comments, and the submitted reviews together, and that same
# single read is what still answers the merge question.
#
# Cursor rules, all fail-silent:
#   - First sight of a sidecar records every id currently visible and prints
#     nothing, so pre-existing history never wakes anyone.
#   - An id already in the cursor is never reported again, so replaying the
#     same state emits nothing.
#   - New ids are appended only after the rewritten cursor is on disk, so a
#     wake is never delivered without its cursor advance.
#   - A malformed cursor, an unexpected payload shape, or any file that is not
#     a private regular non-symlink file in a private directory is refused with
#     no output and no write, and stays refused until it is corrected.
#
# One sweep emits at most one activity line. Comments and reviews are each one
# group; a group with new ids reports its count, its newest item's author, and
# that item's first line, and a sweep holding two groups reports the reviews,
# because a submitted review is the stronger signal. Both groups are recorded
# as seen, so nothing is re-reported and no per-comment spam is possible.
#
# The line is:
#   pr-activity: <url> <comment|review> <author>: <text>
# and <text> leads with "<n> new - " when a group holds more than one new item.
set -u
LC_ALL=C
export LC_ALL

# One activity line stays short enough to read in a wake and to survive the
# watcher's flattening of a check's output into one durable record.
ACTIVITY_TEXT_MAX=300
# A cursor is rewritten once it grows past this many ids, keeping its newest
# tail, so a long-lived poll stays bounded without losing recent history.
ACTIVITY_CEILING=800
ACTIVITY_KEEP=400
# A poll never walks more payload lines than this, so an unexpectedly huge
# payload cannot outlast the watcher's check timeout.
ACTIVITY_LINES_MAX=3000

ACTIVITY_SEEN=
ACTIVITY_SEEN_COUNT=0

file_mode() {
  if [ "$(uname)" = Darwin ]; then
    stat -f %Lp "$1" 2>/dev/null
  else
    stat -c %a "$1" 2>/dev/null
  fi
}

# A poll-owned private file: a regular non-symlink owned by this effective user
# with exactly the expected mode.
private_file_ok() { # <path> <mode>
  [ -f "$1" ] && [ ! -L "$1" ] || return 1
  [ -O "$1" ] || return 1
  [ "$(file_mode "$1")" = "$2" ]
}

# Refuse a malformed task id before any cursor work, so a corrupt identity can
# never name the file this poll is about to write.
task_id_ok() {
  local id=$1
  [ "${#id}" -ge 1 ] && [ "${#id}" -le 64 ] || return 1
  case "$id" in
    [A-Za-z0-9._-]*) ;;
    *) return 1 ;;
  esac
  case "$id" in
    *[!A-Za-z0-9._-]*) return 1 ;;
    .*) return 1 ;;
  esac
}

# A poll-owned private directory: this effective user's own, not a link, and not
# open for other users to write into. An exact mode is NOT required, because a
# home's state directory is legitimately 0755 in the field, and a poll that
# demanded 0700 would go quietly silent on every real home.
dir_ok() { # <path>
  local mode group other
  [ -d "$1" ] && [ ! -L "$1" ] || return 1
  [ -O "$1" ] || return 1
  mode=$(file_mode "$1")
  case "$mode" in
    *[0-7][0-7][0-7]) ;;
    *) return 1 ;;
  esac
  other=${mode: -1}
  group=${mode: -2:1}
  # Reject a directory group or other may write into: that is what would let a
  # foreign process swap the cursor this poll is about to rename into place.
  case "$group$other" in
    *[2367]*) return 1 ;;
  esac
}

# A sidecar path is accepted only as the private sibling of a private task id,
# so the single path this script may ever write is a <id>.pr-activity beside a
# sidecar whose own bytes were just proven to carry this task's identity.
sidecar_ok() { # <sidecar>
  local dir name
  case "$1" in
    /**.pr-poll) ;;
    *) return 1 ;;
  esac
  case "$1" in
    *$'\n'*|*$'\r'*|*$'\t'*) return 1 ;;
  esac
  [ "${#1}" -le 4096 ] || return 1
  dir=${1%/*}
  name=${1##*/}
  [ "$dir/$name" = "$1" ] || return 1
  [ "$dir" != / ] || return 1
  [ "${#name}" -ge 9 ] || return 1
  task_id_ok "${name%.pr-poll}" || return 1
  dir_ok "$dir" || return 1
  private_file_ok "$1" 600 || return 1
}

# Prove a cursor id is a forge node id and nothing else, so no payload line can
# smuggle a path or a control character into the file this poll rewrites.
activity_id_ok() { # <kind> <id>
  case "$1" in
    C | R) ;;
    *) return 1 ;;
  esac
  case "$2" in
    [A-Za-z0-9_-][A-Za-z0-9_-]*) ;;
    *) return 1 ;;
  esac
  [ "${#2}" -le 64 ] || return 1
  case "$2" in
    *[!A-Za-z0-9_-]*) return 1 ;;
  esac
}

# Reduce one reported text field to a single printable ASCII line. The forge
# already replaced tabs and newlines, and anything left over is dropped rather
# than forwarded. Non-ASCII becomes a space so no word is glued shut, runs of
# spaces collapse, and the result holds one byte per character, which is what
# lets the caller's length bound cut the line without splitting a character.
activity_text_clean() { # <text>
  printf '%s' "$1" | tr -d '\000-\037\177' | tr '\200-\377' ' ' | tr -s ' ' | sed -e 's/^ //' -e 's/ $//'
}

# Author logins are reported only in their canonical shape; anything else is
# named as unknown rather than cleaned into something the captain misreads.
activity_author_clean() { # <login>
  case "$1" in
    [A-Za-z0-9._-][A-Za-z0-9._-]*)
      [ "${#1}" -le 39 ] && printf '%s' "$1" && return 0
      ;;
  esac
  printf 'unknown'
}

# Read the five sidecar lines and prove they are exactly the identity this poll
# was handed, so a caller-supplied path cannot be pointed at another task's
# record and the cursor this poll writes can only ever be that record's sibling.
sidecar_matches_identity() { # <sidecar> <provider> <url> <host> <path> <number>
  local file=$1 want_provider=$2 want_url=$3 want_host=$4 want_path=$5 want_number=$6
  local line field=0
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  { exec 3< "$file"; } 2>/dev/null || return 1
  while IFS= read -r line <&3; do
    field=$((field + 1))
    case "$field" in
      1) [ "$line" = "$want_provider" ] || { exec 3<&-; return 1; } ;;
      2) [ "$line" = "$want_url" ] || { exec 3<&-; return 1; } ;;
      3) [ "$line" = "$want_host" ] || { exec 3<&-; return 1; } ;;
      4) [ "$line" = "$want_path" ] || { exec 3<&-; return 1; } ;;
      5) [ "$line" = "$want_number" ] || { exec 3<&-; return 1; } ;;
      *) exec 3<&-; return 1 ;;
    esac
  done
  exec 3<&-
  [ "$field" -eq 5 ]
}

# Load the recorded ids. Any format miss fails, and the caller keeps silent
# rather than waking on a cursor it cannot trust.
activity_cursor_load() { # <cursor>
  local file=$1 header line kind id
  ACTIVITY_SEEN=
  ACTIVITY_SEEN_COUNT=0
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  [ -O "$file" ] || return 1
  [ "$(file_mode "$file")" = 600 ] || return 1
  { exec 3< "$file"; } 2>/dev/null || return 1
  IFS= read -r header <&3 || { exec 3<&-; return 1; }
  [ "$header" = fm-pr-activity-v1 ] || { exec 3<&-; return 1; }
  while IFS= read -r line <&3; do
    ACTIVITY_SEEN_COUNT=$((ACTIVITY_SEEN_COUNT + 1))
    [ "$ACTIVITY_SEEN_COUNT" -le "$ACTIVITY_CEILING" ] || { exec 3<&-; return 1; }
    kind=${line%%$'\t'*}
    id=${line#*$'\t'}
    # This one check also proves the record holds exactly one tab: a second tab
    # would leave a control character in kind or in id, and both are refused.
    activity_id_ok "$kind" "$id" || { exec 3<&-; return 1; }
    ACTIVITY_SEEN="$ACTIVITY_SEEN$line"$'\n'
  done
  exec 3<&-
}

# Only a submitted review is engagement. A state this release does not name is
# skipped, never guessed at, and stays out of the cursor, so a review that later
# reaches a reportable state is still reported rather than burned as seen.
review_state_reportable() { # <state>
  case "$1" in
    APPROVED | CHANGES_REQUESTED | COMMENTED | APPROVED_SUGGESTIONS | DISMISSED) return 0 ;;
  esac
  return 1
}

# Report whether one id is already recorded. ACTIVITY_SEEN ends every record with
# a newline and starts with none, so the probe is given a leading newline of its
# own and can match only a whole record, never a fragment of one.
activity_seen_has() { # <kind> <id>
  case $'\n'"$ACTIVITY_SEEN" in
    *$'\n'"$1	$2"$'\n'*) return 0 ;;
  esac
  return 1
}

# Rewrite the cursor with the ids it already held plus every new id, keeping the
# newest tail once the ceiling is passed. The caller has already refused any
# path it would not accept, and a failed write leaves the old cursor in place.
activity_cursor_write() { # <cursor> <lines>
  local cursor=$1 lines=$2 dir tmp line
  local total=0 keep_from=0 n=0
  # Every caller passes newline-terminated records and the heredoc below adds
  # one more newline, so one trailing break is removed here rather than at
  # every call site, and an empty set stays a header-only cursor.
  lines=${lines%$'\n'}
  dir=${cursor%/*}
  tmp=$dir/.${cursor##*/}.tmp.$$
  rm -f -- "$tmp" 2>/dev/null
  # A leftover temporary from an earlier killed sweep belongs to no one else in
  # this private directory, so it is never reused: an occupied name refuses.
  [ ! -e "$tmp" ] && [ ! -L "$tmp" ] || return 1
  { exec 3> "$tmp"; } 2>/dev/null || return 1
  if ! printf 'fm-pr-activity-v1\n' >&3; then
    exec 3>&-
    rm -f -- "$tmp"
    return 1
  fi
  if [ -n "$lines" ]; then
    total=$(printf '%s\n' "$lines" | sed -n '$=')
    case "$total" in
      [1-9]*) ;;
      *)
        exec 3>&-
        rm -f -- "$tmp"
        return 1
        ;;
    esac
    [ "$total" -gt "$ACTIVITY_CEILING" ] && keep_from=$((total - ACTIVITY_KEEP))
    while IFS= read -r line; do
      n=$((n + 1))
      [ -n "$line" ] || continue
      [ "$n" -gt "$keep_from" ] || continue
      if ! printf '%s\n' "$line" >&3; then
        exec 3>&-
        rm -f -- "$tmp"
        return 1
      fi
    done <<EOF
$lines
EOF
  fi
  exec 3>&-
  chmod 600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  private_file_ok "$tmp" 600 || { rm -f -- "$tmp"; return 1; }
  # Re-check the destination immediately before the rename so a cursor replaced
  # with a link while this rewrite was in flight is never followed or replaced.
  [ -L "$cursor" ] && { rm -f -- "$tmp"; return 1; }
  [ -e "$cursor" ] && ! private_file_ok "$cursor" 600 && { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$cursor" || {
    rm -f -- "$tmp" 2>/dev/null
    return 1
  }
}

if [ "$#" -eq 6 ] && [ "$1" = --validated ]; then
  provider=$2
  url=$3
  host=$4
  path=$5
  number=$6
  sidecar=
elif [ "$#" -eq 7 ] && [ "$1" = --validated ]; then
  provider=$2
  url=$3
  host=$4
  path=$5
  number=$6
  sidecar=$7
elif [ "$#" -eq 0 ]; then
  case "$0" in
    *.check.sh) sidecar=${0%.check.sh}.pr-poll ;;
    *) exit 0 ;;
  esac

  [ -f "$sidecar" ] && [ ! -L "$sidecar" ] || exit 0
  { exec 3< "$sidecar"; } 2>/dev/null || exit 0
  IFS= read -r provider <&3 || exit 0
  IFS= read -r url <&3 || exit 0
  IFS= read -r host <&3 || exit 0
  IFS= read -r path <&3 || exit 0
  IFS= read -r number <&3 || exit 0
  if IFS= read -r _extra <&3; then
    exit 0
  fi
  exec 3<&-
else
  exit 0
fi

case "$number" in
  [1-9]*) ;;
  *) exit 0 ;;
esac
case "$number" in
  *[!0-9]*) exit 0 ;;
esac

# Every component is revalidated here rather than trusted from the sidecar, and
# the stored URL must then be exactly reconstructible from those components, so
# a doctored sidecar cannot redirect this poll at another host or project.
case "$provider" in
  github)
    [ "$host" = github.com ] || exit 0
    owner=${path%%/*}
    repo=${path#*/}
    [ "${#owner}" -ge 1 ] && [ "${#owner}" -le 39 ] || exit 0
    case "$owner" in
      *[!A-Za-z0-9-]*|-*|*-|*--*) exit 0 ;;
    esac
    [ "${#repo}" -ge 1 ] && [ "${#repo}" -le 100 ] || exit 0
    case "$repo" in
      .|..|*[!A-Za-z0-9._-]*) exit 0 ;;
    esac
    [ "$url" = "https://github.com/$owner/$repo/pull/$number" ] || exit 0
    # The one read that still answers the merge question now carries the
    # top-level comments and submitted reviews with it, so activity adds a
    # signal to an existing call rather than adding a call per sweep. gh reads
    # both arrays in ascending time order, so the last item of a group is its
    # newest, and each item's globally unique node id is its cursor key.
    payload=$(gh pr view "$url" --json state,comments,reviews --jq '
"S\t" + (.state // ""),
(.comments // [] | .[] | "C\t" + ((.id // "") | tostring) + "\t" + ((.author.login) // "") + "\t" + ((.body // "") | gsub("[\t\r\n]"; " "))),
(.reviews // [] | .[] | "R\t" + ((.id // "") | tostring) + "\t" + ((.author.login) // "") + "\t" + ((.state // "") + "\t" + ((.body // "") | gsub("[\t\r\n]"; " "))))
' 2>/dev/null) || exit 0
    [ -n "$payload" ] || exit 0

    first=$(printf '%s\n' "$payload" | sed -n '1p')
    case "$first" in
      "S	"*) state=${first#"S	"} ;;
      *) exit 0 ;;
    esac
    # A merge is the one verdict this poll has always carried, so it stays the
    # only line that sweep emits and is never followed by an activity report.
    if [ "$state" = MERGED ]; then
      printf '%s\n' merged
      exit 0
    fi
    [ -n "$sidecar" ] || exit 0

    # Only a path already proven to be this task's own private record can name
    # the cursor, and the record's bytes must repeat the identity revalidated
    # above before a single line is written beside it.
    sidecar_ok "$sidecar" || exit 0
    sidecar_matches_identity "$sidecar" "$provider" "$url" "$host" "$path" "$number" || exit 0
    cursor=${sidecar%.pr-poll}.pr-activity
    if [ ! -e "$cursor" ]; then
      [ ! -L "$cursor" ] || exit 0
      # First sight seeds the cursor with everything already there and reports
      # nothing, so a poll armed on an old conversation never replays it.
      seed=
      lines=0
      while IFS= read -r line; do
        lines=$((lines + 1))
        [ "$lines" -le "$ACTIVITY_LINES_MAX" ] || exit 0
        case "$line" in
          S*) continue ;;
          "C	"*) kind=C ;;
          "R	"*) kind=R ;;
          *) exit 0 ;;
        esac
        id=${line#*$'\t'}
        id=${id%%$'\t'*}
        activity_id_ok "$kind" "$id" || exit 0
        if [ "$kind" = R ]; then
          rest=${line#*$'\t'}
          rest=${rest#*$'\t'}
          rest=${rest#*$'\t'}
          review_state=${rest%%$'\t'*}
          review_state_reportable "$review_state" || continue
        fi
        seed="$seed$kind	$id
"
      done <<EOF
$payload
EOF
      activity_cursor_write "$cursor" "$seed" || exit 0
      exit 0
    fi

    activity_cursor_load "$cursor" || exit 0
    new_lines=
    comment_count=0
    comment_author=
    comment_text=
    review_count=0
    review_author=
    review_text=
    lines=0
    while IFS= read -r line; do
      lines=$((lines + 1))
      [ "$lines" -le "$ACTIVITY_LINES_MAX" ] || exit 0
      case "$line" in
        S*) continue ;;
        "C	"*) kind=C ;;
        "R	"*) kind=R ;;
        *) exit 0 ;;
      esac
      rest=${line#*$'\t'}
      id=${rest%%$'\t'*}
      activity_id_ok "$kind" "$id" || exit 0
      activity_seen_has "$kind" "$id" && continue
      rest=${rest#*$'\t'}
      author=${rest%%$'\t'*}
      case "$kind" in
        C)
          text=${rest#*$'\t'}
          [ "$text" != "$rest" ] || exit 0
          comment_count=$((comment_count + 1))
          comment_author=$author
          comment_text=$text
          ;;
        R)
          state_field=${rest#*$'\t'}
          state_field=${state_field%%$'\t'*}
          text=${rest#*$'\t'}
          text=${text#*$'\t'}
          [ "$text" != "$rest" ] || exit 0
          # Only a submitted review is engagement. A state this release does not
          # name is skipped, never guessed at, and stays out of the cursor so a
          # review that later reaches a reportable state is still reported.
          review_state_reportable "$state_field" || continue
          review_count=$((review_count + 1))
          review_author=$author
          review_text=$state_field
          [ -n "$text" ] && review_text="$state_field - $text"
          ;;
      esac
      new_lines="$new_lines$kind	$id
"
    done <<EOF
$payload
EOF

    # Nothing new, or only the payload's own shape to report: stay silent, and
    # leave an unchanged cursor untouched on disk. A group count of zero is a
    # payload this release cannot read, so it is never named as an activity.
    [ -n "$new_lines" ] || exit 0
    [ "$((comment_count + review_count))" -gt 0 ] || exit 0
    count=$((comment_count + review_count))
    if [ "$review_count" -gt 0 ]; then
      kind_label=review
      author=$review_author
      text=$review_text
      count=$review_count
    else
      kind_label=comment
      author=$comment_author
      text=$comment_text
    fi
    [ "$count" -gt 1 ] && text="$count new - $text"
    text=$(activity_text_clean "$text")
    [ -n "$text" ] || text='(no text)'
    [ "${#text}" -le "$ACTIVITY_TEXT_MAX" ] || text=${text:0:$ACTIVITY_TEXT_MAX}
    author=$(activity_author_clean "$author")

    # The cursor advance is published first: a wake that could not be replayed
    # safely is never delivered, and a crash between these two lines costs one
    # missed report rather than a repeated one.
    activity_cursor_write "$cursor" "${ACTIVITY_SEEN}$new_lines" || exit 0
    printf 'pr-activity: %s %s %s: %s\n' "$url" "$kind_label" "$author" "$text"
    ;;
  gitlab)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    [ "$host" != github.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    [ "${#path}" -ge 3 ] && [ "${#path}" -le 1024 ] || exit 0
    case "$path" in
      /*|*/|*//*) exit 0 ;;
    esac
    # A GitLab project sits under at least one group at no fixed depth, and
    # GitLab reserves the "-" segment as its route separator.
    rest=$path
    segments=0
    while [ -n "$rest" ]; do
      case "$rest" in
        */*) segment=${rest%%/*}; rest=${rest#*/} ;;
        *) segment=$rest; rest= ;;
      esac
      segments=$((segments + 1))
      [ "$segments" -le 20 ] || exit 0
      [ "${#segment}" -ge 1 ] && [ "${#segment}" -le 255 ] || exit 0
      case "$segment" in
        .|..|-*|*.git|*.atom|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$segments" -ge 2 ] || exit 0
    [ "$url" = "https://$host/$path/-/merge_requests/$number" ] || exit 0
    # glab resolves the instance from the project URL passed to -R, so the host
    # comes from the validated record rather than glab's configured default.
    # It cannot take a merge request URL the way gh does: that form shells out
    # to git for the current repository, and the watcher runs in no repository.
    # The state is read from glab's own field output rather than its JSON,
    # because plain glab has no field selector and firstmate does not require a
    # JSON processor; only an exact "merged" wakes, so a changed format or an
    # unreadable merge request stays silent instead of reporting a merge.
    # GitLab reports no activity: glab's single standard read of a merge request
    # yields its fields and not its notes, and a second call per sweep is the
    # one thing this poll's contract forbids. A merge stays reported, and an
    # unverified note format stays unguessed rather than half-parsed.
    raw=$(glab mr view "$number" -R "https://$host/$path" 2>/dev/null) || exit 0
    state=$(printf '%s\n' "$raw" | sed -n 's/^state:[[:space:]]*//p' | head -1) || exit 0
    [ "$state" = merged ] && printf '%s\n' merged
    ;;
  *) exit 0 ;;
esac
exit 0
