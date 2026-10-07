#!/usr/bin/env bash
set -eu
ROOT=$PWD
E=/home/art/.no-mistakes/evidence/01M4B0WCFKS0F03ZZ5EPCCQ72P
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_TEST_SEAM FM_TEST_HARNESS CLAUDE_CONFIG_DIR
export FM_HOME="$ROOT/.phase/away-home"
"$ROOT/bin/fm-lab-home.sh" create "$FM_HOME"
trap 'rm -rf "$FM_HOME"' EXIT
cp .tasks.toml "$FM_HOME/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$FM_HOME/data/backlog.md"
bin/fm-tasks-axi.sh add other 'out of scope ready unit'
bin/fm-tasks-axi.sh update other --body 'Existing note to preserve.'
bin/fm-tasks-axi.sh add held 'explicit captain hold'
bin/fm-captain-hold.sh hold held --reason 'design pick waits for captain'
bin/fm-afk-contract.sh enter --spend 4 --words 'No dispatch is authorized. Do not merge, push, open a PR, or change global configuration.'
STATE="$FM_HOME/state"; FM_ROOT="$ROOT"
export STATE FM_ROOT FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=away-review FM_LEASE_HOLDER_PID=$$
printf '%s\n' "$$" > "$STATE/.lock"
printf 'turn=away-review\nunscoped=1\nrows=\ntasks=\nwake=heartbeat\nposture=away\n' > "$STATE/.supervision-host-turn"
. bin/fm-wake-lib.sh
fm_wake_append heartbeat heartbeat heartbeat
bin/fm-wake-grant.sh activate "$$" away-review
rows=$(awk -F '\t' '{print $2}' "$STATE/.wake-queue")
bin/fm-wake-grant.sh publish away-review $rows
bin/fm-afk-contract.sh readback > "$E/away-readback.txt"
bin/fm-branch-prompt.sh > "$ROOT/.phase/prompt"
printf 'heartbeat\n' | bin/fm-branch-dispatch.mjs wake-prompt --report bin/fm-branch-report.sh --away --readback-file "$E/away-readback.txt" > "$ROOT/.phase/wake"
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
fm_supervision_engine_turn claude sonnet "$ROOT/.phase/prompt" "$ROOT/.phase/wake" "$session" new 180 "$E/away-result.json" "$E/away-errors.txt" || rc=$?
printf 'engine_exit=%s\n' "$rc"
bin/fm-tasks-axi.sh show other --full
bin/fm-tasks-axi.sh show held --full
cat "$STATE/branch-outcomes.jsonl" 2>/dev/null || true
printf 'wake_remaining='; wc -c < "$STATE/.wake-queue"
[ "$rc" = 0 ]
