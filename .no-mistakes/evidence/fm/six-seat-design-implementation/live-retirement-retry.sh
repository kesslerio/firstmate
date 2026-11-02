#!/usr/bin/env bash
# Live driver: a secondmate-home retirement that fails mid-removal must be
# retryable once the original failure is fixed.
#
# Each case provisions a real secondmate home with bin/fm-home-seed.sh and
# records a stopped tmux-backend secondmate on a private lab tmux socket. The
# induced failure is an unreadable process-event registration, which the removal
# reaches after it published its retry evidence and before it renamed the home.
#
# Case A (negative control, teardown from the parent commit c86c53fc): the
# failing attempt leaves its removal evidence behind, so the later retry refuses.
# Case B (teardown from this change): the failing attempt withdraws that
# evidence, so the retry after the operator fixes the permission succeeds.
set -u
ROOT=/home/art/.no-mistakes/worktrees/9f75ec418609/01M6DDN8CWC4PFXJKN77TZ98SJ
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || exit 1
PRE="$LAB/pre"
mkdir -p "$PRE"
git -C "$ROOT" archive c86c53fc | tar -x -C "$PRE" || exit 1
chmod +x "$PRE/bin/"*.sh
TM_PRE="$LAB/tmux-pre"; TM_NEW="$LAB/tmux-new"
mkdir -p "$TM_PRE" "$TM_NEW"
active_tm= TM_ACTIVE=
cleanup() {
  [ -z "$TM_PRE" ] || TMUX_TMPDIR="$TM_PRE" tmux -L fm-lab kill-server >/dev/null 2>&1 || true
  [ -z "$TM_NEW" ] || TMUX_TMPDIR="$TM_NEW" tmux -L fm-lab kill-server >/dev/null 2>&1 || true
  rm -rf "$LAB"
}
trap cleanup EXIT

case_setup() {  # <case> <tmux-dir> -> sets P MATE
  local c=$1
  P="$LAB/$c/primary"; MATE="$LAB/$c/mate"
  "$ROOT/bin/fm-lab-home.sh" create "$P" >/dev/null || return 1
  ( cd "$ROOT" && FM_SECONDMATE_SCOPE='live validation' \
    FM_SECONDMATE_CHARTER='# Live retirement driver
## Routing scope
live validation' \
    env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$P" "$ROOT/bin/fm-home-seed.sh" mate1 "$MATE" --no-projects >/dev/null ) || return 1
  {
    printf 'window=fmlabretire:fm-mate1\nbackend=tmux\nendpoint_task_id=mate1\n'
    printf 'kind=secondmate\nmode=secondmate\nharness=claude\n'
    printf 'home=%s\nworktree=%s\nproject=%s\nspawn_gen=g-live-1\n' "$MATE" "$MATE" "$MATE"
  } > "$P/state/mate1.meta"
  mkdir -p "$MATE/state/procevent"
  printf 'registration\n' > "$MATE/state/procevent/wait.source"
  chmod 000 "$MATE/state/procevent/wait.source"
}

teardown_with() {  # <bin> <tmux-dir> <home>
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    TMUX_TMPDIR="$2" TMUX= FM_HOME="$3" "$1" mate1 </dev/null 2>&1 | grep -v '^●'
  return "${PIPESTATUS[0]}"
}

state_line() {  # <label> <home> <meta>
  local home_state meta_state ev_state
  [ -d "$2" ] && home_state="home present" || home_state="home retired"
  [ -e "$3" ] && meta_state="meta present" || meta_state="meta removed"
  [ -e "${3%.meta}.home-removal" ] && ev_state="removal evidence PRESENT" || ev_state="removal evidence withdrawn"
  printf '%s: %s; %s; %s\n' "$1" "$home_state" "$meta_state" "$ev_state"
}

echo "== lab: $LAB"
echo
echo "== case A: pre-fix teardown fails mid-removal, then the operator retries"
case_setup caseA "$TM_PRE" || { echo "case A setup failed"; exit 1; }
teardown_with "$PRE/bin/fm-teardown.sh" "$TM_PRE" "$P"; echo "pre-fix first attempt rc=$?"
state_line "after the pre-fix failure" "$MATE" "$P/state/mate1.meta"
chmod 644 "$MATE/state/procevent/wait.source"
teardown_with "$ROOT/bin/fm-teardown.sh" "$TM_NEW" "$P"; echo "retry with this change rc=$?"
state_line "after the retry" "$MATE" "$P/state/mate1.meta"
echo
echo "== case B: this change's teardown fails mid-removal, then the operator retries"
case_setup caseB "$TM_NEW" || { echo "case B setup failed"; exit 1; }
teardown_with "$ROOT/bin/fm-teardown.sh" "$TM_NEW" "$P"; echo "first attempt rc=$?"
state_line "after the failed attempt" "$MATE" "$P/state/mate1.meta"
chmod 644 "$MATE/state/procevent/wait.source"
teardown_with "$ROOT/bin/fm-teardown.sh" "$TM_NEW" "$P"; echo "retry after the fix rc=$?"
state_line "after the retry" "$MATE" "$P/state/mate1.meta"
ls -d "$MATE".retiring.* 2>/dev/null || echo "no staging directory left behind"
echo "registry after retirement: [$(cat "$P/data/secondmates.md")]"
echo "== done"
