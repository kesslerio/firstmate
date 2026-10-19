#!/usr/bin/env bash
# Behavior tests for tests/lib.sh's shared fixture-tempdir helper
# (fm_test_tmproot / fm_test_cleanup / fm_test_reap_orphans).
#
# The near-universal call pattern across this suite is
# `TMP_ROOT=$(fm_test_tmproot prefix)`, which forks a subshell to capture the
# function's stdout. These tests spawn real, separate bash processes that use
# that exact pattern and assert the fixture root is actually gone once the
# owning process's guarded teardown has run - on a normal exit and on a
# terminating signal - plus that a stale marked fixture from a killed prior
# run gets reaped on the next source. Nothing here inspects tests/lib.sh's
# source text; it only observes filesystem state around the real helper.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LIB="$ROOT/tests/lib.sh"
CHILDREN=()
cleanup_children() {
  local child
  for child in "${CHILDREN[@]:-}"; do
    [ -n "$child" ] || continue
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap 'cleanup_children || exit $?' EXIT

test_nested_source_keeps_a_separate_default_child_registry() {
  local parent_registry=$FM_TEST_DEFAULT_CHILD_REGISTRY nested_registry
  nested_registry=$(FM_TEST_CHILD_REGISTRY="$parent_registry" bash -c '. "$1"; printf "%s\n" "$FM_TEST_CHILD_REGISTRY"' _ "$LIB")
  [ "$nested_registry" != "$parent_registry" ] || fail 'nested source reused its parent default child registry'
  assert_present "$parent_registry" 'nested cleanup removed its parent default child registry'
  pass 'nested source owns a separate default child registry'
}
test_nested_source_keeps_a_separate_default_child_registry

test_supplied_child_registry_survives_source_and_cleanup() {
  local harness registry output
  harness=$(fm_test_tmproot fm-external-child-registry)
  registry="$harness/children"
  (umask 077; : > "$registry")
  if output=$(FM_TEST_CHILD_REGISTRY="$registry" bash -c '
    . "$1"
    [ "$FM_TEST_CHILD_REGISTRY" = "$2" ] || { echo "external child registry was redirected"; exit 61; }
    sleep 30 &
    child=$!
    fm_test_track_child "$child" kill
    fm_test_stop_children || exit 62
    [ -f "$2" ] && [ ! -s "$2" ] || { echo "external child registry was removed or not drained"; exit 63; }
    ! kill -0 "$child" 2>/dev/null || { echo "registered child remains live"; exit 64; }
  ' _ "$LIB" "$registry" 2>&1); then
    :
  else
    fail "supplied child registry contract failed: $output"
  fi
  assert_present "$registry" 'normal exit removed the supplied child registry'
  [ ! -s "$registry" ] || fail 'normal exit left pending child records'
  pass 'supplied child registry retains its path and empty artifact after owned cleanup'
}
test_supplied_child_registry_survives_source_and_cleanup

test_failed_exit_cleanup_retains_child_and_fixture_evidence() {
  local harness mode registry rc child fixture recorded_registry
  harness=$(fm_test_tmproot fm-failed-exit-cleanup)
  for mode in default supplied custom-default custom-supplied; do
    mkdir "$harness/$mode"
    registry=
    if [ "$mode" = supplied ] || [ "$mode" = custom-supplied ]; then
      registry="$harness/$mode/children"
      : > "$registry"
    fi
    # shellcheck disable=SC2016 # The script expands arguments in its child Bash.
    if FM_TEST_CHILD_REGISTRY="$registry" python3 -c '
import os,signal,subprocess,sys
child=subprocess.Popen(sys.argv[1:],start_new_session=True)
try:
    rc=child.wait(timeout=12)
except subprocess.TimeoutExpired:
    os.killpg(child.pid,signal.SIGKILL)
    child.wait()
    rc=124
sys.exit(rc)
' bash -c '
      . "$1"
      case "$3" in custom-*)
        cleanup_children() { fm_test_cleanup; }
        trap '\''cleanup_children || exit $?'\'' EXIT
        ;;
      esac
      fixture=$(fm_test_tmproot fm-failed-child-evidence)
      printf "%s\n" "$fixture" > "$2/fixture"
      printf "%s\n" "$FM_TEST_CHILD_REGISTRY" > "$2/registry"
      python3 -c '\''import pathlib,signal,sys,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); pathlib.Path(sys.argv[1]).touch(); time.sleep(30)'\'' "$2/ready" >/dev/null 2>&1 &
      child=$!
      printf "%s\n" "$child" > "$2/pid"
      fm_test_track_child "$child" term
      for ((i=0;i<100;i++)); do
        [ ! -e "$2/ready" ] || break
        sleep .02
      done
      [ -e "$2/ready" ] || exit 71
      exit 0
    ' _ "$LIB" "$harness/$mode" "$mode" > "$harness/$mode/stdout" 2> "$harness/$mode/stderr"; then
      rc=0
    else
      rc=$?
    fi
    child=$(cat "$harness/$mode/pid")
    fm_test_track_child "$child" kill
    fixture=$(cat "$harness/$mode/fixture")
    recorded_registry=$(cat "$harness/$mode/registry")
    [ "$rc" -ne 0 ] && [ "$rc" -ne 124 ] && [ "$rc" -ne 137 ] || fail "$mode EXIT cleanup hid child cleanup failure (status $rc)"
    assert_present "$fixture" "$mode EXIT cleanup removed the failed child's fixture evidence"
    assert_present "$recorded_registry" "$mode EXIT cleanup removed child ownership evidence"
    grep -q "^$child""$(printf '\t')" "$recorded_registry" || fail "$mode EXIT cleanup drained failed child ownership evidence"
    kill -0 "$child" 2>/dev/null || fail "$mode failure fixture did not keep the TERM-ignoring child alive"
    fm_test_stop_children || fail "$mode failed-child recovery did not stop the owned process"
    fm_test_remove_tree "$fixture"
    rm -f "$recorded_registry"
  done
  pass 'failed EXIT cleanup reports failure and retains default and supplied child ownership and fixture evidence'
}
test_failed_exit_cleanup_retains_child_and_fixture_evidence

test_fixture_root_gone_after_normal_exit() {
  local child_out child_dir
  child_out=$(bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-exit)
    printf "%s\n" "$d"
    if [ -d "$d" ]; then printf "mid:present\n"; else printf "mid:missing\n"; fi
  ')
  child_dir=$(printf '%s\n' "$child_out" | sed -n '1p')
  assert_contains "$child_out" "mid:present" \
    "the fixture root was not present while its owning process was still alive"
  assert_absent "$child_dir" \
    "fm_test_tmproot's fixture root survived its owning process's normal exit"
  pass "fm_test_tmproot cleans up its fixture root on normal exit"
}

test_fixture_root_gone_after_sigterm() {
  local harness dirfile child_dir pid tries
  harness=$(fm_test_tmproot fm-test-cleanup-sigterm-harness)
  dirfile="$harness/child-dir"
  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-term)
    printf "%s\n" "$d" > "'"$dirfile"'"
    while :; do sleep 0.1; done
  ' &
  pid=$!
  CHILDREN+=("$pid")
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the child never published its fixture root before the wait timed out"
  child_dir=$(cat "$dirfile")
  assert_present "$child_dir" "the child's fixture root did not exist before it was signaled"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  CHILDREN[${#CHILDREN[@]}-1]=''
  assert_absent "$child_dir" \
    "fm_test_tmproot's fixture root survived SIGTERM to its owning process"
  pass "fm_test_tmproot cleans up its fixture root on SIGTERM"
}

test_cleanup_registry_resists_precreation() {
  local harness shared_tmp victim
  harness=$(fm_test_tmproot fm-test-cleanup-registry-harness)
  shared_tmp="$harness/shared-tmp"
  victim="$harness/victim"
  mkdir -p "$shared_tmp" "$victim"

  TMPDIR="$shared_tmp" bash -c '
    printf "%s\n" "$1" > "$TMPDIR/.fm-test-cleanup.$$"
    . "$2"
  ' _ "$victim" "$LIB"

  assert_present "$victim" \
    "a precreated predictable cleanup registry injected an arbitrary deletion target"
  pass "the cleanup registry cannot be injected through path precreation"
}

test_fixture_registration_failure_rolls_back_root() {
  local harness failure_tmp registry_dir output leaked_root
  harness=$(fm_test_tmproot fm-test-cleanup-registration-harness)
  failure_tmp="$harness/tmp"
  registry_dir="$harness/registry-dir"
  mkdir -p "$failure_tmp" "$registry_dir"

  if output=$(TMPDIR="$failure_tmp" FM_TEST_CLEANUP_REGISTRY="$registry_dir" \
    fm_test_tmproot fm-test-cleanup-registration-failure 2>/dev/null); then
    fail "fm_test_tmproot succeeded after its cleanup registry rejected registration"
  fi
  [ -z "$output" ] || fail "fm_test_tmproot published an unregistered fixture root"
  for leaked_root in "$failure_tmp"/fm-test-cleanup-registration-failure.*; do
    [ ! -e "$leaked_root" ] || fail "fm_test_tmproot leaked a root after registration failed"
  done
  pass "failed fixture registration rolls back the new root"
}

test_orphan_sweep_respects_fixture_ownership() {
  local harness dirfile active_dir stale_dir fresh_dir pid tries
  harness=$(fm_test_tmproot fm-test-cleanup-orphan-harness)
  dirfile="$harness/active-dir"
  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
    d=$(fm_test_tmproot fm-test-cleanup-active)
    printf "%s\n" "$d" > "'"$dirfile"'"
    while :; do sleep 0.1; done
  ' &
  pid=$!
  CHILDREN+=("$pid")
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the active child never published its fixture root before the wait timed out"
  active_dir=$(cat "$dirfile")
  touch -t 202001010000 "$active_dir/.fm-test-fixture"

  stale_dir=$(mktemp -d "$FM_TEST_TMPDIR/fm-test-cleanup-stale.XXXXXX")
  printf '%s\n%s\n' "$$" reused-process-identity > "$stale_dir/.fm-test-fixture"
  touch -t 202001010000 "$stale_dir/.fm-test-fixture"
  fresh_dir=$(mktemp -d "$FM_TEST_TMPDIR/fm-test-cleanup-fresh.XXXXXX")
  : > "$fresh_dir/.fm-test-fixture"

  bash -c '
    # shellcheck source=tests/lib.sh
    . "'"$LIB"'"
  '

  assert_absent "$stale_dir" \
    "a stale fixture root whose PID was reused by another process was not reaped"
  assert_present "$active_dir" \
    "the orphan reaper removed an old fixture root whose owning process was still alive"
  assert_present "$fresh_dir" \
    "the orphan reaper removed a fresh marked fixture root it does not own yet"
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null
  CHILDREN[${#CHILDREN[@]}-1]=''
  assert_absent "$active_dir" \
    "the active fixture root survived its owning process's teardown"
  rm -rf "$fresh_dir"
  pass "the orphan sweep reaps only old fixtures without a live owner"
}

test_orphan_sweep_reaps_read_only_package_tree() {
  local stale_dir package_dir
  stale_dir=$(mktemp -d "$FM_TEST_TMPDIR/fm-test-cleanup-read-only.XXXXXX")
  package_dir="$stale_dir/packages/extension"
  mkdir -p "$package_dir"
  printf '%s\n%s\n' "$$" reused-process-identity > "$stale_dir/.fm-test-fixture"
  printf 'installed package\n' > "$package_dir/entrypoint.py"
  chmod -R a-w "$stale_dir/packages"
  touch -t 202001010000 "$stale_dir/.fm-test-fixture"

  bash -c '
    # shellcheck source=tests/lib.sh
    . "$1"
  ' _ "$LIB"

  assert_absent "$stale_dir" \
    "the orphan reaper left a stale fixture containing a read-only package tree"
  pass "the orphan sweep reaps read-only package fixtures"
}

test_registries_avoid_git_worktree_root() {
  # A TMPDIR pointed at a repository root used to place live `.fm-test-*`
  # registries beside tracked files. A concurrent git add during a suite then
  # committed them (observed on the claim-walk CI fix round). The helper must
  # keep registries and fixture roots outside that root for the whole run.
  local harness repo dirfile child_dir pid tries entry
  harness=$(fm_test_tmproot fm-test-cleanup-gitroot-harness)
  repo="$harness/repo"
  dirfile="$harness/child-dir"
  mkdir -p "$repo"
  git -C "$repo" init -q
  bash -c '
    export TMPDIR="$1"
    # shellcheck source=tests/lib.sh
    . "$2"
    d=$(fm_test_tmproot fm-test-cleanup-gitroot)
    printf "%s\n" "$d" > "$3"
    # Hold the suite open so a concurrent add would see any root-side leak.
    while :; do sleep 0.1; done
  ' _ "$repo" "$LIB" "$dirfile" &
  pid=$!
  CHILDREN+=("$pid")
  tries=0
  while [ "$tries" -lt 100 ]; do
    [ -s "$dirfile" ] && break
    sleep 0.05
    tries=$((tries + 1))
  done
  [ -s "$dirfile" ] || fail "the git-root TMPDIR child never published its fixture root"
  child_dir=$(cat "$dirfile")
  assert_present "$child_dir" "the git-root TMPDIR child did not create a fixture root"
  case "$child_dir" in
    "$repo"|"$repo"/*)
      fail "fm_test_tmproot placed a fixture root inside the git worktree root: $child_dir"
      ;;
  esac
  for entry in "$repo"/.fm-test-cleanup.* "$repo"/.fm-test-procevent.* "$repo"/.fm-test-watcher.*; do
    [ ! -e "$entry" ] || fail "a live test registry landed in the git worktree root: $entry"
  done
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null || true
  CHILDREN[${#CHILDREN[@]}-1]=''
  assert_absent "$child_dir" \
    "the git-root TMPDIR child's fixture root survived SIGTERM"
  pass "test registries and fixture roots stay out of a git worktree TMPDIR"
}

test_fixture_root_gone_after_normal_exit
test_fixture_root_gone_after_sigterm
test_cleanup_registry_resists_precreation
test_fixture_registration_failure_rolls_back_root
test_orphan_sweep_respects_fixture_ownership
test_orphan_sweep_reaps_read_only_package_tree
test_registries_avoid_git_worktree_root

test_owned_children_stop_on_every_exit() {
  local harness mode result rc leader child unrelated
  harness=$(fm_test_tmproot fm-owned-child-exits)
  sleep 30 & unrelated=$!
  CHILDREN+=("$unrelated")
  for mode in success failure interrupt; do
    rc=0
    result=$(bash -c '
      . "$1"
      FM_TEST_CHILD_REGISTRY="$2/registry-$3"
      python3 - "$2/pids-$3" <<'"'"'PYOWNED'"'"' &
import os, signal, sys, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
child=os.fork()
if child==0:
    while True: time.sleep(.1)
open(sys.argv[1],"w").write(f"{os.getpid()} {child}\n")
while True: time.sleep(.1)
PYOWNED
      owned=$!
      fm_test_track_child "$owned" kill
      i=0
      while [ ! -s "$2/pids-$3" ] && [ "$i" -lt 200 ]; do sleep .01; i=$((i+1)); done
      [ -s "$2/pids-$3" ] || exit 4
      case "$3" in failure) exit 42 ;; interrupt) kill -TERM "$$"; sleep 1 ;; esac
    ' _ "$LIB" "$harness" "$mode" 2>&1) || rc=$?
    case "$mode" in success) expect_code 0 "$rc" "$result" ;; failure) expect_code 42 "$rc" "$result" ;; interrupt) expect_code 143 "$rc" "$result" ;; esac
    read -r leader child < "$harness/pids-$mode"
    for result in "$leader" "$child"; do
      case "$(ps -p "$result" -o stat= 2>/dev/null)" in ''|Z*) ;; *) fail "owned process survived $mode cleanup: $result" ;; esac
    done
    kill -0 "$unrelated" 2>/dev/null || fail 'owned cleanup signalled an unrelated fixture'
  done
  kill "$unrelated" 2>/dev/null || true
  wait "$unrelated" 2>/dev/null || true
  CHILDREN[${#CHILDREN[@]}-1]=''
  pass 'owned TERM-resistant leaders and descendants stop on success, assertion failure and interruption'
}
test_owned_children_stop_on_every_exit

test_custom_cleanup_precedes_signal_tree_removal() {
  local harness
  harness=$(fm_test_tmproot fm-custom-signal-cleanup)
  LIB="$LIB" HARNESS="$harness" python3 - <<'PY'
import os, pathlib, signal, subprocess, time
base = pathlib.Path(os.environ['HARNESS'])
script = r'''
. "$1"
d=$(fm_test_tmproot fm-custom-signal-owner)
FM_TEST_CHILD_REGISTRY="$d/children"
cleanup() {
  [ -s "$d/children" ] && printf owned > "$2/cleanup-$3"
  fm_test_stop_children
  fm_test_cleanup
}
trap 'cleanup "$@"' EXIT
python3 - "$2/pids-$3" <<'OWNED' &
import os, signal, sys, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
child=os.fork()
if child == 0:
    time.sleep(45)
    os._exit(0)
open(sys.argv[1], 'w').write(f'{os.getpid()} {child}')
time.sleep(45)
OWNED
fm_test_track_child "$!" kill
printf '%s' "$d" > "$2/ready-$3"
case "$3" in success) exit 0 ;; failure) exit 42 ;; esac
deadline=$((SECONDS+30))
while [ "$SECONDS" -lt "$deadline" ]; do sleep .1; done
exit 4
'''
def reset_signals():
    signal.signal(signal.SIGINT, signal.SIG_DFL)
    signal.signal(signal.SIGQUIT, signal.SIG_DFL)
for mode, sig, expected in [('success', None, 0), ('failure', None, 42),
                             ('INT', signal.SIGINT, 130), ('TERM', signal.SIGTERM, 143),
                             ('HUP', signal.SIGHUP, 129), ('QUIT', signal.SIGQUIT, 131)]:
    proc = subprocess.Popen(['bash', '-c', script, '_', os.environ['LIB'], str(base), mode],
                            start_new_session=True, preexec_fn=reset_signals,
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        deadline=time.monotonic()+8
        while not ((base/f'ready-{mode}').exists() and (base/f'pids-{mode}').exists()):
            assert time.monotonic()<deadline, mode
            time.sleep(.02)
        fixture=pathlib.Path((base/f'ready-{mode}').read_text())
        if sig is not None:
            proc.send_signal(sig)
        _, err=proc.communicate(timeout=12)
        assert proc.returncode==expected, (mode, proc.returncode, err)
        assert (base/f'cleanup-{mode}').read_text()=='owned', mode
        assert not fixture.exists(), mode
        for pid in (base/f'pids-{mode}').read_text().split():
            state=subprocess.run(['ps', '-p', pid, '-o', 'stat='], capture_output=True, text=True).stdout.strip()
            assert not state or state.startswith('Z'), (mode, pid, state)
    finally:
        if proc.poll() is None:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
print('ok - custom ownership cleanup precedes tree removal on success, failure and every supported signal')
PY
}
test_custom_cleanup_precedes_signal_tree_removal


test_cleanup_resumes_only_the_registered_stopped_identity() {
  local child foreign i status
  sleep 30 & child=$!
  fm_test_track_child "$child" kill
  sleep 30 & foreign=$!
  fm_test_track_child "$foreign" kill
  kill -STOP "$child" "$foreign"
  for ((i=0;i<100;i++)); do
    status=$(ps -p "$child" -o stat=)
    case "$status" in *T*) break ;; esac
    sleep .01
  done
  case "$status" in *T*) ;; *) fail 'owned child never stopped' ;; esac
  local registry=$FM_TEST_CHILD_REGISTRY
  FM_TEST_CHILD_REGISTRY="$(fm_test_tmproot fm-stopped-only)/children"
  fm_test_track_child "$child" kill
  fm_test_stop_children || fail 'registered stopped child survived cleanup'
  case "$(ps -p "$foreign" -o stat=)" in *T*) ;; *) fail 'cleanup resumed an unregistered stopped child' ;; esac
  FM_TEST_CHILD_REGISTRY=$registry
  fm_test_stop_children || fail 'remaining fixture cleanup failed'
  pass 'cleanup resumes verified stopped children and leaves unregistered stopped processes untouched'
}
test_cleanup_resumes_only_the_registered_stopped_identity
