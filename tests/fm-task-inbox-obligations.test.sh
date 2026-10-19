#!/usr/bin/env bash
# Accountable steering: acknowledgments do not prove execution.
# Literal shell snippets are evaluated by the child bash, not this test shell.
# shellcheck disable=SC2016
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-task-inbox-obligations)
export HOME="$TMP_ROOT/user" FM_HOME="$TMP_ROOT/home"
export FM_STATE_OVERRIDE="$FM_HOME/state" FM_TASK_INBOX_OBLIGATION_GRACE_SECS=0
export PYTHONDONTWRITEBYTECODE=1
mkdir -p "$HOME" "$FM_STATE_OVERRIDE"
mkdir -p "$TMP_ROOT/fakebin"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP_ROOT/fakebin/tmux"
chmod +x "$TMP_ROOT/fakebin/tmux"
export PATH="$TMP_ROOT/fakebin:$PATH"
STATE=$FM_STATE_OVERRIDE
HELPER="$ROOT/bin/fm-task-inbox.sh"
printf 'id=t1\nkind=secondmate\nspawn_gen=g1\nbackend=tmux\nwindow=test:fm-t1\n' > "$STATE/t1.meta"
write_record() {
  bash -c '. "$1"; fm_task_inbox_write "$2" t1 "$3" "" disposition' _ \
    "$ROOT/bin/fm-task-inbox-lib.sh" "$STATE" "$1"
}
rec=$(write_record 'Do the requested operation')
mv "$rec" "$STATE/t1.inbox/handled/"
rec="$STATE/t1.inbox/handled/${rec##*/}"
# Generic activity and an attributable-looking promise are not execution proof.
printf 'working [corr=promise]: acknowledged, I will start\n' > "$STATE/t1.status"
printf 'g1\n' > "$STATE/t1.progress"
"$HELPER" tick t1 > "$TMP_ROOT/tick1"
"$HELPER" tick t1 > "$TMP_ROOT/tick2"
"$HELPER" tick t1 > "$TMP_ROOT/tick3"
[ "$(grep -c 'instruction execution unaccounted' "$STATE/.wake-queue")" = 1 ] \
  || fail 'handled actionable record became quiet without execution proof'
"$HELPER" tick t1 > "$TMP_ROOT/tick4"
[ "$(grep -c 'instruction execution unaccounted' "$STATE/.wake-queue")" = 1 ] \
  || fail 'escalation repeated after restart'
[ "$(find "$STATE/t1.inbox" -name '*.msg' | wc -l | tr -d ' ')" = 1 ] \
  || fail 'recovery minted a duplicate instruction'
pass 'handled promise plus generic progress still reconciles once and escalates once'

expect_denied() {
  if "$@" > "$TMP_ROOT/denied.out" 2>&1; then fail "unsafe operation accepted: $*"; fi
}
rec2=$(write_record 'Start one concrete command')
mv "$rec2" "$STATE/t1.inbox/handled/"
rec2="$STATE/t1.inbox/handled/${rec2##*/}"
expect_denied "$HELPER" disposition t1 "$rec2" --gen g1 --disposition started --reason 'I will start'
expect_denied "$HELPER" disposition t1 "$rec2" --gen wrong --disposition waiting --reason dependency --condition new-key
expect_denied "$HELPER" disposition t1 "$rec2" --gen g1 --disposition waiting --reason '' --condition new-key
expect_denied "$HELPER" disposition t1 "$rec2" --gen g1 --disposition refused --reason forbidden --condition ''
expect_denied "$HELPER" disposition t1 "$STATE/t1.inbox/handled/../../t1.meta" --gen g1 --disposition waiting --reason dependency --condition key
ln -s "$rec2" "$STATE/t1.inbox/handled/999.msg"
expect_denied "$HELPER" disposition t1 "$STATE/t1.inbox/handled/999.msg" --gen g1 --disposition waiting --reason dependency --condition key
rm "$STATE/t1.inbox/handled/999.msg"
mkdir -p "$TMP_ROOT/foreign/state"
expect_denied env FM_HOME="$TMP_ROOT/foreign" "$HELPER" disposition t1 "$rec2" --gen g1 --disposition waiting --reason dependency --condition key
"$HELPER" run t1 "$rec2" --gen g1 --timeout 5 -- python3 -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); p.write_text(p.read_text()+"run\n" if p.exists() else "run\n")' "$TMP_ROOT/executions" > "$TMP_ROOT/run.out"
"$HELPER" run t1 "$rec2" --gen g1 --timeout 5 -- python3 -c 'import pathlib,sys; p=pathlib.Path(sys.argv[1]); p.write_text(p.read_text()+"run\n" if p.exists() else "run\n")' "$TMP_ROOT/executions" > "$TMP_ROOT/run-retry.out"
[ "$(wc -l < "$TMP_ROOT/executions" | tr -d ' ')" = 1 ] || fail 'execution replayed on duplicate receipt request'
"$HELPER" query t1 > "$TMP_ROOT/query.json"
python3 - "$TMP_ROOT/query.json" <<'PY'
import json,sys
items=json.load(open(sys.argv[1]))
assert len(items)==2
assert items[0]['receipt'] is None
proof=items[1]['receipt']
assert proof['proof']=='helper-exec' and proof['returncode']==0 and proof['pid'] > 0
PY
expect_denied "$HELPER" disposition t1 "$rec2" --gen g1 --disposition refused --reason forbidden --condition key
pass 'only real exec records started; wrong owner, generation, path, empty waits and conflicts refuse'

rec3=$(write_record 'Needs permission before proceeding')
mv "$rec3" "$STATE/t1.inbox/handled/"
rec3="$STATE/t1.inbox/handled/${rec3##*/}"
"$HELPER" disposition t1 "$rec3" --gen g1 --disposition waiting --reason 'permission required' --condition 'approve-exact-operation' > /dev/null
"$HELPER" disposition t1 "$rec3" --gen g1 --disposition waiting --reason 'permission required' --condition 'approve-exact-operation' > /dev/null
"$HELPER" tick t1 > /dev/null
"$HELPER" tick t1 > /dev/null
"$HELPER" tick t1 > /dev/null
[ "$(grep -c 'instruction execution unaccounted' "$STATE/.wake-queue")" = 1 ] || fail 'valid wait caused execution-recovery loop'
expect_denied "$HELPER" guard t1
pass 'valid exact-record wait is idempotent; another record remains outstanding and blocks cleanup'

# Historical records and explicit passive notices never acquire obligations.
printf 'id=quiet\nspawn_gen=q1\n' > "$STATE/quiet.meta"
bash -c '. "$1"; fm_task_inbox_write "$2" quiet "passive notice" "" none' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$STATE" > /dev/null
mkdir -p "$STATE/quiet.inbox/handled"
printf 'schema=fm-task-inbox.v1\n--\nhistorical' > "$STATE/quiet.inbox/handled/123.msg"
[ "$("$HELPER" tick quiet)" = '[]' ] || fail 'passive/legacy records woke an idle mate'
"$HELPER" guard quiet
pass 'passive and historical handled records stay quiet'

# Legacy *new* deliveries remain deliverable, but cannot assert a wildcard generation.
printf 'id=legacy\nkind=secondmate\nbackend=tmux\nwindow=test:fm-legacy\n' > "$STATE/legacy.meta"
legacy=$(bash -c '. "$1"; fm_task_inbox_write "$2" legacy "new actionable instruction" "" disposition' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$STATE")
[ -f "$legacy" ] || fail 'legacy receiver lost new delivery'
expect_denied "$HELPER" disposition legacy "$legacy" --gen legacy --disposition waiting --reason blocked --condition key
"$HELPER" tick legacy > /dev/null
"$HELPER" tick legacy > /dev/null
[ "$(grep -c 'unverified or superseded incarnation' "$STATE/.wake-queue")" = 1 ] || fail 'legacy unverified incarnation became silent'
# A replacement may not discharge its predecessor's record.
printf 'id=legacy\nspawn_gen=replacement\n' > "$STATE/legacy.meta"
expect_denied "$HELPER" disposition legacy "$legacy" --gen replacement --disposition waiting --reason blocked --condition key
pass 'legacy new steers retain visible unverified obligations; replacements cannot inherit receipts'

# Command execution must release the task metadata lock after durable start.
long=$(write_record 'Run a bounded command with private arguments')
secret=sentinel-instruction-secret
cat > "$TMP_ROOT/$secret" <<'PY'
#!/usr/bin/env python3
import pathlib,sys,time
until=time.monotonic()+15
while not pathlib.Path(sys.argv[1]).exists() and time.monotonic()<until:
    time.sleep(.05)
PY
chmod +x "$TMP_ROOT/$secret"
INSTRUCTION_TEST_SECRET="$secret" "$HELPER" run t1 "$long" --gen g1 --timeout 20 -- "$TMP_ROOT/$secret" "$TMP_ROOT/release" "$secret" > "$TMP_ROOT/long.out" 2> "$TMP_ROOT/long.err" &
owner=$!
for _ in $(seq 1 100); do
  [ ! -s "$TMP_ROOT/long.out" ] || break
  sleep .05
done
[ -s "$TMP_ROOT/long.out" ] || { kill "$owner"; wait "$owner" || true; fail 'bounded execution never published its start'; }
expect_denied "$HELPER" run t1 "$long" --gen g1 --timeout 20 -- "$TMP_ROOT/$secret" "$TMP_ROOT/release" "$secret"
PATH="$TMP_ROOT/fakebin:$PATH" FM_ROOT_OVERRIDE="$FM_HOME" "$ROOT/bin/fm-send.sh" t1 'New steer while prior command runs' > "$TMP_ROOT/parallel-send.out" 2> "$TMP_ROOT/parallel-send.err" \
  || { touch "$TMP_ROOT/release"; wait "$owner" || true; fail "running command held metadata lock: $(cat "$TMP_ROOT/parallel-send.err")"; }
touch "$TMP_ROOT/release"
wait "$owner" || fail "wrapped execution failed: $(cat "$TMP_ROOT/long.err")"
"$HELPER" query t1 > "$TMP_ROOT/after-run.json"
if grep -R "$secret" "$STATE/t1.inbox/obligations" "$TMP_ROOT/after-run.json" "$TMP_ROOT/long.out" "$TMP_ROOT/long.err"; then
  fail 'execution receipts leaked argv, executable name, or environment'
fi
pid=$(python3 - "$TMP_ROOT/long.out" <<'PY'
import json,sys
print(json.load(open(sys.argv[1]))['receipt']['pid'])
PY
)
if kill -0 "$pid" 2>/dev/null; then fail 'owned command still exists after return'; fi
pass 'new steering succeeds during wrapped execution; receipts omit command secrets and owned process exits'

# A missing runtime fails before a partial accountable publication.
missing_path=$(fm_test_base_path_sans "$PATH" python3)
printf 'id=no-python\nspawn_gen=np1\n' > "$STATE/no-python.meta"
expect_denied env PATH="$missing_path" bash -c '. "$1"; fm_task_inbox_write "$2" no-python action "" disposition' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$STATE"
[ ! -e "$STATE/no-python.inbox" ] || fail 'missing Python left a partial delivery'
pass 'missing Python refuses before accountable delivery'

# Timeouts stop the owned command group, and late returns cannot mutate a replacement.
timeout_record=$(write_record 'Run a bounded command')
expect_denied "$HELPER" run t1 "$timeout_record" --gen g1 --timeout 1 -- bash -c 'sleep 30 & child=$!; printf "%s\n" "$child" > "$1"; wait' _ "$TMP_ROOT/descendant.pid"
[ -s "$TMP_ROOT/descendant.pid" ] || fail 'timeout fixture never started its descendant'
descendant=$(cat "$TMP_ROOT/descendant.pid")
state=$(ps -o stat= -p "$descendant" 2>/dev/null || true)
case "$state" in ''|Z*) ;; *) fail "owned descendant survived timeout: $descendant $state" ;; esac
"$HELPER" query t1 > "$TMP_ROOT/timeout-query.json"
python3 - "$TMP_ROOT/timeout-query.json" "${timeout_record##*/}" <<'PY'
import json,sys
item=next(x for x in json.load(open(sys.argv[1])) if x['record']==sys.argv[2])
assert item['receipt']['returncode']==124
PY
timeout_status=0
"$HELPER" run t1 "$timeout_record" --gen g1 --timeout 1 -- bash -c 'sleep 30 & child=$!; printf "%s\n" "$child" > "$1"; wait' _ "$TMP_ROOT/descendant.pid" > /dev/null || timeout_status=$?
[ "$timeout_status" = 124 ] || fail 'identical completed timeout reported success or a different status'
[ "$(cat "$TMP_ROOT/descendant.pid")" = "$descendant" ] || fail 'timeout repeat launched a second descendant'
late=$(write_record 'Long command across a generation change')
"$HELPER" run t1 "$late" --gen g1 --timeout 10 -- python3 -c 'import pathlib,sys,time; p=pathlib.Path(sys.argv[1]); end=time.monotonic()+8
while not p.exists() and time.monotonic()<end: time.sleep(.05)' "$TMP_ROOT/late-release" > "$TMP_ROOT/late.out" 2> "$TMP_ROOT/late.err" &
late_owner=$!
for _ in $(seq 1 100); do [ ! -s "$TMP_ROOT/late.out" ] || break; sleep .05; done
[ -s "$TMP_ROOT/late.out" ] || { kill "$late_owner"; wait "$late_owner" || true; fail 'late-return fixture never started'; }
sed 's/spawn_gen=g1/spawn_gen=g2/' "$STATE/t1.meta" > "$STATE/t1.meta.new"
mv "$STATE/t1.meta.new" "$STATE/t1.meta"
touch "$TMP_ROOT/late-release"
if wait "$late_owner"; then fail 'old execution return was accepted into replacement generation'; fi
expect_denied "$HELPER" disposition t1 "$rec3" --gen g2 --disposition waiting --reason 'permission required' --condition 'approve-exact-operation'
expect_denied "$HELPER" guard t1
"$HELPER" query t1 > "$TMP_ROOT/late-query.json"
python3 - "$TMP_ROOT/late-query.json" "${late##*/}" "${rec3##*/}" <<'PY'
import json,sys
items=json.load(open(sys.argv[1]))
assert 'returncode' not in next(x for x in items if x['record']==sys.argv[2])['receipt']
assert next(x for x in items if x['record']==sys.argv[3])['outstanding']
PY
pass 'timeout stops owned descendants; replacement generation rejects old returns and invalidates reported waits'

# An authentic receipt copied from another record is still foreign evidence.
foreign=$(write_record 'Independent record must retain independent ownership')
cp "$STATE/t1.inbox/obligations/${rec2##*/}.json" "$STATE/t1.inbox/obligations/${foreign##*/}.json"
expect_denied "$HELPER" query t1
rm "$STATE/t1.inbox/obligations/${foreign##*/}.json"
pass 'foreign receipt cannot discharge a distinct record'

# Delivery's fire-and-forget exemption does not make an instruction passive.
printf 'id=fire\nspawn_gen=f1\n' > "$STATE/fire.meta"
fire=$(bash -c '. "$1"; fm_task_inbox_write "$2" fire "Perform the operation without a report" fire-and-forget disposition' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$STATE")
printf '%s\n' "${fire##*/}" > "$STATE/fire.inbox/.retry-ring"
"$HELPER" tick fire > /dev/null
"$HELPER" tick fire > /dev/null
[ ! -e "$STATE/fire.inbox/.retry-ring" ] || fail 'accountable reconciliation left a duplicate delivery retry'
"$HELPER" tick fire > /dev/null
"$HELPER" tick fire > /dev/null
[ "$(grep -c 'instruction execution unaccounted: fire ' "$STATE/.wake-queue")" = 1 ] || fail 'unread actionable fire-and-forget instruction escaped accountability'
[ -f "$fire" ] || fail 'accountability moved or replayed the original unread instruction'
pass 'actionable fire-and-forget delivery stays accountable while unread, with one recovery budget'

# Failure after durable exec proof must still stop the command group.
handoff=$(write_record 'Observe a failed execution-owner handoff')
python3 - "$ROOT/bin/fm-task-inbox-obligation.py" "$STATE" "$handoff" <<'PY'
import importlib.util, os, pathlib, sys, types
spec=importlib.util.spec_from_file_location('obligation', sys.argv[1])
module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
inbox=module.Inbox(sys.argv[2], 't1')
ready=pathlib.Path(sys.argv[2])/'injected-ready'
os.environ['FM_INSTRUCTION_READY_FILE']=str(ready)
original_safe=module.safe_path
def injected_safe(path, root=None):
    if pathlib.Path(path)==ready: raise OSError('injected handoff failure')
    return original_safe(path, root)
module.safe_path=injected_safe
children=[]
original_popen=module.subprocess.Popen
def tracked_popen(*args, **kwargs):
    child=original_popen(*args, **kwargs); children.append(child); return child
module.subprocess.Popen=tracked_popen
args=types.SimpleNamespace(record=sys.argv[3], gen='g2', command='run', argv=['sleep','30'])
try:
    try: inbox.disposition(args)
    except OSError: pass
    else: raise AssertionError('handoff fault did not occur')
    assert len(children)==1
    if pathlib.Path("/proc/self/stat").exists():
        assert children[0].instruction_start_identity
    assert children[0].poll() is not None, 'execution survived failed start handoff'
finally:
    for child in children: module.stop_child(child)
PY
pass 'failed start handoff stops its exact observed command process'

refused=$(write_record 'Operation prohibited until its decision changes')
"$HELPER" disposition t1 "$refused" --gen g2 --disposition refused --reason 'outside approved scope' --condition 'captain approves this operation' > /dev/null
"$HELPER" query t1 | python3 -c 'import json,sys; x=next(x for x in json.load(sys.stdin) if x["record"]==sys.argv[1]); assert not x["outstanding"] and x["receipt"]["condition"]=="captain approves this operation"' "${refused##*/}"
pass 'concrete exact-record refusal remains visible and settles its current obligation'

# The remote observation contract must carry explicit unresolved state.
python3 - "$ROOT/bin/fm-task-inbox-obligation.py" "$STATE" <<'PY'
import contextlib, importlib.util, io, json, sys, types
spec=importlib.util.spec_from_file_location('obligation', sys.argv[1])
module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
inbox=module.Inbox(sys.argv[2], 'remote-schema')
inbox.remote_track()
item=dict(schema=1, task='remote-schema', record='001.msg', obligation='a'*32, receipt={'disposition':'waiting'}, outstanding=True)
snapshot=dict(schema='fm-instruction-observations.v1', task='remote-schema', alerts=[], obligations=[item])
module.subprocess.run=lambda *a,**k: types.SimpleNamespace(returncode=0, stdout=json.dumps(snapshot).encode())
monitor=inbox.state/'.obligation-remote-remote-schema.json'
with contextlib.redirect_stdout(io.StringIO()): inbox.remote_tick()
assert module.read_json(monitor)['outstanding']==['a'*32], 'stale wait receipt masked unresolved state'
del item['outstanding']
with contextlib.redirect_stdout(io.StringIO()): inbox.remote_tick()
assert 'unknown_since' in module.read_json(monitor), 'missing unresolved predicate was accepted as settled'
PY
pass 'remote stale waits retain explicit outstanding state; malformed observations become unknown'

# A rejected durable wake must not consume escalation's dedup marker.
queued=$(write_record 'Keep failed escalation pending for durable delivery')
mv "$queued" "$STATE/t1.inbox/handled/"
queued="$STATE/t1.inbox/handled/${queued##*/}"
python3 - "$ROOT/bin/fm-task-inbox-obligation.py" "$STATE" "$queued" <<'PY'
import contextlib, importlib.util, io, subprocess, sys
spec=importlib.util.spec_from_file_location('obligation', sys.argv[1])
module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
inbox=module.Inbox(sys.argv[2], 't1')
claim=inbox.record(sys.argv[3]); path,data=inbox.ledger(claim)
data.update(observed=0, recovery=0); inbox.save(path,data)
original_run=module.subprocess.run
def reject_wake(argv, **kwargs):
    if argv[1]=='_wake': raise subprocess.CalledProcessError(1, ['injected-queue-failure'])
    return original_run(argv, **kwargs)
module.subprocess.run=reject_wake
try: inbox.tick()
except subprocess.CalledProcessError: pass
else: raise AssertionError('wake rejection did not surface')
assert 'escalated' not in inbox.ledger(claim)[1]
module.subprocess.run=original_run
with contextlib.redirect_stdout(io.StringIO()): inbox.tick(); inbox.tick()
assert inbox.ledger(claim)[1]['escalated']
queue=(inbox.state/'.wake-queue').read_text()
assert queue.count('obligation='+claim['obligation'])==1
PY
pass 'failed wake publication retains escalation; durable retry queues exactly once'

# Remote alert publication must preserve observable state across storage faults.
python3 - "$ROOT/bin/fm-task-inbox-obligation.py" "$STATE" <<'PY'
import contextlib, importlib.util, io, json, subprocess, sys, types
spec=importlib.util.spec_from_file_location('obligation', sys.argv[1])
module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
original_atomic=module.atomic_json
clock=[2000]
module.time.time=lambda: clock[0]
sequence=[0]
def scenario(alerts, prior=(), fault=None, target=None, outstanding=True):
    sequence[0]+=1
    task='remote-publication-'+str(sequence[0])
    inbox=module.Inbox(sys.argv[2],task)
    path=inbox.state/('.obligation-remote-'+task+'.json')
    module.atomic_json=original_atomic
    inbox.remote_track()
    initial=module.read_json(path)
    initial.update(alerts=list(prior)+['unknown'],unknown_since=1)
    original_atomic(path,initial)
    queue=[]
    snapshot=dict(schema='fm-instruction-observations.v1',task=task,
        alerts=[dict(obligation=key,message=key) for key in alerts],
        obligations=[dict(schema=1,task=task,record='001.msg',obligation='c'*32,outstanding=outstanding)])
    active=[fault]
    def transport(argv, **kwargs):
        if argv[1]=='_remote':
            return types.SimpleNamespace(returncode=0,stdout=json.dumps(snapshot).encode())
        assert argv[1]=='_wake'
        if active[0]=='queue' and argv[-1]==target:
            active[0]=None
            raise subprocess.CalledProcessError(1,['injected-queue-failure'])
        queue.append(argv[-1])
        return types.SimpleNamespace(returncode=0)
    def publish(destination,data):
        previous=module.read_json(destination)
        newly=set(data['alerts'])-set(previous['alerts'])
        if active[0]=='before' and target in newly:
            active[0]=None
            raise OSError('injected before durable alert publication')
        if active[0]=='redundant' and target in previous['alerts'] and previous==data:
            raise OSError('storage unavailable after all required state was published')
        original_atomic(destination,data)
        if active[0]=='after' and target in newly:
            active[0]=None
            raise OSError('injected after durable alert publication')
    module.subprocess.run=transport
    module.atomic_json=publish
    def tick():
        clock[0]+=1
        output=io.StringIO()
        with contextlib.redirect_stdout(output): inbox.remote_tick()
        return json.loads(output.getvalue())
    if fault in ('queue','before','after'):
        try: tick()
        except (OSError,subprocess.CalledProcessError): pass
        else: raise AssertionError('publication fault was not exercised')
        durable=module.read_json(path)
        assert (target in durable['alerts']) == (fault=='after')
        # A failed first publication retains unknown; completed publications
        # preserve positive snapshot facts even if a later alert fails.
        if any(key in durable['alerts'] for key in alerts if key not in prior):
            assert durable['outstanding']==(['c'*32] if outstanding else [])
            assert 'unknown_since' not in durable
        pending=[key for key in alerts if key not in durable['alerts']]
        assert [item['obligation'] for item in tick()]==pending
        assert queue.count(target)==(2 if fault=='before' else 1)
    else:
        assert [item['obligation'] for item in tick()]==[key for key in alerts if key not in prior]
    durable=module.read_json(path)
    assert durable['outstanding']==(['c'*32] if outstanding else [])
    assert 'unknown_since' not in durable and 'unknown' not in durable['alerts']
    assert set(durable['alerts'])==set(prior)|set(alerts)
    module.atomic_json=original_atomic
    before=list(queue)
    assert tick()==[] and queue==before, 'durable alert was queued again after restart'
    assert module.read_json(path)['outstanding']==durable['outstanding']
    return queue

a,b='a'*32,'b'*32
assert scenario([],outstanding=False)==[]
assert scenario([a])==[a]
assert scenario([a,b])==[a,b]
assert scenario([a,b],prior=[a,b],outstanding=False)==[]
assert scenario([a,b],prior=[a])==[b]
for fault in ('queue','before','after'):
    for target in (a,b): scenario([a,b],fault=fault,target=target)
# Once the final required alert snapshot is durable, later storage failure
# must not turn successful observation into a false error or repeat delivery.
assert scenario([a],fault='redundant',target=a)==[a]
assert scenario([a,b],fault='redundant',target=b)==[a,b]
PY
pass 'remote alert results, dedup and outstanding facts survive queue and publication faults'

# Faults surround actual durable writes and harmless command effects.
python3 - "$ROOT/bin/fm-task-inbox-obligation.py" <<'PY'
import contextlib, hashlib, importlib.util, io, json, os, pathlib, subprocess, sys, tempfile, time, types, unittest

spec=importlib.util.spec_from_file_location('review_inbox', sys.argv.pop(1))
module=importlib.util.module_from_spec(spec); spec.loader.exec_module(module)

class ExecutionReservation(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home=pathlib.Path(self.temp.name)/'home'
        self.state=self.home/'state'
        self.directory=self.state/'worker.inbox'
        self.directory.mkdir(parents=True)
        old=dict(os.environ)
        self.addCleanup(lambda: (os.environ.clear(), os.environ.update(old)))
        os.environ.update(FM_HOME=str(self.home),FM_STATE_OVERRIDE=str(self.state),FM_INSTRUCTION_READY_FILE=str(self.state/'ready'))
        (self.state/'worker.meta').write_text('spawn_gen=g1\n')
        self.record=self.directory/'1.msg'
        self.claim=dict(schema=1,home=str(self.home),state=str(self.state),task='worker',record='1.msg',generation='g1',obligation='a'*32,accepted=int(time.time()),body_sha256=hashlib.sha256(b'action').hexdigest(),expectation='disposition')
        self.record.write_bytes(b'obligation='+json.dumps(self.claim).encode()+b'\n--\naction')
        self.inbox=module.Inbox(self.state,'worker')
        self.effects=self.home/'effects'
        self.args=types.SimpleNamespace(command='run',record=str(self.record),gen='g1',argv=[sys.executable,'-I','-c','from pathlib import Path; import sys; p=Path(sys.argv[1]); p.open("a").write("effect\\n")',str(self.effects)])
        self.children=[]
        original=module.subprocess.Popen
        self.real_popen=original
        def observed(*args,**kwargs):
            child=original(*args,**kwargs); self.children.append(child)
            child.wait(timeout=5)
            return child
        module.subprocess.Popen=observed
        self.addCleanup(setattr,module.subprocess,'Popen',original)
        self.addCleanup(self.cleanup_children)

    def cleanup_children(self):
        for child in self.children:
            if child.poll() is None: module.stop_child(child)
        self.assertTrue(all(child.poll() is not None for child in self.children))

    def invoke(self):
        with contextlib.redirect_stdout(io.StringIO()): return self.inbox.disposition(self.args)

    def test_before_reservation_failure_has_no_effect(self):
        def failed(*_): raise OSError('injected reservation write failure')
        self.inbox.save=failed
        with self.assertRaises(OSError): self.invoke()
        self.assertFalse(self.effects.exists())
        self.assertEqual(self.children,[])

    def test_started_publication_failure_never_replays(self):
        save=self.inbox.save
        def failed(path,data):
            if data.get('receipt'): raise OSError('injected started publication failure')
            save(path,data)
        self.inbox.save=failed
        with self.assertRaises(OSError): self.invoke()
        self.inbox.save=save
        with self.assertRaises(ValueError): self.invoke()
        self.assertEqual(self.effects.read_text().splitlines(),['effect'])
        self.assertEqual(len(self.children),1)
        item=self.inbox.query()[0]
        self.assertTrue(item['outstanding'])
        self.assertIsNotNone(item['attempt'])
        self.assertIsNone(item['receipt'])

    def test_repeat_failure_returns_recorded_status(self):
        self.args.argv=[sys.executable,'-I','-c','raise SystemExit(7)']
        child,path,data=self.invoke()
        data['receipt'].update(returncode=7,returned_at=int(time.time()))
        self.inbox.save(path,data)
        with self.assertRaises(SystemExit) as result: self.invoke()
        self.assertEqual(result.exception.code,7)
        self.assertEqual(len(self.children),1)

    def test_repeat_pending_refuses(self):
        self.invoke()
        with self.assertRaises(ValueError): self.invoke()
        self.assertEqual(len(self.children),1)
        self.assertFalse(self.inbox.query()[0]['outstanding'])

    def test_explicit_external_state(self):
        external=pathlib.Path(self.temp.name)/'external-state'
        external.mkdir()
        os.environ['FM_STATE_OVERRIDE']=str(external)
        self.assertEqual(module.Inbox(external,'worker').state,external)

    def test_explicit_alternate_home_state(self):
        alternate=self.home/'other-state'; alternate.mkdir()
        os.environ['FM_STATE_OVERRIDE']=str(alternate)
        self.assertEqual(module.Inbox(alternate,'worker').state,alternate)

    def test_completed_statuses_and_malformed_returns(self):
        _,path,data=self.invoke()
        for status in (0,7,124,-15):
            data['receipt']['returncode']=status; self.inbox.save(path,data)
            with self.assertRaises(SystemExit) as result: self.invoke()
            self.assertEqual(result.exception.code,status if status>=0 else 1)
        for status in (True,'0',None,256,-256):
            data['receipt']['returncode']=status; self.inbox.save(path,data)
            with self.assertRaises(ValueError): self.invoke()
        self.assertEqual(len(self.children),1)

    def test_uncertain_attempt_denies_other_dispositions_and_bindings(self):
        original=module.subprocess.Popen
        def denied(*_,**__): raise OSError('injected no executable')
        module.subprocess.Popen=denied
        try:
            with self.assertRaises(ValueError): self.invoke()
        finally: module.subprocess.Popen=original
        self.assertTrue(self.inbox.query()[0]['outstanding'])
        with self.assertRaises(ValueError): self.invoke()
        self.args.argv=[sys.executable,'-c','raise SystemExit(0)']
        with self.assertRaises(ValueError): self.invoke()
        self.args.gen='wrong'
        with self.assertRaises(ValueError): self.invoke()
        self.args.gen='g1'; self.args.command='disposition'; self.args.disposition='refused'
        self.args.reason='permission'; self.args.condition='key'
        with self.assertRaises(ValueError): self.invoke()
        self.assertFalse(self.effects.exists())
        self.assertEqual(self.children,[])

    def test_receipt_must_match_attempt_command_and_execution(self):
        _,path,data=self.invoke()
        for field in ('command_sha256','execution_id'):
            prior=data['attempt'][field]
            data['attempt'][field]='b'*len(prior); self.inbox.save(path,data)
            with self.assertRaises(ValueError): self.inbox.query()
            data['attempt'][field]=prior

    def test_directory_durability_failure_prevents_execution(self):
        sync=module.sync_directory
        for failing_directory in (self.directory,self.directory/'obligations'):
            def failed(path):
                if path==failing_directory: raise OSError('injected directory fsync failure')
                sync(path)
            module.sync_directory=failed
            try:
                with self.assertRaises(OSError): self.invoke()
            finally: module.sync_directory=sync
            self.assertFalse(self.effects.exists())
            self.assertEqual(self.children,[])
        # Replacement succeeded before its directory fsync failed: conservative
        # readback refuses the retained reservation rather than guessing durability.
        with self.assertRaises(ValueError): self.invoke()
        self.assertTrue(self.inbox.query()[0]['outstanding'])

    def test_abrupt_owner_exit_after_reservation(self):
        program='''import importlib.util,os,sys,types
spec=importlib.util.spec_from_file_location('owner',sys.argv[1]); m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
inbox=m.Inbox(sys.argv[2],'worker'); save=inbox.save
def exit_after_save(path,data):
    save(path,data)
    os._exit(17)
inbox.save=exit_after_save
inbox.disposition(types.SimpleNamespace(command='run',record=sys.argv[3],gen='g1',argv=[sys.executable,'-I','-c','raise SystemExit(0)']))
'''
        child=self.real_popen([sys.executable,'-I','-B','-c',program,str(module.__file__),str(self.state),str(self.record)],start_new_session=True)
        self.children.append(child)
        self.assertEqual(child.wait(timeout=5),17)
        with self.assertRaises(ValueError): self.invoke()
        self.assertTrue(self.inbox.query()[0]['outstanding'])
        self.assertFalse(self.effects.exists())

    def test_state_and_home_boundaries(self):
        foreign=pathlib.Path(self.temp.name)/'foreign'; foreign.mkdir()
        with self.assertRaises(ValueError): module.Inbox(foreign,'worker')
        link=self.home/'linked-state'; link.symlink_to(self.state,target_is_directory=True)
        os.environ['FM_STATE_OVERRIDE']=str(link)
        with self.assertRaises(ValueError): module.Inbox(link,'worker')
        os.environ['FM_STATE_OVERRIDE']=str(self.state)
        os.environ['FM_HOME']=str(foreign)
        other=module.Inbox(self.state,'worker')
        with self.assertRaises(ValueError): other.record(self.record)
        os.environ['FM_HOME']=str(self.home)
        self.record.write_bytes(self.record.read_bytes()+b'tampered')
        with self.assertRaises(ValueError): self.invoke()

    def test_override_selects_one_exact_channel(self):
        selected=self.home/'selected'; selected.mkdir()
        os.environ['FM_STATE_OVERRIDE']=str(selected)
        self.assertEqual(module.Inbox(selected,'worker').state,selected)
        for wrong in (self.state,self.state/'parent-route',self.home/'other'):
            with self.assertRaises(ValueError): module.Inbox(wrong,'worker')
        os.environ.pop('FM_STATE_OVERRIDE')
        for default in (self.state,self.state/'parent-route'):
            self.assertEqual(module.Inbox(default,'worker').state,default)
        with self.assertRaises(ValueError): module.Inbox(selected,'worker')

unittest.main()
PY
pass 'execution reservations survive publication faults and owner loss without replay; repeats and channel bindings remain honest'

failed_run=$(write_record 'A command can return failure after executing')
for _ in 1 2; do
  run_status=0
  "$HELPER" run t1 "$failed_run" --gen g2 --timeout 5 -- python3 -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).open("a").write("effect\n"); raise SystemExit(7)' "$TMP_ROOT/failed-effects" > /dev/null || run_status=$?
  [ "$run_status" = 7 ] || fail 'failed execution repeat did not preserve the actual exit status'
done
[ "$(wc -l < "$TMP_ROOT/failed-effects" | tr -d ' ')" = 1 ] || fail 'failed execution repeat ran the command again'
pass 'public run preserves failure and timeout statuses and refuses pending repeats without reexecution'

for override_state in "$FM_HOME/alternate-state" "$TMP_ROOT/external-state"; do
  (
    export FM_STATE_OVERRIDE=$override_state
    mkdir -p "$FM_STATE_OVERRIDE"
    printf 'id=override\nspawn_gen=o1\n' > "$FM_STATE_OVERRIDE/override.meta"
    override_record=$(bash -c '. "$1"; fm_task_inbox_write "$2" override action "" disposition' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$FM_STATE_OVERRIDE")
    printf 'answer\n' > "$TMP_ROOT/outside-response"
    expect_denied "$HELPER" disposition override "$override_record" --gen o1 --disposition fulfilled --response "$TMP_ROOT/outside-response"
    printf 'answer\n' > "$FM_HOME/inside-response"
    "$HELPER" disposition override "$override_record" --gen o1 --disposition fulfilled --response "$FM_HOME/inside-response" > /dev/null
    "$HELPER" guard override
    expect_denied env FM_HOME="$TMP_ROOT/user" "$HELPER" query override
    expect_denied python3 "$ROOT/bin/fm-task-inbox-obligation.py" query "$TMP_ROOT/unconfigured-state" override
  )
done
pass 'explicit alternate and external state channels work while home response and internal state boundaries hold'

# Source the production watcher through its supported function-loading entry.
# Real metadata-lock ownership must defer observation without spending recovery.
(
  # shellcheck source=/dev/null
  . "$ROOT/bin/fm-watch.sh"
  printf 'id=contended\nspawn_gen=c1\n' > "$STATE/contended.meta"
  held_record=$(bash -c '. "$1"; fm_task_inbox_write "$2" contended action "" disposition' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$STATE")
  mv "$held_record" "$STATE/contended.inbox/handled/"
  lock=$(fm_meta_lock_path "$STATE/contended.meta")
  bash -c '. "$1"; fm_lock_try_acquire "$2" || exit 1
trap '\''fm_lock_release "$2"'\'' EXIT
touch "$3"
for ((i=0;i<200;i++)); do [ ! -f "$4" ] || exit 0; sleep .1; done
exit 1' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$lock" "$TMP_ROOT/lock-held" "$TMP_ROOT/lock-release" &
  holder=$!
  trap 'kill "$holder" 2>/dev/null || true; wait "$holder" 2>/dev/null || true' EXIT
  for _ in $(seq 1 100); do [ ! -f "$TMP_ROOT/lock-held" ] || break; sleep .05; done
  [ -f "$TMP_ROOT/lock-held" ] || fail 'metadata lock fixture did not acquire ownership'
  export FM_TASK_INBOX_LOCK_WAIT_SECS=1
  status=0
  "$HELPER" tick contended > "$TMP_ROOT/contended.out" 2> "$TMP_ROOT/contended.err" || status=$?
  [ "$status" = 75 ] || fail "live metadata lock did not return contention: $status"
  INSTRUCTION_WAKE_REASON=
  inbox_obligation_check_one contended tick 2> "$TMP_ROOT/watcher-contention.err"
  [ -z "$INSTRUCTION_WAKE_REASON" ] && [ ! -e "$STATE/.instruction-error-contended" ] \
    || fail 'ordinary metadata contention became a recovery failure'
  [ ! -e "$STATE/contended.inbox/obligations" ] || fail 'contended observation spent recovery budget'
  if grep -q 'contended' "$STATE/.wake-queue"; then fail 'metadata contention queued a false stale wake'; fi

  # Invalid metadata must remain an error even while a real holder is live.
  printf 'spawn_gen=duplicate\n' >> "$STATE/contended.meta"
  status=0
  "$HELPER" tick contended > /dev/null 2> "$TMP_ROOT/invalid-meta.err" || status=$?
  [ "$status" != 0 ] && [ "$status" != 75 ] || fail 'invalid metadata was mistaken for contention'
  printf 'id=contended\nspawn_gen=c1\n' > "$STATE/contended.meta"
  # A second observer actively waits for the live holder, then succeeds once
  # that holder releases within the original acquisition window.
  FM_TASK_INBOX_LOCK_WAIT_SECS=5 "$HELPER" tick contended > "$TMP_ROOT/released-waiter.out" 2> "$TMP_ROOT/released-waiter.err" &
  observer=$!
  trap 'kill "$observer" "$holder" 2>/dev/null || true; wait "$observer" 2>/dev/null || true; wait "$holder" 2>/dev/null || true' EXIT
  sleep .2
  kill -0 "$observer" 2>/dev/null || fail 'metadata observer did not wait for the holder'
  touch "$TMP_ROOT/lock-release"
  wait "$holder" || fail 'metadata lock holder failed to release'
  wait "$observer" || fail "released metadata observer failed: $(cat "$TMP_ROOT/released-waiter.err")"
  trap - EXIT
  [ ! -e "$lock" ] && [ ! -L "$lock" ] || fail 'owned metadata lock survived release'

  # A diagnostic on stderr accompanies actual valid JSON from the real helper.
  real_python=$(command -v python3)
  mkdir "$TMP_ROOT/noisy-python"
  cat > "$TMP_ROOT/noisy-python/python3" <<'SH'
#!/usr/bin/env bash
case "${1:-}:${2:-}" in */fm-task-inbox-obligation.py:tick) echo 'incidental helper diagnostic' >&2 ;; esac
exec "$FM_REAL_PYTHON" "$@"
SH
  chmod +x "$TMP_ROOT/noisy-python/python3"
  export FM_REAL_PYTHON=$real_python
  PATH="$TMP_ROOT/noisy-python:$PATH" inbox_obligation_check_one contended tick 2> "$TMP_ROOT/noisy.err"
  grep -q 'incidental helper diagnostic' "$TMP_ROOT/noisy.err" || fail 'helper stderr diagnostic was lost'
  [ ! -e "$STATE/.instruction-error-contended" ] || fail 'stderr corrupted valid helper JSON'
  inbox_obligation_check_one contended tick
  inbox_obligation_check_one contended tick
  [ "$(grep -c 'instruction execution unaccounted: contended ' "$STATE/.wake-queue")" = 1 ] \
    || fail 'released metadata lock did not resume normal reconciliation and escalation'

  # Unsafe lock indirection and malformed locks are failures, never skips.
  for shape in foreign-link malformed-pid all-zero-pid regular-file; do
    case "$shape" in
      foreign-link) mkdir "$TMP_ROOT/foreign-lock"; printf '%s\n' "$$" > "$TMP_ROOT/foreign-lock/pid"; ln -s "$TMP_ROOT/foreign-lock" "$lock" ;;
      malformed-pid) mkdir "$lock"; printf 'invalid\n' > "$lock/pid" ;;
      all-zero-pid) mkdir "$lock"; printf '00\n' > "$lock/pid" ;;
      regular-file) printf 'invalid\n' > "$lock" ;;
    esac
    INSTRUCTION_WAKE_REASON=
    inbox_obligation_check_one contended tick 2> "$TMP_ROOT/unsafe-lock.err"
    case "$INSTRUCTION_WAKE_REASON" in *'recovery failed'*) ;; *) fail "$shape lock was silently deferred" ;; esac
    [ -f "$STATE/.instruction-error-contended" ] || fail 'unsafe lock failure was not durably visible'
    if [ -d "$lock" ] && [ ! -L "$lock" ]; then rm "$lock/pid"; rmdir "$lock"; else rm "$lock"; fi
    inbox_obligation_check_one contended tick
    [ ! -e "$STATE/.instruction-error-contended" ] || fail 'successful observation retained obsolete failure marker'
  done
  printf '{malformed\n' > "$STATE/contended.inbox/obligations/${held_record##*/}.json"
  INSTRUCTION_WAKE_REASON=
  inbox_obligation_check_one contended tick 2> "$TMP_ROOT/recovery-failed.err"
  case "$INSTRUCTION_WAKE_REASON" in *'recovery failed'*) ;; *) fail 'genuine ledger failure was suppressed' ;; esac
  [ -s "$TMP_ROOT/recovery-failed.err" ] || fail 'genuine recovery failure lost stderr diagnostics'
)
pass 'watcher defers only live lock contention, resumes reconciliation after release, separates stderr, and surfaces unsafe locks and recovery failures'

# A live steal mutex may deny creation while the primary lock is absent. The
# primary acquisition deadline still applies, and this is not primary contention.
python3 - "$ROOT/bin/fm-task-inbox-lib.sh" "$STATE" <<'PY'
import os, pathlib, signal, subprocess, sys
state=pathlib.Path(sys.argv[2])
lock=state/'.meta-deadline.lock'
steal=pathlib.Path(str(lock)+'.steal')
steal.mkdir()
(steal/'pid').write_text(str(os.getpid())+'\n')
child=subprocess.Popen(['bash','-c',
    '. "$1"; FM_TASK_INBOX_LOCK_WAIT_SECS=0 fm_task_inbox_lock_acquire "$2"',
    '_',sys.argv[1],str(lock)],start_new_session=True)
try:
    try:
        status=child.wait(timeout=3)
    except subprocess.TimeoutExpired:
        raise AssertionError('absent primary plus live steal mutex exceeded acquisition deadline')
    assert status==1, f'blocked primary creation returned {status}, expected ordinary failure'
    assert not lock.exists() and not lock.is_symlink(), 'failed acquisition left a primary lock'
    assert (steal/'pid').read_text().strip()==str(os.getpid()), 'foreign steal mutex ownership changed'
finally:
    if child.poll() is None:
        os.killpg(child.pid,signal.SIGTERM)
        try: child.wait(timeout=1)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid,signal.SIGKILL)
            child.wait(timeout=1)
    assert child.poll() is not None, 'owned acquisition process survived cleanup'
    (steal/'pid').unlink()
    steal.rmdir()
PY
pass 'absent primary with a live steal mutex returns ordinary failure at the acquisition deadline'
