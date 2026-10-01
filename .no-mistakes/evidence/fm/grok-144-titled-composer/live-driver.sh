#!/usr/bin/env bash
# Consolidated live driver for the Grok approval-titled composer check.
# Runs the real bin/fm-tmux-lib.sh adapter against real panes on a private
# lab tmux socket, and records every verdict.
set -u
LAB=$(cat /tmp/fmlab_path)
SHIM=$(cat /tmp/fmshim)
EV=/Users/kesslerio/.no-mistakes/evidence/01M3VG2XT06ZJK831A1ZYK8CV6
ROOT=/Users/kesslerio/.no-mistakes/worktrees/8036f35f7c08/01M3VG2XT06ZJK831A1ZYK8CV6
export TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB"
export PATH="$SHIM:$PATH"
cd "$ROOT"
# shellcheck source=bin/fm-tmux-lib.sh
. bin/fm-tmux-lib.sh

state() { fm_tmux_composer_state "$1"; }
pend() { if fm_pane_input_pending "$1"; then printf defers; else printf injectable; fi; }

{
  printf '# live verdicts - real tmux adapter (bin/fm-tmux-lib.sh) on a private lab socket\n'
  printf '# grok %s, pane launched as `grok --always-approve`\n\n' "$(grok --version 2>/dev/null | head -1)"
  printf '%-20s %-9s %s\n' WINDOW VERDICT INJECTION_GUARD
  printf '%-20s %-9s %s\n' grok-idle "$(state primary)" "$(pend primary)"
} > "$EV/live-verdicts.txt"

tmux new-window -d -t primary: -n blankshell -c "$ROOT" -- \
  bash -c 'printf "\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\n\n"; printf "\033[A"; exec sleep 240'
render() { tmux new-window -d -t primary: -n "$1" -c "$ROOT" -- bash /tmp/fm_render_fixture.sh "$2" "$3" "${4:-$3}"; }
render t_ok     'Grok 4.7 (high) · always-approve'         74
render t_low    'Grok 4.6 (low) · always-approve'          74
render t_105    'Grok 4.6 (xhigh)'                         74 77
render t_overh  'Grok 4.7 (high) · always-approve'         74 77
render t_badw   'Grok 4.7 (high) · always-approve'         74 75
render t_bad    'Grok 4.7 (high) · auto-approve'           74
render t_trail  'Grok 4.7 (high) · always-approve now'     74
render t_other  'Other 4.7 (high) · always-approve'        74
render t_effort 'Grok 4.7 (turbo) · always-approve'        74
render t_dot    'unknown surface · mode'                   74
render t_dot2   'Grok 4.7 (high) · always-approve · extra' 74
sleep 2
for w in blankshell t_ok t_low t_105 t_overh t_badw t_bad t_trail t_other t_effort t_dot t_dot2; do
  printf '%-20s %-9s %s\n' "$w" "$(state "primary:$w")" "$(pend "primary:$w")" >> "$EV/live-verdicts.txt"
done

# Cursorless reads of the SAME real pane (how herdr/zellij/cmux/orca read it).
pane=$(fm_tmux_composer_capture primary)
printf '\n# cursorless re-read of the real idle pane (herdr/zellij profile, then cmux/orca profile)\n' >> "$EV/live-verdicts.txt"
printf 'herdr_profile=%s\n' "$(fm_composer_classify_screen "$(printf 'styled=1\ncursor=0\nidentity=1\nrows=0')" "$pane")" >> "$EV/live-verdicts.txt"
printf 'cmux_orca_profile=%s\n' "$(fm_composer_classify_screen "$(printf 'styled=0\ncursor=0\nidentity=0\nrows=0')" "$pane")" >> "$EV/live-verdicts.txt"

tmux capture-pane -p -t primary | grep . | tail -6 > "$EV/live-grok-idle-pane.txt"
tmux capture-pane -p -e -t primary > "$EV/live-grok-idle-pane.ansi.txt"
tmux send-keys -t primary -l 'deploy the fix'
sleep 2
{
  printf '\n# adversarial: real draft typed into the live approval-titled composer\n'
  printf 'grok-typed verdict=%s guard=%s\n' "$(state primary)" "$(pend primary)"
  tmux capture-pane -p -t primary | grep . | tail -4
} >> "$EV/live-verdicts.txt"
tmux capture-pane -p -t primary | grep . | tail -6 > "$EV/live-grok-typed-pane.txt"
cat "$EV/live-verdicts.txt"
