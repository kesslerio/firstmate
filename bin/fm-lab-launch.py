#!/usr/bin/env python3
import fcntl
import json
import os
from pathlib import Path
import secrets
import signal
import stat
import subprocess
import sys
import tempfile
import time


def read_owned(path):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd) as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022 or info.st_nlink != 1:
            raise ValueError('unsafe lab launch record')
        return stream.read()


def context(root):
    info = root.stat()
    if root.resolve() != root or info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise ValueError('unsafe lab launch directory')
    text = read_owned(root / '.fm-live-lab')
    fields = {}
    for line in text.splitlines()[1:]:
        key, sep, value = line.partition('=')
        if sep:
            fields.setdefault(key, []).append(value)
    if not text.startswith('fm-live-lab v1\n') or fields.get('home') != [str(root / 'home')]:
        raise ValueError('foreign lab launch record')
    return fields


def lock_root(root):
    fd = os.open(root / '.fm-lab-launch.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or info.st_mode & 0o022:
        os.close(fd)
        raise ValueError('unsafe lab launch lock')
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    return fd


def started(pid):
    # Persisted process identities must survive a caller's timezone or locale.
    environment = dict(os.environ, LC_ALL='C', TZ='UTC')
    return ' '.join(subprocess.check_output(['ps', '-o', 'lstart=', '-p', str(pid)], text=True, env=environment).split())


def save(path, data):
    fd, temporary = tempfile.mkstemp(prefix='.anchor-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(data, stream)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def launch_records(root, fields, retirement_requests=None):
    for name in fields.get('anchor_record', []):
        if not name.startswith('.fm-lab-anchor-') or Path(name).name != name:
            raise ValueError('invalid lab launch binding')
        data = json.loads(read_owned(root / name))
        if data.get('schema') != 1 or data.get('root') != str(root) or data.get('nonce') != fields.get('nonce'):
            raise ValueError('foreign lab launch binding')
        pid = data['pid']
        if type(pid) is not int or pid <= 1 or type(data['group']) is not int or data['group'] <= 1 or type(data.get('child')) is not int or data['child'] <= 1:
            raise ValueError('incomplete lab launch binding')
        if data.get('retired') is True:
            yield name, data
            continue
        try:
            validate_owner(root, data)
        except (OSError, ValueError, subprocess.SubprocessError):
            request = retirement_requests.get(name) if retirement_requests is not None else None
            if not request:
                raise
            # A matching terminal acknowledgement remains authoritative when its owner exits during observation.
            terminal = json.loads(read_owned(root / name))
            current = context(root)
            if (not isinstance(terminal, dict) or terminal.get('retired') is not True
                    or terminal.get('retirement_error')
                    or terminal.get('retirement_request') != request['request']
                    or identity(terminal) != identity(data) or identity(terminal) != request['identity']
                    or current.get('nonce') != fields.get('nonce')
                    or name not in current.get('anchor_record', [])):
                raise
            data = terminal
        yield name, data


def validate_owner(root, data):
    pid = data['pid']
    if started(pid) != data['start'] or os.getpgid(pid) != data['group']:
        raise ValueError('stale lab launch binding')
    command = subprocess.check_output(['ps', '-o', 'args=', '-p', str(pid)], text=True)
    if str(Path(__file__).resolve()) not in command or str(root) not in command:
        raise ValueError('changed lab launch owner')


def anchors(root, fields):
    for _, data in launch_records(root, fields):
        if data.get('retired') is not True:
            print(str(data['pid']) + '\t' + data['start'])


def identity(data):
    return {key: data[key] for key in ('schema', 'root', 'nonce', 'pid', 'start', 'group', 'child', 'retirement_token')}


def request_retirement(root, fields, expected):
    records = [(name, data) for name, data in launch_records(root, fields) if data.get('retired') is not True]
    current = '\n'.join(str(data['pid']) + '\t' + data['start'] for _, data in records)
    if current != expected.strip():
        raise ValueError('changed lab launch retirement owners')
    requests = []
    for name, data in records:
        request = dict(record=name, identity=identity(data), request=secrets.token_hex(16))
        save(root / (name + '.retire'), request)
        requests.append(request)
    print(json.dumps(requests))


def retirement_status(root, fields, requests):
    records = dict(launch_records(root, fields, {request['record']: request for request in requests}))
    for request in requests:
        data = records[request['record']]
        if identity(data) != request['identity']:
            raise ValueError('changed lab launch retirement identity')
        acknowledged = data.get('retirement_request') == request['request']
        if acknowledged and data.get('retirement_error'):
            raise ValueError(data['retirement_error'])
        if data.get('retired') is True:
            if not acknowledged:
                raise ValueError('unacknowledged lab launch retirement')
        else:
            print(data['pid'])


def acknowledge_retirement(path, data, request, error=None, retired=False):
    result = dict(data, retirement_request=request)
    result.pop('retirement_error', None)
    result.pop('retired', None)
    if error:
        result['retirement_error'] = error
    if retired:
        result['retired'] = True
    try:
        save(path, result)
    except OSError as failure:
        result.pop('retired', None)
        result['retirement_error'] = 'launch retirement acknowledgement unavailable: ' + str(failure)
        try:
            save(path, result)
        except OSError:
            return data
    return result


def register(root, path, data):
    save(path, data)
    fd = os.open(root / '.fm-live-lab', os.O_WRONLY | os.O_APPEND | os.O_NOFOLLOW)
    try:
        os.write(fd, ('anchor_record=' + path.name + '\n').encode())
        os.fsync(fd)
    finally:
        os.close(fd)


def launch_environment(root, path, data):
    return dict(os.environ, FM_LAB_LAUNCH_ROOT=str(root), FM_LAB_LAUNCH_HELPER=str(Path(__file__).resolve()), FM_LAB_LAUNCH_RECORD=path.name,
                FM_LAB_LAUNCH_TOKEN=data['retirement_token'])


def detached(root, command):
    lock = lock_root(root)
    fields = context(root)
    if os.path.lexists(root / '.fm-lab-launch-closed') or fields.get('cleanup_started'):
        raise ValueError('lab launch is closed for cleanup')
    name = os.environ.get('FM_LAB_LAUNCH_RECORD', '')
    if name not in fields.get('anchor_record', []) or Path(name).name != name:
        raise ValueError('unregistered lab launch owner')
    owner = json.loads(read_owned(root / name))
    if (not isinstance(owner, dict) or owner.get('schema') != 1 or owner.get('root') != str(root) or owner.get('nonce') != fields.get('nonce')
            or owner.get('retired') is True or not command
            or not os.environ.get('FM_LAB_LAUNCH_TOKEN')
            or owner.get('retirement_token') != os.environ['FM_LAB_LAUNCH_TOKEN']):
        raise ValueError('foreign lab launch owner')
    validate_owner(root, owner)
    pid = os.getpid()
    if os.getpgrp() != pid:
        os.setpgid(0, 0)
    receive, send = os.pipe()
    guardian = os.fork()
    if guardian:
        os.close(send)
        os.close(lock)
        with os.fdopen(receive) as stream:
            binding = json.load(stream)
        os.execvpe(command[0], command, launch_environment(root, root / binding['record'], binding))
    os.close(receive)
    for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT, signal.SIGQUIT):
        signal.signal(signum, signal.SIG_IGN)
    path = root / ('.fm-lab-anchor-' + str(pid))
    data = dict(schema=1, root=str(root), nonce=fields['nonce'], pid=os.getpid(), group=pid,
                child=pid, start=started(os.getpid()), retirement_token=secrets.token_hex(16))
    try:
        register(root, path, data)
        try:
            os.write(send, json.dumps(dict(record=path.name, retirement_token=data['retirement_token'])).encode())
        except BrokenPipeError:
            pass
    finally:
        os.close(send)
        os.close(lock)
    return supervise(root, fields, path, data)


def launch(root, command):
    lock = lock_root(root)
    fields = context(root)
    if os.path.lexists(root / '.fm-lab-launch-closed') or fields.get('cleanup_started'):
        raise ValueError('lab launch is closed for cleanup')
    if not fields.get('nonce') or not command:
        raise ValueError('launch needs a named lab and command')
    for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT, signal.SIGQUIT):
        signal.signal(signum, signal.SIG_IGN)
    def restore():
        os.setpgid(0, 0)
        for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT, signal.SIGQUIT, signal.SIGUSR1):
            signal.signal(signum, signal.SIG_DFL)
    pid = os.getpid()
    path = root / ('.fm-lab-anchor-' + str(os.getppid()))
    data = dict(schema=1, root=str(root), nonce=fields['nonce'], pid=pid, group=pid,
                start=started(pid), retirement_token=secrets.token_hex(16))
    register(root, path, data)
    receive, send = os.pipe()
    try:
        child = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), 'execute', str(receive), *command],
                                 preexec_fn=restore, pass_fds=(receive,), env=launch_environment(root, path, data))
        os.close(receive)
        receive = None
        os.setpgid(0, child.pid)
        data['group'] = child.pid
        data['child'] = child.pid
        if os.isatty(0):
            previous = signal.signal(signal.SIGTTOU, signal.SIG_IGN)
            try:
                os.tcsetpgrp(0, child.pid)
            finally:
                signal.signal(signal.SIGTTOU, previous)
        save(path, data)
        try:
            os.write(send, b'1')
        except BrokenPipeError:
            pass
    finally:
        if receive is not None:
            os.close(receive)
        os.close(send)
        os.close(lock)
    return supervise(root, fields, path, data, child)


def supervise(root, fields, path, data, child=None):
    pid = data['pid']
    consumed_requests = set()
    while True:
        if child is not None:
            child.poll()
        try:
            request = json.loads(read_owned(root / (path.name + '.retire')))
            current = json.loads(read_owned(path))
            if (not isinstance(request, dict) or not isinstance(current, dict)
                    or request.get('record') != path.name or request.get('identity') != identity(data)
                    or identity(current) != identity(data) or context(root).get('nonce') != fields['nonce']
                    or not isinstance(request.get('request'), str) or len(request['request']) != 32):
                raise ValueError('foreign lab launch retirement request')
        except (OSError, ValueError, KeyError, TypeError):
            request = None
        if request and request['request'] in consumed_requests:
            if data.get('retirement_request') != request['request']:
                data = acknowledge_retirement(path, data, request['request'], 'replayed lab launch retirement request')
        elif request and (child is None or child.returncode is not None):
            error = None
            try:
                validate_owner(root, data)
                observer = subprocess.Popen(['ps', '-axo', 'pid=,pgid=,stat='], stdout=subprocess.PIPE, text=True)
                observed, _ = observer.communicate()
                if observer.returncode != 0:
                    raise ValueError('launch retirement observation failed')
                peers = [row.split() for row in observed.splitlines()]
                if any(len(row) != 3 or not row[0].isdigit() or not row[1].isdigit() for row in peers) or not any(row[0] == str(pid) and row[1] == str(data['group']) for row in peers):
                    raise ValueError('launch retirement observation incomplete')
                if any(row[1] == str(data['group']) and row[0] not in (str(pid), str(observer.pid)) and not row[2].startswith('Z') for row in peers):
                    time.sleep(.1)
                    continue
            except (OSError, ValueError, subprocess.SubprocessError) as failure:
                error = 'launch retirement observation unavailable: ' + str(failure)
            consumed_requests.add(request['request'])
            data = acknowledge_retirement(path, data, request['request'], error, retired=error is None)
            if data.get('retired') is True:
                return child.returncode if child is not None else 0
        time.sleep(.1)


try:
    mode, directory = sys.argv[1:3]
    if mode == 'execute':
        fd = int(directory)
        ready = os.read(fd, 1)
        os.close(fd)
        if ready != b'1':
            sys.exit(1)
        os.execvp(sys.argv[3], sys.argv[3:])
    root = Path(directory)
    fields = context(root)
    if mode == 'anchors':
        anchors(root, fields)
    elif mode == 'request-retirement':
        request_retirement(root, fields, sys.stdin.read())
    elif mode == 'retirement-status':
        retirement_status(root, fields, json.load(sys.stdin))
    elif mode == 'seal':
        lock = lock_root(root)
        try:
            fields = context(root)
            anchors(root, fields)
            fd = os.open(root / '.fm-lab-launch-closed', os.O_CREAT | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
            os.close(fd)
        finally:
            os.close(lock)
    elif mode == 'launch':
        guardian = os.fork()
        if guardian:
            _, status = os.waitpid(guardian, 0)
            sys.exit(os.waitstatus_to_exitcode(status))
        sys.exit(launch(root, sys.argv[3:]))
    elif mode == 'detached':
        sys.exit(detached(root, sys.argv[3:]))
    else:
        raise ValueError('invalid lab launch operation')
except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
    print('lab launch ownership unavailable: ' + str(error), file=sys.stderr)
    sys.exit(1)
