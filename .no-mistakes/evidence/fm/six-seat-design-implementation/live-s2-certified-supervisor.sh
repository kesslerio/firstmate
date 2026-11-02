#!/usr/bin/env bash
# Live scenario S2: a supervisor that was already running on a remote host when
# its pools were declared is counted exactly once, and a generation the remote
# serve certificate proves is never refused as one the seat ledger never issued.
#
# Driven through the real bin/fm-fleet-seats.sh serve-remotes ->
# bin/fm-on.sh -> bin/fm-remote-entrypoint.sh -> remote job worker ->
# bin/fm-remote-secondmate-control.sh path, against a genuine second Firstmate
# checkout (git clone of this worktree) as the remote code root and a real Herdr
# lab session holding a real Claude supervisor agent.
#
# The SSH hop is the one stand-in: no second host is reachable from the gate,
# and a real ssh to this same account would write the remote job worker's state
# into the operator's home. `$LAB/bin/ssh` therefore execs the remote code
# root's own entrypoint with the exact argv fm-on.sh composed.
set -u
ROOT=${ROOT:?run from the worktree}
LAB=${LAB:?disposable lab dir}
BIN=$ROOT/bin
PRIMARY=$LAB/primary
SHOP=$LAB/shop
REMOTE_ROOT=$LAB/remote-root
ID=theshop
GEN=host.1
MODEL=pool-model-b
mkdir -p "$LAB/tmux" "$LAB/remote-jobs" "$LAB/bin"
export TMPDIR=$LAB/tmp
mkdir -p "$TMPDIR"

say() { printf '\n### %s\n' "$*"; }
step() { printf '\n--- %s\n' "$*"; }

HERDR_SESSION=
cleanup() {
  [ -z "$HERDR_SESSION" ] || FM_HERDR_LAB_STATE_DIR="$LAB/herdr-lab" \
    "$BIN/fm-herdr-lab.sh" teardown "$HERDR_SESSION" >/dev/null 2>&1 || true
}
trap cleanup EXIT

# --- the remote "host": a genuine second Firstmate checkout ------------------
step "git clone the run worktree as the remote code root"
git clone -q --no-hardlinks "$ROOT" "$REMOTE_ROOT"
git -C "$REMOTE_ROOT" log --oneline -1
[ "$(git -C "$REMOTE_ROOT" rev-parse HEAD)" = "$(git -C "$ROOT" rev-parse HEAD)" ] \
  || { echo "SCENARIO FAILED: the remote code root is not the change under test"; exit 1; }

# The one stand-in for the SSH hop (see the header).
cat > "$LAB/bin/ssh" <<SH
#!/usr/bin/env bash
# fm-on.sh argv: <ssh options> -- <host> fm-remote-entrypoint.sh 1 <root> <home> <argv>
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

# --- a real running supervisor on the remote host ---------------------------
step "provision a real Herdr lab session and start a real Claude supervisor in it"
HERDR_SESSION=$(FM_HERDR_LAB_STATE_DIR="$LAB/herdr-lab" "$BIN/fm-herdr-lab.sh" name poolsuper)
FM_HERDR_LAB_STATE_DIR="$LAB/herdr-lab" "$BIN/fm-herdr-lab.sh" provision "$HERDR_SESSION" \
  || { echo "SCENARIO FAILED: herdr lab did not provision"; exit 1; }
mkdir -p "$LAB/supervisor-dir"
FM_HERDR_LAB_STATE_DIR="$LAB/herdr-lab" "$BIN/fm-herdr-lab.sh" run "$HERDR_SESSION" \
  workspace create --label supervisor --cwd "$LAB/supervisor-dir" >/dev/null 2>&1
FM_HERDR_LAB_STATE_DIR="$LAB/herdr-lab" "$BIN/fm-herdr-lab.sh" run "$HERDR_SESSION" \
  pane send-text w1:p1 'claude --dangerously-skip-permissions' >/dev/null 2>&1
FM_HERDR_LAB_STATE_DIR="$LAB/herdr-lab" "$BIN/fm-herdr-lab.sh" run "$HERDR_SESSION" \
  pane send-keys w1:p1 enter >/dev/null 2>&1
agent=
for _ in $(seq 1 20); do
  sleep 2
  agent=$(herdr --session "$HERDR_SESSION" agent get w1:p1 2>/dev/null \
    | jq -r '.result.agent | "\(.agent // "")/\(.agent_status // "")"' 2>/dev/null)
  case "$agent" in ''|/) agent= ;; *) break ;; esac
done
agent_status=$(herdr --session "$HERDR_SESSION" agent get w1:p1 2>/dev/null | jq -r '.result.agent.agent_status // empty')
agent_proc=$(herdr --session "$HERDR_SESSION" pane process-info --pane w1:p1 2>/dev/null \
  | jq -r '.result.process_info.foreground_processes[0].name // empty')
printf 'herdr session=%s pane=w1:p1 agent=%s status=%s foreground=%s\n' \
  "$HERDR_SESSION" "$agent" "$agent_status" "$agent_proc"
case "$agent" in claude/*|*/claude*) ;; *) echo "SCENARIO FAILED: no real supervisor agent registered in the lab session"; exit 1 ;; esac

# The remote home is a second mate whose binding names its remote parent, so it
# receives policy and grants from the primary instead of owning a ledger.
printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=labhost\n' > "$SHOP/.fm-secondmate-parent"

# The supervisor's own host-side record, written the way a pre-pool launch left it.
printf 'kind=secondmate\nmode=secondmate\nharness=claude\nbackend=herdr\nendpoint_task_id=%s\nmodel=%s\nspawn_gen=%s\nwindow=%s:w1:p1\nherdr_session=%s\nherdr_workspace_id=w1\nherdr_tab_id=w1:t1\nherdr_pane_id=w1:p1\nworktree=%s\nproject=%s\nhome=%s\n' \
  "$ID" "$MODEL" "$GEN" "$HERDR_SESSION" "$HERDR_SESSION" "$SHOP" "$SHOP" "$SHOP" \
  > "$SHOP/state/parent-route/$ID.meta"

# --- primary home: pools, registry route, and its pre-generation route record
printf '{"pools":[{"name":"shared","capacity":1,"models":["%s"]}]}\n' "$MODEL" > "$PRIMARY/config/fleet-seats"
printf -- '- %s - Lab remote mate. (host: labhost; root: %s; home: %s; scope: lab; projects: ; added 2026-11-02)\n' \
  "$ID" "$REMOTE_ROOT" "$SHOP" > "$PRIMARY/data/secondmates.md"
printf 'kind=secondmate\nmode=secondmate\nharness=claude\nbackend=herdr\nendpoint_task_id=%s\nmodel=%s\nwindow=%s:w1:p1\nherdr_session=%s\nherdr_workspace_id=w1\nherdr_tab_id=w1:t1\nherdr_pane_id=w1:p1\nremote_host=labhost\nremote_root=%s\nhome=%s\nworktree=%s\nproject=%s\n' \
  "$ID" "$MODEL" "$HERDR_SESSION" "$HERDR_SESSION" "$REMOTE_ROOT" "$SHOP" "$SHOP" "$SHOP" \
  > "$PRIMARY/state/$ID.meta"

seat() { # <cmd...> in the primary home
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
    -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$PRIMARY" PATH="$LAB/bin:$PATH" \
    "$BIN/fm-fleet-seats.sh" "$@"
}
new_holder() { sleep 600 >/dev/null 2>&1 & HOLDER=$!; }

say "S2: a pre-pool remote supervisor is counted exactly once, and a certificate-proved generation is not refused"
step "before the first serve the remote cannot be counted (no certificate)"
new_holder
pre=$(seat reserve probe0 --generation g-probe0 --harness claude --model "$MODEL" --kind ship --holder-pid "$HOLDER" 2>&1)
printf 'rc=%s\n%s\n' "$?" "$pre"
kill "$HOLDER" 2>/dev/null || true

step "bin/fm-fleet-seats.sh serve-remotes (real on -> entrypoint -> worker -> host control)"
serve=$(env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
  -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
  FM_HOME="$PRIMARY" FM_SSH_BIN="$LAB/bin/ssh" FM_FLEET_SEATS_TEST_BACKOFF=0 \
  "$BIN/fm-fleet-seats.sh" serve-remotes 2>&1)
src=$?
printf 'rc=%s\n%s\n' "$src" "$serve"
[ "$src" -eq 0 ] || { echo "SCENARIO FAILED: the serve pass failed"; exit 1; }
printf '%s\n' "$serve" | grep -q "served $ID" \
  || { echo "SCENARIO FAILED: the remote was not served"; exit 1; }

CERT=$PRIMARY/state/fleet-seats/remote-$ID.cert
step "published serve certificate $CERT"
jq -c '{epoch, complete, holders}' "$CERT"
[ "$(jq '.holders | length' "$CERT")" -eq 1 ] \
  || { echo "SCENARIO FAILED: the pre-pool supervisor was not reported exactly once"; exit 1; }
[ "$(jq -r '.holders[0].generation' "$CERT")" = "$GEN" ] \
  || { echo "SCENARIO FAILED: the certificate does not carry the host generation"; exit 1; }
[ "$(jq -r '.holders[0].model' "$CERT")" = "$MODEL" ] \
  || { echo "SCENARIO FAILED: the certificate does not carry the host model"; exit 1; }

step "a second seat on the same model is refused, with the one held seat named"
new_holder
full=$(seat reserve contender --generation g-contender --harness claude --model "$MODEL" --kind ship --holder-pid "$HOLDER" 2>&1)
frc=$?
printf 'rc=%s\n%s\n' "$frc" "$full"
kill "$HOLDER" 2>/dev/null || true
[ "$frc" -eq 4 ] || { echo "SCENARIO FAILED: a full pool did not refuse the second seat"; exit 1; }
printf '%s\n' "$full" | grep -q 'is full (1 of 1 seats held)' \
  || { echo "SCENARIO FAILED: the certificate holder and the primary route record were charged twice"; exit 1; }
printf '%s\n' "$full" | grep -q "$ID" \
  || { echo "SCENARIO FAILED: the refusal did not name the remote supervisor"; exit 1; }

say "S2b: a certificate-proved generation replaces the recorded one instead of tripping ledger history"

# A relaunch persists the host generation into the parent record before it
# reserves; the certificate is what issued that identity.
printf 'spawn_gen=%s\n' "$GEN" >> "$PRIMARY/state/$ID.meta"
step "parent record now names the certificate-proved generation $GEN; reserve its replacement on the full pool"
new_holder
rep=$(seat reserve "$ID" --generation g-replacement --previous-generation "$GEN" \
  --harness claude --model "$MODEL" --kind secondmate --holder-pid "$HOLDER" 2>&1)
rrc=$?
printf 'rc=%s\n%s\n' "$rrc" "$rep"
kill "$HOLDER" 2>/dev/null || true
[ "$rrc" -eq 0 ] || { echo "SCENARIO FAILED: the certificate-proved generation was not admitted as a replacement"; exit 1; }
printf '%s\n' "$rep" | grep -q 'used=1 capacity=1' \
  || { echo "SCENARIO FAILED: the replacement did not keep exactly one seat"; exit 1; }
seat release "$ID" --generation g-replacement --reason prelaunch >/dev/null 2>&1 || true

step "a generation no certificate proves is still refused as one the ledger never issued"
sed -i "s/^spawn_gen=.*/spawn_gen=host.gone/" "$PRIMARY/state/$ID.meta"
new_holder
conf=$(seat reserve "$ID" --generation g-conflict --previous-generation "$GEN" \
  --harness claude --model "$MODEL" --kind secondmate --holder-pid "$HOLDER" 2>&1)
crc=$?
printf 'rc=%s\n%s\n' "$crc" "$conf"
kill "$HOLDER" 2>/dev/null || true
[ "$crc" -eq 5 ] || { echo "SCENARIO FAILED: an unproved generation was not refused"; exit 1; }
printf '%s\n' "$conf" | grep -q 'never issued' \
  || { echo "SCENARIO FAILED: the refusal did not name ledger history"; exit 1; }

say "S2c: the same primary reached through a symlinked home alias keeps one identity"
sed -i "s/^spawn_gen=.*/spawn_gen=$GEN/" "$PRIMARY/state/$ID.meta"
ln -s "$PRIMARY" "$LAB/primary-alias"
alias_seat() {
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
    -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    FM_HOME="$LAB/primary-alias" PATH="$LAB/bin:$PATH" \
    "$BIN/fm-fleet-seats.sh" "$@"
}
step "FM_HOME=$LAB/primary-alias (symlink) reserve + show + reconcile-remote"
new_holder
alias_out=$(alias_seat reserve alias-probe --generation g-alias --harness claude --model "$MODEL" \
  --kind ship --holder-pid "$HOLDER" 2>&1)
arc=$?
printf 'reserve rc=%s\n%s\n' "$arc" "$alias_out"
kill "$HOLDER" 2>/dev/null || true
[ "$arc" -eq 4 ] || { echo "SCENARIO FAILED: the aliased home did not see the same full pool"; exit 1; }
printf '%s\n' "$alias_out" | grep -q 'is full (1 of 1 seats held)' \
  || { echo "SCENARIO FAILED: the aliased home counted a different capacity"; exit 1; }
direct_show=$(seat show "$ID" 2>&1)
alias_show=$(alias_seat show "$ID" 2>&1)
[ "$direct_show" = "$alias_show" ] \
  || { echo "SCENARIO FAILED: the aliased home read a different holder record"; exit 1; }
printf 'show through the alias matches the direct read:\n%s\n' "$alias_show"
(umask 077; printf '{}\n' > "$LAB/empty-response.json")
rec=$(alias_seat reconcile-remote theshop --generation missing --response-file "$LAB/empty-response.json" 2>&1)
rrc2=$?
printf 'reconcile-remote rc=%s\n%s\n' "$rrc2" "$rec"
printf '%s\n' "$rec" | grep -q 'no seat is reserved' \
  || { echo "SCENARIO FAILED: the aliased owner state was rejected by the shared authority"; exit 1; }

say "PASS: the pre-pool supervisor counted exactly once from the serve certificate, a certificate-proved generation was admitted as a replacement, and an unproved one was refused"
