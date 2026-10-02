# Reuse driver helpers without executing its scenario body.
import pathlib, os, json, shutil, subprocess
E=pathlib.Path('/home/art/.no-mistakes/evidence/01M3XNDH7V995J96HA86TEWX4D')
exec((E/'live-custody.py').read_text().split('writer=None')[0])
try:
    W.mkdir()
    for h in [P,H]: run([R/'bin/fm-lab-home.sh','create',h])
    (H/'bin').mkdir(); shutil.copyfile(R/'AGENTS.md',H/'AGENTS.md'); (H/'state/parent-route').mkdir(); (H/'data/.parent-route').mkdir()
    (P/'config/fleet-seats').write_text('{"pools":[{"name":"shared","capacity":1,"models":["pool-model-a"]}]}\n')
    for verb in ['launch','relaunch']:
        reset(); old='previous.'+verb; pending(old); original=state(old); op='candidate.'+verb; record=pending(op,old)
        x=host(verb,op,record,old); assert disposition(x)['disposition']=='prelaunch'; response(op,x)
        assert state(op)['lifecycle']=='released' and state(old)==original
        note(verb+' fresh candidate refuses without releasing pending predecessor',x,seats('show','ios').stdout+'\n'+probe())
    for verb in ['launch','relaunch']:
        for refusal in ['home','directories']:
            reset(); op='trace.'+verb+'.'+refusal; pending(op); f=receipt(op,verb,'dispatched'); before=f.read_bytes()
            if refusal=='home': (H/'.fm-secondmate-home').write_text('foreign\n')
            else: (H/'data/.parent-route').rmdir(); (H/'data/.parent-route').write_text('blocked')
            a=[R/'bin/fm-remote-secondmate-control.sh',verb,'ios','notaharness','pool-model-a','medium']
            if verb=='launch': a+=['herdr']
            trace=E/('exec-'+verb+'-'+refusal+'.log')
            x=run(['strace','-f','-e','trace=execve','-o',trace,*a,'--operation',op],H,'',False)
            assert x.returncode==1 and disposition(x)['disposition']=='unknown' and f.read_bytes()==before,x.stdout
            response(op,x); assert state(op)['lifecycle']=='reserved'
            import re
            launches=re.findall(r'execve\("([^"]+)"',trace.read_text())
            assert not any(pathlib.Path(a).name in ['tmux','herdr','claude','codex','fm-control.sh','fm-spawn.sh'] for a in launches),launches
            note(verb+' '+refusal+' system-call trace',x,'Actual execve trace shows no endpoint provider, control or spawn invocation; parent remains reserved. Evidence: '+trace.name)
            if refusal=='directories': (H/'data/.parent-route').unlink(); (H/'data/.parent-route').mkdir()
    # Exact original executable files, rather than extracted function bodies.
    b=W/'before'; (b/'bin').mkdir(parents=True)
    for p in (R/'bin').iterdir(): (b/'bin'/p.name).symlink_to(p)
    for name in ['fm-remote-secondmate-control.sh','fm-secondmate-liveness-lib.sh']:
        p=b/'bin'/name; p.unlink(); p.write_text(run(['git','show','5333e1bc2a211fea55db51d85611feb088ee8cee:bin/'+name]).stdout); p.chmod(0o700)
    for verb in ['launch','relaunch']:
        reset(); op='before.'+verb; pending(op); f=receipt(op,verb,'dispatched'); (H/'.fm-secondmate-home').write_text('foreign\n')
        a=[b/'bin/fm-remote-secondmate-control.sh',verb,'ios','notaharness','pool-model-a','medium']
        if verb=='launch': a+=['herdr']
        x=run([*a,'--operation',op],H,'',False)
        assert disposition(x)['disposition']=='prelaunch' and 'phase=prelaunch\n' in f.read_text(),x.stdout
        response(op,x); assert state(op)['lifecycle']=='released'
        note('pre-fix '+verb+' reproduces unsafe downgrade and parent release',x,f.read_text()+seats('show','ios').stdout)
    print('Additional CLI boundaries and original-head reproductions completed.',flush=True)
finally:
    shutil.rmtree(W,ignore_errors=True)
