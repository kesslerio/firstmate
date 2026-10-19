#!/usr/bin/env python3
"""Record-bound instruction dispositions; shell entry point: fm-task-inbox.sh.

An acknowledgement only settles delivery. Explicit disposition records bind the
home, state directory, task, sequence, body digest, and enqueue spawn generation.
Legacy tasks without a generation accept delivery but cannot prove an incarnation;
their obligations stay visible until a supervisor resolves the lifecycle.

run proves that this helper successfully executed the supplied argv, not that argv
implements the message's meaning. fulfilled is an agent attestation backed by a
nonempty response artifact, not an independent semantic verifier. waiting/refused
require a reason and condition belonging to this exact instruction. Generic busy,
status promises, and turn events never settle an obligation. None of these paths
replays an operation. The shell entry point holds the existing task metadata lock;
the ledger lock also serializes receipts, recovery, and cleanup checks.
"""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import shutil
import socket
import stat
import subprocess
import sys
import tempfile
import time
import uuid

SCRIPT = Path(__file__).with_name('fm-task-inbox.sh')


def fail(message):
    raise ValueError(message)


def safe_path(path, root=None):
    path = Path(os.path.abspath(path))
    if root is not None and not path.is_relative_to(root):
        fail(f'path is outside the owning home: {path}')
    for part in [path, *path.parents]:
        if part.is_symlink():
            fail(f'symlink is not an instruction channel: {part}')
    return path


def read_json(path):
    safe_path(path)
    if not path.exists():
        return None
    if not path.is_file():
        fail(f'expected regular ledger file: {path}')
    with path.open() as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        fail(f'invalid ledger object: {path}')
    return value


def atomic_json(path, value):
    safe_path(path)
    fd, temporary = tempfile.mkstemp(prefix='.obligation-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as handle:
            json.dump(value, handle, sort_keys=True)
            handle.write('\n')
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        sync_directory(path.parent)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def sync_directory(path):
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


class Inbox:
    def __init__(self, state, task):
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', task):
            fail('invalid task identity')
        self.home = safe_path(os.environ.get('FM_HOME') or fail('FM_HOME is required'))
        self.state = safe_path(state)
        if os.environ.get('FM_STATE_OVERRIDE'):
            admitted = {safe_path(os.environ['FM_STATE_OVERRIDE'])}
        else:
            admitted = {self.home / 'state', self.home / 'state' / 'parent-route'}
        if self.state not in admitted:
            fail('instruction state must be the home state, parent-route, or exact explicit FM_STATE_OVERRIDE')
        self.task = task
        self.directory = safe_path(self.state / (task + '.inbox'), self.state)
        self.meta = safe_path(self.state / (task + '.meta'), self.state)

    def generation(self):
        if not self.meta.is_file():
            fail(f'task metadata is missing: {self.meta}')
        values = [line.split('=', 1)[1] for line in self.meta.read_text().splitlines()
                  if line.startswith('spawn_gen=')]
        if len(values) > 1 or (values and not re.fullmatch(r'[A-Za-z0-9._:+-]+', values[0])):
            fail('task generation is ambiguous or invalid')
        return values[0] if values else None

    def header(self, record):
        if not re.fullmatch(r'[0-9]+\.msg', record):
            fail('invalid record name')
        body = sys.stdin.buffer.read()
        return dict(schema=1, home=str(self.home), state=str(self.state), task=self.task,
                    record=record, generation=self.generation(), obligation=uuid.uuid4().hex,
                    accepted=int(time.time()), body_sha256=hashlib.sha256(body).hexdigest(),
                    expectation='disposition', helper=str(SCRIPT),
                    instruction='Acknowledgement is not execution. Use helper --help to record a disposition; never rerun an uncertain operation.')

    def record(self, path):
        path = safe_path(path, self.directory)
        if path.parent not in (self.directory, self.directory / 'handled') or not re.fullmatch(r'[0-9]+\.msg', path.name):
            fail('record must be one numeric .msg in this task inbox or handled directory')
        if not path.is_file():
            fail(f'instruction record is missing: {path}')
        data = path.read_bytes()
        header, separator, body = data.partition(b'\n--\n')
        if not separator:
            fail('invalid instruction record')
        fields = [line[len(b'obligation='):] for line in header.splitlines() if line.startswith(b'obligation=')]
        if not fields:
            return None
        if len(fields) != 1:
            fail('ambiguous instruction obligation')
        claim = json.loads(fields[0])
        if not isinstance(claim, dict):
            fail('invalid instruction obligation')
        expected = dict(schema=1, home=str(self.home), state=str(self.state), task=self.task,
                        record=path.name, expectation='disposition', body_sha256=hashlib.sha256(body).hexdigest())
        if any(claim.get(k) != v for k, v in expected.items()):
            fail('instruction ownership or body identity does not match')
        if not re.fullmatch(r'[0-9a-f]{32}', str(claim.get('obligation', ''))):
            fail('invalid obligation identity')
        if 'generation' not in claim or (claim['generation'] is not None and not re.fullmatch(r'[A-Za-z0-9._:+-]+', str(claim['generation']))):
            fail('invalid instruction generation binding')
        if type(claim.get('accepted')) is not int or claim['accepted'] < 0:
            fail('invalid instruction acceptance time')
        claim['delivery'] = 'fire-and-forget' if b'delivery=fire-and-forget' in header.splitlines() else ''
        return claim

    @contextlib.contextmanager
    def locked(self):
        if not self.directory.exists():
            yield False
            return
        safe_path(self.directory)
        lock = safe_path(self.directory / '.obligation.lock')
        fd = os.open(lock, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                fail('obligation lock is not a regular file')
            deadline = time.monotonic() + 5
            while True:
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        fail('instruction ledger is locked; retry the same disposition')
                    time.sleep(.05)
            yield True
        finally:
            os.close(fd)

    def entries(self):
        seen = set()
        for parent in (self.directory, self.directory / 'handled'):
            safe_path(parent)
            for path in sorted(parent.glob('*.msg')):
                claim = self.record(path)
                if claim is None:
                    continue
                if path.name in seen:
                    fail('instruction exists in both unread and handled directories')
                seen.add(path.name)
                yield path, claim
        directory = safe_path(self.directory / 'obligations')
        for ledger in directory.glob('*.json'):
            if ledger.name.removesuffix('.json') not in seen:
                fail('instruction ledger lost its bound record; retain the channel for reconciliation')

    def ledger(self, claim):
        directory = safe_path(self.directory / 'obligations')
        path = directory / (claim['record'] + '.json')
        data = read_json(path)
        if data is None:
            data = dict(schema=1, obligation=claim['obligation'], home=claim['home'],
                        state=claim['state'], task=self.task, record=claim['record'],
                        generation=claim['generation'], body_sha256=claim['body_sha256'])
        if any(data.get(key) != claim[key] for key in ('schema', 'obligation', 'home', 'state', 'task', 'record', 'generation', 'body_sha256')):
            fail('receipt belongs to a different instruction or incarnation')
        for key in ('observed', 'recovery'):
            if key in data and (type(data[key]) is not int or data[key] < 0):
                fail('malformed instruction recovery budget')
        receipt = data.get('receipt')
        attempt = data.get('attempt')
        if attempt is not None:
            if (not isinstance(attempt, dict)
                    or not re.fullmatch(r'[0-9a-f]{64}', str(attempt.get('command_sha256', '')))
                    or not re.fullmatch(r'[0-9a-f]{32}', str(attempt.get('execution_id', '')))
                    or type(attempt.get('at')) is not int or attempt['at'] < 0):
                fail('malformed execution reservation; retain for reconciliation')
        if receipt is not None:
            if not isinstance(receipt, dict) or receipt.get('disposition') not in ('started', 'waiting', 'refused', 'fulfilled'):
                fail('malformed instruction disposition')
            disposition = receipt['disposition']
            if disposition in ('waiting', 'refused') and any(not isinstance(receipt.get(key), str) or not receipt[key].strip() for key in ('reason', 'condition')):
                fail('wait/refusal has no concrete reason and condition')
            if disposition == 'started' and (receipt.get('proof') != 'helper-exec' or type(receipt.get('pid')) is not int or receipt['pid'] < 1 or not re.fullmatch(r'[0-9a-f]{64}', str(receipt.get('command_sha256', ''))) or not re.fullmatch(r'[0-9a-f]{32}', str(receipt.get('execution_id', '')))):
                fail('started receipt has no helper execution evidence')
            if disposition == 'fulfilled' and (receipt.get('proof') != 'agent-response' or not receipt.get('sha256')):
                fail('fulfilled receipt has no response evidence')
            if 'returncode' in receipt and (disposition != 'started' or type(receipt['returncode']) is not int
                                            or not -255 <= receipt['returncode'] <= 255):
                fail('malformed execution return status')
            if attempt is not None and (disposition != 'started' or any(
                    receipt.get(key) != attempt[key] for key in ('command_sha256', 'execution_id'))):
                fail('execution receipt does not match its reservation')
        return path, data

    def save(self, path, data):
        safe_path(path.parent)
        path.parent.mkdir(mode=0o700, exist_ok=True)
        # Persist the obligations directory entry as well as the ledger inside it.
        sync_directory(path.parent.parent)
        atomic_json(path, data)

    def current(self, claim, generation):
        actual = self.generation()
        if not actual or not claim['generation']:
            fail('unverified incarnation: delivery retained, but a legacy task cannot attest a generation-bound disposition')
        if claim['generation'] != actual or generation != actual:
            fail('wrong or superseded spawn generation')

    def disposition(self, args):
        claim = self.record(args.record)
        if claim is None:
            fail('legacy/passive record has no disposition obligation')
        self.current(claim, args.gen)
        path, data = self.ledger(claim)
        if args.command == 'run':
            if not args.argv or args.argv[0] == '--' and len(args.argv) == 1:
                fail('run needs an executable argv')
            argv = args.argv[1:] if args.argv[0] == '--' else args.argv
            command_sha256 = hashlib.sha256(json.dumps(argv).encode()).hexdigest()
            if data.get('receipt'):
                if data['receipt'].get('command_sha256') == command_sha256 and data['receipt'].get('proof') == 'helper-exec':
                    print(json.dumps(data))
                    if 'returncode' not in data['receipt']:
                        fail('execution is still running or its completion is uncertain; operation was not repeated')
                    result = data['receipt']['returncode']
                    raise SystemExit(result if 0 <= result <= 255 else 1)
                fail('conflicting disposition; operation was not repeated')
            if data.get('attempt'):
                fail('execution attempt is uncertain; reconcile the reserved instruction without repeating its operation')
            data['attempt'] = dict(command_sha256=command_sha256, execution_id=uuid.uuid4().hex,
                                   at=int(time.time()))
            self.save(path, data)
            child_env = {key: value for key, value in os.environ.items() if key != 'FM_INSTRUCTION_READY_FILE'}
            try:
                child = subprocess.Popen(argv, start_new_session=True, env=child_env)
            except OSError:
                fail('requested executable could not be started; execution reservation retained for reconciliation')
            try:
                def interrupted(signum, _frame):
                    stop_child(child)
                    raise SystemExit(128 + signum)
                for signum in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
                    signal.signal(signum, interrupted)
                identity = None
                proc = Path(f'/proc/{child.pid}/stat')
                if proc.exists():
                    try:
                        identity = proc.read_text().rsplit(')', 1)[1].split()[19]
                    except (OSError, IndexError):
                        pass
                child.instruction_start_identity = identity
                receipt = dict(disposition='started', proof='helper-exec', command_sha256=command_sha256,
                               executable_sha256=hashlib.sha256((shutil.which(argv[0]) or argv[0]).encode()).hexdigest(),
                               execution_id=data['attempt']['execution_id'], pid=child.pid,
                               pid_start=identity, host=socket.gethostname(), at=int(time.time()))
                data['receipt'] = receipt
                self.save(path, data)
                print(json.dumps(data), flush=True)
                ready = os.environ.get('FM_INSTRUCTION_READY_FILE')
                if not ready:
                    fail('execution owner did not provide its metadata-lock handoff')
                safe_path(ready, self.state).write_text('ready\n')
                return child, path, data
            except BaseException:
                # Every post-exec handoff failure still owns the command group.
                # Retain any durable start receipt: the operation did execute.
                stop_child(child)
                raise
        if data.get('attempt') and not data.get('receipt'):
            fail('execution attempt is uncertain; a disposition cannot overwrite its reservation')
        if args.disposition not in ('waiting', 'refused', 'fulfilled'):
            fail('started requires run with an actual executable; busy or a promise is not evidence')
        receipt = dict(disposition=args.disposition)
        if args.disposition in ('waiting', 'refused'):
            if not args.reason or not args.reason.strip() or not args.condition or not args.condition.strip():
                fail('wait/refusal requires a nonempty reason and condition or decision key')
            receipt.update(reason=args.reason, condition=args.condition)
        else:
            if not args.response:
                fail('fulfilled requires a nonempty response artifact; this is an agent attestation')
            response = safe_path(args.response, self.home)
            if not response.is_file() or not response.read_bytes().strip():
                fail('response artifact must be a nonempty regular file in the owning home')
            receipt.update(proof='agent-response', response=str(response), sha256=hashlib.sha256(response.read_bytes()).hexdigest())
        previous = data.get('receipt')
        if previous:
            if {k: v for k, v in previous.items() if k != 'at'} != receipt:
                fail('conflicting disposition for this instruction')
            print(json.dumps(data))
            return None
        receipt['at'] = int(time.time())
        if args.disposition == 'waiting':
            subprocess.run([str(SCRIPT), '_wait', self.task, claim['obligation'], args.reason, args.condition], check=True)
        data['receipt'] = receipt
        self.save(path, data)
        print(json.dumps(data))
        return None

    def query(self):
        result = []
        for record, claim in self.entries():
            _, data = self.ledger(claim)
            result.append(dict(**claim, handled=record.parent.name == 'handled', receipt=data.get('receipt'),
                               attempt=data.get('attempt'),
                               recovery=data.get('recovery'), escalated=data.get('escalated', False),
                               outstanding=self.outstanding(claim, data)))
        return result

    def outstanding(self, claim, data):
        receipt = data.get('receipt')
        return not receipt or (receipt['disposition'] in ('waiting', 'refused') and self.generation() != claim['generation'])

    def tick(self, report_only=False):
        grace = os.environ.get('FM_TASK_INBOX_OBLIGATION_GRACE_SECS', '90')
        if not re.fullmatch(r'[0-9]{1,8}', grace):
            fail('FM_TASK_INBOX_OBLIGATION_GRACE_SECS must be 0..99999999')
        now = int(time.time())
        alerts = []
        generation = self.generation()
        for record, claim in self.entries():
            path, data = self.ledger(claim)
            if not self.outstanding(claim, data):
                continue
            stale = not generation or generation != claim['generation']
            # Delivery owns unread records. A replaced/unverified incarnation
            # has no safe delivery target and must remain visible regardless.
            if record.parent.name != 'handled' and not stale and claim['delivery'] != 'fire-and-forget':
                continue
            if data.get('escalated'):
                if report_only:
                    alerts.append(dict(obligation=claim['obligation'], message=data['escalated']))
                continue
            if 'observed' not in data:
                data['observed'] = now
                self.save(path, data)
                continue
            if now - data.get('recovery', data['observed']) < int(grace):
                continue
            if not stale and 'recovery' not in data:
                # Reserve the sole reconciliation attempt before terminal I/O.
                # Unknown delivery never causes an operation or nudge replay.
                data['recovery'] = now
                self.save(path, data)
                retry = safe_path(self.directory / '.retry-ring')
                if retry.is_file() and retry.read_text().strip() == record.name:
                    retry.unlink()
                subprocess.run([str(SCRIPT), '_ring', self.task, str(record)], check=False)
                continue
            suffix = ('unverified or superseded incarnation' if stale else
                      'execution attempt reserved but execution evidence is uncertain' if data.get('attempt') else
                      'acknowledged without a disposition')
            message = f'instruction execution unaccounted: {self.task} {claim["record"]} obligation={claim["obligation"]} ({suffix}); reconcile this existing instruction, never blindly replay its operation'
            if report_only:
                alerts.append(dict(obligation=claim['obligation'], message=message))
            else:
                # Queue before dedup, while receipts remain excluded by locks.
                subprocess.run([str(SCRIPT), '_wake', self.task, message], check=True)
                data['escalated'] = message
                self.save(path, data)
                alerts.append(dict(obligation=claim['obligation'], message=message))
        print(json.dumps(alerts))

    def remote_tick(self):
        """Parent-owned observation; transport loss never means an empty inbox."""
        path = safe_path(self.state / ('.obligation-remote-' + self.task + '.json'))
        data = read_json(path)
        if data is None:
            print('[]')
            return
        if data.get('schema') != 1 or data.get('task') != self.task or data.get('home') != str(self.home):
            fail('foreign remote-obligation monitor')
        now = int(time.time())
        grace = os.environ.get('FM_TASK_INBOX_OBLIGATION_GRACE_SECS', '90')
        if not re.fullmatch(r'[0-9]{1,8}', grace):
            fail('invalid instruction obligation grace')
        if now - data.get('queried_at', 0) < int(grace):
            print('[]')
            return
        data['queried_at'] = now
        atomic_json(path, data)
        result = subprocess.run([str(SCRIPT), '_remote', self.task], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        try:
            snapshot = json.loads(result.stdout) if result.returncode == 0 else None
            if not isinstance(snapshot, dict) or snapshot.get('schema') != 'fm-instruction-observations.v1' or snapshot.get('task') != self.task or not isinstance(snapshot.get('alerts'), list):
                raise ValueError('unknown remote observation')
            alerts = snapshot['alerts']
            if any(not isinstance(item, dict) or not re.fullmatch(r'[0-9a-f]{32}', str(item.get('obligation', ''))) or not isinstance(item.get('message'), str) for item in alerts):
                raise ValueError('invalid remote observation')
            observations = snapshot.get('obligations')
            if not isinstance(observations, list) or any(
                    not isinstance(item, dict) or item.get('schema') != 1 or item.get('task') != self.task
                    or not re.fullmatch(r'[0-9a-f]{32}', str(item.get('obligation', '')))
                    or not re.fullmatch(r'[0-9]+\.msg', str(item.get('record', '')))
                    or type(item.get('outstanding')) is not bool for item in observations):
                raise ValueError('invalid remote instruction identities')
            if len({item['obligation'] for item in observations}) != len(observations):
                raise ValueError('duplicate remote instruction identities')
            data['outstanding'] = [item['obligation'] for item in observations if item['outstanding']]
            data.pop('unknown_since', None)
            # Positive reconciliation closes this transport outage only. Keep
            # exact instruction dedups, but allow a later outage to surface.
            data['alerts'] = [key for key in data['alerts'] if key != 'unknown']
        except (ValueError, TypeError):
            if 'unknown_since' not in data:
                data['unknown_since'] = now
                atomic_json(path, data)
                print('[]')
                return
            if now - data['unknown_since'] < int(grace):
                print('[]')
                return
            alerts = [dict(obligation='unknown', message=f'instruction obligation observation unknown for remote task {self.task}; verify transport and matching remote helper version; never resend the original operation blindly')]
        emitted = []
        for alert in alerts:
            if alert['obligation'] in data['alerts']:
                continue
            subprocess.run([str(SCRIPT), '_wake', self.task, alert['message']], check=True)
            data['alerts'].append(alert['obligation'])
            atomic_json(path, data)
            emitted.append(alert)
        if not emitted:
            atomic_json(path, data)
        print(json.dumps(emitted))

    def remote_track(self):
        path = safe_path(self.state / ('.obligation-remote-' + self.task + '.json'))
        data = read_json(path) or dict(schema=1, task=self.task, home=str(self.home), alerts=[])
        if data.get('task') != self.task or data.get('home') != str(self.home):
            fail('foreign remote-obligation monitor')
        # Before transport, record that an enqueue may become completion-unknown.
        # The next observation must reconcile it even if reply tracking resolves.
        data['outstanding'] = None
        data['queried_at'] = 0
        atomic_json(path, data)


def stop_child(child):
    # A completed group can disappear and its numeric leader PID can be reused.
    # If Linux now exposes a different leader incarnation, it is not ours.
    identity = getattr(child, 'instruction_start_identity', None)
    if identity is not None:
        try:
            current = Path(f'/proc/{child.pid}/stat').read_text().rsplit(')', 1)[1].split()[19]
            if current != identity:
                return
        except (OSError, IndexError):
            pass
    try:
        os.killpg(child.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        child.wait(timeout=2)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    child.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('validate', 'verify', 'header', 'query', 'tick', 'remote-tick', 'remote-track', 'guard', 'disposition', 'run', 'finish'))
    parser.add_argument('state')
    parser.add_argument('task')
    parser.add_argument('record', nargs='?')
    parser.add_argument('--gen')
    parser.add_argument('--disposition')
    parser.add_argument('--reason')
    parser.add_argument('--condition')
    parser.add_argument('--response')
    parser.add_argument('--report-only', action='store_true')
    parser.add_argument('--timeout', type=int, default=300)
    parser.add_argument('--execution-id')
    parser.add_argument('--returncode', type=int)
    # Split the command argv before argparse, preserving literal flags/bytes.
    argv = sys.argv[1:]
    command_argv = []
    if '--' in argv:
        index = argv.index('--')
        command_argv, argv = argv[index + 1:], argv[:index]
    args = parser.parse_args(argv)
    args.argv = command_argv
    inbox = Inbox(args.state, args.task)
    if args.command == 'validate':
        safe_path(inbox.directory / 'handled', inbox.state)
        inbox.generation()
        return
    if args.command == 'verify':
        if inbox.record(args.record) is None:
            fail('matching legacy delivery has no obligation; inspect it rather than minting a duplicate')
        return
    if args.command == 'header':
        print('obligation=' + json.dumps(inbox.header(args.record), separators=(',', ':')))
        return
    if args.command == 'remote-tick':
        inbox.remote_tick()
        return
    if args.command == 'remote-track':
        inbox.remote_track()
        return
    if args.command == 'guard':
        monitor = read_json(inbox.state / ('.obligation-remote-' + inbox.task + '.json'))
        if monitor and (monitor.get('outstanding') is None or monitor.get('outstanding') or 'unknown_since' in monitor):
            fail('teardown refused: remote instruction obligations are outstanding or unobserved; reconcile the remote inbox first')
    child_result = None
    with inbox.locked() as exists:
        if not exists:
            if args.command in ('query', 'tick', 'guard'):
                print('[]')
                return
            fail('instruction inbox is absent')
        if args.command == 'query':
            print(json.dumps(inbox.query()))
        elif args.command == 'tick':
            inbox.tick(args.report_only)
        elif args.command == 'guard':
            outstanding = [item for item in inbox.query() if item['outstanding']]
            if outstanding:
                fail('teardown refused: outstanding instruction obligations: ' + ', '.join(item['record'] for item in outstanding))
        elif args.command == 'finish':
            if args.returncode is None or not -255 <= args.returncode <= 255:
                fail('finish requires an execution return status in -255..255')
            claim = inbox.record(args.record)
            if claim is None:
                fail('execution record no longer owns its instruction')
            inbox.current(claim, args.gen)
            path, data = inbox.ledger(claim)
            receipt = data.get('receipt', {})
            if receipt.get('proof') != 'helper-exec' or receipt.get('execution_id') != args.execution_id:
                fail('execution return belongs to a different receipt')
            if 'returncode' in receipt and receipt['returncode'] != args.returncode:
                fail('conflicting execution return')
            receipt['returncode'] = args.returncode
            receipt['returned_at'] = int(time.time())
            inbox.save(path, data)
        else:
            if not args.record:
                fail('record path is required')
            if not 1 <= args.timeout <= 3600:
                fail('run timeout must be 1..3600 seconds')
            child_result = inbox.disposition(args)
    if child_result:
        child, path, data = child_result
        try:
            try:
                result = child.wait(timeout=args.timeout)
            except subprocess.TimeoutExpired:
                stop_child(child)
                result = 124
        finally:
            # This wrapper owns the command group, not detached worker sessions.
            stop_child(child)
        subprocess.run([str(SCRIPT), 'finish', inbox.task, args.record, '--gen', args.gen,
                        '--execution-id', data['receipt']['execution_id'], '--returncode', str(result)], check=True)
        sys.exit(result if 0 <= result <= 255 else 1)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f'error: instruction obligation: {error}', file=sys.stderr)
        sys.exit(1)
