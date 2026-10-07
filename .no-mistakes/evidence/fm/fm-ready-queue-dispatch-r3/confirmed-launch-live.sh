#!/usr/bin/env bash
set -eu
ROOT=$PWD
export PATH="$ROOT/.phase/bin:$PATH"
E=/home/art/.no-mistakes/evidence/01M4B0WCFKS0F03ZZ5EPCCQ72P
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_TEST_SEAM FM_TEST_HARNESS CLAUDE_CONFIG_DIR
export FM_HOME="$ROOT/.phase/confirmed-launch-home"
"$ROOT/bin/fm-lab-home.sh" create "$FM_HOME"
SOCKET_ROOT="$ROOT/.phase/t"
mkdir -p "$SOCKET_ROOT"
cleanup() { chmod -R u+w "$FM_HOME"; TMUX_TMPDIR="$SOCKET_ROOT" tmux -L fm-lab kill-server 2>/dev/null || true; rm -rf "$FM_HOME" "$SOCKET_ROOT"; }
trap cleanup EXIT
export TMPDIR="$ROOT/.phase/tmp"
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
bin/fm-afk-contract.sh enter --spend 4 --words 'Dispatch the queued unit next using its existing brief and local-only contract with Codex. Only next is authorized. Do not merge, push, or open a PR. At the Codex folder-trust dialog, use Enter as authorized; never pre-accept hook trust in a store.'
bin/fm-tasks-axi.sh add next 'authorized proof unit'
bin/fm-tasks-axi.sh update next --body "Project: $ROOT/.phase/fixture. Brief is $FM_HOME/data/next/brief.md. Dispatch via bin/fm-spawn.sh next $ROOT/.phase/fixture --mode local-only --yolo off --harness codex. A note is not a live worker."

STATE="$FM_HOME/state"; FM_ROOT="$ROOT"
export STATE FM_ROOT FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=confirmed-launch-review FM_LEASE_HOLDER_PID=$$
printf '%s\n' "$$" > "$STATE/.lock"
printf 'turn=confirmed-launch-review\nunscoped=1\nrows=\ntasks=\nwake=heartbeat\nposture=away\n' > "$STATE/.supervision-host-turn"
. bin/fm-wake-lib.sh
fm_wake_append heartbeat heartbeat heartbeat
bin/fm-wake-grant.sh activate "$$" confirmed-launch-review
rows=$(awk -F '\t' '{print $2}' "$STATE/.wake-queue")
bin/fm-wake-grant.sh publish confirmed-launch-review $rows
bin/fm-afk-contract.sh readback > "$E/confirmed-launch-readback.txt"
bin/fm-branch-prompt.sh > "$ROOT/.phase/prompt"
printf 'heartbeat\n' | bin/fm-branch-dispatch.mjs wake-prompt --report bin/fm-branch-report.sh --away --readback-file "$E/confirmed-launch-readback.txt" > "$ROOT/.phase/wake"
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
fm_supervision_engine_turn claude sonnet "$ROOT/.phase/prompt" "$ROOT/.phase/wake" "$session" new 240 "$E/confirmed-launch-result.json" "$E/confirmed-launch-errors.txt" || rc=$?
python3 - <<'VERIFY'
import os, subprocess, time, pathlib
root=pathlib.Path.cwd(); home=pathlib.Path(os.environ['FM_HOME']); evidence=pathlib.Path('/home/art/.no-mistakes/evidence/01M4B0WCFKS0F03ZZ5EPCCQ72P')
def run(args): return subprocess.run(args, text=True, capture_output=True)
meta=home/'state/next.meta'
assert meta.exists(), 'supervision did not create worker metadata'
fields=dict(line.split('=',1) for line in meta.read_text().splitlines() if '=' in line)
print(meta.read_text(),flush=True)
worker=pathlib.Path(fields['worktree'])
assert worker.is_relative_to(root), 'worker escaped workspace'
target=fields.get('window','primary:fm-next')
trust_answered=False
for n in range(120):
    pane=run(['tmux','-L','fm-lab','capture-pane','-p','-t',target]).stdout
    if ('Trust this folder?' in pane or 'Do you trust the contents' in pane) and not trust_answered:
        (evidence/'confirmed-launch-trust.txt').write_text(pane)
        print('Reproduced folder-trust startup gate; sending authorized Enter',flush=True)
        sent=run(['bin/fm-send.sh','next','--key','Enter'])
        print(sent.stdout+sent.stderr,flush=True)
        assert sent.returncode==0
        trust_answered=True
    if (home/'data/next/proof.txt').exists():
        assert (home/'data/next/proof.txt').read_text().strip()=='493', 'worker produced incorrect result'
        live=run(['tmux','-L','fm-lab','list-panes','-t',target,'-F','#{pane_dead} #{pane_pid} #{pane_current_command}'])
        assert live.returncode==0 and live.stdout.startswith('0 '), 'worker endpoint not live'
        (evidence/'confirmed-launch-worker.txt').write_text(pane+'\nLive endpoint: '+live.stdout+'\nProof: '+(home/'data/next/proof.txt').read_text())
        print('PASS: live Codex worker processed launch brief and wrote 493',flush=True)
        break
    time.sleep(1)
else:
    (evidence/'confirmed-launch-worker.txt').write_text(pane)
    raise AssertionError('worker did not process brief within 120 seconds')
VERIFY
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
