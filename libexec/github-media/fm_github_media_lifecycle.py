"""Private Linux command lifetime for fm-github-media-state, not a command gateway.

An ephemeral subreaper inherits the target lease and watches a parent-only pipe.
It kills and reaps its own children (including adopted, detached descendants)
before recording stopped. No restart ever signals a recorded numeric PID.
Missing stopped evidence leaves the durable operation held, even after reboot.
"""
import base64
import ctypes
import os
from pathlib import Path
import re
import selectors
import signal
import subprocess
import time
import uuid


class Lifetime:
    def __init__(self, directory, lease, write, read, require):
        self.directory, self.lease = directory, lease
        self.write, self.read, self.require = write, read, require
        require(os.name == 'posix' and Path('/proc/self/task').is_dir() and
                hasattr(os, 'pidfd_open') and hasattr(signal, 'pidfd_send_signal'),
                'Linux subreaper/pidfd lifecycle unavailable; publication held')

    def settled(self):
        for path in self.directory.glob('command-*.json'):
            record = self.read(path, True)
            self.require(isinstance(record, dict) and record.get('state') == 'stopped',
                         'uncertain command ownership; no replacement or PID-based takeover')
            required = {'schema', 'id', 'phase', 'state', 'guardian', 'reason', 'returncode', 'output', 'descendants_reaped'}
            guardian = record.get('guardian')
            self.require(type(record.get('schema')) is int and record['schema'] == 1 and
                         isinstance(record.get('id'), str) and
                         re.fullmatch(r'[0-9a-f]{32}', record['id']) is not None and
                         path.name == 'command-' + record['id'] + '.json' and
                         record.get('phase') in ('read', 'attach', 'body-edit', 'hygiene', 'runtime'),
                         'malformed command ownership receipt; no replacement')
            if guardian is None:
                self.require(set(record) == required | {'child_started'} and
                             record['child_started'] is False and record['reason'] == 'spawn-failed' and
                             record['returncode'] is None and record['output'] == '' and
                             record['descendants_reaped'] is True,
                             'malformed no-child ownership receipt; no replacement')
                continue
            self.require(set(record) in (required, required | {'child_pid'}) and
                         record['descendants_reaped'] is True and
                         record['reason'] in ('exited', 'deadline', 'owner-lost', 'output-limit', 'spawn-failed') and
                         (record['returncode'] is None or type(record['returncode']) is int) and
                         isinstance(guardian, dict) and set(guardian) == {'pid', 'boot', 'start'} and
                         type(guardian['pid']) is int and guardian['pid'] > 0 and
                         isinstance(guardian['boot'], str) and re.fullmatch(r'[0-9a-f-]{36}', guardian['boot']) and
                         isinstance(guardian['start'], str) and guardian['start'].isdigit() and
                         isinstance(record['output'], str),
                         'malformed command ownership receipt; no replacement')
            base64.b64decode(record['output'], validate=True)

    def run(self, argv, env, phase, timeout=30, command_id=None):
        self.settled()
        if env.get('FM_TEST_SEAM') == '1' and phase in ('attach', 'body-edit') and env.get('FM_GITHUB_MEDIA_TEST_TIMEOUT'):
            timeout = float(env['FM_GITHUB_MEDIA_TEST_TIMEOUT'])
            self.require(.5 <= timeout <= 120, 'invalid synthetic deadline')
        command_id = command_id or uuid.uuid4().hex
        path = self.directory / ('command-' + command_id + '.json')
        self.require(not path.exists(), 'command identity already used; no replay')
        record = dict(schema=1, id=command_id, phase=phase, state='starting')
        self.write(path, record)
        reader = writer = None
        try:
            reader, writer = os.pipe()
            pid = os.fork()
        except OSError:
            # Both failures precede creation of a child. Close only this call's
            # descriptors; never reset an interrupted or uncertain starting.
            for fd in (reader, writer):
                if fd is not None:
                    os.close(fd)
            record.update(state='stopped', guardian=None, child_started=False,
                          reason='spawn-failed', returncode=None, output='', descendants_reaped=True)
            self.write(path, record)
            self.settled()
            return record
        if pid == 0:
            os.close(writer)
            # Do not keep the caller's stdout/stderr pipes open after its death.
            null = os.open(os.devnull, os.O_RDWR)
            for fd in (0, 1, 2):
                os.dup2(null, fd)
            os.close(null)
            try:
                os.setsid()
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                signal.signal(signal.SIGINT, signal.SIG_IGN)
                self.guard(argv, env, reader, path, record, timeout)
            except BaseException:
                # A missing terminal record is a permanent refusal, not a
                # license to guess whether an orphaned command is still live.
                os._exit(1)
            os._exit(0)
        os.close(reader)
        try:
            os.waitpid(pid, 0)
        finally:
            os.close(writer)
            # On handled interruption, EOF requests cleanup. Wait for this
            # exact guardian; SIGKILL needs no handler because EOF still fires.
            old = {s: signal.signal(s, signal.SIG_IGN) for s in (signal.SIGTERM, signal.SIGINT)}
            try:
                try:
                    os.waitpid(pid, 0)
                except ChildProcessError:
                    pass
            finally:
                for s, handler in old.items():
                    signal.signal(s, handler)
        result = self.read(path, True)
        self.require(result.get('state') == 'stopped',
                     'uncertain command ownership; operation held for operator reconciliation')
        self.settled()
        return result

    def guard(self, argv, env, reader, path, record, timeout):
        # PR_SET_CHILD_SUBREAPER makes daemonized grandchildren our children
        # when their immediate parent dies. Direct children cannot have their
        # PIDs reused until we reap them; pidfds also bind each signal exactly.
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.prctl(36, 1, 0, 0, 0) != 0:
            raise OSError('subreaper unavailable')
        record.update(state='running', guardian=dict(pid=os.getpid(),
                      boot=Path('/proc/sys/kernel/random/boot_id').read_text().strip(),
                      start=Path('/proc/self/stat').read_text().rsplit(')', 1)[1].split()[19]))
        self.write(path, record)
        proc = None
        output = bytearray()
        reason, code = 'exited', None
        try:
            # Parent may already have died before fork/spawn completed.
            with selectors.DefaultSelector() as sel:
                sel.register(reader, selectors.EVENT_READ)
                if sel.select(0):
                    reason = 'owner-lost'
                else:
                    proc = subprocess.Popen(argv, env=env, cwd=self.directory,
                                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                            stderr=subprocess.DEVNULL, start_new_session=True,
                                            pass_fds=(self.lease,))
                    record['child_pid'] = proc.pid
                    self.write(path, record)
                    sel.register(proc.stdout, selectors.EVENT_READ)
                    deadline = time.monotonic() + timeout
                    while proc.poll() is None:
                        if time.monotonic() >= deadline:
                            reason = 'deadline'
                            break
                        for key, _ in sel.select(min(.1, max(0, deadline-time.monotonic()))):
                            if key.fileobj == reader:
                                reason = 'owner-lost'
                                break
                            chunk = os.read(proc.stdout.fileno(), 65536)
                            output.extend(chunk)
                            if not chunk:
                                sel.unregister(proc.stdout)
                            if len(output) > 2 * 1024 * 1024:
                                reason = 'output-limit'
                                break
                        if reason != 'exited':
                            break
                    code = proc.poll()
        except OSError:
            reason = 'spawn-failed'
        finally:
            # Never signal a saved PGID: an already-reaped leader permits
            # reuse. Kill only our currently owned children with pidfds, then
            # reap/adopt the next generation until the kernel proves ECHILD.
            deadline = time.monotonic() + 5
            while True:
                children = Path('/proc/self/task/' + str(os.getpid()) + '/children').read_text().split()
                for child in children:
                    try:
                        fd = os.pidfd_open(int(child))
                        try:
                            signal.pidfd_send_signal(fd, signal.SIGKILL)
                        finally:
                            os.close(fd)
                    except ProcessLookupError:
                        pass
                try:
                    pid, status = os.waitpid(-1, os.WNOHANG)
                    if proc is not None and pid == proc.pid and code is None:
                        code = os.waitstatus_to_exitcode(status)
                        proc.returncode = code
                except ChildProcessError:
                    break
                if time.monotonic() >= deadline:
                    raise OSError('descendant termination unproved')
                if pid == 0:
                    time.sleep(.01)
            if proc is not None:
                output.extend(proc.stdout.read(2 * 1024 * 1024 + 1 - min(len(output), 2 * 1024 * 1024)))
                proc.stdout.close()
            os.close(reader)
        if len(output) > 2 * 1024 * 1024:
            reason, output = 'output-limit', bytearray()
        record.update(state='stopped', reason=reason, returncode=code, descendants_reaped=True,
                      output=base64.b64encode(output).decode())
        self.write(path, record)
