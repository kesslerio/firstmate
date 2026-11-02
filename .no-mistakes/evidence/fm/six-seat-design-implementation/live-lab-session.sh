#!/usr/bin/env bash
# Live driver: a remote secondmate recorded under an isolated fm-lab-* Herdr
# session resolves its predecessor and relaunches on that same session, and a
# launch that finds a supervisor already running on another model is still
# recognised by the receipt that observed it.
#
# Everything below is the real product: bin/fm-herdr-lab.sh's isolated session,
# bin/fm-home-seed.sh's secondmate home, a real Claude Code agent launched by
# bin/fm-remote-secondmate-control.sh, the real bin/fm-fleet-seats.sh serve and
# reconcile verbs, and the real relaunch wrapper. Only ssh itself is replaced by
# a local-exec shim so the "remote host" is a disposable home on this machine.
set -u
ROOT=/home/art/.no-mistakes/worktrees/9f75ec418609/01M6DDN8CWC4PFXJKN77TZ98SJ
export FM_HERDR_LAB_STATE_DIR=/home/art/.no-mistakes/evidence/01M6DDN8CWC4PFXJKN77TZ98SJ/herdr-lab-state
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || exit 1
P="$LAB/primary"; R="$LAB/remote"; JOBS="$LAB/jobs"; HOST=lab-host
S=; PRE6=
teardown_everything() {
  local home pid
  [ -z "$S" ] || "$ROOT/bin/fm-herdr-lab.sh" teardown "$S" >/dev/null 2>&1 || true
  for home in "$P" "$R"; do
    for pid in "$home/state/.watch.lock/pid" "$home/state/.supervision-host"; do
      [ -f "$pid" ] || continue
      awk -F '\t' '$1 == "host" { print $2 }' "$pid" 2>/dev/null | while read -r p; do
        [ -z "$p" ] || kill -TERM "$p" 2>/dev/null || true
      done
      head -n 1 "$pid" 2>/dev/null | tr -cd '0-9' | while read -r p; do
        [ -z "$p" ] || kill -TERM "$p" 2>/dev/null || true
      done
    done
  done
  chmod -R u+w "$LAB" 2>/dev/null || true
  rm -rf "$LAB"
}
trap teardown_everything EXIT
holder() { sleep 600 >/dev/null 2>&1 & echo $!; }
seats() { env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$P" "$ROOT/bin/fm-fleet-seats.sh" "$@"; }
serve() {
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$P" FM_SSH_BIN="$LAB/bin/ssh" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux \
    FM_REMOTE_JOB_STATE_ROOT="$JOBS" FM_FLEET_SEATS_TEST_BACKOFF=0 \
    "$ROOT/bin/fm-fleet-seats.sh" serve-remotes
}
host_call() {  # <fm-command> <args...>
  env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$P" FM_SSH_BIN="$LAB/bin/ssh" \
    FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_STATE_ROOT="$JOBS" \
    "$ROOT/bin/fm-on.sh" mate1 "$@"
}
hostgen() { sed -n 's/^spawn_gen=//p' "$R/state/parent-route/mate1.meta"; }
pane_status() { "$ROOT/bin/fm-herdr-lab.sh" run "$S" pane get "$1" 2>/dev/null | jq -r '.result.pane.agent_status // "absent"'; }
wait_classified() {  # <pane> <polls of 2s>
  local pane=$1 i=0 state
  while [ "$i" -lt "${2:-60}" ]; do
    state=$(pane_status "$pane")
    case "$state" in unknown|absent|'') ;; *) printf '%s' "$state"; return 0 ;; esac
    sleep 2
    i=$((i + 1))
  done
  printf '%s' "$(pane_status "$pane")"
  return 1
}

echo "== lab: $LAB"

# --- disposable isolated session + a real seeded remote secondmate home -------
S=$("$ROOT/bin/fm-herdr-lab.sh" name live-session) || exit 1
"$ROOT/bin/fm-herdr-lab.sh" provision "$S" || exit 1
"$ROOT/bin/fm-lab-home.sh" create "$P" >/dev/null || exit 1
( cd "$ROOT" && FM_SECONDMATE_SCOPE='live validation' \
  FM_SECONDMATE_CHARTER='# Live remote mate
## Routing scope
live validation' \
  env -u FM_STATE_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
  FM_HOME="$P" "$ROOT/bin/fm-home-seed.sh" mate1 "$R" --no-projects >/dev/null ) || exit 1
"$ROOT/bin/fm-claude-trust.sh" --secondmate-home "$R" mate1 || exit 1
printf -- '- mate1 - live remote mate. (host: %s; root: %s; home: %s; scope: live validation; projects: ; added 2026-11-01)\n' \
  "$HOST" "$ROOT" "$R" > "$P/data/secondmates.md"
printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=%s\n' "$HOST" > "$R/.fm-secondmate-parent"
mkdir -p "$LAB/bin" "$JOBS"
cat > "$LAB/bin/ssh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$LAB/ssh.log"
while [ "\$#" -gt 0 ]; do case "\$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac; done
[ "\${1:-}" = $HOST ] || exit 91
[ "\${2:-}" = fm-remote-entrypoint.sh ] || exit 92
shift 2
exec "$ROOT/bin/fm-remote-entrypoint.sh" "\$@"
SH
chmod +x "$LAB/bin/ssh"

# --- a real agent in the lab session (the host-side launch) -------------------
echo "== setup: real host-side launch of mate1 into the lab session"
( cd "$R" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_STATE_OVERRIDE \
    -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE \
    FM_HOME="$R" HERDR_SESSION="$S" "$ROOT/bin/fm-remote-secondmate-control.sh" \
    launch mate1 claude haiku - herdr --herdr-session "$S" ) > "$LAB/launch.out" 2>&1 \
  || { echo "host launch FAILED"; tail -20 "$LAB/launch.out"; exit 1; }
sed -n 's/^/  /p' "$LAB/launch.out" | tail -8
TARGET=$(sed -n 's/^target=//p' "$LAB/launch.out" | tail -1)
GEN0=$(hostgen)
PANE=${TARGET#*:}
echo "  endpoint=$TARGET generation=$GEN0 pane-status=$(wait_classified "$PANE")"
{
  printf 'kind=secondmate\nroute=remote\nremote_host=%s\nremote_root=%s\n' "$HOST" "$ROOT"
  printf 'remote_backend=herdr\nremote_herdr_session=%s\n' "$S"
  printf 'remote_spawn_gen=%s\nremote_target=%s\n' "$GEN0" "$TARGET"
  printf 'home=%s\nworktree=%s\nproject=%s\nharness=claude\nmodel=haiku\neffort=default\n' "$R" "$R" "$R"
} > "$P/state/mate1.meta"

# --- scenario: the lab-session predecessor resolves and relaunches in place --
echo
echo "== 6a: negative control - the wrapper before the lab-session route fix"
PRE6="$LAB/pre6"; mkdir -p "$PRE6"
git -C "$ROOT" archive f0e88a52 | tar -x -C "$PRE6" || exit 1
chmod +x "$PRE6/bin/"*.sh
git -C "$PRE6" init -q -b main && git -C "$PRE6" add -A >/dev/null 2>&1 \
  && git -C "$PRE6" -c user.name=fmtest -c user.email=fmtest@example.invalid commit -qm pre || exit 1
cp -p "$P/state/mate1.meta" "$LAB/meta.before"
( cd "$LAB" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_STATE_OVERRIDE \
    -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$P" \
    FM_SSH_BIN="$LAB/bin/ssh" FM_REMOTE_JOB_STATE_ROOT="$JOBS" \
    FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$PRE6/bin/fm-remote-secondmate-relaunch.sh" \
    mate1 claude sonnet - ) 2>&1 | grep -v '^●' | sed -n '1,6p'
echo "  pre-fix record unchanged: $(cmp -s "$LAB/meta.before" "$P/state/mate1.meta" && echo yes || echo NO)"

echo
echo "== 6b: this change's wrapper relaunches mate1 on its recorded lab session"
relaunch_once() {
  ( cd "$LAB" && env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_STATE_OVERRIDE \
      -u FM_CONFIG_OVERRIDE -u FM_DATA_OVERRIDE -u FM_ROOT_OVERRIDE FM_HOME="$P" \
      FM_SSH_BIN="$LAB/bin/ssh" FM_REMOTE_JOB_STATE_ROOT="$JOBS" \
      FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux "$ROOT/bin/fm-remote-secondmate-relaunch.sh" \
      mate1 claude sonnet - ) > "$LAB/relaunch.out" 2>&1
}
relaunch_once
if grep -q 'exit command could not be sent' "$LAB/relaunch.out"; then
  # The stand-in host has no attached Herdr client, so this TUI's composer
  # submit is not observable there. An operator closes the old agent from its
  # own pane, exactly as the product's exit verb would have.
  echo "  (operator step: closing the old agent from its pane)"
  "$ROOT/bin/fm-herdr-lab.sh" run "$S" pane send-text "$PANE" '/exit' >/dev/null 2>&1 || true
  "$ROOT/bin/fm-herdr-lab.sh" run "$S" pane send-keys "$PANE" Enter >/dev/null 2>&1 || true
  sleep 3
  relaunch_once
fi
grep -v '^●' "$LAB/relaunch.out" | sed -n '1,12p' | sed 's/^/  /'
echo "  parent record now: harness=$(sed -n 's/^harness=//p' "$P/state/mate1.meta") model=$(sed -n 's/^model=//p' "$P/state/mate1.meta") generation=$(sed -n 's/^remote_spawn_gen=//p' "$P/state/mate1.meta") session=$(sed -n 's/^remote_herdr_session=//p' "$P/state/mate1.meta")"
echo "  endpoint after relaunch: target=$(sed -n 's/^remote_target=//p' "$P/state/mate1.meta") pane-status=$(wait_classified "$PANE")"
echo "  host calls this relaunch made (decoded argv):"
grep -oE '[A-Za-z0-9_-]+@?[A-Za-z0-9+/=]*$' "$LAB/ssh.log" | tail -2 | while read -r blob; do
  printf '    %s\n' "$(printf '%s' "$blob" | base64 -d 2>/dev/null | tr '\0' ' ')"
done

# --- scenario: an already-running supervisor on another model ---------------
echo
echo "== 3a: enable pools and let the real serve pass certify the fleet"
cat > "$P/config/fleet-seats" <<'JSON'
{"pools":[{"name":"shared","capacity":2,"models":["haiku","sonnet"]}]}
JSON
serve | sed 's/^/  /'
jq -c '{epoch, holders}' "$P/state/fleet-seats/remote-mate1.cert" | sed 's/^/  /'
RUNNING_MODEL=$(sed -n 's/^model=//p' "$R/state/parent-route/mate1.meta")
RUNNING_GEN=$(hostgen)
echo "== 3b: a pooled launch asks for a DIFFERENT model than the one running ($RUNNING_MODEL)"
OP="s$(date +%s).$$.1"
(
  cd "$LAB"
  seats reserve mate1 --generation "$OP" --previous-generation "$RUNNING_GEN" \
    --harness claude --model haiku --kind secondmate --holder-pid $$
  RF=$(umask 077; mktemp "$LAB/route.XXXXXX")
  jq -cn --arg host "$HOST" --arg root "$ROOT" --arg home "$R" --arg op "$OP" \
    '{placement: "remote", backend: "herdr", target: null, home: $home, host: $host,
      remote_root: $root, spawn_gen: null, operation: $op}' > "$RF"
  seats dispatch mate1 --generation "$OP" --route-file "$RF"
) 2>&1 | sed 's/^/  /'
host_call fm-remote-secondmate-control.sh launch mate1 claude haiku - herdr \
  --operation "$OP" --previous "$RUNNING_GEN" --herdr-session "$S" > "$LAB/op-launch.out" 2>&1
echo "  host launch rc=$? pane-status=$(pane_status "$PANE")"
grep -v '^●' "$LAB/op-launch.out" | sed -n '1,12p' | sed 's/^/  host: /' 
sed -n 's/^seat_disposition=//p' "$LAB/op-launch.out" | tail -1 | jq -c \
  '{disposition, requested_generation, actual_generation, actual_model, startup_confirmed}' | sed 's/^/  receipt: /'
RESP=$(umask 077; mktemp "$LAB/response.XXXXXX")
sed -n 's/^seat_disposition=//p' "$LAB/op-launch.out" | tail -1 > "$RESP"
echo "== 3c: the parent applies the receipt the host observed"
seats reconcile-remote mate1 --generation "$OP" --response-file "$RESP" 2>&1 | sed 's/^/  /'
echo "  reconcile rc=$?"
seats show mate1 | jq -c '.incarnations[] | {generation, lifecycle, model, startup_confirmed, target: .route.target}' | sed 's/^/  ledger: /'
echo "== 3d: the pool now holds one seat for the running supervisor, not a phantom"
H=$(holder)
seats reserve other --generation "s$(date +%s).$$.2" --harness claude --model sonnet --holder-pid "$H" 2>&1 | sed 's/^/  /'
echo "== done"
