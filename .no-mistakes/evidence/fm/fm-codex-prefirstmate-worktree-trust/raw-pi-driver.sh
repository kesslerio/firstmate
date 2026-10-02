#!/usr/bin/env bash
set -euo pipefail
. tests/fixtures.sh
TMP_ROOT=$(fm_test_tmproot fm-raw-pi-live)
SOCKET="$TMP_ROOT/tmux.sock"
cleanup_raw() {
  tmux -S "$SOCKET" kill-session -t fmft-pi-raw >/dev/null 2>&1 || true
  tmux -S "$SOCKET" kill-server >/dev/null 2>&1 || true
  fm_test_cleanup
}
trap cleanup_raw EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP
trap 'exit 131' QUIT
CASE="$TMP_ROOT/case"
PROJ="$CASE/project"
WT="$CASE/wt"
fm_git_worktree "$PROJ" "$WT" raw-pi
printf '{}\n' > "$TMP_ROOT/treehouse-state.json"
mkdir -p "$WT/.pi/extensions" "$CASE/pi-root"
[ ! -f "$HOME/.pi/agent/auth.json" ] || ln -s "$HOME/.pi/agent/auth.json" "$CASE/pi-root/auth.json"
[ ! -f "$HOME/.pi/agent/models.json" ] || ln -s "$HOME/.pi/agent/models.json" "$CASE/pi-root/models.json"
fakebin=$(fm_test_make_spawn_fakebin "$CASE/fake" pi)
fm_test_spawn_home "$CASE/home" pi
fm_test_spawn_brief "$CASE/home" raw-pi
FM_FAKE_LAUNCH_LOG="$CASE/launch.log" fm_test_run_spawn "$CASE/home" "$WT" "$fakebin" raw-pi "$PROJ" 'pi --tui-mode regular' --mode no-mistakes --yolo off
launch=$(cat "$CASE/launch.log")
python3 - "$launch" <<'PY'
import shlex, sys
words=shlex.split(sys.argv[1])
flags=words[words.index('pi')+1:]
assert flags == ['--approve','--tui-mode','regular'], flags
print('Exact emitted raw Pi argv:', flags)
PY
printf '%s\n' "$launch"
tmux -S "$SOCKET" new-session -d -s fmft-pi-raw -x 160 -y 45 -c "$WT" "env PI_CODING_AGENT_DIR='$CASE/pi-root' $launch"
for ((i=0; i<30; i++)); do
  text=$(tmux -S "$SOCKET" capture-pane -p -t fmft-pi-raw)
  case "$text" in
    *'Trust project folder?'*) printf 'ERROR: raw Pi launch stalled on project trust\n'; exit 1 ;;
    *'escape interrupt'*|*'ctrl+o'*)
      [ ! -f "$CASE/pi-root/trust.json" ]
      printf 'Raw Pi launch reached the real editor with no trust prompt and no persisted approval.\n'
      exit 0 ;;
  esac
  sleep 1
done
printf 'ERROR: raw Pi editor did not start: %s\n' "$text"
exit 1
