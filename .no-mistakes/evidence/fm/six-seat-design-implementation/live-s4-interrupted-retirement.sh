#!/usr/bin/env bash
# Live scenario S4: a remote retirement that is interrupted after it published
# its durable intent stays retryable, and the retry neither strands a staged
# copy nor leaves pending evidence behind.
#
# The interruption is real: the host controller is killed while its retirement
# is in flight (after the pending record exists), and the retry is the primary's
# own bin/fm-teardown.sh path over the real on -> entrypoint -> worker ->
# host-control chain, against a real Herdr lab session.
set -u
ROOT=${ROOT:?run from the worktree}
LAB=${LAB:?disposable lab dir}
BIN=$ROOT/bin
PRIMARY=$LAB/primary
SHOP=$LAB/shop
REMOTE_ROOT=$LAB/remote-root
ID=labtwo
GEN=lab.gen.2
mkdir -p "$LAB/tmux" "$LAB/remote-jobs" "$LAB/bin" "$LAB/tmp"
export TMPDIR=$LAB/tmp
say() { printf '\n### %s\n' "$*"; }
step() { printf '\n--- %s\n' "$*"; }
HERDR_SESSION=
cleanup() {
  [ -z "$HERDR_SESSION" ] || FM_HERDR_LAB_STATE_DIR="$LAB/herdr-lab" \
    "$BIN/fm-herdr-lab.sh" teardown "$HERDR_SESSION" >/dev/null 2>&1 || true
}
trap cleanup EXIT

git clone -q --no-hardlinks "$ROOT" "$REMOTE_ROOT"
[ "$(git -C "$REMOTE_ROOT" rev-parse HEAD)" = "$(git -C "$ROOT" rev-parse HEAD)" ] \
  || { echo "SCENARIO FAILED: the remote code root is not the change under test"; exit 1; }
cat > "$LAB/bin/ssh" <<SH
#!/usr/bin/env bash
args=("\$@")
for ((i = 0; i < \${#args[@]}; i++)); do
  if [ "\${args[i]}" = fm-remote-entrypoint.sh ]; then
    cd "$REMOTE_ROOT" || exit 64
    export FM_REMOTE_JOB_STATE_ROOT=$LAB/remote-jobs
    export FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux
    exec "$REMOTE_ROOT/bin/fm-remote-entrypoint.sh" "\${args[@]:i+1:4}"
  fi
done
echo "ssh stand-in: no entrypoint in argv" >&2
exit 64
SH
chmod +x "$LAB/bin/ssh"

step "real Herdr lab session with a real Claude supervisor"
HERDR_SESSION=$(FM_HERDR_LAB_STATE_DIR="$LAB/herdr-lab" "$BIN/fm-herdr-lab.sh" name retrymate)
FM_HERDR_LAB_STATE_DIR="$LAB/herdr-lab" "$BIN/fm-herdr-lab.sh" provision "$HERDR_SESSION" \
  || { echo "SCENARIO FAILED: herdr lab did not provision"; exit 1; }
mkdir -p "$LAB/mate-dir"
FM_HERDR_LAB_STATE_DIR="$LAB/herdr-lab" "$BIN/fm-herdr-lab.sh" run "$HERDR_SESSION" \
  workspace create --label $ID --cwd "$LAB/mate-dir" >/dev/null 2>&1
FM_HERDR_LAB_STATE_DIR="$LAB/herdr-lab" "$BIN/fm-herdr-lab.sh" run "$HERDR_SESSION" \
  pane send-text w1:p1 'claude --dangerously-skip-permissions' >/dev/null 2>&1
FM_HERDR_LAB_STATE_DIR="$LAB/herdr-lab" "$BIN/fm-herdr-lab.sh" run "$HERDR_SESSION" \
  pane send-keys w1:p1 enter >/dev/null 2>&1
agent=
for _ in $(seq 1 20); do
  sleep 2
  agent=$(herdr --session "$HERDR_SESSION" agent get w1:p1 2>/dev/null | jq -r '.result.agent.agent // empty')
  [ -n "$agent" ] && break
done
printf 'herdr session=%s agent=%s\n' "$HERDR_SESSION" "${agent:-none}"
[ -n "$agent" ] || { echo "SCENARIO FAILED: no real supervisor registered"; exit 1; }

printf 'kind=secondmate\nmode=secondmate\nharness=claude\nbackend=herdr\nendpoint_task_id=%s\nmodel=pool-model-b\nspawn_gen=%s\nwindow=%s:w1:p1\nherdr_session=%s\nherdr_workspace_id=w1\nherdr_tab_id=w1:t1\nherdr_pane_id=w1:p1\nworktree=%s\nproject=%s\nhome=%s\n' \
  "$ID" "$GEN" "$HERDR_SESSION" "$HERDR_SESSION" "$SHOP" "$SHOP" "$SHOP" \
  > "$SHOP/state/parent-route/$ID.meta"
printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=labhost\n' > "$SHOP/.fm-secondmate-parent"
printf -- '- %s - Lab retry mate. (host: labhost; root: %s; home: %s; scope: lab; projects: ; added 2026-11-02)\n' \
  "$ID" "$REMOTE_ROOT" "$SHOP" > "$PRIMARY/data/secondmates.md"
printf 'kind=secondmate\nmode=secondmate\nharness=claude\nbackend=herdr\nendpoint_task_id=%s\nmodel=pool-model-b\nspawn_gen=%s\nwindow=%s:w1:p1\nherdr_session=%s\nherdr_workspace_id=w1\nherdr_tab_id=w1:t1\nherdr_pane_id=w1:p1\nremote_host=labhost\nremote_root=%s\nhome=%s\nremote_backend=herdr\nremote_herdr_session=%s\nremote_spawn_gen=%s\nremote_target=%s:w1:p1\nworktree=%s\nproject=%s\n' \
  "$ID" "$GEN" "$HERDR_SESSION" "$HERDR_SESSION" "$REMOTE_ROOT" "$SHOP" \
  "$HERDR_SESSION" "$GEN" "$HERDR_SESSION" "$SHOP" "$SHOP" \
  > "$PRIMARY/state/$ID.meta"

host_on() {
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
    -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$PRIMARY" FM_SSH_BIN="$LAB/bin/ssh" "$BIN/fm-on.sh" "$@"
}
PRIMARY_TEARDOWN() {
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
    -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$PRIMARY" FM_SSH_BIN="$LAB/bin/ssh" "$BIN/fm-teardown.sh" "$@"
}
PENDING=$REMOTE_ROOT/state/remote-secondmate-history/$ID.retirement.$GEN.pending.json

say "S4: an interrupted remote retirement stays retryable"
step "start the host retirement and interrupt it once its durable intent exists"
host_on "$ID" fm-remote-secondmate-control.sh retire "$ID" --expect-generation "$GEN" \
  --herdr-session "$HERDR_SESSION" > "$LAB/attempt1.out" 2>&1 &
ATTEMPT=$!
seen=0
for _ in $(seq 1 300); do
  if [ -f "$PENDING" ]; then seen=1; break; fi
  sleep 0.2
done
printf 'pending record published=%s\n' "$seen"
[ "$seen" -eq 1 ] || { echo "SCENARIO FAILED: the retirement never published its durable intent"; exit 1; }
# Kill the whole attempt: the caller, the entrypoint stand-in, and the staged
# host command, exactly as a dropped link or a crashed host would.
for pid in $(ps -eo pid=,args= | awk -v id="$ID" '/fm-remote-secondmate-control\.sh retire/ && index($0, id) {print $1}'); do
  kill -KILL "$pid" 2>/dev/null || true
done
kill -KILL "$ATTEMPT" 2>/dev/null || true
wait "$ATTEMPT" 2>/dev/null || true
sleep 1
step "interrupted state"
printf 'pending exists: %s\n' "$([ -f "$PENDING" ] && echo yes || echo no)"
jq -c . "$PENDING" 2>/dev/null || true
printf 'home exists: %s\n' "$([ -e "$SHOP" ] && echo yes || echo no)"
printf 'pane: %s\n' "$(herdr --session "$HERDR_SESSION" pane get w1:p1 2>&1 | jq -r '.error.code // "present"' 2>/dev/null)"
[ -f "$PENDING" ] || { echo "SCENARIO FAILED: the interruption left no durable intent to retry from"; exit 1; }

step "retry through the primary's own bin/fm-teardown.sh"
retry=$(PRIMARY_TEARDOWN "$ID" 2>&1); rrc=$?
printf 'rc=%s\n%s\n' "$rrc" "$retry"
[ "$rrc" -eq 0 ] || { echo "SCENARIO FAILED: the interrupted retirement was not retryable"; exit 1; }

step "retry outcome"
pane=$(herdr --session "$HERDR_SESSION" pane get w1:p1 2>&1)
printf 'herdr pane get: %s\n' "$pane"
printf '%s\n' "$pane" | grep -q 'pane_not_found' \
  || { echo "SCENARIO FAILED: the pane survived the retried retirement"; exit 1; }
[ ! -e "$SHOP" ] || { echo "SCENARIO FAILED: the home survived the retry"; exit 1; }
ls -d "$LAB"/shop.retiring.* 2>/dev/null && { echo "SCENARIO FAILED: the retry stranded a staged copy"; exit 1; }
ls "$REMOTE_ROOT/state/remote-secondmate-history/"*.pending.json 2>/dev/null \
  && { echo "SCENARIO FAILED: pending retirement evidence survived the retry"; exit 1; }
PROOF=$REMOTE_ROOT/state/remote-secondmate-history/$ID.retirement.$GEN.json
jq -c . "$PROOF"
[ "$(jq -r .destroyed "$PROOF")" = true ] \
  || { echo "SCENARIO FAILED: the retry published no destruction proof"; exit 1; }
[ ! -e "$PRIMARY/state/$ID.meta" ] || { echo "SCENARIO FAILED: the route record survived the retry"; exit 1; }
grep -qE "^- $ID( |$)" "$PRIMARY/data/secondmates.md" \
  && { echo "SCENARIO FAILED: the registry route survived the retry"; exit 1; }

say "S4b: interruption after the endpoint closes (home removal / proof window)"
ID=labthree
GEN=lab.gen.3
SHOP2=$LAB/shop-$ID
mkdir -p "$SHOP2/bin" "$SHOP2/state/parent-route"
printf '%s\n' "$ID" > "$SHOP2/.fm-secondmate-home"
printf '# Firstmate\n' > "$SHOP2/AGENTS.md"
printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=labhost\n' > "$SHOP2/.fm-secondmate-parent"
FM_HERDR_LAB_STATE_DIR="$LAB/herdr-lab" "$BIN/fm-herdr-lab.sh" run "$HERDR_SESSION" \
  workspace create --label $ID --cwd "$LAB/mate-dir" >/dev/null 2>&1
WS=$(FM_HERDR_LAB_STATE_DIR="$LAB/herdr-lab" "$BIN/fm-herdr-lab.sh" run "$HERDR_SESSION" \
  workspace list --json 2>/dev/null | jq -r --arg l "$ID" '.result.workspaces[] | select(.label == $l) | .id' | tail -1)
WS=${WS:-w2}
PANE_ID=$WS:p1
FM_HERDR_LAB_STATE_DIR="$LAB/herdr-lab" "$BIN/fm-herdr-lab.sh" run "$HERDR_SESSION" \
  pane send-text "$PANE_ID" 'claude --dangerously-skip-permissions' >/dev/null 2>&1
FM_HERDR_LAB_STATE_DIR="$LAB/herdr-lab" "$BIN/fm-herdr-lab.sh" run "$HERDR_SESSION" \
  pane send-keys "$PANE_ID" enter >/dev/null 2>&1
agent=
for _ in $(seq 1 20); do
  sleep 2
  agent=$(herdr --session "$HERDR_SESSION" agent get "$PANE_ID" 2>/dev/null | jq -r '.result.agent.agent // empty')
  [ -n "$agent" ] && break
done
printf 'second supervisor pane=%s agent=%s\n' "$PANE_ID" "${agent:-none}"
[ -n "$agent" ] || { echo "SCENARIO FAILED: no real supervisor registered for the second mate"; exit 1; }
printf 'kind=secondmate\nmode=secondmate\nharness=claude\nbackend=herdr\nendpoint_task_id=%s\nmodel=pool-model-b\nspawn_gen=%s\nwindow=%s:%s\nherdr_session=%s\nherdr_workspace_id=%s\nherdr_tab_id=%s:t1\nherdr_pane_id=%s\nworktree=%s\nproject=%s\nhome=%s\n' \
  "$ID" "$GEN" "$HERDR_SESSION" "$PANE_ID" "$HERDR_SESSION" "$WS" "$WS" "$PANE_ID" "$SHOP2" "$SHOP2" "$SHOP2" \
  > "$SHOP2/state/parent-route/$ID.meta"
printf -- '- %s - Lab second retry mate. (host: labhost; root: %s; home: %s; scope: lab; projects: ; added 2026-11-02)\n' \
  "$ID" "$REMOTE_ROOT" "$SHOP2" >> "$PRIMARY/data/secondmates.md"
printf 'kind=secondmate\nmode=secondmate\nharness=claude\nbackend=herdr\nendpoint_task_id=%s\nmodel=pool-model-b\nspawn_gen=%s\nwindow=%s:%s\nherdr_session=%s\nherdr_workspace_id=%s\nherdr_tab_id=%s:t1\nherdr_pane_id=%s\nremote_host=labhost\nremote_root=%s\nhome=%s\nremote_backend=herdr\nremote_herdr_session=%s\nremote_spawn_gen=%s\nremote_target=%s:%s\nworktree=%s\nproject=%s\n' \
  "$ID" "$GEN" "$HERDR_SESSION" "$PANE_ID" "$HERDR_SESSION" "$WS" "$WS" "$PANE_ID" "$REMOTE_ROOT" "$SHOP2" \
  "$HERDR_SESSION" "$GEN" "$HERDR_SESSION" "$PANE_ID" "$SHOP2" "$SHOP2" > "$PRIMARY/state/$ID.meta"
PENDING2=$REMOTE_ROOT/state/remote-secondmate-history/$ID.retirement.$GEN.pending.json
host_on "$ID" fm-remote-secondmate-control.sh retire "$ID" --expect-generation "$GEN" \
  --herdr-session "$HERDR_SESSION" > "$LAB/attempt2.out" 2>&1 &
ATTEMPT2=$!
closed=0
for _ in $(seq 1 600); do
  if ! herdr --session "$HERDR_SESSION" pane get "$PANE_ID" >/dev/null 2>&1; then closed=1; break; fi
  sleep 0.05
done
printf 'endpoint closed by the first attempt=%s\n' "$closed"
for pid in $(ps -eo pid=,args= | awk -v id="$ID" '/fm-remote-secondmate-control\.sh retire/ && index($0, id) {print $1}'); do
  kill -KILL "$pid" 2>/dev/null || true
done
kill -KILL "$ATTEMPT2" 2>/dev/null || true
wait "$ATTEMPT2" 2>/dev/null || true
sleep 1
step "interrupted state after the endpoint closed"
printf 'pending exists: %s\n' "$([ -f "$PENDING2" ] && echo yes || echo no)"
printf 'home exists: %s\n' "$([ -e "$SHOP2" ] && echo yes || echo no)"
ls -d "$LAB"/shop-$ID.retiring.* 2>/dev/null || true
printf 'proof exists: %s\n' "$([ -f "$REMOTE_ROOT/state/remote-secondmate-history/$ID.retirement.$GEN.json" ] && echo yes || echo no)"
step "retry the second interruption through bin/fm-teardown.sh"
retry2=$(PRIMARY_TEARDOWN "$ID" 2>&1); rrc2=$?
printf 'rc=%s\n%s\n' "$rrc2" "$retry2"
[ "$rrc2" -eq 0 ] || { echo "SCENARIO FAILED: the post-close interruption was not retryable"; exit 1; }
[ ! -e "$SHOP2" ] || { echo "SCENARIO FAILED: the second home survived the retry"; exit 1; }
ls -d "$LAB"/shop-$ID.retiring.* 2>/dev/null && { echo "SCENARIO FAILED: the retry stranded a staged copy"; exit 1; }
ls "$REMOTE_ROOT/state/remote-secondmate-history/"*.pending.json 2>/dev/null \
  && { echo "SCENARIO FAILED: pending evidence survived"; exit 1; }
PROOF2=$REMOTE_ROOT/state/remote-secondmate-history/$ID.retirement.$GEN.json
jq -c . "$PROOF2"
[ "$(jq -r .destroyed "$PROOF2")" = true ] \
  || { echo "SCENARIO FAILED: the second retry published no destruction proof"; exit 1; }
[ ! -e "$PRIMARY/state/$ID.meta" ] || { echo "SCENARIO FAILED: the second route record survived"; exit 1; }

say "PASS: the interrupted retirement kept its durable intent, the retry finished it, and no staged copy or pending record was stranded"
