#!/usr/bin/env bash
# Live drive of bin/fm-lock.sh on a ps-denied host, in a disposable lab home.
#
# ps denial is simulated the way an EDR policy presents itself: a `ps` on PATH
# that prints "Operation not permitted" and exits 126 for EVERY call (including
# `ps -V`), which is exactly the shape bin/fm-session-lock-lib.sh requires
# before it routes identity off ps. Everything else is real: a real process
# tree, the real /proc provider, the real CLI.
set -u
WT=$1
LAB=$2
rc=0
say() { printf '%s\n' "$*"; }
pass() { say "PASS $*"; }
fail() { say "FAIL $*"; rc=1; }
check() {  # <label> <expected-substring> <actual>
  [ -n "$2" ] || { fail "$1 (driver bug: empty expectation)"; return; }
  case "$3" in
    *"$2"*) pass "$1" ;;
    *) fail "$1 (wanted '$2', got: $3)" ;;
  esac
}

# The harness: a copy of bash, so the launched process's kernel comm is the
# harness name and a real ancestry walk from the CLI reaches it.
mkdir -p "$LAB/bin" "$LAB/fakebin"
cp "$(command -v bash)" "$LAB/bin/claude"

# A denied ps: every invocation of the binary is refused.
printf '#!/usr/bin/env bash\necho "ps: Operation not permitted" >&2\nexit 126\n' > "$LAB/fakebin/ps"
chmod +x "$LAB/fakebin/ps"

STATE=$LAB/state
DENIED_PATH="$LAB/fakebin:$PATH"

# Run one command inside a live harness-named process, with ps denied.
harness() {  # <bin> <tag> <body>
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u CLAUDE_CONFIG_DIR \
      -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE \
      -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
      -u FM_PROJECTS_OVERRIDE \
      FM_HOME="$LAB" FM_LAB="$LAB" FM_WT="$WT" FM_TAG="$2" PATH="$DENIED_PATH" \
      "$1" --norc --noprofile -c "$3"
}

# A long-lived harness that acquires the lock, publishes its pid, stays alive.
OWN_PID=
own_lock_bg() {  # <bin> <tag>
  local bin=$1 tag=$2
  rm -f "$LAB/$tag.pid" "$LAB/$tag.ready" "$LAB/$tag.acquire"
  harness "$bin" "$tag" '
printf "%s" $$ > "$FM_LAB/$FM_TAG.pid"
cd "$FM_WT" || exit 9
bin/fm-lock.sh > "$FM_LAB/$FM_TAG.acquire" 2>&1
printf "acquire-rc=%s\n" "$?" >> "$FM_LAB/$FM_TAG.acquire"
: > "$FM_LAB/$FM_TAG.ready"
sleep 300
: ' &
  local i=0
  while [ ! -e "$LAB/$tag.ready" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
  OWN_PID=$(cat "$LAB/$tag.pid" 2>/dev/null)
  return 0
}

stop_pid() {  # <pid>
  [ -n "${1:-}" ] || return 0
  kill -TERM "$1" 2>/dev/null
  local i=0
  while kill -0 "$1" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  kill -KILL "$1" 2>/dev/null
  wait "$1" 2>/dev/null
  return 0
}

# Ask the library directly, in a plain shell, with ps denied.
lib_denied() {  # <pid> <expression>
  env -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID FM_HOME="$LAB" PATH="$DENIED_PATH" TARGET="$1" \
    bash -c '. "$1/bin/fm-session-lock-lib.sh"; eval "$2"' _ "$WT" "$2"
}
lib_allowed() {  # <pid> <expression>
  env -u CLAUDE_PID -u CLAUDE_CODE_SESSION_ID FM_HOME="$LAB" TARGET="$1" \
    bash -c '. "$1/bin/fm-session-lock-lib.sh"; eval "$2"' _ "$WT" "$2"
}

say "=== host: $(uname -s) $(uname -r); lab: $LAB"
say "=== denied ps probe:"
env PATH="$DENIED_PATH" ps -o comm= -p $$ >/dev/null 2>&1
say "    ps -o comm= -> rc=$?"
env PATH="$DENIED_PATH" ps -V >/dev/null 2>&1
say "    ps -V -> rc=$?"

# ---------------------------------------------------------------- scenario 1
say ""
say "=== S1: a primary acquires the session lock while ps is denied"
rm -f "$STATE/.lock" "$STATE/.lock-session" "$STATE/.lock.acquire"
s1=$(harness "$LAB/bin/claude" s1 '
printf "harness-pid=%s\n" $$
cd "$FM_WT" || exit 9
bin/fm-lock.sh; printf "cli-rc=%s\n" "$?"
printf "lock-line1=%s\n" "$(cat "$FM_HOME/state/.lock" 2>/dev/null)"
' 2>&1)
say "$s1"
p1=$(printf '%s\n' "$s1" | sed -n 's/^harness-pid=//p')
l1=$(printf '%s\n' "$s1" | sed -n 's/^lock-line1=//p')
check "S1 the CLI reported acquisition" "lock acquired: harness pid $p1" "$s1"
check "S1 the CLI exited 0" "cli-rc=0" "$s1"
[ -n "$p1" ] && [ "$l1" = "$p1" ] && pass "S1 state/.lock records the live harness pid $p1" \
  || fail "S1 state/.lock holds '$l1', expected $p1"
case "$s1" in
  *"cannot locate harness process"*) fail "S1 the walk still failed on the denied-ps host" ;;
  *) pass "S1 no ancestry failure on the denied-ps host" ;;
esac

# ------------------------------------------------------------- scenarios 2-4
say ""
say "=== S2/S3/S4: live foreign owner refused, dead owner reclaimable, status agrees"
rm -f "$STATE/.lock" "$STATE/.lock-session" "$STATE/.lock.acquire"
own_lock_bg "$LAB/bin/claude" owner
owner=$OWN_PID
say "    owner harness pid=$owner : $(tr '\n' ' ' < "$LAB/owner.acquire")"
s4live=$(harness "$LAB/bin/claude" status4 'cd "$FM_WT" && bin/fm-lock.sh status')
say "    S4 live status (denied ps): $s4live"
check "S4 a live harness holder reads held" "lock: held by live harness pid $owner" "$s4live"

s2=$(harness "$LAB/bin/claude" s2 '
cd "$FM_WT" || exit 9
bin/fm-lock.sh; printf "contender-rc=%s\n" "$?"
printf "lock-line1=%s\n" "$(cat "$FM_HOME/state/.lock" 2>/dev/null)"
' 2>&1)
say "$s2"
check "S2 the contender was refused, naming the live owner" "another live firstmate session holds the lock (pid $owner)" "$s2"
check "S2 the contender exited 1" "contender-rc=1" "$s2"
l2=$(printf '%s\n' "$s2" | sed -n 's/^lock-line1=//p')
[ "$l2" = "$owner" ] && pass "S2 the takeover attempt left the owner pid $owner in state/.lock" \
  || fail "S2 the lock changed to '$l2' while owner $owner was alive"

stop_pid "$owner"
say "    owner $owner stopped"
s4dead=$(harness "$LAB/bin/claude" status4b 'cd "$FM_WT" && bin/fm-lock.sh status')
say "    S4 dead status (denied ps): $s4dead"
check "S4 a dead holder reads stale (no permanent read-only wedge)" "lock: stale (pid $owner dead or not a harness)" "$s4dead"

s3=$(harness "$LAB/bin/claude" s3 '
printf "harness-pid=%s\n" $$
cd "$FM_WT" || exit 9
bin/fm-lock.sh; printf "cli-rc=%s\n" "$?"
printf "lock-line1=%s\n" "$(cat "$FM_HOME/state/.lock" 2>/dev/null)"
' 2>&1)
say "$s3"
p3=$(printf '%s\n' "$s3" | sed -n 's/^harness-pid=//p')
l3=$(printf '%s\n' "$s3" | sed -n 's/^lock-line1=//p')
check "S3 the stale lock was reclaimed by the new primary" "lock acquired: harness pid $p3" "$s3"
check "S3 the reclaiming CLI exited 0" "cli-rc=0" "$s3"
[ -n "$p3" ] && [ "$l3" = "$p3" ] && pass "S3 state/.lock was rewritten to the new harness pid $p3" \
  || fail "S3 state/.lock holds '$l3', expected $p3"

# ---------------------------------------------------------------- scenario 5
say ""
say "=== S5: a live Cursor owner behind a non-ASCII alias path still blocks reclaim"
CUR_DIR="$LAB/Users/José/.local/share/cursor-agent/versions/test"
CUR_ALIAS="$LAB/Users/José/.local/bin/agent"
mkdir -p "$CUR_DIR" "${CUR_ALIAS%/*}"
cp "$(command -v bash)" "$CUR_DIR/agent"
ln -sfn "$CUR_DIR/agent" "$CUR_ALIAS"
rm -f "$STATE/.lock" "$STATE/.lock-session" "$STATE/.lock.acquire"
own_lock_bg "$CUR_ALIAS" cursor
cur=$OWN_PID
say "    cursor alias harness pid=$cur : $(tr '\n' ' ' < "$LAB/cursor.acquire")"
say "    alias path: $CUR_ALIAS"
say "    kernel comm: $(cat "/proc/$cur/comm" 2>/dev/null)"

ps_comm=$(ps -o comm= -p "$cur")
ps_args=$(ps -o args= -p "$cur")
prov=$(lib_denied "$cur" 'fm_os_proc_triple "$TARGET"')
prov_comm=${prov#*$'\t'}; prov_comm=${prov_comm%%$'\t'*}
prov_rest=${prov#*$'\t'}; prov_args=${prov_rest#*$'\t'}
say "    ps route   : comm=[$ps_comm] args=[$ps_args]"
say "    /proc route: comm=[$prov_comm] args=[$prov_args]"
[ -n "$prov_comm" ] && [ "$prov_comm" = "$ps_comm" ] && pass "S5 comm is identical across the ps and /proc routes" \
  || fail "S5 comm differs: ps=[$ps_comm] proc=[$prov_comm]"
[ -n "$prov_args" ] && [ "$prov_args" = "$ps_args" ] && pass "S5 args are identical across the ps and /proc routes" \
  || fail "S5 args differ: ps=[$ps_args] proc=[$prov_args]"
case "$prov_args" in
  *"José"*) pass "S5 the /proc route preserved the UTF-8 bytes of the alias path" ;;
  *) fail "S5 the /proc route lost the UTF-8 bytes: [$prov_args]" ;;
esac

v_ps=$(lib_allowed "$cur" 'fm_harness_pid_alive "$TARGET" && echo alive')
v_denied=$(lib_denied "$cur" 'fm_harness_pid_alive "$TARGET" && echo alive')
say "    harness verdict with ps available: [${v_ps:-not-a-harness}]"
say "    harness verdict with ps denied   : [${v_denied:-not-a-harness}]"

s5=$(harness "$LAB/bin/claude" s5 '
cd "$FM_WT" || exit 9
bin/fm-lock.sh; printf "contender-rc=%s\n" "$?"
printf "lock-line1=%s\n" "$(cat "$FM_HOME/state/.lock" 2>/dev/null)"
' 2>&1)
say "$s5"
check "S5 the contender was refused, naming the live Cursor owner" "another live firstmate session holds the lock (pid $cur)" "$s5"
l5=$(printf '%s\n' "$s5" | sed -n 's/^lock-line1=//p')
[ "$l5" = "$cur" ] && pass "S5 state/.lock still records the Cursor owner pid $cur" \
  || fail "S5 the lock changed to '$l5' while the Cursor owner $cur was alive"

stop_pid "$cur"
say ""
say "=== RESULT rc=$rc"
exit "$rc"
