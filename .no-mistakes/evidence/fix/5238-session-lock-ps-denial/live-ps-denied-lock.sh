#!/usr/bin/env bash
# Live validation driver for fix/5238-session-lock-ps-denial.
#
# Drives the REAL product entrypoints (bin/fm-lock.sh, bin/fm-inbox.sh, and the
# real Claude Stop hook) against a disposable lab home with the ps BINARY denied
# on PATH (a shim that exits 126, the status bash returns for a refused exec -
# the EDR-denial class this change exists for). Every owner pid used as a lock
# record is a REAL live or dead process, and the identity the fallback reads
# comes from the REAL /proc tree on this host.
#
# Usage: bash live-ps-denied-lock.sh
# Exits 0 only when every assertion below passed.
set -u

REPO=/home/art/.no-mistakes/worktrees/9f75ec418609/01M68Y5XF21SCWJ2DHXKVJASRW
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX") || exit 1
DENY="$LAB/denied"
BASELINE=$(mktemp -d "${TMPDIR:-/tmp}/fm-base.XXXXXX")
BASE_COMMIT=bb3e6906548b5c03d3212e9f060bafde982e0cf1
FIXTURE_PIDS=()
FAILED=0

cleanup() {
  local pid
  for pid in ${FIXTURE_PIDS[@]+"${FIXTURE_PIDS[@]}"}; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  # Any keeper a hook started through the lab home, by exact lab path.
  for pid in $(ps -eo pid=,args= 2>/dev/null | grep -F "$LAB" | grep -v grep | awk '{print $1}'); do
    kill -TERM "$pid" 2>/dev/null || true
  done
  "$REPO/bin/fm-lab-home.sh" teardown "$LAB" >/dev/null 2>&1 || true
  rm -rf "$LAB" "$BASELINE"
}
trap cleanup EXIT

step() { printf '\n===== %s =====\n' "$*"; }
ok() { printf 'PASS: %s\n' "$*"; }
bad() { printf 'FAIL: %s\n' "$*"; FAILED=1; }
check() {  # <description> <condition...>
  local what=$1
  shift
  if "$@"; then ok "$what"; else bad "$what"; fi
}

# --- disposable lab home + a denied ps --------------------------------------
"$REPO/bin/fm-lab-home.sh" create "$LAB" >/dev/null || exit 1
mkdir -p "$LAB/bin" "$LAB/tmux" "$DENY"
ln -s "$(command -v bash)" "$LAB/bin/claude"
cat > "$DENY/ps" <<'SH'
#!/usr/bin/env bash
echo "$0: Operation not permitted" >&2
exit 126
SH
chmod +x "$DENY/ps"
echo "lab home: $LAB"
echo "denied ps: $(PATH="$DENY:$PATH" ps -V 2>&1; echo "rc=$?")"

# A real live verified harness: bash exec'd through a path named claude, so the
# kernel comm is "claude" and argv[0] is that path - the same identity shape a
# real Claude Code session presents, and readable from /proc without ps.
start_harness() {
  "$LAB/bin/claude" -c 'while :; do sleep 1; done' >/dev/null 2>&1 &
  local pid=$! i=0
  FIXTURE_PIDS+=("$pid")
  while [ ! -d "/proc/$pid" ] && [ "$i" -lt 40 ]; do sleep 0.05; i=$((i + 1)); done
  printf '%s\n' "$pid"
}
start_sleeper() {
  sleep 600 >/dev/null 2>&1 &
  local pid=$! i=0
  FIXTURE_PIDS+=("$pid")
  while [ ! -d "/proc/$pid" ] && [ "$i" -lt 40 ]; do sleep 0.05; i=$((i + 1)); done
  printf '%s\n' "$pid"
}
record_owner() {  # <pid>
  printf '%s\n' "$1" > "$LAB/state/.lock"
  printf 'S1\n' > "$LAB/state/.lock-session"
}
# Run the real acquisition entrypoint as a harness-named session whose ancestry
# is only itself (setsid), with the denied ps on PATH. Extra VAR=VALs pass
# through env.
acquire_denied() {
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID FM_HOME="$LAB" "$@" \
    setsid --wait "$LAB/bin/claude" -c \
    "export PATH=\"$DENY:\$PATH\"; exec \"$REPO/bin/fm-lock.sh\""
}
status_denied() {
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID FM_HOME="$LAB" PATH="$DENY:$PATH" \
    "$REPO/bin/fm-lock.sh" status
}
status_normal() {
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID FM_HOME="$LAB" \
    "$REPO/bin/fm-lock.sh" status
}

# --- 1. a live verified harness owner is never taken over -------------------
step "denied ps: live verified harness owner must be refused"
HARNESS=$(start_harness)
echo "live harness pid $HARNESS comm=$(ps -o comm= -p "$HARNESS") args=$(ps -o args= -p "$HARNESS" | cut -c1-80)"
record_owner "$HARNESS"
out=$(acquire_denied 2>&1); rc=$?
printf 'acquire rc=%s\n%s\nlock now: %s\n' "$rc" "$out" "$(cat "$LAB/state/.lock")"
check "acquisition refused with exit 1" [ "$rc" -eq 1 ]
check "refusal names the live owner and its session" \
  grep -q "another live firstmate session holds the lock (pid $HARNESS, session S1)" <<<"$out"
check "the live owner's lock was left untouched" [ "$(cat "$LAB/state/.lock")" = "$HARNESS" ]

# --- 2. a dead owner record is reclaimed (no read-only wedge) ---------------
step "denied ps: dead owner record must be reclaimed"
DEAD=$(bash -c 'echo $$')
while kill -0 "$DEAD" 2>/dev/null; do sleep 0.05; done
echo "dead pid $DEAD is gone"
record_owner "$DEAD"
out=$(acquire_denied 2>&1); rc=$?
new=$(cat "$LAB/state/.lock")
printf 'acquire rc=%s\n%s\nlock now: %s\n' "$rc" "$out" "$new"
check "acquisition succeeded" [ "$rc" -eq 0 ]
check "acquisition reported the claimed harness pid" grep -q '^lock acquired: harness pid [0-9]' <<<"$out"
check "the dead record was replaced" [ "$new" != "$DEAD" ]
check "the new owner is a live process" kill -0 "$new"

# --- 3. a live non-harness pid (reused record) is reclaimable --------------
step "denied ps: live non-harness owner must be reclaimed"
SLEEPER=$(start_sleeper)
echo "live non-harness pid $SLEEPER comm=$(ps -o comm= -p "$SLEEPER")"
record_owner "$SLEEPER"
out=$(acquire_denied 2>&1); rc=$?
new=$(cat "$LAB/state/.lock")
printf 'acquire rc=%s\n%s\nlock now: %s\n' "$rc" "$out" "$new"
check "acquisition succeeded over the reused non-harness pid" [ "$rc" -eq 0 ]
check "the non-harness record was replaced" [ "$new" != "$SLEEPER" ]

# --- 4. a live owner whose identity cannot be read still blocks reclaim ----
# The owner stays a real live process this user may signal, but its /proc entry
# is masked inside an unprivileged bwrap mount namespace, so the ps-free route
# genuinely cannot read its identity. A control run in the SAME sandbox masks an
# unrelated pid and still reclaims, which proves the mask - not bwrap - is what
# blocks the reclaim.
step "denied ps: live owner with unreadable identity must be refused"
masked_acquire() {  # <pid-to-mask>
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID FM_HOME="$LAB" \
    bwrap --dev-bind / / --ro-bind /proc /proc --tmpfs "/proc/$1" \
    setsid --wait "$LAB/bin/claude" -c \
    "export PATH=\"$DENY:\$PATH\"; exec \"$REPO/bin/fm-lock.sh\""
}
record_owner "$SLEEPER"
out=$(masked_acquire "$SLEEPER" 2>&1); rc=$?
printf 'masked owner -> acquire rc=%s\n%s\nlock now: %s\n' "$rc" "$out" "$(cat "$LAB/state/.lock")"
check "acquisition refused a live owner whose identity cannot be read" [ "$rc" -eq 1 ]
check "the unreadable owner's lock was left untouched" [ "$(cat "$LAB/state/.lock")" = "$SLEEPER" ]
DECOY=$(start_sleeper)
record_owner "$SLEEPER"
out=$(masked_acquire "$DECOY" 2>&1); rc=$?
printf 'control mask  -> acquire rc=%s\n%s\nlock now: %s\n' "$rc" "$out" "$(cat "$LAB/state/.lock")"
check "the same sandbox still reclaims when the owner is readable" [ "$rc" -eq 0 ]
check "the readable non-harness owner was replaced" [ "$(cat "$LAB/state/.lock")" != "$SLEEPER" ]

# --- 5. status reports a held lock on the fallback route -------------------
step "denied ps: fm-lock.sh status reports the live harness as held"
record_owner "$HARNESS"
st=$(status_denied)
printf '%s\n' "$st"
check "status reports held by the live harness" [ "$st" = "lock: held by live harness pid $HARNESS" ]

# The same inspect verdict feeds fm-inbox.sh ready, the machine-readable
# consumer of the lock state.
ready_denied=$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID FM_HOME="$LAB" PATH="$DENY:$PATH" \
  "$REPO/bin/fm-inbox.sh" ready)
printf 'ready (denied ps): %s\n' "$ready_denied"
check "denied ps: inbox ready reports lock.state=held" \
  python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["lock"]["state"]=="held" else 1)' <<<"$ready_denied"
check "denied ps: inbox ready reports live_harness=true" \
  python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["lock"]["live_harness"] is True else 1)' <<<"$ready_denied"

# --- 6. normal ps route: status and inbox ready agree ----------------------
step "working ps: status and inbox ready report the live harness holder"
st=$(status_normal)
ready=$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID FM_HOME="$LAB" "$REPO/bin/fm-inbox.sh" ready)
printf 'status: %s\nready: %s\n' "$st" "$ready"
check "status reports held by the live harness" [ "$st" = "lock: held by live harness pid $HARNESS" ]
check "inbox ready reports lock.state=held" \
  python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["lock"]["state"]=="held" else 1)' <<<"$ready"
check "inbox ready reports live_harness=true" \
  python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if d["lock"]["live_harness"] is True else 1)' <<<"$ready"
check "inbox ready reports the harness pid" \
  python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d['lock']['pid']==$HARNESS else 1)" <<<"$ready"

# --- 7. all-zero lock records stay reclaimable -----------------------------
step "denied ps: all-zero lock records must be reclaimed"
for rec in 0 00 000 0000; do
  record_owner "$rec"
  out=$(acquire_denied 2>&1); rc=$?
  new=$(cat "$LAB/state/.lock")
  printf 'record %-4s -> rc=%s lock=%s %s\n' "'$rec'" "$rc" "$new" "$(head -1 <<<"$out")"
  check "zero-form record '$rec' was reclaimed" [ "$rc" -eq 0 ]
  check "zero-form record '$rec' no longer holds the lock" [ "$new" != "$rec" ]
done

# --- 8. a live Cursor owner reached through a UTF-8 alias still holds ------
step "denied ps: live Cursor owner under a UTF-8 path must be refused"
UTF="$LAB/José/.local/bin"
mkdir -p "$UTF" "$LAB/cursor-agent/versions/2026.1"
cp "$(command -v bash)" "$LAB/cursor-agent/versions/2026.1/cursor-agent"
chmod 755 "$LAB/cursor-agent/versions/2026.1/cursor-agent"
ln -sfn "$LAB/cursor-agent/versions/2026.1/cursor-agent" "$UTF/agent"
"$UTF/agent" -c 'while :; do sleep 1; done' &
CURSOR=$!
FIXTURE_PIDS+=("$CURSOR")
i=0
while [ ! -d "/proc/$CURSOR" ] && [ "$i" -lt 40 ]; do sleep 0.05; i=$((i + 1)); done
echo "live Cursor alias pid $CURSOR comm=$(ps -o comm= -p "$CURSOR") argv0=$(ps -o args= -p "$CURSOR" | cut -d' ' -f1)"
record_owner "$CURSOR"
st_normal=$(status_normal)
st_denied=$(status_denied)
printf 'status (ps): %s\nstatus (denied): %s\n' "$st_normal" "$st_denied"
check "ps route reports the UTF-8 Cursor owner as held" [ "$st_normal" = "lock: held by live harness pid $CURSOR" ]
check "fallback route reports the UTF-8 Cursor owner as held" [ "$st_denied" = "lock: held by live harness pid $CURSOR" ]
out=$(acquire_denied 2>&1); rc=$?
printf 'acquire rc=%s\n%s\nlock now: %s\n' "$rc" "$out" "$(cat "$LAB/state/.lock")"
check "acquisition refused the live UTF-8 Cursor owner" [ "$rc" -eq 1 ]
check "the UTF-8 Cursor owner's lock was left untouched" [ "$(cat "$LAB/state/.lock")" = "$CURSOR" ]

# --- 9. the real Claude Stop hook stands down for a live foreign owner -----
step "denied ps: Claude Stop auto-arm stays inert for a live foreign owner"
: > "$LAB/AGENTS.md"
: > "$LAB/state/task.meta"
if ! git -C "$LAB" rev-parse --git-dir >/dev/null 2>&1; then
  git init -q "$LAB" >/dev/null 2>&1
  git -C "$LAB" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m init
fi
record_owner "$CURSOR"
printf '{"transcript_path":"/tmp/live-evidence.jsonl"}' | \
  env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID FM_HOME="$LAB" FM_ROOT_OVERRIDE="$LAB" \
    PATH="$DENY:$PATH" setsid --wait "$LAB/bin/claude" -c \
    "exec \"$REPO/bin/fm-claude-stop-autoarm.sh\"" >"$LAB/hook.out" 2>"$LAB/hook.err"
rc=$?
printf 'hook rc=%s\n--stdout--\n%s\n--stderr--\n%s\nlock now: %s\n' \
  "$rc" "$(cat "$LAB/hook.out")" "$(cat "$LAB/hook.err")" "$(cat "$LAB/state/.lock")"
check "the Stop hook exited 0 (inert)" [ "$rc" -eq 0 ]
check "the Stop hook left the foreign owner's lock untouched" [ "$(cat "$LAB/state/.lock")" = "$CURSOR" ]
check "the Stop hook wrote no auto-arm ledger for the foreign home" [ ! -e "$LAB/state/.claude-autoarm-epoch" ]

# --- 10. the Cursor turn-end guard applies the same verdict live -----------
step "denied ps: Cursor turn-end guard is inert for a live foreign owner and recovers a dead one"
guard_run() {  # <payload> ; stdin payload, denied ps, harness-named shell
  printf '%s' "$1" | env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID -u PI_CODING_AGENT \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS FM_HOME="$LAB" FM_ROOT_OVERRIDE="$LAB" \
    PATH="$DENY:$PATH" timeout 120 setsid --wait "$LAB/bin/claude" -c \
    "exec \"$REPO/bin/fm-turnend-guard-cursor.sh\""
}
record_owner "$CURSOR"
guard_run '{"loop_count":0,"session_id":"S2"}' >"$LAB/guard-foreign.out" 2>&1; rc=$?
printf 'foreign owner -> guard rc=%s, lock now: %s\n' "$rc" "$(cat "$LAB/state/.lock")"
check "the guard exited 0 for a live foreign owner" [ "$rc" -eq 0 ]
check "the guard left the foreign owner's lock untouched" [ "$(cat "$LAB/state/.lock")" = "$CURSOR" ]
record_owner "$DEAD"
guard_run '{"loop_count":0,"session_id":"S2"}' >"$LAB/guard-dead.out" 2>&1; rc=$?
printf 'dead owner    -> guard rc=%s, lock now: %s\n' "$rc" "$(cat "$LAB/state/.lock")"
check "the guard exited 0 after recovering the dead record" [ "$rc" -eq 0 ]
check "the guard reclaimed and rewrote the dead record" [ "$(cat "$LAB/state/.lock")" != "$DEAD" ]

# --- 11. before/after: the pre-fix build wedges on the same host -----------
# The base commit's own bin/ is extracted read-only from git into a temp dir and
# driven against the same lab home, the same denied ps, and the same dead
# record, so the read-only wedge this change removes is demonstrated, not
# asserted from a changelog.
step "before/after: the base commit cannot reclaim the same dead record"
git -C "$REPO" archive "$BASE_COMMIT" bin | tar -x -C "$BASELINE" || bad "could not extract the base commit"
record_owner "$DEAD"
out=$(env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PID FM_HOME="$LAB" PATH="$DENY:$PATH" "$LAB/bin/claude" -c "exec \"$BASELINE/bin/fm-lock.sh\"" 2>&1); rc=$?
printf 'base  acquire rc=%s\n%s\nlock now: %s\n' "$rc" "$out" "$(cat "$LAB/state/.lock")"
check "the base build still refuses on the denied-ps host" [ "$rc" -eq 1 ]
check "the base build leaves the dead record in place" [ "$(cat "$LAB/state/.lock")" = "$DEAD" ]
out=$(acquire_denied 2>&1); rc=$?
printf 'head  acquire rc=%s\n%s\nlock now: %s\n' "$rc" "$out" "$(cat "$LAB/state/.lock")"
check "the fixed build reclaims the same record" [ "$rc" -eq 0 ]
check "the fixed build replaces the dead record" [ "$(cat "$LAB/state/.lock")" != "$DEAD" ]

printf '\n===== summary =====\n' 
if [ "$FAILED" -eq 0 ]; then
  echo "ALL LIVE CHECKS PASSED"
else
  echo "LIVE CHECKS FAILED"
fi
exit "$FAILED"
