#!/usr/bin/env bash
# tests/fm-remote-secondmate-relaunch.test.sh - regression coverage for
# bin/fm-remote-secondmate-relaunch.sh: the parent-side tool an operator runs
# to move a remote secondmate onto a new harness, model, or effort.
#
# Reproduces the observed defect: running
# bin/fm-on.sh <id> fm-remote-secondmate-control.sh relaunch <id> <harness>
# <model> <effort> relaunches the agent on its host, but that host-local verb
# can only rewrite its own endpoint record. The parent's own state/<id>.meta
# kept naming the runtime the mate used to run. The wrapper drives the same
# host-local relaunch and then republishes this home's own record from the
# identity the host confirmed.
#
# The remote transport is faked at the SSH boundary, exactly as the other
# remote-secondmate suites fake it, rather than exercising a real host.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$ROOT/bin/fm-pr-lib.sh"

command -v perl >/dev/null 2>&1 || { echo "skip: perl not found"; exit 0; }

TMP=$(fm_test_tmproot fm-remote-secondmate-relaunch)
FM_TEST_CHILD_REGISTRY="$TMP/children"
export FM_TEST_CHILD_REGISTRY
HOME_DIR="$TMP/home"
FAKEBIN=$(fm_fakebin "$TMP/fake")
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config"

printf -- '- ios - iOS delivery (host: remote-mac; root: /srv/fm; home: /srv/fm-home; scope: iOS; projects: alpha; added 2026-08-01)\n' \
  > "$HOME_DIR/data/secondmates.md"

reset_meta() {
  fm_write_meta "$HOME_DIR/state/ios.meta" \
    "window=remote:ios" \
    "endpoint_task_id=ios" \
    "worktree=/srv/fm-home" \
    "project=/srv/fm" \
    "harness=pi" \
    "kind=secondmate" \
    "mode=secondmate" \
    "yolo=off" \
    "model=openai-codex/gpt-5.6-sol" \
    "effort=medium" \
    "home=/srv/fm-home" \
    "projects=alpha" \
    "remote_host=remote-mac" \
    "remote_root=/srv/fm" \
    "remote_backend=herdr" \
    "remote_herdr_session=fm-remote" \
    "remote_target=fm-remote:w1:p1"
}

cat > "$FAKEBIN/fake-ssh" <<'SH'
#!/usr/bin/env bash
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
host=$1
entry=$2
shift 2
[ "$host" = remote-mac ] || exit 91
[ "$entry" = fm-remote-entrypoint.sh ] || exit 92
argv_b64=$4
command_fields=$(perl -MMIME::Base64=decode_base64 -e '
  my $data=decode_base64($ARGV[0]);
  my @args=split(/\0/, $data);
  print join("\t", map { defined $_ ? $_ : "" } @args[0..5]);
' "$argv_b64")
IFS=$'\t' read -r cmd action id harness model effort <<EOF
$command_fields
EOF
[ "$cmd" = fm-remote-secondmate-control.sh ] || exit 93
[ "$action" = relaunch ] || exit 94
case "$FM_FAKE_RELAUNCH_MODE" in
  concurrent)
    printf '%s\n' "$harness" >> "$FM_FAKE_RELAUNCH_SYNC/entered"
    if [ "$harness" = claude ]; then
      touch "$FM_FAKE_RELAUNCH_SYNC/a-ready"
      deadline=$((SECONDS + 8))
      while [ ! -e "$FM_FAKE_RELAUNCH_SYNC/release-a" ]; do
        [ "$SECONDS" -lt "$deadline" ] || exit 95
        sleep .02
      done
    fi
    ;;
  change-route)
    printf 'remote_host=changed-host\nspawn_gen=replacement\n' >> "$FM_FAKE_RELAUNCH_SYNC/../home/state/ios.meta"
    ;;

  refuse)
    printf 'error: unverified remote secondmate harness: %s\n' "$harness" >&2
    exit 1
    ;;
  confirm-other)
    harness=claude
    model=claude-opus-5-5
    effort=medium
    ;;
esac
printf 'relaunched %s harness=%s from=pi model=%s effort=%s backend=herdr endpoint=fm-remote:w1:p1 worktree=/srv/fm-home\n' \
  "$id" "$harness" "$model" "$effort"
printf 'schema=fm-remote-secondmate-control.v1\n'
printf 'backend=herdr\n'
printf 'target=fm-remote:w1:p1\n'
printf 'herdr_session=fm-remote\n'
printf 'harness=%s\n' "$harness"
printf 'model=%s\n' "$model"
printf 'effort=%s\n' "$effort"
SH
chmod +x "$FAKEBIN/fake-ssh"

run_relaunch() {  # <args...>
  env FM_HOME="$HOME_DIR" FM_SSH_BIN="$FAKEBIN/fake-ssh" \
    FM_FAKE_RELAUNCH_MODE="${FM_FAKE_RELAUNCH_MODE:-}" FM_FAKE_RELAUNCH_SYNC="${FM_FAKE_RELAUNCH_SYNC:-}" \
    "$ROOT/bin/fm-remote-secondmate-relaunch.sh" "$@" 2>&1
}

# --- a successful relaunch republishes the parent's own route record --------
reset_meta
OUT=$(run_relaunch ios claude claude-opus-5-5 medium); RC=$?
expect_code 0 "$RC" "a confirmed remote relaunch should succeed"$'\n'"$OUT"
assert_contains "$OUT" "relaunched ios harness=claude" \
  "the wrapper should still print the host's own confirmation line"
assert_grep 'harness=claude' "$HOME_DIR/state/ios.meta" \
  "the parent record did not pick up the confirmed harness"
assert_grep 'model=claude-opus-5-5' "$HOME_DIR/state/ios.meta" \
  "the parent record did not pick up the confirmed model"
assert_grep 'effort=medium' "$HOME_DIR/state/ios.meta" \
  "the parent record did not pick up the confirmed effort"
assert_no_grep 'harness=pi' "$HOME_DIR/state/ios.meta" \
  "the stale runtime should not still be recorded"
assert_no_grep 'model=openai-codex/gpt-5.6-sol' "$HOME_DIR/state/ios.meta" \
  "the stale model should not still be recorded"
assert_grep 'remote_host=remote-mac' "$HOME_DIR/state/ios.meta" \
  "unrelated route fields must survive the update"
assert_grep 'window=remote:ios' "$HOME_DIR/state/ios.meta" \
  "unrelated identity fields must survive the update"
pass "a successful remote relaunch republishes the parent's harness, model, and effort"

# --- the parent records what the host confirmed, not what it was asked ------
reset_meta
FM_FAKE_RELAUNCH_MODE=confirm-other
OUT=$(run_relaunch ios default default default); RC=$?
unset FM_FAKE_RELAUNCH_MODE
expect_code 0 "$RC" "a relaunch whose host resolves a different identity should succeed"$'\n'"$OUT"
assert_grep 'harness=claude' "$HOME_DIR/state/ios.meta" \
  "the parent record should follow the host's confirmed harness"
assert_grep 'model=claude-opus-5-5' "$HOME_DIR/state/ios.meta" \
  "the parent record should follow the host's confirmed model"
assert_no_grep 'harness=default' "$HOME_DIR/state/ios.meta" \
  "the parent record must not keep the unresolved request"
pass "a remote relaunch records the identity the host confirmed"

# --- a refused relaunch leaves the parent's record untouched -----------------
reset_meta
cp "$HOME_DIR/state/ios.meta" "$TMP/ios-before-refusal.meta"
FM_FAKE_RELAUNCH_MODE=refuse
OUT=$(run_relaunch ios notaharness - -); RC=$?
unset FM_FAKE_RELAUNCH_MODE
[ "$RC" -ne 0 ] || fail "a refused host relaunch must not be reported as successful"
assert_contains "$OUT" "unverified remote secondmate harness" \
  "the refusal reason should reach the caller"
cmp -s "$TMP/ios-before-refusal.meta" "$HOME_DIR/state/ios.meta" \
  || fail "a refused relaunch must not touch the parent's record"
pass "a refused remote relaunch leaves the parent's record untouched"

# --- a local (non-remote) secondmate is refused, not silently mishandled ----
fm_write_meta "$HOME_DIR/state/local1.meta" \
  "window=firstmate:fm-local1" "endpoint_task_id=local1" \
  "worktree=/srv/local1" "project=/srv/local1" "harness=codex" \
  "kind=secondmate" "mode=secondmate" "yolo=off" "home=/srv/local1"
OUT=$(run_relaunch local1 claude - -); RC=$?
[ "$RC" -ne 0 ] || fail "a local secondmate must not be accepted by the remote relaunch tool"
assert_contains "$OUT" "not a remotely placed secondmate" \
  "the refusal should explain the tool this task needs instead"
pass "a local secondmate is refused by the remote relaunch tool"

# --- a relaunch keeps an already-armed PR poll authenticating ---------------
# fm-pr-check.sh now refuses to arm a poll on a kind=secondmate record, but a
# record armed before that refusal can still carry the block until the
# watcher retires it. fm-pr-check.sh wrote pr= (and, when a forge head was
# readable, pr_head=) as the LAST lines of the record, and
# fm_pr_metadata_identity_parse treats any other key appearing after pr= as
# invalid, so this wrapper must not append its harness=/model=/effort= lines
# after that identity block. The fixture is seeded the way such a record was
# really written: pr= appended last to the meta, then the poll artifacts
# published through the same fm_pr_poll_prepare/fm_pr_poll_publish_prepared
# pair fm-pr-check.sh uses, since the refused entry point cannot arm it.
reset_meta
printf 'pr=https://github.com/example/repo/pull/1\n' >> "$HOME_DIR/state/ios.meta" \
  || fail "could not write the pr= identity for the relaunch-ordering test"
fm_pr_poll_prepare "$HOME_DIR/state" ios github \
  https://github.com/example/repo/pull/1 github.com example/repo 1 \
  "$ROOT/bin/fm-pr-poll.sh" \
  || fail "could not prepare the PR poll fixture for the relaunch-ordering test"
fm_pr_poll_publish_prepared \
  || fail "could not publish the PR poll fixture for the relaunch-ordering test"
fm_pr_poll_artifacts_valid "$HOME_DIR/state" ios "$ROOT/bin/fm-pr-poll.sh" \
  || fail "PR poll fixture did not authenticate before the relaunch"
OUT=$(run_relaunch ios claude claude-opus-5-5 medium); RC=$?
expect_code 0 "$RC" "a confirmed remote relaunch should succeed with an armed PR poll"$'\n'"$OUT"
fm_pr_poll_artifacts_valid "$HOME_DIR/state" ios "$ROOT/bin/fm-pr-poll.sh" \
  || fail "a remote relaunch broke PR poll authentication by writing harness/model/effort after pr="
pass "a remote relaunch keeps an already-armed PR poll authenticating"

echo "ALL TESTS PASSED"

reset_meta
sync="$TMP/interleave"; mkdir "$sync"
FM_FAKE_RELAUNCH_MODE=concurrent FM_FAKE_RELAUNCH_SYNC="$sync" run_relaunch ios claude model-a high > "$sync/a.out" & a=$!
fm_test_track_child "$a"
for ((i=0; i<200; i++)); do [ -e "$sync/a-ready" ] && break; sleep .02; done
assert_present "$sync/a-ready" 'first remote operation did not reach confirmation barrier'
FM_FAKE_RELAUNCH_MODE=concurrent FM_FAKE_RELAUNCH_SYNC="$sync" run_relaunch ios pi model-b medium > "$sync/b.out" & b=$!
fm_test_track_child "$b"
sleep .2
assert_equals claude "$(cat "$sync/entered")" 'second operation bypassed parent task serialization'
touch "$sync/release-a"
wait "$a" || fail 'first serialized relaunch failed'
wait "$b" || fail 'second serialized relaunch failed'
assert_equals $'claude\npi' "$(cat "$sync/entered")" 'remote operations must preserve publication order'
assert_grep 'harness=pi' "$HOME_DIR/state/ios.meta" 'parent must name last confirmed runtime'
assert_grep 'model=model-b' "$HOME_DIR/state/ios.meta" 'stale confirmation overwrote newer runtime'
reset_meta
rc=0
FM_FAKE_RELAUNCH_MODE=change-route FM_FAKE_RELAUNCH_SYNC="$sync" run_relaunch ios claude model-c high > "$sync/change.out" || rc=$?
[ "$rc" -ne 0 ] || fail 'changed route/generation accepted stale confirmation'
assert_grep 'harness=pi' "$HOME_DIR/state/ios.meta" 'stale confirmation changed original runtime'
assert_grep 'remote_host=changed-host' "$HOME_DIR/state/ios.meta" 'route replacement was overwritten'
pass 'parent task lock serializes remote operation and publication; changed routes refuse stale confirmation'

for field in kind remote_host remote_root home; do
  reset_meta
  python3 - "$HOME_DIR/state/ios.meta" "$field" <<'PYROUTE'
import pathlib, sys
p=pathlib.Path(sys.argv[1]); field=sys.argv[2]
p.write_text(''.join((field+'=foreign\n') if line.startswith(field+'=') else line for line in p.read_text().splitlines(keepends=True)))
PYROUTE
  before=$(cksum "$HOME_DIR/state/ios.meta")
  rc=0
  run_relaunch ios claude model high > "$sync/denied-$field" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "mismatched $field route was relaunched"
  assert_grep 'does not identify the configured remote secondmate route' "$sync/denied-$field" 'route denial must precede remote effects'
  assert_equals "$before" "$(cksum "$HOME_DIR/state/ios.meta")" 'denied route changed parent metadata'
done
pass 'remote relaunch rejects kind, host, root and home disagreement before transport'
