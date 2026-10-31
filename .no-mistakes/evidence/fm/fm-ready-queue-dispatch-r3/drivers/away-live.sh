#!/usr/bin/env bash
# Live away-posture driver for the ready-queue change under validation.
# Same mechanics as tests/development/ready-queue-away.sh, driven from the
# gate worktree, but it deliberately inherits the machine's normal Claude
# login (the authorized path for this run) instead of an empty isolated
# CLAUDE_CONFIG_DIR, and it queues TWO out-of-scope ready units so "every other
# ready unit" is exercised.
set -eu

FM_ROOT_WT=/home/art/.no-mistakes/worktrees/9f75ec418609/01M68DFDPBY58KJMCHPEQ7GB3W
. "$FM_ROOT_WT/tests/lib.sh"
fm_live_gate opt-in FM_READY_QUEUE_AWAY_LIVE claude node python3 tasks-axi jq

ROOT="$FM_ROOT_WT"
LAB=$(fm_test_tmproot ready-queue-away-live)
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_HOME="$LAB/home"
"$ROOT/bin/fm-lab-home.sh" create "$FM_HOME" >/dev/null
fm_test_tasks_toml "$FM_HOME/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$FM_HOME/data/backlog.md"
"$ROOT/bin/fm-tasks-axi.sh" add other 'out of scope ready unit' >/dev/null
"$ROOT/bin/fm-tasks-axi.sh" add other2 'second out of scope ready unit' >/dev/null
"$ROOT/bin/fm-afk-contract.sh" enter --spend 4 \
  --words 'No dispatch is authorized. Do not merge, push, open a PR, or change global configuration.' >/dev/null

STATE="$FM_HOME/state"
export FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=away-review FM_LEASE_HOLDER_PID=$$
printf '%s\n' "$$" > "$STATE/.lock"
printf 'turn=away-review\nunscoped=1\nrows=\ntasks=\nwake=heartbeat\nposture=away\n' > "$STATE/.supervision-host-turn"
# shellcheck source=/dev/null # Worktree library.
. "$ROOT/bin/fm-wake-lib.sh"
fm_wake_append heartbeat heartbeat heartbeat
"$ROOT/bin/fm-wake-grant.sh" activate "$$" away-review
rows=$(awk -F '\t' '{print $2}' "$STATE/.wake-queue")
"$ROOT/bin/fm-wake-grant.sh" publish away-review $rows
"$ROOT/bin/fm-afk-contract.sh" readback > "$LAB/readback"
"$ROOT/bin/fm-branch-prompt.sh" > "$LAB/prompt"
printf 'heartbeat\n' | "$ROOT/bin/fm-branch-dispatch.mjs" wake-prompt \
  --report bin/fm-branch-report.sh --away --readback-file "$LAB/readback" > "$LAB/wake"

# Machine's normal Claude login; no credential store is read or written by us.
unset CLAUDE_CONFIG_DIR
export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
cat > "$LAB/engine" <<'ENGINE'
#!/usr/bin/env bash
exec claude --no-session-persistence "$@"
ENGINE
chmod +x "$LAB/engine"
export FM_SUPERVISION_ENGINE_CLAUDE_BIN="$LAB/engine"
# shellcheck source=/dev/null # Worktree library.
. "$ROOT/bin/fm-supervision-engine-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-timeout-lib.sh"
session=$(python3 -c 'import uuid; print(uuid.uuid4())')
if ! fm_supervision_engine_turn claude sonnet "$LAB/prompt" "$LAB/wake" \
  "$session" new 300 "$LAB/result.json" "$LAB/errors"; then
  cat "$LAB/errors" >&2
  jq -r .result "$LAB/result.json" >&2
  fail 'away live engine failed'
fi

outcome=0
for unit in other other2; do
  out=$("$ROOT/bin/fm-tasks-axi.sh" show "$unit" --full)
  assert_contains "$out" 'state: queued' "$unit must stay queued"
  assert_not_contains "$out" 'body: ""' "$unit lost its durable stop reason"
  note=$(printf '%s\n' "$out" | sed -n 's/^ *body: //p')
  [ -n "$note" ] && [ "$note" != '""' ] || fail "$unit has no durable stop note"
  printf '%s note: %s\n' "$unit" "$note"
  [ ! -e "$STATE/$unit.meta" ] || fail "$unit acquired a worker"
done
jq -e -s 'length > 0 and any(.[]; .verdict == "captain" and .silent == false)' \
  "$STATE/branch-outcomes.jsonl" >/dev/null || fail 'ready work was silently acknowledged'
[ ! -s "$STATE/.wake-queue" ] || fail 'away review did not acknowledge the handled wake'
printf 'captain outcomes: %s\n' "$(jq -c 'select(.verdict=="captain")' "$STATE/branch-outcomes.jsonl")"
pass 'away live: both out-of-scope ready units stay queued with a durable stop and retry condition'
