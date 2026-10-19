#!/usr/bin/env bash
# Exercise heartbeat delivery through the watcher and the real backlog consumer.
set -u
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-watch-ready-queue)

test_ready_queue_addressing() {
  local form=$1 dir result rc
  dir=$(make_case "addressing-$form")
  mkdir -p "$dir/data" "$dir/home/.tasks-axi"
  printf 'backend = "beads"\n' > "$dir/.tasks.toml"
  printf 'backend = "markdown"\n' > "$dir/home/.tasks-axi/config.toml"
  cat > "$dir/fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
[ "$1" = list ] || exit 2
[ "$PWD" = "$FM_TEST_BACKLOG_ROOT" ] || exit 2
[ -z "${TASKS_AXI_FILE:-}" ] || exit 2
printf '%s\n' "$PWD" >> "$FM_TEST_READY_LOG"
case "$FM_TEST_READY_RESULT" in
  ready) printf 'count: 1\ntasks[1]{id,state,kind,repo,title,deps,blocked,blocked_by,held,hold_kind,hold_reason,hold_until}:\n  ready,queued,task,"-",ready,none,no,none,no,"-","-","-"\n' ;;
  empty) printf 'count: 0\n' ;;
  failed) exit 2 ;;
esac
SH
  chmod +x "$dir/fakebin/tasks-axi"
  for result in ready empty failed; do
    : > "$dir/ready.log"
    # Each addressing verdict is an independent owning-home observation.
    rm -f "$dir/state/.ready-review.json"
    (
      cd "$dir" || exit 2
      local addressing_home="$dir"
      export FM_TEST_BACKLOG_ROOT="$dir" FM_TEST_READY_LOG="$dir/ready.log"
      export FM_TEST_READY_RESULT="$result"
      unset TASKS_AXI_BACKEND FM_DATA_OVERRIDE
      case "$form" in
        absolute) export FM_DATA_OVERRIDE="$dir/data" ;;
        relative) export FM_DATA_OVERRIDE=data ;;
        trailing-slash) export FM_DATA_OVERRIDE="$dir/data/" ;;
        relative-home) addressing_home=. ;;
        trailing-slash-home) addressing_home="$dir/" ;;
      esac
      # shellcheck source=bin/fm-ready-queue-lib.sh
      . "$ROOT/bin/fm-ready-queue-lib.sh"
      FM_HOME="$addressing_home" HOME="$dir/home" PATH="$dir/fakebin:$PATH" \
        fm_ready_queue_needs_review
    )
    rc=$?
    if [ "$result" = empty ]; then
      [ "$rc" = 1 ] || fail "$form empty queue required review"
    else
      [ "$rc" = 0 ] || fail "$form $result queue was silently suppressed"
    fi
    [ "$(cat "$dir/ready.log")" = "$dir" ] || fail "$form did not query the selected backlog root"
  done
  pass "$form backlog addressing preserves ready, empty, and unavailable verdicts"
}

test_ready_heartbeat() {
  local mode=${1:-ready} dir pid out
  dir=$(make_case "$mode-heartbeat")
  mkdir -p "$dir/data" "$dir/config"
  cp "$ROOT/.tasks.toml" "$dir/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/data/backlog.md"
  FM_HOME="$dir" "$ROOT/bin/fm-tasks-axi.sh" add cap-ready 'beyond current spend cap' >/dev/null \
    || fail 'could not queue candidate with stale spending title'
  FM_HOME="$dir" "$ROOT/bin/fm-tasks-axi.sh" add dependency 'landed dependency' >/dev/null \
    || fail 'could not create dependency'
  FM_HOME="$dir" "$ROOT/bin/fm-tasks-axi.sh" block cap-ready --by dependency >/dev/null \
    || fail 'could not record dependency'
  FM_HOME="$dir" "$ROOT/bin/fm-tasks-axi.sh" 'done' dependency --pr https://github.com/example/fixture/pull/1 >/dev/null \
    || fail 'could not record landed dependency'
  if [ "$mode" = unreadable ]; then
    printf '#!/usr/bin/env bash\nprintf "readiness unavailable\\n" >&2\nexit 2\n' > "$dir/fakebin/tasks-axi"
    chmod +x "$dir/fakebin/tasks-axi"
  fi
  # No away record, live worker, or new status event: the queue itself must
  # cause a fleet review after a restriction expires.
  out="$dir/watch.out"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_POLL=0.2 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=1 "$ROOT/bin/fm-watch.sh" > "$out" &
  pid=$!
  wait_for_exit "$pid" 60 || fail 'ready queue heartbeat was absorbed without a supervision turn'
  [ "$(cat "$out")" = heartbeat ] || fail 'ready queue did not produce heartbeat wake'
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" "$ROOT/bin/fm-wake-drain.sh" > "$dir/drain.out" 2>/dev/null \
    || fail 'could not drain queued heartbeat'
  assert_contains "$(cat "$dir/drain.out")" "$(printf '\theartbeat\t')" 'heartbeat was not durably delivered'
  pass "$mode queue reaches supervision despite stale title and silent status logs"
}

test_not_ready_heartbeat() {
  local mode=$1 dir pid out i rc
  dir=$(make_case "$mode-heartbeat")
  mkdir -p "$dir/data" "$dir/config"
  cp "$ROOT/.tasks.toml" "$dir/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/data/backlog.md"
  if [ "$mode" = held ]; then
    FM_HOME="$dir" "$ROOT/bin/fm-tasks-axi.sh" add held 'waiting for captain' >/dev/null \
      || fail 'could not add held task'
    FM_HOME="$dir" "$ROOT/bin/fm-captain-hold.sh" hold held --reason 'explicit captain hold' >/dev/null \
      || fail 'could not hold task'
  fi
  out="$dir/watch.out"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_POLL=0.2 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=1 "$ROOT/bin/fm-watch.sh" > "$out" &
  pid=$!
  for ((i=0; i<60; i++)); do
    [ "$(cat "$dir/state/.heartbeat-streak" 2>/dev/null || echo 0)" -ge 1 ] && break
    sleep 0.1
  done
  kill -TERM "$pid" 2>/dev/null || true
  wait_for_exit "$pid" 60
  rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 143 ] || fail 'quiet watcher did not stop'
  [ "$(cat "$dir/state/.heartbeat-streak" 2>/dev/null || echo 0)" -ge 1 ] \
    || fail "$mode queue was not reviewed"
  [ ! -s "$out" ] && [ ! -s "$dir/state/.wake-queue" ] \
    || fail "$mode queue produced an unnecessary heartbeat wake"
  pass "$mode queue remains quiet without dispatchable work"
}

test_emitted_stop_revalidation_contract() {
  local prompt
  # This is the final generated agent interface, not implementation source;
  # it verifies delivery of the rule, not the model's interpretation of it.
  prompt=$("$ROOT/bin/fm-branch-prompt.sh") || fail 'could not generate supervision prompt'
  assert_contains "$prompt" "Before treating any finish or fleet check as handled, verify every candidate's recorded stop against current dependencies, holds, away posture, spend cap, and worker capacity" 'emitted prompt omitted current-stop verification'
  assert_contains "$prompt" 'a stale title or earlier restriction never establishes a current stop, and a cleared restriction requires dispatch or the attended handoff in this turn' 'emitted prompt omitted expired-stop dispatch'
  pass 'emitted supervision prompt requires current stop verification after finish'
}

test_emitted_away_scope_gate() {
  local prompt
  # The away-scope gate is delivered through this generated interface, so the
  # emitted bytes are the surface a test can prove; the branch's own reading of
  # the captain's words is not.
  prompt=$("$ROOT/bin/fm-branch-prompt.sh") || fail 'could not generate supervision prompt'
  assert_contains "$prompt" 'Away, standing autonomy does not widen: dispatch only the queued unblocked work the recorded away words name or a standing grant covers' 'emitted prompt let away dispatch widen past the recorded words'
  assert_contains "$prompt" 'Every other ready unit waits for MAIN, and you record its not-ready reason on its backlog note' 'emitted prompt omitted the waiting reason for out-of-scope away work'
  assert_contains "$prompt" 'This is the durable handoff, even for an unsolicited cleanup or heartbeat; a routine note never substitutes for it' 'emitted prompt lost the attended handoff'
  pass 'emitted supervision prompt gates away dispatch to the recorded words and keeps the attended handoff'
}

test_daemon_heartbeat() {
  local mode=$1 skip=${2:-heartbeat} dir state
  dir=$(make_case "daemon-$mode-$skip")
  state="$dir/state"
  mkdir -p "$dir/data" "$dir/config"
  cp "$ROOT/.tasks.toml" "$dir/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/data/backlog.md"
  printf 'mode: quiet\n' > "$state/.afk"
  if [ "$mode" != empty ]; then
    FM_HOME="$dir" "$ROOT/bin/fm-tasks-axi.sh" add queued 'next unit' >/dev/null || fail 'could not queue unit'
    FM_HOME="$dir" "$ROOT/bin/fm-tasks-axi.sh" add dependency 'dependency' >/dev/null || fail 'could not add dependency'
    FM_HOME="$dir" "$ROOT/bin/fm-tasks-axi.sh" block queued --by dependency >/dev/null || fail 'could not set dependency'
    FM_HOME="$dir" "$ROOT/bin/fm-tasks-axi.sh" 'done' dependency --pr https://github.com/example/fixture/pull/1 >/dev/null || fail 'could not land dependency'
  fi
  if [ "$mode" = held ]; then
    FM_HOME="$dir" "$ROOT/bin/fm-captain-hold.sh" hold queued --reason 'explicit hold' >/dev/null || fail 'could not hold unit'
  fi
  if [ "$mode" = unreadable ]; then
    printf '#!/usr/bin/env bash\nexit 2\n' > "$dir/fakebin/tasks-axi"
    chmod +x "$dir/fakebin/tasks-axi"
  fi
  if [ "$mode" = failed ]; then
    mkdir "$state/.subsuper-escalations"
  fi
  append_wake "$state" heartbeat heartbeat heartbeat || fail 'could not enqueue daemon heartbeat'
  (
    # shellcheck source=/dev/null # Production module is linted separately.
    . "$ROOT/bin/fm-supervise-daemon.sh"
    # shellcheck disable=SC2034 # Used by the sourced daemon's log function.
    LOG="$state/daemon.log"
    if [ "$mode" != empty ]; then
      if FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$dir/config" \
        PATH="$dir/fakebin:$PATH" FM_INJECT_SKIP="$skip" FM_ESCALATE_BATCH_SECS=90 \
        handle_durable_wakes heartbeat "$state"; then
        fail 'daemon acknowledged ready review without a current disposition'
      fi
    else
      FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$dir/config" \
        PATH="$dir/fakebin:$PATH" FM_INJECT_SKIP="$skip" FM_ESCALATE_BATCH_SECS=90 \
        handle_durable_wakes heartbeat "$state" || fail 'daemon heartbeat handling failed'
    fi
  ) || fail 'daemon handling assertions failed'
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" > "$dir/remaining" 2>/dev/null || fail 'could not inspect remaining wakes'
  case "$mode" in
    empty)
      [ ! -s "$state/.subsuper-escalations" ] || fail 'nonready work reached dispatcher'
      [ ! -s "$dir/remaining" ] || fail 'nonready heartbeat remained unacknowledged'
      ;;
    failed)
      assert_contains "$(cat "$dir/remaining")" "$(printf '\theartbeat\t')" 'failed handoff lost its durable wake'
      ;;
    *)
      assert_contains "$(cat "$state/.subsuper-escalations")" 'ready-queue fleet check:' 'ready work was silently consumed'
      assert_contains "$(cat "$dir/remaining")" "$(printf '\theartbeat\t')" 'ready review was consumed before MAIN acted'
      ;;
  esac
  pass "daemon $mode heartbeat respects readiness before skip=$skip and acknowledgement"
}


test_ready_review_contract() {
  export -f fm_test_track_child fm_test_stop_children
  ROOT="$ROOT" REVIEW_TMP="$TMP_ROOT/review-contract" python3 - <<'PYTEST'
import json
import os
from pathlib import Path
import subprocess

root = Path(os.environ['ROOT'])
base = Path(os.environ['REVIEW_TMP'])
base.mkdir()


def home(name):
    path = base / name
    for directory in ('data', 'state', 'config'):
        (path / directory).mkdir(parents=True)
    (path / '.tasks.toml').write_text((root / '.tasks.toml').read_text())
    (path / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    return path


def call(path, script, *args, ok=True):
    env = dict(os.environ, FM_HOME=str(path), FM_STATE_OVERRIDE=str(path / 'state'),
               FM_DATA_OVERRIDE=str(path / 'data'), FM_CONFIG_OVERRIDE=str(path / 'config'))
    result = subprocess.run([str(root / 'bin' / script), *args], env=env,
                            capture_output=True, text=True, timeout=25)
    if ok:
        assert result.returncode == 0, (script, args, result.stderr)
    else:
        assert result.returncode != 0, (script, args, 'unexpected success')
    return result


def task(path, *args):
    return call(path, 'fm-tasks-axi.sh', *args)


def review(path, *args, **kwargs):
    return call(path, 'fm-ready-review.sh', *args, **kwargs)


def scan(path):
    return json.loads(review(path, 'scan').stdout)


def generation(path, name='dependent'):
    return scan(path)['candidates'][name]['generation']


def seed(path, partial=False):
    for name in ('dependency', 'dependent'):
        task(path, 'add', name, name)
    task(path, 'block', 'dependent', '--by', 'dependency')
    task(path, 'hold', 'dependent', '--kind', 'captain', '--reason', 'captain approval pending')
    if partial:
        task(path, 'add', 'other', 'other dependency')
        task(path, 'hold', 'other', '--kind', 'external', '--reason', 'external review')
        task(path, 'block', 'dependent', '--by', 'other')
    task(path, 'done', 'dependency', '--no-prune')


def stop(path, name='dependent', gate='structured'):
    review(path, 'stop', name, generation(path, name), '--gate', gate,
           '--reason', 'current explicit gate', '--retry', 'review when the gate changes')


h = home('held')
seed(h, partial=True)
review(h, 'needs-review')
first = generation(h)
assert scan(h)['candidates']['dependent']['facts']['dependencies']['other'] == 'queued'
review(h, 'guard', 'main', ok=False)
call(h, 'fm-branch-outcome.sh', 'append', '--task', 'fleet', '--verdict', 'routine', '--summary', 'no action', ok=False)
assert not (h / 'state/branch-outcomes.jsonl').exists()
seq = call(h, 'fm-branch-outcome.sh', 'append', '--task', 'fleet', '--verdict', 'captain', '--summary', 'Review the queued work').stdout.strip()
record = json.loads((h / 'state/branch-outcomes.jsonl').read_text())
assert record['readyReview']['candidates'] == [{'task': 'dependent', 'generation': first}]
review(h, 'guard', 'branch')
review(h, 'guard', 'main', ok=False)
review(h, 'needs-review', ok=False)  # Durable unconsumed handoff suppresses repeat offers.
call(h, 'fm-branch-outcome.sh', 'mark-read', '--through', seq)
call(h, 'fm-branch-outcome.sh', 'mark-processed', '--through', seq, ok=False)
stop(h)
call(h, 'fm-branch-outcome.sh', 'mark-processed', '--through', seq)
assert 'held: yes' in task(h, 'show', 'dependent').stdout
review(h, 'needs-review', ok=False)
task(h, 'done', 'other', '--no-prune')
second = generation(h)
assert first != second
review(h, 'stop', 'dependent', first, '--gate', 'structured', '--reason', 'old', '--retry', 'old', ok=False)
review(h, 'needs-review')
stop(h)
review(h, 'guard', 'main')
task(h, 'unhold', 'dependent')
review(h, 'guard', 'main', ok=False)
review(h, 'stop', 'dependent', generation(h), '--gate', 'structured', '--reason', 'obsolete hold', '--retry', 'none', ok=False)
print('ok - partial dependency, held-only review, attended durable handoff, MAIN guard, stale stop and hold preservation')

# Other gate decisions remain explicit attestations and are bounded/revalidated.
for gate in ('approval', 'credential', 'account', 'spend', 'capacity', 'away', 'external'):
    stop(h, gate=gate)
    review(h, 'guard', 'main')
    (h / 'config/worker-target').write_text(str(5 + len(gate)) + '\n')
    review(h, 'guard', 'main', ok=False)
    (h / 'config/worker-target').unlink()
stop(h, gate='capacity')
ledger = h / 'state/.ready-review.json'
saved = json.loads(ledger.read_text())
saved['candidates']['dependent']['stop']['until'] = 1
ledger.write_text(json.dumps(saved))
review(h, 'guard', 'main', ok=False)
print('ok - explicit gate stops expire and gate configuration changes re-open review')

shared = home('capacity-root')
sibling = home('capacity-sibling')
(h / '.fm-secondmate-parent').write_text(f'schema=fm-secondmate-parent.v1\nroute=local\nparent_home={shared}\n')
(shared / 'data/secondmates.md').write_text(
    f'- b - reviewer (home: {h}; scope: all; projects: all; added 2026-10-18)\n'
    f'- a - worker (home: {sibling}; scope: all; projects: all; added 2026-10-18)\n')
worker = sibling / 'state/worker.meta'
worker.write_text('kind=ship\nspawn_gen=s1.2.3\nproject=/synthetic/project\n')
stop(h, gate='capacity')
review(h, 'guard', 'main')
review(h, 'guard', 'main')
worker.write_text(worker.read_text() + 'pr=https://github.com/owner/repo/pull/1\npr_spawn_gen=s1.2.3\n')
review(h, 'guard', 'main', ok=False)
review(h, 'poll')
assert (h / 'state/.wake-queue').exists()
stop(h, gate='capacity')
review(h, 'guard', 'main')
worker.unlink()
review(h, 'guard', 'main', ok=False)
stop(h, gate='capacity')
(shared / 'config/project-capacity').write_text('project 2\n')
review(h, 'guard', 'main', ok=False)
stop(h, gate='capacity')
worker.symlink_to(shared / 'config/project-capacity')
review(h, 'guard', 'main', ok=False)
worker.unlink()
(h / '.fm-secondmate-parent').unlink()
print('ok - shared ready handoff, worker removal, root capacity changes and unsafe records invalidate stops')

# Starting a row, writing a plausible status, or directly invoking the hook is
# deliberately insufficient; exact SDK + real fm-spawn proves the positive path.
task(h, 'start', 'dependent')
(h / 'state/dependent.status').write_text('working: processing requested brief\n')
(h / 'state/dependent.meta').write_text('kind=ship\nendpoint_task_id=dependent\nspawn_gen=s1.2.3\n')
review(h, 'launch', 'dependent', 's1.2.3', ok=False)
review(h, 'guard', 'main', ok=False)
print('ok - In flight, fabricated status and direct launch receipt cannot prove requested worker start')
before_done = generation(h)
task(h, 'done', 'dependent', '--no-prune')
assert generation(h) != before_done
review(h, 'guard', 'main', ok=False)
stop(h, gate='external')
review(h, 'guard', 'main')
before_missing = generation(h)
task(h, 'done', 'dependent', '--keep', '0')
assert generation(h) != before_missing
review(h, 'guard', 'main', ok=False)
print('ok - Done and removal invalidate old dispositions without fabricating start or completion')

other = home('same-id-other-home')
seed(other)
other_ledger = other / 'state/.ready-review.json'
other_ledger.write_text(ledger.read_text())
review(other, 'scan', ok=False)
other_ledger.unlink()
assert generation(other) != generation(h)
review(other, 'stop', 'dependent', generation(h), '--gate', 'structured', '--reason', 'foreign', '--retry', 'foreign', ok=False)
print('ok - same task IDs in independent homes and foreign generation/ledger are refused')

missing = home('archived-node')
seed(missing)
task(missing, 'done', 'dependency', '--keep', '0')
assert scan(missing)['candidates']['dependent']['facts']['dependencies']['dependency'] == 'missing'
review(missing, 'guard', 'main', ok=False)
assert 'held: yes' in task(missing, 'show', 'dependent').stdout
print('ok - pruned dependency is uncertainty, never known Done or hold-release authority')

# Report append failure cannot create handoff coverage; restart reads pending work.
failure = home('append-failure')
seed(failure)
(failure / 'state/branch-outcomes.jsonl').mkdir()
call(failure, 'fm-branch-outcome.sh', 'append', '--task', 'fleet', '--verdict', 'captain', '--summary', 'handoff', ok=False)
(failure / 'state/branch-outcomes.jsonl').rmdir()
review(failure, 'needs-review')
review(failure, 'guard', 'branch', ok=False)
for shape in ('link', 'fifo', 'directory'):
    path = failure / 'state/.ready-review.json'
    before = path.read_bytes()
    path.unlink()
    if shape == 'link':
        path.symlink_to(base / 'missing-ledger')
    elif shape == 'fifo':
        os.mkfifo(path)
    else:
        path.mkdir()
    review(failure, 'guard', 'main', ok=False)
    path.rmdir() if shape == 'directory' else path.unlink()
    path.write_bytes(before)
review(failure, 'needs-review')
print('ok - append failure, restart and unsafe ledger inputs retain review responsibility without blocking reads')
queue = failure / 'state/.wake-queue'
queue.mkdir()
review(failure, 'poll', ok=False)
queue.rmdir()
assert review(failure, 'poll').stdout.strip() == 'heartbeat'
queued = queue.read_bytes()
assert review(failure, 'poll').stdout == ''
assert queue.read_bytes() == queued
assert len(queued.splitlines()) == 1
print('ok - failed wake publication retries before deduplication and restart coalesces unconsumed review')

# Protocol fixture: launch/current-state owners are process-backed test doubles.
# This proves observed-start persistence, not SDK launch acceptance (the real
# SDK/supervisor/fm-spawn integration owns that separate acceptance).
import shutil
import signal
import time
import atexit
owned_processes = []
owned_signals = (signal.SIGINT, signal.SIGTERM, signal.SIGHUP, signal.SIGQUIT)
def interrupted(signum, frame):
    for sig in owned_signals:
        signal.signal(sig, signal.SIG_IGN)
    raise SystemExit(128 + signum)
for sig in owned_signals:
    signal.signal(sig, interrupted)
def launch_owned(*args, **kwargs):
    blocked = signal.pthread_sigmask(signal.SIG_BLOCK, owned_signals)
    try:
        process = subprocess.Popen(*args, preexec_fn=lambda: signal.pthread_sigmask(signal.SIG_SETMASK, blocked), **kwargs)
        owned_processes.append(process)
        registry = base / f'owner-{process.pid}'
        subprocess.run(['bash', '-c', 'fm_test_track_child "$1" kill', '_', str(process.pid)],
                       env=dict(os.environ, FM_TEST_CHILD_REGISTRY=str(registry)), check=True,
                       preexec_fn=lambda: signal.pthread_sigmask(signal.SIG_SETMASK, blocked))
        return process
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, blocked)
def stop_owned(process):
    registry = base / f'owner-{process.pid}'
    subprocess.run(['bash', '-c', 'fm_test_stop_children'],
                   env=dict(os.environ, FM_TEST_CHILD_REGISTRY=str(registry)), check=True, timeout=8)
    process.communicate(timeout=5)
def cleanup_owned():
    for process in reversed(owned_processes):
        stop_owned(process)
atexit.register(cleanup_owned)
fixture = base / 'owner-protocol'
shutil.copytree(root / 'bin', fixture / 'bin', symlinks=True)
shutil.copy2(root / '.tasks.toml', fixture / '.tasks.toml')
(fixture / 'bin/fm-spawn.sh').write_text('''#!/usr/bin/env bash
set -eu
bin=$(cd "$(dirname "$0")" && pwd)
sleep 120 &
child=$!
trap 'kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true' EXIT
printf '%s\n' "$child" > "$FM_HOME/child.pid"
ps -p "$child" -o lstart= > "$FM_HOME/child.start"
"$bin/fm-tasks-axi.sh" start dependent >/dev/null
printf 'kind=ship\nendpoint_task_id=dependent\nspawn_gen=s1.2.3\n' > "$FM_HOME/state/dependent.meta"
"$bin/fm-ready-review.sh" launch dependent s1.2.3
touch "$FM_HOME/launched"
wait "$child"
''')
(fixture / 'bin/fm-crew-state.sh').write_text('''#!/usr/bin/env python3
import os
import subprocess
from pathlib import Path
home=Path(os.environ['FM_HOME'])
try:
 pid=int((home/'child.pid').read_text())
 state=subprocess.run(['ps', '-p', str(pid), '-o', 'lstart='], capture_output=True, text=True)
 live=state.returncode == 0 and state.stdout.strip() == (home/'child.start').read_text().strip()
 if (home/'replace-during-processing').exists():
  (home/'state/dependent.meta').write_text('endpoint_task_id=dependent\\nspawn_gen=s2.3.4\\n')
  (home/'replace-during-processing').unlink()
 print('state: working · source: pane · process-backed test observation' if live and not (home/'idle').exists() else 'state: unknown · source: none · idle test process')
except (OSError,ValueError):
 print('state: unknown · source: none · missing test process')
''')
saved_root = root
root = fixture
process_home = home('observed-processing')
seed(process_home)
task(process_home, 'unhold', 'dependent')
original = generation(process_home)
env = dict(os.environ, FM_HOME=str(process_home), FM_STATE_OVERRIDE=str(process_home / 'state'),
           FM_DATA_OVERRIDE=str(process_home / 'data'))
child = launch_owned(['bash', 'bin/fm-spawn.sh'], cwd=fixture, env=env, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, text=True, start_new_session=True)
try:
    deadline = time.monotonic() + 10
    while not (process_home / 'launched').exists() and time.monotonic() < deadline:
        assert child.poll() is None, child.communicate()
        time.sleep(.05)
    assert (process_home / 'launched').exists(), 'process-backed launch hook did not complete'
    review(process_home, 'guard', 'main')
    proof = scan(process_home)['candidates']['dependent']['observed_start']
    assert proof['generation'] == original and proof['spawn_gen'] == 's1.2.3'
    (process_home / 'idle').touch()
    review(process_home, 'guard', 'main')
    task(process_home, 'done', 'dependent', '--no-prune')
    review(process_home, 'guard', 'main')
    task(process_home, 'done', 'dependent', '--keep', '0')
    review(process_home, 'guard', 'main')
    task(process_home, 'add', 'dependent', 'new incarnation')
    assert generation(process_home) != original
    review(process_home, 'guard', 'main', ok=False)
finally:
    stop_owned(child)
    worker = int((process_home / 'child.pid').read_text())
    state = subprocess.run(['ps', '-p', str(worker), '-o', 'lstart='], capture_output=True, text=True)
    assert state.returncode != 0 or state.stdout.strip() != (process_home / 'child.start').read_text().strip()
    root = saved_root
print('ok - process-backed owner proof persists after idle, Done and removal; recreated ID needs a fresh start (protocol fixture only)')

# Exercise recovery at the same public owner boundary. The child is a real
# bounded process; launch/current-processing remain explicitly test doubles.
# The separate SDK fixture proves real fm-spawn and harness integration.
import re
import traceback
(fixture / 'bin/fm-tasks-axi.sh').rename(fixture / 'bin/fm-tasks-axi-real.sh')
(fixture / 'bin/fm-tasks-axi.sh').write_text('''#!/usr/bin/env bash
set -eu
if [ "${1:-}" = list ] && [ -f "$FM_HOME/graph-unavailable" ]; then exit 2; fi
if [ "${1:-}" = list ] && [ -f "$FM_HOME/change-graph-during-hook" ]; then
  rm "$FM_HOME/change-graph-during-hook"
  "$(dirname "$0")/fm-tasks-axi-real.sh" hold dependent --kind captain --reason 'new authority during launch hook' >/dev/null
fi
exec "$(dirname "$0")/fm-tasks-axi-real.sh" "$@"
''')
(fixture / 'bin/fm-tasks-axi.sh').chmod(0o755)
(fixture / 'bin/fm-spawn.sh').write_text('''#!/usr/bin/env bash
set -eu
bin=$(cd "$(dirname "$0")" && pwd)
generation=$1
sleep 180 &
child=$!
trap 'kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true' EXIT
trap 'exit 143' TERM
printf '%s\n' "$child" > "$FM_HOME/child.pid"
ps -p "$child" -o lstart= > "$FM_HOME/child.start"
if [ ! -f "$FM_HOME/relaunch" ] && [ ! -f "$FM_HOME/keep-queued" ]; then "$bin/fm-tasks-axi.sh" start dependent >/dev/null; fi
printf 'kind=ship\nendpoint_task_id=dependent\nspawn_gen=%s\n' "$generation" > "$FM_HOME/state/dependent.meta"
if [ -f "$FM_HOME/fail-hook-graph" ]; then touch "$FM_HOME/graph-unavailable"; fi
if [ -f "$FM_HOME/change-hook-graph" ]; then touch "$FM_HOME/change-graph-during-hook"; fi
printf '%s\n' "$generation" >> "$FM_HOME/launch-calls"
status=0
"$bin/fm-ready-review.sh" launch dependent "$generation" || status=$?
printf '%s\n' "$status" > "$FM_HOME/hook-status"
touch "$FM_HOME/hook-done"
wait "$child"
''')


def protocol_launch(path, spawn='s1.2.3'):
    for name in ('hook-done', 'hook-status'):
        (path / name).unlink(missing_ok=True)
    env = dict(os.environ, FM_HOME=str(path), FM_STATE_OVERRIDE=str(path / 'state'),
               FM_DATA_OVERRIDE=str(path / 'data'), FM_CONFIG_OVERRIDE=str(path / 'config'))
    process = launch_owned(['bash', 'bin/fm-spawn.sh', spawn], cwd=fixture, env=env,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                               start_new_session=True)
    try:
        deadline = time.monotonic() + 10
        while not (path / 'hook-done').exists() and time.monotonic() < deadline:
            assert process.poll() is None, process.communicate()
            time.sleep(.02)
        assert (path / 'hook-done').exists(), 'confirmed launch hook did not finish'
        worker = int((path / 'child.pid').read_text())
        started = (path / 'child.start').read_text().strip()
        current = subprocess.run(['ps', '-p', str(worker), '-o', 'lstart='],
                                 capture_output=True, text=True, timeout=5)
        assert current.returncode == 0 and current.stdout.strip() == started
        return process, worker, started
    except BaseException:
        stop_owned(process)
        raise


def protocol_stop(owned):
    process, worker, started = owned
    # Popen retains ownership of this unreaped direct child; the worker is
    # checked against its recorded start identity after the group exits.
    if process.poll() is None:
        stop_owned(process)
    current = subprocess.run(['ps', '-p', str(worker), '-o', 'lstart='],
                             capture_output=True, text=True, timeout=5)
    assert current.returncode != 0 or current.stdout.strip() != started, 'owned worker survived cleanup'


def observed_home(name, owned):
    path = home(name)
    seed(path)
    task(path, 'unhold', 'dependent')
    gen = generation(path)
    owned.append(protocol_launch(path))
    assert (path / 'hook-status').read_text().strip() == '0'
    review(path, 'guard', 'main')
    item = scan(path)['candidates']['dependent']
    assert item['observed_start']['generation'] == gen
    return path, item


def pending_guards(path):
    refused = review(path, 'guard', 'main', ok=False)
    assert 'unhandled ready review' in refused.stderr
    review(path, 'report-check', 'routine', ok=False)
    # Offer a real durable wake before a branch handoff suppresses repeat offers.
    review(path, 'poll')
    drained = call(path, 'fm-wake-drain.sh')
    presentation = drained.stdout + drained.stderr
    match = re.search(r'WAKE_ACK_REQUIRED:.*--ack-through (\d+) --recovery-generation (\S+)', presentation)
    assert match, presentation
    queue = path / 'state/.wake-queue'
    before = queue.read_bytes()
    refused = call(path, 'fm-wake-drain.sh', '--ack-through', match[1],
                   '--recovery-generation', match[2], ok=False)
    assert 'unhandled ready review' in refused.stderr, refused.stderr
    assert queue.read_bytes() == before, 'pending execution was acknowledged'
    seq = call(path, 'fm-branch-outcome.sh', 'append', '--task', 'fleet', '--verdict', 'captain',
               '--summary', 'Current execution still required').stdout.strip()
    call(path, 'fm-branch-outcome.sh', 'mark-read', '--through', seq)
    call(path, 'fm-branch-outcome.sh', 'mark-processed', '--through', seq, ok=False)
    return seq


def reopen_after_teardown(owned):
    path, before = observed_home('reopen-after-teardown', owned)
    protocol_stop(owned.pop())
    (path / 'state/dependent.meta').unlink()
    # Teardown and reopening occur between review observations: the owner last
    # saw In flight, never the intermediate Done row or removed task metadata.
    task(path, 'done', 'dependent', '--no-prune')
    task(path, 'reopen', 'dependent')
    after = scan(path)['candidates']['dependent']
    assert after['state'] == 'queued' and not (path / 'state/dependent.meta').exists()
    assert after['facts'] == before['facts'], 'reopen did not isolate lifecycle from graph facts'
    assert after['generation'] != before['generation'], 'reopened work retained its old generation'
    assert 'observed_start' not in after and 'launch' not in after
    seq = pending_guards(path)
    # A current stop settles this new obligation, and changing its retry facts
    # reopens it. Only a fresh confirmed launch/current start settles execution.
    stop(path, gate='external')
    review(path, 'guard', 'main')
    (path / 'config/worker-target').write_text('7\n')
    review(path, 'guard', 'main', ok=False)
    owned.append(protocol_launch(path, 's2.3.4'))
    review(path, 'guard', 'main')
    fresh = scan(path)['candidates']['dependent']['observed_start']
    assert fresh['generation'] == after['generation'] and fresh['spawn_gen'] == 's2.3.4'
    call(path, 'fm-branch-outcome.sh', 'mark-processed', '--through', seq)


def graph_failure_after_launch(owned):
    path = home('confirmed-launch-graph-failure')
    seed(path)
    task(path, 'unhold', 'dependent')
    gen = generation(path)
    (path / 'idle').touch()
    (path / 'fail-hook-graph').touch()
    owned.append(protocol_launch(path))
    assert (path / 'hook-status').read_text().strip() == '0', 'published launch lost its graph-independent receipt'
    book = json.loads((path / 'state/.ready-review.json').read_text())
    item = book['candidates']['dependent']
    assert book['uncertainty'] and item['confirmed_launch']['generation'] == gen
    assert item['confirmed_launch']['spawn_gen'] == 's1.2.3' and 'observed_start' not in item
    review(path, 'guard', 'main', ok=False)
    (path / 'graph-unavailable').unlink()
    seq = pending_guards(path)  # A confirmed launch alone is still insufficient.
    item = scan(path)['candidates']['dependent']
    assert item['launch']['generation'] == gen and 'confirmed_launch' not in item
    assert 'observed_start' not in item
    (path / 'idle').unlink()
    review(path, 'guard', 'main')
    assert scan(path)['candidates']['dependent']['observed_start']['spawn_gen'] == 's1.2.3'
    assert (path / 'launch-calls').read_text().splitlines() == ['s1.2.3'], 'recovery replayed a launch'
    call(path, 'fm-branch-outcome.sh', 'mark-processed', '--through', seq)


def prune_existing_worker(owned):
    path, before = observed_home('observed-worker-prerequisite-pruned', owned)
    stop(path, gate='capacity')
    task(path, 'done', 'dependency', '--keep', '0')
    after = scan(path)['candidates']['dependent']
    assert after['facts']['dependencies'] == {'dependency': 'missing'}
    assert after['generation'] != before['generation'] and 'stop' not in after
    assert after.get('observed_start') == before['observed_start'], 'pruning erased the actual observed start'
    assert after.get('launch') == before['launch']
    assert after.get('start_generation') == before['generation']
    (path / 'idle').touch()
    review(path, 'guard', 'main')
    review(path, 'report-check', 'routine')
    task(path, 'hold', 'dependent', '--kind', 'captain', '--reason', 'new captain authority')
    after = scan(path)['candidates']['dependent']
    assert 'observed_start' not in after and 'start_generation' not in after
    review(path, 'guard', 'main', ok=False)
    assert 'held: yes' in task(path, 'show', 'dependent').stdout


def denied_lifecycle_changes(owned):
    for change in ('requeue', 'hold', 'dependency-edge', 'dependency-reopened', 'replacement',
                   'metadata-removed', 'metadata-malformed', 'metadata-duplicate', 'foreign-home', 'foreign-task'):
        path, before = observed_home('denied-anchor-' + change, owned)
        if change == 'requeue':
            task(path, 'done', 'dependent', '--no-prune')
            task(path, 'reopen', 'dependent')
        elif change == 'hold':
            task(path, 'hold', 'dependent', '--kind', 'captain', '--reason', 'fresh authority')
        elif change == 'dependency-edge':
            task(path, 'add', 'extra', 'new prerequisite')
            task(path, 'block', 'dependent', '--by', 'extra')
        elif change == 'dependency-reopened':
            task(path, 'reopen', 'dependency')
        else:
            meta = path / 'state/dependent.meta'
            if change == 'metadata-removed':
                meta.unlink()
            elif change == 'metadata-malformed':
                meta.write_text('endpoint_task_id=dependent\nspawn_gen=invalid\n')
            elif change == 'metadata-duplicate':
                with meta.open('a') as stream:
                    stream.write('spawn_gen=s1.2.3\n')
            elif change == 'foreign-home':
                with meta.open('a') as stream:
                    stream.write('home=' + str(base / 'foreign') + '\n')
            elif change == 'foreign-task':
                meta.write_text('endpoint_task_id=other\nspawn_gen=s1.2.3\n')
            else:
                meta.write_text('endpoint_task_id=dependent\nspawn_gen=s2.3.4\n')
            task(path, 'done', 'dependency', '--keep', '0')
        after = scan(path)['candidates']['dependent']
        assert after['generation'] != before['generation'], change
        assert 'observed_start' not in after and 'launch' not in after and 'start_generation' not in after, change
        review(path, 'guard', 'main', ok=False)
        protocol_stop(owned.pop())
    print('ok - requeue, holds, dependency changes and invalid/replaced/foreign metadata cannot reuse observed starts')


def denied_pending_launches(owned):
    for change in ('hold', 'dependency-edge', 'requeue', 'replacement', 'metadata-removed', 'foreign-home', 'foreign-task'):
        path = home('denied-pending-' + change)
        seed(path)
        task(path, 'unhold', 'dependent')
        gen = generation(path)
        (path / 'fail-hook-graph').touch()
        owned.append(protocol_launch(path))
        assert (path / 'hook-status').read_text().strip() == '0'
        assert 'confirmed_launch' in json.loads((path / 'state/.ready-review.json').read_text())['candidates']['dependent']
        if change == 'hold':
            task(path, 'hold', 'dependent', '--kind', 'captain', '--reason', 'fresh authority')
        elif change == 'dependency-edge':
            task(path, 'add', 'extra', 'new prerequisite')
            task(path, 'block', 'dependent', '--by', 'extra')
        elif change == 'requeue':
            # Observe In flight while still lacking current processing, then
            # reopen to queued. The old hook belongs to the previous lifecycle.
            (path / 'idle').touch()
            (path / 'graph-unavailable').unlink()
            scan(path)
            task(path, 'done', 'dependent', '--no-prune')
            task(path, 'reopen', 'dependent')
        elif change == 'metadata-removed':
            (path / 'state/dependent.meta').unlink()
        elif change == 'foreign-home':
            with (path / 'state/dependent.meta').open('a') as stream:
                stream.write('home=' + str(base / 'foreign') + '\n')
        elif change == 'foreign-task':
            (path / 'state/dependent.meta').write_text('endpoint_task_id=other\nspawn_gen=s1.2.3\n')
        else:
            (path / 'state/dependent.meta').write_text('endpoint_task_id=dependent\nspawn_gen=s2.3.4\n')
        (path / 'graph-unavailable').unlink(missing_ok=True)
        after = scan(path)['candidates']['dependent']
        assert 'launch' not in after and 'observed_start' not in after and 'confirmed_launch' not in after, change
        review(path, 'guard', 'main', ok=False)
        if change in ('replacement', 'metadata-removed', 'foreign-home', 'foreign-task'):
            # A metadata A-B-A must not revive a discarded pending receipt.
            (path / 'state/dependent.meta').write_text('endpoint_task_id=dependent\nspawn_gen=s1.2.3\n')
            review(path, 'guard', 'main', ok=False)
            assert 'observed_start' not in scan(path)['candidates']['dependent']
        if change in ('hold', 'dependency-edge', 'requeue'):
            assert after['generation'] != gen, change
        protocol_stop(owned.pop())
    print('ok - unavailable-graph launch facts cannot cross candidate, task, home or spawn changes; busy alone is insufficient')


def changed_metadata_during_processing(owned):
    path = home('metadata-replaced-during-current-observation')
    seed(path)
    task(path, 'unhold', 'dependent')
    generation(path)
    owned.append(protocol_launch(path))
    (path / 'replace-during-processing').touch()
    review(path, 'guard', 'main', ok=False)
    assert not (path / 'replace-during-processing').exists(), 'current-state observation did not run'
    item = scan(path)['candidates']['dependent']
    assert 'observed_start' not in item, 'metadata changed across observation but start was accepted'
    review(path, 'guard', 'main', ok=False)


def changed_graph_during_launch_hook(owned):
    path = home('graph-epoch-changed-during-hook')
    seed(path)
    task(path, 'unhold', 'dependent')
    gen = generation(path)
    (path / 'change-hook-graph').touch()
    owned.append(protocol_launch(path))
    assert (path / 'hook-status').read_text().strip() != '0', 'hook rebound its old launch fact to a changed graph epoch'
    item = scan(path)['candidates']['dependent']
    assert item['generation'] != gen and item['facts']['held'] == 'yes'
    assert 'launch' not in item and 'observed_start' not in item and 'confirmed_launch' not in item
    review(path, 'guard', 'main', ok=False)
    assert (path / 'launch-calls').read_text().splitlines() == ['s1.2.3']


def fresh_confirmed_replacement(owned):
    path, before = observed_home('fresh-confirmed-replacement', owned)
    stop(path, gate='capacity')
    protocol_stop(owned.pop())
    (path / 'relaunch').touch()
    (path / 'idle').touch()
    owned.append(protocol_launch(path, 's2.3.4'))
    assert (path / 'hook-status').read_text().strip() == '0'
    item = scan(path)['candidates']['dependent']
    assert item['generation'] != before['generation']
    assert item['launch']['spawn_gen'] == 's2.3.4'
    assert 'observed_start' not in item and 'start_generation' not in item and 'stop' not in item
    review(path, 'guard', 'main', ok=False)
    (path / 'idle').unlink()
    review(path, 'guard', 'main')
    proof = scan(path)['candidates']['dependent']['observed_start']
    assert proof['generation'] == item['generation'] and proof['spawn_gen'] == 's2.3.4'


def malformed_lifecycle_anchor(owned):
    path, _before = observed_home('malformed-start-anchor', owned)
    ledger = path / 'state/.ready-review.json'
    original = ledger.read_bytes()
    for bad in ('not-a-generation', 'f' * 63, 'g' * 64, 123, None):
        book = json.loads(original)
        item = book['candidates']['dependent']
        item['start_generation'] = bad
        item['launch']['generation'] = bad
        item['observed_start']['generation'] = bad
        ledger.write_text(json.dumps(book))
        review(path, 'guard', 'main', ok=False)
        review(path, 'report-check', 'routine', ok=False)
    ledger.write_bytes(original)
    review(path, 'guard', 'main')


def manual_pending_owner_handoff(owned):
    for scanned in (False, True):
        path = home('manual-pending-' + str(scanned))
        seed(path)
        task(path, 'unhold', 'dependent')
        (path / 'config/backlog-backend').write_text('manual\n')
        (path / 'keep-queued').touch()
        (path / 'idle').touch()
        if scanned:
            generation(path)
        before = (path / 'data/backlog.md').read_bytes()
        owned.append(protocol_launch(path))
        assert (path / 'hook-status').read_text().strip() == '0'
        assert (path / 'data/backlog.md').read_bytes() == before
        item = scan(path)['candidates']['dependent']
        gen = item['generation']
        assert item['state'] == 'queued' and item['confirmed_launch']['generation'] == gen
        assert 'launch' not in item and 'observed_start' not in item
        seq = pending_guards(path)
        denied = review(path, 'launch', 'dependent', 's1.2.3', ok=False)
        assert 'requires the confirmed fm-spawn caller' in denied.stderr
        # Even actual processing cannot replace the manual owner's owed row edit.
        (path / 'idle').unlink()
        review(path, 'guard', 'main', ok=False)
        (path / 'idle').touch()
        task(path, 'start', 'dependent')
        item = scan(path)['candidates']['dependent']
        assert item['generation'] == gen and item['launch']['generation'] == gen
        assert 'confirmed_launch' not in item and 'observed_start' not in item
        review(path, 'guard', 'main', ok=False)
        (path / 'idle').unlink()
        review(path, 'guard', 'main')
        item = scan(path)['candidates']['dependent']
        assert item['observed_start']['spawn_gen'] == 's1.2.3'
        call(path, 'fm-branch-outcome.sh', 'mark-processed', '--through', seq)
        assert (path / 'launch-calls').read_text().splitlines() == ['s1.2.3']
        protocol_stop(owned.pop())


def automatic_queued_still_refused(owned):
    for scanned in (False, True):
        path = home('automatic-queued-' + str(scanned))
        seed(path)
        task(path, 'unhold', 'dependent')
        (path / 'keep-queued').touch()
        if scanned:
            generation(path)
        owned.append(protocol_launch(path))
        assert (path / 'hook-status').read_text().strip() != '0'
        item = scan(path)['candidates']['dependent']
        assert item['state'] == 'queued' and 'launch' not in item and 'observed_start' not in item
        review(path, 'guard', 'main', ok=False)
        protocol_stop(owned.pop())


def manual_pending_changes_still_refused(owned):
    for change in ('hold', 'dependency', 'replacement', 'unknown'):
        path = home('manual-pending-change-' + change)
        seed(path)
        task(path, 'unhold', 'dependent')
        (path / 'config/backlog-backend').write_text('manual\n')
        (path / 'keep-queued').touch()
        old_gen = generation(path)
        owned.append(protocol_launch(path))
        assert (path / 'hook-status').read_text().strip() == '0'
        if change == 'hold':
            task(path, 'hold', 'dependent', '--kind', 'captain', '--reason', 'new authority')
        elif change == 'dependency':
            task(path, 'add', 'extra', 'new prerequisite')
            task(path, 'block', 'dependent', '--by', 'extra')
        elif change == 'replacement':
            (path / 'state/dependent.meta').write_text('endpoint_task_id=dependent\nspawn_gen=s2.3.4\n')
            task(path, 'start', 'dependent')
        else:
            (path / 'graph-unavailable').touch()
        review(path, 'guard', 'main', ok=False)
        item = json.loads((path / 'state/.ready-review.json').read_text())['candidates']['dependent']
        assert 'launch' not in item and 'observed_start' not in item
        if change in ('hold', 'dependency'):
            assert item['generation'] != old_gen and 'confirmed_launch' not in item
        if change == 'replacement':
            assert 'confirmed_launch' not in item
            (path / 'state/dependent.meta').write_text('endpoint_task_id=dependent\nspawn_gen=s1.2.3\n')
            review(path, 'guard', 'main', ok=False)
        if change == 'unknown':
            assert item['confirmed_launch']['generation'] == old_gen
            (path / 'graph-unavailable').unlink()
            review(path, 'guard', 'main', ok=False)
        protocol_stop(owned.pop())


def manual_changed_graph_during_hook(owned):
    for scanned in (False, True):
        path = home('manual-hook-graph-change-' + str(scanned))
        seed(path)
        task(path, 'unhold', 'dependent')
        (path / 'config/backlog-backend').write_text('manual\n')
        (path / 'keep-queued').touch()
        if scanned:
            generation(path)
        (path / 'change-hook-graph').touch()
        owned.append(protocol_launch(path))
        assert (path / 'hook-status').read_text().strip() != '0'
        item = scan(path)['candidates']['dependent']
        assert item['facts']['held'] == 'yes'
        assert 'launch' not in item and 'observed_start' not in item and 'confirmed_launch' not in item
        review(path, 'guard', 'main', ok=False)
        protocol_stop(owned.pop())


def untracked_launch_graph_compatibility(owned):
    path = home('untracked-launch-graph-compatibility')
    seed(path)
    task(path, 'unhold', 'dependent')
    ledger = path / 'state/.ready-review.json'
    assert not ledger.exists(), 'compatibility fixture already tracked a candidate'
    (path / 'fail-hook-graph').touch()
    owned.append(protocol_launch(path))
    assert (path / 'hook-status').read_text().strip() == '0', 'untracked launch acquired a new post-publication failure'
    book = json.loads(ledger.read_text())
    assert book['uncertainty'] and book['candidates'] == {}
    seq = pending_guards(path)
    (path / 'graph-unavailable').unlink()
    review(path, 'guard', 'main')
    assert scan(path)['candidates'] == {}, 'compatibility path manufactured a candidate or processing proof'
    call(path, 'fm-branch-outcome.sh', 'mark-processed', '--through', seq)


root = fixture
errors = []
try:
    for scenario in (reopen_after_teardown, graph_failure_after_launch, prune_existing_worker,
                     denied_lifecycle_changes, denied_pending_launches, changed_metadata_during_processing,
                     changed_graph_during_launch_hook, fresh_confirmed_replacement, malformed_lifecycle_anchor,
                     manual_pending_owner_handoff, automatic_queued_still_refused,
                     manual_pending_changes_still_refused, manual_changed_graph_during_hook,
                     untracked_launch_graph_compatibility):
        owned = []
        try:
            scenario(owned)
            print('ok - process-backed ready-review ' + scenario.__name__)
        except Exception:
            errors.append(scenario.__name__ + '\n' + traceback.format_exc())
        finally:
            for process in reversed(owned):
                protocol_stop(process)
finally:
    root = saved_root
assert not errors, '\n'.join(errors)

PYTEST
}


test_dependency_completion_poll() {
  local dir pid i
  dir=$(make_case dependency-poll)
  mkdir -p "$dir/data" "$dir/config"
  cp "$ROOT/.tasks.toml" "$dir/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$dir/data/backlog.md"
  FM_HOME="$dir" "$ROOT/bin/fm-tasks-axi.sh" add dependency dependency >/dev/null || fail 'add dependency'
  FM_HOME="$dir" "$ROOT/bin/fm-tasks-axi.sh" hold dependency --kind external --reason 'prerequisite pending' >/dev/null || fail 'hold prerequisite'
  FM_HOME="$dir" "$ROOT/bin/fm-tasks-axi.sh" add dependent dependent >/dev/null || fail 'add dependent'
  FM_HOME="$dir" "$ROOT/bin/fm-tasks-axi.sh" block dependent --by dependency >/dev/null || fail 'block dependent'
  FM_HOME="$dir" "$ROOT/bin/fm-tasks-axi.sh" hold dependent --kind captain --reason 'explicit authority pending' >/dev/null || fail 'hold dependent'
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_POLL=0.2 FM_CHECK_INTERVAL=999999 \
    FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" > "$dir/watch.out" &
  pid=$!
  for ((i=0; i<100; i++)); do
    [ -s "$dir/state/.ready-review.json" ] && break
    sleep 0.1
  done
  [ -s "$dir/state/.ready-review.json" ] || fail 'watcher never observed initial held graph'
  FM_HOME="$dir" "$ROOT/bin/fm-tasks-axi.sh" 'done' dependency --no-prune >/dev/null || fail 'complete dependency'
  wait_for_exit "$pid" 60 || fail 'dependency completion waited for heartbeat backoff'
  [ "$(cat "$dir/watch.out")" = heartbeat ] || fail 'held dependency graph did not wake review'
  assert_contains "$(cat "$dir/state/.wake-queue")" 'ready-review:' 'review was not durably queued'
  assert_contains "$(FM_HOME="$dir" "$ROOT/bin/fm-tasks-axi.sh" show dependent)" 'held: yes' 'observer released explicit hold'
  [ ! -e "$dir/state/dependent.meta" ] || fail 'observer fabricated a launch'
  pass 'held-only dependency completion bypasses idle heartbeat backoff and preserves captain authority'
}

test_ready_review_contract || fail 'ready review contract failed'
test_dependency_completion_poll
test_ready_queue_addressing absolute
test_ready_queue_addressing relative
test_ready_queue_addressing trailing-slash
test_ready_queue_addressing relative-home
test_ready_queue_addressing trailing-slash-home
test_ready_heartbeat
test_ready_heartbeat unreadable
test_not_ready_heartbeat empty
test_not_ready_heartbeat held
test_emitted_stop_revalidation_contract
test_emitted_away_scope_gate
test_daemon_heartbeat ready
test_daemon_heartbeat ready signal
test_daemon_heartbeat empty
test_daemon_heartbeat held
test_daemon_heartbeat unreadable
test_daemon_heartbeat failed

test_growing_ready_review_history() {
  python3 - "$ROOT/bin/fm_ready_review.py" "$TMP_ROOT" <<'PY'
import importlib.util, json, pathlib, sys
spec=importlib.util.spec_from_file_location('review_growth',sys.argv[1]); module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
state=pathlib.Path(sys.argv[2])/'growing-review'; state.mkdir()
review=module.Review.__new__(module.Review); review.state=state; review.path=state/'.ready-review.json'; review.binding={'home':'owned'}; review.lock=None
book={'schema':1,'binding':review.binding,'candidates':{f't{i}':{'generation':'a'*64,'state':'done','history':'x'*9000} for i in range(1000)}}
module.write(review.path,book)
assert review.path.stat().st_size>module.MAX_BYTES
with review: assert len(review.book['candidates'])==1000; review.save()
try: module.write(review.path,{'candidates':{'oversized':{'history':'x'*(module.MAX_BYTES+1)}}})
except module.Refusal: pass
else: raise AssertionError('oversized ledger record accepted')
with review: assert len(review.book['candidates'])==1000
with (state/'branch-outcomes.jsonl').open('w') as stream:
    for seq in range(1,1001):
        row={'seq':seq,'verdict':'captain','summary':'x'*9000,'readyReview':{'binding':review.binding,'candidates':[{'task':'pending','generation':'b'*64}]}}
        stream.write(json.dumps(row)+'\n')
assert (state/'branch-outcomes.jsonl').stat().st_size>module.MAX_BYTES
assert ('pending','b'*64) in review.handoffs()
for raw in ('{"seq":1002}\n','not json\n','x'*(module.MAX_BYTES+1)):
    with (state/'branch-outcomes.jsonl').open('a') as stream: stream.write(raw)
    try: review.handoffs()
    except (module.Refusal,ValueError): pass
    else: raise AssertionError('malformed outcome accepted')
    (state/'branch-outcomes.jsonl').write_text('')
victim=state/'victim'; victim.write_text('untouched')
review.path.unlink(); review.path.symlink_to(victim)
try: module.write(review.path,book)
except (module.Refusal,OSError): pass
else: raise AssertionError('unsafe ledger destination accepted')
assert victim.read_text()=='untouched'
PY
}
test_growing_ready_review_history


test_ready_review_reuses_one_current_facts_snapshot() {
  python3 - "$ROOT/bin/fm_ready_review.py" "$TMP_ROOT" <<'PYFACTS'
import importlib.util, os, pathlib, sys, types
spec=importlib.util.spec_from_file_location('ready_facts',sys.argv[1]); module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
home=pathlib.Path(sys.argv[2])/'one-facts-snapshot'
(home/'state').mkdir(parents=True)
(home/'data').mkdir()
os.environ.update(FM_HOME=str(home),FM_STATE_OVERRIDE=str(home/'state'))
args=types.SimpleNamespace(data=str(home/'data'),backend='markdown',manual_lifecycle=False)
calls=[]
def observe(argv, **kwargs):
    calls.append(argv)
    return str(home)+'\n'+str(home/'state') if len(calls)%2 else str(len(calls))+'\nlive\n'
module.run=observe
review=module.Review(args)
review.rows=[]
facts=review.retry_facts()
for number in range(5):
    item={'generation':str(number),'stop':{'generation':str(number),'binding':review.binding,'gate':'external','until':review.now+100,'facts':facts,'reason':'capacity full','retry':'capacity opens'}}
    assert review.settled(str(number),item)
assert len(calls)==2, ('one operation repeated its topology/liveness observation',len(calls))
next_review=module.Review(args)
assert next_review.retry_facts()!=facts, 'new operation reused old observation'
assert len(calls)==4
print('ok - stopped candidates reuse one current observation per operation')
PYFACTS
}
test_ready_review_reuses_one_current_facts_snapshot
