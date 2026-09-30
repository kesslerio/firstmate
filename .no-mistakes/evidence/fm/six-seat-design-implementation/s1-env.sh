E=/Users/kesslerio/.no-mistakes/evidence/01M3RP9FKDWJ4VTFQQY8Q2R70E
LAB="$E/s1l"; LR=$(cat "$E/s1-remote-lab-root")
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE HERDR_SESSION HERDR_SOCKET_PATH HERDR_PANE_ID TMUX
export FM_HOME="$LAB" FM_SSH_BIN="$E/s1-ssh.sh"
cd "$E/s1c" || return 1
T="$E/s1-transcript.log"
run() { printf '\n$ %s\n' "$*" >> "$T"; "$@" >> "$T" 2>&1; local rc=$?; printf 'exit=%s\n' "$rc" >> "$T"; return $rc; }
note() { printf '\n## %s\n' "$*" >> "$T"; }
