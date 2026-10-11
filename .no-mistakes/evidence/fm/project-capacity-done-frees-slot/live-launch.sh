#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
LAB="$PWD/.l"
[ ! -e "$LAB" ]
cleanup() {
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null || true
  [ ! -d "$LAB/state/candidate.git-hooks" ] || chmod u+w "$LAB/state/candidate.git-hooks"
  rm -rf "$LAB"
}
trap cleanup EXIT
bin/fm-lab-home.sh create "$LAB"
mkdir -p "$LAB/tmux" "$LAB/codex"
export FM_HOME="$LAB" CODEX_HOME="$LAB/codex" TMUX_TMPDIR="$LAB/tmux" HOME="$LAB"
unset FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux
git init -q --bare "$LAB/origin.git"
git clone -q "$LAB/origin.git" "$LAB/projects/project"
PROJECT="$LAB/projects/project"
printf 'Disposable capacity fixture\n' > "$PROJECT/README.md"
printf 'max_trees = 2\nroot = "%s"\n' "$LAB" > "$PROJECT/treehouse.toml"
git -C "$PROJECT" add .
git -C "$PROJECT" -c user.name='Lab' -c user.email='lab@example.invalid' commit -qm fixture
git -C "$PROJECT" push -q origin HEAD
printf 'project 1\n' > "$LAB/config/project-capacity"
printf 'kind=scout\nmode=no-mistakes\nproject=%s\n' "$PROJECT" > "$LAB/state/holder.meta"
printf 'done: complete\ncaptain-held: report delivered\n' > "$LAB/state/holder.status"
mkdir -p "$LAB/data/candidate"
cat > "$LAB/data/candidate/brief.md" <<'EOF'
# Task
## Captain's intent
Verify that the completed scout frees this disposable lab's capacity slot.
## Firstmate spec
Do not modify any files. State that the lab launch was received and stop.
# Definition of done
Delivery contract: mode=local-only
EOF
tmux -L fm-lab new-session -d -s firstmate -x 120 -y 40 -c "$ROOT" 'bash --noprofile --norc'
export TMUX="$(tmux -L fm-lab display-message -p '#{socket_path}'),$(tmux -L fm-lab display-message -p '#{pid}'),0"
timeout -k 5s 100s bin/fm-spawn.sh candidate "$PROJECT" --mode local-only --yolo off --harness codex
cat "$LAB/state/candidate.meta"
printf '\nCandidate pane after launch:\n'
tmux -L fm-lab capture-pane -p -t firstmate:fm-candidate
printf '\nAttempting a second candidate while first candidate holds the slot:\n'
rc=0
bin/fm-spawn.sh second "$PROJECT" --mode local-only --yolo off --harness codex || rc=$?
[ "$rc" = 75 ]
[ ! -e "$LAB/state/second.meta" ]
tmux -L fm-lab list-panes -a -F '#{window_name} #{pane_current_command} #{pane_current_path}'
printf '\nLaunch verified; private server and disposable lab will be removed.\n'
