#!/usr/bin/env bash
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-instruction-protocol)
export HOME="$TMP_ROOT/user" FM_HOME="$TMP_ROOT/home"
export FM_STATE_OVERRIDE="$FM_HOME/state" FM_DATA_OVERRIDE="$FM_HOME/data" FM_CONFIG_OVERRIDE="$FM_HOME/config"
export FM_ROOT_OVERRIDE="$ROOT" FM_TASK_INBOX_OBLIGATION_GRACE_SECS=0
mkdir -p "$HOME" "$FM_STATE_OVERRIDE" "$FM_DATA_OVERRIDE" "$FM_CONFIG_OVERRIDE" "$TMP_ROOT/tools"
printf tmux > "$FM_CONFIG_OVERRIDE/backend"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP_ROOT/tools/tmux"
chmod +x "$TMP_ROOT/tools/tmux"
export PATH="$TMP_ROOT/tools:$PATH"
printf 'id=owned\nkind=secondmate\nspawn_gen=g1\nbackend=tmux\nwindow=test:owned\n' > "$FM_STATE_OVERRIDE/owned.meta"
record=$(bash -c '. "$1"; fm_task_inbox_write "$2" owned "Run the bounded requested action" "" disposition' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$FM_STATE_OVERRIDE")
mv "$record" "$FM_STATE_OVERRIDE/owned.inbox/handled/"
"$ROOT/bin/fm-task-inbox.sh" tick owned >/dev/null
"$ROOT/bin/fm-task-inbox.sh" tick owned >/dev/null
. "$ROOT/bin/fm-timeout-lib.sh"
out=$(fm_run_timed 10 "$ROOT/bin/fm-watch.sh") || fail 'watcher did not publish the exhausted instruction obligation'
case "$out" in 'check: instruction execution unaccounted:'*) ;; *) fail "instruction wake lost its public framing: $out" ;; esac
"$ROOT/bin/fm-task-inbox.sh" tick owned >/dev/null
[ "$(grep -c 'instruction execution unaccounted' "$FM_STATE_OVERRIDE/.wake-queue")" = 1 ] || fail 'alert framing lost durable keyed deduplication'
python3 - "$FM_STATE_OVERRIDE/.wake-queue" <<'PYROW'
import pathlib,sys
rows=[line.split('\t',4) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
assert any(row[2]=='stale' and row[3]=='owned' and row[4].startswith('check: instruction execution unaccounted:') for row in rows)
PYROW
printf '%s\n' "$out"
