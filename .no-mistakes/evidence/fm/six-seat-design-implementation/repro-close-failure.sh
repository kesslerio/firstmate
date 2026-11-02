#!/usr/bin/env bash
# Reproduce tests/fm-teardown-endpoint-safety.test.sh:1318 standalone.
REPO=/home/art/.no-mistakes/worktrees/9f75ec418609/01M6EA9YQ1WQ6KN9Z59PAMBTGD
D=/tmp/fm-close-repro
rm -rf "$D"; mkdir -p "$D/home/state" "$D/home/data" "$D/home/config" "$D/fakebin" "$D/worktree" "$D/project"
git init -q "$D/project"
: > "$D/worktree/sentinel"; : > "$D/runtime.log"
cat > "$D/fakebin/tmux" <<SH
#!/usr/bin/env bash
printf 'tmux' >> "$D/runtime.log"
printf ' <%s>' "\$@" >> "$D/runtime.log"
printf '\n' >> "$D/runtime.log"
if [ -n "\${FM_TEST_BLOCK_KILL:-}" ] && [ "\${1:-}" = kill-window ]; then
  echo "can't find window" >&2
  exit 1
fi
cd '$D'
exec /run/current-system/sw/bin/tmux -S '$D/dedicated.sock' "\$@"
SH
chmod +x "$D/fakebin/tmux"
cd "$D"
env -u TMUX -u TMUX_PANE /run/current-system/sw/bin/tmux -S dedicated.sock new-session -d -s 'close failure' -n control
env -u TMUX -u TMUX_PANE /run/current-system/sw/bin/tmux -S dedicated.sock new-window -d -t '=close failure:' -n fm-strand-task
printf 'window=%s\nendpoint_task_id=strand-task\nworktree=%s\nproject=%s\nkind=ship\nmode=no-mistakes\n' \
  'close failure:fm-strand-task' "$D/nonexistent-worktree" "$D/nonexistent-project" > "$D/home/state/strand-task.meta"
echo "=== windows before"; env -u TMUX -u TMUX_PANE /run/current-system/sw/bin/tmux -S dedicated.sock list-windows -t '=close failure' -F '#{window_name}'
env -u TMUX -u TMUX_PANE FM_TEST_BLOCK_KILL=1 FM_GATE_REFUSE_BYPASS=1 \
  FM_HOME="$D/home" FM_ROOT_OVERRIDE="$REPO" FM_RUNTIME_LOG="$D/runtime.log" \
  PATH="$D/fakebin:$PATH" "$REPO/bin/fm-teardown.sh" strand-task > "$D/out" 2> "$D/err"
echo "rc=$?"
echo "=== out"; cat "$D/out"
echo "=== err"; cat "$D/err"
echo "=== runtime.log"; cat "$D/runtime.log"
echo "=== meta present?"; ls "$D/home/state"
echo "=== windows after"; env -u TMUX -u TMUX_PANE /run/current-system/sw/bin/tmux -S dedicated.sock list-windows -t '=close failure' -F '#{window_name}'
env -u TMUX -u TMUX_PANE /run/current-system/sw/bin/tmux -S dedicated.sock kill-server 2>/dev/null
