#!/usr/bin/env bash
# Live evidence: real bin/fm-spawn.sh, real tmux backend, real claude 2.1.316,
# real pi 1.4.0, disposable marked lab home.
#
# Scenarios driven here:
#   A pinned Claude launch           -> `model pin asserted:` on stderr
#   B pinned launch the vendor remaps -> `model pin mismatch:` on stderr, launch ok
#   C unpinned launch                 -> no model-pin verdict at all
#   D pinned launch on a retired model -> `model pin unverified:` (no model ran)
#   E worker writes its own status during a pinned launch -> worker line stays,
#     no model-pin line ever enters the status file
#   F raw pinned Claude launch        -> immediate unverified, no --session-id
set -u
ROOT=/home/art/.no-mistakes/worktrees/9f75ec418609/01M68QGZB6QPX2YWXNQW6N3858
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || exit 1
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux" "$LAB/user-home" "$LAB/claude-config"
# An isolated Claude store: a copy of the machine's existing login (read-only
# source) so the operator's own config and transcripts are never touched.
cp -p "$HOME/.claude/.credentials.json" "$LAB/claude-config/.credentials.json"
chmod 600 "$LAB/claude-config/.credentials.json"
printf '%s\n' '{"hasCompletedOnboarding": true, "theme": "dark"}' > "$LAB/claude-config/.claude.json"
# Model-reviewed permissions instead of bypass, so a fresh folder needs no
# one-time bypass consent dialog in this disposable store.
printf 'auto\n' > "$LAB/config/claude-permission-mode"
SM=$(mktemp -d "${TMPDIR:-/tmp}/fm-sm.XXXXXX") || exit 1
mkdir -p "$SM/bin" "$SM/data" "$SM/state" "$SM/config" "$SM/projects"
printf '# Firstmate\n' > "$SM/AGENTS.md"
git -C "$SM" init -q -b main
git -C "$SM" -c user.email=lab@example.invalid -c user.name=lab commit -q --allow-empty -m init
echo "# lab=$LAB secondmate-home=$SM"

cleanup() {
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null || true
  chmod -R u+w "$LAB" 2>/dev/null || true
  rm -rf "$LAB" "$SM"
}
trap cleanup EXIT

tmuxlab() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab "$@"; }
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -c "$ROOT" -e FM_HOME="$LAB" bash

launch() {  # <id> <brief-body> <polls> <interval> [spawn args...]
  local id=$1 brief=$2 polls=$3 interval=$4
  shift 4
  mkdir -p "$LAB/data/$id"
  printf '%s\n' "$brief" > "$LAB/data/$id/brief.md"
  printf '%s\n' "$id" > "$SM/.fm-secondmate-home"
  local start end
  start=$(date +%s%N)
  tmuxlab send-keys -t primary \
    "env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME='$LAB' HOME='$LAB/user-home' CLAUDE_CONFIG_DIR='$LAB/claude-config' FM_MODEL_PIN_POLLS=$polls FM_MODEL_PIN_POLL_INTERVAL=$interval '$ROOT/bin/fm-spawn.sh' '$id' '$SM' --secondmate --backend tmux $* >'$LAB/$id.out' 2>'$LAB/$id.err'; echo rc=\$? >'$LAB/$id.rc'" Enter
  for _ in $(seq 1 400); do [ -f "$LAB/$id.rc" ] && break; sleep 0.5; done
  end=$(date +%s%N)
  echo
  echo "### $id :: args=[$*] rc=$(sed 's/^rc=//' "$LAB/$id.rc" 2>/dev/null || echo MISSING) elapsed_ms=$(( (end - start) / 1000000 ))"
  echo "--- stdout"; cat "$LAB/$id.out" 2>/dev/null
  echo "--- stderr"; cat "$LAB/$id.err" 2>/dev/null
  echo "--- state/$id.status (model-pin lines: $(grep -c 'model pin' "$LAB/state/$id.status" 2>/dev/null || echo 0))"
  cat "$LAB/state/$id.status" 2>/dev/null || echo "(no status file)"
  echo "--- state/$id.meta model/harness/kind"; grep -E '^(harness|model|kind|approval_mode)=' "$LAB/state/$id.meta" 2>/dev/null
}

echo
echo "=============================================================="
echo "A: pinned Claude launch (pin claude-haiku-4-5) -> asserted"
launch live-pin-assert 'Reply with exactly: OK' 120 0.5 --harness claude --model claude-haiku-4-5
echo "--- live claude process (launch carries --session-id?)"
pgrep -af "claude --session-id" | sed -n '1,3p'
echo "--- transcripts under the isolated CLAUDE_CONFIG_DIR"
for f in "$LAB"/claude-config/projects/*/*.jsonl; do
  [ -f "$f" ] || continue
  echo "$f"
  jq -r 'select(.type=="assistant") | .message.model' "$f" 2>/dev/null | sort -u | sed 's/^/    assistant model: /'
done
echo "--- task pane (worker answered its brief)"
tmuxlab capture-pane -p -t "primary:fm-live-pin-assert" 2>/dev/null | tail -8

echo
echo "=============================================================="
echo "B: vendor remap (pin claude-opus-4-1, Claude Code remaps to Opus 5.5) -> mismatch"
launch live-pin-mismatch 'Reply with exactly: OK' 120 0.5 --harness claude --model claude-opus-4-1
echo "--- live claude process for the mismatched launch"
pgrep -af "claude --session-id" | sed -n '1,5p'
echo "--- transcripts under the isolated CLAUDE_CONFIG_DIR"
for f in "$LAB"/claude-config/projects/*/*.jsonl; do
  [ -f "$f" ] || continue
  echo "$f"
  jq -r 'select(.type=="assistant") | .message.model' "$f" 2>/dev/null | sort -u | sed 's/^/    assistant model: /'
done
echo "--- task pane still live after the mismatch was reported"
tmuxlab capture-pane -p -t "primary:fm-live-pin-mismatch" 2>/dev/null | tail -8

echo
echo "=============================================================="
echo "C: unpinned Claude launch -> no model-pin verdict"
launch live-unpinned 'Reply with exactly: OK' 120 0.5 --harness claude

echo
echo "=============================================================="
echo "D: retired model (pin claude-3-opus-latest, no model runs) -> unverified"
launch live-retired 'Reply with exactly: OK' 8 0.5 --harness claude --model claude-3-opus-latest

echo
echo "=============================================================="
echo "E: worker writes its own status during a pinned launch"
mkdir -p "$LAB/data/live-worker-status"
cat > "$LAB/data/live-worker-status/brief.md" <<EOF
# Task
## Captain's intent
First run this exact shell command, replacing nothing:
printf 'working: live worker owns this line\n' >> '$LAB/state/live-worker-status.status'
Then reply with exactly: OK
EOF
printf '%s\n' live-worker-status > "$SM/.fm-secondmate-home"
start=$(date +%s%N)
tmuxlab send-keys -t primary \
  "env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME='$LAB' HOME='$LAB/user-home' CLAUDE_CONFIG_DIR='$LAB/claude-config' FM_MODEL_PIN_POLLS=120 FM_MODEL_PIN_POLL_INTERVAL=0.5 '$ROOT/bin/fm-spawn.sh' live-worker-status '$SM' --secondmate --backend tmux --harness claude --model claude-haiku-4-5 >'$LAB/live-worker-status.out' 2>'$LAB/live-worker-status.err'; echo rc=\$? >'$LAB/live-worker-status.rc'" Enter
for _ in $(seq 1 400); do [ -f "$LAB/live-worker-status.rc" ] && break; sleep 0.5; done
end=$(date +%s%N)
echo "rc=$(sed 's/^rc=//' "$LAB/live-worker-status.rc" 2>/dev/null) elapsed_ms=$(( (end - start) / 1000000 ))"
echo "--- stderr"; cat "$LAB/live-worker-status.err" 2>/dev/null
echo "--- state/live-worker-status.status (model-pin lines: $(grep -c 'model pin' "$LAB/state/live-worker-status.status" 2>/dev/null || echo 0))"
cat "$LAB/state/live-worker-status.status" 2>/dev/null || echo "(no status file)"
sleep 3
echo "--- status file again after the worker finished its turn"
cat "$LAB/state/live-worker-status.status" 2>/dev/null || echo "(no status file)"
echo "--- task pane"
tmuxlab capture-pane -p -t "primary:fm-live-worker-status" 2>/dev/null | tail -10

echo
echo "=============================================================="
echo "F: raw pinned Claude launch -> immediate unverified, no session address"
launch live-pin-raw 'unused' 400 0.5 --harness 'claude --version && sleep 300' --model claude-haiku-4-5
echo "--- live process for the raw launch (no --session-id must appear)"
pgrep -af 'claude --version && sleep 300' | sed -n '1,3p'
echo "--- pid-search for a session id on that raw launch: $(pgrep -af 'claude --version && sleep 300' | grep -c -- '--session-id' || true)"

echo
echo "=============================================================="
echo "G: full lab state (status files / no model-pin residue outside stderr)"
ls -1 "$LAB/state" | sed -n '1,40p'
echo "--- any status file carrying a model-pin line?"
grep -rl 'model pin' "$LAB"/state/*.status 2>/dev/null || echo "(none)"
echo "--- pane/window inventory"
tmuxlab list-windows -F '#{window_name}'
