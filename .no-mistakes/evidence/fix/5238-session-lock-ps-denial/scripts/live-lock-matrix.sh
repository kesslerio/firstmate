#!/usr/bin/env bash
# live-lock-matrix.sh <tree> <label>
# Drives the REAL session-lock product from harness-shaped sessions under a
# genuine ps exec denial (the caller binds /dev/null over the ps binary inside
# `unshare -r -m`):
#   S1 a live session acquires and holds its lock
#   S2 a second live session is refused and the owner's record is untouched
#   S3 after the owner exits, the next session reclaims the stale record
# Everything it writes stays in a disposable lab home under $SCRATCH.
set -u
TREE=$1
LABEL=$2
SCRATCH=${3:?scratch dir}
LAB=$SCRATCH/lab
CLAUDE_BIN=$SCRATCH/bin/claude
LOCK="$LAB/state/.lock"

CLI=("$CLAUDE_BIN")
# Sessions inherit this environment: no gate overrides, the disposable lab home.
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE \
  FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE CLAUDE_PID CLAUDE_CODE_SESSION_ID
export FM_HOME="$LAB"

write_session_script() { # <path>
  cat > "$1" <<SH
#!/usr/bin/env bash
set -u
cd "$TREE" || exit 9
out=\$("$TREE/bin/fm-lock.sh" 2>&1); rc=\$?
echo "acquire rc=\$rc out=[\$out]"
echo "lock=[\$(cat "$LOCK" 2>/dev/null)]"
echo "status=[\$("$TREE/bin/fm-lock.sh" status 2>&1)]"
SH
  chmod +x "$1"
}

run_session() { # <script> ; foreground, one harness-shaped session
  "${CLI[@]}" -c "bash '$1'; :" 2>&1
}

echo "### label=$LABEL tree=$(basename "$TREE")"
ps -V >/dev/null 2>&1
echo "  ps -V rc=$?  (126 == exec refused by the OS)"
ps -o comm= -p 1 >/dev/null 2>&1
echo "  ps -o comm= rc=$?"

write_session_script "$SCRATCH/a.sh"
write_session_script "$SCRATCH/b.sh"
write_session_script "$SCRATCH/c.sh"

echo "### S1: session A (real harness-shaped process) acquires on the denied-ps host"
"${CLI[@]}" -c "bash '$SCRATCH/a.sh'; echo \$\$ > '$SCRATCH/a.pid'; sleep 240; :" > "$SCRATCH/a.out" 2>&1 &
i=0
while [ "$i" -lt 200 ] && ! grep -q 'acquire rc=' "$SCRATCH/a.out" 2>/dev/null; do sleep 0.05; i=$((i + 1)); done
wait_for_pid=0
while [ "$wait_for_pid" -lt 100 ] && [ ! -s "$SCRATCH/a.pid" ]; do sleep 0.05; wait_for_pid=$((wait_for_pid + 1)); done
A=$(tr -d '[:space:]' < "$SCRATCH/a.pid" 2>/dev/null)
sed 's/^/    /' "$SCRATCH/a.out"
echo "    session A anchor pid=$A  alive=$(kill -0 "$A" 2>/dev/null && echo yes || echo no)"

echo "### S2: session B, a second live harness, tries the same home"
run_session "$SCRATCH/b.sh" > "$SCRATCH/b.out" 2>&1
sed 's/^/    /' "$SCRATCH/b.out"
echo "    lock after B=[$(cat "$LOCK" 2>/dev/null)] (must still be A=$A)"
echo "    A alive after B: $(kill -0 "$A" 2>/dev/null && echo yes || echo no)"

echo "### S3: the owner exits; its stale record stays; the next session reclaims"
kill "$A" 2>/dev/null
i=0
while [ "$i" -lt 200 ] && kill -0 "$A" 2>/dev/null; do sleep 0.05; i=$((i + 1)); done
kill -0 "$A" 2>/dev/null && echo "    owner still alive (UNEXPECTED)" || echo "    owner gone: yes"
echo "    stale record=[$(cat "$LOCK" 2>/dev/null)]"
run_session "$SCRATCH/c.sh" > "$SCRATCH/c.out" 2>&1
sed 's/^/    /' "$SCRATCH/c.out"

echo "### teardown"
kill "$A" 2>/dev/null
echo "DONE"
