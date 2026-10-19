#!/usr/bin/env python3
"""One owner for ready-review generations, dispositions and acknowledgment guards.

Uses tasks-axi's flat TOON table, never parses backlog Markdown. All receipts
bind canonical home, state, data and backend, plus a candidate graph generation.
A missing dependency is uncertain, never equivalent to known Done. Explicit
holds are reconsidered but never released here. No dispatch policy lives here.

A branch report's readyReview field is the durable handoff itself. Publication
of that outcome precedes any acknowledgment; failure leaves the review pending.
MAIN cannot consume the handoff until each current candidate has processing
proof or a current concrete stop. Structured stops bind current retry facts;
other stops are bounded supervisor attestations and expire within five minutes.
The launch hook records only confirmed fm-spawn publication, not processing;
current fm-crew-state working evidence must also match the same incarnation.
Once observed, that start is retained through idle, terminal lifecycle states,
and prerequisite pruning for the same in-flight worker. A new queued obligation,
changed hold/task facts, or replacement worker requires fresh start evidence.
Confirmed launch facts are saved before graph observation and reconciled only
within the same candidate epoch after an unavailable graph recovers.
Caller provenance and private receipts are consistency checks, not a security
boundary against an actor able to rewrite this same user's scripts or state.
"""
from contextlib import contextmanager
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import signal
import stat
import subprocess
import sys
import tempfile
import time

BIN = Path(__file__).resolve().parent
FIELDS = ['id', 'state', 'kind', 'repo', 'title', 'deps', 'blocked', 'blocked_by',
          'held', 'hold_kind', 'hold_reason', 'hold_until']
ID = re.compile(r'[A-Za-z0-9][A-Za-z0-9._-]*\Z')
GEN = re.compile(r'[0-9a-f]{64}\Z')
SPAWN = re.compile(r's[1-9][0-9]*\.[0-9]+\.[0-9]+\Z')
GATES = ('structured', 'approval', 'credential', 'account', 'spend', 'capacity', 'away', 'external')
MAX_BYTES = 8 * 1024 * 1024


class Refusal(Exception):
    pass


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def safe_dir(path, create=False):
    if create:
        path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise Refusal(f'unsafe review directory: {path}')


@contextmanager
def input_stream(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    except FileNotFoundError:
        yield None
        return
    with os.fdopen(fd, 'r', encoding='utf-8') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_mode & 0o022:
            raise Refusal(f'unsafe review input: {path}')
        yield stream


def read(path, absent=None):
    with input_stream(path) as stream:
        if stream is None:
            return absent
        value = stream.read(MAX_BYTES + 1)
        if len(value.encode('utf-8')) > MAX_BYTES:
            raise Refusal(f'oversized review record: {path}')
        return value


def outcome_rows(path):
    with input_stream(path) as stream:
        if stream is None:
            return
        while True:
            line = stream.readline(MAX_BYTES + 1)
            if not line:
                return
            if len(line.encode('utf-8')) > MAX_BYTES:
                raise Refusal(f'oversized outcome record: {path}')
            yield json.loads(line)


def validate_ledger_records(value):
    if not isinstance(value, dict):
        raise Refusal('invalid ready review ledger')
    for key, record in value.items():
        records = ({name: item} for name, item in record.items()) if key == 'candidates' and isinstance(record, dict) else ({key: record},)
        if any(len(json.dumps(item).encode('utf-8')) > MAX_BYTES for item in records):
            raise Refusal('oversized ready review ledger record')


def write(path, value):
    with input_stream(path):
        pass
    validate_ledger_records(value)
    fd, name = tempfile.mkstemp(prefix='.ready-review.', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream, sort_keys=True)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def run(args, timeout=15):
    # Commands are literal argv; neither output nor argv is retained on failure.
    try:
        process = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        try:
            stdout, _stderr = process.communicate(timeout=timeout)
        except BaseException:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate()
            raise
    except (OSError, subprocess.TimeoutExpired) as error:
        raise Refusal(f'{Path(args[0]).name} observation unavailable') from error
    if process.returncode:
        raise Refusal(f'{Path(args[0]).name} observation failed (exit {process.returncode})')
    if len(stdout) > MAX_BYTES:
        raise Refusal('graph observation exceeds review bound')
    return stdout


def launch_caller():
    """Only the direct post-commit spawn caller can publish launch provenance."""
    parent = os.getppid()
    proc = Path(f'/proc/{parent}/cmdline')
    try:
        if proc.exists():
            words = proc.read_bytes().decode().rstrip('\0').split('\0')
        else:
            words = shlex.split(run(['ps', '-p', str(parent), '-o', 'command='], timeout=3))
        expected = BIN / 'fm-spawn.sh'
        return any(Path(word).resolve() == expected for word in words[:3])
    except (OSError, ValueError, Refusal):
        return False


def toon_cells(line):
    """Decode the flat string-only table emitted by tasks-axi list --fields.

    TOON quotes use JSON escaping, not CSV double-quote escaping. Reject any
    different shape rather than interpreting partial graph output as empty.
    """
    cells, offset = [], 0
    while offset < len(line):
        if line[offset] == '"':
            cell, end = json.JSONDecoder().raw_decode(line[offset:])
            if not isinstance(cell, str):
                raise Refusal('graph table contains a non-string field')
            offset += end
        else:
            end = line.find(',', offset)
            if end < 0:
                end = len(line)
            cell, offset = line[offset:end], end
        cells.append(cell)
        if offset == len(line):
            break
        if line[offset] != ',':
            raise Refusal('graph table delimiter is invalid')
        offset += 1
    return cells


def graph(data, backend):
    if backend == 'markdown' and not (data / 'backlog.md').exists() and not (data / 'backlog.md').is_symlink():
        return {}
    if backend == 'markdown':
        read(data / 'backlog.md')  # Validate before any tasks-axi read.
    output = run([str(BIN / 'fm-tasks-axi.sh'), 'list', '--fields', ','.join(FIELDS[5:])])
    lines = output.splitlines()
    if not lines or not re.fullmatch(r'count: [0-9]+', lines[0]):
        raise Refusal('tasks-axi graph count is unavailable')
    count = int(lines[0][7:])
    if count == 0:
        return {}
    expected = f'tasks[{count}]' + '{' + ','.join(FIELDS) + '}:'
    if len(lines) < count + 2 or lines[1] != expected:
        raise Refusal('tasks-axi graph schema is unavailable')
    rows = {}
    for line in lines[2:count + 2]:
        if not line.startswith('  '):
            raise Refusal('tasks-axi graph row is malformed')
        values = toon_cells(line[2:])
        if len(values) != len(FIELDS):
            raise Refusal('tasks-axi graph row has missing fields')
        row = dict(zip(FIELDS, values))
        task = row['id']
        if not ID.fullmatch(task) or task in rows or row['state'] not in ('queued', 'in_flight', 'done'):
            raise Refusal('tasks-axi graph identity is invalid')
        if row['held'] not in ('yes', 'no') or row['blocked'] not in ('yes', 'no'):
            raise Refusal('tasks-axi graph eligibility is invalid')
        deps = []
        if row['deps'] != 'none':
            for edge in row['deps'].split(','):
                kind, sep, target = edge.partition(':')
                if not sep or not ID.fullmatch(target):
                    raise Refusal('tasks-axi dependency identity is invalid')
                if kind == 'blocked-by':
                    deps.append(target)
        row['dependencies'] = sorted(set(deps))
        rows[task] = row
    return rows


class Review:
    def __init__(self, args):
        self.home = Path(os.environ['FM_HOME']).resolve(strict=True)
        self.state = Path(os.environ.get('FM_STATE_OVERRIDE') or str(self.home / 'state'))
        safe_dir(self.state, create=True)
        self.state = self.state.resolve(strict=True)
        self.data = Path(args.data).resolve()
        self.backend = args.backend
        self.manual_lifecycle = args.manual_lifecycle
        self.binding = digest([str(self.home), str(self.state), str(self.data), self.backend])
        self.path = self.state / '.ready-review.json'
        self.lock = None
        self.now = int(time.time())

    def __enter__(self):
        path = self.state / '.ready-review.lock'
        self.lock = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
        info = os.fstat(self.lock)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.getuid():
            raise Refusal('unsafe ready review lock')
        deadline = time.monotonic() + 10
        while True:
            try:
                fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    raise Refusal('ready review lock remained busy; retry review')
                time.sleep(.05)
        with input_stream(self.path) as stream:
            self.book = json.load(stream) if stream is not None else {'schema': 1, 'binding': self.binding, 'candidates': {}}
        validate_ledger_records(self.book)
        if self.book.get('schema') != 1 or self.book.get('binding') != self.binding or not isinstance(self.book.get('candidates'), dict):
            raise Refusal('foreign or invalid ready review ledger; repair owning-home state')
        for task, item in self.book['candidates'].items():
            if not ID.fullmatch(task) or not isinstance(item, dict) or not GEN.fullmatch(item.get('generation', '')):
                raise Refusal('invalid ready review candidate')
        return self

    def __exit__(self, *_args):
        if self.lock is not None:
            os.close(self.lock)

    def save(self):
        write(self.path, self.book)

    def sync(self):
        try:
            self.rows = graph(self.data, self.backend)
            self.book.pop('uncertainty', None)
        except Refusal as error:
            self.rows = None
            self.book['uncertainty'] = str(error)
            self.save()
            return
        candidates = self.book['candidates']
        for task, row in self.rows.items():
            deps = {dep: self.rows.get(dep, {}).get('state', 'missing') for dep in row['dependencies']}
            eligible = row['held'] == 'no' and row['blocked'] == 'no'
            affected = bool(deps) and (any(state in ('done', 'missing') for state in deps.values()) or task in candidates)
            if task not in candidates and (row['state'] != 'queued' or row['kind'] == 'public-followup' or not (eligible or affected)):
                continue
            # In-flight is a result of launch, not a new candidate generation.
            facts = {key: row[key] for key in ('id', 'kind', 'repo', 'held', 'hold_kind', 'hold_reason', 'hold_until')}
            facts['dependencies'] = deps
            prior = candidates.get(task)
            if prior is not None and self.observed_start(prior) and row['state'] == 'done':
                # The obligation was to begin this work. A subsequent lifecycle
                # event cannot undo the start we actually observed. Reopening
                # this id below creates a fresh obligation instead.
                prior['state'] = 'done'
                continue
            lifecycle_changed = prior is not None and prior.get('state') != row['state'] and (
                row['state'] in ('queued', 'done') or prior.get('state') in ('done', 'missing'))
            replaced = False
            same_worker = False
            if prior is not None and self.observed_start(prior) and row['state'] != 'done':
                raw = read(self.state / f'{task}.meta')
                if raw is not None:
                    try:
                        meta = self.metadata(task)
                        replaced = (meta['spawn_gen'] != prior['observed_start']['spawn_gen']
                                    or self.metadata(task) != meta)
                        same_worker = not replaced
                    except Refusal:
                        replaced = True
            if prior is None or prior['facts'] != facts or lifecycle_changed or replaced:
                # Graph eligibility changes independently of a start already
                # observed for this exact worker. Pruning a Done prerequisite
                # cannot erase that history or grant a new dispatch/hold release.
                retain_start = (same_worker and prior.get('state') == row['state'] == 'in_flight'
                                and {key: value for key, value in prior['facts'].items() if key != 'dependencies'}
                                == {key: value for key, value in facts.items() if key != 'dependencies'}
                                and prior['facts']['dependencies'].keys() == deps.keys()
                                and all(old == deps[dep] or (old == 'done' and deps[dep] == 'missing')
                                        for dep, old in prior['facts']['dependencies'].items()))
                # A-B-A graph changes must never revive an old receipt token.
                candidates[task] = {'generation': digest([self.binding, facts, secrets.token_hex(16)]),
                                    'facts': facts, 'created': self.now}
                if retain_start:
                    candidates[task].update(start_generation=prior.get('start_generation', prior['generation']),
                                            launch=prior['launch'], observed_start=prior['observed_start'])
            candidates[task]['state'] = row['state']
        for task, item in candidates.items():
            if task not in self.rows:
                if self.observed_start(item):
                    item['state'] = 'missing'
                elif item.get('state') != 'missing':
                    facts = dict(item['facts'], missing=True)
                    candidates[task] = {'generation': digest([self.binding, facts, secrets.token_hex(16)]), 'facts': facts,
                                        'created': self.now, 'state': 'missing'}
        for task, item in candidates.items():
            launch = item.get('confirmed_launch')
            if (isinstance(launch, dict) and launch.get('binding') == self.binding
                    and launch.get('generation') == item['generation'] and item.get('state') == 'in_flight'):
                try:
                    if self.metadata(task)['spawn_gen'] == launch.get('spawn_gen'):
                        if self.observed_start(item):
                            item.pop('confirmed_launch')
                        else:
                            item['launch'] = item.pop('confirmed_launch')
                            item.pop('start_generation', None)
                            item.pop('observed_start', None)
                    else:
                        item.pop('confirmed_launch')
                except Refusal:
                    item.pop('confirmed_launch')
        self.save()

    def confirm_launch(self, task, spawn_generation):
        """Persist the direct confirmed-spawn fact before observing the graph."""
        meta = self.metadata(task)
        if meta['spawn_gen'] != spawn_generation or self.metadata(task) != meta:
            raise Refusal('launch publication does not match current worker incarnation')
        item = self.book['candidates'].get(task)
        if item is not None:
            previous = item.get('launch', item.get('confirmed_launch'))
            if (isinstance(previous, dict) and previous.get('binding') == self.binding
                    and previous.get('spawn_gen') != spawn_generation):
                # A fresh confirmed replacement belongs to a fresh lifecycle;
                # it must not inherit the previous worker's proof or stop.
                item = {'generation': digest([self.binding, item['facts'], secrets.token_hex(16)]),
                        'facts': item['facts'], 'created': self.now, 'state': item['state']}
                self.book['candidates'][task] = item
            item['confirmed_launch'] = {'binding': self.binding, 'generation': item['generation'],
                                        'spawn_gen': spawn_generation}
            self.save()
            return item['generation']
        return None

    def defer_manual_launch(self, task, spawn_generation, launch_generation):
        """Retain genuine launch provenance while its manual row transition is owed."""
        if not self.manual_lifecycle or self.rows is None:
            return False
        item = self.book['candidates'].get(task)
        row = self.rows.get(task)
        if (item is None or row is None or row['state'] != 'queued'
                or row['held'] != 'no' or row['blocked'] != 'no'):
            return False
        if launch_generation is None:
            # A healthy first graph observation can discover the candidate only
            # after the direct caller's initial confirmation found no epoch.
            # Never rebind an existing epoch that changed during this hook.
            launch_generation = self.confirm_launch(task, spawn_generation)
        fact = item.get('confirmed_launch')
        meta = self.metadata(task)
        return (item['generation'] == launch_generation and item.get('state') == 'queued'
                and meta['spawn_gen'] == spawn_generation and self.metadata(task) == meta
                and isinstance(fact, dict) and fact.get('binding') == self.binding
                and fact.get('generation') == launch_generation
                and fact.get('spawn_gen') == spawn_generation)

    def retry_facts(self):
        # Hash facts, never record account names, paths or configuration contents.
        names = ('crew-dispatch.json', 'project-capacity', 'worker-target', 'pi-account', 'claude-account', 'backend', 'crew-harness')
        config = Path(os.environ.get('FM_CONFIG_OVERRIDE') or str(self.home / 'config'))
        if config.exists() or config.is_symlink():
            safe_dir(config)
        values = [read(config / name) for name in names]
        values += [read(self.state / name) for name in ('.afk-contract', '.afk', '.last-launch')]
        topology = run(['bash', '-c',
                        '. "$1/fm-wake-lib.sh"; . "$1/fm-secondmate-registry-lib.sh"; '
                        'fm_firstmate_root_home "$2" || exit 1; '
                        'fm_local_firstmate_state_dirs "$3" || exit 1; '
                        'printf "%s\n" "${FM_LOCAL_FIRSTMATE_STATES[@]}"',
                        'ready-review', str(BIN), str(self.home), str(self.state)]).splitlines()
        root_config = Path(topology[0]) / 'config'
        if root_config.exists() or root_config.is_symlink():
            safe_dir(root_config)
        values.append(read(root_config / 'project-capacity'))
        for directory in sorted(set(topology[1:])):
            state = Path(directory)
            if state.exists() or state.is_symlink():
                safe_dir(state)
            values.append(directory)
            for path in sorted(state.glob('*.meta')):
                values.append([str(path), read(path)])
        values.append(run(['bash', '-c',
                           '. "$1/fm-liveness-lib.sh"; '
                           'fm_liveness_snapshot "$2" "$3" || exit 1; '
                           'printf "%s\n" "$FM_LIVENESS_TARGET" "$FM_LIVENESS_LIVE"',
                           'ready-review', str(BIN), str(self.home), str(self.state)]))
        return digest(values)

    def poll(self):
        # A local graph mutation bypasses idle-heartbeat backoff. Other backends
        # and time/liveness changes are re-observed within 30 seconds. These
        # are opaque input bytes, not another Markdown interpretation.
        inputs = [self.backend, read(self.data.parent / '.tasks.toml'), self.retry_facts()]
        if self.backend == 'markdown':
            inputs.append(read(self.data / 'backlog.md'))
        fingerprint = digest(inputs)
        observation = self.book.get('observation', {})
        if observation.get('fingerprint') == fingerprint and self.now < observation.get('next', 0) <= self.now + 30:
            return
        self.sync()
        pending = self.unresolved('branch')
        if pending:
            key = 'ready-review:' + digest([self.binding, pending])
            queued = read(self.state / '.wake-queue', '')
            exists = any(len(parts) >= 5 and parts[3] == key for parts in (line.split('\t') for line in queued.splitlines()))
            if not exists:
                # Queue before recording the observation. A failed append or
                # restart retries; an existing unconsumed row is responsibility,
                # never an acknowledgment. Existing turn recovery owns retries
                # and escalation; this observer never replays a launch.
                run(['bash', '-c', '. "$1/fm-wake-lib.sh"; fm_wake_append heartbeat "$2" heartbeat', 'ready-review', str(BIN), key])
                print('heartbeat')
        self.book['observation'] = {'fingerprint': fingerprint, 'next': self.now + 30}
        self.save()

    def metadata(self, task):
        raw = read(self.state / f'{task}.meta')
        if raw is None:
            raise Refusal('candidate has no launch metadata')
        values = {}
        for line in raw.splitlines():
            key, sep, value = line.partition('=')
            if sep:
                if key in values:
                    raise Refusal('candidate has ambiguous launch metadata')
                values[key] = value
        gen = values.get('spawn_gen', '')
        if not SPAWN.fullmatch(gen) or values.get('endpoint_task_id') != task or values.get('kind', 'ship') == 'secondmate':
            raise Refusal('candidate launch identity is unverified')
        if values.get('home') and Path(values['home']).resolve() != self.home:
            raise Refusal('candidate launch belongs to another home')
        return values

    def started(self, task, item):
        launch = item.get('launch')
        if not isinstance(launch, dict) or launch.get('generation') != item['generation'] or launch.get('binding') != self.binding:
            return False
        if item.get('state') != 'in_flight':
            return False
        try:
            meta = self.metadata(task)
            if meta['spawn_gen'] != launch.get('spawn_gen'):
                return False
            output = run([str(BIN / 'fm-crew-state.sh'), task], timeout=12)
            if self.metadata(task) != meta:
                return False
            if output.startswith('state: working · source: ') and ('source: pane ·' in output or 'source: run-step ·' in output):
                item['observed_start'] = {'binding': self.binding, 'generation': item['generation'],
                                          'spawn_gen': meta['spawn_gen'], 'observed_at': self.now}
                self.save()
                return True
            return False
        except Refusal:
            return False

    def observed_start(self, item):
        proof = item.get('observed_start')
        launch = item.get('launch')
        generation = item.get('start_generation', item['generation'])
        return (isinstance(generation, str) and GEN.fullmatch(generation) is not None
                and isinstance(proof, dict) and isinstance(launch, dict)
                and proof.get('binding') == launch.get('binding') == self.binding
                and proof.get('generation') == launch.get('generation') == generation
                and proof.get('spawn_gen') == launch.get('spawn_gen')
                and SPAWN.fullmatch(proof.get('spawn_gen', '')) is not None
                and isinstance(proof.get('observed_at'), int) and 0 < proof['observed_at'] <= self.now)

    def settled(self, task, item):
        if self.observed_start(item):
            return True
        if self.rows is None:
            return False
        stop = item.get('stop')
        if isinstance(stop, dict) and stop.get('generation') == item['generation'] and stop.get('binding') == self.binding:
            structured = stop.get('gate') == 'structured' and self.structurally_stopped(item)
            current = structured and stop.get('until') == 0
            current = current or (isinstance(stop.get('until'), int) and self.now < stop['until'] <= self.now + 300)
            if current and stop.get('facts') == self.retry_facts():
                if stop.get('gate') in GATES and all(isinstance(stop.get(key), str) and 0 < len(stop[key].strip()) <= 2000 for key in ('reason', 'retry')):
                    return True
        return self.started(task, item)

    @staticmethod
    def structurally_stopped(item):
        if item.get('state') in ('done', 'missing'):
            return False
        facts = item['facts']
        return facts['held'] == 'yes' or any(value != 'done' for value in facts['dependencies'].values())

    def pending(self):
        return [{'task': task, 'generation': item['generation']} for task, item in self.book['candidates'].items()
                if not self.settled(task, item)]

    def handoffs(self):
        processed_raw = read(self.state / '.branch-outcomes-processed', '0\n').strip()
        if not processed_raw.isdigit():
            raise Refusal('invalid outcome processed cursor')
        processed = int(processed_raw)
        covered = set()
        previous = 0
        for row in outcome_rows(self.state / 'branch-outcomes.jsonl'):
            if not isinstance(row, dict):
                raise Refusal('invalid outcome handoff record')
            seq = row.get('seq')
            if not isinstance(seq, int) or seq != previous + 1:
                raise Refusal('invalid outcome handoff sequence')
            previous = seq
            review = row.get('readyReview')
            if seq <= processed or row.get('verdict') != 'captain' or not isinstance(review, dict) or review.get('binding') != self.binding:
                continue
            for candidate in review.get('candidates', []):
                covered.add((candidate['task'], candidate['generation']))
            if review.get('uncertainty'):
                covered.add(('uncertainty', digest(review['uncertainty'])))
        return covered

    def unresolved(self, actor):
        pending = self.pending()
        if self.book.get('uncertainty'):
            pending.append({'task': 'uncertainty', 'generation': digest(self.book['uncertainty'])})
        if pending and actor == 'branch':
            covered = self.handoffs()
            pending = [item for item in pending if (item['task'], item['generation']) not in covered]
        return pending

    def select(self, task, generation):
        item = self.book['candidates'].get(task)
        if item is None or item['generation'] != generation or self.rows is None:
            raise Refusal('stale or foreign candidate generation; run scan again')
        return item


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--data', required=True)
    parser.add_argument('--backend', required=True)
    parser.add_argument('--manual-lifecycle', action='store_true')
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('scan')
    commands.add_parser('needs-review')
    commands.add_parser('poll')
    report = commands.add_parser('report-check')
    report.add_argument('verdict', choices=('routine', 'captain'))
    guard = commands.add_parser('guard')
    guard.add_argument('actor', choices=('main', 'branch'))
    stop = commands.add_parser('stop')
    stop.add_argument('task')
    stop.add_argument('generation')
    stop.add_argument('--gate', required=True, choices=GATES)
    stop.add_argument('--reason', required=True)
    stop.add_argument('--retry', required=True)
    launch = commands.add_parser('launch')
    launch.add_argument('task')
    launch.add_argument('spawn_generation')
    args = parser.parse_args()
    if args.command == 'launch' and not launch_caller():
        raise Refusal('launch receipt requires the confirmed fm-spawn caller; use fm-spawn')
    if args.command == 'stop' and (os.environ.get('FM_TASK_ID') or os.environ.get('FM_SUPERVISION_ACTOR', 'main') not in ('main', 'branch')):
        raise Refusal('only the owning main or supervision branch may record a ready-work stop')
    with Review(args) as review:
        if args.command == 'poll':
            review.poll()
            return 0
        if args.command == 'launch':
            launch_generation = review.confirm_launch(args.task, args.spawn_generation)
        review.sync()
        if args.command == 'scan':
            print(json.dumps(review.book, sort_keys=True))
        elif args.command == 'needs-review':
            return 0 if review.unresolved('branch') else 1
        elif args.command == 'guard':
            pending = review.unresolved(args.actor)
            if pending:
                raise Refusal('unhandled ready review for ' + ', '.join(item['task'] for item in pending) + '; run bin/fm-ready-review.sh scan, then dispatch with fm-spawn or record a current stop; branch may report a captain handoff')
        elif args.command == 'report-check':
            pending = review.unresolved('branch')
            if pending and args.verdict != 'captain':
                raise Refusal('ready work has no processing proof/current stop; report captain to durably hand it to MAIN')
            payload = {'binding': review.binding, 'candidates': [item for item in pending if item['task'] != 'uncertainty']}
            if any(item['task'] == 'uncertainty' for item in pending):
                payload['uncertainty'] = review.book['uncertainty']
            print(json.dumps(payload, separators=(',', ':')))
        elif args.command == 'stop':
            item = review.select(args.task, args.generation)
            if not args.reason.strip() or not args.retry.strip() or len(args.reason) > 2000 or len(args.retry) > 2000:
                raise Refusal('stop needs a bounded concrete reason and retry condition')
            if args.gate == 'structured' and not review.structurally_stopped(item):
                raise Refusal('structured stop has no current hold or unresolved dependency')
            item['stop'] = {'binding': review.binding, 'generation': args.generation, 'gate': args.gate,
                            'reason': args.reason, 'retry': args.retry, 'facts': review.retry_facts(),
                            'until': 0 if args.gate == 'structured' else review.now + 300}
            review.save()
        elif args.command == 'launch':
            item = review.book['candidates'].get(args.task)
            if review.rows is None:
                if item is not None and 'confirmed_launch' not in item:
                    raise Refusal('graph unavailable and launch has no current candidate binding; inspect before acknowledging')
                message = ('confirmed launch retained while graph is unavailable' if item is not None
                           else 'graph unavailable; no tracked ready-work candidate to bind')
                print('ready review: ' + message + '; run scan before acknowledging', file=sys.stderr)
            if review.defer_manual_launch(args.task, args.spawn_generation, launch_generation):
                print('ready review: confirmed launch retained; manual backlog transition to In flight remains pending; run scan before acknowledging', file=sys.stderr)
                return 0
            if item is not None and review.rows is not None:
                meta = review.metadata(args.task)
                launch = item.get('launch')
                if (item['generation'] != launch_generation or item.get('state') != 'in_flight'
                        or meta['spawn_gen'] != args.spawn_generation or not isinstance(launch, dict)
                        or launch.get('binding') != review.binding or launch.get('spawn_gen') != args.spawn_generation):
                    raise Refusal('launch publication does not match current candidate incarnation')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (Refusal, OSError, ValueError, KeyError, TypeError) as error:
        # External command output and configuration values never enter errors.
        message = str(error) if isinstance(error, Refusal) else 'review state could not be validated; inspect the owning-home review ledger'
        print('ready review: ' + message, file=sys.stderr)
        sys.exit(2)
