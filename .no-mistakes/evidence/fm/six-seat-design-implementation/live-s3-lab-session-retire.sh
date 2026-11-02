#!/usr/bin/env bash
# Live scenario S3: a remote second mate recorded under an isolated fm-lab-*
# Herdr session is resolved and retired on that same session, driven by the
# primary's own bin/fm-teardown.sh -> bin/fm-on.sh ->
# bin/fm-remote-entrypoint.sh -> remote job worker ->
# bin/fm-remote-secondmate-control.sh retire path, against a real Herdr lab and
# a real Claude supervisor agent in it.
#
# The SSH hop is the same single stand-in S2 documents: no second host is
# reachable here and real ssh to this account would write the remote job
# worker's state into the operator's home.
set -u
ROOT=${ROOT:?run from the worktree}
LAB=${LAB:?disposable lab dir}
BIN=$ROOT/bin
PRIMARY=$LAB/primary
SHOP=$LAB/shop
REMOTE_ROOT=$LAB/remote-root
ID=labmate
GEN=lab.gen.1
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
    # The remote host's own checkout is the cwd on a real second host, so the
    # staged command never inherits the gate worktree's git-common-dir.
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

step "provision a real Herdr lab session and start this mate's real Claude supervisor"
HERDR_SESSION=$(FM_HERDR_LAB_STATE_DIR="$LAB/herdr-lab" "$BIN/fm-herdr-lab.sh" name retiree)
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
printf 'herdr session=%s pane=w1:p1 agent=%s state=%s\n' "$HERDR_SESSION" "${agent:-none}" \
  "$(herdr --session "$HERDR_SESSION" agent get w1:p1 2>/dev/null | jq -r '.result.agent.agent_status // empty')"
[ -n "$agent" ] || { echo "SCENARIO FAILED: no real supervisor registered in the lab session"; exit 1; }

printf 'kind=secondmate\nmode=secondmate\nharness=claude\nbackend=herdr\nendpoint_task_id=%s\nmodel=pool-model-b\nspawn_gen=%s\nwindow=%s:w1:p1\nherdr_session=%s\nherdr_workspace_id=w1\nherdr_tab_id=w1:t1\nherdr_pane_id=w1:p1\nworktree=%s\nproject=%s\nhome=%s\n' \
  "$ID" "$GEN" "$HERDR_SESSION" "$HERDR_SESSION" "$SHOP" "$SHOP" "$SHOP" \
  > "$SHOP/state/parent-route/$ID.meta"
printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=labhost\n' > "$SHOP/.fm-secondmate-parent"

printf -- '- %s - Lab lab-session mate. (host: labhost; root: %s; home: %s; scope: lab; projects: ; added 2026-11-02)\n' \
  "$ID" "$REMOTE_ROOT" "$SHOP" > "$PRIMARY/data/secondmates.md"
printf 'kind=secondmate\nmode=secondmate\nharness=claude\nbackend=herdr\nendpoint_task_id=%s\nmodel=pool-model-b\nspawn_gen=%s\nwindow=%s:w1:p1\nherdr_session=%s\nherdr_workspace_id=w1\nherdr_tab_id=w1:t1\nherdr_pane_id=w1:p1\nremote_host=labhost\nremote_root=%s\nhome=%s\nremote_backend=herdr\nremote_herdr_session=%s\nremote_spawn_gen=%s\nremote_target=%s:w1:p1\nworktree=%s\nproject=%s\n' \
  "$ID" "$GEN" "$HERDR_SESSION" "$HERDR_SESSION" "$REMOTE_ROOT" "$SHOP" \
  "$HERDR_SESSION" "$GEN" "$HERDR_SESSION" "$SHOP" "$SHOP" \
  > "$PRIMARY/state/$ID.meta"

on() { # <host-controller args...>
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
    -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$PRIMARY" FM_SSH_BIN="$LAB/bin/ssh" "$BIN/fm-on.sh" "$@"
}

say "S3: a lab-session remote second mate resolves and retires on its recorded session"
step "host route resolution without and with the recorded session"
bare=$(on "$ID" fm-remote-secondmate-control.sh route "$ID" 2>&1); brc=$?
printf 'without --herdr-session rc=%s\n%s\n' "$brc" "$bare"
[ "$brc" -ne 0 ] || { echo "SCENARIO FAILED: a lab-session endpoint resolved against the shared session"; exit 1; }
printf '%s\n' "$bare" | grep -q "expected 'fm-remote'" \
  || { echo "SCENARIO FAILED: the refusal did not name the default session"; exit 1; }
routed=$(on "$ID" fm-remote-secondmate-control.sh route "$ID" --herdr-session "$HERDR_SESSION" 2>&1); rrc=$?
printf 'with --herdr-session rc=%s\n%s\n' "$rrc" "$routed"
[ "$rrc" -eq 0 ] || { echo "SCENARIO FAILED: the recorded lab session did not resolve"; exit 1; }
printf '%s\n' "$routed" | grep -q "^target=$HERDR_SESSION:w1:p1$" \
  || { echo "SCENARIO FAILED: the route did not resolve on the recorded lab session"; exit 1; }

step "primary-driven retirement: bin/fm-teardown.sh $ID"
td=$(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
  -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
  FM_HOME="$PRIMARY" FM_SSH_BIN="$LAB/bin/ssh" "$BIN/fm-teardown.sh" "$ID" 2>&1); trc=$?
printf 'rc=%s\n%s\n' "$trc" "$td"
[ "$trc" -eq 0 ] || { echo "SCENARIO FAILED: retirement did not complete"; exit 1; }

step "the real endpoint, home, and both sides' destruction evidence"
pane=$(herdr --session "$HERDR_SESSION" pane get w1:p1 2>&1)
printf 'herdr pane get: %s\n' "$pane"
printf '%s\n' "$pane" | grep -q 'pane_not_found' \
  || { echo "SCENARIO FAILED: the lab-session pane survived retirement"; exit 1; }
[ ! -e "$SHOP" ] || { echo "SCENARIO FAILED: the remote home survived retirement"; exit 1; }
[ ! -e "$PRIMARY/state/$ID.meta" ] || { echo "SCENARIO FAILED: the primary route record survived"; exit 1; }
grep -qE "^- $ID( |$)" "$PRIMARY/data/secondmates.md" \
  && { echo "SCENARIO FAILED: the registry route survived"; exit 1; }
PROOF=$REMOTE_ROOT/state/remote-secondmate-history/$ID.retirement.$GEN.json
printf 'host destruction proof %s:\n' "$PROOF"
jq -c . "$PROOF"
[ "$(jq -r .destroyed "$PROOF")" = true ] \
  || { echo "SCENARIO FAILED: no destruction proof was published"; exit 1; }
[ "$(jq -r .generation "$PROOF")" = "$GEN" ] \
  || { echo "SCENARIO FAILED: the proof names another generation"; exit 1; }
[ "$(jq -r .target "$PROOF")" = "$HERDR_SESSION:w1:p1" ] \
  || { echo "SCENARIO FAILED: the proof names another session"; exit 1; }
[ "$(jq -r .backend "$PROOF")" = herdr ] \
  || { echo "SCENARIO FAILED: the proof names another backend"; exit 1; }
step "no staged copy or pending evidence survives"
ls -d "$LAB"/shop.retiring.* 2>/dev/null && { echo "SCENARIO FAILED: a staged retirement copy was stranded"; exit 1; }
ls "$REMOTE_ROOT/state/remote-secondmate-history/"*.pending.json 2>/dev/null \
  && { echo "SCENARIO FAILED: retirement pending evidence survived"; exit 1; }

say "PASS: the lab-session mate refused the shared session, resolved on the recorded one, and retired there with the pane, home, records, and a matching destruction proof"
