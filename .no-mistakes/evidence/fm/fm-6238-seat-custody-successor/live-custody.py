import os, pathlib, subprocess, json, shutil, time, hashlib
R=pathlib.Path.cwd(); E=pathlib.Path('/home/art/.no-mistakes/evidence/01M3XNDH7V995J96HA86TEWX4D'); W=R/'.nm-live'; P=W/'parent'; H=W/'host'
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k in ['TASKS_AXI_FILE','TASKS_AXI_BACKEND']: env.pop(k,None)
env['TMPDIR']=str(R/'.nm-test-tmp')
def run(args, home=None, data=None, check=True, extra=None):
    v=env.copy()
    if home: v['FM_HOME']=str(home)
    if extra: v.update(extra)
    x=subprocess.run([str(a) for a in args],input=data,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env=v,timeout=90)
    if check and x.returncode: raise RuntimeError(f'{args}: {x.returncode}\n{x.stdout}')
    return x
def seats(*args,check=True): return run([R/'bin/fm-fleet-seats.sh',*args],P,check=check)
def host(verb,op,data='',prev=None):
    a=[R/'bin/fm-remote-secondmate-control.sh',verb,'ios','notaharness','pool-model-a','medium']
    if verb=='launch': a+=['herdr']
    a+=['--operation',op]
    if prev: a+=['--previous',prev]
    return run(a,H,data,False)
def disposition(x):
    replies=[json.loads(s.split('=',1)[1]) for s in x.stdout.splitlines() if s.startswith('seat_disposition=')]
    assert len(replies)==1,x.stdout
    return replies[0]
def response(op,x):
    d=disposition(x); assert d['operation']==op and d['requested_generation']==op
    f=W/'response.json'; f.write_text(json.dumps(d)); f.chmod(0o600)
    return seats('reconcile-remote','ios','--generation',op,'--response-file',f,check=False)
def state(op):
    return next(i for i in json.loads(seats('show','ios').stdout)['incarnations'] if i['generation']==op)
def reset():
    shutil.rmtree(P/'state/fleet-seats',ignore_errors=True)
    for f in (H/'state/parent-route').iterdir():
        if f.is_file(): f.unlink()
    (H/'.fm-secondmate-home').write_text('ios\n')
def pending(op,prev=None):
    a=['reserve','ios','--generation',op,'--kind','secondmate','--harness','pi','--model','pool-model-a','--holder-pid',str(os.getpid())]
    if prev: a+=['--previous-generation',prev]
    seats(*a)
    route=W/'route.json'; route.write_text(json.dumps(dict(placement='remote',backend='herdr',target=None,home=str(H),host='disposable-host',remote_root=str(R),operation=op))); route.chmod(0o600)
    seats('dispatch','ios','--generation',op,'--route-file',route)
    return seats('show','ios').stdout
def receipt(op,verb,phase):
    f=H/'state/parent-route'/f'ios.seat-operation.{op}'
    f.write_text(f'schema=fm-remote-seat-receipt.v1\noperation={op}\nverb={verb}\nrequested_generation={op}\nprevious_generation=-\nphase={phase}\nroute_backend=herdr\nroute_target=fm-lab-custody:w1:p1\n')
    return f
def probe():
    x=seats('reserve','probe','--generation','probe1','--harness','pi','--model','pool-model-a','--holder-pid',str(os.getpid()),check=False)
    assert x.returncode==4,x.stdout
    return x.stdout.strip()
def note(title,x,other):
    print('\nSCENARIO '+title,flush=True); print(x.stdout.rstrip(),flush=True); print(other,flush=True)
writer=None
try:
    W.mkdir()
    for h in [P,H]: run([R/'bin/fm-lab-home.sh','create',h])
    (H/'bin').mkdir(); shutil.copyfile(R/'AGENTS.md',H/'AGENTS.md'); (H/'state/parent-route').mkdir(); (H/'data/.parent-route').mkdir()
    (P/'config/fleet-seats').write_text('{"pools":[{"name":"shared","capacity":1,"models":["pool-model-a"]}]}\n')
    for verb in ['launch','relaunch']:
        for phase in ['received','dispatched','started','prelaunch','dead-after-start','cancelled']:
            for refusal in ['home','directories']:
                reset(); op=f'live.{verb}.{phase.replace("-",".")}.{refusal}'; pending(op); f=receipt(op,verb,phase); before=f.read_bytes()
                meta=H/'state/parent-route/ios.meta'; meta.write_text('spawn_gen=original\nbackend=herdr\nwindow=fm-lab-custody:w1:p1\n')
                journal=H/'state/parent-route/ios.control-relaunch'; journal.write_text('v1\nphase=launching\nseat_operation=original\n')
                snapshots={p:p.read_bytes() for p in [meta,journal]}
                if refusal=='home': (H/'.fm-secondmate-home').write_text('foreign\n')
                else: (H/'data/.parent-route').rmdir(); (H/'data/.parent-route').write_text('blocked\n')
                x=host(verb,op); assert x.returncode==1 and disposition(x)['disposition']=='unknown',x.stdout
                assert before==f.read_bytes() and all(p.read_bytes()==b for p,b in snapshots.items())
                response(op,x); assert state(op)['lifecycle']=='reserved'
                denied=probe()
                note(f'{verb} retained {phase}, refused {refusal}',x,f'receipt sha256 unchanged={hashlib.sha256(before).hexdigest()}; metadata and journal unchanged; parent={state(op)["lifecycle"]}\n{denied}')
                if refusal=='directories': (H/'data/.parent-route').unlink(); (H/'data/.parent-route').mkdir()
        reset(); op=f'fresh.{verb}'; record=pending(op); x=host(verb,op,record)
        assert x.returncode==1 and disposition(x)['disposition']=='prelaunch',x.stdout
        f=H/'state/parent-route'/f'ios.seat-operation.{op}'; reservation=H/'state/parent-route'/f'ios.seat-reservation.{op}'
        saved=(f.read_bytes(),reservation.read_bytes()); response(op,x); assert state(op)['lifecycle']=='released'
        note(f'{verb} genuinely fresh refusal',x,seats('show','ios').stdout)
        y=host(verb,op); assert y.returncode==1 and disposition(y)['disposition']=='prelaunch'; assert saved==(f.read_bytes(),reservation.read_bytes())
        note(f'{verb} same-token settled replay',y,'receipt and immutable reservation byte-for-byte unchanged')
        for damage in ['missing','foreign','malformed']:
            reset(); op=f'damaged.{verb}.{damage}'; record=pending(op); f=receipt(op,verb,'received')
            reservation=H/'state/parent-route'/f'ios.seat-reservation.{op}'; reservation.write_text(record); original=reservation.read_bytes()
            if damage=='missing': f.unlink(); before=None
            else:
                with f.open('a') as fd: fd.write('operation=foreign\n' if damage=='foreign' else 'phase=started\n')
                before=f.read_bytes()
            x=host(verb,op); assert x.returncode==1 and disposition(x)['disposition']=='unknown',x.stdout
            assert (not f.exists() if before is None else f.read_bytes()==before); assert reservation.read_bytes()==original
            response(op,x); assert state(op)['lifecycle']=='reserved'; denied=probe()
            note(f'{verb} {damage} evidence',x,f'parent remains reserved; receipt never reopened or rewritten; immutable reservation unchanged\n{denied}')
    reset(); op='live.barrier'; pending(op); f=receipt(op,'launch','received'); before=f.read_bytes(); shim=W/'instrumentation'; shim.mkdir(); realcp=shutil.which('cp')
    (shim/'cp').write_text('#!/usr/bin/env bash\n'+repr(realcp)+' "$@" || exit $?\n: > "$BARRIER_READY"\nwhile [ ! -e "$BARRIER_RELEASE" ]; do sleep 0.02; done\n'); (shim/'cp').chmod(0o700)
    owner='''set -eu
. "$ROOT/bin/fm-secondmate-liveness-lib.sh"
fm_supervisor_lifecycle_acquire "$HOST_HOME/state/parent-route" ios 0
trap 'fm_supervisor_lifecycle_release "$HOST_HOME/state/parent-route" ios' EXIT
printf '%s\\n' "$FM_SUPERVISOR_LIFECYCLE_CARRIER" > "$CARRIER_FILE"
fm_remote_seat_receipt_update "$RECEIPT" "$OP" "$OP" phase=dispatched route_backend=herdr route_target=fm-lab-custody:w1:p1
'''
    ownerenv=env|dict(ROOT=str(R),HOST_HOME=str(H),RECEIPT=str(f),OP=op,PATH=str(shim)+':'+env['PATH'],BARRIER_READY=str(W/'ready'),BARRIER_RELEASE=str(W/'release'),CARRIER_FILE=str(W/'carrier'))
    writerlog=(E/'live-owner.log').open('w'); writer=subprocess.Popen(['bash','-c',owner],env=ownerenv,stdout=writerlog,stderr=subprocess.STDOUT)
    deadline=time.monotonic()+10
    while not (W/'ready').exists() and time.monotonic()<deadline: time.sleep(.02)
    assert (W/'ready').exists(),'writer barrier unavailable'
    carrier=(W/'carrier').read_text().strip()
    for verb in ['launch','relaunch']:
        (H/'.fm-secondmate-home').write_text('foreign\n'); x=host(verb,op)
        assert disposition(x)['disposition']=='unknown' and f.read_bytes()==before
        response(op,x); assert state(op)['lifecycle']=='reserved'
        note(f'{verb} early retry during owner snapshot barrier',x,'receipt unchanged; parent reserved; '+probe())
    (H/'.fm-secondmate-home').write_text('ios\n')
    for c in ['',carrier,carrier.rsplit('|',1)[0]+'|stale']:
        x=run(['bash','-c','. "$ROOT/bin/fm-secondmate-liveness-lib.sh"; fm_remote_seat_receipt_update "$RECEIPT" "$OP" "$OP" phase=prelaunch'],check=False,extra=dict(ROOT=str(R),RECEIPT=str(f),OP=op,FM_SUPERVISOR_LIFECYCLE_CARRIER=c))
        assert x.returncode and f.read_bytes()==before
        note('reject missing, unrelated, or stale writer carrier',x,'receipt byte-for-byte unchanged')
    # Refusal uses the real mutex wait; run both callers concurrently.
    for verb in ['launch','relaunch']:
        x=host(verb,op); assert x.returncode==1 and disposition(x)['disposition']=='unknown' and 'another lifecycle episode' in x.stdout
        response(op,x); assert state(op)['lifecycle']=='reserved'
        note(f'{verb} busy lifecycle mutex',x,'parent remains reserved; '+probe())
    (W/'release').touch(); assert writer.wait(timeout=10)==0; writer=None; writerlog.close()
    assert 'phase=dispatched\n' in f.read_text() and 'route_target=fm-lab-custody:w1:p1\n' in f.read_text()
    print('\nOWNER RECEIPT AFTER BARRIER\n'+f.read_text(),flush=True)
    (E/'live-dispatched-receipt.txt').write_bytes(f.read_bytes())
    allowed='''set -eu
. "$ROOT/bin/fm-secondmate-liveness-lib.sh"
fm_supervisor_lifecycle_acquire "$HOST_HOME/state/parent-route" ios 0
trap 'fm_supervisor_lifecycle_release "$HOST_HOME/state/parent-route" ios' EXIT
if fm_remote_seat_receipt_update "$RECEIPT" "$OP" "$OP" phase=prelaunch; then exit 8; fi
bash -c '. "$ROOT/bin/fm-secondmate-liveness-lib.sh"; fm_remote_seat_receipt_update "$RECEIPT" "$OP" "$OP" phase=started actual_generation="$OP"'
'''
    run(['bash','-c',allowed],extra=dict(ROOT=str(R),HOST_HOME=str(H),RECEIPT=str(f),OP=op)); assert 'phase=started\n' in f.read_text()
    print('\nVERIFIED DESCENDANT UPDATE\n'+f.read_text(),flush=True)
    print('All direct product custody scenarios passed.',flush=True)
finally:
    if writer:
        (W/'release').touch()
        try: writer.wait(timeout=10)
        except subprocess.TimeoutExpired: writer.terminate(); writer.wait(timeout=5)
    shutil.rmtree(W,ignore_errors=True)
