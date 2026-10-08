from pathlib import Path
import os
source=Path('/Users/kesslerio/.no-mistakes/evidence/01M4E63C3Z7SP0Z1415AH2WBNA/live-startup-network.py').read_text()
exec(source[:source.index('\ntry:\n    scenario(')])

def allowed():
    h=home('owned-sweeps')
    (h/'state/.lock').write_text(str(os.getpid())+'\n')
    p=launch_internal(h,'owned','1',str(os.getpid()))
    print(p.communicate(timeout=12)[0],flush=True)
    assert p.returncode==0
    assert status(h)['locked']=='1' and status(h)['phases']=='probe,sweeps'
    assert 'NEEDS_GH_AUTH' in run(h,'report').stdout
    assert 'were skipped' not in read(h,'.startup-network.report')
    assert not (h/'state/.lock.acquire').exists()
    record(h)

def held_lease():
    h=home('held-lease')
    (h/'state/.lock').write_text(str(os.getpid())+'\n')
    holder=hold(h,'.lock.acquire')
    p=launch_internal(h,'lease','1',str(os.getpid()))
    print(p.communicate(timeout=12)[0],flush=True)
    assert p.returncode!=0
    out=run(h,'report').stdout
    assert 'did not run' in out and 'still held by pid '+str(holder.pid) in out
    assert 'NEEDS_GH_AUTH' not in out
    assert wake_count(h)==1
    release(holder)
    record(h)

def completed_publication():
    h=home('completed-publication')
    (h/'state/.lock').write_text(str(os.getpid())+'\n')
    p=launch_internal(h,'completed','1',str(os.getpid()))
    until(lambda: (h/'state/.lock.acquire').exists())
    holder=hold(h,'.startup-network.lock')
    print(p.communicate(timeout=12)[0],flush=True)
    assert p.returncode!=0
    out=run(h,'report').stdout
    assert 'NEEDS_GH_AUTH' in out
    assert 'still held by pid '+str(holder.pid) in out
    assert 'gh-auth' in out
    assert wake_count(h)==0
    release(holder)
    recover(h)
    assert wake_count(h)==1
    record(h)

try:
    scenario('The unchanged captured owner runs deferred sweeps under the acquisition lease',allowed)
    scenario('A held acquisition lease ends the worker without executing sweeps and reports the refusal',held_lease)
    scenario('Publication contention retains completed real probe findings and their matching timings for later recovery',completed_publication)
finally:
    for p in PROCS: release(p)
    shutil.rmtree(BASE)
    (EVID/'live-owned-scenarios.json').write_text(json.dumps(RESULTS,indent=2)+'\n')
    print('Disposable homes and owned processes cleaned up.',flush=True)
raise SystemExit(0 if all(r['result']=='pass' for r in RESULTS) else 1)
