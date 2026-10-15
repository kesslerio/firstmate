#!/usr/bin/env bash
# Offline public-interface tests for authorized snapshots and cross-home leases.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
if [ "$(uname -s)" != Linux ]; then
  printf '%s\n' 'skip: Linux subreaper/pidfd media lifecycle is unavailable'
  exit 0
fi
TEST_ROOT=$(fm_test_tmproot fm-github-media)
export TEST_ROOT ROOT
python3 -B - <<'PY'
import sys
from pathlib import Path
import os
import fcntl
import hashlib
import json
import signal
import subprocess
import time
sys.path.insert(0, str(Path(os.environ['ROOT'])/'libexec/github-media'))
from github_media_fixtures import (root, cli, transport, native, validator, parser, fixture,
                                 command, run, denied, inspect, add_video, deps,
                                 publish, prepared, wait_for_file, wait_gone)

def body_value(p, kind='pr', value=None):
 remote=json.loads((p/'remote.json').read_text()); key='/repos/owner/repo/'+('pulls' if kind=='pr' else 'issues')+'/7'
 if value is not None:
  remote[key]['body']=value; (p/'remote.json').write_text(json.dumps(remote))
 return remote[key]['body']

def body_approval(p,m,draft,purpose='final',offset=0):
 path=p/'draft.md'; path.write_bytes(draft.encode())
 a=dict(schema=1,id='body-1',home=m['home'],task=m['task'],operation=m['operation'],target=m['target'],actor=m['actor'],source=m.get('source'),authority=m['authority'],purpose=purpose,before_body_sha256=hashlib.sha256(body_value(p,m['target']['kind']).encode()).hexdigest(),draft=dict(path=str(path),sha256=hashlib.sha256(draft.encode()).hexdigest()),prose_offset=offset)
 approval=p/'body-approval.json'; approval.write_text(json.dumps(a)); return approval

def edit_body(p,m,e,approval,needle=None):
 r=subprocess.run(['bash',str(cli),'edit-body','--operation',m['operation'],'--dependencies',str(deps(p)),'--approval',str(approval)],env=e,capture_output=True,text=True,timeout=20)
 assert (r.returncode==0) if needle is None else (r.returncode!=0 and needle in r.stderr),(r.returncode,r.stderr)
 return r

def final_draft(p,m,offset=0):
 body=body_value(p,m['target']['kind']); prose,media=body.split('\n\n',1)
 if m['files'][-1]['media_type']=='video/mp4':
  first,video=media.split('\n\n'); media=first+'\n\n'+m['files'][-1]['label']+'\n\n'+video
 return prose[:offset]+'\n\n'+media+'\n\n'+prose[offset:]

def complete(p,m,e,rec,needle=None,review_only=False,evidence_bytes=b'SYNTHETIC TEST ATTESTATION - NOT UI PROOF'):
 evidence=[]
 for i,f in zip(rec['items'],m['files']):
  artifact=p/('review-'+str(i['ordinal'])); artifact.write_bytes(evidence_bytes)
  evidence.append(dict(ordinal=i['ordinal'],sha256=f['sha256'],url=i['attempts'][-1]['url'],label=f['label'],rendered=True,playback=f['media_type']=='video/mp4',artifact=dict(path=str(artifact),sha256=hashlib.sha256(artifact.read_bytes()).hexdigest())))
 a=dict(schema=1,home=m['home'],task=m['task'],operation=m['operation'],target=m['target'],actor=m['actor'],source=m.get('source'),authority=m['authority'],body_sha256=hashlib.sha256(body_value(p,m['target']['kind']).encode()).hexdigest(),reviewer='independent-reviewer',independent=True,provenance='synthetic test only',media=evidence)
 path=p/'completion.json'; path.write_text(json.dumps(a))
 if review_only: return path
 return finish(p,m,e,path,needle)

def finish(p,m,e,path,needle=None):
 r=subprocess.run(['bash',str(cli),'complete','--operation',m['operation'],'--dependencies',str(deps(p)),'--review',str(path)],env=e,capture_output=True,text=True,timeout=20)
 assert (r.returncode==0) if needle is None else (r.returncode!=0 and needle in r.stderr),(r.returncode,r.stderr)
 return r

def parser_binding_regressions():
 # New execution must require schema 2; retained schema 1 is evidence only.
 p,m,e=fixture(); prepared(p,m,e)
 result=json.loads(publish(p,m,e).stdout)
 assert result['dependencies']['schema']==2 and 'parser' in result['dependencies']
 assert len((p/'native-calls').read_text().splitlines())==1
 for case in ['legacy','absent','digest','relative','symlink','nonexec']:
  p,m,e=fixture(); prepared(p,m,e); dependency=deps(p); value=json.loads(dependency.read_text())
  if case=='legacy': value['schema']=1; value.pop('parser')
  elif case=='absent': value.pop('parser')
  elif case=='digest': value['parser']['sha256']='0'*64
  elif case=='relative': value['parser']['path']='cmark-gfm'
  elif case=='symlink':
   link=p/'parser-link'; link.symlink_to(parser); value['parser']['path']=str(link)
  elif case=='nonexec':
   path=p/'parser'; path.write_bytes(parser.read_bytes()); path.chmod(0o600); value['parser']['path']=str(path)
  dependency.write_text(json.dumps(value))
  r=subprocess.run(['bash',str(cli),'publish','--operation','op1','--dependencies',str(dependency)],env=e,capture_output=True,text=True,timeout=10)
  assert r.returncode!=0,(case,r.stdout,r.stderr)
  assert not (p/'native-calls').exists() and not (p/'hygiene-calls').exists()
 for history in ['none','confirmed','unknown','body-journal','attach-journal']:
  p,m,e=fixture(); op=prepared(p,m,e)
  if history in ['confirmed','unknown']:
   if history=='unknown': (p/'no-append').touch()
   publish(p,m,e,'unknown' if history=='unknown' else None)
  rec=json.loads((op/'operation.json').read_text()); old=json.loads(deps(p).read_text()); old['schema']=1; old.pop('parser'); rec['dependencies']=old
  if history in ['body-journal','attach-journal']:
   journal=next(op.glob('command-*.json')); entry=json.loads(journal.read_text()); entry['phase']='body-edit' if history=='body-journal' else 'attach'; journal.write_text(json.dumps(entry))
  (op/'operation.json').write_text(json.dumps(rec))
  assert json.loads(inspect(p,m,e).stdout)['dependencies']==old
  before=(p/'native-calls').read_bytes() if (p/'native-calls').exists() else b''
  if history=='none':
   assert json.loads(publish(p,m,e).stdout)['dependencies']['schema']==2
  else:
   publish(p,m,e,'binding changed')
   assert (op/'operation.json').read_text()==json.dumps(rec)
   assert ((p/'native-calls').read_bytes() if (p/'native-calls').exists() else b'')==before
 print('ok - schema2 parser binding and schema1 inspection/provisional/frozen history',flush=True)

if os.environ.get('FM_GITHUB_MEDIA_PARSER_ONLY')=='1':
 parser_binding_regressions(); sys.exit()

def u3_c4_regressions():
 for body in ['`literal\n\n<!-- unfinished\nclosing `',
              '`literal\n# Heading\n<!-- unfinished\nclosing `',
              '``literal\n \t\n<!-- unfinished\nclosing ``',
              '`literal\r\n\r\n<!-- unfinished\r\nclosing `',
              '`literal\n\n<details><summary>Evidence</summary>\nclosing `',
              '`literal\ncontinued`']:
  p,m,e=fixture(); body_value(p,value=body); op=prepared(p,m,e)
  r=subprocess.run(['bash',str(cli),'publish','--operation','op1','--dependencies',str(deps(p))],env=e,capture_output=True,text=True,timeout=15)
  assert r.returncode==1 and 'unsafe' in r.stderr and 'Traceback' not in r.stderr,(body,r.returncode,r.stderr)
  assert not (p/'native-calls').exists() and json.loads((op/'operation.json').read_text())['state']=='held'
  assert body_value(p)==body
 for body in ['`literal`\n\n<!-- complete -->','`<!-- literal -->`',
              '``literal ` tick``\n\n<!-- complete -->',
              '```text\n`literal\n\n<!-- unfinished\nclosing `\n```',
              '<!-- raw ` tick\n\ncomment -->', '<code>raw ` tick\n\ncode</code>']:
  p,m,e=fixture(); body_value(p,value=body); prepared(p,m,e); publish(p,m,e)
  assert body_value(p).startswith(body.rstrip(' \t\r\n')+'\n\n')
  assert json.loads((p/'hygiene-calls').read_text().splitlines()[0])['body']==body
 print('ok - U3-C4 multiline inline spans refuse before mutation; literal comments, same-line code and fences retain exact bytes',flush=True)

if os.environ.get('FM_GITHUB_MEDIA_C4_ONLY')=='1':
 u3_c4_regressions(); sys.exit()

def placement_regressions():
 for prose,offset in [('```text\nliteral\n```',len('```text\n')),
                      ('<details><summary>Evidence</summary>\n\ntext\n</details>',len('<details><summary>Evidence</summary>\n'))]:
  p,m,e=fixture(); body_value(p,value=prose); prepared(p,m,e); rec=json.loads(publish(p,m,e).stdout)
  media='![Approved view]('+rec['items'][0]['attempts'][-1]['url']+')'
  draft=prose[:offset]+'\n\n'+media+'\n\n'+prose[offset:]
  approval=body_approval(p,m,draft,offset=offset)
  edit_body(p,m,e,approval,'unsafe'); assert not (p/'body-calls').exists()
 print('ok - final media cannot move into a fence or unsupported open HTML insertion boundary',flush=True)

if os.environ.get('FM_GITHUB_MEDIA_PLACEMENT_ONLY')=='1':
 placement_regressions(); sys.exit()

def u4_regressions():
 guard=Path(os.environ['ROOT'])/'tests/fm-github-media-hygiene.test.sh'
 p,m,e=fixture(); e.pop('FM_GITHUB_MEDIA_POLICY_SOURCE',None); e.pop('FM_GITHUB_MEDIA_POLICY_SHA256',None)
 r=subprocess.run(['bash',str(guard)],env=e,capture_output=True,text=True,timeout=10)
 assert r.returncode==0 and 'no real policy pass' in r.stdout
 bindings=dict(FM_GITHUB_MEDIA_POLICY_SOURCE=str(validator),
               FM_GITHUB_MEDIA_POLICY_SHA256=hashlib.sha256(validator.read_bytes()).hexdigest(),
               FM_GITHUB_MEDIA_CMARK_SOURCE=str(parser),
               FM_GITHUB_MEDIA_CMARK_SHA256=hashlib.sha256(parser.read_bytes()).hexdigest())
 # Even a correctly hashed synthetic parser must never qualify this real gate.
 for case in ['fake-parser',*bindings,'stale-policy','stale-parser']:
  supplied=bindings.copy()
  if case in bindings: supplied.pop(case)
  if case=='stale-policy': supplied['FM_GITHUB_MEDIA_POLICY_SHA256']='0'*64
  if case=='stale-parser': supplied['FM_GITHUB_MEDIA_CMARK_SHA256']='0'*64
  trial={k:v for k,v in e.items() if k not in bindings}; trial.update(supplied)
  r=subprocess.run(['bash',str(guard)],env=trial,capture_output=True,text=True,timeout=10)
  assert r.returncode!=0 and 'binding' in r.stderr,(case,r.stdout,r.stderr)
 print('ok - real-policy guard honestly omits unqualified source and rejects stale/partial bindings',flush=True)
 for kind in ['pr','issue']:
  p,m,e=fixture(kind); add_video(p,m); body_value(p,kind,'<details><summary>Evidence</summary>\n\nmedia still owed')
  op=prepared(p,m,e); publish(p,m,e,'unsafe')
  before=body_value(p,kind); repair=body_approval(p,m,before+'\n\n</details>','repair')
  rec=json.loads(edit_body(p,m,e,repair).stdout)
  assert not (p/'native-calls').exists() and body_value(p,kind).startswith(before)
  edit_body(p,m,e,repair); assert len((p/'body-calls').read_text().splitlines())==1
  rec=json.loads(publish(p,m,e).stdout)
  # Move the exact ordered media block ahead of the retained disclosure.
  prose=before+'\n\n</details>'
  image='![Approved view]('+rec['items'][0]['attempts'][-1]['url']+')'
  video=rec['items'][1]['attempts'][-1]['url']
  draft='\n\n'+image+'\n\nApproved playback\n\n'+video+'\n\n'+prose.replace('media still owed\n','')
  approval=body_approval(p,m,draft); a=json.loads(approval.read_text()); a.update(id='final-1',retire_media_owed='media still owed\n'); approval.write_text(json.dumps(a))
  rec=json.loads(edit_body(p,m,e,approval).stdout)
  assert body_value(p,kind)==draft and len((p/'native-calls').read_text().splitlines())==2
  edit_body(p,m,e,approval); publish(p,m,e)
  assert len((p/'body-calls').read_text().splitlines())==2
  done=json.loads(complete(p,m,e,rec).stdout); assert done['state']=='delivery-complete'
  complete(p,m,e,rec); inspect(p,m,e)
  q,n,other=fixture(kind,shared=Path(e['FM_GITHUB_MEDIA_TEST_ROOT']))
  body_value(q,kind,draft); denied(q,n,other,'known confirmed receipts')
  f=Path(n['files'][0]['path']); f.write_bytes(f.read_bytes()+b'new bytes'); n['files'][0].update(size=f.stat().st_size,sha256=hashlib.sha256(f.read_bytes()).hexdigest())
  successor=prepared(q,n,other); inspect(p,m,e)
  publish(p,m,e,'historical'); assert (op/'operation.json').exists() and successor.exists()
  print('ok - '+kind+' repair/final/terminal handoff retains prose, receipts and history',flush=True)

 for case in ['draft','authority','body','actor','source','omit','order','label','prose','policy','legacy']:
  p,m,e=fixture(); add_video(p,m); prepared(p,m,e); rec=json.loads(publish(p,m,e).stdout)
  draft=final_draft(p,m); approval=body_approval(p,m,draft); a=json.loads(approval.read_text())
  if case=='draft': (p/'draft.md').write_text(draft+'changed')
  if case=='authority': a['authority']['explicit']=False
  if case=='body': body_value(p,value=body_value(p)+'drift')
  if case in ['actor','source']:
   remote=json.loads((p/'remote.json').read_text())
   if case=='actor': remote['/user']['login']='changed'
   else: remote['/repos/owner/repo/pulls/7']['head']['sha']='b'*40
   (p/'remote.json').write_text(json.dumps(remote))
  if case in ['omit','order','label','prose']:
   if case=='omit': draft=draft.replace('![Approved view]('+rec['items'][0]['attempts'][-1]['url']+')','')
   if case=='order': draft=draft.replace(rec['items'][0]['attempts'][-1]['url'],'SWAP').replace(rec['items'][1]['attempts'][-1]['url'],rec['items'][0]['attempts'][-1]['url']).replace('SWAP',rec['items'][1]['attempts'][-1]['url'])
   if case=='label': draft=draft.replace('Approved view','Different label')
   if case=='prose': draft=draft.replace('original body','removed prose')
   (p/'draft.md').write_text(draft); a['draft']['sha256']=hashlib.sha256(draft.encode()).hexdigest()
  if case=='policy': (p/'deny-draft').touch()
  if case=='legacy': (p/'legacy-validator').touch()
  approval.write_text(json.dumps(a)); edit_body(p,m,e,approval,'')
  assert not (p/'body-calls').exists() and len((p/'native-calls').read_text().splitlines())==2
  print('ok - body handoff refuses '+case,flush=True)

 for field in ['protocol','valid','repo','target_kind','body_sha256','labels_sha256']:
  p,m,e=fixture(); add_video(p,m); prepared(p,m,e); publish(p,m,e)
  approval=body_approval(p,m,final_draft(p,m)); (p/'mismatch-draft').write_text(field)
  edit_body(p,m,e,approval,'receipt mismatch'); assert not (p/'body-calls').exists()
 print('ok - new draft requires all six exact validator receipt fields',flush=True)

 p,m,e=fixture(); prepared(p,m,e); (p/'validator-timeout').touch()
 r=subprocess.run(['bash',str(cli),'publish','--operation','op1','--dependencies',str(deps(p))],env=e,capture_output=True,text=True,timeout=40)
 assert r.returncode!=0 and 'validator' in r.stderr and not (p/'native-calls').exists()
 op=Path(m['home'])/'data/task/github-media/op1'
 journals=[json.loads(f.read_text()) for f in op.glob('command-*.json')]
 assert all(j['state']=='stopped' and j['descendants_reaped'] for j in journals)
 assert any(j['phase']=='hygiene' and j['reason']=='deadline' for j in journals)
 print('ok - real validator deadline holds before mutation and proves owned children stopped',flush=True)

 for marker in ['body-no-write','body-nonzero','body-lose-readback']:
  p,m,e=fixture(); prepared(p,m,e); publish(p,m,e); approval=body_approval(p,m,final_draft(p,m)); (p/marker).touch()
  edit_body(p,m,e,approval,None if marker=='body-nonzero' else '')
  if marker=='body-lose-readback': (p/'bad-wire').unlink()
  edit_body(p,m,e,approval,'unknown' if marker=='body-no-write' else None)
  assert len((p/'body-calls').read_text().splitlines())==1 and len((p/'native-calls').read_text().splitlines())==1
  if marker=='body-no-write':
   publish(p,m,e,'unknown'); complete(p,m,e,json.loads(inspect(p,m,e).stdout),'unknown')
  print('ok - fixed body edit '+marker+' reconciles without replay',flush=True)

 # Terminal attestations are supplied, never manufactured by the command.
 p,m,e=fixture(); add_video(p,m); op=prepared(p,m,e); rec=json.loads(publish(p,m,e).stdout)
 complete(p,m,e,rec,'final approved')
 approval=body_approval(p,m,final_draft(p,m)); rec=json.loads(edit_body(p,m,e,approval).stdout)
 complete(p,m,e,rec); valid=json.loads((p/'completion.json').read_text())
 # Return to the pre-completion record to exercise each gate independently.
 (op/'operation.json').write_text(json.dumps(rec))
 for field,value in [('independent',False),('reviewer','operator'),('body_sha256','0'*64),('media',[])]:
  path=p/'bad-review.json'; path.write_text(json.dumps(dict(valid,**{field:value})))
  finish(p,m,e,path,''); assert json.loads(inspect(p,m,e).stdout)['state']!='delivery-complete'
 for field,value in [('playback',False),('url','https://example.invalid/asset'),('sha256','0'*64)]:
  bad=json.loads(json.dumps(valid)); bad['media'][1][field]=value
  path.write_text(json.dumps(bad)); finish(p,m,e,path,'')
 q,n,other=fixture(shared=Path(e['FM_GITHUB_MEDIA_TEST_ROOT'])); denied(q,n,other,'unresolved')
 body_value(p,value=body_value(p)+'\nremote drift'); finish(p,m,e,p/'completion.json','body drift')
 assert (op/'operation.json').exists(); denied(q,n,other,'unresolved')
 print('ok - incomplete/stale/mismatched independent review retains ownership',flush=True)

 # Repair must not remove existing prose or any media-owed line.
 p,m,e=fixture(); prepared(p,m,e)
 approval=body_approval(p,m,'replacement','repair'); edit_body(p,m,e,approval,'retain every')
 assert not (p/'body-calls').exists()
 # An intermediate partial upload cannot enter either body-edit phase.
 p,m,e=fixture(); add_video(p,m); op=prepared(p,m,e); (p/'head-drift').touch(); publish(p,m,e,'head')
 remote=json.loads((p/'remote.json').read_text()); remote['/repos/owner/repo/pulls/7']['head']['sha']='a'*40; (p/'remote.json').write_text(json.dumps(remote))
 for purpose in ['repair','final']:
  approval=body_approval(p,m,body_value(p)+'\naddition',purpose); edit_body(p,m,e,approval,'phase')
 assert not (p/'body-calls').exists()
 print('ok - no prose deletion or intermediate upload body edits',flush=True)

 # Even a never-launched body command freezes dependencies and cannot claim a
 # coincidental human write of the draft as its own effect after restart.
 p,m,e=fixture(); op=prepared(p,m,e); approval=body_approval(p,m,body_value(p)+'\nrepair','repair')
 hook=p/'hook'; hook.mkdir(); (hook/'sitecustomize.py').write_text('''import json,os,signal
original=os.replace
def replace(src,dst,*a,**kw):
 if str(dst).endswith('/operation.json'):
  with open(src) as f: record=json.load(f)
  if record.get('body_edits'):
   result=original(src,dst,*a,**kw); os.kill(os.getpid(),signal.SIGKILL); return result
 return original(src,dst,*a,**kw)
os.replace=replace
''')
 e['PYTHONPATH']=str(hook); edit_body(p,m,e,approval,''); del e['PYTHONPATH']
 rec=json.loads(inspect(p,m,e).stdout); assert rec['body_edits'][0]['state']=='unknown' and rec['dependencies']
 changed=p/'reviewed-validator-change'; changed.write_bytes(validator.read_bytes()+b'\n# changed\n')
 publish(p,m,e,'binding changed',dependency=deps(p,{'validator':changed}))
 body_value(p,value=(p/'draft.md').read_text()); edit_body(p,m,e,approval,'unknown')
 assert not (p/'body-calls').exists() and not (p/'native-calls').exists()
 print('ok - body journal freezes dependencies before launch and prevents false attribution',flush=True)

 for death in ['kill','deadline']:
  p,m,e=fixture(); op=prepared(p,m,e); publish(p,m,e); approval=body_approval(p,m,final_draft(p,m)); (p/'body-block').touch()
  if death=='deadline': e['FM_GITHUB_MEDIA_TEST_TIMEOUT']='1'
  args=['bash',str(cli),'edit-body','--operation','op1','--dependencies',str(deps(p)),'--approval',str(approval)]
  proc=subprocess.Popen(args,env=e,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
  fds=[]
  try:
   wait_for_file(p/'body-entered',proc)
   pids=[int((p/'body-pid').read_text()),int((p/'grandchild-pid').read_text())]; fds=[os.pidfd_open(pid) for pid in pids]
   q,n,other=fixture(shared=Path(e['FM_GITHUB_MEDIA_TEST_ROOT'])); denied(q,n,other,'busy')
   if death=='kill':
    q2,n2,e2=fixture(shared=Path(e['FM_GITHUB_MEDIA_TEST_ROOT'])); n2['target']['object_id']='O_other'
    remote=json.loads((q2/'remote.json').read_text()); remote['/repos/owner/repo/pulls/7']['node_id']='O_other'; (q2/'remote.json').write_text(json.dumps(remote))
    prepared(q2,n2,e2)
   if death=='kill': proc.kill()
   proc.communicate(timeout=12); wait_gone(pids)
   for _ in range(200):
    if all(json.loads(f.read_text())['state']=='stopped' for f in op.glob('command-*.json')): break
    time.sleep(.02)
   else: raise AssertionError('body guardian ownership remains unsettled')
   edit_body(p,m,e,approval,'unknown'); denied(q,n,other,'unresolved')
   assert len((p/'body-calls').read_text().splitlines())==1
   journal=next(op.glob('command-*.json')); saved=json.loads(journal.read_text()); saved['state']='running'; journal.write_text(json.dumps(saved))
   edit_body(p,m,e,approval,'ownership')
   print('ok - body '+death+' retains unknown and reaps exact detached descendants',flush=True)
  finally:
   if proc.poll() is None: proc.kill(); proc.wait(timeout=5)
   for fd in fds:
    try: signal.pidfd_send_signal(fd,signal.SIGKILL)
    except ProcessLookupError: pass
    os.close(fd)

def cleanup_approval(p,m,draft):
 path=body_approval(p,m,draft,'repair'); a=json.loads(path.read_text())
 a['reviewed_cleanup']=dict(before_body_sha256=a['before_body_sha256'],draft_sha256=a['draft']['sha256'],provenance='Owner explicitly reviewed this exact cleanup, including deletions')
 path.write_text(json.dumps(a)); return path

def resume_prepare(p,m,e,needle=None):
 args=command(p,m,e); args.insert(3,'--resume')
 r=subprocess.run(args,env=e,capture_output=True,text=True,timeout=15)
 assert (r.returncode==0) if needle is None else (r.returncode!=0 and needle in r.stderr),(r.returncode,r.stderr)
 return r

def u4_fix_regressions():
 failures=[]
 def check(name,fn):
  try: fn(); print('ok - '+name,flush=True)
  except AssertionError as exc: failures.append(name); print('not ok - '+name+': '+str(exc),flush=True)

 def cleanup():
  for kind in ['pr','issue']:
   p,m,e=fixture(kind); add_video(p,m)
   before='Retained prose\nSYNTHETIC_PRIVATE_MARKER\n'; clean='Retained prose\n'
   body_value(p,kind,before); op=prepared(p,m,e); (p/'deny-private').touch()
   publish(p,m,e,'validator refused'); approval=body_approval(p,m,clean,'repair')
   edit_body(p,m,e,approval,'retain every')
   approval=cleanup_approval(p,m,clean); rec=json.loads(edit_body(p,m,e,approval).stdout)
   assert body_value(p,kind)==clean and rec['baseline_body_sha256']==hashlib.sha256(before.encode()).hexdigest()
   assert rec['expected_body_sha256']==hashlib.sha256(clean.encode()).hexdigest()
   edit_body(p,m,e,approval); assert len((p/'body-calls').read_text().splitlines())==1
   assert not (p/'native-calls').exists()
   calls=[json.loads(x) for x in (p/'hygiene-calls').read_text().splitlines()]
   assert any(x['body']==clean for x in calls) and any(x['body'].count('user-attachments/assets/')==2 for x in calls)
   rec=json.loads(publish(p,m,e).stdout)
   assert rec['items'][0]['attempts'][0]['pre_body']==clean
   assert (p/'native-hashes').read_text().splitlines()==[f['sha256'] for f in m['files']]
   expected=hashlib.sha256(clean.encode()).hexdigest()
   for item in rec['items']:
    a=item['attempts'][-1]; assert a['pre_body_sha256']==hashlib.sha256(a['pre_body'].encode()).hexdigest()==expected
    expected=a['post_body_sha256']
   assert rec['expected_body_sha256']==expected
   assert rec['expected_body_sha256']==hashlib.sha256(body_value(p,kind).encode()).hexdigest()

 def renewal():
  for kind in ['pr','issue']:
   p,m,e=fixture(kind); add_video(p,m); (p/'read-error').touch(); denied(p,m,e,'authentication')
   op=Path(m['home'])/'data/task/github-media/op1'; failed=(op/'operation.json').read_bytes()
   journals={f.name:f.read_bytes() for f in op.glob('command-*.json')}
   snapshots={f.name:f.read_bytes() for f in op.glob('[0-9]*')}
   (p/'read-error').unlink()
   q,n,other=fixture(kind,shared=Path(e['FM_GITHUB_MEDIA_TEST_ROOT'])); denied(q,n,other,'unresolved')
   denied(p,m,e,'unresolved')
   rec=json.loads(resume_prepare(p,m,e).stdout); assert rec['state']=='prepared' and rec['manifest']==m
   assert any(f.read_bytes()==failed for f in op.glob('preparation-*.json'))
   assert all((op/name).read_bytes()==data for name,data in {**journals,**snapshots}.items())
   assert not (p/'body-calls').exists() and not (p/'native-calls').exists()
   publish(p,m,e); resume_prepare(p,m,e,'preparing')
   assert len((p/'native-calls').read_text().splitlines())==2

 def completion():
  for kind in ['pr','issue']:
   for failure in ['missing-artifact','hygiene']:
    p,m,e=fixture(kind); add_video(p,m); op=prepared(p,m,e); publish(p,m,e)
    rec=json.loads(edit_body(p,m,e,body_approval(p,m,final_draft(p,m))).stdout)
    path=complete(p,m,e,rec,review_only=True); old=json.loads(path.read_text())
    if failure=='missing-artifact': Path(old['media'][1]['artifact']['path']).unlink()
    else: (p/'deny-draft').touch()
    # A declined ordinal snapshot from the earlier contract is also retained.
    legacy=op/'review-0'; legacy.write_bytes(b'OLDER DECLINED SYNTHETIC ARTIFACT'); legacy.chmod(0o600)
    finish(p,m,e,path,''); assert 'completion_review' not in json.loads(inspect(p,m,e).stdout)
    retained={f.name:f.read_bytes() for f in op.glob('review-*')}
    if failure=='hygiene': (p/'deny-draft').unlink()
    blocks='![Approved view]('+rec['items'][0]['attempts'][-1]['url']+')\n\nApproved playback\n\n'+rec['items'][1]['attempts'][-1]['url']
    draft='original body\n\n'+blocks+'\n\n'
    approval=body_approval(p,m,draft,offset=len('original body')); a=json.loads(approval.read_text()); a['id']='body-2'; approval.write_text(json.dumps(a))
    rec=json.loads(edit_body(p,m,e,approval).stdout); assert body_value(p,kind)==draft
    oldpath=p/'old-review.json'; oldpath.write_text(json.dumps(old)); finish(p,m,e,oldpath,'final body')
    path=complete(p,m,e,rec,review_only=True,evidence_bytes=b'FRESH SYNTHETIC BODY-BOUND REVIEW - NOT UI PROOF')
    done=json.loads(finish(p,m,e,path).stdout); assert done['state']=='delivery-complete'
    sealed=(op/'operation.json').read_bytes(); finish(p,m,e,path); assert (op/'operation.json').read_bytes()==sealed
    assert all((op/name).read_bytes()==data for name,data in retained.items())
    complete(p,m,e,rec,'sealed',evidence_bytes=b'OTHER SYNTHETIC REVIEW - NOT UI PROOF')
    assert len((p/'native-calls').read_text().splitlines())==2 and len((p/'body-calls').read_text().splitlines())==2
    assert done['expected_body_sha256']==hashlib.sha256(draft.encode()).hexdigest()

 def cleanup_denials():
  for case in ['before','draft','actor','source','external-drift','provenance','cumulative',
               'protocol','valid','repo','target_kind','body_sha256','labels_sha256']:
   p,m,e=fixture(); add_video(p,m); body_value(p,value='Retained\nSYNTHETIC_PRIVATE_MARKER\n'); prepared(p,m,e)
   (p/'deny-private').touch(); approval=cleanup_approval(p,m,'Retained\n')
   a=json.loads(approval.read_text())
   if case in ['before','draft']: a['reviewed_cleanup'][case+'_body_sha256' if case=='before' else 'draft_sha256']='0'*64
   elif case=='actor': a['actor']='wrong-owner'
   elif case=='source': a['source']['head']='b'*40
   elif case=='external-drift': body_value(p,value='Retained\n')
   elif case=='provenance': a['reviewed_cleanup']['provenance']=''
   elif case=='cumulative': (p/'deny-cumulative').touch()
   else: (p/'mismatch-validator').write_text(case)
   approval.write_text(json.dumps(a)); before=body_value(p); edit_body(p,m,e,approval,'')
   assert body_value(p)==before and not (p/'body-calls').exists() and not (p/'native-calls').exists(),case
  p,m,e=fixture(); prepared(p,m,e); approval=cleanup_approval(p,m,'Reviewed clean prose')
  (p/'body-no-write').touch(); edit_body(p,m,e,approval,'unknown'); edit_body(p,m,e,approval,'unknown')
  (p/'body-no-write').unlink(); publish(p,m,e,'unknown')
  assert len((p/'body-calls').read_text().splitlines())==1 and not (p/'native-calls').exists()
  changed=p/'changed-validator'; changed.write_bytes(validator.read_bytes()+b'\n# changed dependency\n')
  publish(p,m,e,'binding changed',dependency=deps(p,{'validator':changed}))

 def recovery_denials():
  for case in ['approval','actor','repository','object','head','snapshot','snapshot-during-read','missing-snapshot','unknown','malformed','attach','body-edit','item-attempt']:
   p,m,e=fixture(); (p/'read-error').touch(); denied(p,m,e,'authentication'); (p/'read-error').unlink()
   op=Path(m['home'])/'data/task/github-media/op1'; remote=json.loads((p/'remote.json').read_text())
   if case=='approval': m['authority']['provenance']='changed approval'
   elif case=='actor': remote['/user']['login']='wrong-owner'
   elif case=='repository': remote['/repos/owner/repo']['node_id']='R_wrong'
   elif case=='object': remote['/repos/owner/repo/pulls/7']['node_id']='O_wrong'
   elif case=='head': remote['/repos/owner/repo/pulls/7']['head']['sha']='b'*40
   elif case=='snapshot': (op/'0.png').write_bytes(b'partial or corrupt bytes')
   elif case=='snapshot-during-read': (p/'mutate').write_text(str(op/'0.png'))
   elif case=='missing-snapshot': (op/'0.png').unlink()
   elif case=='item-attempt':
    rec=json.loads((op/'operation.json').read_text()); rec['items'][0]['attempts']=[dict(state='unknown')]; (op/'operation.json').write_text(json.dumps(rec))
   else:
    path=next(op.glob('command-*.json')); j=json.loads(path.read_text())
    if case=='unknown': j['state']='running'
    elif case=='malformed': j.pop('descendants_reaped')
    else: j['phase']=case
    path.write_text(json.dumps(j))
   (p/'remote.json').write_text(json.dumps(remote)); retained={f.name:f.read_bytes() for f in op.iterdir()}
   resume_prepare(p,m,e,'')
   assert all((op/name).read_bytes()==data for name,data in retained.items() if not (case=='snapshot-during-read' and name=='0.png')),case
   assert json.loads((op/'operation.json').read_text())['state']=='preparing'
   assert not (p/'native-calls').exists() and not (p/'body-calls').exists(),case

 def partial_and_live():
  # Missing later source fails before making its snapshot; original approved
  # bytes can be supplied later without restaging or resetting earlier bytes.
  p,m,e=fixture(); add_video(p,m); video=Path(m['files'][1]['path']); data=video.read_bytes(); video.unlink()
  denied(p,m,e,'readable'); op=Path(m['home'])/'data/task/github-media/op1'
  first=(op/'0.png').read_bytes(); video.write_bytes(data)
  rec=json.loads(resume_prepare(p,m,e).stdout); assert rec['state']=='prepared' and (op/'0.png').read_bytes()==first
  assert not (p/'native-calls').exists() and not (p/'body-calls').exists()
  # Legacy empty items can adopt only intact approved snapshots after a read
  # failure. Unknown/mutating entries above are never normalized away.
  p,m,e=fixture(); (p/'read-error').touch(); denied(p,m,e,'authentication'); (p/'read-error').unlink()
  op=Path(m['home'])/'data/task/github-media/op1'; rec=json.loads((op/'operation.json').read_text()); rec['items']=[]
  (op/'operation.json').write_text(json.dumps(rec,sort_keys=True)+'\n'); (p/'block').touch()
  args=command(p,m,e); args.insert(3,'--resume')
  proc=subprocess.Popen(args,env=e,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
  try:
   wait_for_file(p/'entered',proc); resume_prepare(p,m,e,'busy')
   q,n,other=fixture(shared=Path(e['FM_GITHUB_MEDIA_TEST_ROOT'])); denied(q,n,other,'busy')
   (p/'release').touch(); out,err=proc.communicate(timeout=15); assert proc.returncode==0,err
   assert json.loads(out)['items'][0]['state']=='unattempted'
   assert not (p/'native-calls').exists() and not (p/'body-calls').exists()
  finally:
   if proc.poll() is None: proc.terminate(); proc.communicate(timeout=10)

 def completion_receipts():
  p,m,e=fixture(); add_video(p,m); op=prepared(p,m,e); publish(p,m,e)
  rec=json.loads(edit_body(p,m,e,body_approval(p,m,final_draft(p,m))).stdout)
  path=complete(p,m,e,rec,review_only=True)
  for field in ['protocol','valid','repo','target_kind','body_sha256','labels_sha256']:
   (p/'mismatch-validator').write_text(field); finish(p,m,e,path,'receipt mismatch')
   assert 'completion_review' not in json.loads(inspect(p,m,e).stdout)
  (p/'mismatch-validator').unlink()
  retained={f.name:f.read_bytes() for f in op.glob('review-*')}
  path=complete(p,m,e,rec,review_only=True,evidence_bytes=b'FRESH SYNTHETIC RECEIPT REVIEW - NOT UI PROOF')
  finish(p,m,e,path)
  assert all((op/name).read_bytes()==data for name,data in retained.items())
  assert len((p/'native-calls').read_text().splitlines())==2 and len((p/'body-calls').read_text().splitlines())==1
  q,n,other=fixture(shared=Path(e['FM_GITHUB_MEDIA_TEST_ROOT'])); body_value(q,value=body_value(p))
  denied(q,n,other,'known confirmed receipts')
  f=Path(n['files'][0]['path']); f.write_bytes(f.read_bytes()+b'disjoint'); n['files'][0].update(size=f.stat().st_size,sha256=hashlib.sha256(f.read_bytes()).hexdigest())
  prepared(q,n,other); inspect(p,m,e); publish(p,m,e,'historical')
  claim=json.loads(next(Path(e['FM_GITHUB_MEDIA_TEST_ROOT']).glob('*.json')).read_text())
  assert claim['history'][0]['operation_dir']==str(op) and all((op/name).read_bytes()==data for name,data in retained.items())

 for name,fn in [('U4-J1 explicit reviewed cleanup',cleanup),('U4-J2 renewed preparation',renewal),('U4-H1 fresh completion after refusal and placement',completion),('cleanup exact authority and policy denials',cleanup_denials),('preparation context and history denials',recovery_denials),('partial staging and live owner',partial_and_live),('completion six fields and successor history',completion_receipts)]: check(name,fn)
 assert not failures,failures

if os.environ.get('FM_GITHUB_MEDIA_U4_FIX_ONLY')=='1':
 u4_fix_regressions(); sys.exit()

if os.environ.get('FM_GITHUB_MEDIA_U4_ONLY')=='1':
 u4_regressions(); sys.exit()

# U3 fix regressions use only the public Bash interface and synthetic journals.
def u3_fix_regressions():
 failures=[]
 def check(name,case):
  try:
   case(); print('ok - '+name,flush=True)
  except AssertionError as exc:
   failures.append(name); print('not ok - '+name+': '+str(exc),flush=True)

 def correction(name,migration=False):
  p,m,e=fixture(); op=prepared(p,m,e)
  bad=p/('reviewed-legacy-validator' if name=='validator' else 'unsupported-native')
  bad.write_bytes(b'import sys; sys.exit(0)\n' if name=='validator' else native.read_bytes().replace(b"'2.102.0'",b"'0.0.0'"))
  bad.chmod(0o700)
  dependency=deps(p,{name:bad}); old=json.loads(dependency.read_text())
  publish(p,m,e,'receipt' if name=='validator' else 'runtime',dependency=dependency)
  refused=json.loads(inspect(p,m,e).stdout)
  assert all(i['state']=='unattempted' and not i.get('attempts') for i in refused['items'])
  assert not (p/'native-calls').exists()
  if migration:
   old['schema']=1; old.pop('parser')
   refused['dependencies']=old; (op/'operation.json').write_text(json.dumps(refused))
  corrected=p/('reviewed-'+name); corrected.write_bytes((validator if name=='validator' else native).read_bytes()+b'\n# reviewed correction\n'); corrected.chmod(0o700)
  dependency=deps(p,{name:corrected})
  result=json.loads(publish(p,m,e,dependency=dependency).stdout)
  assert result['state']=='published-confirmed' and result['dependencies']==json.loads(dependency.read_text())
  assert len((p/'native-calls').read_text().splitlines())==1
  assert migration or 'dependencies' not in refused, 'pre-attempt refusal froze dependencies'
  q,n,other=fixture(shared=Path(e['FM_GITHUB_MEDIA_TEST_ROOT'])); denied(q,n,other,'unresolved')
 for name in ['validator','native']:
  check('same operation accepts corrected reviewed '+name,lambda name=name:correction(name))
 check('settled legacy pre-attempt binding migrates',lambda:correction('validator',True))

 def frozen(outcome):
  p,m,e=fixture(); op=prepared(p,m,e)
  if outcome=='unknown': (p/'no-append').touch()
  publish(p,m,e,'unknown' if outcome=='unknown' else None)
  original=(op/'operation.json').read_bytes()
  for name,source in [('validator',validator),('native',native),('read',transport),('parser',parser)]:
   replacement=p/('changed-'+name); replacement.write_bytes(source.read_bytes()+b'\n# different reviewed dependency\n'); replacement.chmod(0o700)
   if name=='read': e['FM_GITHUB_MEDIA_TEST_READ']=str(replacement)
   publish(p,m,e,'binding changed',dependency=deps(p,{name:replacement}))
   e['FM_GITHUB_MEDIA_TEST_READ']=str(transport)
   assert (op/'operation.json').read_bytes()==original
   assert len((p/'native-calls').read_text().splitlines())==1
 for outcome in ['unknown','confirmed']:
  check(outcome+' attempt freezes all dependencies',lambda outcome=outcome:frozen(outcome))

 def history(uncertain=False):
  p,m,e=fixture(); op=prepared(p,m,e); dependency=deps(p)
  rec=json.loads((op/'operation.json').read_text()); rec.update(state='held',dependencies=json.loads(dependency.read_text()))
  (op/'operation.json').write_text(json.dumps(rec))
  journal=next(op.glob('command-*.json')); command_record=json.loads(journal.read_text())
  command_record['phase']='attach'
  if uncertain: command_record['state']='running'
  journal.write_text(json.dumps(command_record))
  replacement=p/'changed-validator'; replacement.write_bytes(validator.read_bytes()+b'\n# changed\n')
  publish(p,m,e,'ownership' if uncertain else 'binding changed',dependency=deps(p,{'validator':replacement}))
  assert not (p/'native-calls').exists() and json.loads((op/'operation.json').read_text())==rec
 check('settled attach history cannot migrate an unattempted item',history)
 check('free lease with unknown command ownership cannot migrate',lambda:history(True))

 def disclosure(body,kind):
  p,m,e=fixture(kind); add_video(p,m)
  key='/repos/owner/repo/'+('pulls' if kind=='pr' else 'issues')+'/7'
  remote=json.loads((p/'remote.json').read_text()); remote[key]['body']=body; (p/'remote.json').write_text(json.dumps(remote))
  prepared(p,m,e); publish(p,m,e)
  expected=body.rstrip(' \t\r\n')+'\n\n![Approved view](https://github.com/user-attachments/assets/11111111-1111-1111-1111-000000000001)\n\nhttps://github.com/user-attachments/assets/11111111-1111-1111-1111-000000000002'
  assert json.loads((p/'remote.json').read_text())[key]['body']==expected
  assert len((p/'native-calls').read_text().splitlines())==2
  calls=[json.loads(line) for line in (p/'hygiene-calls').read_text().splitlines()]
  assert calls[0]['body']==body and calls[-1]['body']==expected
 bodies=[
  'Existing review evidence\n\n<details>\n<summary>Checks</summary>\n\nChecks passed.\n\n</details>\n \t\r\n',
  '<details><summary>Checks with `inline code` and <code>literal [ `</code></summary>\n\n<!-- complete comment [ ` -->\n<details><summary>Nested checks</summary>\n\nPassed.\n\n</details>\n</details>\n',
  'Existing evidence with `<details>` as code.\n\n```html\n<details>unfinished example\n```\n\n<!-- complete comment -->\n',
  '<details>\n<summary>Example commands</summary>\n\n```html\n<script>literal fenced example\n```\n\n</details>\n',
  '<!-- closed -\\x-> -->\n<!-- literal \\` and \\[ -->\n<!-- closed -\\-->\n',
  '`literal backslash\\`\n<!-- complete comment -->\n',
  '``literal \\` backtick``\n<!-- complete comment -->\n',
 ]
 large_comment_body = ('<!-- bounded comment fixture -->\r\n' * 1750 +
                       '<!-- multiline comment begins\r\nand ends here -->\r\n'
                       '<details>\r\n'
                       '<summary>Multiline close control</summary\r\n>\r\n'
                       'Checks passed.\r\n'
                       '</details\r\n>\r\n')
 assert len(large_comment_body.encode('utf-8')) <= 65536
 bodies.append(large_comment_body)
 for kind in ['pr','issue']:
  for ordinal,body in enumerate(bodies):
   check(kind+' closed disclosure/code/comment append '+str(ordinal),lambda body=body,kind=kind:disclosure(body,kind))

 def unsafe(body):
  p,m,e=fixture(); remote=json.loads((p/'remote.json').read_text()); remote['/repos/owner/repo/pulls/7']['body']=body; (p/'remote.json').write_text(json.dumps(remote))
  prepared(p,m,e); result=publish(p,m,e,'unsafe')
  output=result.stdout+result.stderr
  assert result.returncode==1 and body not in output and 'Traceback' not in output
  assert json.loads(inspect(p,m,e).stdout)['state']=='held'
  assert not (p/'native-calls').exists()
 for body in ['<details><summary>Checks</summary>open','<details><summary>Checks</details></summary>',
              '<!-- unclosed -\\x->','<!-- unclosed -\\!->','<!-- unclosed -x->',
              '`literal backslash\\`\n<!-- unfinished',
              '``literal \\` backtick``\n<!-- unfinished',
              '<details><summary>Checks</summary></details></details>','<!-- unfinished','<!-- malformed --!>',
              '<details><summary>Checks</summary><!-- unfinished</details>','<details><summary>Checks</summary></details',
              '<script>raw absorption','<pre>raw absorption','<textarea>raw absorption',
              '<div>unsupported even when closed</div>','<details open><summary>Unsupported attribute</summary></details>',
              '<summary>Unowned summary</summary>','<details>Missing summary</details>',
              '<details><summary>Checks</summary><code>unclosed</details>',
              '<details><summary>Checks</summary><summary>Repeated summary</summary></details>',
              '<![invalid-synthetic-private-body]>','<!DOCTYPE html>','<?processing instruction?>',
              '<details><summary>Checks</summary>\r\r```\rliteral\r```\r\r</details>',
              '<details><summary>Checks</summary>\n```html\n<script>raw absorption\n```\n</details>',
              '<details><summary>`<script>raw absorption`</summary></details>']:
  check('unsafe HTML boundary '+repr(body),lambda body=body:unsafe(body))

 # Indented content outside fences is deliberately unsupported: a literal
 # close must never pop an HTML frame, even if a real close follows it.
 for indent in ['    ','\t',' \t']:
  for ending in ['', '\n\n</details>']:
   body='<details><summary>Checks</summary>\n\n'+indent+'</details>'+ending
   check('unsupported indented disclosure '+repr(body),lambda body=body:unsafe(body))
 for body in ['escaped \\` delimiter','escaped \\<details>','escaped \\[ delimiter']:
  check('unsupported prose escape '+repr(body),lambda body=body:unsafe(body))

 def disclosure_denied(marker,body,needle):
  p,m,e=fixture(); add_video(p,m); (p/marker).touch()
  remote=json.loads((p/'remote.json').read_text()); remote['/repos/owner/repo/pulls/7']['body']=body; (p/'remote.json').write_text(json.dumps(remote))
  prepared(p,m,e); result=publish(p,m,e,needle)
  assert not (p/'native-calls').exists() and body not in result.stderr
  if marker=='deny-cumulative': assert (p/'hygiene-calls').exists()
 check('closed disclosure still requires hygiene approval',lambda:disclosure_denied('deny-cumulative',bodies[0],'validator'))
 check('closed comment still refuses native snapshot rewriting',lambda:disclosure_denied('unused-marker','<!-- 0.png -->','snapshot'))
 assert not failures, failures

u3_fix_regressions()

# U3 regression: a prepared operation must fail closed at the explicit
# validator dependency, rather than exposing a successful publication stub.
p,m,e=fixture(); r=run(p,m,e); assert r.returncode==0,r.stderr
r=subprocess.run(['bash',str(cli),'publish','--operation',m['operation'],
                  '--dependencies',str(p/'missing-dependencies.json')],
                 env=e,capture_output=True,text=True,timeout=5)
assert r.returncode==1 and 'dependency' in r.stderr, (r.returncode,r.stderr)
assert json.loads(inspect(p,m,e).stdout)['items'][0]['state']=='unattempted'
print('ok - publication refuses missing reviewed dependencies before attempt')

# Denial and restart contracts come first so an absent command is meaningful red.
p,m,e=fixture(); del m['authority']; denied(p,m,e,'authority')
p,m,e=fixture(); m['files'][0]['sha256']='0'*64; denied(p,m,e,'digest')
p,m,e=fixture(); (p/'bad-wire').touch(); denied(p,m,e,'gh-axi response')
for kind in ['pr','issue']:
 p,m,e=fixture(kind,author='approved-user'); r=run(p,m,e)
 assert r.returncode == 0, r.stderr
 receipt=json.loads(r.stdout); assert receipt['state']=='prepared'
 op=Path(receipt['operation_dir'])
 record=json.loads((op/'operation.json').read_text())
 assert record['manifest']==m and record['items'][0]['state']=='unattempted'
 staged=op/record['items'][0]['snapshot']
 assert hashlib.sha256(staged.read_bytes()).hexdigest()==m['files'][0]['sha256']
 assert record['baseline_body_sha256']==hashlib.sha256(b'original body').hexdigest()
 for path in [op,op/'operation.json',staged,Path(e['FM_GITHUB_MEDIA_TEST_ROOT'])]:
  assert path.stat().st_mode & 0o077 == 0, path
 assert json.loads(inspect(p,m,e).stdout)==record
 original=staged.read_bytes(); staged.write_bytes(b'x'*len(original)); inspect(p,m,e,'snapshot digest'); staged.write_bytes(original)
 denied(p,m,e,'unresolved')
 (op/'operation.json').chmod(0)
 inspect(p,m,e,'readable')
 denied(p,m,e,'unresolved')
 print('ok - '+kind+' prepared private bytes; restart cannot replay even unreadable receipt')
for field,value,needle in [('authority',{},'authority'),('actor','wrong','actor'),('attempt',0,'attempt'),('home','/wrong','home')]:
 p,m,e=fixture(); m[field]=value; denied(p,m,e,needle)
for field,value in [('object_id','O_wrong'),('repository_id','R_wrong'),('number',8)]:
 p,m,e=fixture(); m['target'][field]=value; denied(p,m,e,'target')
p,m,e=fixture(); m['source']['head']='b'*40; denied(p,m,e,'head')
p,m,e=fixture(); remote=json.loads((p/'remote.json').read_text()); remote['/repos/owner/repo']['permissions']['push']=False; remote['/repos/owner/repo/pulls/7']['user']={'login':'other-user'}; (p/'remote.json').write_text(json.dumps(remote)); denied(p,m,e,'qualified repository-push subset')
writer_limit='writer capability is outside the qualified repository-push subset; reconcile the retained operation instead of retrying prepare'
for kind in ['pr','issue']:
 p,m,e=fixture(kind,author='approved-user'); remote=json.loads((p/'remote.json').read_text())
 remote['/repos/owner/repo']['permissions']['push']=False; (p/'remote.json').write_text(json.dumps(remote))
 r=run(p,m,e)
 assert r.returncode != 0 and writer_limit in r.stderr, (kind,r.returncode,r.stdout,r.stderr)
 calls=[json.loads(line) for line in (p/'calls').read_text().splitlines()]
 assert [call[:2] for call in calls] == [['api','GET'],['api','GET']], (kind,calls)
 assert [call[2] for call in calls] == ['/user','/repos/owner/repo'], (kind,calls)
 print('ok - refused unqualified author-only '+kind+' writer without remote mutation')
help_result=subprocess.run(['bash',str(cli),'--help'],capture_output=True,text=True,timeout=5)
assert help_result.returncode == 0, help_result.stderr
assert 'Only repository-push writers are currently qualified' in help_result.stdout, help_result.stdout
assert 'Author-only issue/PR body permissions are not qualified yet' in help_result.stdout, help_result.stdout
assert 'prepare --resume explicitly continues only the current owner' in help_result.stdout, help_result.stdout
assert 'all other unresolved states require their own reconciliation' in help_result.stdout, help_result.stdout
print('ok - public help declares writer qualification and reconciliation limit')
for mode,needle in [('symlink','regular'),('directory','regular'),('fifo','regular'),('empty','empty'),('signature','signature'),('unreadable','readable'),('large','limit')]:
 p,m,e=fixture(); f=Path(m['files'][0]['path']); f.unlink()
 if mode=='symlink': f.symlink_to(p/'remote.json')
 elif mode=='directory': f.mkdir()
 elif mode=='fifo': os.mkfifo(f)
 else:
  f.write_bytes(b'' if mode=='empty' else b'wrong signature' if mode=='signature' else b'\x89PNG\r\n\x1a\n'+b'x'*10)
  if mode=='unreadable': f.chmod(0)
  if mode=='large':
   with f.open('r+b') as out: out.truncate(10*1024*1024+1)
  m['files'][0]['size']=f.stat().st_size
  m['files'][0]['sha256']=hashlib.sha256(f.read_bytes()).hexdigest() if mode!='unreadable' else '0'*64
 denied(p,m,e,needle)
p,m,e=fixture(); denied(p,m,e,'listed',extra=[str(p/'other')])
p,m,e=fixture(); m['files']*=2; denied(p,m,e,'duplicate')
p,m,e=fixture(); m['files'][0]['label']='![unsafe](url)'; denied(p,m,e,'label')
p,m,e=fixture(); m['files'][0]['media_type']='video/webm'; denied(p,m,e,'unsupported')
for suffix,mime,data in [('.jpg','image/jpeg',b'\xff\xd8\xffsynthetic'),('.gif','image/gif',b'GIF89asynthetic'),('.mp4','video/mp4',b'\x00\x00\x00\x18ftypisom\x00\x00\x00\x00isommp42')]:
 p,m,e=fixture(); f=p/('media'+suffix); f.write_bytes(data)
 m['files'][0].update(path=str(f),media_type=mime,size=len(data),sha256=hashlib.sha256(data).hexdigest())
 r=run(p,m,e); assert r.returncode==0,r.stderr
 print('ok - supported signature '+mime)
p,m,e=fixture(); m['files'][0]['path']=str(p/'image.jpg'); (p/'image.png').rename(p/'image.jpg'); denied(p,m,e,'signature')
p,m,e=fixture(); second=dict(m['files'][0],path=str(p/'second.png'),sha256='1'*64); Path(second['path']).write_bytes(b'bad'); m['files'].append(second); denied(p,m,e,'size'); assert not (p/'calls').exists()
p,m,e=fixture(); (p/'parent-link').symlink_to(p,target_is_directory=True); m['files'][0]['path']=str(p/'parent-link/image.png'); denied(p,m,e,'regular')
p,m,e=fixture(); e['FM_TEST_SEAM']='0'; denied(p,m,e,'test seam')

# Fault injection at the OS read seam changes the synthetic regular file after
# the first read starts. It is loaded only in this subprocess, not production.
p,m,e=fixture(); f=Path(m['files'][0]['path']); f.write_bytes(b'\x89PNG\r\n\x1a\n'+b'x'*200000)
m['files'][0].update(size=f.stat().st_size,sha256=hashlib.sha256(f.read_bytes()).hexdigest())
hook=p/'hook'; hook.mkdir(); (hook/'sitecustomize.py').write_text('''import os
original_read=os.read
def read(fd,n):
 data=original_read(fd,n)
 target=os.environ.get('MUTATE_SOURCE')
 if target and os.fstat(fd).st_ino==os.stat(target).st_ino:
  os.environ.pop('MUTATE_SOURCE')
  with open(target,'r+b') as f:
   f.seek(100000); f.write(b'changed during staging')
 return data
os.read=read
''')
e.update(PYTHONPATH=str(hook),MUTATE_SOURCE=str(f)); denied(p,m,e,'digest'); assert not (p/'calls').exists()
assert b'changed during staging' in f.read_bytes()
p,m,e=fixture(); (p/'mutate').write_text(str(Path(m['home'])/'data/task/github-media/op1/0.png')); denied(p,m,e,'snapshot size')

# A forged owner, malformed journal or unreadable global claim never permits
# takeover, even though no process holds its kernel lock.
p,m,e=fixture(); r=run(p,m,e); assert r.returncode==0,r.stderr
op=Path(json.loads(r.stdout)['operation_dir']); claim=next(Path(e['FM_GITHUB_MEDIA_TEST_ROOT']).glob('*.json'))
c=json.loads(claim.read_text()); c['home']='/unowned'; claim.write_text(json.dumps(c)); inspect(p,m,e,'ownership'); denied(p,m,e,'unresolved')
claim.write_text('{interrupted'); denied(p,m,e,'unresolved'); claim.chmod(0); denied(p,m,e,'unresolved')
p,m,e=fixture(); f=Path(m['files'][0]['path']);
with f.open('r+b') as out: out.truncate(10*1024*1024)
m['files'][0]['size']=f.stat().st_size; m['files'][0]['sha256']=hashlib.sha256(f.read_bytes()).hexdigest()
(p/'mutate').write_text(str(f)); r=run(p,m,e); assert r.returncode==0,r.stderr
op=Path(json.loads(r.stdout)['operation_dir']); rec=json.loads((op/'operation.json').read_text()); assert hashlib.sha256((op/rec['items'][0]['snapshot']).read_bytes()).hexdigest()==m['files'][0]['sha256']; assert f.read_bytes()==b'changed after snapshot'
print('ok - exact size boundary and source replacement cannot replace staged bytes')

# A real blocked subprocess holds the target lease across homes. Death frees
# the kernel lease but leaves the journal, so no PID heuristics grant replay.
shared=root/'shared'
p,m,e=fixture(shared=shared); (p/'block').touch()
proc=subprocess.Popen(command(p,m,e),env=e,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
transport_pid=None
try:
 for _ in range(150):
  if (p/'entered').exists(): break
  assert proc.poll() is None,proc.communicate()
  time.sleep(.02)
 else: raise AssertionError('transport did not enter')
 transport_pid=int((p/'transport-pid').read_text())
 q,n,other=fixture(shared=shared); denied(q,n,other,'busy')
 q,n,other=fixture(shared=shared); n['target']['object_id']='O_other'
 remote=json.loads((q/'remote.json').read_text()); remote['/repos/owner/repo/pulls/7']['node_id']='O_other'; (q/'remote.json').write_text(json.dumps(remote))
 assert run(q,n,other).returncode==0
 # SIGTERM exercises the helper's cleanup of its separately owned read group.
 proc.terminate(); proc.wait(timeout=3)
 for _ in range(100):
  try: os.kill(transport_pid,0)
  except ProcessLookupError: break
  time.sleep(.02)
 else: raise AssertionError('owned read process survived interruption')
 q,n,other=fixture(shared=shared); denied(q,n,other,'unresolved')
 for lock in shared.glob('*.lock'):
  with lock.open('r+b') as f: fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
 print('ok - cross-home contention, unrelated target, real process death and free-lock refusal')
finally:
 if proc.poll() is None: os.killpg(proc.pid,signal.SIGKILL); proc.wait(timeout=3)
 if transport_pid:
  try: os.killpg(transport_pid,signal.SIGKILL)
  except ProcessLookupError: pass

# Abrupt death while staging leaves an incomplete durable operation. The
# synthetic I/O barrier needs no external transport or child process.
shared=root/'crash-shared'; p,m,e=fixture(shared=shared)
hook=p/'hook'; hook.mkdir(); (hook/'sitecustomize.py').write_text('''import os,time
original_read=os.read
def read(fd,n):
 data=original_read(fd,n)
 target=os.environ.get('BLOCK_SOURCE')
 if target and os.fstat(fd).st_ino==os.stat(target).st_ino:
  open(os.environ['BLOCK_ENTERED'],'w').close()
  time.sleep(10)
 return data
os.read=read
''')
e.update(PYTHONPATH=str(hook),BLOCK_SOURCE=m['files'][0]['path'],BLOCK_ENTERED=str(p/'entered'))
proc=subprocess.Popen(command(p,m,e),env=e,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
try:
 for _ in range(150):
  if (p/'entered').exists(): break
  assert proc.poll() is None,proc.communicate()
  time.sleep(.02)
 else: raise AssertionError('staging barrier did not enter')
 os.killpg(proc.pid,signal.SIGKILL); proc.wait(timeout=3)
 q,n,other=fixture(shared=shared); denied(q,n,other,'unresolved')
 inspect(p,m,e,'unresolved')
 for lock in shared.glob('*.lock'):
  with lock.open('r+b') as f: fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
 assert not (p/'calls').exists()
 print('ok - SIGKILL during staging releases lease but preserves unresolved ownership')
finally:
 if proc.poll() is None: os.killpg(proc.pid,signal.SIGKILL); proc.wait(timeout=3)
print('ok - all U2 offline behavior contracts')

# Native rendering is characterized from cli/cli v2.102.0 attach.go,
# userasset.go, attach_test.go and both edit implementations, not CLI stdout.
for kind in ['pr','issue']:
 for initial in ['original body','original body \t\r\n\n','']:
  p,m,e=fixture(kind); add_video(p,m)
  remote=json.loads((p/'remote.json').read_text()); key='/repos/owner/repo/'+('pulls' if kind=='pr' else 'issues')+'/7'
  remote[key]['body']=initial; (p/'remote.json').write_text(json.dumps(remote))
  op=prepared(p,m,e); r=publish(p,m,e); rec=json.loads(r.stdout)
  assert rec['state']=='published-confirmed' and rec['rendered_qa']=='pending-independent-review'
  urls=['https://github.com/user-attachments/assets/11111111-1111-1111-1111-'+str(n).zfill(12) for n in [1,2]]
  expected=initial.rstrip(' \t\r\n')
  expected+= ('\n\n' if expected else '')+'![Approved view]('+urls[0]+')\n\n'+urls[1]
  assert json.loads((p/'remote.json').read_text())[key]['body']==expected
  assert [i['state'] for i in rec['items']]==['published-confirmed']*2
  assert (p/'native-hashes').read_text().splitlines()==[f['sha256'] for f in m['files']]
  publish(p,m,e); assert len((p/'native-calls').read_text().splitlines())==2
  assert json.loads(inspect(p,m,e).stdout)['state']=='published-confirmed'
  q,n,other=fixture(shared=Path(e['FM_GITHUB_MEDIA_TEST_ROOT'])); denied(q,n,other,'unresolved')
  print('ok - '+kind+' native image/video ordered forms, normalization, confirmed reuse, cross-home claim')

p,m,e=fixture(); (p/'native-nonzero').touch(); prepared(p,m,e)
r=publish(p,m,e); rec=json.loads(r.stdout)
assert rec['items'][0]['attempts'][0]['command_outcome']['returncode']==1
publish(p,m,e); assert len((p/'native-calls').read_text().splitlines())==1
print('ok - nonzero landed embed confirms before exit classification and never repeats')

for marker in ['legacy-validator','malformed-validator','deny-label','deny-cumulative','bad-version']:
 p,m,e=fixture(); add_video(p,m); (p/marker).touch()
 if marker=='deny-label': m['files'][1]['label']='Forbidden label'
 prepared(p,m,e); publish(p,m,e,'runtime' if marker=='bad-version' else 'validator')
 assert not (p/'native-calls').exists()
 assert json.loads(inspect(p,m,e).stdout)['items'][0]['state']=='unattempted'
 print('ok - zero uploads for '+marker)
for field in ['protocol','valid','repo','target_kind','body_sha256','labels_sha256']:
 p,m,e=fixture(); prepared(p,m,e); (p/'mismatch-validator').write_text(field)
 publish(p,m,e,'receipt mismatch'); assert not (p/'native-calls').exists()
print('ok - every validator receipt input binding is required')
for body in ['```python\nopen','~~~\nopen','<!-- open','<details>\nopen','`open','[open','text (open']:
 p,m,e=fixture(); remote=json.loads((p/'remote.json').read_text()); remote['/repos/owner/repo/pulls/7']['body']=body; (p/'remote.json').write_text(json.dumps(remote))
 prepared(p,m,e); publish(p,m,e,'unsafe'); assert not (p/'native-calls').exists()
print('ok - unsafe/unclosed Markdown and HTML append contexts refuse')

for marker in ['no-append','body-drift','lose-readback','deny-readback','head-drift']:
 p,m,e=fixture(); add_video(p,m); op=prepared(p,m,e); (p/marker).touch()
 needle={'no-append':'unknown','body-drift':'unknown','lose-readback':'response','deny-readback':'validator','head-drift':'head'}[marker]
 publish(p,m,e,needle)
 rec=json.loads((op/'operation.json').read_text()); assert rec['state']=='held'
 assert len((p/'native-calls').read_text().splitlines())==1
 assert rec['items'][1]['state']=='unattempted'
 if marker in ['head-drift','deny-readback']: assert rec['items'][0]['state']=='published-confirmed'
 if marker=='lose-readback':
  (p/'bad-wire').unlink(); (p/marker).unlink(); publish(p,m,e)
  assert len((p/'native-calls').read_text().splitlines())==2
 elif marker=='no-append':
  publish(p,m,e,'disposition'); assert len((p/'native-calls').read_text().splitlines())==1
 print('ok - '+marker+' preserves confirmed/pending/unknown state honestly')

# A URL can be displayed without fetching it: no verification URL, redirect,
# secret-bearing URL, or CLI stdout is an authenticated read destination.
for url in ['https://evil.invalid/asset','https://github.com/user-attachments/assets/11111111-1111-1111-1111-111111111111?redirect=https://evil.invalid','https://token@github.com/user-attachments/assets/11111111-1111-1111-1111-111111111111']:
 p,m,e=fixture(); prepared(p,m,e); (p/'evil-url').write_text(url)
 publish(p,m,e,'unknown')
 assert all(json.loads(line)[2] in ['/user','/repos/owner/repo','/repos/owner/repo/pulls/7'] for line in (p/'calls').read_text().splitlines())
print('ok - arbitrary/redirected URLs never become authenticated verification requests')

# One-use operator disposition is bound to all immutable item/attempt fields.
p,m,e=fixture(); op=prepared(p,m,e); (p/'no-append').touch(); publish(p,m,e,'unknown')
rec=json.loads((op/'operation.json').read_text()); prior=rec['items'][0]['attempts'][-1]['id']
d=dict(schema=1,id='retry-1',authority=m['authority'],target=m['target'],operation=m['operation'],ordinal=0,sha256=m['files'][0]['sha256'],prior_attempt=prior,action='retry-unknown')
path=p/'disposition.json'
for field,value in [('target',dict(m['target'],number=8)),('operation','other'),('ordinal',1),('sha256','0'*64),('prior_attempt','0'*32),('authority',dict(m['authority'],explicit=False))]:
 path.write_text(json.dumps(dict(d,**{field:value}))); publish(p,m,e,'disposition',path)
 assert len((p/'native-calls').read_text().splitlines())==1
path.write_text(json.dumps(d)); publish(p,m,e,'unknown',path)
rec=json.loads((op/'operation.json').read_text()); assert rec['consumed_dispositions']==['retry-1']
assert len((p/'native-calls').read_text().splitlines())==2
publish(p,m,e,'disposition',path)
d['prior_attempt']=rec['items'][0]['attempts'][-1]['id']; path.write_text(json.dumps(d)); publish(p,m,e,'already consumed',path)
assert len((p/'native-calls').read_text().splitlines())==2
d['id']='retry-2'; path.write_text(json.dumps(d)); (p/'no-append').unlink(); publish(p,m,e,disposition=path)
assert len((p/'native-calls').read_text().splitlines())==3
publish(p,m,e,'no unresolved',path)
print('ok - bound single-use dispositions reject absent, wrong and reused authority')

# Input/dependency failures have no side effects, including authentication
# failure before the attempt and an unavailable real validator protocol.
for case in ['missing-validator','changed-digest','auth','actor','head','body','snapshot']:
 p,m,e=fixture(); op=prepared(p,m,e); dependency=deps(p)
 d=json.loads(dependency.read_text())
 if case=='missing-validator': d['validator']['path']=str(p/'absent-validator')
 if case=='changed-digest': d['validator']['sha256']='0'*64
 dependency.write_text(json.dumps(d))
 if case=='auth': (p/'read-error').touch()
 if case in ['actor','head','body']:
  remote=json.loads((p/'remote.json').read_text())
  if case=='actor': remote['/user']['login']='other-user'
  if case=='head': remote['/repos/owner/repo/pulls/7']['head']['sha']='b'*40
  if case=='body': remote['/repos/owner/repo/pulls/7']['body']='changed by human'
  (p/'remote.json').write_text(json.dumps(remote))
 if case=='snapshot': (op/'0.png').write_bytes(b'changed')
 r=subprocess.run(['bash',str(cli),'publish','--operation','op1','--dependencies',str(dependency)],env=e,capture_output=True,text=True,timeout=15)
 assert r.returncode!=0 and not (p/'native-calls').exists(),case
 assert 'changed by human' not in r.stderr and str(op) not in r.stderr
 assert 'synthetic-auth-secret' not in r.stderr
 print('ok - '+case+' refuses before upload without identity repair or private diagnostics')

# Persistent receipt write failure after upload leaves the pre-launch attempt
# unknown on disk. Once storage works, strict readback reuses it without upload.
p,m,e=fixture(); op=prepared(p,m,e)
hook=p/'hook'; hook.mkdir(); (hook/'sitecustomize.py').write_text('''import os
original_replace=os.replace
def replace(src,dst,*a,**kw):
 if str(dst).endswith('/operation.json') and os.path.exists(os.environ['FIXTURE']+'/native-calls'):
  raise OSError('synthetic receipt write failure')
 return original_replace(src,dst,*a,**kw)
os.replace=replace
''')
e['PYTHONPATH']=str(hook); publish(p,m,e,'invalid input or state')
rec=json.loads((op/'operation.json').read_text()); assert rec['items'][0]['state']=='unknown'
del e['PYTHONPATH']; publish(p,m,e); assert len((p/'native-calls').read_text().splitlines())==1
print('ok - persistent post-upload receipt failure reconciles without repeating upload')

p,m,e=fixture(); prepared(p,m,e); (p/'native-auth-error').touch()
r=publish(p,m,e,'unknown'); assert 'synthetic-auth-secret' not in r.stderr
publish(p,m,e,'disposition'); assert len((p/'native-calls').read_text().splitlines())==1
print('ok - native auth/token/SSO failure remains unknown, with no secret output or account switch')

for failure in ['upload-failure','patch-failure']:
 p,m,e=fixture(); op=prepared(p,m,e); (p/failure).touch()
 publish(p,m,e,'unknown'); publish(p,m,e,'disposition')
 assert len((p/'native-calls').read_text().splitlines())==1
 assert (p/'uploaded-unreferenced').exists()==(failure=='patch-failure')
 assert json.loads((op/'operation.json').read_text())['items'][0]['state']=='unknown'
 print('ok - '+failure+' cannot prove absence of an asset and never blindly repeats')

p,m,e=fixture(); add_video(p,m); op=prepared(p,m,e)
(p/'block-after-land').touch(); e['FM_GITHUB_MEDIA_TEST_TIMEOUT']='1'
publish(p,m,e,'cancellation'); rec=json.loads((op/'operation.json').read_text())
assert [i['state'] for i in rec['items']]==['published-confirmed','unattempted']
(p/'block-after-land').unlink(); publish(p,m,e)
assert len((p/'native-calls').read_text().splitlines())==2
print('ok - deadline after landed embed retains confirmation and holds later items')

# Refusing the durable pre-launch write prevents even starting native. A
# separate crash after the write but before launch cannot attribute a later
# URL-shaped human append to a command that never started.
for crash in [False,True]:
 p,m,e=fixture(); op=prepared(p,m,e); hook=p/'hook'; hook.mkdir()
 (hook/'sitecustomize.py').write_text('''import json,os,signal
original_replace=os.replace
def replace(src,dst,*a,**kw):
 if str(dst).endswith('/operation.json'):
  with open(src) as f: record=json.load(f)
  if record.get('state')=='publishing':
   if os.environ['CRASH_BEFORE_NATIVE']=='1':
    result=original_replace(src,dst,*a,**kw)
    os.kill(os.getpid(),signal.SIGKILL)
    return result
   raise OSError('synthetic pre-launch journal failure')
 return original_replace(src,dst,*a,**kw)
os.replace=replace
''')
 e.update(PYTHONPATH=str(hook),CRASH_BEFORE_NATIVE='1' if crash else '0')
 r=subprocess.run(['bash',str(cli),'publish','--operation','op1','--dependencies',str(deps(p))],env=e,capture_output=True,text=True,timeout=12)
 assert r.returncode!=0 and not (p/'native-calls').exists()
 del e['PYTHONPATH']; del e['CRASH_BEFORE_NATIVE']
 rec=json.loads((op/'operation.json').read_text())
 assert rec['dependencies']==json.loads((p/'dependencies.json').read_text()) and rec['items'][0]['attempts']
 replacement=p/'different-reviewed-validator'; replacement.write_bytes(validator.read_bytes()+b'\n# different\n')
 publish(p,m,e,'binding changed',dependency=deps(p,{'validator':replacement}))
 assert not (p/'native-calls').exists()
 if crash:
  remote=json.loads((p/'remote.json').read_text())
  remote['/repos/owner/repo/pulls/7']['body']+='\n\n![Approved view](https://github.com/user-attachments/assets/11111111-1111-1111-1111-111111111111)'
  (p/'remote.json').write_text(json.dumps(remote)); publish(p,m,e,'body drift')
  assert json.loads((op/'operation.json').read_text())['items'][0]['state']=='unknown'
print('ok - durable journal precedes launch; never-started commands cannot claim URL-shaped appends')

# Retaining pre-body contexts must not create a journal that restart refuses
# to read. Bound the next attempt before native launch and keep prior receipts.
p,m,e=fixture(); add_video(p,m)
f=p/'second.png'; f.write_bytes(b'\x89PNG\r\n\x1a\nsecond distinct synthetic image')
m['files'].append(dict(path=str(f),size=f.stat().st_size,sha256=hashlib.sha256(f.read_bytes()).hexdigest(),media_type='image/png',label='Approved view'))
remote=json.loads((p/'remote.json').read_text()); remote['/repos/owner/repo/pulls/7']['body']='Large synthetic context. '*36000
(p/'remote.json').write_text(json.dumps(remote)); prepared(p,m,e)
publish(p,m,e,'bounded size')
rec=json.loads(inspect(p,m,e).stdout)
assert [i['state'] for i in rec['items']]==['published-confirmed','published-confirmed','unattempted']
assert len((p/'native-calls').read_text().splitlines())==2
print('ok - bounded journal growth preserves readable confirmations and refuses next launch')

# Unknown command ownership is not repaired using boot/PID guesses. An actual
# unrelated process remains alive when a synthetic stale journal names it.
p,m,e=fixture(); op=prepared(p,m,e)
sentinel=subprocess.Popen(['python3','-c','import time; time.sleep(30)'],env=e)
try:
 journal=next(op.glob('command-*.json')); saved=json.loads(journal.read_text())
 saved.update(state='running',guardian=dict(pid=sentinel.pid,boot='old-boot',start='wrong-start'))
 journal.write_text(json.dumps(saved))
 publish(p,m,e,'ownership'); inspect(p,m,e,'ownership')
 assert sentinel.poll() is None and not (p/'native-calls').exists()
 q,n,other=fixture(shared=Path(e['FM_GITHUB_MEDIA_TEST_ROOT'])); denied(q,n,other,'unresolved')
finally:
 sentinel.terminate(); sentinel.wait(timeout=3)
print('ok - stale/reboot/uncertain PID records refuse replacement without unrelated signals')

for phase,death in [('read','kill'),('attach','kill'),('attach','term'),('attach','deadline'),('hygiene','kill'),('hygiene','deadline')]:
 p,m,e=fixture(); op=Path(m['home'])/'data/task/github-media/op1'
 if phase=='read':
  (p/'block').touch(); (p/'read-grandchild').touch(); args=command(p,m,e); entered=p/'entered'; pidfile=p/'transport-pid'
 elif phase=='hygiene':
  prepared(p,m,e); (p/'parser-block').touch()
  args=['bash',str(cli),'publish','--operation','op1','--dependencies',str(deps(p))]
  entered=p/'parser-entered'; pidfile=p/'validator-pid'
 else:
  prepared(p,m,e); (p/'native-block').touch()
  args=['bash',str(cli),'publish','--operation','op1','--dependencies',str(deps(p))]
  entered=p/'native-entered'; pidfile=p/'native-pid'
  if death=='deadline': e['FM_GITHUB_MEDIA_TEST_TIMEOUT']='1'
 proc=subprocess.Popen(args,env=e,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
 fds=[]
 try:
  wait_for_file(entered,proc)
  pids=[int(pidfile.read_text()),int((p/('parser-pid' if phase=='hygiene' else 'grandchild-pid')).read_text())]
  fds=[os.pidfd_open(pid) for pid in pids]
  q,n,other=fixture(shared=Path(e['FM_GITHUB_MEDIA_TEST_ROOT'])); denied(q,n,other,'busy')
  if death=='kill': proc.kill()
  elif death=='term': proc.terminate()
  proc.communicate(timeout=40 if phase=='hygiene' else 12)
  wait_gone(pids)
  for _ in range(200):
   journals=[json.loads(f.read_text()) for f in op.glob('command-*.json')]
   if all(j['state']=='stopped' for j in journals): break
   time.sleep(.02)
  else: raise AssertionError('guardian failed to prove stopped')
  for lock in Path(e['FM_GITHUB_MEDIA_TEST_ROOT']).glob('*.lock'):
   with lock.open('r+b') as f: fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
  denied(q,n,other,'unresolved')
  if phase=='attach':
   publish(p,m,e,'disposition'); assert len((p/'native-calls').read_text().splitlines())==1
  if phase=='hygiene':
   assert not (p/'native-calls').exists()
   (p/'parser-block').unlink(); publish(p,m,e)
   assert len((p/'native-calls').read_text().splitlines())==1
  print('ok - '+phase+' '+death+': child and detached grandchild reaped before lease release; no replay')
 finally:
  if proc.poll() is None: proc.kill(); proc.wait(timeout=5)
  for fd in fds:
   try: signal.pidfd_send_signal(fd,signal.SIGKILL)
   except ProcessLookupError: pass
   os.close(fd)

parser_binding_regressions()
print('ok - all U3 offline publication/reconciliation behavior contracts')

# This opt-in guard must neither publish nor report acceptance when skipped.
live=Path(os.environ['ROOT'])/'tests/fm-github-media-live.test.sh'
p,m,e=fixture(); e.update(FM_GITHUB_MEDIA_LIVE='0',FM_LIVE='0')
r=subprocess.run(['bash',str(live)],env=e,capture_output=True,text=True,timeout=8)
assert r.returncode==0 and 'skip: live:' in r.stdout and not (p/'calls').exists(),r.stderr
e['FM_GITHUB_MEDIA_LIVE']='1'; e.pop('FM_GITHUB_MEDIA_LIVE_CASES',None)
r=subprocess.run(['bash',str(live)],env=e,capture_output=True,text=True,timeout=8)
assert r.returncode!=0 and 'incomplete' in r.stderr and not (p/'calls').exists(),r.stderr
print('ok - live guard skips explicitly and an opt-in flag alone cannot publish')
u4_regressions()
u4_fix_regressions()
u3_c4_regressions()
placement_regressions()
PY
