#!/usr/bin/env bash
# Live validation driver for fix/5238-session-lock-ps-denial.
#
# It stands the real product up in a disposable lab home (bin/fm-lab-home.sh)
# and drives bin/fm-lock.sh and bin/fm-inbox.sh inside a REAL process tree whose
# parent is a process NAMED claude, once with a ps binary that cannot execute
# (PATH shim exiting 126, the status bash uses for a refused exec - the host
# behavior this change exists for) and once with the real ps as the baseline.
#
# Every assertion is on product-observable output: the lock file the product
# writes, the verdict it prints, the JSON it emits, and whether a live owner's
# lock was replaced. The shim simulates the hostile environment, never the
# product. Linux-only by design: the ps-free route it exercises is the /proc
# route (the Darwin sysctl helper needs a macOS host).
set -u

ROOT=${ROOT:-$(pwd)}
EV=${EV:-$(cd "$(dirname "$0")" && pwd)}
FAILS=0
PASSES=0
pass() { PASSES=$((PASSES + 1)); printf 'PASS - %s\n' "$*"; }
fail() { FAILS=$((FAILS + 1)); printf 'FAIL - %s\n' "$*"; }
say() { printf '\n===== %s =====\n' "$*"; }
field() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1; }

[ "$(uname -s)" = Linux ] || { echo "this driver is Linux-only (the ps-free route under test is /proc)"; exit 2; }
[ -x "$ROOT/bin/fm-lock.sh" ] || { echo "missing $ROOT/bin/fm-lock.sh"; exit 2; }

LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || exit 1
"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { rm -rf "$LAB"; exit 1; }
TREE=$(mktemp -d "${TMPDIR:-/tmp}/fm-tree.XXXXXX") || exit 1
PIDS=()
cleanup() {
  local p
  for p in ${PIDS[@]+"${PIDS[@]}"}; do kill "$p" 2>/dev/null || true; done
  rm -rf "$LAB" "$TREE"
}
trap cleanup EXIT

mkdir -p "$TREE/bin" "$TREE/denied" "$TREE/real"
# A process NAMED claude: the kernel reports the basename of the executed path,
# so a bash symlink called claude is a real claude-shaped ancestor.
ln -s /bin/bash "$TREE/bin/claude"
cat > "$TREE/denied/ps" <<'SH'
#!/usr/bin/env bash
echo "ps: Operation not permitted" >&2
exit 126
SH
chmod +x "$TREE/denied/ps"
mkdir -p "$TREE/ownerdenied" "$TREE/emptyproc"
REAL_PS=$(command -v ps)
cat > "$TREE/ownerdenied/ps" <<SH
#!/usr/bin/env bash
# Real ps for every process except the live owner under test, whose identity is
# made unreadable the way a policy denial makes it unreadable: ps refuses that
# pid and refuses the -V denial probe, so the product's own confirmation takes
# it to the ps-free route (whose /proc root here is empty).
case " \$* " in
  *" -V "*|*" -p \$OWNER "*) echo "ps: Operation not permitted" >&2; exit 126 ;;
esac
exec "$REAL_PS" "\$@"
SH
chmod +x "$TREE/ownerdenied/ps"
cp "$EV/live-parent.sh" "$TREE/parent.sh"
cp "$EV/live-child.sh" "$TREE/child.sh"
chmod +x "$TREE/parent.sh" "$TREE/child.sh"

scrub() {
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u FM_ROOT_OVERRIDE \
    -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
    -u FM_PROJECTS_OVERRIDE -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS "$@"
}

run_tree() {  # <denied|real> <scenario> [extra env assignments...]
  local route=$1 scen=$2 path
  shift 2
  case $route in
    denied) path="$TREE/denied:$PATH" ;;
    ownerdenied) path="$TREE/ownerdenied:$PATH" ;;
    *) path="$TREE/real:$PATH" ;;
  esac
  rm -f "$TREE/parent.pid"
  scrub FM_HOME="$LAB" ROOT="$ROOT" LAB="$LAB" SCENARIO="$scen" "$@" \
    PATH="$path" "$TREE/bin/claude" "$TREE/parent.sh" "$TREE/parent.pid" \
    /bin/bash "$TREE/child.sh" 2>&1
}

reset_lock() { rm -f "$LAB/state/.lock" "$LAB/state/.lock-session"; }

wait_for_comm() {  # <pid> <comm>
  local i=0
  while [ "$i" -lt 100 ]; do
    [ "$(cat "/proc/$1/comm" 2>/dev/null)" = "$2" ] && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

printf 'worktree=%s\nhome=%s\n' "$ROOT" "$LAB"
printf 'bash=%s claude_symlink=%s\n' "$(command -v bash)" "$TREE/bin/claude"

# ---------------------------------------------------------------------------
say "S1  ps denied: a real claude-named session acquires its own home lock and reads it as held"
reset_lock
out=$(run_tree denied acquire)
claude=$(field "$(cat "$TREE/parent.pid" 2>/dev/null)" pid)
claude=$(cat "$TREE/parent.pid" 2>/dev/null)
printf '%s\n' "$out" | sed 's/^/  /'
[ "$(field "$out" mode)" = "acquire ps_denied=126" ] \
  && pass "the driver's ps shim really refuses ps inside the product's own process (rc 126)" \
  || fail "ps was not actually denied inside the product's process tree"
[ "$(field "$out" acquire_rc)" = 0 ] \
  && pass "fm-lock.sh acquired a free lock with ps denied (no read-only wedge)" \
  || fail "fm-lock.sh refused a free lock with ps denied: $(field "$out" acquire_out)"
[ "$(field "$out" lock_after)" = "$claude" ] \
  && pass "state/.lock names the live claude-named ancestor pid $claude read through /proc" \
  || fail "state/.lock is '$(field "$out" lock_after)', expected $claude"
[ "$(field "$out" status_out)" = "lock: held by live harness pid $claude" ] \
  && pass "fm-lock.sh status reports held for the live harness owner" \
  || fail "fm-lock.sh status said '$(field "$out" status_out)'"
case $out in
  *'"lock":{"state":"held","pid":'$claude',"live_harness":true'*)
    pass "fm-inbox.sh ready projects lock.state=held, live_harness=true for that pid" ;;
  *) fail "fm-inbox.sh ready did not report the live harness lock: $(field "$out" ready_out)" ;;
esac

say "S2  baseline: the same session tree with the real ps binary behaves identically"
reset_lock
out=$(run_tree real acquire)
claude=$(cat "$TREE/parent.pid" 2>/dev/null)
printf '%s\n' "$out" | sed 's/^/  /'
[ "$(field "$out" mode)" = "acquire ps_denied=0" ] \
  && pass "the baseline run really used the working ps binary" \
  || fail "the baseline run did not have a working ps"
[ "$(field "$out" acquire_rc)" = 0 ] && [ "$(field "$out" lock_after)" = "$claude" ] \
  && pass "with ps working, the same tree acquires the same lock pid (nothing drifted)" \
  || fail "ps-working acquisition changed: rc=$(field "$out" acquire_rc) lock=$(field "$out" lock_after) expected $claude"
[ "$(field "$out" status_out)" = "lock: held by live harness pid $claude" ] \
  && pass "with ps working, status reports held for the same owner" \
  || fail "ps-working status said '$(field "$out" status_out)'"
case $out in
  *'"lock":{"state":"held","pid":'$claude',"live_harness":true'*)
    pass "with ps working, fm-inbox.sh ready reports the same held lock" ;;
  *) fail "ps-working ready projection changed: $(field "$out" ready_out)" ;;
esac

# ---------------------------------------------------------------------------
say "S3  foreign live harness: a second live claude session's lock is refused, never taken over"
"$TREE/bin/claude" -c 'sleep 150; :' &
FOREIGN=$!
PIDS+=("$FOREIGN")
if wait_for_comm "$FOREIGN" claude; then
  pass "a second, independent live claude-named session is running (pid $FOREIGN)"
else
  fail "could not stand up the independent live claude session"
fi
for route in denied real; do
  printf '%s\n' "$FOREIGN" > "$LAB/state/.lock"
  rm -f "$LAB/state/.lock-session"
  out=$(run_tree "$route" refuse)
  printf '  [%s route]\n' "$route"
  printf '%s\n' "$out" | sed 's/^/  /'
  [ "$(field "$out" acquire_rc)" = 1 ] \
    && pass "$route route: fm-lock.sh refused a live foreign harness owner" \
    || fail "$route route: fm-lock.sh did not refuse the live foreign owner (rc $(field "$out" acquire_rc))"
  case "$(field "$out" acquire_out)" in
    *"another live firstmate session holds the lock (pid $FOREIGN"*)
      pass "$route route: the refusal names the foreign owner pid $FOREIGN" ;;
    *) fail "$route route: refusal did not name pid $FOREIGN: $(field "$out" acquire_out)" ;;
  esac
  [ "$(field "$out" lock_after)" = "$FOREIGN" ] \
    && pass "$route route: the live foreign owner's lock file was left untouched" \
    || fail "$route route: the live foreign owner's lock was replaced by '$(field "$out" lock_after)'"
  [ "$(field "$out" status_out)" = "lock: held by live harness pid $FOREIGN" ] \
    && pass "$route route: status reports the foreign owner as held" \
    || fail "$route route: status said '$(field "$out" status_out)'"
done

# ---------------------------------------------------------------------------
say "S4  ps denied: zero-valued and malformed lock records stay reclaimable, never a permanent wedge"
out=$(run_tree denied zeros)
claude=$(cat "$TREE/parent.pid" 2>/dev/null)
printf '%s\n' "$out" | sed 's/^/  /'
while IFS= read -r rec; do
  line=$(printf '%s\n' "$out" | grep -F "record=[$rec] acquire_rc=" | head -n 1)
  case $line in
    *"acquire_rc=0 lock_after=[$claude]")
      pass "record [$rec] was reclaimed and rewritten to the current session pid" ;;
    *) fail "record [$rec] did not reclaim cleanly: ${line:-<no line>}" ;;
  esac
done <<'RECORDS'

 
not-a-pid
0
00
000
0000
win:
win:7abc
RECORDS
case $out in
  *refusal_out=*) fail "a zero or malformed record still wedged the home: $out" ;;
  *) pass "no zero or malformed record produced a lock refusal" ;;
esac

# ---------------------------------------------------------------------------
say "S5  ps denied: a live pid that is not a harness is a reusable record, not a wedge"
sleep 150 &
NOTHARNESS=$!
PIDS+=("$NOTHARNESS")
if wait_for_comm "$NOTHARNESS" sleep; then
  pass "a live non-harness process is running (pid $NOTHARNESS, comm sleep)"
else
  fail "could not stand up the live non-harness process"
fi
printf '%s\n' "$NOTHARNESS" > "$LAB/state/.lock"
rm -f "$LAB/state/.lock-session"
out=$(run_tree denied refuse)
claude=$(cat "$TREE/parent.pid" 2>/dev/null)
printf '%s\n' "$out" | sed 's/^/  /'
[ "$(field "$out" acquire_rc)" = 0 ] && [ "$(field "$out" lock_after)" = "$claude" ] \
  && pass "a reused live non-harness pid was reclaimed and the lock rewritten" \
  || fail "a live non-harness pid still wedged the lock: rc=$(field "$out" acquire_rc) lock=$(field "$out" lock_after)"

# ---------------------------------------------------------------------------
say "S6  ps denied: a live Cursor owner behind a UTF-8 install path keeps its identity and its lock"
CUR="$TREE/cursor"
mkdir -p "$CUR/cursor-agent/versions/9.9.9" "$CUR/José/.local/bin"
cp /bin/bash "$CUR/cursor-agent/versions/9.9.9/cursor-agent"
chmod +x "$CUR/cursor-agent/versions/9.9.9/cursor-agent"
ln -s "$CUR/cursor-agent/versions/9.9.9/cursor-agent" "$CUR/José/.local/bin/agent"
"$CUR/José/.local/bin/agent" -c 'sleep 150; :' &
CURSORPID=$!
PIDS+=("$CURSORPID")
if wait_for_comm "$CURSORPID" agent; then
  pass "a live Cursor-shaped process runs through the UTF-8 symlink alias (pid $CURSORPID, comm agent)"
else
  fail "could not stand up the Cursor-shaped process"
fi
read_id() {  # <route>
  local path=$PATH
  [ "$1" = denied ] && path="$TREE/denied:$PATH"
  scrub PATH="$path" CURSORPID="$CURSORPID" bash -c '
    . "$1" || exit 9
    fm_proc_info "$CURSORPID" || exit 8
    printf "%s\t%s" "$FM_PROC_COMM" "$FM_PROC_ARGS"
  ' _ "$ROOT/bin/fm-session-lock-lib.sh"
}
ps_id=$(read_id real)
denied_id=$(read_id denied)
printf '  ps_route      =%s\n  denied_route  =%s\n' "$ps_id" "$denied_id"
[ "$ps_id" = "$denied_id" ] \
  && pass "the denied-ps identity is byte-identical to what the working ps reports" \
  || fail "the two routes disagree: ps '$ps_id' vs denied '$denied_id'"
case "$denied_id" in
  *'José/.local/bin/agent'*) pass "the denied-ps route preserves the UTF-8 alias path bytes" ;;
  *) fail "the denied-ps route mangled the UTF-8 alias path: $denied_id" ;;
esac
cur_comm=${denied_id%%$'\t'*}
cur_args=${denied_id#*$'\t'}
scrub CURSORPID="$CURSORPID" bash -c '
  . "$1"
  fm_harness_pid_alive "$CURSORPID" || exit 5
  fm_session_lock_pid_blocks_reclaim "$CURSORPID" || exit 6
' _ "$ROOT/bin/fm-session-lock-lib.sh" \
  && pass "the denied-ps route classifies the live Cursor alias as a harness that blocks reclaim" \
  || fail "the denied-ps route let the live Cursor alias fall through as reclaimable"
mangled=${cur_args//José/Jos??}
printf '  mangled_args  =%s\n' "$mangled"
scrub CUR="$cur_comm" ARGS="$mangled" bash -c '
  . "$1"
  fm_harness_process_matches "$CUR" "$ARGS"
' _ "$ROOT/bin/fm-session-lock-lib.sh" \
  && fail "a mangled control-byte rendering still matched, so this case proves nothing" \
  || pass "the pre-fix ANSI-only byte rule (é -> ?) would have lost this owner's identity"
for route in denied real; do
  printf '%s\n' "$CURSORPID" > "$LAB/state/.lock"
  rm -f "$LAB/state/.lock-session"
  out=$(run_tree "$route" refuse)
  printf '  [%s route]\n' "$route"
  printf '%s\n' "$out" | sed 's/^/  /'
  [ "$(field "$out" acquire_rc)" = 1 ] \
    && pass "$route route: fm-lock.sh refused to take over the live Cursor owner's lock" \
    || fail "$route route: the live Cursor owner's lock was taken over (rc $(field "$out" acquire_rc))"
  [ "$(field "$out" lock_after)" = "$CURSORPID" ] \
    && pass "$route route: the Cursor owner's lock file is unchanged" \
    || fail "$route route: the Cursor owner's lock was replaced by '$(field "$out" lock_after)'"
  [ "$(field "$out" status_out)" = "lock: held by live harness pid $CURSORPID" ] \
    && pass "$route route: status reports the Cursor owner as held" \
    || fail "$route route: status said '$(field "$out" status_out)'"
done

# ---------------------------------------------------------------------------
say "S7  ps denied: a live owner whose identity cannot be read is refused, not guessed at"
sleep 150 &
UNREADABLE=$!
PIDS+=("$UNREADABLE")
if wait_for_comm "$UNREADABLE" sleep; then
  pass "a live owner process for the unreadable case is running (pid $UNREADABLE)"
else
  fail "could not stand up the live owner for the unreadable case"
fi
printf '%s\n' "$UNREADABLE" > "$LAB/state/.lock"
rm -f "$LAB/state/.lock-session"
out=$(run_tree ownerdenied unreadable OWNER="$UNREADABLE" FM_PROC_ROOT_OVERRIDE="$TREE/emptyproc")
printf '%s\n' "$out" | sed 's/^/  /'
[ "$(field "$out" owner_alive)" = 0 ] \
  && pass "the owner is genuinely live when the product reads it" \
  || fail "the unreadable-owner fixture did not hold: $(field "$out" owner_alive)"
[ "$(field "$out" acquire_rc)" = 1 ] \
  && pass "fm-lock.sh refused to reclaim a lock held by a live but unreadable owner" \
  || fail "fm-lock.sh took a lock from a live unreadable owner (rc $(field "$out" acquire_rc))"
case "$(field "$out" acquire_out)" in
  *"another live firstmate session holds the lock (pid $UNREADABLE"*)
    pass "the refusal names the live owner pid $UNREADABLE" ;;
  *) fail "the refusal did not name the unreadable live owner: $(field "$out" acquire_out)" ;;
esac
[ "$(field "$out" lock_after)" = "$UNREADABLE" ] \
  && pass "the unreadable live owner's lock file is unchanged" \
  || fail "the unreadable live owner's lock was replaced by '$(field "$out" lock_after)'"

# ---------------------------------------------------------------------------
printf '\n===== summary =====\n'
printf 'checks passed: %s\nchecks failed: %s\n' "$PASSES" "$FAILS"
if [ "$FAILS" -eq 0 ]; then
  echo "RESULT: ALL CHECKS PASSED"
  exit 0
fi
echo "RESULT: FAILURES PRESENT"
exit 1
