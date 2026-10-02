#!/usr/bin/env bash
set -eu
. "$PWD/.test-validation/product/tests/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot raw-runtime)
SOCKET="/proc/$VALIDATION_DRIVER_PID/cwd/.test-validation/raw.sock"
REAL_TMUX=/run/current-system/sw/bin/tmux
cleanup() { "$REAL_TMUX" -S "$SOCKET" kill-server >/dev/null 2>&1 || true; fm_test_cleanup; }
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
printf '{}\n' > "$TMP_ROOT/treehouse-state.json"
case_dir="$TMP_ROOT/case"
proj="$case_dir/project"
wt="$case_dir/wt"
fm_git_init_commit "$proj"
mkdir -p "$proj/.pi/extensions" "$case_dir/custom store" "$case_dir/pi-store"
printf 'export default function () {}\n' > "$proj/.pi/extensions/test.ts"
git -C "$proj" add .pi
git -C "$proj" -c user.name=Fixture -c user.email=fixture@example.invalid commit --quiet -m "trust-gated fixture"
fm_git_add_origin "$proj" "$proj.origin.git"
git -C "$proj" worktree add --quiet -b fresh "$wt"
ln -s "$VALIDATION_CODEX_AUTH" "$case_dir/custom store/auth.json"
ln -s "$VALIDATION_PI_AUTH/auth.json" "$case_dir/pi-store/auth.json"
printf 'check_for_update_on_startup = false\n' > "$case_dir/custom store/config.toml"
for harness in codex pi; do
 home="$case_dir/home-$harness"
 fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake-$harness")
 fm_test_spawn_home "$home" "$harness"
 fm_test_spawn_brief "$home" "raw-$harness"
 if [ "$harness" = codex ]; then
  raw="CODEX_HOME='$case_dir/custom store' codex --disable hooks"
 else
  raw="pi --tui-mode regular --no-session"
 fi
 FM_FAKE_LAUNCH_LOG="$case_dir/$harness.launch" fm_test_run_spawn "$home" "$wt" "$fakebin" "raw-$harness" "$proj" "$raw" --mode no-mistakes --yolo off
 launch=$(cat "$case_dir/$harness.launch")
 printf '%s\n' "$launch" > "$VALIDATION_EVIDENCE/raw-$harness-launch.txt"
 printf -v runtime_command 'env HOME=%q PI_CODING_AGENT_DIR=%q bash -c %q' "$case_dir/runtime-home" "$case_dir/pi-store" "$launch"
 "$REAL_TMUX" -S "$SOCKET" new-session -d -s "raw-$harness" -x 160 -y 45 -c "$wt" "$runtime_command"
 matched=0
 for ((i=0;i<35;i++)); do
  text=$("$REAL_TMUX" -S "$SOCKET" capture-pane -pt "raw-$harness" -S -60 2>/dev/null || true)
  case "$text" in *'Update available'*) "$REAL_TMUX" -S "$SOCKET" send-keys -t "raw-$harness" Escape ;; esac
  if [ "$harness" = codex ]; then
   case "$text" in *'Ask Codex to do anything'*|*'? for shortcuts'*) matched=1; break ;; esac
  else
   case "$text" in *'escape interrupt'*|*'ctrl+o'*) matched=1; break ;; esac
  fi
  sleep 1
 done
 printf '%s\n' "$text" > "$VALIDATION_EVIDENCE/raw-$harness-pane.txt"
 [ "$matched" = 1 ] || fail "raw $harness never reached editor"
 case "$text" in *'Trust project folder?'*|*'Trust this folder?'*) fail "raw $harness still prompts" ;; esac
 pass "raw $harness launch reached the actual editor without folder-trust prompt"
 "$REAL_TMUX" -S "$SOCKET" kill-session -t "raw-$harness"
done
cat "$case_dir/custom store/config.toml" > "$VALIDATION_EVIDENCE/raw-codex-store.toml"
[ ! -e "$case_dir/pi-store/trust.json" ] || fail 'raw Pi wrote trust store'
pass 'raw Pi approval persisted no trust store'
