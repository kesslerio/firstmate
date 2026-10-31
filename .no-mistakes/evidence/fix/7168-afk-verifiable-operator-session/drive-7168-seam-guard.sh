#!/usr/bin/env bash
# S11 adversarial: the endpoint-probe test seam must not be usable from a real
# operator session. FM_AFK_LAUNCH_TARGET_PROBE is honoured only with
# FM_TEST_SEAM=1, so a stray probe override must not let an unresolvable
# supervisor target arm away mode.
set -u
ROOT=${FM_REPO_ROOT:?}
cd "$ROOT" || exit 1
H=$(mktemp -d "${TMPDIR:-/tmp}/fm-7168-seam.XXXXXX") || exit 1
bin/fm-lab-home.sh create "$H" >/dev/null || exit 1
: > "$H/config/supervision-host-off"
FM_HOME="$H" bin/fm-afk-launch.sh enter --words 'seam guard' >/dev/null 2>&1
PROBE=$(command -v true)
echo "probe=$PROBE FM_TEST_SEAM=${FM_TEST_SEAM:-<unset>}"
OUT=$(env -u FM_TEST_SEAM -u FM_TEST_HARNESS -u FM_SUPERVISOR_TARGET -u FM_SUPERVISOR_BACKEND \
  FM_HOME="$H" FM_AFK_LAUNCH_TARGET_PROBE="$PROBE" \
  FM_SUPERVISOR_TARGET=no-such-session:0 FM_SUPERVISOR_BACKEND=tmux \
  bin/fm-afk-launch.sh start-native 2>&1); RC=$?
printf 'rc=%s\n%s\n' "$RC" "$OUT"
if [ "$RC" -ne 0 ] && [ ! -e "$H/state/.afk" ] \
  && printf '%s' "$OUT" | grep -F "does not resolve to a tmux endpoint" >/dev/null; then
  echo "PASS: a stray FM_AFK_LAUNCH_TARGET_PROBE without FM_TEST_SEAM=1 cannot bypass the real endpoint check"
  rm -rf "$H"; exit 0
fi
echo "FAIL: the probe override bypassed the endpoint check outside the seam (rc=$RC)"
rm -rf "$H"; exit 1
