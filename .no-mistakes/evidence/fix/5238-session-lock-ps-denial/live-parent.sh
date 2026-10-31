#!/usr/bin/env bash
# Parent fixture for live-session-lock-driver.sh.
#
# Executed as a process NAMED claude (a symlink to /bin/bash called "claude"),
# so the denied-ps ancestry walk finds a real harness-shaped ancestor. It stays
# alive while the child runs, records its own pid, and then waits for the child.
set -u
pidfile=$1; shift
printf '%s\n' "$$" > "$pidfile"
"$@"
rc=$?
exit "$rc"
