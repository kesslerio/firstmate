#!/usr/bin/env bash
# Live drive of the change under validation:
# "Buffer remote stderr so sent: precedes notices on delivery for remote steer".
#
# Drives the REAL bin/fm-send.sh + bin/fm-on.sh + bin/fm-remote-entrypoint.sh +
# bin/fm-remote-secondmate-control.sh. Only the `ssh` binary is replaced, at the
# product's own FM_SSH_BIN process seam (the same seam the repo's
# docs/verification/public-followup.md documents), and that stub executes the
# real remote entrypoint against a local directory standing in for the remote
# home. No host and no network are involved.
set -u
ROOT={run-worktree}
EV=~/.no-mistakes/evidence/01M71BRK3FQ4N0VND596HQN12Z
cd "$ROOT" || exit 1

# Reuse the suite's own fixture builders (stubbed ssh transport, remote-home
# fixture, parent-home fixture, send_env) without running its test bodies.
python3 - "$ROOT/tests/fm-send-remote-delivery.test.sh" "$EV/_helpers.sh" <<'PY'
import sys
src = open(sys.argv[1]).read().split("\n")[:863]
text = "\n".join(src).replace(
    '. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"', '. "$ROOT/tests/lib.sh"', 1)
assert 'tests/lib.sh' in text
open(sys.argv[2], "w").write(text)
PY
# shellcheck disable=SC1091
. "$EV/_helpers.sh"

FAILED=0
note() { printf '%s\n' "$*"; }
check() {  # <description> <ok:0|1> <detail-on-failure>
  if [ "$2" -eq 0 ]; then
    note "PASS  $1"
  else
    note "FAIL  $1"
    [ -z "${3:-}" ] || printf '      %s\n' "$3"
    FAILED=1
  fi
}

# ---------------------------------------------------------------------------
# S1: a delivered remote steer prints sent: before the remote leg's notice.
# ---------------------------------------------------------------------------
s1_sent_precedes_notice() {
  local dir fb ssh_log home rhome rc err sent_line notice_line named legrh legs leg_stdout leg_stderr
  dir="$TMP_ROOT/live-sent-order"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/sent.ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home live-sent-order)
  home=$(setup_remote_parent_home live-sent-order "$rhome")

  note "CASE 1: delivered remote steer, remote leg emits a doorbell notice on stderr"
  note "  cmd: fm-send.sh rsm 'please rename the metric'  (FM_HOME=<lab parent home>, ssh seam -> real remote leg)"
  mkdir -p "$dir/tmp"
  rc=0
  send_env "$fb" "$home" "$ssh_log" TMPDIR="$dir/tmp" \
    "$SEND" rsm "please rename the metric" >"$dir/out" 2>"$dir/err" || rc=$?
  err=$(cat "$dir/err")
  note "  exit: $rc"
  note "  stderr (numbered):"
  nl -ba "$dir/err" | sed 's/^/    /'
  note "  stdout: $(cat "$dir/out")"
  check "delivered remote steer exits 0" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)" "$err"
  named=$(sent_named_record "$dir/err")
  check "the sent: confirmation names the far-side record" "$([ -n "$named" ] && echo 0 || echo 1)" "$err"
  check "the named far-side record exists in the remote home" \
    "$([ -n "$named" ] && [ -f "$named" ] && case "$named" in "$rhome"/*) echo 0 ;; *) echo 1 ;; esac || echo 1)" "$named"
  sent_line=$(grep -n '^sent: ' "$dir/err" | head -1 | cut -d: -f1)
  notice_line=$(grep -n '^notice: steer durably recorded at ' "$dir/err" | head -1 | cut -d: -f1)
  check "the remote leg's notice: line reaches the operator" "$([ -n "$notice_line" ] && echo 0 || echo 1)" "$err"
  check "sent: precedes the buffered notice: (sent line $sent_line < notice line $notice_line)" \
    "$([ -n "$sent_line" ] && [ -n "$notice_line" ] && [ "$sent_line" -lt "$notice_line" ] && echo 0 || echo 1)" "$err"
  check "no internal steer_record= line is replayed to the operator" \
    "$(printf '%s' "$err" | grep -q '^steer_record=' && echo 1 || echo 0)"
  check "a delivered send carries no error: line" \
    "$(printf '%s' "$err" | grep -q '^error:' && echo 1 || echo 0)"
  check "the remote stderr buffer file is removed after the send" \
    "$([ -z "$(ls -A "$dir/tmp" 2>/dev/null)" ] && echo 0 || echo 1)" "$(ls -A "$dir/tmp" 2>/dev/null)"

  # Independent corroboration that the notice is emitted BY the remote call:
  # run that leg on its own and show it on the leg's stderr.
  legrh=$(setup_remote_secondmate_home live-sent-order-leg)
  note "  --- direct run of the remote leg (bin/fm-remote-secondmate-control.sh send-stdin rsm):"
  printf 'please rename the metric\n' > "$dir/leg.in"
  legs=0
  env HOME="$fb/remote-account" FM_HOME="$legrh" FM_ROOT_OVERRIDE="$ROOT" PATH="$fb:$PATH" \
    "$ROOT/bin/fm-remote-secondmate-control.sh" send-stdin rsm < "$dir/leg.in" \
    >"$dir/leg.out" 2>"$dir/leg.err" || legs=$?
  leg_stdout=$(cat "$dir/leg.out"); leg_stderr=$(cat "$dir/leg.err")
  note "    exit: $legs"
  note "    leg stdout: $leg_stdout"
  note "    leg stderr: $leg_stderr"
  check "the remote leg reports its record on stdout" \
    "$(printf '%s' "$leg_stdout" | grep -q '^steer_record=' && echo 0 || echo 1)" "$leg_stdout"
  check "the remote leg emits the notice on its own stderr" \
    "$(printf '%s' "$leg_stderr" | grep -q '^notice: steer durably recorded at ' && echo 0 || echo 1)" "$leg_stderr"
}

# ---------------------------------------------------------------------------
# S2: unusable temp dir refuses before any remote attempt.
# ---------------------------------------------------------------------------
s2_unusable_tmpdir() {
  local dir fb ssh_log home rhome rc err count
  dir="$TMP_ROOT/live-bad-tmp"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/badtmp.ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home live-bad-tmp)
  home=$(setup_remote_parent_home live-bad-tmp "$rhome")

  note "CASE 2: unusable TMPDIR (stderr buffer cannot be created)"
  note "  cmd: TMPDIR=$dir/nonexistent fm-send.sh rsm 'please rename the metric'"
  rc=0
  send_env "$fb" "$home" "$ssh_log" TMPDIR="$dir/nonexistent" \
    "$SEND" rsm "please rename the metric" >"$dir/out" 2>"$dir/err" || rc=$?
  err=$(cat "$dir/err")
  note "  exit: $rc"
  note "  stderr (numbered):"
  nl -ba "$dir/err" | sed 's/^/    /'
  check "buffer failure refuses the send with a nonzero exit" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)" "$err"
  check "the refusal names the missing prerequisite" \
    "$(printf '%s' "$err" | grep -q 'could not create remote stderr buffer' && echo 0 || echo 1)" "$err"
  check "no sent: line is printed (nothing was delivered)" \
    "$(printf '%s' "$err" | grep -q '^sent:' && echo 1 || echo 0)"
  count=$(grep -c . "$ssh_log" 2>/dev/null || true)
  check "no remote attempt is made (ssh invocations: ${count:-0})" "$([ -z "${count:-}" ] || [ "$count" = 0 ] && echo 0 || echo 1)"
  check "no far-side record is written" "$([ -z "$(remote_inbox_records "$rhome")" ] && echo 0 || echo 1)"
  check "the undelivered reply expectation is discarded" \
    "$([ -z "$(pending_record "$home")" ] && echo 0 || echo 1)" "$(pending_record "$home")"
}

# ---------------------------------------------------------------------------
# S3: a genuinely failing remote leg still surfaces its own diagnostics.
# ---------------------------------------------------------------------------
s3_real_remote_failure() {
  local dir fb ssh_log home rhome rc err
  dir="$TMP_ROOT/live-leg-fail"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/legfail.ssh.log"; : > "$ssh_log"
  # A remote home with no parent-route endpoint record: the real remote leg
  # refuses the delivery and prints its own error on stderr.
  rhome="$TMP_ROOT/live-leg-fail-rhome-broken"; mkdir -p "$rhome/state"
  printf 'rsm\n' > "$rhome/.fm-secondmate-home"
  home=$(setup_remote_parent_home live-leg-fail "$rhome")

  note "CASE 3: real remote leg failure (remote home has no parent-route endpoint)"
  note "  cmd: fm-send.sh rsm 'please rename the metric'  (real leg refuses the record)"
  rc=0
  send_env "$fb" "$home" "$ssh_log" \
    "$SEND" rsm "please rename the metric" >"$dir/out" 2>"$dir/err" || rc=$?
  err=$(cat "$dir/err")
  note "  exit: $rc"
  note "  stderr (numbered):"
  nl -ba "$dir/err" | sed 's/^/    /'
  check "a failed remote leg exits nonzero" "$([ "$rc" -ne 0 ] && echo 0 || echo 1)" "$err"
  check "the buffered remote diagnostics still reach the operator" \
    "$(printf '%s' "$err" | grep -qi 'error:' && echo 0 || echo 1)" "$err"
  check "the send is reported as not sent" \
    "$(printf '%s' "$err" | grep -q 'steer not sent to remote secondmate rsm' && echo 0 || echo 1)" "$err"
  check "no sent: confirmation is printed for a failed send" \
    "$(printf '%s' "$err" | grep -q '^sent:' && echo 1 || echo 0)"
  check "no far-side record is written" "$([ -z "$(remote_inbox_records "$rhome" 2>/dev/null)" ] && echo 0 || echo 1)"
}

# ---------------------------------------------------------------------------
# S4: ambiguous transport retried once - buffered stderr spans both attempts.
# ---------------------------------------------------------------------------
s4_ambiguous_then_success() {
  local dir fb ssh_log home rhome rc err sent_line first_notice notices
  dir="$TMP_ROOT/live-ambiguous"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/ambig.ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home live-ambiguous)
  home=$(setup_remote_parent_home live-ambiguous "$rhome")
  # first ssh call executes the real leg, then reports 255 (completion unknown);
  # the identical retry executes it again and succeeds. The wrapper replaces the
  # ssh stub in place because send_env pins FM_SSH_BIN to $fb/fake-ssh.
  mv "$fb/fake-ssh" "$fb/fake-ssh-exec"
  cat > "$fb/fake-ssh" <<SH
#!/usr/bin/env bash
set -u
c=\$(cat "$dir/ambig.count" 2>/dev/null || echo 0)
c=\$((c + 1))
printf '%s\n' "\$c" > "$dir/ambig.count"
rc=0
"$fb/fake-ssh-exec" "\$@" || rc=\$?
if [ "\$c" = 1 ]; then
  exit 255
fi
exit "\$rc"
SH
  chmod +x "$fb/fake-ssh"

  note "CASE 4: ssh 255 after the record landed, then the identical retry succeeds"
  note "  cmd: fm-send.sh rsm 'please rename the metric'  (attempt 1 ambiguous, attempt 2 delivered)"
  rc=0
  send_env "$fb" "$home" "$ssh_log" \
    "$SEND" rsm "please rename the metric" >"$dir/out" 2>"$dir/err" || rc=$?
  err=$(cat "$dir/err")
  note "  exit: $rc"
  note "  ssh attempts: $(cat "$dir/ambig.count" 2>/dev/null || echo 0)"
  note "  stderr (numbered):"
  nl -ba "$dir/err" | sed 's/^/    /'
  check "the retried delivery exits 0" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)" "$err"
  check "the transport was retried exactly once" \
    "$([ "$(cat "$dir/ambig.count" 2>/dev/null || echo 0)" = 2 ] && echo 0 || echo 1)"
  check "exactly one far-side record exists" \
    "$([ "$(remote_inbox_records "$rhome" | grep -c . || true)" = 1 ] && echo 0 || echo 1)" \
    "$(remote_inbox_records "$rhome")"
  notices=$(printf '%s\n' "$err" | grep -c '^notice: steer durably recorded at ' || true)
  check "stderr carries a notice from each attempt (found ${notices:-0}, expected 2)" \
    "$([ "${notices:-0}" = 2 ] && echo 0 || echo 1)" "$err"
  sent_line=$(grep -n '^sent: ' "$dir/err" | head -1 | cut -d: -f1)
  first_notice=$(grep -n '^notice: steer durably recorded at ' "$dir/err" | head -1 | cut -d: -f1)
  check "sent: precedes every buffered notice across both attempts" \
    "$([ -n "$sent_line" ] && [ -n "$first_notice" ] && [ "$sent_line" -lt "$first_notice" ] && echo 0 || echo 1)" "$err"
}

# ---------------------------------------------------------------------------
# S5: a remote leg that reports no record still gets a delivery confirmation.
# ---------------------------------------------------------------------------
s5_no_report_still_confirms() {
  local dir fb ssh_log home rhome rc err
  dir="$TMP_ROOT/live-noreport"; mkdir -p "$dir"
  fb=$(make_stubs "$dir"); ssh_log="$dir/noreport.ssh.log"; : > "$ssh_log"
  rhome=$(setup_remote_secondmate_home live-noreport)
  home=$(setup_remote_parent_home live-noreport "$rhome")

  note "CASE 5: remote leg older than the steer_record report (delivers, reports nothing)"
  note "  cmd: fm-send.sh rsm 'please rename the metric'  (remote leg stdout dropped)"
  rc=0
  send_env "$fb" "$home" "$ssh_log" FM_FAKE_SSH_DROP_REPORT=1 \
    "$SEND" rsm "please rename the metric" >"$dir/out" 2>"$dir/err" || rc=$?
  err=$(cat "$dir/err")
  note "  exit: $rc"
  note "  stderr (numbered):"
  nl -ba "$dir/err" | sed 's/^/    /'
  check "delivery without a remote report still exits 0" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)" "$err"
  check "delivery is still confirmed without a named path" \
    "$(printf '%s' "$err" | grep -q "sent: steer to remote secondmate rsm durably recorded in remote secondmate rsm's own steering inbox" && echo 0 || echo 1)" "$err"
  check "exactly one far-side record exists" \
    "$([ "$(remote_inbox_records "$rhome" | grep -c . || true)" = 1 ] && echo 0 || echo 1)"
}

for scenario in s1_sent_precedes_notice s2_unusable_tmpdir s3_real_remote_failure \
  s4_ambiguous_then_success s5_no_report_still_confirms; do
  out="$EV/live-$scenario.log"
  {
    printf '=== %s ===\n' "$scenario"
    printf 'worktree: %s (HEAD %s)\n' "$ROOT" "$(git -C "$ROOT" rev-parse --short HEAD)"
    printf 'started: %s\n' "$(date -u +%FT%TZ)"
    "$scenario"
    printf 'finished: %s\n' "$(date -u +%FT%TZ)"
  } > "$out" 2>&1
  cat "$out"
  printf '\n'
done

rm -rf "$TMP_ROOT" 2>/dev/null || true
printf 'OVERALL: %s\n' "$([ "$FAILED" -eq 0 ] && echo PASS || echo FAIL)"
exit "$FAILED"
