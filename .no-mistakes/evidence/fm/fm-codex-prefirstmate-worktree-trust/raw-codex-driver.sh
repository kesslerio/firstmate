#!/usr/bin/env bash
set -euo pipefail
AUTH_FILE="${CODEX_HOME:-$HOME/.codex}/auth.json"
. tests/fixtures.sh
TMP_ROOT=$(fm_test_tmproot fm-raw-codex-live)
SOCKET="$TMP_ROOT/tmux.sock"
cleanup_raw() {
  tmux -S "$SOCKET" kill-session -t fmft-codex-raw >/dev/null 2>&1 || true
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
SELECTED="$CASE/custom codex store"
fm_git_worktree "$PROJ" "$WT" raw-codex
printf '{}\n' > "$TMP_ROOT/treehouse-state.json"
mkdir -p "$SELECTED"
ln -s "$AUTH_FILE" "$SELECTED/auth.json"
printf 'check_for_update_on_startup = false\n' > "$SELECTED/config.toml"
fakebin=$(fm_test_make_spawn_fakebin "$CASE/fake" codex)
fm_test_spawn_home "$CASE/home" codex
fm_test_spawn_brief "$CASE/home" raw-codex
FM_TEST_CODEX_HOME="$CASE/supervisor-store" FM_FAKE_LAUNCH_LOG="$CASE/launch.log" fm_test_run_spawn "$CASE/home" "$WT" "$fakebin" raw-codex "$PROJ" "CODEX_HOME='$SELECTED' codex --disable hooks" --mode no-mistakes --yolo off
launch=$(cat "$CASE/launch.log")
python3 - "$launch" "$SELECTED" "$PROJ" "$CASE/supervisor-store" <<'PY'
import shlex, sys, tomllib
from pathlib import Path
words=shlex.split(sys.argv[1])
assignments=[word for word in words if word.startswith('CODEX_HOME=')]
assert assignments == ['CODEX_HOME='+sys.argv[2]], assignments
config=tomllib.loads((Path(sys.argv[2])/'config.toml').read_text())
assert config['projects'][sys.argv[3]]['trust_level']=='trusted'
assert not (Path(sys.argv[4])/'config.toml').exists()
flags=words[words.index('codex')+1:]
assert flags == ['--disable', 'hooks'], flags
print('Exactly one launch-store assignment; matching repository trust saved in custom store; supervisor store untouched; replay has no positional prompt.')
PY
printf '%s\n' "$launch"
cp "$SELECTED/config.toml" "$FM_EVIDENCE_DIR/raw-codex-config.toml"
tmux -S "$SOCKET" new-session -d -s fmft-codex-raw -x 160 -y 45 -c "$WT" "$launch"
for ((i=0; i<30; i++)); do
  text=$(tmux -S "$SOCKET" capture-pane -p -t fmft-codex-raw)
  case "$text" in
    *'Trust this folder?'*) printf 'ERROR: raw Codex launch stalled on folder trust\n'; exit 1 ;;
    *'› '* )
      case "$text" in
        *'Ask Codex to do anything'*|*'? for shortcuts'*)
          printf 'Raw Codex launch read the custom store and reached the real editor without folder trust.\n'
          exit 0 ;;
      esac ;;
  esac
  sleep 1
done
printf 'ERROR: raw Codex editor did not start: %s\n' "$text"
exit 1
