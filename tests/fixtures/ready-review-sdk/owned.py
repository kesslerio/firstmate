"""One fixture owner and bounded pipe capture; pidfd signals only."""
import ctypes
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import time
import uuid

def identity(pid):
    try:
        fields=Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()
        return dict(pid=pid,start=fields[19],ppid=int(fields[1]),state=fields[0])
    except (FileNotFoundError,ProcessLookupError):return None

def signal_identity(record,sig,signals):
    descriptor=None
    try:
        descriptor=os.pidfd_open(record['pid'],0)
        current=identity(record['pid'])
        if not current or current['start']!=record['start'] or current['state']=='Z':return
        signal.pidfd_send_signal(descriptor,sig,None,0)
        signals.append(dict(pid=record['pid'],start=record['start'],signal=int(sig),transport='pidfd'))
    except ProcessLookupError:pass
    finally:
        if descriptor is not None:os.close(descriptor)

class Owner:
    def __init__(self):
        if not callable(getattr(os,'pidfd_open',None)) or not callable(getattr(signal,'pidfd_send_signal',None)):
            raise RuntimeError('Identity-bound pidfd signals required before fixture launch')
        if ctypes.CDLL(None,use_errno=True).prctl(36,1,0,0,0):raise OSError(ctypes.get_errno(),'PR_SET_CHILD_SUBREAPER')
        self.self_identity=identity(os.getpid());self.direct={};self.observed={};self.reaped=[];self.signals=[];self.captures=[]

    def register(self,process):
        record=identity(process.pid)
        if not record or record['ppid']!=os.getpid():raise RuntimeError('Direct child identity not established')
        self.direct[process.pid]=(record['start'],process)
        self.observed[(record['pid'],record['start'])]=record
        return record

    def cycle(self):
        if getattr(self,'evidence',None) and not getattr(self,'cleaning',False):
            total=0
            for path in self.evidence.rglob('*'):
                try:
                    if path.is_file() and not path.is_symlink():total+=path.stat().st_size
                except FileNotFoundError:pass
            if total>128*1024*1024:raise RuntimeError('Owned evidence aggregate byte cap exceeded')
        records=[]
        for path in Path('/proc').iterdir():
            if path.name.isdigit():
                record=identity(int(path.name))
                if record:records.append(record)
        live={r['pid']:r for r in records if (r['pid'],r['start']) in self.observed}
        live[os.getpid()]=self.self_identity
        changed=True
        while changed:
            changed=False
            for record in records:
                key=(record['pid'],record['start'])
                if record['pid']==os.getpid() or record['pid'] in live:continue
                parent=live.get(record['ppid'])
                if not parent:continue
                first_parent=identity(parent['pid']);child=identity(record['pid']);final_parent=identity(parent['pid'])
                if (not first_parent or first_parent['start']!=parent['start'] or not final_parent or
                    final_parent['start']!=parent['start'] or not child or child['start']!=record['start'] or child['ppid']!=parent['pid']):continue
                self.observed[key]=child;live[child['pid']]=child;changed=True
        for record in list(live.values()):
            if record['pid']==os.getpid():continue
            direct=self.direct.get(record['pid'])
            if record['ppid']!=os.getpid() or record['state']!='Z' or (direct and direct[0]==record['start']):continue
            current=identity(record['pid'])
            if not current or current['start']!=record['start'] or current['ppid']!=os.getpid() or current['state']!='Z':continue
            try:pid,status=os.waitpid(record['pid'],os.WNOHANG)
            except ChildProcessError:continue
            if pid:self.reaped.append(dict(**record,wait_status=status))

    def survivors(self):
        self.cycle();result=[]
        for record in self.observed.values():
            current=identity(record['pid'])
            if current and current['start']==record['start']:result.append(current)
        return result

    def cleanup(self,grace=5):
        self.cleaning=True
        failures=[]
        for sig in (signal.SIGTERM,signal.SIGKILL):
            deadline=time.monotonic()+grace;sent=set()
            while True:
                for _start,process in self.direct.values():process.poll()
                for record in self.survivors():
                    key=(record['pid'],record['start'])
                    if record['state']=='Z' or key in sent:continue
                    try:signal_identity(record,sig,self.signals);sent.add(key)
                    except BaseException as error:failures.append(repr(error))
                if not self.survivors() or time.monotonic()>=deadline:break
                time.sleep(.02)
        for _start,process in self.direct.values():
            try:process.wait(timeout=2)
            except BaseException as error:failures.append(repr(error))
        self.cycle();return failures

    def receipt(self):
        return dict(controller=self.self_identity,observed=list(self.observed.values()),adopted_reaped=self.reaped,
                    signals=self.signals,captures=self.captures,survivors=self.survivors())

def capture(argv,env,cwd,directory,label,seconds,owner=None,limit=16*1024*1024):
    """Pre-write stream byte caps, bounded reads, true pipe EOF, one Popen exit owner."""
    prefix=Path(directory)/(label+'-'+uuid.uuid4().hex)
    paths=[Path(str(prefix)+suffix) for suffix in ('.stdout','.stderr')]
    process=None;selector=selectors.DefaultSelector();record=None;failure=None;complete=False
    buffers=[bytearray(),bytearray()];signals=[];start=time.monotonic();streams=[]
    try:
        for path in paths:streams.append(path.open('xb'))
        process=subprocess.Popen([str(arg) for arg in argv],env=env,cwd=cwd,stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=True)
        record=owner.register(process) if owner else identity(process.pid)
        if not record:raise RuntimeError('Direct capture identity missing')
        selector.register(process.stdout,selectors.EVENT_READ,0);selector.register(process.stderr,selectors.EVENT_READ,1)
        next_cycle=start
        while True:
            now=time.monotonic()
            if owner and now>=next_cycle:owner.cycle();next_cycle=now+.05
            for key,_mask in selector.select(.02):
                chunk=os.read(key.fileobj.fileno(),65536)
                if not chunk:selector.unregister(key.fileobj);continue
                index=key.data
                if len(chunk)>limit-len(buffers[index]):raise RuntimeError('Pre-write output byte cap exceeded')
                if streams[index].write(chunk)!=len(chunk):raise RuntimeError('Output short write')
                buffers[index].extend(chunk)
            if process.poll() is not None and not selector.get_map():complete=True;break
            if time.monotonic()-start>=seconds:raise TimeoutError('Owned capture deadline exceeded')
    except BaseException as error:failure=error
    finally:
        selector.close()
        if process and process.poll() is None and record:
            for sig in (signal.SIGTERM,signal.SIGKILL):
                try:signal_identity(record,sig,signals);process.wait(timeout=2)
                except (ProcessLookupError,subprocess.TimeoutExpired):pass
                except BaseException as error:
                    if failure is None:failure=error
                if process.poll() is not None:break
        if process:
            process.stdout.close();process.stderr.close()
        for stream in streams:stream.close()
        receipt=dict(argv=[str(arg) for arg in argv],identity=record,exit_code=process.returncode if process else None,
                     output_complete=complete,bytes=[len(value) for value in buffers],per_stream_cap=limit,
                     logs=[str(path) for path in paths],signals=signals,error=repr(failure) if failure else None)
        if owner:owner.captures.append(receipt)
        Path(str(prefix)+'.json').write_text(json.dumps(receipt,indent=2)+'\n')
    if failure:raise failure
    if not complete:raise RuntimeError('Owned output pipes did not complete')
    return receipt,tuple(bytes(value).decode('utf8',errors='replace') for value in buffers)
