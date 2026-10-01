#!/usr/bin/env bash
# Live drive: the away-mode supervisor (bin/fm-supervise-daemon.sh, run through
# its own source guard) against a disposable state root.
# Usage: drive-daemon.sh <case> <newest status line>
set -u
ROOT=/Users/kesslerio/.no-mistakes/worktrees/8036f35f7c08/01M3VPK3RDXETQSJYZNQ716E37
case_name=$1; line=$2
dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-daemon-drive.$case_name.XXXXXX")
state=$dir/state; fakebin=$dir/fakebin
mkdir -p "$state" "$fakebin" "$dir/wt"
cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message) printf 'fakepane\n'; exit 0 ;;
  capture-pane) cat "${FM_FAKE_TMUX_CAPTURE:-/dev/null}" 2>/dev/null; exit 0 ;;
esac
exit 1
SH
chmod +x "$fakebin/tmux"
task=parked; win="sess:fm-$task"; key=$(printf '%s' "$task" | tr ':/.' '___')
printf 'idle prompt $\n' > "$dir/pane.txt"
printf '%s\n' "$line" > "$state/$task.status"
printf 'window=%s\nworktree=%s\nkind=ship\nharness=pi\n' "$win" "$dir/wt" > "$state/$task.meta"
size=$(LC_ALL=C wc -c < "$state/$task.status" | tr -d '[:space:]')
ident=$(cd "$ROOT" && bash -c '. bin/fm-classify-lib.sh; _fm_open_decisions_file_ident "$1"' _ "$state/$task.status")
printf '%s@%s' "$size" "$ident" > "$state/.subsuper-seen-status-$key"

step() {  # <label> <shell snippet>; runs against the real daemon script
  echo "--- $1"
  ( cd "$ROOT" && PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$win" \
      FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" FM_STATE_OVERRIDE="$state" \
      FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=3600 \
      FM_ESCALATE_BATCH_SECS=999999 FM_SUPERVISOR_TARGET="$win" WIN="$win" \
      bash -c '. bin/fm-supervise-daemon.sh; STATE="$(_state_root)"; eval "$1"' _ "$2" ) 2>&1 | sed 's/^/    /'
}
esc() { [ -s "$state/.subsuper-escalations" ] && wc -l < "$state/.subsuper-escalations" | tr -d ' ' || echo 0; }

echo "=== away-mode case: $case_name"
echo "=== newest status line: $line"
step "what the away supervisor classifies this quiet pane as:" \
  'classify_stale "$WIN" "$STATE"; echo'
echo
date +%s > "$state/.subsuper-stale-$key"
step "handle_wake on the lane's quiet (a wedge marker was pending before the park):" \
  'handle_wake "stale: $WIN" "$STATE"'
echo "    pause marker to age on: $([ -e "$state/.subsuper-paused-$key" ] && echo yes || echo NO)"
echo "    possible-wedge marker kept: $([ -e "$state/.subsuper-stale-$key" ] && echo YES || echo no)"
echo "    escalations raised: $(esc)"

echo $(( $(date +%s) - 500 )) > "$state/.subsuper-stale-$key"
date +%s > "$state/.subsuper-last-scan"
step "housekeeping past the wedge bound:" 'housekeeping "$STATE"'
echo "    escalations after the bound: $(esc)  (0 = no possible-wedge alarm)"

echo $(( $(date +%s) - 5000 )) > "$state/.subsuper-paused-$key"
step "housekeeping past the recheck cadence:" 'housekeeping "$STATE"'
echo "    escalations now: $(esc)"
sed 's/^/      /' "$state/.subsuper-escalations" 2>/dev/null
echo "    recheck window reset: age $(( $(date +%s) - $(cat "$state/.subsuper-paused-$key" 2>/dev/null || echo 0) ))s"

: > "$state/.subsuper-escalations"
printf 'working: CI is green, resuming\n' >> "$state/$task.status"
printf '%s@%s' "$(LC_ALL=C wc -c < "$state/$task.status" | tr -d '[:space:]')" "$ident" > "$state/.subsuper-seen-status-$key"
step "the lane moves on: handle_wake after a newer status line:" 'handle_wake "stale: $WIN" "$STATE"'
echo "    back on the wedge ladder: $([ -e "$state/.subsuper-stale-$key" ] && echo yes || echo NO)"
echo "    pause tracking dropped: $([ ! -e "$state/.subsuper-paused-$key" ] && echo yes || echo NO)"
echo $(( $(date +%s) - 500 )) > "$state/.subsuper-stale-$key"
step "housekeeping after resume:" 'housekeeping "$STATE"'
echo "    escalations after resume:"
sed 's/^/      /' "$state/.subsuper-escalations" 2>/dev/null
rm -rf "$dir"
