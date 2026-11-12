#!/usr/bin/env bash
# Pre-fix reproduction for fix/watcher-beacon-progress: the same long-check-cycle
# fixture the fixed tree passes, driven against a base-commit export (47df77f).
# Shows the historical false watcher-down while the watcher is genuinely working.
# Usage: reproduce-base-false-alarm.sh <base-export-root>
set -u
ROOT=$(cd "$1" && pwd) || exit 1
export FM_GATE_REFUSE_BYPASS=1
unset NO_MISTAKES_GATE
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-base-repro.XXXXXX") || exit 1
W=
cleanup() { [ -z "$W" ] || kill -TERM "$W" 2>/dev/null || true; rm -rf "$WORK"; }
trap cleanup EXIT

d="$WORK/case"; home=$d/home; beat=$home/state/.last-watcher-beat
mkdir -p "$home/state" "$home/config" "$home/data" "$d/root/bin"
: > "$d/root/AGENTS.md"; git -C "$d/root" init -q
printf 'kind=ship\n' > "$home/state/task.meta"
i=1
while [ "$i" -le 5 ]; do
  printf '#!/usr/bin/env bash\nsleep 2\nexit 0\n' > "$home/state/slow-$i.check.sh"
  chmod 0700 "$home/state/slow-$i.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" "slow-$i" >/dev/null
  i=$((i + 1))
done
FM_HOME="$home" FM_GUARD_GRACE=4 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=1 \
  FM_CHECK_TIMEOUT=30 FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" > "$d/watch.out" 2>&1 &
W=$!
i=0
while [ "$i" -lt 150 ]; do
  [ "$(cat "$home/state/.watch.lock/pid" 2>/dev/null || true)" = "$W" ] && [ -e "$beat" ] && break
  sleep 0.1; i=$((i + 1))
done
printf 'base-commit watcher pid %s holds the lock; sampling beacon age for 12s with a 4s grace\n' "$W"
maxage=0
i=0
while [ "$i" -lt 60 ]; do
  now=$(date +%s); m=$(stat -c %Y "$beat" 2>/dev/null || printf 0)
  a=$((now - m)); [ "$a" -le "$maxage" ] || maxage=$a
  sleep 0.2; i=$((i + 1))
done
printf 'base: max beacon age while the watcher worked: %ss (grace 4s)\n' "$maxage"
out=''
i=0
while [ "$i" -lt 40 ]; do
  now=$(date +%s); a=$(( now - $(stat -c %Y "$beat" 2>/dev/null || printf 0) ))
  if [ "$a" -ge 6 ]; then
    out=$(env -u FM_POLL -u FM_GUARD_GRACE FM_ROOT_OVERRIDE="$d/root" FM_HOME="$home" \
      FM_GUARD_GRACE=4 FM_SUPERVISION_MODEL=persistent "$ROOT/bin/fm-guard.sh" 2>&1)
    printf 'base: pull guard ran with beacon age %ss of a 4s grace:\n%s\n' "$a" "${out:-<silent>}"
    break
  fi
  sleep 0.5; i=$((i + 1))
done
printf 'base: arm during the working cycle:\n'
env FM_HOME="$home" FM_GUARD_GRACE=4 FM_ARM_ATTACH_POLL=0.1 FM_ARM_CONFIRM_TIMEOUT=5 \
  "$ROOT/bin/fm-watch-arm.sh" 2>&1 | sed -n 1,3p
kill -TERM "$W" 2>/dev/null || true
W=
if [ -e "$home/state/.watch.lock/pid" ]; then
  kill -TERM "$(cat "$home/state/.watch.lock/pid" 2>/dev/null || true)" 2>/dev/null || true
fi
