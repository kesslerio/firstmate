#!/usr/bin/env bash
set -eu
EVIDENCE=/home/art/.no-mistakes/evidence/01M53EGCQXW2H51Q8EPQ12MT36
LAB="$EVIDENCE/h2"
bin/fm-lab-home.sh create "$LAB"
mkdir -p "$LAB/tmux"
cleanup() {
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null || true
  if TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab list-sessions 2>/dev/null; then echo 'ERROR server survived'; return 1; fi
  rm -rf "$LAB" "$PWD/.test-sol-lab"
}
trap cleanup EXIT
touch "$LAB/config/supervision-host"
printf '%s\n' '{"default":{"harness":"codex","model":"gpt-6.1-sol"}}' > "$LAB/config/crew-dispatch.json"
for n in 1 2 3 4; do printf 'held-%s\tgpt-6.1-sol\t1\t0\n' "$n"; done > "$LAB/state/sol-sessions.tsv"
mkdir -p "$LAB/data/fifth"
cat > "$LAB/data/fifth/brief.md" <<'BRIEF'
# Task
## Captain's intent
Exercise refusal of a fifth Sol worker.
## Firstmate spec
The four-session ceiling refuses this spawn without creating an endpoint.
# Definition of done
Delivery contract: mode=local-only
BRIEF
mkdir -p .test-sol-lab/project
git -C .test-sol-lab/project init -q
git -C .test-sol-lab/project -c user.name='Lab' -c user.email=lab@example.invalid -c core.hooksPath=/dev/null commit --allow-empty -qm Initial
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -x 120 -y 40 -c "$PWD" -e FM_HOME="$LAB" claude
sleep 4
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab capture-pane -p -t primary > "$EVIDENCE/round2-lab-primary.txt"
SOCKET=$(TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab display-message -p -t primary '#{socket_path}')
set +e
env -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME="$LAB" TMUX="$SOCKET,0,0" FM_BACKEND=tmux bin/fm-spawn.sh fifth "$PWD/.test-sol-lab/project" --harness codex --model gpt-6.1-sol --mode local-only --yolo off > "$EVIDENCE/round2-live-spawn-refusal.log" 2>&1
rc=$?
set -e
cat "$EVIDENCE/round2-live-spawn-refusal.log"
echo "spawn exit=$rc"
[ "$rc" = 1 ]
grep -q 'Sol ceiling reached' "$EVIDENCE/round2-live-spawn-refusal.log"
[ ! -e "$LAB/state/fifth.meta" ]
[ ! -e "$LAB/data/fifth/launch-brief.md" ]
[ "$(TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab list-windows -t primary -F '#{window_id}' | wc -l)" -eq 1 ]
echo 'Refusal created no metadata, rendered launch brief, or worker window.'
