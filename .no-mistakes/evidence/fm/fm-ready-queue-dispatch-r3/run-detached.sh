#!/usr/bin/env bash
# Evidence helper: run a command in a double-forked, setsid'd child so the
# caller-of-record ancestry is the system init rather than the invoking harness.
# Used to give the tagged-session ownership case the clean caller ancestry it
# requires without a transient unit, host service, or harness-detector change.
set -u
log=$1; shift
rm -f "$log" "$log.rc"
( setsid bash -c '
  log=$1; shift
  "$@" >>"$log" 2>&1
  printf "%s\n" "$?" > "$log.rc"
' _ "$log" "$@" & )
for _ in $(seq 1 3600); do
  [ -s "$log.rc" ] && break
  sleep 0.5
done
if [ ! -s "$log.rc" ]; then
  echo "run-detached: timed out waiting for $log" >&2
  exit 124
fi
rc=$(cat "$log.rc")
echo "run-detached: exit=$rc log=$log"
exit "$rc"
