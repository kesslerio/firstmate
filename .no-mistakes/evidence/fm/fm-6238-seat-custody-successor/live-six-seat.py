import pathlib, shutil, os
E=pathlib.Path('/home/art/.no-mistakes/evidence/01M3XNDH7V995J96HA86TEWX4D')
exec((E/'live-custody.py').read_text().split('writer=None')[0])
try:
    W.mkdir()
    for h in [P,H]: run([R/'bin/fm-lab-home.sh','create',h])
    (H/'bin').mkdir(); shutil.copyfile(R/'AGENTS.md',H/'AGENTS.md'); (H/'state/parent-route').mkdir(); (H/'data/.parent-route').mkdir()
    (P/'config/fleet-seats').write_text('{"pools":[{"name":"shared","capacity":6,"models":["pool-model-a"]}]}\n')
    for verb in ['launch','relaunch']:
        reset()
        for n in range(5): seats('reserve','peer'+str(n),'--generation','peer'+str(n),'--harness','pi','--model','pool-model-a','--holder-pid',str(os.getpid()))
        op='six.'+verb; pending(op); f=receipt(op,verb,'dispatched'); before=f.read_bytes(); (H/'.fm-secondmate-home').write_text('foreign\n')
        x=host(verb,op); assert disposition(x)['disposition']=='unknown' and f.read_bytes()==before
        response(op,x); assert state(op)['lifecycle']=='reserved'; denied=probe(); assert '(6 of 6 seats held)' in denied
        note(verb+' invalid same-token retry at six-seat capacity',x,'original dispatched receipt byte-for-byte unchanged; parent pending generation still reserved\n'+denied)
    print('Six-seat capacity remains enforced after both early refusal paths.',flush=True)
finally: shutil.rmtree(W,ignore_errors=True)
