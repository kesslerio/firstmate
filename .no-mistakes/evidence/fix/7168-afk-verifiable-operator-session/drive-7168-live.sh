#!/usr/bin/env bash
# drive-7168-live.sh - live end-user drive of the #7168 away-supervision change.
#
# Runs INSIDE a disposable firstmate lab tmux pane (private socket) whose shell
# carries the Claude harness marker, so every call below is the real product
# CLI (bin/fm-afk-launch.sh / bin/fm-afk-start.sh) in a Claude primary.
# Each scenario gets its own marked disposable lab home under $TR and prints
# PASS/FAIL lines that the outer capture log records.
set -u
# This script lives in the evidence dir, so the run worktree is passed in.
ROOT=${FM_REPO_ROOT:?set FM_REPO_ROOT to the run worktree}
cd "$ROOT" || exit 1
TR=$(mktemp -d "${TMPDIR:-/tmp}/fm-7168-live.XXXXXX") || exit 1
echo "TR=$TR"
echo "harness=$(bin/fm-harness.sh) TMUX_PANE=${TMUX_PANE:-<unset>} TMUX=${TMUX:-<unset>}"

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf 'PASS: %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf 'FAIL: %s\n' "$*"; }
sec()  { printf '\n===== %s\n' "$*"; }

# Every operator-session marker cleared: a plain terminal hosting no
# tmux/herdr/Rex/Orca/T3 session - the "no verifiable operator session" case.
nose() { env -u TMUX -u TMUX_PANE -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_SESSION \
  -u REX_SESSION -u REX_BLOCK -u ORCA_TERMINAL_HANDLE \
  -u FM_SUPERVISOR_TARGET -u FM_SUPERVISOR_BACKEND "$@"; }
# The ambient pane env (real TMUX_PANE), without a pinned supervisor override.
innermost() { env -u FM_SUPERVISOR_TARGET -u FM_SUPERVISOR_BACKEND "$@"; }

fresh_home() {  # <label> -> echoes home path
  local h="$TR/$1"
  "$ROOT/bin/fm-lab-home.sh" create "$h" >/dev/null || return 1
  : > "$h/config/supervision-host-off"
  FM_HOME="$h" "$ROOT/bin/fm-afk-launch.sh" enter --words 'live 7168 scenario' >/dev/null 2>&1 || return 1
  printf '%s' "$h"
}

# ---------------------------------------------------------------- scenario 1
sec "S1 gap1: start-native from a session with no operator session"
H1=$(fresh_home s1) || bad "s1: could not mint lab home"
BEFORE=$(cksum < "$H1/state/.afk-contract")
OUT1=$(nose FM_HOME="$H1" bin/fm-afk-launch.sh start-native 2>&1); RC1=$?
printf '%s\n' "rc=$RC1" "$OUT1"
echo "state:"; ls -a "$H1/state"
if [ "$RC1" -ne 0 ] && [ ! -e "$H1/state/.afk" ] && [ ! -e "$H1/state/.afk-daemon-terminal" ] \
  && printf '%s' "$OUT1" | grep -F 'verifiable operator session' >/dev/null \
  && printf '%s' "$OUT1" | grep -F 'refusing to arm away mode' >/dev/null \
  && [ "$(cksum < "$H1/state/.afk-contract")" = "$BEFORE" ]; then
  ok "s1 native entry refuses before state/.afk with no operator session"
else
  bad "s1 native entry armed or did not refuse (rc=$RC1)"
fi

# ---------------------------------------------------------------- scenario 2
sec "S2 gap1: the same native entry still arms from a real tmux pane"
OUT2=$(innermost FM_HOME="$H1" bin/fm-afk-launch.sh start-native 2>&1); RC2=$?
printf '%s\n' "rc=$RC2" "$OUT2"
echo "--- .afk:"; cat "$H1/state/.afk" 2>&1
echo "--- daemon terminal record:"; tr '\t' ' ' < "$H1/state/.afk-daemon-terminal" 2>&1
if [ "$RC2" -eq 0 ] && [ "$(head -n 1 "$H1/state/.afk" 2>/dev/null)" = away ] \
  && [ "$(tr '\t' ' ' < "$H1/state/.afk-daemon-terminal" 2>/dev/null)" = 'none - native' ]; then
  ok "s2 a supported tmux session arms and records 'none - native'"
else
  bad "s2 supported session was refused or recorded wrong (rc=$RC2)"
fi

# ---------------------------------------------------------------- scenario 3
sec "S3 gap1: a resolved-but-nonexistent endpoint is refused before arming"
H3=$(fresh_home s3) || bad "s3: could not mint lab home"
for ACTION in start start-native; do
  OUT3=$(innermost FM_HOME="$H3" FM_SUPERVISOR_TARGET=no-such-session:0 FM_SUPERVISOR_BACKEND=tmux \
    bin/fm-afk-launch.sh "$ACTION" 2>&1); RC3=$?
  printf '%s\n' "[$ACTION] rc=$RC3" "$OUT3"
  if [ "$RC3" -ne 0 ] && [ ! -e "$H3/state/.afk" ] && [ ! -e "$H3/state/.afk-daemon-terminal" ] \
    && printf '%s' "$OUT3" | grep -F "supervisor target 'no-such-session:0' does not resolve to a tmux endpoint" >/dev/null; then
    ok "s3 $ACTION refuses an unresolvable supervisor target before arming"
  else
    bad "s3 $ACTION armed with an unresolvable target (rc=$RC3)"
  fi
done

# ---------------------------------------------------------------- scenario 4
sec "S4 gap1: a refused refresh preserves the prior armed lifecycle byte-for-byte"
H4=$(fresh_home s4) || bad "s4: could not mint lab home"
printf 'away\n1793424136\n' > "$H4/state/.afk"
printf 'escalation-digest\n' > "$H4/state/.subsuper-escalations"
printf '1793424000\n' > "$H4/state/.subsuper-escalations.since"
printf 'stale\n' > "$H4/state/.subsuper-reported-stale-abc123"
B4=$(cd "$H4/state" && cksum .afk .subsuper-escalations .subsuper-escalations.since .subsuper-reported-stale-abc123)
OUT4=$(nose FM_HOME="$H4" bin/fm-afk-launch.sh start-native 2>&1); RC4=$?
printf '%s\n' "rc=$RC4" "$OUT4"
A4=$(cd "$H4/state" && cksum .afk .subsuper-escalations .subsuper-escalations.since .subsuper-reported-stale-abc123)
echo "before: $B4"; echo "after:  $A4"
if [ "$RC4" -ne 0 ] && [ "$B4" = "$A4" ] && [ ! -e "$H4/state/.afk-daemon-terminal" ]; then
  ok "s4 refused refresh left the armed flag and stale escalation artifacts untouched"
else
  bad "s4 refused refresh rewrote the away lifecycle (rc=$RC4)"
fi

# ---------------------------------------------------------------- scenario 5
sec "S5 gap2: an Orca primary is refused by name on both launcher paths"
H5=$(fresh_home s5) || bad "s5: could not mint lab home"
for ACTION in start start-native; do
  OUT5=$(nose ORCA_TERMINAL_HANDLE=term_abc123 FM_HOME="$H5" \
    bin/fm-afk-launch.sh "$ACTION" 2>&1); RC5=$?
  printf '%s\n' "[$ACTION] rc=$RC5" "$OUT5"
  if [ "$RC5" -ne 0 ] && [ ! -e "$H5/state/.afk" ] \
    && printf '%s' "$OUT5" | grep -F "does not support supervisor backend 'orca'" >/dev/null \
    && ! printf '%s' "$OUT5" | grep -F 'does not resolve to a tmux' >/dev/null; then
    ok "s5 $ACTION recognizes the Orca terminal and refuses orca by name, before arming"
  else
    bad "s5 $ACTION did not give the documented Orca refusal (rc=$RC5)"
  fi
done

# ---------------------------------------------------------------- scenario 6
sec "S6 gap2: the away daemon refuses orca at startup and logs the source"
OUT6=$(nose ORCA_TERMINAL_HANDLE=term_abc123 FM_HOME="$H5" FM_STATE_OVERRIDE="$H5/state" \
  bin/fm-afk-start.sh 2>&1); RC6=$?
printf '%s\n' "rc=$RC6" "$OUT6"
echo "--- state/.supervise-daemon.log:"; cat "$H5/state/.supervise-daemon.log" 2>&1 | tail -5
if [ "$RC6" -ne 0 ] \
  && printf '%s' "$OUT6" | grep -F "does not support supervisor backend 'orca'" >/dev/null \
  && grep -F "unsupported supervisor backend 'orca' (source=ORCA_TERMINAL_HANDLE)" \
       "$H5/state/.supervise-daemon.log" >/dev/null 2>&1; then
  ok "s6 daemon startup names orca and logs source=ORCA_TERMINAL_HANDLE instead of aiming at tmux"
else
  bad "s6 daemon startup did not refuse orca by name (rc=$RC6)"
fi

# ---------------------------------------------------------------- scenario 7
sec "S7 gap2: an innermost tmux pane inside an Orca terminal keeps tmux (not refused)"
H7=$(fresh_home s7) || bad "s7: could not mint lab home"
OUT7=$(innermost ORCA_TERMINAL_HANDLE=term_abc123 FM_HOME="$H7" bin/fm-afk-launch.sh start-native 2>&1); RC7=$?
printf '%s\n' "rc=$RC7" "$OUT7"
if [ "$RC7" -eq 0 ] && [ "$(head -n 1 "$H7/state/.afk" 2>/dev/null)" = away ] \
  && ! printf '%s' "$OUT7" | grep -F 'orca' >/dev/null; then
  ok "s7 a tmux session nested in Orca keeps its own transport and arms"
else
  bad "s7 a tmux session inside Orca was refused or mis-recorded (rc=$RC7)"
fi

# ---------------------------------------------------------------- scenario 8
sec "S8 one supported-backend list: an unsupported backend refuses on both paths"
H8=$(fresh_home s8) || bad "s8: could not mint lab home"
for ACTION in start start-native; do
  OUT8=$(nose FM_HOME="$H8" FM_SUPERVISOR_TARGET=whatever:9 FM_SUPERVISOR_BACKEND=zellij \
    bin/fm-afk-launch.sh "$ACTION" 2>&1); RC8=$?
  printf '%s\n' "[$ACTION] rc=$RC8" "$OUT8"
  if [ "$RC8" -ne 0 ] && [ ! -e "$H8/state/.afk" ] \
    && printf '%s' "$OUT8" | grep -F "does not support supervisor backend 'zellij'" >/dev/null; then
    ok "s8 $ACTION refuses the unsupported backend from the shared list before arming"
  else
    bad "s8 $ACTION did not refuse zellij pre-flag (rc=$RC8)"
  fi
done

# ---------------------------------------------------------------- scenario 9
sec "S9 end-to-end: start launches the daemon in a detached tmux terminal, stop tears it down"
H9=$(fresh_home s9) || bad "s9: could not mint lab home"
OUT9=$(innermost FM_HOME="$H9" bin/fm-afk-launch.sh start 2>&1); RC9=$?
printf '%s\n' "rc=$RC9" "$OUT9"
echo "--- daemon terminal record:"; tr '\t' ' ' < "$H9/state/.afk-daemon-terminal" 2>&1
echo "--- lab tmux sessions:"; tmux list-sessions 2>&1
sleep 3
OUT9B=$(innermost FM_HOME="$H9" bin/fm-afk-launch.sh stop 2>&1); RC9B=$?
printf '%s\n' "[stop] rc=$RC9B" "$OUT9B"
echo "--- state after stop:"; ls -a "$H9/state"
echo "--- lab tmux sessions after stop:"; tmux list-sessions 2>&1
if [ "$RC9" -eq 0 ] && [ "$(head -n 1 "$H9/state/afk-contracts/"* 2>/dev/null | head -1)" != "" ] \
  && [ ! -e "$H9/state/.afk" ] && [ "$RC9B" -eq 0 ]; then
  ok "s9 start armed and launched a real daemon terminal; stop cleared .afk and archived the record"
else
  bad "s9 end-to-end start/stop did not complete (start=$RC9 stop=$RC9B)"
fi

printf '\n===== SUMMARY pass=%s fail=%s\n' "$PASS" "$FAIL"
echo "TR=$TR (left for the outer teardown)"
[ "$FAIL" -eq 0 ]
