#!/usr/bin/env bash
# Live follow-up: F) raw pinned Claude launch, E) worker writes its own status
# while the launcher is asserting the pin.
set -u
ROOT=/home/art/.no-mistakes/worktrees/9f75ec418609/01M68QGZB6QPX2YWXNQW6N3858
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || exit 1
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/tmux" "$LAB/user-home" "$LAB/claude-config"
cp -p "$HOME/.claude/.credentials.json" "$LAB/claude-config/.credentials.json"
chmod 600 "$LAB/claude-config/.credentials.json"
printf '%s\n' '{"hasCompletedOnboarding": true, "theme": "dark"}' > "$LAB/claude-config/.claude.json"
# Let the worker run the one harmless printf the brief asks for without a
# permission prompt, so a real status write really lands during the probe.
printf '%s\n' '{"permissions":{"allow":["Bash(printf:*)"],"deny":[],"ask":[]}}' > "$LAB/claude-config/settings.json"
printf 'auto\n' > "$LAB/config/claude-permission-mode"
SM=$(mktemp -d "${TMPDIR:-/tmp}/fm-sm.XXXXXX") || exit 1
mkdir -p "$SM/bin" "$SM/data" "$SM/state" "$SM/config" "$SM/projects"
printf '# Firstmate\n' > "$SM/AGENTS.md"
git -C "$SM" init -q -b main
git -C "$SM" -c user.email=lab@example.invalid -c user.name=lab commit -q --allow-empty -m init
echo "# lab=$LAB secondmate-home=$SM"
cleanup() {
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null || true
  chmod -R u+rwX "$LAB" 2>/dev/null || true
  rm -rf "$LAB" "$SM"
}
trap cleanup EXIT
tmuxlab() { TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab "$@"; }
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE \
  -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -c "$ROOT" -e FM_HOME="$LAB" bash

# shell_quote one argument so the pane command keeps the raw launch command whole
quoted() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

run_spawn() {  # <id> <polls> <interval> <harness-arg> [spawn args...]
  local id=$1 polls=$2 interval=$3 harness=$4
  shift 4
  printf '%s\n' "$id" > "$SM/.fm-secondmate-home"
  local args
  args=$(printf '%s ' "$@")
  local start end
  start=$(date +%s%N)
  tmuxlab send-keys -t primary \
    "env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE FM_HOME='$LAB' HOME='$LAB/user-home' CLAUDE_CONFIG_DIR='$LAB/claude-config' FM_MODEL_PIN_POLLS=$polls FM_MODEL_PIN_POLL_INTERVAL=$interval '$ROOT/bin/fm-spawn.sh' '$id' '$SM' --secondmate --backend tmux --harness $(quoted "$harness") $args >'$LAB/$id.out' 2>'$LAB/$id.err'; echo done >'$LAB/$id.rc'" Enter
  for _ in $(seq 1 400); do [ -f "$LAB/$id.rc" ] && break; sleep 0.5; done
  end=$(date +%s%N)
  echo
  echo "### $id :: harness=[$harness] args=[$args]"
  echo "--- spawn returned after $(( (end - start) / 1000000 )) ms"
  echo "--- stdout"; cat "$LAB/$id.out" 2>/dev/null
  echo "--- stderr (last 6 lines)"; tail -6 "$LAB/$id.err" 2>/dev/null
  echo "--- state/$id.status (model-pin lines: $(grep -c 'model pin' "$LAB/state/$id.status" 2>/dev/null || echo 0))"
  cat "$LAB/state/$id.status" 2>/dev/null || echo "(no status file)"
  echo "--- state/$id.meta model/harness"; grep -E '^(harness|model)=' "$LAB/state/$id.meta" 2>/dev/null
}

mkdir -p "$LAB/data/live-pin-raw-2" "$LAB/data/live-worker-status-2"
printf '# Task\n## Captain'"'"'s intent\nraw probe\n' > "$LAB/data/live-pin-raw-2/brief.md"
cat > "$LAB/data/live-worker-status-2/brief.md" <<EOF
# Task
## Captain's intent
First run exactly this command: printf 'working: live worker owns this line\n' >> '$LAB/state/live-worker-status-2.status'
Then reply with exactly: OK
EOF

echo
echo "=============================================================="
echo "F: raw pinned Claude launch -> immediate unverified, no session address"
run_spawn live-pin-raw-2 400 0.5 'claude --version && sleep 300' --model claude-haiku-4-5
echo "--- live process for that raw launch (a --session-id must NOT appear)"
pgrep -af 'claude --version && sleep 300' | sed -n '1,3p'
echo "--- how many --session-id occurrences on the raw launch: $(pgrep -af 'claude --version && sleep 300' | grep -c -- '--session-id' || true)"

echo
echo "=============================================================="
echo "E: worker writes its own status while the launcher asserts the pin"
run_spawn live-worker-status-2 120 0.5 claude --model claude-haiku-4-5
echo "--- status file immediately after the launcher returned"
cat "$LAB/state/live-worker-status-2.status" 2>/dev/null || echo "(no status file)"
sleep 8
echo "--- status file after the worker finished its turn"
cat "$LAB/state/live-worker-status-2.status" 2>/dev/null || echo "(no status file)"
echo "--- task pane"
tmuxlab capture-pane -p -t "primary:fm-live-worker-status-2" 2>/dev/null | tail -12
echo "--- any status file carrying a model-pin line?"
grep -rl 'model pin' "$LAB"/state/*.status 2>/dev/null || echo "(none)"
