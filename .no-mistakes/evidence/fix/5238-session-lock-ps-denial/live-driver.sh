#!/usr/bin/env bash
# Live validation driver for fix/5238-session-lock-ps-denial.
#
# Drives the real, public product surfaces - bin/fm-lock.sh (acquire + status)
# and bin/fm-inbox.sh ready - against disposable lab FM_HOMEs and real process
# trees. The only things faked are OS conditions the change targets: a ps binary
# that refuses to exec (the EDR-style deny the issue reports) and a Cygwin/MSYS
# ps for the Windows tagged-owner cases.
set -u

ROOT=/home/art/.no-mistakes/worktrees/9f75ec418609/01M68ERTXFG1M8WBBKXPBN9FS0
EVD=/home/art/.no-mistakes/evidence/01M68ERTXFG1M8WBBKXPBN9FS0
LAB=$(mktemp -d /tmp/fm-lab.XXXXXX)
PIDS=()
FAILED=0
SCENARIO_FAILS=0
PREV_NAME=

"$ROOT/bin/fm-lab-home.sh" create "$LAB" >/dev/null || { echo "LAB SETUP FAILED"; exit 1; }
mkdir -p "$LAB/bin" "$LAB/bin-denied" "$LAB/bin-cygwin" "$LAB/out" "$LAB/homes"

# A ps that cannot execute at all: exactly the /bin/ps denial the change exists
# for (capability denial on the binary, not a ps syntax difference).
cat > "$LAB/bin-denied/ps" <<'SH'
#!/usr/bin/env bash
echo "ps: Operation not permitted" >&2
exit 126
SH
chmod +x "$LAB/bin-denied/ps"

# The harness-named session executable: a real bash whose comm and argv[0] name
# a verified harness, exactly like a real claude install path.
ln -sf /bin/bash "$LAB/bin/claude"

# Every command substitution inherits this EXIT trap; only the shell that
# created the lab may tear it down, or the first $(...) would delete the fixture
# out from under the run.
TOP_BASHPID=$BASHPID
cleanup() {
  [ "$BASHPID" = "$TOP_BASHPID" ] || return 0
  local p
  for p in ${PIDS[@]+"${PIDS[@]}"}; do kill "$p" 2>/dev/null; done
  sleep 0.1
  for p in ${PIDS[@]+"${PIDS[@]}"}; do kill -9 "$p" 2>/dev/null; done
  rm -rf "$LAB"
}
trap cleanup EXIT

note() { printf '%s\n' "$*"; }
ok()   { printf 'CHECK ok   - %s\n' "$*"; }
bad()  { printf 'CHECK FAIL - %s\n' "$*"; FAILED=$((FAILED + 1)); SCENARIO_FAILS=$((SCENARIO_FAILS + 1)); }

scenario() {  # <name>
  if [ "$SCENARIO_FAILS" -ne 0 ]; then
    printf 'RESULT fail - %s (%d failed checks)\n' "$PREV_NAME" "$SCENARIO_FAILS"
  elif [ -n "$PREV_NAME" ]; then
    printf 'RESULT pass - %s\n' "$PREV_NAME"
  fi
  SCENARIO_FAILS=0
  PREV_NAME=$1
  printf '\n==== SCENARIO: %s ====\n' "$1"
}
finish_scenarios() {
  if [ "$SCENARIO_FAILS" -ne 0 ]; then
    printf 'RESULT fail - %s (%d failed checks)\n' "$PREV_NAME" "$SCENARIO_FAILS"
  else
    printf 'RESULT pass - %s\n' "$PREV_NAME"
  fi
}

new_home() {  # <name> -> prints home path
  local h="$LAB/homes/$1"
  rm -rf "$h"
  "$ROOT/bin/fm-lab-home.sh" create "$h" >/dev/null
  printf '%s\n' "$h"
}

# Run a body inside a harness-named session whose parent is init (the double
# fork reparents it), so the ancestry walk sees exactly one harness - this
# session - and can never escape into the agent running this driver.
#
# usage: session <home> <body> <prefix> [env-assignment...]
session() {
  local home=$1 body=$2 prefix=$3
  shift 3
  rm -f "$prefix.pid" "$prefix.out" "$prefix.err" "$prefix.rc"
  ( ( env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u FM_ROOT_OVERRIDE \
        -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE \
        -u FM_PROJECTS_OVERRIDE FM_HOME="$home" "$@" \
        "$LAB/bin/claude" -c 'printf "%s\n" "$$" > "$1"; "$0" >"$2" 2>"$3"; printf "%s\n" "$?" >"$4"; :' \
        "$body" "$prefix.pid" "$prefix.out" "$prefix.err" "$prefix.rc" </dev/null >/dev/null 2>&1 & ) & )
  local i=0
  while [ ! -s "$prefix.rc" ] && [ "$i" -lt 400 ]; do sleep 0.05; i=$((i + 1)); done
  [ -s "$prefix.rc" ] || echo "141" > "$prefix.rc"
  local p
  p=$(cat "$prefix.pid" 2>/dev/null || true)
  [ -n "$p" ] && PIDS+=("$p")
  cat "$prefix.rc"
}

await_pidfile() {  # <file>
  local i=0
  while [ ! -s "$1" ] && [ "$i" -lt 200 ]; do sleep 0.05; i=$((i + 1)); done
}

# A live, real harness process that stays alive (its parent is init).
hold_harness() {  # <seconds> -> prints the live harness pid
  local secs=$1 pidfile="$LAB/out/hold-session.pid" p
  rm -f "$pidfile"
  ( ( "$LAB/bin/claude" -c 'printf "%s\n" "$$" > "$0"; sleep "$1"; :' "$pidfile" "$secs" </dev/null >/dev/null 2>&1 & ) & )
  await_pidfile "$pidfile"
  p=$(cat "$pidfile" 2>/dev/null || true)
  PIDS+=("$p")
  printf '%s\n' "$p"
}

# A live, real non-harness process (kernel comm "python3").
hold_plain() {  # <seconds> -> prints pid
  local secs=$1 pidfile="$LAB/out/plain.pid" p
  rm -f "$pidfile"
  ( ( python3 -c 'import os,sys,time
open(sys.argv[1],"w").write("%d\n" % os.getpid())
time.sleep(float(sys.argv[2]))' "$pidfile" "$secs" </dev/null >/dev/null 2>&1 & ) & )
  await_pidfile "$pidfile"
  p=$(cat "$pidfile" 2>/dev/null || true)
  PIDS+=("$p")
  printf '%s\n' "$p"
}

# A live pid whose identity the ps route cannot read: a non-leader thread id.
# kill -0 succeeds (it is a live task) while `ps -o comm= -p <tid>` exits 1.
hold_thread() {  # <seconds> -> prints the tid
  local secs=$1 pidfile="$LAB/out/tid.pid" t
  rm -f "$pidfile"
  ( ( python3 -c 'import sys,threading,time
def hold():
    open(sys.argv[1],"w").write("%d\n" % threading.get_native_id())
    time.sleep(float(sys.argv[2]))
t=threading.Thread(target=hold); t.start(); t.join()' "$pidfile" "$secs" </dev/null >/dev/null 2>&1 & ) & )
  await_pidfile "$pidfile"
  t=$(cat "$pidfile" 2>/dev/null || true)
  PIDS+=("$t")
  printf '%s\n' "$t"
}

# A pid that is certainly dead: a short-lived process, reaped and awaited.
dead_pid() {
  bash -c 'exit 0' &
  local p=$!
  wait "$p" 2>/dev/null
  printf '%s\n' "$p"
}

body_acquire() {  # <home> <prefix> [env...] -> prints the `fm-lock.sh` rc
  local home=$1 prefix=$2 body="$LAB/out/body-acquire.sh"
  shift 2
  cat > "$body" <<SH
#!/usr/bin/env bash
printf 'ps -V says: '
ps -V >/dev/null 2>&1 || printf 'ps refused (rc=%s)\n' "\$?"
[ -e "\$FM_HOME/state/.lock" ] && printf 'lock before: %s\n' "\$(cat "\$FM_HOME/state/.lock")"
"$ROOT/bin/fm-lock.sh"
rc=\$?
printf 'fm-lock rc=%s\n' "\$rc"
printf 'lock after: %s\n' "\$(cat "\$FM_HOME/state/.lock" 2>/dev/null)"
exit "\$rc"
SH
  chmod +x "$body"
  session "$home" "$body" "$prefix" "$@" >/dev/null
  cat "$prefix.out" "$prefix.err" > "$prefix.log"
  cat "$prefix.rc"
}

expect_rc() {  # <desc> <actual> <expected>
  if [ "$2" = "$3" ]; then ok "$1 (rc=$2)"; else bad "$1: rc=$2 expected $3"; fi
}
expect_contains() {  # <desc> <file> <needle>
  if grep -Fq -- "$3" "$2"; then ok "$1 (contains: $3)"; else
    bad "$1: no '$3' in:"; sed -n '1,20p' "$2" | sed 's/^/    | /'
  fi
}
expect_absent() {  # <desc> <file> <needle>
  if grep -Fq -- "$3" "$2"; then bad "$1: unexpected '$3' in:"; sed -n '1,20p' "$2" | sed 's/^/    | /'
  else ok "$1 (absent: $3)"; fi
}
expect_eq() {  # <desc> <actual> <expected>
  if [ "$2" = "$3" ]; then ok "$1 (= $2)"; else bad "$1: got '$2' expected '$3'"; fi
}
show() { sed 's/^/    | /' "$1"; }

################################################################################
scenario "S1 a session on a ps-denied host acquires the session lock (the reported permanent read-only wedge)"

H=$(new_home s1)
rc=$(body_acquire "$H" "$LAB/out/s1" PATH="$LAB/bin-denied:$PATH")
show "$LAB/out/s1.log"
expect_rc "fm-lock.sh acquires under a denied ps" "$rc" 0
expect_contains "the acquisition is reported" "$LAB/out/s1.log" "lock acquired: harness pid"
anchor=$(cat "$H/state/.lock" 2>/dev/null || true)
sesspid=$(cat "$LAB/out/s1.pid" 2>/dev/null || true)
expect_eq "state/.lock holds this session's harness pid" "$anchor" "$sesspid"
expect_absent "no fail-closed diagnostic on a resolved identity" "$LAB/out/s1.log" "fm-session-lock:"
cp "$LAB/out/s1.log" "$EVD/live-s1-denied-ps-acquire.log"

################################################################################
scenario "S2 a live harness owner on a ps-denied host keeps the lock: a second session is refused, lock unchanged (no takeover)"

H=$(new_home s2)
owner=$(hold_harness 90)
printf '%s\n' "$owner" > "$H/state/.lock"
printf 'S2-foreign-session\n' > "$H/state/.lock-session"
rc=$(body_acquire "$H" "$LAB/out/s2" PATH="$LAB/bin-denied:$PATH")
show "$LAB/out/s2.log"
expect_rc "the second session is refused" "$rc" 1
expect_contains "the refusal names the live owner" "$LAB/out/s2.log" "another live firstmate session holds the lock (pid $owner"
expect_eq "the lock file is unchanged" "$(cat "$H/state/.lock")" "$owner"
expect_eq "the sidecar is unchanged" "$(cat "$H/state/.lock-session")" "S2-foreign-session"
cp "$LAB/out/s2.log" "$EVD/live-s2-denied-ps-live-owner-refused.log"

################################################################################
scenario "S3 a live owner whose identity cannot be read blocks reclaim (fail closed)"

H=$(new_home s3)
tid=$(hold_thread 90)
printf '%s\n' "$tid" > "$H/state/.lock"
note "unreadable live owner: thread id $tid"
note "  kill -0 -> $(kill -0 "$tid" 2>/dev/null && echo alive || echo not-alive); ps -o comm= -p $tid -> rc=$(ps -o comm= -p "$tid" >/dev/null 2>&1; echo $?)"
rc=$(body_acquire "$H" "$LAB/out/s3")
show "$LAB/out/s3.log"
expect_rc "an unreadable live owner is not reclaimed" "$rc" 1
expect_contains "the refusal names the unreadable owner" "$LAB/out/s3.log" "another live firstmate session holds the lock (pid $tid"
expect_eq "the lock file is unchanged" "$(cat "$H/state/.lock")" "$tid"
cp "$LAB/out/s3.log" "$EVD/live-s3-unreadable-owner-refused.log"

################################################################################
scenario "S4 a dead owner record is reclaimed on a ps-denied host"

H=$(new_home s4)
dead=$(dead_pid)
printf '%s\n' "$dead" > "$H/state/.lock"
note "dead owner pid: $dead"
rc=$(body_acquire "$H" "$LAB/out/s4" PATH="$LAB/bin-denied:$PATH")
show "$LAB/out/s4.log"
expect_rc "the stale lock is reclaimed" "$rc" 0
expect_contains "the acquisition is reported" "$LAB/out/s4.log" "lock acquired: harness pid"
expect_eq "state/.lock is rewritten to this session" "$(cat "$H/state/.lock")" "$(cat "$LAB/out/s4.pid")"
cp "$LAB/out/s4.log" "$EVD/live-s4-dead-owner-reclaimed.log"

################################################################################
scenario "S5 a reused pid owned by a live non-harness is reclaimed"

H=$(new_home s5)
plain=$(hold_plain 90)
printf '%s\n' "$plain" > "$H/state/.lock"
note "live non-harness owner pid: $plain ($(ps -o comm= -p "$plain" 2>/dev/null))"
rc=$(body_acquire "$H" "$LAB/out/s5")
show "$LAB/out/s5.log"
expect_rc "the reused pid does not wedge the home" "$rc" 0
expect_eq "state/.lock is rewritten to this session" "$(cat "$H/state/.lock")" "$(cat "$LAB/out/s5.pid")"

H2=$(new_home s5b)
printf '%s\n' "$plain" > "$H2/state/.lock"
rc=$(body_acquire "$H2" "$LAB/out/s5b" PATH="$LAB/bin-denied:$PATH")
show "$LAB/out/s5b.log"
expect_rc "the same reused pid is reclaimed under a denied ps too" "$rc" 0
cp "$LAB/out/s5.log" "$EVD/live-s5-reused-pid-reclaimed.log"

################################################################################
scenario "S6 malformed, empty, whitespace and zero-form lock records stay reclaimable"

for record in 0 00 000 not-a-pid win: win:7abc; do
  tag=$(printf '%s' "$record" | tr -c 'a-zA-Z0-9' '_')
  H=$(new_home "s6-$tag")
  printf '%s\n' "$record" > "$H/state/.lock"
  rc=$(body_acquire "$H" "$LAB/out/s6-$tag")
  printf '\n-- record %s\n' "$(printf '%q' "$record")"
  show "$LAB/out/s6-$tag.log"
  expect_rc "record '$record' is reclaimed" "$rc" 0
  expect_eq "record '$record' is replaced by this session" "$(cat "$H/state/.lock")" "$(cat "$LAB/out/s6-$tag.pid")"
done

H=$(new_home s6-empty)
: > "$H/state/.lock"
rc=$(body_acquire "$H" "$LAB/out/s6-empty")
printf '\n-- record <empty file>\n'
show "$LAB/out/s6-empty.log"
expect_rc "an empty lock record is reclaimed" "$rc" 0
expect_eq "the empty record is replaced by this session" "$(cat "$H/state/.lock")" "$(cat "$LAB/out/s6-empty.pid")"

H=$(new_home s6-space)
printf '   \n' > "$H/state/.lock"
rc=$(body_acquire "$H" "$LAB/out/s6-space")
printf '\n-- record <whitespace>\n'
show "$LAB/out/s6-space.log"
expect_rc "a whitespace lock record is reclaimed" "$rc" 0

H=$(new_home s6-zero-denied)
printf '00\n' > "$H/state/.lock"
rc=$(body_acquire "$H" "$LAB/out/s6-zero-denied" PATH="$LAB/bin-denied:$PATH")
printf '\n-- record 00 under a denied ps\n'
show "$LAB/out/s6-zero-denied.log"
expect_rc "the zero-form record is reclaimed under a denied ps" "$rc" 0
{ echo '== malformed/zero/empty record transcripts'; for f in "$LAB"/out/s6-*.log; do echo "--- $f"; cat "$f"; done; } \
  > "$EVD/live-s6-reclaimable-records.log"

################################################################################
scenario "S7 status/inspect report a live harness holder as held and a non-harness holder as not"

H=$(new_home s7)
owner=$(hold_harness 90)
plain=$(hold_plain 90)
printf '%s\n' "$owner" > "$H/state/.lock"
{ printf '$ bin/fm-lock.sh status   (live harness pid %s, real ps)\n' "$owner"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID FM_HOME="$H" "$ROOT/bin/fm-lock.sh" status
  printf '$ bin/fm-lock.sh status   (same holder, denied ps)\n'
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID FM_HOME="$H" PATH="$LAB/bin-denied:$PATH" "$ROOT/bin/fm-lock.sh" status
  printf '%s\n' "$plain" > "$H/state/.lock"
  printf '$ bin/fm-lock.sh status   (live non-harness pid %s)\n' "$plain"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID FM_HOME="$H" "$ROOT/bin/fm-lock.sh" status
  printf 'dead\n' > /dev/null
  d=$(dead_pid)
  printf '%s\n' "$d" > "$H/state/.lock"
  printf '$ bin/fm-lock.sh status   (dead pid %s)\n' "$d"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID FM_HOME="$H" "$ROOT/bin/fm-lock.sh" status
  printf '$ bin/fm-lock.sh status   (record "00")\n'
  printf '00\n' > "$H/state/.lock"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID FM_HOME="$H" "$ROOT/bin/fm-lock.sh" status
} > "$LAB/out/s7-status.log" 2>&1
show "$LAB/out/s7-status.log"
[ "$(grep -c "lock: held by live harness pid $owner" "$LAB/out/s7-status.log")" = 2 ] \
  && ok "status reports the live harness holder through both the ps and denied-ps routes" \
  || bad "status does not report the live harness holder as held on both routes"
expect_contains "status reports a live non-harness as stale" "$LAB/out/s7-status.log" "lock: stale (pid $plain dead or not a harness)"

# Machine-readable consumer of the same inspect helper.
printf '%s\n' "$owner" > "$H/state/.lock"
{ printf '$ bin/fm-inbox.sh ready   (live harness pid %s)\n' "$owner"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID FM_HOME="$H" "$ROOT/bin/fm-inbox.sh" ready 2>&1
  printf '%s\n' "$plain" > "$H/state/.lock"
  printf '$ bin/fm-inbox.sh ready   (live non-harness pid %s)\n' "$plain"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID FM_HOME="$H" "$ROOT/bin/fm-inbox.sh" ready 2>&1
} > "$LAB/out/s7-inbox.log" 2>&1
show "$LAB/out/s7-inbox.log"
grep -Fq '"state":"held"' "$LAB/out/s7-inbox.log" \
  && ok "fm-inbox.sh ready reports lock.state=held for the harness holder" \
  || bad "fm-inbox.sh ready did not report lock.state=held"
grep -Fq '"live_harness":true' "$LAB/out/s7-inbox.log" \
  && ok "fm-inbox.sh ready reports live_harness=true for the harness holder" \
  || bad "fm-inbox.sh ready did not report live_harness=true"
grep -Fq '"live_harness":false' "$LAB/out/s7-inbox.log" \
  && ok "fm-inbox.sh ready reports live_harness=false for the non-harness holder" \
  || bad "fm-inbox.sh ready did not report live_harness=false for the non-harness holder"
cp "$LAB/out/s7-status.log" "$EVD/live-s7-status.log"
cp "$LAB/out/s7-inbox.log" "$EVD/live-s7-inbox-ready.log"

################################################################################
scenario "S8 the ps route and the ps-free provider route reach the same identity verdict for real processes (control bytes, empty argv elements, comm with space/paren/newline, non-ASCII harness name)"

cat > "$LAB/parity.sh" <<SH
#!/usr/bin/env bash
set -u
. "$ROOT/bin/fm-session-lock-lib.sh"
if fm_proc_info "\$1"; then
  if fm_harness_process_matches "\$FM_PROC_COMM" "\$FM_PROC_ARGS"; then m=yes; else m=no; fi
  printf 'verdict readable match=%s|' "\$m"
  printf 'fields comm=%q args=%q ppid=%s' "\$FM_PROC_COMM" "\$FM_PROC_ARGS" "\$FM_PROC_PPID"
else
  printf 'verdict unreadable match=no|fields none'
fi
SH
chmod +x "$LAB/parity.sh"

h1=$(hold_harness 90)

# t2: a real process whose argv carries a newline, a tab, a CR, non-ASCII bytes,
# an empty middle element and a trailing empty element.
t2file="$LAB/out/t2.pid"
rm -f "$t2file"
( ( python3 -c 'import os,sys
f=open(sys.argv[1],"w"); f.write("x"); f.close()
os.execv(sys.executable, [sys.executable, "-c", "import time; time.sleep(60)",
                          "\n", "", "tab\there", "cr\r", "uni\u00e9", "sp ace", "a)b(c", ""])' "$t2file" </dev/null >/dev/null 2>&1 & ) & )
await_pidfile "$t2file"
sleep 0.3
t2=$(pgrep -f 'time.sleep\(60\)' -n 2>/dev/null | head -1)
[ -n "$t2" ] && PIDS+=("$t2")

# t3: a live process whose kernel comm contains a space, parentheses and a
# newline - the shape the /proc stat parser must cut from the LAST ") ".
t3file="$LAB/out/t3.pid"
rm -f "$t3file"
( ( python3 -c 'import ctypes,sys,time
open(sys.argv[1],"w").write("%d\n" % __import__("os").getpid())
ctypes.CDLL(None).prctl(15, b"sle ep (x\n2", 0,0,0)
time.sleep(60)' "$t3file" </dev/null >/dev/null 2>&1 & ) & )
await_pidfile "$t3file"
t3=$(cat "$t3file" 2>/dev/null || true)
[ -n "$t3" ] && PIDS+=("$t3")

# t5: a harness-named process whose name carries a non-ASCII byte, to prove the
# byte-rendering difference cannot flip the harness verdict.
cp /bin/bash "$LAB/bin/claude-é"
t5file="$LAB/out/t5.pid"
rm -f "$t5file"
( ( "$LAB/bin/claude-é" -c 'printf "%s\n" "$$" > "$0"; sleep 60; :' "$t5file" </dev/null >/dev/null 2>&1 & ) & )
await_pidfile "$t5file"
t5=$(cat "$t5file" 2>/dev/null || true)
[ -n "$t5" ] && PIDS+=("$t5")

t4=$(dead_pid)

REPORT="$LAB/out/s8-parity.log"
: > "$REPORT"
verdict_fails=0
for pair in "live harness:$h1" "python control-byte argv:$t2" "comm with space/paren/newline:$t3" "harness name with non-ASCII:$t5" "dead pid:$t4" "live non-harness:$plain"; do
  label=${pair%:*}; pid=${pair##*:}
  ps_out=$("$LAB/parity.sh" "$pid" 2>&1)
  den_out=$(PATH="$LAB/bin-denied:$PATH" "$LAB/parity.sh" "$pid" 2>&1)
  ps_verdict=${ps_out%%|*}
  den_verdict=${den_out%%|*}
  {
    printf '== %s (pid %s)\n' "$label" "$pid"
    printf '   ps        : %s\n' "$ps_out"
    printf '   denied-ps : %s\n' "$den_out"
    if [ "$ps_verdict" = "$den_verdict" ]; then
      printf '   PARITY verdict same (%s)\n' "$ps_verdict"
    else
      printf '   PARITY VERDICT DIFFERS: ps=%s denied=%s\n' "$ps_verdict" "$den_verdict"
    fi
    if [ "${ps_out#*|}" = "${den_out#*|}" ]; then
      printf '   fields identical\n'
    else
      printf '   fields differ between routes (byte rendering)\n'
    fi
  } >> "$REPORT"
  [ "$ps_verdict" = "$den_verdict" ] || verdict_fails=$((verdict_fails + 1))
done
cat "$REPORT"
if [ "$verdict_fails" -eq 0 ]; then
  ok "both routes reach the same identity verdict for every real process shape"
else
  bad "$verdict_fails real process shape(s) got a different identity verdict from the two routes"
fi
cp "$REPORT" "$EVD/live-s8-route-parity.log"
cp "$LAB/parity.sh" "$EVD/live-s8-parity-probe.sh"

################################################################################
scenario "S8b a ps-denied host and a ps host reach the same lock decision for the same owner state"

for state in live-harness live-non-harness dead; do
  case $state in
    live-harness) pid=$(hold_harness 90) ;;
    live-non-harness) pid=$(hold_plain 90) ;;
    dead) pid=$(dead_pid) ;;
  esac
  for route in ps denied; do
    H=$(new_home "s8b-${state}-${route}")
    printf '%s\n' "$pid" > "$H/state/.lock"
    if [ "$route" = denied ]; then
      rc=$(body_acquire "$H" "$LAB/out/s8b-${state}-${route}" PATH="$LAB/bin-denied:$PATH")
    else
      rc=$(body_acquire "$H" "$LAB/out/s8b-${state}-${route}")
    fi
    printf '%-16s %-7s owner=%s -> fm-lock rc=%s\n' "$state" "$route" "$pid" "$rc"
    printf '%s\n' "$rc" > "$LAB/out/rc-${state}-${route}"
  done
  expect_eq "same decision on both routes for a $state owner (rc)" \
    "$(cat "$LAB/out/rc-${state}-denied")" "$(cat "$LAB/out/rc-${state}-ps")"
done
expect_eq "a live harness owner is still refused when ps is denied" "$(cat "$LAB/out/rc-live-harness-denied")" "1"
expect_eq "a dead owner is reclaimed when ps is denied" "$(cat "$LAB/out/rc-dead-denied")" "0"
expect_eq "a reused non-harness owner is reclaimed when ps is denied" "$(cat "$LAB/out/rc-live-non-harness-denied")" "0"
{ echo '== route decision matrix'; for f in "$LAB"/out/s8b-*.log; do echo "--- $f"; cat "$f"; done; } \
  > "$EVD/live-s8b-decision-matrix.log"

################################################################################
scenario "S9 Windows tagged win:<pid> owners: live harness and unreadable table block, absent/reused/malformed are reclaimable"

# A Cygwin-family ps: refuses -o, serves the documented fixed columns, and reads
# the Windows process table with `ps -W`.
cat > "$LAB/bin-cygwin/uname" <<'SH'
#!/usr/bin/env bash
printf '%s\n' 'MINGW64_NT-10.0-26200'
SH
cat > "$LAB/bin-cygwin/ps" <<'SH'
#!/usr/bin/env bash
set -u
for a in "$@"; do
  [ "$a" = "-o" ] && { echo "ps: unknown option -- o" >&2; exit 1; }
done
mode=p full=0 pid=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -W) mode=W; shift ;;
    -f) full=1; shift ;;
    -p) pid=$2; shift 2 ;;
    *) shift ;;
  esac
done
if [ "$mode" = W ]; then
  [ -z "${FM_TEST_WIN_PS_LOG:-}" ] || printf 'W\n' >> "$FM_TEST_WIN_PS_LOG"
  if [ -n "${FM_TEST_WIN_PS_FAIL_AFTER:-}" ] && [ -n "${FM_TEST_WIN_PS_LOG:-}" ]; then
    n=$(grep -c '^W$' "$FM_TEST_WIN_PS_LOG" 2>/dev/null || echo 0)
    [ "$n" -le "$FM_TEST_WIN_PS_FAIL_AFTER" ] || { echo "ps: cannot read the Windows process table" >&2; exit 1; }
  fi
  [ -z "${FM_TEST_WIN_PS_FAIL:-}" ] || { echo "ps: cannot read the Windows process table" >&2; exit 1; }
  printf '%s\n' '      PID    PPID    PGID     WINPID   TTY         UID    STIME COMMAND'
  [ -n "${FM_TEST_WIN_TABLE:-}" ] && printf '%s\n' "$FM_TEST_WIN_TABLE"
  exit 0
fi
pid=${pid:-${FM_TEST_WIN_ANCHOR:-700}}
case $pid in
  "${FM_TEST_WIN_ANCHOR:-700}") comm=${FM_TEST_WIN_ANCHOR_COMM:-/opt/claude/versions/2.1.220}; ppid=1 ;;
  *) comm=/usr/bin/bash; ppid=${FM_TEST_CYG_PPID:-1} ;;
esac
if [ "$full" = 1 ]; then
  printf '%s\n' '     UID     PID    PPID  TTY        STIME COMMAND'
  printf 'u %s %s ? 00:00:00 %s\n' "$pid" "$ppid" "$comm"
else
  printf '%s\n' '      PID    PPID    PGID     WINPID   TTY         UID    STIME COMMAND'
  printf '%s %s %s 9999 ? 0 00:00:00 %s\n' "$pid" "$ppid" "$pid" "$comm"
fi
SH
chmod +x "$LAB/bin-cygwin/uname" "$LAB/bin-cygwin/ps"

win_acquire() {  # <home> <prefix> [extra env...]
  local home=$1 prefix=$2
  shift 2
  local body="$LAB/out/body-win.sh"
  cat > "$body" <<SH
#!/usr/bin/env bash
printf 'uname: %s\n' "\$(uname -s)"
printf 'lock before: %s\n' "\$(cat "\$FM_HOME/state/.lock" 2>/dev/null)"
CLAUDE_CODE_SESSION_ID=S-WIN CLAUDE_PID=\${FM_TEST_WIN_ANCHOR:-700} "$ROOT/bin/fm-lock.sh"
rc=\$?
printf 'fm-lock rc=%s\n' "\$rc"
printf 'lock after: %s\n' "\$(cat "\$FM_HOME/state/.lock" 2>/dev/null)"
exit "\$rc"
SH
  chmod +x "$body"
  session "$home" "$body" "$prefix" PATH="$LAB/bin-cygwin:$PATH" "$@" >/dev/null
  cat "$prefix.out" "$prefix.err" > "$prefix.log"
  cat "$prefix.rc"
}

WIN_SELF='    700    1   700    700 ? 0 00:00:00 claude.exe'
WIN_OWNER='   7204    1  7204   7204 ? 0 00:00:00 claude.exe'
WIN_LIVE_TABLE="$WIN_SELF
$WIN_OWNER"
WIN_OTHER_TABLE="$WIN_SELF
   7204    1  7204   7204 ? 0 00:00:00 notepad.exe"
WIN_ABSENT_TABLE="$WIN_SELF
   9999    1  9999   9999 ? 0 00:00:00 bash.exe"

H=$(new_home s9-live)
printf 'win:7204\n' > "$H/state/.lock"
gatelog="$LAB/out/wincount-live.log"
: > "$gatelog"
rc=$(win_acquire "$H" "$LAB/out/s9-live" FM_TEST_WIN_TABLE="$WIN_LIVE_TABLE" FM_TEST_WIN_ANCHOR=700 \
  FM_TEST_WIN_PS_LOG="$gatelog")
gate_read=$(grep -c '^W$' "$gatelog" 2>/dev/null || true)
note "the reclaim verdict is the Windows-table read number $gate_read of this run"
show "$LAB/out/s9-live.log"
expect_rc "a live tagged harness owner is not reclaimed" "$rc" 1
expect_contains "the refusal names the tagged owner" "$LAB/out/s9-live.log" "holds the lock (pid win:7204"
expect_eq "the tagged lock is unchanged" "$(cat "$H/state/.lock")" "win:7204"

# A totally unreadable Windows table also leaves the home read-only. Note that
# on this fixture it blocks anchor resolution as well as the gate.
H=$(new_home s9-unreadable)
printf 'win:7204\n' > "$H/state/.lock"
rc=$(win_acquire "$H" "$LAB/out/s9-unreadable" FM_TEST_WIN_TABLE="$WIN_LIVE_TABLE" FM_TEST_WIN_PS_FAIL=1 FM_TEST_WIN_ANCHOR=700)
show "$LAB/out/s9-unreadable.log"
expect_rc "an unreadable Windows process table leaves the home read-only" "$rc" 1
expect_eq "the lock survives a fully unreadable table" "$(cat "$H/state/.lock")" "win:7204"

# The gate's own unreadable-table path: let the anchor resolve, then deny the
# table from the read the reclaim verdict makes (read number gate_read above).
H=$(new_home s9-unreadable-gate)
printf 'win:7204\n' > "$H/state/.lock"
gatefail=$((gate_read > 1 ? gate_read - 1 : 1))
note "denying Windows-table read $((gatefail + 1)) of this run, the reclaim verdict's own read"
rc=$(win_acquire "$H" "$LAB/out/s9-unreadable-gate" FM_TEST_WIN_TABLE="$WIN_LIVE_TABLE" FM_TEST_WIN_ANCHOR=700 \
  FM_TEST_WIN_PS_LOG="$LAB/out/wincount-gate.log" FM_TEST_WIN_PS_FAIL_AFTER="$gatefail")
show "$LAB/out/s9-unreadable-gate.log"
expect_rc "the reclaim gate is denied when the Windows table stops reading" "$rc" 1
expect_contains "the gate refusal names the tagged owner" "$LAB/out/s9-unreadable-gate.log" "holds the lock (pid win:7204"
expect_eq "the lock survives a gate-time unreadable table" "$(cat "$H/state/.lock")" "win:7204"

H=$(new_home s9-absent)
printf 'win:7204\n' > "$H/state/.lock"
rc=$(win_acquire "$H" "$LAB/out/s9-absent" FM_TEST_WIN_TABLE="$WIN_ABSENT_TABLE" FM_TEST_WIN_ANCHOR=700)
show "$LAB/out/s9-absent.log"
expect_rc "a tagged pid absent from the table is reclaimed" "$rc" 0
expect_eq "the tagged lock is replaced by this session" "$(cat "$H/state/.lock")" "win:700"

H=$(new_home s9-reused)
printf 'win:7204\n' > "$H/state/.lock"
rc=$(win_acquire "$H" "$LAB/out/s9-reused" FM_TEST_WIN_TABLE="$WIN_OTHER_TABLE" FM_TEST_WIN_ANCHOR=700)
show "$LAB/out/s9-reused.log"
expect_rc "a tagged pid present as a live non-harness is reclaimed" "$rc" 0

for record in 'win:' 'win:7abc'; do
  tag=$(printf '%s' "$record" | tr -c 'a-zA-Z0-9' '_')
  H=$(new_home "s9-$tag")
  printf '%s\n' "$record" > "$H/state/.lock"
  rc=$(win_acquire "$H" "$LAB/out/s9-$tag" FM_TEST_WIN_TABLE="$WIN_LIVE_TABLE" FM_TEST_WIN_ANCHOR=700)
  printf '\n-- tagged record %s\n' "$(printf '%q' "$record")"
  show "$LAB/out/s9-$tag.log"
  expect_rc "malformed tagged record '$record' is reclaimed" "$rc" 0
  expect_eq "record '$record' is replaced by this session" "$(cat "$H/state/.lock")" "win:700"
done
{ echo '== Cygwin/MSYS tagged-owner transcripts'; for f in "$LAB"/out/s9-*.log; do echo "--- $f"; cat "$f"; done; } \
  > "$EVD/live-s9-windows-tagged.log"

finish_scenarios
printf '\n==== OVERALL: %s failed check(s) ====\n' "$FAILED"
[ "$FAILED" -eq 0 ]
