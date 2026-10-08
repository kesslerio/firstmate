#!/usr/bin/env bash
# Static watcher program for a validated pull request, merge request, or Gerrit
# change poll sidecar.
# It emits exactly one merged line for a merged change and stays silent on
# every error, so a failed lookup can never be read as a merge.
# A GitHub read of that same single gh api graphql call also reports new top-level
# pull request comments and submitted reviews.
# One new group in a sweep is one activity line, never one line per comment:
# pr-activity: <url> <kind> <author>: <first line>
# kind is comment or review.
# When the sweep has more than one new item, that first line is prefixed with
# "<count> new:" and the kind, author, and text are the newest item's.
# The first line is the body up to its first newline, with ASCII controls
# removed, trimmed, and capped at 200 characters.
# An empty review body uses the review state instead, so a changes-requested
# review with no text still names the decision.
# The provider-tagged identity is data in the sidecar and is never interpolated
# into this source: these bytes are identical for every task.
# The activity cursor is a poll-owned sibling, <stem>.pr-activity, derived from
# the check path the same way this program derives <stem>.pr-poll from $0.
# The watcher passes that check path as the seventh --validated argument.
# A six-argument --validated read has no cursor anchor and stays merge-only.
# The cursor is created on first sight: that sweep records the current item ids
# and the pull request URL and does not wake, so pre-existing history is silent.
# A later sweep wakes only for ids not in the cursor, staging them in
# <stem>.pr-activity.pending until the watcher queues the wake and commits them.
# Replaying the same items emits nothing.
# Cursor file lines are fm-pr-activity-v1, the pull request URL, then one id.
# A missing anchor, a parse miss, a forge error, a symlink cursor, a hard link,
# or a path with an empty, dot, or dot-dot component stays silent and does not
# wake or write through the bad path.
# A cursor whose stored URL does not match this pull request is reseeded
# without a wake.
# GitLab and Gerrit stay merge-only: their one standard-CLI read does not
# expose comments without a second call or a JSON tool the GitLab path does
# not require.
# Each provider is read through its own standard CLI, gh for GitHub, glab for
# GitLab, and gerrit-axi for Gerrit, so an upstream checkout needs no extra
# tooling to follow the first two. The Gerrit branch additionally needs jq,
# which bin/fm-pr-check.sh refuses to arm a Gerrit watch without.
set -u
LC_ALL=C
export LC_ALL

# One bounded gh api graphql read, selected with gh's own query language so it does not
# grow a jq binary dependency. Pending reviews are drafts, not submissions.
POLL_ACTIVITY_QUERY="query(\$owner: String!, \$repo: String!, \$number: Int!) { repository(owner: \$owner, name: \$repo) { pullRequest(number: \$number) { state comments(first: 100) { nodes { id author { login } createdAt body } pageInfo { hasNextPage } } reviews(first: 100) { nodes { id author { login } submittedAt state body } pageInfo { hasNextPage } } } } }"
POLL_ACTIVITY_JQ='.data.repository.pullRequest | if ((.state|type)=="string" and (.comments.nodes|type)=="array" and (.reviews.nodes|type)=="array" and (.comments.pageInfo.hasNextPage|type)=="boolean" and (.reviews.pageInfo.hasNextPage|type)=="boolean") then "state=\(.state)", "truncated=\(.comments.pageInfo.hasNextPage or .reviews.pageInfo.hasNextPage)", (.comments.nodes[] | select((.id|type)=="string" and .id != "") | ["comment", .id, (.author.login // "unknown"), (.createdAt // ""), ((.body // "") | split("\n")[0] | gsub("\t"; " ") | gsub("\r"; "") | .[0:200])] | join("\t")), (.reviews.nodes[] | select(.state != "PENDING" and (.state|type)=="string" and .state != "" and (.id|type)=="string" and .id != "") | ["review", .id, (.author.login // "unknown"), (.submittedAt // ""), (if ((.body // "") | gsub("[[:space:]]"; "") | length) == 0 then .state else ((.body // "") | split("\n")[0] | gsub("\t"; " ") | gsub("\r"; "") | .[0:200]) end)] | join("\t")) else empty end'

POLL_CHECK_PATH=
if [ "$#" -eq 7 ] && [ "$1" = --validated ]; then
  provider=$2
  url=$3
  host=$4
  path=$5
  number=$6
  POLL_CHECK_PATH=$7
elif [ "$#" -eq 6 ] && [ "$1" = --validated ]; then
  provider=$2
  url=$3
  host=$4
  path=$5
  number=$6
elif [ "$#" -eq 0 ]; then
  case "$0" in
    *.check.sh) data=${0%.check.sh}.pr-poll ;;
    *) exit 0 ;;
  esac
  POLL_CHECK_PATH=$0

  [ -f "$data" ] && [ ! -L "$data" ] || exit 0
  { exec 3< "$data"; } 2>/dev/null || exit 0
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

poll_dirname() {
  case "$1" in
    */*) printf '%s\n' "${1%/*}" ;;
    *) printf '.\n' ;;
  esac
}

poll_components_safe() {
  local path=$1 rest segment
  [ -n "$path" ] || return 1
  case "$path" in
    *$'\n'*|*$'\t'*) return 1 ;;
  esac
  rest=$path
  case "$rest" in
    /*) rest=${rest#/} ;;
  esac
  while [ -n "$rest" ]; do
    case "$rest" in
      */*) segment=${rest%%/*}; rest=${rest#*/} ;;
      *) segment=$rest; rest= ;;
    esac
    case "$segment" in
      ''|.|..) return 1 ;;
    esac
  done
}

poll_device() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %d "$1" 2>/dev/null
  else
    stat -c %d "$1" 2>/dev/null
  fi
}

poll_link_count() {
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %l "$1" 2>/dev/null
  else
    stat -c %h "$1" 2>/dev/null
  fi
}

poll_same_device() {
  local left right
  left=$(poll_device "$1") || return 1
  right=$(poll_device "$2") || return 1
  [ -n "$left" ] && [ "$left" = "$right" ]
}

poll_private_cursor_or_absent() {
  local file=$1 sidecar=$2 mode
  [ ! -L "$file" ] || return 1
  [ -e "$file" ] || return 0
  [ -f "$file" ] || return 1
  [ "$(poll_link_count "$file")" = 1 ] || return 1
  poll_same_device "$file" "$sidecar" || return 1
  if [ "$(uname)" = Darwin ]; then
    mode=$(/usr/bin/stat -f %Lp "$file" 2>/dev/null) || return 1
  else
    mode=$(stat -c %a "$file" 2>/dev/null) || return 1
  fi
  [ "$mode" = 600 ]
}

poll_one_line() {
  local text=$1
  text=$(printf '%s' "$text" | tr -d '\000-\037\177' || true)
  text=${text#"${text%%[![:space:]]*}"}
  text=${text%"${text##*[![:space:]]}"}
  printf '%s' "$text"
}

poll_state_of() {
  local raw=$1 line state
  [ -n "$raw" ] || return 1
  line=${raw%%$'
'*}
  case "$line" in
    state=*) state=${line#state=} ;;
    MERGED|OPEN|CLOSED)
      [ "$raw" = "$line" ] || return 1
      state=$line
      ;;
    *) return 1 ;;
  esac
  case "$state" in
    [A-Z]*) ;;
    *) return 1 ;;
  esac
  case "$state" in
    *[!A-Z_]*) return 1 ;;
  esac
  printf '%s\n' "$state"
}

poll_sidecar_matches() {
  local file=$1 provider_line url_line host_line path_line number_line
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  exec 5< "$file" || return 1
  IFS= read -r provider_line <&5 || { exec 5<&-; return 1; }
  IFS= read -r url_line <&5 || { exec 5<&-; return 1; }
  IFS= read -r host_line <&5 || { exec 5<&-; return 1; }
  IFS= read -r path_line <&5 || { exec 5<&-; return 1; }
  IFS= read -r number_line <&5 || { exec 5<&-; return 1; }
  if IFS= read -r _extra <&5; then
    exec 5<&-
    return 1
  fi
  exec 5<&-
  [ "$provider_line" = "$provider" ] && [ "$url_line" = "$url" ] \
    && [ "$host_line" = "$host" ] && [ "$path_line" = "$path" ] \
    && [ "$number_line" = "$number" ]
}

# Print the check path whose sibling cursor may be used, or fail closed.
poll_activity_anchor() {
  local check stem sidecar cursor dir
  check=${POLL_CHECK_PATH:-}
  [ -n "$check" ] || return 1
  poll_components_safe "$check" || return 1
  case "$check" in
    *.check.sh) ;;
    *) return 1 ;;
  esac
  stem=${check%.check.sh}
  [ -n "$stem" ] || return 1
  case "$stem" in
    */) return 1 ;;
  esac
  sidecar=$stem.pr-poll
  cursor=$stem.pr-activity
  poll_components_safe "$sidecar" || return 1
  poll_components_safe "$cursor" || return 1
  dir=$(poll_dirname "$check")
  [ "$dir" = "$(poll_dirname "$sidecar")" ] || return 1
  [ "$dir" = "$(poll_dirname "$cursor")" ] || return 1
  [ ! -L "$dir" ] && [ -d "$dir" ] || return 1
  poll_sidecar_matches "$sidecar" || return 1
  poll_same_device "$dir" "$sidecar" || return 1
  poll_private_cursor_or_absent "$cursor" "$sidecar" || return 1
  poll_private_cursor_or_absent "$cursor.pending" "$sidecar" || return 1
  printf '%s\n' "$check"
}

# 0 ready, 1 reseed without a wake, 2 absent (seed), 3 refuse.
poll_cursor_ids() {
  local cursor=$1 line version stored_url ids=
  if [ -L "$cursor" ] || [ -d "$cursor" ]; then
    return 3
  fi
  if [ ! -e "$cursor" ]; then
    return 2
  fi
  [ -f "$cursor" ] || return 3
  [ "$(poll_link_count "$cursor")" = 1 ] || return 3
  exec 4< "$cursor" || return 1
  IFS= read -r version <&4 || { exec 4<&-; return 1; }
  IFS= read -r stored_url <&4 || { exec 4<&-; return 1; }
  [ "$version" = fm-pr-activity-v1 ] || { exec 4<&-; return 1; }
  [ "$stored_url" = "$url" ] || { exec 4<&-; return 1; }
  while IFS= read -r line <&4 || [ -n "$line" ]; do
    [ -n "$line" ] || { exec 4<&-; return 1; }
    case "$line" in
      *[!A-Za-z0-9_+=/-]*) exec 4<&-; return 1 ;;
    esac
    [ "${#line}" -le 200 ] || { exec 4<&-; return 1; }
    ids="${ids}${line}"$'
'
  done
  exec 4<&-
  printf '%s' "$ids"
}

poll_write_cursor() {
  local cursor=$1 sorted=$2 dir tmp
  dir=$(poll_dirname "$cursor")
  poll_private_cursor_or_absent "$cursor" "$dir" || return 1
  tmp=$(mktemp "$dir/.fm-pr-activity.XXXXXX") || return 1
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  {
    printf '%s\n' fm-pr-activity-v1
    printf '%s\n' "$url"
    if [ -n "$sorted" ]; then
      printf '%s' "$sorted"
      case "$sorted" in
        *$'
') ;;
        *) printf '\n' ;;
      esac
    fi
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  if ! poll_private_cursor_or_absent "$tmp" "$dir" \
    || ! poll_private_cursor_or_absent "$cursor" "$dir"; then
    rm -f -- "$tmp"
    return 1
  fi
  mv -f -- "$tmp" "$cursor" || { rm -f -- "$tmp"; return 1; }
  [ -f "$cursor" ] && poll_private_cursor_or_absent "$cursor" "$dir"
}

poll_is_newer() {
  local cts=$1 cid=$2 bts=$3 bid=$4
  [ -n "$bid" ] || return 0
  if [ -n "$cts" ] && [ -z "$bts" ]; then
    return 0
  fi
  if [ -z "$cts" ] && [ -n "$bts" ]; then
    return 1
  fi
  if [ "$cts" \> "$bts" ]; then
    return 0
  fi
  if [ "$cts" \< "$bts" ]; then
    return 1
  fi
  [ "$cid" \> "$bid" ]
}

poll_parse_activity() {
  local raw=$1 line first=1 kind id author ts text rest
  POLL_ROWS=
  POLL_TRUNCATED=
  POLL_READ_IDS=$'\n'
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$first" -eq 1 ]; then
      first=0
      case "$line" in
        state=*) continue ;;
        *) return 1 ;;
      esac
    fi
    if [ -z "$POLL_TRUNCATED" ]; then
      case "$line" in
        truncated=true|truncated=false) POLL_TRUNCATED=${line#truncated=} ;;
        *) return 1 ;;
      esac
      continue
    fi
    [ -n "$line" ] || return 1
    case "$line" in
      *$'	'*$'	'*$'	'*$'	'*) ;;
      *) return 1 ;;
    esac
    kind=${line%%$'	'*}
    rest=${line#*$'	'}
    id=${rest%%$'	'*}
    rest=${rest#*$'	'}
    author=${rest%%$'	'*}
    rest=${rest#*$'	'}
    ts=${rest%%$'	'*}
    text=${rest#*$'	'}
    case "$kind" in
      comment|review) ;;
      *) return 1 ;;
    esac
    case "$id" in
      ''|*[!A-Za-z0-9_+=/-]*) return 1 ;;
    esac
    [ "${#id}" -le 200 ] || return 1
    case "$POLL_READ_IDS" in
      *$'
'"$id"$'
'*) return 1 ;;
    esac
    POLL_READ_IDS="${POLL_READ_IDS}${id}"$'
'
    case "$author" in
      ''|[!A-Za-z0-9]*|*[!A-Za-z0-9_-]*) author=unknown ;;
    esac
    [ "${#author}" -le 39 ] || author=unknown
    case "$ts" in
      ''|*[!0-9A-Za-z:._+-]*) return 1 ;;
    esac
    text=$(poll_one_line "$text")
    POLL_ROWS="${POLL_ROWS}${kind}"$'	'"${id}"$'	'"${author}"$'	'"${ts}"$'	'"${text}"$'
'
  done < <(printf '%s' "$raw")
  [ -n "$POLL_TRUNCATED" ]
}

poll_emit_github_activity() {
  local raw=$1 anchor cursor loaded mode seen sorted current_ids new_count
  local line kind id author ts text rest best_kind best_id best_author best_ts best_text summary
  anchor=$(poll_activity_anchor) || return 0
  cursor=${anchor%.check.sh}.pr-activity
  poll_parse_activity "$raw" || return 0
  loaded=$(poll_cursor_ids "$cursor")
  mode=$?
  case "$mode" in
    0|1|2) ;;
    *) return 0 ;;
  esac
  new_count=0
  best_id=
  best_ts=
  best_kind=
  best_author=
  best_text=
  current_ids=
  # Command substitution strips the cursor's trailing newline, so put one back
  # or the last id never matches and every replay wakes.
  seen=$'\n'"${loaded}"$'
'
  if [ -n "$POLL_ROWS" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] || continue
      kind=${line%%$'	'*}
      rest=${line#*$'	'}
      id=${rest%%$'	'*}
      rest=${rest#*$'	'}
      author=${rest%%$'	'*}
      rest=${rest#*$'	'}
      ts=${rest%%$'	'*}
      text=${rest#*$'	'}
      current_ids="${current_ids}${id}"$'
'
      [ "$mode" -eq 0 ] || continue
      case "$seen" in
        *$'
'"$id"$'
'*) continue ;;
      esac
      new_count=$((new_count + 1))
      if poll_is_newer "$ts" "$id" "$best_ts" "$best_id"; then
        best_ts=$ts
        best_id=$id
        best_kind=$kind
        best_author=$author
        best_text=$text
      fi
    done < <(printf '%s' "$POLL_ROWS")
  fi
  sorted=$(printf '%s' "$current_ids" | LC_ALL=C sort -u)
  if [ "$mode" -eq 0 ] && [ "$new_count" -eq 0 ] && [ "$loaded" = "$sorted" ]; then
    return 0
  fi
  if [ "$mode" -ne 0 ] || [ "$new_count" -eq 0 ]; then
    poll_write_cursor "$cursor" "$sorted" || return 0
    return 0
  fi
  [ -n "$best_kind" ] && [ -n "$best_author" ] || return 0
  poll_write_cursor "$cursor.pending" "$sorted" || return 0
  summary=$best_text
  if [ "$new_count" -gt 1 ]; then
    summary="$new_count new: $best_text"
  fi
  if [ "$POLL_TRUNCATED" = true ]; then
    summary="truncated: $summary"
  fi
  printf 'pr-activity: %s %s %s: %s\n' "$url" "$best_kind" "$best_author" "$summary"
  return 0
}

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
    raw=$(gh api graphql --hostname github.com -f query="$POLL_ACTIVITY_QUERY" \
      -f owner="$owner" -f repo="$repo" -F number="$number" \
      --jq "$POLL_ACTIVITY_JQ" 2>/dev/null) || exit 0
    state=$(poll_state_of "$raw") || exit 0
    if [ "$state" = MERGED ]; then
      printf '%s\n' merged
      exit 0
    fi
    poll_emit_github_activity "$raw" || exit 0
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
    raw=$(glab mr view "$number" -R "https://$host/$path" 2>/dev/null) || exit 0
    state=$(printf '%s\n' "$raw" | sed -n 's/^state:[[:space:]]*//p' | head -1) || exit 0
    [ "$state" = merged ] && printf '%s\n' merged
    ;;
  gerrit)
    [ "${#host}" -ge 1 ] && [ "${#host}" -le 253 ] || exit 0
    [ "$host" != github.com ] || exit 0
    case "$host" in
      .*|*.|*..*|*[!a-z0-9.-]*) exit 0 ;;
    esac
    [ "${#path}" -ge 1 ] && [ "${#path}" -le 1024 ] || exit 0
    case "$path" in
      /*|*/|*//*) exit 0 ;;
    esac
    # A Gerrit project name is a path at no fixed depth that needs no enclosing
    # group, so one segment is canonical here where GitLab needs two, and Gerrit
    # reserves no route segment inside it.
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
        .|..|-*|*.git|*[!A-Za-z0-9._-]*) exit 0 ;;
      esac
    done
    [ "$segments" -ge 1 ] || exit 0
    [ "$url" = "https://$host/c/$path/+/$number" ] || exit 0
    # gerrit-axi resolves its server from the current directory's origin remote
    # first, and the watcher runs in no repository, so the host must be passed
    # explicitly from the validated record. Without it the tool has no host to
    # reach and fails before reading anything, and this poll is silent on every
    # failure, so the watch would wait forever on a change it never looked at.
    #
    # The status is read explicitly and is the only thing that can wake this
    # poll. Gerrit's submittability is a different question: a merged change
    # still reports its submit state as OK with nothing blocking it, so reading
    # submittability, a blocked_on list, or vote values would report a merge for
    # an open change that is merely ready to submit.
    #
    # jq selects the one record whose change number matches. A change number is
    # server-global and --host already pins the server, so the number alone
    # names the change. The record's own url field is deliberately not compared
    # against the stored URL: Gerrit composes that field from
    # gerrit.canonicalWebUrl and omits it when that setting is unset, so an
    # equality test would leave a correctly armed watch silent forever on such
    # a server, and this poll has no channel to report that it never matched.
    json=$(gerrit-axi show "$number" --host "$host" --json 2>/dev/null) || exit 0
    [ -n "$json" ] || exit 0
    status=$(printf '%s' "$json" | jq -r --argjson change "$number" '
      if type == "object" and .ok == true and (.changes | type) == "array" then
        [.changes[] | select((.change | type) == "number" and .change == $change)] as $match
        | if ($match | length) == 1
             and ($match[0].status | type) == "string"
          then $match[0].status
          else error("no exact change record")
          end
      else
        error("invalid gerrit record")
      end' 2>/dev/null) || exit 0
    [ "$status" = MERGED ] && printf '%s\n' merged
    ;;
  *) exit 0 ;;
esac
exit 0
