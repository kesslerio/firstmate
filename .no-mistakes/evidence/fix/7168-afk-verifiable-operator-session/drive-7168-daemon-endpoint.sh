#!/usr/bin/env bash
# drive-7168-daemon-endpoint.sh - live proof that the daemon's own startup
# endpoint check - the one docs/configuration.md says the launcher now mirrors -
# rejects an unresolvable supervisor target, and that both entry paths use it.
# Run inside the disposable lab tmux pane (Claude harness marker), from the
# run worktree, with FM_REPO_ROOT set.
set -u
ROOT=${FM_REPO_ROOT:?set FM_REPO_ROOT to the run worktree}
cd "$ROOT" || exit 1
H=$(mktemp -d "${TMPDIR:-/tmp}/fm-7168-daemon.XXXXXX")
bin/fm-lab-home.sh create "$H" >/dev/null || exit 1
: > "$H/config/supervision-host-off"
echo "home=$H"

echo "=== daemon startup: FM_SUPERVISOR_TARGET=no-such-session:0 backend=tmux"
OUT=$(env -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION \
  -u REX_SESSION -u REX_BLOCK -u ORCA_TERMINAL_HANDLE \
  FM_HOME="$H" FM_STATE_OVERRIDE="$H/state" \
  FM_SUPERVISOR_TARGET=no-such-session:0 FM_SUPERVISOR_BACKEND=tmux \
  bin/fm-afk-start.sh 2>&1); RC=$?
printf '%s\n' "rc=$RC" "$OUT"
echo "--- daemon log:"; tail -3 "$H/state/.supervise-daemon.log" 2>&1

if [ "$RC" -ne 0 ] \
  && printf '%s' "$OUT" | grep -F "supervisor target 'no-such-session:0' does not resolve to a tmux pane" >/dev/null \
  && grep -F "startup failed: target 'no-such-session:0' not found (backend=tmux)" \
       "$H/state/.supervise-daemon.log" >/dev/null 2>&1; then
  echo "PASS: daemon startup refuses an unresolvable supervisor target (the check the launcher now mirrors)"
else
  echo "FAIL: daemon startup did not refuse the unresolvable target (rc=$RC)"
fi
echo "cleanup-home=$H"
