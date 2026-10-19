"""Public-owner scenarios. Imports are inert; runtime entrypoints require a private spec."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import sys
import time

_binding=importlib.util.spec_from_file_location('ready_review_owned',Path(__file__).with_name('owned.py'))
_owned=importlib.util.module_from_spec(_binding);_binding.loader.exec_module(_owned)

CASE_NAMES = ('permitted-start-with-held-sibling', 'away-denied', 'credential-denied',
              'account-denied', 'capacity-denied', 'spend-denied', 'approval-denied',
              'partial-dependency', 'ack-without-disposition-denied', 'duplicate-no-relaunch',
              'stale-generation-denied', 'owner-home-isolation')

def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def identity(pid):
    try:
        fields=Path(f'/proc/{pid}/stat').read_text().rsplit(')',1)[1].split()
        return dict(pid=pid,start=fields[19],ppid=int(fields[1]),state=fields[0],uid=Path(f'/proc/{pid}').stat().st_uid)
    except (FileNotFoundError,ProcessLookupError):return None

def require(value, message):
    if not value:raise AssertionError(message)

def seed_binding(directory):
    directory=Path(directory)
    receipt=directory/'receipt.json';binding=json.loads(receipt.read_text())['seeds']['accounting']
    head=binding['base_head'];pack=directory/'accounting/existing-base.pack';shallow=directory/'accounting/shallow'
    require(re.fullmatch('[0-9a-f]{40}',head),'Invalid admitted existing HEAD')
    require(sha(pack)==binding['pack_sha256'] and pack.stat().st_size==binding['pack_bytes'],'Admitted seed pack identity differs')
    require(sha(shallow)==binding['shallow_sha256'] and shallow.read_bytes()==(head+'\n').encode(),'Admitted seed shallow boundary differs')
    return dict(binding,receipt_sha256=sha(receipt)),pack,shallow

def load():
    spec=json.loads(Path(os.environ['FM_RR_SPEC']).read_text())
    require(spec['schema']==1 and spec['kind']=='private-ready-review-sdk-fixture','Private test fixture required')
    return spec

class Scenario:
    def __init__(self,spec):
        self.s=spec; self.root=Path(spec['root']);self.output=Path(spec['output']);self.source=Path(spec['source'])
        self.base=dict(os.environ)
        for key in list(self.base):
            if key.endswith('_OVERRIDE') or key in ('FM_GATE_REFUSE_BYPASS','FM_TEST_SEAM','FM_TASK_ID','FM_TASK_INBOX'):
                self.base.pop(key)

    def home(self,name):return self.root/'homes'/name

    def env(self,name):
        env=dict(self.base,FM_HOME=str(self.home(name)))
        socket_record=self.home(name)/'state/.fm-lab-tmux-dir'
        if socket_record.exists():env['TMUX_TMPDIR']=socket_record.read_text().strip()
        env.pop('TMUX',None);env.pop('TMUX_PANE',None)
        return env

    def cmd(self,name,argv,ok=True,contains=None,timeout=90,extra=None,cwd=None):
        env=self.env(name);env.update(extra or {})
        started=time.monotonic()
        receipt,(stdout,stderr)=_owned.capture(argv,env,cwd or self.home(name),self.output,'command-'+name,timeout)
        event=dict(home=name,argv=[str(v) for v in argv],exit_code=receipt['exit_code'],stdout=stdout,stderr=stderr,
                   elapsed=time.monotonic()-started,process=receipt['identity'],capture=receipt)
        with (self.output/'commands.jsonl').open('a') as stream:stream.write(json.dumps(event)+'\n')
        require((receipt['exit_code']==0)==ok,f'Unexpected command result: {argv[0]} {argv[1:]}: {receipt["exit_code"]}: {stderr}')
        if contains is not None:require(contains in stdout+stderr,f'Expected owner diagnostic missing: {contains}')
        return stdout+stderr

    def fm(self,name,script,*args,**kwargs):return self.cmd(name,['bash',self.source/'bin'/script,*args],**kwargs)
    def task(self,name,*args,**kwargs):return self.fm(name,'fm-tasks-axi.sh',*args,**kwargs)
    def review(self,name,*args,**kwargs):return self.fm(name,'fm-ready-review.sh',*args,**kwargs)
    def scan(self,name):return json.loads(self.review(name,'scan'))
    def generation(self,name,task):return self.scan(name)['candidates'][task]['generation']

    def record(self,case,**evidence):
        require(case in CASE_NAMES,'Unknown acceptance case')
        path=self.output/(case+'.json')
        require(not path.exists(),'Acceptance case attempted twice')
        path.write_text(json.dumps(dict(case=case,status='passed',evidence=evidence),indent=2)+'\n')

    def stop(self,name,task,gate,reason,retry,generation=None):
        self.review(name,'stop',task,generation or self.generation(name,task),'--gate',gate,'--reason',reason,'--retry',retry)

    def project(self,name):return self.home(name)/'projects'/('project-'+name)

    def spawn(self,name,task,ok=True,contains=None,model=None):
        return self.fm(name,'fm-spawn.sh',task,self.project(name),'--mode','local-only','--yolo','off',
                       '--harness','pi','--model',model or self.s['provider']+'/child','--backend','tmux',
                       ok=ok,contains=contains,timeout=120)

    def new_home(self,name):
        home=self.home(name)
        self.fm(name,'fm-lab-home.sh','create',home,cwd=self.root)
        (home/'.tasks.toml').write_bytes((self.source/'.tasks.toml').read_bytes())
        (home/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
        (home/'config/crew-harness').write_text('pi\n')
        (home/'config/backend').write_text('tmux\n')
        self.fm(name,'fm-lab-home.sh','tmux-dir',home)

    def add(self,name,task,deps=(),held=False):
        self.task(name,'add',task,f'Private SDK fixture {task} {self.s["nonce"]}','--kind','ship')
        for dependency in deps:self.task(name,'block',task,'--by',dependency)
        if held:self.task(name,'hold',task,'--kind','captain','--reason','Explicit fixture approval remains required')

    def prepare_seed(self):
        origin=self.root/'public-seed.git';name='positive'
        binding,pack,shallow=seed_binding('/opt/sdk-guest/git-seeds')
        head=binding['base_head'];self.cmd(name,['git','init','--quiet','--bare',origin])
        packed=pack.read_bytes()
        require(packed.startswith(b'PACK') and len(packed)>32 and hashlib.sha1(packed[:-20]).digest()==packed[-20:],'Invalid admitted SHA1 pack checksum')
        private_pack=origin/'objects/pack'/('pack-'+packed[-20:].hex()+'.pack');private_pack.write_bytes(packed)
        self.cmd(name,['git','--git-dir',origin,'index-pack',private_pack])
        (origin/'shallow').write_bytes(shallow.read_bytes())
        binding.update(mode='admitted-guest-existing-public-head')
        self.cmd(name,['git','--git-dir',origin,'update-ref','refs/heads/main',head])
        self.cmd(name,['git','--git-dir',origin,'symbolic-ref','HEAD','refs/heads/main'])
        require(self.cmd(name,['git','--git-dir',origin,'rev-parse','HEAD']).strip()==head,'Private seed HEAD differs')
        require(self.cmd(name,['git','--git-dir',origin,'rev-list','HEAD']).splitlines()==[head],'Private seed reaches a different commit')
        wrapper=self.cmd(name,['git','--git-dir',origin,'show','HEAD:bin/fm-sessionstart-run.sh'])
        require(hashlib.sha256(wrapper.encode()).hexdigest()==sha(self.source/'bin/fm-sessionstart-run.sh'),'Committed sessionstart wrapper differs from candidate')
        binding.update(wrapper_sha256=sha(self.source/'bin/fm-sessionstart-run.sh'),private_origin=str(origin),no_canonical_git_mutation=True)
        (self.output/'private-seed.json').write_text(json.dumps(binding,indent=2)+'\n')

    def seed_project(self,name):
        # Only an existing source commit is copied; no new commit or real index is written.
        home=self.home(name); origin=home/'origin.git'; project=self.project(name)
        self.cmd(name,['git','clone','--quiet','--bare','--no-hardlinks',self.root/'public-seed.git',origin])
        self.cmd(name,['git','clone','--quiet','--no-hardlinks',origin,project])
        # treehouse init runs in the disposable project, never the source checkout.
        self.project_cmd(name,['treehouse','init'])
        registry=f'- {project.name} [local-only] - {project}\n'
        (home/'data/projects.md').write_text('# Projects\n\n'+registry)
        for task in self.s['sceneTasks'][name]:
            self.fm(name,'fm-brief.sh',task,project.name,'--mode','local-only')
            brief=home/'data'/task/'brief.md'
            raw=brief.read_text().replace('{TASK}',f'Process only the synthetic dependency acceptance nonce {self.s["nonce"]}.')
            raw=raw.replace('{FIRSTMATE_SPEC}',f'Read this launch brief through the real SDK tools; return the nonce {self.s["nonce"]}.')
            require('{TASK}' not in raw and '{FIRSTMATE_SPEC}' not in raw,'Brief placeholders remain')
            brief.write_text(raw)

    def project_cmd(self,name,argv):
        return self.cmd(name,argv,cwd=self.project(name),timeout=30)

    def setup(self):
        for name in self.s['scenes']:self.new_home(name)
        self.prepare_seed()
        for name in ('positive','capacity','spend','approval','partial'):self.seed_project(name)
        for name in ('positive','approval','partial','stale','foreign-a','foreign-b'):
            self.add(name,'prerequisite',held=True)
            self.add(name,'dependent',deps=('prerequisite',),held=name in ('approval','stale','foreign-a','foreign-b'))
            self.task(name,'done','prerequisite')
        self.add('positive','held',deps=('prerequisite',),held=True)
        self.add('partial','remaining',held=True)
        self.task('partial','block','dependent','--by','remaining')
        for name in ('away','quiet','credential','account','ack'):self.add(name,'dependent')
        for name in ('capacity','spend'):
            for task in self.s['sceneTasks'][name]:self.add(name,task)
        (self.home('positive')/'config/supervision-branch-model').write_text(self.s['provider']+'/branch\n')
        (self.home('positive')/'config/supervision-branch-effort').write_text('off\n')
        self.fm('away','fm-afk-contract.sh','enter','--words','No dispatch is authorized for this private fixture.','--spend','4')
        self.fm('quiet','fm-afk-contract.sh','enter','--words','Quiet fixture; no branch new-work authority.',extra={'FM_AFK_MODE':'quiet'})
        # No generic held marker or forged busy record is seeded anywhere.
        before=self.task('positive','show','held','--full')
        (self.output/'held-before.txt').write_text(before)
        snapshot=self.scan('positive')
        (self.output/'held-facts-before.json').write_text(json.dumps(snapshot['candidates']['held'],indent=2)+'\n')
        # The real watcher must publish and deliver this first review itself.
        # Pre-queuing here coalesces its first poll into a generic recovery wake.
        queue=self.home('positive')/'state/.wake-queue'
        require(not queue.exists() or not queue.read_text().strip(),'Setup pre-queued a dependency review')

    def branch_review(self):
        require(os.environ.get('FM_SUPERVISION_ACTOR')=='branch','Must run through actual branch bash injection')
        # Real actor boundary while attended; a disposable marked home is never a bypass.
        self.spawn('positive','dependent',ok=False,contains='supervision branch never performs this action')
        self.stop('away','dependent','away','The recorded words authorize no dispatch.','MAIN must record a concrete grant before retrying.')
        away=self.scan('away')['candidates']['dependent']
        require(away['stop']['gate']=='away' and not (self.home('away')/'state/dependent.meta').exists(),'Away stop lost or worker launched')
        self.review('away','guard','main')
        self.spawn('quiet','dependent',ok=False,contains='supervision branch never performs this action')
        self.record('away-denied',boundary='recorded-grant choice is supervisor-attested; actual attended/quiet branch spawn refusals also exercised',
                    stop=away['stop'],worker_absent=True)
        self.review('positive','guard','main',ok=False,contains='unhandled ready review')
        print('BRANCH_REVIEW_COMPLETE')

    def ack_args(self,name):
        view=self.fm(name,'fm-wake-drain.sh')
        found=re.search(r'WAKE_ACK_REQUIRED: after handling completes run bin/fm-wake-drain.sh --ack-through ([0-9]+) --recovery-generation (\S+)',view)
        require(found,'Real drain did not publish its exact acknowledgment arguments')
        return ['--ack-through',found[1],'--recovery-generation',found[2]]

    def ack(self,name):self.fm(name,'fm-wake-drain.sh',*self.ack_args(name))

    def branch_ack(self):
        require(os.environ.get('FM_SUPERVISION_ACTOR')=='branch','Must use actual branch actor')
        self.ack('positive');print('BRANCH_ACK_COMPLETE')

    def worker(self):
        task=os.environ.get('FM_TASK_ID');home=Path(os.environ['FM_HOME'])
        require(task in self.s['workerTasks'],'Unowned worker task')
        brief=home/'data'/task/'launch-brief.md'
        raw=brief.read_text();require(self.s['nonce'] in raw,'Actual worker brief nonce absent')
        worktree=Path.cwd().resolve()
        primary_project=home/'projects'/('project-'+home.name)
        require(worktree not in (home.resolve(),primary_project.resolve(),self.source.resolve()),'Worker did not enter an isolated worktree')
        receipt=dict(task=task,home=str(home),nonce=self.s['nonce'],brief=str(brief),brief_sha256=sha(brief),
                     worktree=str(worktree),processor=identity(os.getpid()))
        (self.output/f'{task}-processed.json').write_text(json.dumps(receipt,indent=2)+'\n')
        print('WORKER_PROCESSED '+self.s['nonce'])

    def worker_proof(self,name,task):
        deadline=time.monotonic()+90
        while time.monotonic()<deadline:
            logs=[]
            for path in self.output.glob('provider-*.jsonl'):
                for line in path.read_text().splitlines():
                    try:value=json.loads(line)
                    except json.JSONDecodeError:continue
                    if value.get('event')=='worker-holding' and value.get('task')==task and value.get('home')==str(self.home(name)):logs.append(value)
            if logs:break
            time.sleep(.05)
        require(len(logs)==1,'Exactly one actual child processing barrier is required')
        event=logs[0]; current=identity(event['pid'])
        require(current and current['start']==event['start'] and current['uid']==os.getuid() and current['state']!='Z','Actual SDK child identity is not live')
        primary=json.loads((self.output/'primary-owner.json').read_text())
        require(Path(f'/proc/{event["pid"]}/exe').resolve()==Path(primary['exec_path']).resolve(), 'Child executable is not the exact selected Node runtime')
        require(event['argv_entry']==str(Path(self.s['sdkPackage'])/'dist/bundle/cli.js') and event['sdk_package']==self.s['sdkPackage'],
                'Child did not enter the exact accepted SDK CLI')
        processed=json.loads((self.output/f'{task}-processed.json').read_text())
        brief=self.home(name)/'data'/task/'launch-brief.md'
        require(processed['brief_sha256']==sha(brief)==event['brief_sha256'],'Processed brief differs from launched candidate brief')
        meta=self.metadata(name,task)
        require(meta['endpoint_task_id']==task and meta['harness']=='pi' and meta['model']==self.s['provider']+'/child','Actual spawn identity differs')
        require(processed['worktree']==meta['worktree'],'Actual child processed outside its recorded worktree')
        require(Path(f'/proc/{event["pid"]}/cwd').resolve()==Path(meta['worktree']).resolve(),'Actual child left its owned worktree')
        review=self.scan(name)['candidates'][task]
        require(review['launch']['spawn_gen']==meta['spawn_gen'] and review['launch']['generation']==review['generation'],'Missing actual fm-spawn owner hook')
        state=self.fm(name,'fm-crew-state.sh',task)
        require(state.startswith('state: working · source: ') and ('source: pane ·' in state or 'source: run-step ·' in state),'Current owner does not prove processing')
        server_pid=int(self.cmd(name,['tmux','display-message','-p','#{pid}']).strip())
        server=identity(server_pid);require(server and server['uid']==os.getuid(),'Actual terminal server identity missing')
        socket=Path((self.home(name)/'state/.fm-lab-tmux-dir').read_text().strip())/'sdk.sock'
        files=[];events=[]
        for path in self.output.glob('provider-*.jsonl'):
            for line in path.read_text().splitlines():
                try:row=json.loads(line)
                except json.JSONDecodeError:continue
                if row.get('pid')==event['pid'] and row.get('event')=='session-start':files.append(row['session_file'])
                if row.get('pid')==event['pid'] and row.get('event')=='request':events.append(row)
        require(len(set(files))==1,'Actual child session path ambiguous')
        transcript=Path(files[0]); records=[json.loads(line) for line in transcript.read_text().splitlines()]
        messages=[row['message'] for row in records if row.get('type')=='message']
        require(any(message.get('role')=='user' and self.s['nonce'] in json.dumps(message) for message in messages),'Actual persisted child user brief missing')
        require(any(message.get('role')=='toolResult' and message.get('toolName')=='read' and self.s['nonce'] in json.dumps(message) and not message.get('isError') for message in messages),'Actual persisted SDK read result missing')
        require(any(message.get('role')=='toolResult' and message.get('toolCallId')==event['last_result_id'] and 'WORKER_PROCESSED '+self.s['nonce'] in json.dumps(message) and not message.get('isError') for message in messages),'Actual persisted SDK processing result missing')
        proof=dict(child=current,spawn_gen=meta['spawn_gen'],endpoint_task_id=task,candidate_generation=review['generation'],
                   launch=review['launch'],brief_sha256=sha(brief),session_file=str(transcript),session_sha256=sha(transcript),
                   actual_owner_state=state,processing_result_id=event['last_result_id'],provider_session=event['session'])
        proof.update(terminal_server=server,socket_path=str(socket),exec_path=event['exec_path'],argv_entry=event['argv_entry'],sdk_package=event['sdk_package'])
        (self.output/f'{task}-proof.json').write_text(json.dumps(proof,indent=2)+'\n')
        return proof

    def metadata(self,name,task):
        values={}
        for line in (self.home(name)/'state'/f'{task}.meta').read_text().splitlines():
            if '=' in line:key,value=line.split('=',1);require(key not in values,'Duplicate actual metadata field');values[key]=value
        return values

    def assert_queued_no_worker(self,name,task):
        show=self.task(name,'show',task,'--full')
        require('state: queued' in show and not (self.home(name)/'state'/f'{task}.meta').exists(),'Denied task acquired worker or left queue')
        return show

    def main_dispatch(self):
        require(os.environ.get('FM_SUPERVISION_ACTOR','main')=='main','MAIN dispatch must use actual MAIN bash tool')
        self.spawn('positive','dependent')
        proof=self.worker_proof('positive','dependent')
        self.stop('positive','held','structured','Explicit fixture approval remains required.','The keyed captain hold must be answered by its owner.')
        self.review('positive','guard','main')
        held=self.task('positive','show','held','--full')
        before=(self.output/'held-before.txt').read_text()
        original_facts=json.loads((self.output/'held-facts-before.json').read_text())
        current_facts=self.scan('positive')['candidates']['held']
        require(original_facts['facts']==current_facts['facts'] and original_facts['generation']==current_facts['generation'],
                'Explicit held sibling structured identity changed')
        require('held: yes' in held and 'Explicit fixture approval remains required' in held and
                'held: yes' in before and not (self.home('positive')/'state/held.meta').exists(),'Held sibling changed')
        self.record('permitted-start-with-held-sibling',proof=proof,held_before_sha256=hashlib.sha256(before.encode()).hexdigest(),
                    held_after_sha256=hashlib.sha256(held.encode()).hexdigest(),held_preserved=True,held_facts=current_facts['facts'])
        before_generation=self.metadata('positive','dependent')['spawn_gen']
        self.spawn('positive','dependent',ok=False)
        self.scan('positive');self.review('positive','guard','main')
        require(self.metadata('positive','dependent')['spawn_gen']==before_generation,'Duplicate review relaunched worker')
        repeated=self.worker_proof('positive','dependent')['child']
        require((repeated['pid'],repeated['start'])==(proof['child']['pid'],proof['child']['start']),'Duplicate review changed actual worker')
        self.record('duplicate-no-relaunch',spawn_gen=before_generation,child=proof['child'])
        self.denied_cases()
        print('MAIN_DISPATCH_COMPLETE')

    def denied_cases(self):
        # Provider pin mismatch and real empty-root auth refusal, without any real credential.
        for name in ('credential','account'):
            root=self.home(name)/'synthetic-account';root.mkdir()
            allowed='anthropic' if name=='credential' else 'different-fixture-provider'
            (self.home(name)/'config/pi-account').write_text(str(root)+'\n'+allowed+'\n')
            model='anthropic/fixture-no-model' if name=='credential' else self.s['provider']+'/child'
            diagnostic='not signed in' if name=='credential' else 'names provider'
            refusal=self.spawn(name,'dependent',ok=False,contains=diagnostic,model=model)
            self.stop(name,'dependent',name,'Actual private account admission refused the candidate.','Correct the fixture pin or provide usable credentials in its private root.')
            self.review(name,'guard','main')
            self.record(name+'-denied',refusal=refusal,queued=self.assert_queued_no_worker(name,'dependent'))
        for name,seat,waiting in (('capacity','capacity-seat','capacity-wait'),('spend','spend-seat','spend-wait')):
            self.scan(name);self.spawn(name,seat);proof=self.worker_proof(name,seat)
            if name=='capacity':
                (self.home(name)/'config/project-capacity').write_text(self.project(name).name+' 1\n')
                refusal=self.spawn(name,waiting,ok=False,contains='deferred: project')
            else:
                self.fm(name,'fm-afk-contract.sh','enter','--words','Dispatch only these private fixture units.','--spend','1')
                refusal=self.spawn(name,waiting,ok=False,contains='caps concurrent workers at 1')
            self.stop(name,waiting,name,'The actual admission owner refused while the real worker holds its place.','Wait for the actual worker to finish and the owning limit to permit dispatch.')
            self.review(name,'guard','main')
            self.record(name+'-denied',refusal=refusal,occupant=proof,queued=self.assert_queued_no_worker(name,waiting))
        self.scan('approval')
        self.spawn('approval','dependent',ok=False,contains='not dispatchable')
        self.stop('approval','dependent','structured','Explicit approval is still held.','A keyed captain answer must clear this hold.')
        self.review('approval','guard','main')
        self.record('approval-denied',queued=self.assert_queued_no_worker('approval','dependent'))
        partial=self.scan('partial')['candidates']['dependent']
        require(partial['facts']['dependencies']=={'prerequisite':'done','remaining':'queued'},'Partial graph not observed')
        self.spawn('partial','dependent',ok=False,contains='not dispatchable')
        self.stop('partial','dependent','structured','Another structured prerequisite remains queued.','The remaining prerequisite must complete.')
        self.review('partial','guard','main')
        self.record('partial-dependency',facts=partial['facts'],queued=self.assert_queued_no_worker('partial','dependent'))
        self.ack_denied()
        old=self.generation('stale','dependent')
        self.stop('stale','dependent','structured','The old explicit hold applies.','The hold owner must release it.')
        self.task('stale','unhold','dependent')
        new=self.generation('stale','dependent');require(old!=new,'Generation did not change')
        self.stop_stale('stale','dependent',old)
        self.review('stale','guard','main',ok=False,contains='unhandled ready review')
        self.review('stale','launch','dependent','s1.1.1',ok=False,contains='confirmed fm-spawn caller')
        self.task('stale','done','dependent')
        self.review('stale','guard','main',ok=False,contains='unhandled ready review')
        self.record('stale-generation-denied',old=old,new=new,done_without_start_rejected=True,forged_launch_refused=True)
        first=self.generation('foreign-a','dependent');second=self.generation('foreign-b','dependent')
        require(first!=second,'Independent homes reused a candidate generation')
        prior=sha(self.home('foreign-b')/'data/backlog.md')
        self.stop_stale('foreign-b','dependent',first)
        require(sha(self.home('foreign-b')/'data/backlog.md')==prior,'Foreign receipt changed other home backlog')
        self.review('foreign-b','guard','main',ok=False,contains='unhandled ready review')
        self.record('owner-home-isolation',local_generation=first,foreign_generation=second,foreign_backlog_unchanged=True)

    def stop_stale(self,name,task,generation):
        self.review(name,'stop',task,generation,'--gate','external','--reason','Stale fixture receipt.','--retry','No retry under this generation.',
                    ok=False,contains='stale or foreign')

    def ack_denied(self):
        self.scan('ack')
        # Present the real wake before the handoff covers this branch review.
        self.review('ack','poll');arguments=self.ack_args('ack')
        self.fm('ack','fm-branch-outcome.sh','append','--task','fleet','--verdict','routine','--summary','No disposition.',ok=False)
        seq=self.fm('ack','fm-branch-outcome.sh','append','--task','fleet','--verdict','captain','--summary','Handle the synthetic candidate.').strip()
        require(seq=='1','Unexpected isolated handoff sequence')
        self.fm('ack','fm-branch-outcome.sh','mark-read','--through','1')
        path=self.home('ack')/'state/.branch-outcomes-processed'
        old=path.read_bytes() if path.exists() else None
        self.fm('ack','fm-branch-outcome.sh','mark-processed','--through','1',ok=False,contains='unhandled ready review')
        require((path.read_bytes() if path.exists() else None)==old,'Denied processed cursor moved')
        queue=self.home('ack')/'state/.wake-queue';before=queue.read_bytes()
        self.fm('ack','fm-wake-drain.sh',*arguments,ok=False,contains='unhandled ready review')
        require(queue.read_bytes()==before,'Denied wake acknowledgment consumed rows')
        self.stop('ack','dependent','external','The owner explicitly refuses dispatch in this isolated negative test.','A later owner decision must authorize a separate dispatch.')
        self.fm('ack','fm-branch-outcome.sh','mark-processed','--through','1')
        self.fm('ack','fm-wake-drain.sh',*arguments)
        require(not queue.read_text().strip(),'Valid current stop did not allow the same presented acknowledgment')
        self.record('ack-without-disposition-denied',processed_cursor_unchanged=True,wake_queue_unchanged=True,allowed_after_current_stop=True)

    def finalize(self):
        require((self.home('positive')/'state/.branch-outcomes-processed').read_text().strip()=='1','Actual MAIN processing acknowledgment missing')
        self.review('positive','guard','main')
        self.worker_proof('positive','dependent')
        deadline=time.monotonic()+30
        while time.monotonic()<deadline and (self.home('positive')/'state/.wake-queue').read_text().strip():time.sleep(.05)
        require(not (self.home('positive')/'state/.wake-queue').read_text().strip(),'Actual branch did not consume its owned wake')
        cases=[json.loads((self.output/(name+'.json')).read_text()) for name in CASE_NAMES]
        require(all(value['status']=='passed' for value in cases),'Required acceptance case missing')
        result=dict(schema=1,kind='actual-sdk-dependency-scenario',cases=cases,
            boundary='Synthetic deterministic model proves engine/tool/owner integration; grant language remains a supervisor-attested policy choice.')
        (self.output/'scenario-completed.json').write_text(json.dumps(result,indent=2)+'\n')
        print('SDK_SCENARIO_COMPLETE')

def main():
    scenario=Scenario(load())
    action=sys.argv[1]
    actions={'setup':scenario.setup,'branch-review':scenario.branch_review,'branch-ack':scenario.branch_ack,
             'main-dispatch':scenario.main_dispatch,'worker':scenario.worker,'finalize':scenario.finalize}
    require(action in actions,'Unknown fixture action')
    actions[action]()

if __name__=='__main__':main()
