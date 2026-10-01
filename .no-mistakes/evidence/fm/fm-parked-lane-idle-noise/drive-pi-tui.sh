#!/usr/bin/env bash
# Live Pi TUI drive: launch the REAL installed Pi against the tracked
# supervision-branch extension, restore a session that contains one
# fm_branch_outcomes tool call, and observe the rendered transcript rows in the
# real terminal across a /calm toggle.
#
# Calm starts ON (the choice a captain's home persists), so the tool row is
# first painted hidden and stores no stock row at all - the exact state whose
# result render was guarded this round. Turning Calm off then forces that
# stored-row-less result render through Pi's real transcript paint.
set -u
ROOT=/Users/kesslerio/.no-mistakes/worktrees/8036f35f7c08/01M3VPK3RDXETQSJYZNQ716E37
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-pi-tui.XXXXXX")
project=$LAB/project; home=$LAB/home; config=$LAB/agent-dir; sessions=$LAB/sessions
mkdir -p "$project/.pi/extensions/lib" "$home/state" "$home/config" "$config" "$sessions"
cp "$ROOT/.pi/extensions/fm-branch-supervision.ts" "$project/.pi/extensions/"
cp "$ROOT/.pi/extensions/fm-calm.ts" "$project/.pi/extensions/"
cp "$ROOT"/.pi/extensions/lib/* "$project/.pi/extensions/lib/"
for n in 1 2 3 4 5 6 7 8 9 10 11 12; do
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ROOT_OVERRIDE="$ROOT" \
    bash "$ROOT/bin/fm-branch-outcome.sh" append --task "lab-task-$n" --verdict routine \
    --summary "OUTCOME_$n checks green, ready for review" --silent false >/dev/null \
    || { echo "PI TUI DRIVE: could not seed outcome $n"; exit 2; }
done
printf 'on\n' > "$home/config/calm"
now=$(date -u +%Y-%m-%dT%H:%M:%S.000Z)
session_file=$LAB/session.jsonl
cat > "$session_file" <<JSON
{"type":"session","version":3,"id":"aaaaaaaa-1111-4111-8111-111111111111","timestamp":"$now","cwd":"$project"}
{"type":"message","id":"s1","parentId":null,"timestamp":"$now","message":{"role":"user","content":[{"type":"text","text":"What did the supervision branch handle?"}],"timestamp":1}}
{"type":"message","id":"s2","parentId":"s1","timestamp":"$now","message":{"role":"assistant","content":[{"type":"text","text":"Reading the outcome store."},{"type":"toolCall","id":"call_branch_1","name":"fm_branch_outcomes","arguments":{"recent":3}}],"api":"anthropic-messages","provider":"anthropic","model":"claude-sonnet-4-5","usage":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":2,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"toolUse","timestamp":2}}
{"type":"message","id":"s3","parentId":"s2","timestamp":"$now","message":{"role":"toolResult","toolCallId":"call_branch_1","toolName":"fm_branch_outcomes","content":[{"type":"text","text":"OUTCOME_11 checks green, ready for review\nOUTCOME_12 checks green, ready for review\nOUTCOME_13 checks green, ready for review"}],"details":{"ok":true},"isError":false,"timestamp":3}}
{"type":"message","id":"s4","parentId":"s3","timestamp":"$now","message":{"role":"assistant","content":[{"type":"text","text":"Three routine outcomes, none captain-facing."}],"api":"anthropic-messages","provider":"anthropic","model":"claude-sonnet-4-5","usage":{"input":1,"output":1,"cacheRead":0,"cacheWrite":0,"totalTokens":2,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"stop","timestamp":4}}
JSON

SOCKET="fm-pi-tui-$$"
cleanup() { tmux -L "$SOCKET" kill-server 2>/dev/null || true; }
trap cleanup EXIT
tmux -L "$SOCKET" new-session -d -s pitui -x 140 -y 44 \
  "cd '$project' && env FM_HOME='$home' PI_CODING_AGENT_DIR='$config' PI_OFFLINE=1 pi --approve --no-skills --no-prompt-templates --no-context-files --session '$session_file'; rc=\$?; printf '\nPI_EXIT=%s\n' \"\$rc\"; sleep 15"
snap=$LAB/calm-on.txt
i=0
while [ "$i" -lt 300 ]; do
  tmux -L "$SOCKET" capture-pane -p -t pitui -S -600 > "$snap" 2>/dev/null || true
  grep -Fq 'Three routine outcomes' "$snap" && break
  sleep 0.1; i=$((i + 1))
done
echo "=== Pi $(pi --version 2>/dev/null) restored session with Calm ON at start"
cat "$snap"
printf 'hidden tool-result rows on screen (expect 0): '
grep -c 'OUTCOME_11' "$snap"
printf 'hidden tool-call shells on screen (expect 0): '
grep -c 'fm_branch_outcomes recent' "$snap"

# Turn Calm off: the row repaints, and this is the render that used to
# dereference a stock row that was never stored.
tmux -L "$SOCKET" send-keys -t pitui -l "/calm"
tmux -L "$SOCKET" send-keys -t pitui Enter
i=0
while [ "$i" -lt 300 ]; do
  tmux -L "$SOCKET" capture-pane -p -t pitui -S -600 > "$LAB/calm-off.txt" 2>/dev/null || true
  grep -Fq 'fm_branch_outcomes' "$LAB/calm-off.txt" && break
  sleep 0.1; i=$((i + 1))
done
echo; echo "=== persisted Calm choice after the toggle: $(cat "$home/config/calm") (expect off)"
echo "=== After /calm off: the no-stored-row result render repainted inside Pi"
printf 'tool-call rows on screen (expect 1): '; grep -c 'fm_branch_outcomes' "$LAB/calm-off.txt"
printf 'tool-result rows on screen (expect 1): '; grep -c 'OUTCOME_11' "$LAB/calm-off.txt"
printf 'genuine assistant rows still on screen: '; grep -c 'Three routine outcomes' "$LAB/calm-off.txt"
if grep -Fq 'PI_EXIT=' "$LAB/calm-off.txt"; then
  echo "Pi EXITED during the repaint - the render threw:"; cat "$LAB/calm-off.txt"; exit 1
fi
echo "Pi still running with a live transcript: yes"
echo; echo "=== calm-off screen:"; cat "$LAB/calm-off.txt"
tmux -L "$SOCKET" send-keys -t pitui -l '/quit'; tmux -L "$SOCKET" send-keys -t pitui Enter
sleep 1
echo; echo "LAB=$LAB"
