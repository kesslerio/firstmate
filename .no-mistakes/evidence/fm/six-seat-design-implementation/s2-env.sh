# source me: lab env for scenario 2 commands
E=/Users/kesslerio/.no-mistakes/evidence/01M3RP9FKDWJ4VTFQQY8Q2R70E
LAB="$E/s2l"; MATE="$E/s2m"
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE HERDR_SESSION HERDR_SOCKET_PATH HERDR_PANE_ID
export TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB"
TMUX=$(tmux -L fm-lab display-message -p -t primary '#{socket_path},#{pid},0'); export TMUX
