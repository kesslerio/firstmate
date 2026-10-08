import hashlib,json,os,pathlib,pwd,shlex,shutil,signal,socket,subprocess,time
ROOT=pathlib.Path.cwd(); EV=pathlib.Path('/Users/kesslerio/.no-mistakes/evidence/01M4C86PSDNBECPTMSZ1YVFF8Q')
BASE=ROOT/'.test-phase.tmp/live-ssh';BASE.mkdir(mode=0o700)
AUTH=ROOT/'.test-phase.tmp/ssh-probe';AUTH.mkdir(mode=0o700)
user=pwd.getpwuid(os.getuid()).pw_name
sock=socket.socket();sock.bind(('127.0.0.1',0));port=sock.getsockname()[1];sock.close()
INFO={'user':user,'port':port}
for key in ['host','identity']:subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-f',str(AUTH/key)],check=True)
(AUTH/'authorized_keys').write_text((AUTH/'identity.pub').read_text());(AUTH/'authorized_keys').chmod(0o600)
(AUTH/'sshd_config').write_text(f'Port {port}\nListenAddress 127.0.0.1\nHostKey {AUTH}/host\nPidFile {AUTH}/sshd.pid\nAuthorizedKeysFile {AUTH}/authorized_keys\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nUsePAM no\nStrictModes no\nAllowUsers {user}\nLogLevel ERROR\nForceCommand echo disposable-ssh-ready\n')
ENV=os.environ.copy()
for k in list(ENV):
    if k.startswith('FM_') or k in ('TMUX','HERDR_ENV','HERDR_SESSION','TASKS_AXI_FILE','TASKS_AXI_BACKEND'):ENV.pop(k,None)
ENV['TMPDIR']=str(ROOT/'.test-phase.tmp');ENV['GIT_CONFIG_GLOBAL']='/dev/null';ENV['GIT_CONFIG_NOSYSTEM']='1'
LOG=(EV/'live-ssh-transcript.log').open('w');P=None;RESULT=[];JOBS=BASE/'jobs'
def run(args,home=None,code=0,stdin=None,brief=False):
    e=ENV.copy()
    if home:e['FM_HOME']=str(home)
    p=subprocess.run([str(a) for a in args],cwd=ROOT,env=e,input=stdin,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=60)
    LOG.write(('$ [historical generation reservation with 65KB model contract]\n' if brief else '$ '+shlex.join([str(a) for a in args])+'\n')+('[historical reservation output omitted: '+str(len(p.stdout))+' bytes]\n' if brief else p.stdout)+'exit='+str(p.returncode)+'\n');LOG.flush()
    if code is not None:assert p.returncode==code,(p.returncode,p.stdout)
    return p
try:
    parent=BASE/'parent';remote=BASE/'remote-home';code=BASE/'remote-code';code.mkdir()
    for h in [parent,remote]:run(['bin/fm-lab-home.sh','create',h])
    (remote/'.fm-secondmate-home').write_text('ios\n')
    shutil.copyfile(ROOT/'AGENTS.md',remote/'AGENTS.md');(remote/'bin').mkdir()
    (remote/'.fm-secondmate-parent').write_text('schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=localhost\n')
    archive=subprocess.Popen(['git','archive','HEAD'],stdout=subprocess.PIPE,cwd=ROOT,env=ENV)
    tar=subprocess.run(['tar','-x','-C',str(code)],stdin=archive.stdout,env=ENV);archive.stdout.close();assert archive.wait()==0 and tar.returncode==0
    run(['git','-C',code,'init','-q']);run(['git','-C',code,'add','bin','AGENTS.md'])
    force=BASE/'forced-command.py'
    force.write_text('import os,shlex\na=shlex.split(os.environ.get("SSH_ORIGINAL_COMMAND",""))\nassert a and a[0]=="fm-remote-entrypoint.sh"\ne=os.environ.copy()\ne["FM_REMOTE_JOB_PLATFORM_OVERRIDE"]="Linux"\ne["FM_REMOTE_JOB_STATE_ROOT"]='+repr(str(JOBS))+'\ne["TMPDIR"]='+repr(str(ROOT/'.test-phase.tmp'))+'\nos.execve('+repr(str(code/'bin/fm-remote-entrypoint.sh'))+',a,e)\n')
    conf=(AUTH/'sshd_config').read_text().replace('ForceCommand echo disposable-ssh-ready','ForceCommand '+shlex.quote(shutil.which('python3'))+' '+shlex.quote(str(force)))
    (BASE/'sshd_config').write_text(conf)
    serverlog=(EV/'live-sshd.log').open('w')
    P=subprocess.Popen([shutil.which('sshd'),'-D','-e','-f',str(BASE/'sshd_config')],stdout=serverlog,stderr=serverlog,start_new_session=True)
    time.sleep(.4)
    wrapper=BASE/'ssh-wrapper'
    opts=['ssh','-F','/dev/null','-o','BatchMode=yes','-o','IdentitiesOnly=yes','-o','StrictHostKeyChecking=accept-new','-o','UserKnownHostsFile='+str(AUTH/'known_hosts'),'-p',str(INFO['port']),'-i',str(AUTH/'identity'),'-l',INFO['user']]
    wrapper.write_text('#!/bin/sh\nexec '+shlex.join(opts)+' "$@"\n');wrapper.chmod(0o700);ENV['FM_SSH_BIN']=str(wrapper)
    (parent/'data/secondmates.md').write_text('- ios - Disposable SSH lab. (host: 127.0.0.1; root: '+str(code)+'; home: '+str(remote)+'; scope: tests; projects: ; added 2026-10-07)\n')
    (parent/'config/fleet-seats').write_text(json.dumps({'pools':[{'name':'shared','capacity':6,'models':['pool-a']}]}))
    out=run(['bin/fm-fleet-seats.sh','serve-remotes'],parent)
    assert 'served ios' in out.stdout
    cert=json.loads((parent/'state/fleet-seats/remote-ios.cert').read_text())
    LOG.write('Real SSH policy certificate persisted: '+json.dumps(cert)+'\n');LOG.flush()
    RESULT.append({'name':'A parent delivers fleet policy over real SSH to a disposable remote worker and persists its matching certificate','result':'pass','live':True})
    hist='historical-'+('x'*65000);prev='-'
    for i in range(18):
        g='h'+str(i)
        run(['bin/fm-fleet-seats.sh','reserve','ios','--generation',g,'--previous-generation',prev,'--kind','secondmate','--harness','claude','--model',hist,'--holder-pid',str(os.getpid())],parent,brief=True)
        run(['bin/fm-fleet-seats.sh','release','ios','--generation',g,'--reason','prelaunch'],parent)
        prev=g
    op='livepayload'
    run(['bin/fm-fleet-seats.sh','reserve','ios','--generation',op,'--previous-generation',prev,'--kind','secondmate','--harness','claude','--model','pool-a','--holder-pid',str(os.getpid())],parent)
    route=parent/'state/route.json'
    route.write_text(json.dumps({'placement':'remote','backend':'herdr','target':None,'home':str(remote),'host':'127.0.0.1','remote_root':str(code),'spawn_gen':None,'operation':op}));route.chmod(0o600)
    run(['bin/fm-fleet-seats.sh','dispatch','ios','--generation',op,'--route-file',route],parent)
    record=subprocess.run(['bin/fm-fleet-seats.sh','show','ios'],cwd=ROOT,env=dict(ENV,FM_HOME=str(parent)),capture_output=True,text=True,check=True).stdout
    assert len(record.encode())>1048576
    LOG.write('Parent holder serialized bytes='+str(len(record.encode()))+' (> transport stdin bound 1048576)\n');LOG.flush()
    args=['bin/fm-on.sh','ios','fm-remote-secondmate-control.sh','relaunch','ios','unverified-harness','pool-a','medium','--operation',op,'--previous',prev]
    out=run(args,parent,code=None)
    assert out.returncode!=0 and 'unverified remote secondmate harness' in out.stdout and 'seat_disposition=' in out.stdout
    saved=remote/'state/parent-route'/('ios.seat-reservation.'+op)
    compact=saved.read_bytes();body=json.loads(compact)
    assert sorted(body)==['incarnations','schema','task'] and len(body['incarnations'])==1 and body['incarnations'][0]['generation']==op and len(compact)<5000
    LOG.write('Remote reservation serialized bytes='+str(len(compact))+'; normalized payload='+json.dumps(body)+'\n');LOG.flush()
    receipt=remote/'state/parent-route'/('ios.seat-operation.'+op)
    before=(compact,receipt.read_bytes())
    retry=run(args,parent,code=None)
    assert retry.returncode!=0 and 'already handled' in retry.stdout and before==(saved.read_bytes(),receipt.read_bytes())
    assert not (remote/'state/parent-route/ios.meta').exists()
    run(['bin/fm-fleet-seats.sh','reclaim','ios','--generation',op],parent,code=3)
    response=parent/'state/host-response.json'
    response.write_text(next(line.removeprefix('seat_disposition=') for line in retry.stdout.splitlines() if line.startswith('seat_disposition='))+'\n');response.chmod(0o600)
    run(['bin/fm-fleet-seats.sh','reconcile-remote','ios','--generation',op,'--response-file',response],parent)
    final=json.loads(subprocess.run(['bin/fm-fleet-seats.sh','show','ios'],cwd=ROOT,env=dict(ENV,FM_HOME=str(parent)),capture_output=True,text=True,check=True).stdout)
    assert final['incarnations'][-1]['lifecycle']=='released'
    RESULT.append({'name':'A holder larger than the SSH stdin limit sends one compact incarnation; host prelaunch refusal and replay preserve receipts and release only that candidate','result':'pass','live':True})
except Exception as exc:
    LOG.write('DRIVER ERROR: '+repr(exc)+'\n');RESULT.append({'name':'Live isolated SSH policy and compact operation transport','result':'fail','live':True,'reason':str(exc)})
finally:
    if (JOBS/'worker.pid').exists():
        run(['bash','-c','. bin/fm-remote-job-lib.sh; fm_remote_job_stop_worker_tree "$(cat "$1")"','_',JOBS/'worker.pid'],code=None)
    if P:
        try:os.killpg(P.pid,signal.SIGTERM)
        except ProcessLookupError:pass
        P.wait(timeout=10)
    shutil.rmtree(BASE);shutil.rmtree(AUTH)
    LOG.write('Disposable SSH daemon, worker tree, keys, known_hosts, homes, copied code, and state removed.\n');LOG.close()
    (EV/'live-ssh-results.json').write_text(json.dumps(RESULT,indent=2))
print(json.dumps(RESULT,indent=2))
