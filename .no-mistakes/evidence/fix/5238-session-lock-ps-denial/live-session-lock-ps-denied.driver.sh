#!/usr/bin/env bash
# Live validation driver for the ps-denied session-lock change (issue 5238).
# Drives the real product entry points (bin/fm-session-start.sh, bin/fm-lock.sh,
# bin/fm-inbox.sh, bin/fm-claude-stop-autoarm.sh, both turn-end guards) against
# real processes, real /proc, real kill, and a disposable marked lab home.
# The only stand-ins are the ps binary's denial (PATH shim) and, for the
# unreadable-owner case, its selective refusal of the owner's pid.
set -u

REPO=$1
BASE_COMMIT=$2
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-driver.XXXXXX")
LAB= ; LAB2= ; LAB3= ; LAB4= ; LAB5= ; LAB6= ; LAB7= ; LAB8= ; LAB9=
PIDS=()
FAILS=0

say() { printf '%s\n' "$*"; }
sec() { printf '\n========================================================================\n%s\n========================================================================\n' "$*"; }
ok()  { printf 'PASS - %s\n' "$*"; }
bad() { printf 'FAIL - %s\n' "$*"; FAILS=$((FAILS + 1)); }
check_eq() {  # <label> <actual> <expected>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (actual='$2' expected='$3')"; fi
}
check_has() {  # <label> <haystack> <needle>
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1 (missing '$3' in '$2')" ;; esac
}
wait_file() {  # <path> <seconds>
  local i=0
  while [ ! -e "$1" ] && [ "$i" -lt "$(( $2 * 10 ))" ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$1" ]
}
cleanup() {
  local pid
  rm -f "$WORK"/keep* 2>/dev/null || true
  for pid in ${PIDS[@]+"${PIDS[@]}"}; do kill "$pid" 2>/dev/null || true; done
  for pid in ${PIDS[@]+"${PIDS[@]}"}; do wait "$pid" 2>/dev/null || true; done
  [ -n "$LAB" ] && rm -rf "$LAB"
  for d in ${LABS[@]+"${LABS[@]}"}; do rm -rf "$d"; done
  rm -rf "$WORK"
}
trap cleanup EXIT

mkdir -p "$WORK/named" "$WORK/fakebin" "$WORK/logs" "$WORK/emptyproc"
ln -s "$(command -v bash)" "$WORK/named/claude"
ln -s "$(command -v bash)" "$WORK/named/codex"
# A ps binary the policy refuses to execute at all (bash's refused-exec status).
cat > "$WORK/fakebin/ps" <<'SH'
#!/usr/bin/env bash
echo "$0: Operation not permitted" >&2
exit 126
SH
chmod +x "$WORK/fakebin/ps"

new_lab() {  # <varname> -> prints path, records in LABS
  local dir
  dir=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")
  "$REPO/bin/fm-lab-home.sh" create "$dir" >/dev/null || { bad "lab home create $dir"; exit 1; }
  LABS+=("$dir")
  printf '%s\n' "$dir"
}
primary_fixture() {  # <lab> : extra fields the hook scope check needs
  mkdir -p "$1/bin"
  : > "$1/AGENTS.md"
  : > "$1/state/task.meta"
  git init -q "$1"
  git -C "$1" commit -q --allow-empty -m fixture
}
start_named() {  # <name> <script> <args...>  -> sets LAST_PID
  local name=$1
  shift
  "$WORK/named/$name" "$@" > "$WORK/logs/${name}-stdout.$$" 2>&1 &
  LAST_PID=$!
  PIDS+=("$LAST_PID")
}

sec "ENVIRONMENT"
say "repo worktree : $REPO"
say "repo HEAD     : $(git -C "$REPO" rev-parse --short HEAD) ($(git -C "$REPO" rev-parse --abbrev-ref HEAD))"
say "base commit   : $BASE_COMMIT"
say "host          : $(uname -srm)"
say "real ps       : $(command -v ps)"
say "disposable    : $WORK (removed on exit; lab homes minted by bin/fm-lab-home.sh)"

# --- fixtures ---------------------------------------------------------------
LAB=$(new_lab); LABS=("$LAB")
primary_fixture "$LAB"
: > "$WORK/keep-holder"
cat > "$WORK/holder.sh" <<'SH'
#!/usr/bin/env bash
set -u
REPO=$1 LAB=$2 FAKEBIN=$3 LOGS=$4 KEEP=$5 RC=$6 TRIG=$7
cd "$REPO" || exit 9
printf '%s\n' "$$" > "$LOGS/holder.pid"
env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID FM_HOME="$LAB" PATH="$FAKEBIN:$PATH" \
  bash bin/fm-lock.sh > "$LOGS/holder-acquire.log" 2>&1
printf '%s\n' "$?" > "$RC"
rm -f "$TRIG"
while [ -f "$KEEP" ]; do
  if [ -f "$TRIG" ]; then
    rm -f "$TRIG"
    env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID FM_HOME="$LAB" PATH="$FAKEBIN:$PATH" \
      bash bin/fm-lock.sh > "$LOGS/holder-reacquire.log" 2>&1
    printf '%s\n' "$?" > "$LOGS/holder-reacquire.rc"
  fi
  sleep 0.1
done
SH
chmod +x "$WORK/holder.sh"
start_named claude "$WORK/holder.sh" "$REPO" "$LAB" "$WORK/fakebin" "$WORK/logs" \
  "$WORK/keep-holder" "$WORK/logs/holder-acquire.rc" "$WORK/trigger-reacquire"
HOLDER=$LAST_PID
wait_file "$WORK/logs/holder-acquire.rc" 60 || bad "ps-denied session did not finish acquiring"

# ===========================================================================
sec "S1  A session whose ps cannot execute acquires and holds its lock"
say "shape: a real 'claude'-named process (symlink) runs the real bin/fm-lock.sh"
say "       with PATH's ps shadowed by a stub that exits 126 for every call."
say "       \$ PATH=$WORK/fakebin:\$PATH FM_HOME=$LAB bin/fm-lock.sh"
check_eq "1a ps-denied session acquires the lock (exit 0)" "$(cat "$WORK/logs/holder-acquire.rc")" 0
check_eq "1b lock names the live harness pid" "$(cat "$LAB/state/.lock")" "$HOLDER"
say "     acquire output: $(cat "$WORK/logs/holder-acquire.log")"
printf 'x\n' > "$WORK/trigger-reacquire"
wait_file "$WORK/logs/holder-reacquire.rc" 60 || bad "re-acquire did not finish"
check_eq "1c same live session re-acquires its own lock (holds, exit 0)" "$(cat "$WORK/logs/holder-reacquire.rc")" 0
check_has "1d re-acquire reports the same harness pid" "$(cat "$WORK/logs/holder-reacquire.log")" "harness pid $HOLDER"
check_eq "1e lock still names that pid" "$(cat "$LAB/state/.lock")" "$HOLDER"
status_out=$(FM_HOME="$LAB" PATH="$WORK/fakebin:$PATH" bash "$REPO/bin/fm-lock.sh" status 2>&1)
say "     status (ps denied): $status_out"
check_eq "1f lock status reports held by the live harness" "$status_out" "lock: held by live harness pid $HOLDER"
inbox_out=$(FM_HOME="$LAB" PATH="$WORK/fakebin:$PATH" bash "$REPO/bin/fm-inbox.sh" ready 2>&1 | tail -1)
say "     inbox ready (ps denied): $inbox_out"
case "$inbox_out" in
  *'"lock":{"state":"held","pid":'"$HOLDER"',"live_harness":true}'*) ok "1g inbox ready reports held/live_harness=true" ;;
  *) bad "1g inbox ready lock projection (got: $inbox_out)" ;;
esac
LIB="$REPO/bin/fm-session-lock-lib.sh"
ps_triple=$(bash -c '. "$1"; fm_proc_info "$2" || exit 1; printf "%s|%s|%s" "$FM_PROC_PPID" "$FM_PROC_COMM" "$FM_PROC_ARGS"' _ "$LIB" "$HOLDER")
proc_triple=$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID PATH="$WORK/fakebin:$PATH" bash -c '. "$1"; fm_proc_info "$2" || exit 1; printf "%s|%s|%s" "$FM_PROC_PPID" "$FM_PROC_COMM" "$FM_PROC_ARGS"' _ "$LIB" "$HOLDER")
say "     ps route   : $ps_triple"
say "     /proc route: $proc_triple"
check_eq "1h denied-ps /proc route reproduces the ps identity exactly" "$proc_triple" "$ps_triple"

# ===========================================================================
sec "S2  A live lock owner is never taken over (adversarial, both routes)"
: > "$WORK/keep-foreign"
cat > "$WORK/foreign.sh" <<'SH'
#!/usr/bin/env bash
set -u
REPO=$1 LAB=$2 FAKEBIN=$3 LOG=$4 KEEP=$5
cd "$REPO" || exit 9
env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID FM_HOME="$LAB" PATH="$FAKEBIN:$PATH" \
  bash bin/fm-lock.sh > "$LOG" 2>&1
printf '%s\n' "$?" > "$LOG.rc"
while [ -f "$KEEP" ]; do sleep 0.1; done
SH
chmod +x "$WORK/foreign.sh"
start_named codex "$WORK/foreign.sh" "$REPO" "$LAB" "$WORK/fakebin" "$WORK/logs/foreign-denied.log" "$WORK/keep-foreign"
wait_file "$WORK/logs/foreign-denied.log.rc" 60 || bad "foreign session did not finish on the denied route"
say "     denied-ps foreign attempt: rc=$(cat "$WORK/logs/foreign-denied.log.rc") $(cat "$WORK/logs/foreign-denied.log")"
check_eq "2a denied-ps second session is refused (exit 1)" "$(cat "$WORK/logs/foreign-denied.log.rc")" 1
check_has "2b refusal names the live owner" "$(cat "$WORK/logs/foreign-denied.log")" "another live firstmate session holds the lock (pid $HOLDER"
check_eq "2c denied-ps second session did not rewrite the lock" "$(cat "$LAB/state/.lock")" "$HOLDER"
env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID FM_HOME="$LAB" \
  "$WORK/named/codex" -c 'bash "$1/bin/fm-lock.sh" > "$2" 2>&1; echo "$?" > "$2.rc"' _ "$REPO" "$WORK/logs/foreign-ps.log"
say "     ps-route foreign attempt: rc=$(cat "$WORK/logs/foreign-ps.log.rc") $(cat "$WORK/logs/foreign-ps.log")"
check_eq "2d ps-route second session is refused identically (route parity)" \
  "$(cat "$WORK/logs/foreign-ps.log.rc")|$(cat "$WORK/logs/foreign-ps.log")" \
  "$(cat "$WORK/logs/foreign-denied.log.rc")|$(cat "$WORK/logs/foreign-denied.log")"
check_eq "2e ps-route second session did not rewrite the lock" "$(cat "$LAB/state/.lock")" "$HOLDER"
rm -f "$WORK/keep-foreign"

# ===========================================================================
sec "S3  An unreadable live owner blocks reclaim; a proven-dead owner is reclaimed"
REAL_PS=$(command -v ps)
mkdir -p "$WORK/shim1"
cat > "$WORK/shim1/ps" <<SH
#!/usr/bin/env bash
case " \$* " in
  *" -p \$FM_SHIM_OWNER "*) exit 126 ;;
esac
exec $REAL_PS "\$@"
SH
chmod +x "$WORK/shim1/ps"
say "shape: ps runs normally except for the owner pid, which it refuses with 126"
say "       (an EDR acting on one process), and the ps-free provider tree is empty,"
say "       so the owner's liveness is provable (kill -0) but its identity is not."
env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID FM_SHIM_OWNER="$HOLDER" \
  FM_PROC_ROOT_OVERRIDE="$WORK/emptyproc" FM_HOME="$LAB" PATH="$WORK/shim1:$PATH" \
  "$WORK/named/codex" -c 'bash "$1/bin/fm-lock.sh" > "$2" 2>&1; echo "$?" > "$2.rc"' _ "$REPO" "$WORK/logs/unreadable.log"
say "     unreadable-owner attempt: rc=$(cat "$WORK/logs/unreadable.log.rc") $(cat "$WORK/logs/unreadable.log")"
check_eq "3a live owner with unreadable identity is refused (exit 1)" "$(cat "$WORK/logs/unreadable.log.rc")" 1
check_has "3b refusal names the live owner" "$(cat "$WORK/logs/unreadable.log")" "another live firstmate session holds the lock (pid $HOLDER"
check_eq "3c unreadable live owner's lock was not replaced" "$(cat "$LAB/state/.lock")" "$HOLDER"
LAB2=$(new_lab); LABS+=("$LAB2")
printf '999999\n' > "$LAB2/state/.lock"
env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID FM_SHIM_OWNER=999999 \
  FM_PROC_ROOT_OVERRIDE="$WORK/emptyproc" FM_HOME="$LAB2" PATH="$WORK/shim1:$PATH" \
  "$WORK/named/codex" -c 'bash "$1/bin/fm-lock.sh" > "$2" 2>&1; echo "$?" > "$2.rc"' _ "$REPO" "$WORK/logs/dead-owner.log"
say "     proven-dead owner attempt: rc=$(cat "$WORK/logs/dead-owner.log.rc") $(cat "$WORK/logs/dead-owner.log")"
check_eq "3d proven-dead owner record is reclaimed (exit 0)" "$(cat "$WORK/logs/dead-owner.log.rc")" 0
[ "$(cat "$LAB2/state/.lock")" != 999999 ] && ok "3e dead record was replaced with the live session anchor" \
  || bad "3e dead record was not replaced"

# ===========================================================================
sec "S4  Malformed, empty, zero-valued, dead and reused records stay reclaimable"
LAB3=$(new_lab); LABS+=("$LAB3")
for record in '' '   ' 'not-a-pid' '0' '00' '000' '0000' 'win:' 'win:7abc'; do
  printf '%s\n' "$record" > "$LAB3/state/.lock"
  printf 'S1\n' > "$LAB3/state/.lock-session"
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID FM_HOME="$LAB3" PATH="$WORK/fakebin:$PATH" \
    "$WORK/named/claude" -c 'bash "$1/bin/fm-lock.sh" > "$2" 2>&1; echo "$?" > "$2.rc"' _ "$REPO" "$WORK/logs/record.log"
  rc=$(cat "$WORK/logs/record.log.rc")
  now=$(cat "$LAB3/state/.lock")
  if [ "$rc" = 0 ] && [ "$now" != "$record" ] && [ "$now" != '' ]; then
    ok "4 record '$record' reclaimed by a ps-denied session (lock -> $now)"
  else
    bad "4 record '$record' (rc=$rc lock='$now')"
  fi
done
sleep 60 & SLEEPER=$!
PIDS+=("$SLEEPER")
printf '%s\n' "$SLEEPER" > "$LAB3/state/.lock"
env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID FM_HOME="$LAB3" PATH="$WORK/fakebin:$PATH" \
  "$WORK/named/claude" -c 'bash "$1/bin/fm-lock.sh" > "$2" 2>&1; echo "$?" > "$2.rc"' _ "$REPO" "$WORK/logs/reused.log"
check_eq "4j a reused pid naming a live non-harness is reclaimed (exit 0)" "$(cat "$WORK/logs/reused.log.rc")" 0
[ "$(cat "$LAB3/state/.lock")" != "$SLEEPER" ] && ok "4k reused non-harness record was replaced" || bad "4k reused record kept"
kill "$SLEEPER" 2>/dev/null || true

# ===========================================================================
sec "S5  One shared verdict drives Stop auto-arm, both turn-end guards and inspection"
LAB6=$(new_lab); LABS+=("$LAB6")
primary_fixture "$LAB6"
cat > "$WORK/autoarm.sh" <<'SH'
#!/usr/bin/env bash
set -u
REPO=$1 LAB=$2 FAKEBIN=$3 LOG=$4
cd "$REPO" || exit 9
printf '' | env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u PI_CODING_AGENT \
  FM_HOME="$LAB" FM_ROOT_OVERRIDE="$LAB" PATH="$FAKEBIN:$PATH" \
  bash bin/fm-claude-stop-autoarm.sh > "$LOG" 2>&1
printf '%s\n' "$?" > "$LOG.rc"
SH
cat > "$WORK/guard-claude.sh" <<'SH'
#!/usr/bin/env bash
set -u
REPO=$1 LAB=$2 FAKEBIN=$3 LOG=$4
cd "$REPO" || exit 9
printf '{"session_id":"S2","transcript_path":"/tmp/not-a-real-transcript","stop_hook_active":true}' | \
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u PI_CODING_AGENT \
  FM_HOME="$LAB" FM_ROOT_OVERRIDE="$LAB" PATH="$FAKEBIN:$PATH" \
  bash bin/fm-turnend-guard.sh --claude > "$LOG" 2>&1
printf '%s\n' "$?" > "$LOG.rc"
SH
cat > "$WORK/guard-cursor.sh" <<'SH'
#!/usr/bin/env bash
set -u
REPO=$1 LAB=$2 FAKEBIN=$3 LOG=$4
cd "$REPO" || exit 9
printf '{"loop_count":0,"session_id":"S2","cursor_version":"1"}' | \
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u PI_CODING_AGENT \
  FM_HOME="$LAB" FM_ROOT_OVERRIDE="$LAB" PATH="$FAKEBIN:$PATH" \
  bash bin/fm-turnend-guard-cursor.sh > "$LOG" 2>&1
printf '%s\n' "$?" > "$LOG.rc"
SH
chmod +x "$WORK/autoarm.sh" "$WORK/guard-claude.sh" "$WORK/guard-cursor.sh"
run_in_codex() {  # <script> <label> : drives one hook as a child of a codex-named session
  "$WORK/named/codex" "$@" > /dev/null 2>&1
}
printf '%s\n' "$HOLDER" > "$LAB6/state/.lock"
run_in_codex "$WORK/autoarm.sh" "$REPO" "$LAB6" "$WORK/fakebin" "$WORK/logs/autoarm-live.log"
say "     autoarm, live foreign owner: rc=$(cat "$WORK/logs/autoarm-live.log.rc") output=[$(cat "$WORK/logs/autoarm-live.log")] lock=$(cat "$LAB6/state/.lock")"
check_eq "5a Stop auto-arm stands down for a live foreign owner (exit 0)" "$(cat "$WORK/logs/autoarm-live.log.rc")" 0
check_eq "5b Stop auto-arm left the live owner's lock untouched" "$(cat "$LAB6/state/.lock")" "$HOLDER"
run_in_codex "$WORK/guard-claude.sh" "$REPO" "$LAB6" "$WORK/fakebin" "$WORK/logs/guard-claude-live.log"
say "     claude guard, live foreign owner: rc=$(cat "$WORK/logs/guard-claude-live.log.rc")"
say "       $(cat "$WORK/logs/guard-claude-live.log")"
check_eq "5c Claude turn-end guard ends the turn safely (exit 0)" "$(cat "$WORK/logs/guard-claude-live.log.rc")" 0
check_has "5d guard reports the shared foreign-owner verdict naming the owner pid" \
  "$(cat "$WORK/logs/guard-claude-live.log")" "OWNED BY ANOTHER LIVE SESSION"
check_has "5e guard names the live lock owner pid $HOLDER" "$(cat "$WORK/logs/guard-claude-live.log")" "lock owner pid $HOLDER"
check_eq "5f Claude guard did not rewrite the lock" "$(cat "$LAB6/state/.lock")" "$HOLDER"
run_in_codex "$WORK/guard-cursor.sh" "$REPO" "$LAB6" "$WORK/fakebin" "$WORK/logs/guard-cursor-live.log"
check_eq "5g Cursor turn-end guard stands down for the live owner (exit 0)" "$(cat "$WORK/logs/guard-cursor-live.log.rc")" 0
check_eq "5h Cursor guard emits no repair nag for a live owner" "$(cat "$WORK/logs/guard-cursor-live.log")" ""
check_eq "5i Cursor guard left the live owner's lock untouched" "$(cat "$LAB6/state/.lock")" "$HOLDER"
# Contrast: the same hooks DO reclaim a proven-dead record, so 5a-5i are not inert.
printf '999999\n' > "$LAB6/state/.lock"
run_in_codex "$WORK/guard-cursor.sh" "$REPO" "$LAB6" "$WORK/fakebin" "$WORK/logs/guard-cursor-dead.log"
say "     cursor guard, dead owner record: rc=$(cat "$WORK/logs/guard-cursor-dead.log.rc") lock=$(cat "$LAB6/state/.lock")"
[ "$(cat "$LAB6/state/.lock")" != 999999 ] && ok "5j dead-owner contrast: the same guard reclaims the lock" \
  || bad "5j dead-owner contrast: guard left the dead record in place"
printf '999999\n' > "$LAB6/state/.lock"
run_in_codex "$WORK/autoarm.sh" "$REPO" "$LAB6" "$WORK/fakebin" "$WORK/logs/autoarm-dead.log"
say "     autoarm, dead owner record: rc=$(cat "$WORK/logs/autoarm-dead.log.rc") lock=$(cat "$LAB6/state/.lock")"
[ "$(cat "$LAB6/state/.lock")" != 999999 ] && ok "5k dead-owner contrast: auto-arm recovers the lock" \
  || bad "5k dead-owner contrast: auto-arm left the dead record in place"

# ===========================================================================
sec "S6  UTF-8 Cursor owner identity survives the denied-ps route (regression fix)"
mkdir -p "$WORK/José/.local/bin" "$WORK/cursor-agent/versions/test"
cp "$(command -v bash)" "$WORK/cursor-agent/versions/test/cursor-agent"
ln -s "$WORK/cursor-agent/versions/test/cursor-agent" "$WORK/José/.local/bin/agent"
cat > "$WORK/cursor-owner.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "$$" > "$1"
while [ -f "$2" ]; do sleep 0.1; done
SH
chmod +x "$WORK/cursor-owner.sh"
: > "$WORK/keep-cursor"
"$WORK/José/.local/bin/agent" "$WORK/cursor-owner.sh" "$WORK/logs/cursor.pid" "$WORK/keep-cursor" >/dev/null 2>&1 &
CURSOR=$!
PIDS+=("$CURSOR")
wait_file "$WORK/logs/cursor.pid" 30 || bad "cursor fixture did not start"
CURSOR=$(cat "$WORK/logs/cursor.pid")
say "     live Cursor alias: pid=$CURSOR comm=$(cat "/proc/$CURSOR/comm") argv0=$(tr '\0' '\n' < "/proc/$CURSOR/cmdline" | head -1)"
ps_c=$(bash -c '. "$1"; fm_proc_info "$2" || exit 1; printf "%s|%s" "$FM_PROC_COMM" "$FM_PROC_ARGS"' _ "$LIB" "$CURSOR")
proc_c=$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID PATH="$WORK/fakebin:$PATH" bash -c '. "$1"; fm_proc_info "$2" || exit 1; printf "%s|%s" "$FM_PROC_COMM" "$FM_PROC_ARGS"' _ "$LIB" "$CURSOR")
say "     ps route   : $ps_c"
say "     /proc route: $proc_c"
check_eq "6a UTF-8 Cursor identity is byte-identical on both routes" "$proc_c" "$ps_c"
check_has "6b /proc route kept the UTF-8 path bytes (no '?')" "$proc_c" "José"
LAB7=$(new_lab); LABS+=("$LAB7")
printf '%s\n' "$CURSOR" > "$LAB7/state/.lock"
printf 'S1\n' > "$LAB7/state/.lock-session"
cat > "$WORK/takeover.sh" <<'SH'
#!/usr/bin/env bash
set -u
REPO=$1 LAB=$2 FAKEBIN=$3 LOG=$4 KEEP=$5
cd "$REPO" || exit 9
env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID FM_HOME="$LAB" PATH="$FAKEBIN:$PATH" \
  bash bin/fm-lock.sh > "$LOG" 2>&1
printf '%s\n' "$?" > "$LOG.rc"
while [ -f "$KEEP" ]; do sleep 0.1; done
SH
chmod +x "$WORK/takeover.sh"
: > "$WORK/keep-take1"
start_named claude "$WORK/takeover.sh" "$REPO" "$LAB7" "$WORK/fakebin" "$WORK/logs/utf8-head.log" "$WORK/keep-take1"
wait_file "$WORK/logs/utf8-head.log.rc" 60 || bad "UTF-8 takeover attempt (HEAD) did not finish"
say "     HEAD takeover attempt: rc=$(cat "$WORK/logs/utf8-head.log.rc") $(cat "$WORK/logs/utf8-head.log")"
check_eq "6c HEAD: live UTF-8 Cursor owner is not taken over (exit 1)" "$(cat "$WORK/logs/utf8-head.log.rc")" 1
check_eq "6d HEAD: the Cursor owner's lock is unchanged" "$(cat "$LAB7/state/.lock")" "$CURSOR"
rm -f "$WORK/keep-take1"
# Same HEAD source with only the two byte-range fixes reverted: the defect the
# last commit repaired, reproduced through the same real entry point.
mkdir -p "$WORK/prefix-repo" && git -C "$REPO" archive HEAD | tar -x -C "$WORK/prefix-repo"
python3 - "$WORK/prefix-repo/bin/fm-session-lock-lib.sh" <<'REVERT'
import sys
path = sys.argv[1]
text = open(path, encoding='utf-8').read()
old = "tr -c '\\040-\\176\\200-\\377' '?'"
new = "tr -c '\\040-\\176' '?'"
assert text.count(old) == 2, text.count(old)
open(path, 'w', encoding='utf-8').write(text.replace(old, new))
REVERT
say "     pre-fix sanitizer in the disposable checkout:"
grep -n "tr -c " "$WORK/prefix-repo/bin/fm-session-lock-lib.sh" | sed 's/^/       /'
LAB8=$(new_lab); LABS+=("$LAB8")
printf '%s\n' "$CURSOR" > "$LAB8/state/.lock"
printf 'S1\n' > "$LAB8/state/.lock-session"
: > "$WORK/keep-take2"
start_named claude "$WORK/takeover.sh" "$WORK/prefix-repo" "$LAB8" "$WORK/fakebin" "$WORK/logs/utf8-prefix.log" "$WORK/keep-take2"
wait_file "$WORK/logs/utf8-prefix.log.rc" 60 || bad "UTF-8 takeover attempt (pre-fix) did not finish"
say "     pre-fix sanitizer attempt: rc=$(cat "$WORK/logs/utf8-prefix.log.rc") $(cat "$WORK/logs/utf8-prefix.log")"
check_eq "6e pre-fix sanitizer: the same live Cursor owner IS taken over (defect reproduced)" \
  "$(cat "$WORK/logs/utf8-prefix.log.rc")" 0
[ "$(cat "$LAB8/state/.lock")" != "$CURSOR" ] && ok "6f pre-fix: lock was replaced by a competing session" \
  || bad "6f pre-fix: lock unexpectedly kept"

# ===========================================================================
sec "S7  Whole session start on a ps-denied host (user story vs base commit)"
cat > "$WORK/sessionstart.sh" <<'SH'
#!/usr/bin/env bash
set -u
REPO=$1 LAB=$2 FAKEBIN=$3 LOG=$4 KEEP=$5
cd "$REPO" || exit 9
printf '%s\n' "$$" > "$LOG.pid"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID \
  FM_HOME="$LAB" PATH="$FAKEBIN:$PATH" timeout 150 bash bin/fm-session-start.sh > "$LOG" 2>&1
printf '%s\n' "$?" > "$LOG.rc"
while [ -f "$KEEP" ]; do sleep 0.1; done
SH
chmod +x "$WORK/sessionstart.sh"
LAB9=$(new_lab); LABS+=("$LAB9")
: > "$WORK/keep-head-ss"
start_named claude "$WORK/sessionstart.sh" "$REPO" "$LAB9" "$WORK/fakebin" "$WORK/logs/ss-head.log" "$WORK/keep-head-ss"
wait_file "$WORK/logs/ss-head.log.rc" 180 || bad "HEAD session start did not finish"
say "     HEAD session start: rc=$(cat "$WORK/logs/ss-head.log.rc") lock=[$(cat "$LAB9/state/.lock" 2>/dev/null)]"
sed -n '/^LOCK$/,/^HOME ROLE$/p' "$WORK/logs/ss-head.log" | sed 's/^/       /'
check_has "7a HEAD session start acquires the fleet lock under a denied ps" \
  "$(cat "$WORK/logs/ss-head.log")" "lock acquired: harness pid $(cat "$WORK/logs/ss-head.log.pid")"
check_eq "7b HEAD session start wrote the live harness pid to state/.lock" \
  "$(cat "$LAB9/state/.lock")" "$(cat "$WORK/logs/ss-head.log.pid")"
case "$(cat "$WORK/logs/ss-head.log")" in
  *"READ-ONLY SESSION - FLEET LOCK OWNERSHIP WAS NOT VERIFIED"*) bad "7c HEAD session start still reported read-only" ;;
  *) ok "7c HEAD session start did not take the read-only path" ;;
esac
rm -f "$WORK/keep-head-ss"
mkdir -p "$WORK/base-repo" && git -C "$REPO" archive "$BASE_COMMIT" | tar -x -C "$WORK/base-repo"
LAB10=$(new_lab); LABS+=("$LAB10")
: > "$WORK/keep-base-ss"
start_named claude "$WORK/sessionstart.sh" "$WORK/base-repo" "$LAB10" "$WORK/fakebin" "$WORK/logs/ss-base.log" "$WORK/keep-base-ss"
wait_file "$WORK/logs/ss-base.log.rc" 180 || bad "base session start did not finish"
say "     base session start: rc=$(cat "$WORK/logs/ss-base.log.rc") lock=[$(cat "$LAB10/state/.lock" 2>/dev/null)]"
sed -n '/^LOCK$/,/^HOME ROLE$/p' "$WORK/logs/ss-base.log" | sed 's/^/       /'
check_has "7d base commit reproduces the reported read-only wedge" \
  "$(cat "$WORK/logs/ss-base.log")" "READ-ONLY SESSION - FLEET LOCK OWNERSHIP WAS NOT VERIFIED"
check_eq "7e base commit wrote no lock on the same ps-denied host" "$(cat "$LAB10/state/.lock" 2>/dev/null)" ""
rm -f "$WORK/keep-base-ss"

sec "RESULT"
if [ "$FAILS" -eq 0 ]; then say "ALL LIVE CHECKS PASSED"; else say "$FAILS LIVE CHECK(S) FAILED"; fi
exit "$FAILS"
