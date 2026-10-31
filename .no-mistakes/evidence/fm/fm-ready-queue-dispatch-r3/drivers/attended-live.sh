#!/usr/bin/env bash
# Live attended-posture driver for the ready-queue change under validation.
# Drives the real branch prompt + real wake prompt through the real Claude
# engine (machine login, authorized for this run) on a disposable lab home that
# holds one dependency-cleared ready unit and one captain-held sibling. Checks
# the durable attended handoff: a captain outcome naming the ready unit, the
# held sibling untouched, no worker, no silent acknowledgement, and the real
# BRANCH OUTCOMES drain presenting the handoff to MAIN.
set -eu

FM_ROOT_WT=/home/art/.no-mistakes/worktrees/9f75ec418609/01M68DFDPBY58KJMCHPEQ7GB3W
. "$FM_ROOT_WT/tests/lib.sh"
fm_live_gate opt-in FM_READY_QUEUE_ATTENDED_LIVE claude node python3 tasks-axi jq

ROOT="$FM_ROOT_WT"
LAB=$(fm_test_tmproot ready-queue-attended-live)
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_HOME="$LAB/home"
"$ROOT/bin/fm-lab-home.sh" create "$FM_HOME" >/dev/null
fm_test_tasks_toml "$FM_HOME/.tasks.toml"
mkdir -p "$FM_HOME/config"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$FM_HOME/data/backlog.md"
: > "$FM_HOME/config/supervision-host"
"$ROOT/bin/fm-tasks-axi.sh" add next 'next unit whose dependency has landed' >/dev/null
"$ROOT/bin/fm-tasks-axi.sh" add gate 'landed dependency' >/dev/null
"$ROOT/bin/fm-tasks-axi.sh" add held 'captain-held sibling' >/dev/null
"$ROOT/bin/fm-tasks-axi.sh" block next --by gate >/dev/null
"$ROOT/bin/fm-tasks-axi.sh" 'done' gate --pr https://github.com/example/fixture/pull/1 >/dev/null
"$ROOT/bin/fm-captain-hold.sh" hold held --reason 'explicit captain hold' >/dev/null

STATE="$FM_HOME/state"
export FM_SUPERVISION_ACTOR=branch FM_BRANCH_REPORT_TURN=attended-review FM_LEASE_HOLDER_PID=$$
printf '%s\n' "$$" > "$STATE/.lock"
printf 'turn=attended-review\nunscoped=1\nrows=\ntasks=\nwake=heartbeat\nposture=attended\n' > "$STATE/.supervision-host-turn"
# shellcheck source=/dev/null # Worktree library.
. "$ROOT/bin/fm-wake-lib.sh"
fm_wake_append heartbeat heartbeat heartbeat
"$ROOT/bin/fm-wake-grant.sh" activate "$$" attended-review
rows=$(awk -F '\t' '{print $2}' "$STATE/.wake-queue")
"$ROOT/bin/fm-wake-grant.sh" publish attended-review $rows
"$ROOT/bin/fm-branch-prompt.sh" > "$LAB/prompt"
printf 'heartbeat\n' | "$ROOT/bin/fm-branch-dispatch.mjs" wake-prompt \
  --report bin/fm-branch-report.sh > "$LAB/wake"

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
  fail 'attended live engine failed'
fi

jq -c 'select(.verdict=="captain")' "$STATE/branch-outcomes.jsonl" > "$LAB/captain-outcomes" || true
cat "$LAB/captain-outcomes"
[ -s "$LAB/captain-outcomes" ] || fail 'attended ready work produced no captain outcome'
grep -q 'next' "$LAB/captain-outcomes" || fail 'the captain handoff did not name the ready unit'
jq -e -s 'any(.[]; .verdict == "captain" and .silent == false and (.summary | test("next")))' \
  "$STATE/branch-outcomes.jsonl" >/dev/null || fail 'the ready-work handoff was not a non-silent captain outcome'
[ ! -e "$STATE/next.meta" ] || fail 'attended supervision spawned a worker instead of handing off'
out=$("$ROOT/bin/fm-tasks-axi.sh" show next --full)
assert_contains "$out" 'state: queued' 'the ready unit left the queue before MAIN acted'
out=$("$ROOT/bin/fm-tasks-axi.sh" show held --full)
assert_contains "$out" 'held: yes' 'the captain-held sibling lost its hold'
assert_contains "$out" 'hold_reason: "explicit captain hold"' 'the captain-held sibling lost its hold reason'
[ ! -s "$STATE/.wake-queue" ] || fail 'the attended review did not acknowledge the handled wake'

# MAIN's real drain must present the handoff durably.
# The drain identifies MAIN's primary harness; this drive is not itself inside
# a Claude session, so the documented test seam pins that detection to claude.
FM_SUPERVISION_ACTOR=main FM_TEST_SEAM=1 FM_TEST_HARNESS=claude \
  FM_HOME="$FM_HOME" FM_CONFIG_OVERRIDE="$FM_HOME/config" \
  "$ROOT/bin/fm-wake-drain.sh" > "$LAB/drain.out" 2>"$LAB/drain.err" || fail 'main drain failed'
grep -q 'BRANCH OUTCOMES' "$LAB/drain.out" || fail 'main drain did not present BRANCH OUTCOMES'
grep -q 'next' "$LAB/drain.out" || fail 'main drain lost the ready-work handoff'
grep -q 'mark-processed --through' "$LAB/drain.out" || fail 'main drain printed no acknowledgement target'
sed -n '/BRANCH OUTCOMES/,/^$/p' "$LAB/drain.out" | head -20
pass 'attended live: ready unit handed to MAIN as a durable captain outcome while the held sibling waited'
