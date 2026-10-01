#!/usr/bin/env bash
# Adversarial probe: with the exclusion helper neutered (simulating the pre-fix
# scan), does the remote mate's own parent channel reappear in each consumer?
# Uses the real product modules from this worktree; nothing here is a mock.
set -u
ROOT=$(cd "$(dirname "$PWD")" && pwd)   # placeholder, set by caller env
ROOT=${PROBE_ROOT:?}
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-probe.XXXXXX")
INERT=$(mktemp -d "${TMPDIR:-/tmp}/fm-probe-root.XXXXXX")
export FM_ROOT_OVERRIDE="$INERT"

seed_remote_mate() {
  local dir=$1
  mkdir -p "$dir/state"
  printf '%s\n' mate > "$dir/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=remote.example\n' \
    > "$dir/.fm-secondmate-parent"
  printf 'needs-decision [key=captain-hold-pr-7-1]: captain hold pr-7: merge the green PR?\n' \
    > "$dir/state/parent-replies.status"
  printf 'resolved [key=captain-hold-pr-5-2]: captain chose the staged rollout\n' \
    >> "$dir/state/parent-replies.status"
  printf 'note: the release branch is cut\n' >> "$dir/state/parent-replies.status"
}

# Temporarily neuter the exclusion helper inside the real lib (restored below).
LIB="$ROOT/bin/fm-classify-lib.sh"
cp "$LIB" "$W/fm-classify-lib.sh.orig"
restore() {
  cp "$W/fm-classify-lib.sh.orig" "$LIB"
  rm -rf -- "$W" "$INERT"
}
trap restore EXIT
awk '
  /^status_scan_parent_channel_exclude\(\)/ { in_fn=1; print; print "  return 0"; next }
  in_fn && /^\}/ { in_fn=0 }
  { print }
' "$W/fm-classify-lib.sh.orig" > "$LIB"
grep -n -A2 '^status_scan_parent_channel_exclude()' "$LIB" | head -5
echo "--- helper neutered (exclude resolves to nothing, as before the fix) ---"

echo
echo "### watcher scan_signals over a remote mate home"
dir="$W/watch"; seed_remote_mate "$dir/home"
FM_STATE_OVERRIDE="$dir/home/state" FM_HOME="$dir/home" STATE="$dir/home/state" \
  bash -c '. "$1/bin/fm-watch.sh"; scan_signals' _ "$ROOT" > "$W/scan.out"
cut -f3 "$W/scan.out" | sed 's/^/  enumerated: /'
cut -f3 "$W/scan.out" | grep -qx "$dir/home/state/parent-replies.status" \
  && echo "  => LEAK: channel enumerated" || echo "  => channel not enumerated"

echo
echo "### away-mode daemon catch-all scan over a remote mate home"
dir="$W/daemon"; seed_remote_mate "$dir/home"
printf 'note: benchmark results are in\n' > "$dir/home/state/real-task.status"
rm -f "$dir/home/state/.subsuper-last-scan"
FM_TEST_LIB_SOURCED=1 FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" \
  bash -c '. "$1/bin/fm-supervise-daemon.sh"; housekeeping "$2"' _ "$ROOT" "$dir/home/state" \
  >/dev/null 2>&1
echo "  escalation buffer: $(cat "$dir/home/state/.subsuper-escalations" 2>/dev/null || echo '(empty)')"
echo "  phantom seen-file: $(cat "$dir/home/state/.seen-status-parent-replies" 2>/dev/null; cat "$dir/home/state/.subsuper-seen-status-parent-replies" 2>/dev/null || echo '(none)')"

echo
echo "### real fm-wake-drain.sh over a remote mate home"
dir="$W/drain"; seed_remote_mate "$dir/home"; mkdir -p "$dir/home/data"
FM_STATE_OVERRIDE="$dir/home/state" FM_HOME="$dir/home" "$ROOT/bin/fm-wake-drain.sh" > "$W/drain.out"
grep -n 'parent-replies\|captain-hold\|release branch' "$W/drain.out" | sed 's/^/  drain says: /' || true
grep -q 'parent-replies' "$W/drain.out" \
  && echo "  => LEAK: channel content presented" || echo "  => no channel content"
echo
echo "### fixed tree (helper active) for comparison"
cp "$W/fm-classify-lib.sh.orig" "$LIB"
dir="$W/fixed"; seed_remote_mate "$dir/home"; mkdir -p "$dir/home/data"
FM_STATE_OVERRIDE="$dir/home/state" FM_HOME="$dir/home" "$ROOT/bin/fm-wake-drain.sh" > "$W/fixed.out"
grep -c 'parent-replies' "$W/fixed.out" | sed 's/^/  channel lines in drain output: /'
FM_STATE_OVERRIDE="$dir/home/state" FM_HOME="$dir/home" STATE="$dir/home/state" \
  bash -c '. "$1/bin/fm-watch.sh"; scan_signals' _ "$ROOT" | cut -f3 | sed 's/^/  enumerated: /'
