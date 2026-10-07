#!/usr/bin/env bash
set -eu
ROOT=$PWD
E=/home/art/.no-mistakes/evidence/01M4B0WCFKS0F03ZZ5EPCCQ72P
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_TEST_SEAM FM_TEST_HARNESS CLAUDE_CONFIG_DIR
export FM_HOME="$ROOT/.phase/finish-home"
"$ROOT/bin/fm-lab-home.sh" create "$FM_HOME"
trap 'rm -rf "$FM_HOME"' EXIT
cp .tasks.toml "$FM_HOME/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$FM_HOME/data/backlog.md"
bin/fm-tasks-axi.sh add other 'out of scope ready unit'
bin/fm-tasks-axi.sh update other --body 'Existing note to preserve.'
bin/fm-tasks-axi.sh add held 'explicit captain hold'
bin/fm-captain-hold.sh hold held --reason 'design pick waits for captain'
bin/fm-tasks-axi.sh add dependency 'finished predecessor'
bin/fm-tasks-axi.sh block other --by dependency
bin/fm-tasks-axi.sh 'done' dependency --pr https://github.com/example/fixture/pull/1
STATE="$FM_HOME/state"; FM_ROOT="$ROOT"
export STATE FM_ROOT FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=finish-review FM_LEASE_HOLDER_PID=$$
printf '%s\n' "$$" > "$STATE/.lock"
printf 'turn=finish-review\nunscoped=1\nrows=\ntasks=\nwake=heartbeat\nposture=attended\n' > "$STATE/.supervision-host-turn"
. bin/fm-wake-lib.sh
fm_wake_append check dependency 'check: finished predecessor dependency'
bin/fm-wake-grant.sh activate "$$" finish-review
rows=$(awk -F '\t' '{print $2}' "$STATE/.wake-queue")
bin/fm-wake-grant.sh publish finish-review $rows
bin/fm-branch-prompt.sh > "$ROOT/.phase/prompt"
printf 'check: finished predecessor dependency\n' | bin/fm-branch-dispatch.mjs wake-prompt --report bin/fm-branch-report.sh > "$ROOT/.phase/wake"
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
fm_supervision_engine_turn claude sonnet "$ROOT/.phase/prompt" "$ROOT/.phase/wake" "$session" new 150 "$E/finish-result.json" "$E/finish-errors.txt" || rc=$?
printf 'engine_exit=%s\n' "$rc"
bin/fm-tasks-axi.sh show other --full
bin/fm-tasks-axi.sh show held --full
cat "$STATE/branch-outcomes.jsonl" 2>/dev/null || true
printf 'wake_remaining='; wc -c < "$STATE/.wake-queue"
[ "$rc" = 0 ]
