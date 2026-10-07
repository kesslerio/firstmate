#!/usr/bin/env bash
set -eu
ROOT=$PWD
export PATH="$ROOT/.phase/bin:$PATH"
E=/home/art/.no-mistakes/evidence/01M4B0WCFKS0F03ZZ5EPCCQ72P
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_TEST_SEAM FM_TEST_HARNESS CLAUDE_CONFIG_DIR
export FM_HOME="$ROOT/.phase/launch-home"
"$ROOT/bin/fm-lab-home.sh" create "$FM_HOME"
SOCKET_ROOT="$E/t"
mkdir -p "$SOCKET_ROOT"
cleanup() { chmod -R u+w "$FM_HOME"; TMUX_TMPDIR="$SOCKET_ROOT" tmux -L fm-lab kill-server 2>/dev/null || true; rm -rf "$FM_HOME" "$SOCKET_ROOT"; }
trap cleanup EXIT
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$SOCKET_ROOT" tmux -L fm-lab new-session -d -s primary -x 120 -y 40 -c "$PWD" -e FM_HOME="$FM_HOME" codex
export TMUX_TMPDIR="$SOCKET_ROOT"
export TMUX=$(tmux -L fm-lab display-message -p -t primary '#{socket_path},#{pid},0')
export FM_PRIMARY_HARNESS=codex FM_BACKEND=tmux
touch "$FM_HOME/config/supervision-host"
printf 'codex\n' > "$FM_HOME/config/crew-harness"
bin/fm-brief.sh next fixture --mode local-only
python3 - "$FM_HOME/data/next/brief.md" <<'EDIT'
import sys
from pathlib import Path
p=Path(sys.argv[1]); s=p.read_text().replace('{TASK}', 'Write the product of 17 and 29 into proof.txt, then report completion. Do not push or open a PR.').replace('{FIRSTMATE_SPEC}', 'Work only in your disposable fixture worktree. Local-only; no merge or external delivery.'); p.write_text(s)
EDIT

cp .tasks.toml "$FM_HOME/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$FM_HOME/data/backlog.md"
bin/fm-tasks-axi.sh add other 'out of scope ready unit'
bin/fm-tasks-axi.sh update other --body 'Existing note to preserve.'
bin/fm-tasks-axi.sh add held 'explicit captain hold'
bin/fm-captain-hold.sh hold held --reason 'design pick waits for captain'
bin/fm-afk-contract.sh enter --spend 4 --words 'Dispatch the queued unit next using its existing brief and local-only contract with Codex. Only next is authorized. Do not merge, push, open a PR, or change global configuration.'
bin/fm-tasks-axi.sh add next 'authorized proof unit'
bin/fm-tasks-axi.sh update next --body "Project: $ROOT/.phase/fixture. Brief is $FM_HOME/data/next/brief.md. Dispatch via bin/fm-spawn.sh next $ROOT/.phase/fixture --mode local-only --yolo off --harness codex. A note is not a live worker."

STATE="$FM_HOME/state"; FM_ROOT="$ROOT"
export STATE FM_ROOT FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=launch-review FM_LEASE_HOLDER_PID=$$
printf '%s\n' "$$" > "$STATE/.lock"
printf 'turn=launch-review\nunscoped=1\nrows=\ntasks=\nwake=heartbeat\nposture=away\n' > "$STATE/.supervision-host-turn"
. bin/fm-wake-lib.sh
fm_wake_append heartbeat heartbeat heartbeat
bin/fm-wake-grant.sh activate "$$" launch-review
rows=$(awk -F '\t' '{print $2}' "$STATE/.wake-queue")
bin/fm-wake-grant.sh publish launch-review $rows
bin/fm-afk-contract.sh readback > "$E/launch-readback.txt"
bin/fm-branch-prompt.sh > "$ROOT/.phase/prompt"
printf 'heartbeat\n' | bin/fm-branch-dispatch.mjs wake-prompt --report bin/fm-branch-report.sh --away --readback-file "$E/launch-readback.txt" > "$ROOT/.phase/wake"
cat > "$ROOT/.phase/engine" <<'ENGINE'
#!/usr/bin/env bash
exec claude --no-session-persistence "$@"
ENGINE
chmod +x "$ROOT/.phase/engine"
export FM_SUPERVISION_ENGINE_CLAUDE_BIN="$ROOT/.phase/engine"
. bin/fm-supervision-engine-lib.sh
. bin/fm-timeout-lib.sh
session=$(python3 -c 'import uuid; print(uuid.uuid4())')
rc=0
fm_supervision_engine_turn claude sonnet "$ROOT/.phase/prompt" "$ROOT/.phase/wake" "$session" new 240 "$E/launch-result.json" "$E/launch-errors.txt" || rc=$?
printf 'engine_exit=%s\n' "$rc"
bin/fm-tasks-axi.sh show other --full
bin/fm-tasks-axi.sh show held --full
cat "$STATE/branch-outcomes.jsonl" 2>/dev/null || true
bin/fm-tasks-axi.sh show next --full
bin/fm-crew-state.sh next || true
tmux -L fm-lab list-panes -a -F '#{window_name} #{pane_id} #{pane_dead}'
for pane in $(tmux -L fm-lab list-panes -a -F '#{pane_id}'); do tmux -L fm-lab capture-pane -p -t "$pane"; done
printf 'wake_remaining='; wc -c < "$STATE/.wake-queue"
[ "$rc" = 0 ]
