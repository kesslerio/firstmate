#!/usr/bin/env bash
# Live scenario S5: a launch that finds a supervisor already running on another
# model is recognized by the receipt that observed it, and a replacement binds
# the generation the host actually records.
#
# Driven through the real parent half (bin/fm-fleet-seats.sh reserve ->
# dispatch -> reconcile-remote) and the real host half (bin/fm-on.sh ->
# bin/fm-remote-entrypoint.sh -> remote job worker ->
# bin/fm-remote-secondmate-control.sh launch) against a real Herdr lab session
# holding a real Claude supervisor.
set -u
ROOT=${ROOT:?run from the worktree}
LAB=${LAB:?disposable lab dir}
BIN=$ROOT/bin
PRIMARY=$LAB/primary
SHOP=$LAB/shop
REMOTE_ROOT=$LAB/remote-root
ID=theshop
HOST_GEN=host.7
HOST_MODEL=pool-model-b
REQUESTED_MODEL=pool-model-a
mkdir -p "$LAB/tmux" "$LAB/remote-jobs" "$LAB/bin" "$LAB/tmp"
export TMPDIR=$LAB/tmp
say() { printf '\n### %s\n' "$*"; }
step() { printf '\n--- %s\n' "$*"; }
HERDR_SESSION=
HOLDERS=
cleanup() {
  local pid
  for pid in $HOLDERS; do kill "$pid" 2>/dev/null || true; done
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

step "real Herdr lab session with a real Claude supervisor already running"
HERDR_SESSION=$(FM_HERDR_LAB_STATE_DIR="$LAB/herdr-lab" "$BIN/fm-herdr-lab.sh" name observe)
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
[ -n "$agent" ] || { echo "SCENARIO FAILED: no real supervisor registered"; exit 1; }

# The host records the supervisor it actually runs: generation HOST_GEN on
# HOST_MODEL, while the parent is about to ask for REQUESTED_MODEL.
printf 'kind=secondmate\nmode=secondmate\nharness=claude\nbackend=herdr\nendpoint_task_id=%s\nmodel=%s\nspawn_gen=%s\nwindow=%s:w1:p1\nherdr_session=%s\nherdr_workspace_id=w1\nherdr_tab_id=w1:t1\nherdr_pane_id=w1:p1\nworktree=%s\nproject=%s\nhome=%s\n' \
  "$ID" "$HOST_MODEL" "$HOST_GEN" "$HERDR_SESSION" "$HERDR_SESSION" "$SHOP" "$SHOP" "$SHOP" \
  > "$SHOP/state/parent-route/$ID.meta"
printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=labhost\n' > "$SHOP/.fm-secondmate-parent"

printf '{"pools":[{"name":"shared","capacity":2,"models":["%s","%s"]}]}\n' \
  "$REQUESTED_MODEL" "$HOST_MODEL" > "$PRIMARY/config/fleet-seats"
printf -- '- %s - Lab observing mate. (host: labhost; root: %s; home: %s; scope: lab; projects: ; added 2026-11-02)\n' \
  "$ID" "$REMOTE_ROOT" "$SHOP" > "$PRIMARY/data/secondmates.md"
printf 'kind=secondmate\nmode=secondmate\nharness=claude\nbackend=herdr\nendpoint_task_id=%s\nmodel=%s\nwindow=%s:w1:p1\nherdr_session=%s\nherdr_workspace_id=w1\nherdr_tab_id=w1:t1\nherdr_pane_id=w1:p1\nremote_host=labhost\nremote_root=%s\nhome=%s\nworktree=%s\nproject=%s\n' \
  "$ID" "$HOST_MODEL" "$HERDR_SESSION" "$HERDR_SESSION" "$REMOTE_ROOT" "$SHOP" "$SHOP" "$SHOP" \
  > "$PRIMARY/state/$ID.meta"

seat() {
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
    -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$PRIMARY" PATH="$LAB/bin:$PATH" "$BIN/fm-fleet-seats.sh" "$@"
}
host_on() {
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
    -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$PRIMARY" FM_SSH_BIN="$LAB/bin/ssh" "$BIN/fm-on.sh" "$@"
}
new_holder() { sleep 600 >/dev/null 2>&1 & HOLDER=$!; HOLDERS="$HOLDERS $HOLDER"; }

reserve_and_dispatch() { # <operation> <previous>; the reserving process dispatches
  seat reserve "$ID" --generation "$1" --previous-generation "$2" --kind secondmate \
    --harness claude --model "$REQUESTED_MODEL" --holder-pid "$$" || return 1
  route=$(umask 077; mktemp "$PRIMARY/state/.route.XXXXXX") || return 1
  jq -cn --arg host labhost --arg root "$REMOTE_ROOT" --arg home "$SHOP" --arg op "$1" \
    '{placement: "remote", backend: "herdr", target: null, home: $home, host: $host,
      remote_root: $root, spawn_gen: null, operation: $op}' > "$route" || return 1
  seat dispatch "$ID" --generation "$1" --route-file "$route"
  rm -f "$route"
}

say "S5: an observing receipt counts the model the host actually runs, and a replacement binds the host generation"
# Give the primary a certificate for the pre-existing supervisor first, so the
# pool already knows about it.
step "first serve: the pre-existing supervisor is certified"
serve=$(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
  -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
  FM_HOME="$PRIMARY" FM_SSH_BIN="$LAB/bin/ssh" FM_FLEET_SEATS_TEST_BACKOFF=0 \
  "$BIN/fm-fleet-seats.sh" serve-remotes 2>&1)
printf '%s\n' "$serve"
printf '%s\n' "$serve" | grep -q "served $ID" || { echo "SCENARIO FAILED: initial serve failed"; exit 1; }

step "parent reserves a launch asking for $REQUESTED_MODEL, then the host observes the running supervisor"
OP1="op$(date +%s).$$.1"
reserve_and_dispatch "$OP1" - || { echo "SCENARIO FAILED: the candidate seat was not reserved/dispatched"; exit 1; }
launch=$(host_on "$ID" fm-remote-secondmate-control.sh launch "$ID" claude "$REQUESTED_MODEL" - herdr \
  --operation "$OP1" --previous - --herdr-session "$HERDR_SESSION" </dev/null 2>&1)
lrc=$?
printf 'host launch rc=%s\n%s\n' "$lrc" "$launch"
[ "$lrc" -eq 0 ] || { echo "SCENARIO FAILED: the host launch failed"; exit 1; }
printf '%s\n' "$launch" | sed -n 's/^seat_disposition=//p' | tail -1 > "$LAB/disposition1.json"
RESP=$(cat "$LAB/disposition1.json")
printf 'observed disposition: %s\n' "$RESP"
[ "$(printf '%s\n' "$RESP" | jq -r .disposition)" = existing ] \
  || { echo "SCENARIO FAILED: the host did not report the supervisor it found"; exit 1; }
[ "$(printf '%s\n' "$RESP" | jq -r .actual_generation)" = "$HOST_GEN" ] \
  || { echo "SCENARIO FAILED: the receipt does not carry the host generation"; exit 1; }
[ "$(printf '%s\n' "$RESP" | jq -r .actual_model)" = "$HOST_MODEL" ] \
  || { echo "SCENARIO FAILED: the receipt does not carry the model the host runs"; exit 1; }
[ "$(printf '%s\n' "$RESP" | jq -r .actual_model)" != "$REQUESTED_MODEL" ] \
  || { echo "SCENARIO FAILED: the receipt echoed the requested model"; exit 1; }

step "the parent applies that receipt"
chmod 600 "$LAB/disposition1.json"
rec=$(seat reconcile-remote "$ID" --generation "$OP1" --response-file "$LAB/disposition1.json" 2>&1); rrc=$?
printf 'reconcile-remote rc=%s\n%s\n' "$rrc" "$rec"
[ "$rrc" -eq 0 ] || { echo "SCENARIO FAILED: the parent did not accept the observing receipt"; exit 1; }
ledger=$(seat show "$ID")
printf '%s\n' "$ledger" | jq -c '.incarnations[] | {generation, lifecycle, model, previous_generation}'
[ "$(printf '%s\n' "$ledger" | jq -r --arg g "$HOST_GEN" '.incarnations[] | select(.generation == $g) | .model')" = "$HOST_MODEL" ] \
  || { echo "SCENARIO FAILED: the observed supervisor was not counted on the model it runs"; exit 1; }
[ "$(printf '%s\n' "$ledger" | jq -r --arg g "$OP1" '.incarnations[] | select(.generation == $g) | .lifecycle')" = released ] \
  || { echo "SCENARIO FAILED: the candidate seat was not released"; exit 1; }
step "the requested model never took a seat: pool occupancy"
new_holder
probe=$(seat reserve probe-occupancy --generation g-probe-occ --harness claude \
  --model "$REQUESTED_MODEL" --kind ship --holder-pid "$HOLDER" 2>&1); prc=$?
printf 'reserve on %s rc=%s\n%s\n' "$REQUESTED_MODEL" "$prc" "$probe"
[ "$prc" -eq 0 ] || { echo "SCENARIO FAILED: the pool did not have the expected free seat"; exit 1; }
printf '%s\n' "$probe" | grep -q 'used=2 capacity=2' \
  || { echo "SCENARIO FAILED: the observed supervisor and the new launch did not count one seat each"; exit 1; }
seat release probe-occupancy --generation g-probe-occ --reason prelaunch >/dev/null || true

say "S5b: a replacement binds the generation the host actually records"
step "the host now records host.8 while the primary still names host.7 (a lost reply): the stale replacement must be refused"
sed -i "s/^spawn_gen=.*/spawn_gen=host.8/" "$SHOP/state/parent-route/$ID.meta"
OPA="op$(date +%s).$$.a"
reserve_and_dispatch "$OPA" "$HOST_GEN" || { echo "SCENARIO FAILED: the stale-generation candidate was not reserved"; exit 1; }
mismatch=$(host_on "$ID" fm-remote-secondmate-control.sh launch "$ID" claude "$REQUESTED_MODEL" - herdr \
  --operation "$OPA" --previous "$HOST_GEN" --herdr-session "$HERDR_SESSION" </dev/null 2>&1); mrc=$?
printf 'host launch rc=%s\n%s\n' "$mrc" "$mismatch"
[ "$mrc" -eq 6 ] || { echo "SCENARIO FAILED: a replacement of the generation the host no longer records was not refused"; exit 1; }
printf '%s\n' "$mismatch" | grep -q 'generation-mismatch' \
  || { echo "SCENARIO FAILED: the refusal did not name the generation mismatch"; exit 1; }
[ "$(herdr --session "$HERDR_SESSION" agent get w1:p1 2>/dev/null | jq -r '.result.agent.agent // empty')" = "$agent" ] \
  || { echo "SCENARIO FAILED: the refused replacement disturbed the live supervisor"; exit 1; }
[ "$(sed -n 's/^spawn_gen=//p' "$SHOP/state/parent-route/$ID.meta")" = host.8 ] \
  || { echo "SCENARIO FAILED: the refused replacement rewrote the host record"; exit 1; }
# The host answered with its prelaunch refusal, so the parent releases the
# candidate through the same reconcile path it uses for every host reply.
printf '%s\n' "$mismatch" | sed -n 's/^seat_disposition=//p' | tail -1 > "$LAB/disposition-refused.json"
chmod 600 "$LAB/disposition-refused.json"
seat reconcile-remote "$ID" --generation "$OPA" --response-file "$LAB/disposition-refused.json" >/dev/null 2>&1 \
  || { echo "SCENARIO FAILED: the refused candidate could not be released"; exit 1; }
[ "$(seat show "$ID" | jq -r --arg g "$OPA" '.incarnations[] | select(.generation == $g) | .lifecycle')" = released ] \
  || { echo "SCENARIO FAILED: the refused candidate stayed counted"; exit 1; }

step "with the host recording $HOST_GEN again, a replacement naming it is accepted and bound to it"
sed -i "s/^spawn_gen=.*/spawn_gen=$HOST_GEN/" "$SHOP/state/parent-route/$ID.meta"
OPB="op$(date +%s).$$.b"
reserve_and_dispatch "$OPB" "$HOST_GEN" || { echo "SCENARIO FAILED: the host-generation replacement was not reserved"; exit 1; }
replacement=$(host_on "$ID" fm-remote-secondmate-control.sh launch "$ID" claude "$REQUESTED_MODEL" - herdr \
  --operation "$OPB" --previous "$HOST_GEN" --herdr-session "$HERDR_SESSION" </dev/null 2>&1); rep_rc=$?
printf 'host launch rc=%s\n' "$rep_rc"
printf '%s\n' "$replacement" | sed -n 's/^seat_disposition=//p' | tail -1 > "$LAB/disposition4.json"
[ "$rep_rc" -eq 0 ] || { echo "SCENARIO FAILED: the host refused the generation it records"; exit 1; }
printf 'replacement disposition: %s\n' "$(cat "$LAB/disposition4.json")"
[ "$(jq -r .previous_generation "$LAB/disposition4.json")" = "$HOST_GEN" ] \
  || { echo "SCENARIO FAILED: the receipt does not bind the host generation as predecessor"; exit 1; }
[ "$(jq -r .actual_generation "$LAB/disposition4.json")" = "$HOST_GEN" ] \
  || { echo "SCENARIO FAILED: the replacement did not target the host generation"; exit 1; }
chmod 600 "$LAB/disposition4.json"
rec2=$(seat reconcile-remote "$ID" --generation "$OPB" --response-file "$LAB/disposition4.json" 2>&1); rrc2=$?
printf 'reconcile-remote rc=%s\n%s\n' "$rrc2" "$rec2"
[ "$rrc2" -eq 0 ] || { echo "SCENARIO FAILED: the parent did not accept the replacement binding"; exit 1; }
final=$(seat show "$ID")
printf '%s\n' "$final" | jq -c '.incarnations[] | {generation, lifecycle, model, previous_generation}'
[ "$(printf '%s\n' "$final" | jq -r --arg g "$HOST_GEN" '.incarnations[] | select(.generation == $g) | .model')" = "$HOST_MODEL" ] \
  || { echo "SCENARIO FAILED: the replacement lost the host-recorded model"; exit 1; }
[ "$(printf '%s\n' "$final" | jq -r --arg g "$OPB" '.incarnations[] | select(.generation == $g) | .lifecycle')" = released ] \
  || { echo "SCENARIO FAILED: the replacement candidate was not released into the host generation"; exit 1; }

say "PASS: the observing receipt carried the host generation and model (never the requested model), the pool charged it once, a replacement of a generation the host no longer records was refused untouched, and a replacement naming the host generation was bound to it"
