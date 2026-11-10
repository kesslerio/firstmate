#!/usr/bin/env bash
# Disposable lab primary launcher: adopts the session lock as the running pi pid
# (what bin/fm-lock.sh records for a session started through the harness) and
# execs the real pi CLI so the tracked primary extensions load.
set -u
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
exec pi -a -nc --no-session
