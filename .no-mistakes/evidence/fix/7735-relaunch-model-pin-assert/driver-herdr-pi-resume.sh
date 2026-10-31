#!/usr/bin/env bash
# Live attempt 2: Herdr lab session + real Pi worker whose agent SESSION is
# reported to herdr (the machine's pi herdr integration copied into the isolated
# agent dir), then the documented stop-then-relaunch flow with a changed pin.
set -u
ROOT=/home/art/.no-mistakes/worktrees/9f75ec418609/01M68QGZB6QPX2YWXNQW6N3858
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || exit 1
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux"
printf 'auto\n' > "$LAB/config/claude-permission-mode"
SES=$("$ROOT/bin/fm-herdr-lab.sh" name pipin) || exit 1
echo "# lab=$LAB herdr-session=$SES"
SM=$(mktemp -d "${TMPDIR:-/tmp}/fm-sm.XXXXXX") || exit 1
mkdir -p "$SM/bin" "$SM/data" "$SM/state" "$SM/config" "$SM/projects"
printf '# Firstmate\n' > "$SM/AGENTS.md"
cp -RL "$ROOT/.pi" "$SM/.pi"
git -C "$SM" init -q -b main
git -C "$SM" -c user.email=lab@example.invalid -c user.name=lab commit -q --allow-empty -m init
export PI_CODING_AGENT_DIR="$LAB/pi-agent"
mkdir -p "$PI_CODING_AGENT_DIR/extensions"
cp -p "$HOME/.pi/agent/auth.json" "$PI_CODING_AGENT_DIR/auth.json"; chmod 600 "$PI_CODING_AGENT_DIR/auth.json"
cp -p "$HOME/.pi/agent/models.json" "$PI_CODING_AGENT_DIR/models.json" 2>/dev/null || true
# The herdr<->pi integration is what publishes the pane's agent session identity;
# carry the machine's installed copy into the isolated agent dir unchanged.
cp -p "$HOME/.pi/agent/extensions/"*.ts "$PI_CODING_AGENT_DIR/extensions/" 2>/dev/null || true
ID=live-pi-resume
mkdir -p "$LAB/data/$ID"
printf '# Task\n## Captain'"'"'s intent\nReply with exactly: OK\n' > "$LAB/data/$ID/brief.md"
printf '%s\n' "$ID" > "$SM/.fm-secondmate-home"

cleanup() {
  "$ROOT/bin/fm-herdr-lab.sh" teardown "$SES" 2>/dev/null || "$ROOT/bin/fm-herdr-lab.sh" stop "$SES" 2>/dev/null || true
  chmod -R u+rwX "$LAB" 2>/dev/null || true
  rm -rf "$LAB" "$SM"
}
trap cleanup EXIT
labrun() { "$ROOT/bin/fm-herdr-lab.sh" run "$SES" "$@"; }
spawn() {  # <label> <args...>
  local label=$1
  shift
  local start end rc
  start=$(date +%s%N)
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u HERDR_PANE_ID \
    FM_HOME="$LAB" HERDR_SESSION="$SES" PI_CODING_AGENT_DIR="$PI_CODING_AGENT_DIR" \
    FM_MODEL_PIN_POLLS=90 FM_MODEL_PIN_POLL_INTERVAL=0.5 \
    timeout 300 "$ROOT/bin/fm-spawn.sh" "$@" >"$LAB/$label.out" 2>"$LAB/$label.err"
  rc=$?
  end=$(date +%s%N)
  echo
  echo "### $label :: rc=$rc elapsed_ms=$(( (end - start) / 1000000 ))"
  echo "--- stdout"; cat "$LAB/$label.out"
  echo "--- stderr (model pin lines only)"; grep 'model pin' "$LAB/$label.err" || echo '(none)'
}

echo "== provision"; "$ROOT/bin/fm-herdr-lab.sh" provision "$SES" || { echo PROVISION-FAILED; exit 0; }

echo "== fresh Pi launch (pin openai-codex/gpt-5.6-luna)"
spawn fresh "$ID" "$SM" --secondmate --backend herdr --harness pi --model openai-codex/gpt-5.6-luna
PANE=$(sed -n 's/^herdr_pane_id=//p' "$LAB/state/$ID.meta")
echo "--- task pane: $PANE"

echo "== wait for herdr to publish the pane agent SESSION identity"
seen=none
for i in $(seq 1 45); do
  got=$(labrun agent get "$PANE" 2>&1)
  kind=$(printf '%s' "$got" | jq -r '.result.agent.agent_session.kind // empty' 2>/dev/null)
  if [ -n "$kind" ]; then seen=$got; echo "--- published after ~$((i * 2))s"; break; fi
  sleep 2
done
echo "$seen"
echo "--- agent get now"
labrun agent get "$PANE" 2>&1 | head -5
echo "--- pane read tail"
labrun pane read "$PANE" 2>&1 | tail -8

echo "== stop the worker through the product (documented pre-relaunch step)"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS FM_HOME="$LAB" HERDR_SESSION="$SES" \
  PI_CODING_AGENT_DIR="$PI_CODING_AGENT_DIR" timeout 120 "$ROOT/bin/fm-control.sh" "$ID" exit 2>&1 | tail -5
sleep 5
echo "--- agent get after exit"
labrun agent get "$PANE" 2>&1 | head -5

echo "== relaunch pinned to openai-codex/gpt-5.6-sol (resume readback)"
spawn relaunch "$ID" --relaunch --harness pi --model openai-codex/gpt-5.6-sol
echo "--- meta"; sed -n 's/^model=/model=/p' "$LAB/state/$ID.meta"
echo "--- status"; cat "$LAB/state/$ID.status" 2>/dev/null || echo '(absent)'
echo "--- pi session records under the isolated agent dir"
for f in $(find "$PI_CODING_AGENT_DIR" -name '*.jsonl' 2>/dev/null); do
  echo "$f"
  jq -r 'select(.type=="message" and .message.role=="assistant") | "    turn: \(.message.provider)/\(.message.model) stop=\(.message.stopReason)"' "$f" 2>/dev/null | tail -6
done
echo "--- pane read tail after relaunch"
labrun pane read "$PANE" 2>&1 | tail -10
