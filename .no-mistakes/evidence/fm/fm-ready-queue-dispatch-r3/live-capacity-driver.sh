#!/usr/bin/env bash
set -eu
ROOT=$PWD
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_TEST_SEAM TASKS_AXI_FILE TASKS_AXI_BACKEND
export FM_HOME="$ROOT/.validation/home"
printf 'probe 1\n' > "$FM_HOME/config/project-capacity"
printf '%s\n' '- probe [local-only] - disposable lab' > "$FM_HOME/data/projects.md"
"$ROOT/bin/fm-tasks-axi.sh" add successor 'authorized successor'
"$ROOT/bin/fm-tasks-axi.sh" block successor --by probe
"$ROOT/bin/fm-brief.sh" successor probe --mode local-only
python3 - "$FM_HOME/data/successor/brief.md" <<'EDIT'
from pathlib import Path
import sys
p=Path(sys.argv[1]); p.write_text(p.read_text().replace('{TASK}', 'Read seed.txt and report the token.').replace('{FIRSTMATE_SPEC}', 'This is a disposable validation fixture; do not push or open a PR.'))
EDIT
set +e
"$ROOT/bin/fm-spawn.sh" successor "$FM_HOME/projects/probe" --mode local-only --yolo off --harness codex --backend tmux
rc=$?
set -e
test "$rc" = 75
test ! -e "$FM_HOME/state/successor.meta"
"$ROOT/bin/fm-tasks-axi.sh" show successor
printf 'LIVE capacity: second worker deferred without acquiring endpoint\n'
git -C "$FM_HOME/projects/probe" merge --ff-only fm/probe
"$ROOT/bin/fm-teardown.sh" probe
"$ROOT/bin/fm-tasks-axi.sh" ready
test ! -e "$FM_HOME/state/probe.meta"
printf 'LIVE teardown: finished worker retired, successor dependency cleared, ready-work check surfaced\n'
