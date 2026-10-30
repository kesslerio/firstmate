import pathlib, subprocess, json, shutil, os
area=pathlib.Path('/home/art/.local/share/fm-7990-linux-validation-20261030-1')
repo=area/'repo'
head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip()
assert head=='8a21e6ff77846f2cbd1ce4eddf6320431d7fdf17'
env=dict(os.environ,TMPDIR=str(area))
p=subprocess.run(['bash','tests/fm-read-repetition.test.sh'],cwd=repo,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=60)
(area/'round3-focused.log').write_text(p.stdout)
assert p.returncode==0,p.stdout
original=(repo/'tests/fixtures/fm-read-repetition-live.mjs').read_text()
start=original.index('try {\n  await command("get_state");')
end=original.index('} catch (error) {\n  throw new Error',start)
oldcommand=original[original.index('command: "(cd /fixture'):original.index(' }, { id: "call-')]
scenarios=[
 ('numbered',{},'nl -ba -v120 fixture | head -20',3,4),
 ('byte',{},'od -c fixture | head -20',3,4),
 ('absent',None,'cat fixture',6,7),
 ('disabled',{'enabled':False},'cat fixture',6,7),
 ('repeat-limit',{'enabled':True,'repeatLimit':2},'cat fixture',2,3),
 ('window',{'enabled':True,'windowMs':1000},'cat fixture',6,7),
 ('changed-output',{},'cat fixture',6,7),
 ('error-result',{},'cat fixture',6,7),
 ('nonzero-result',{},'cat fixture',6,7),
 ('worker',{},'cat fixture',6,7),
 ('foreign-owner',{},'cat fixture',6,7),
 ('write',{},'nl -ba -v120 fixture > output',6,7),
 ('substitution',{},'nl -ba -v$(echo 120) fixture',6,7),
 ('nested-shell',{},'bash -c "od -c fixture"',6,7),
 ('unsupported-nl',{},'nl -v+120 fixture',6,7),
 ('unsupported-od',{},'od -c --unknown fixture',6,7),
]
results=[]
for name,config,cmd,executions,requests in scenarios:
 lab=area/('round3-lab-'+name); fixture=repo/'tests/fixtures/round3-live.mjs'
 assert not lab.exists()
 s=original.replace("i < 200", "i < 1500")
 configline='writeFileSync(join(repo, "config/read-repetition.json"), \'{"enabled":true}\');'
 replacement='' if config is None else 'writeFileSync(join(repo, "config/read-repetition.json"), '+json.dumps(json.dumps(config or {'enabled':True}))+');'
 s=s.replace(configline,replacement)
 # Two encodings: outer JS template must emit a JS string inside probe.ts.
 s=s.replace(oldcommand,'command: '+json.dumps(json.dumps(cmd))[1:-1])
 if name=='window': s=s.replace('async execute() { executions++;','async execute() { await new Promise(r => setTimeout(r, 1100)); executions++;')
 if name=='changed-output': s=s.replace('text: "unchanged fixture"','text: "fixture output " + executions')
 if name=='error-result': s=s.replace('executions++; save(); return','executions++; save(); if (executions === 3) throw new Error("synthetic tool error"); return')
 if name=='nonzero-result': s=s.replace('details: {}','details: { exitCode: executions === 3 ? 1 : 0 }')
 if name=='worker': s=s.replace('FM_HOME: repo, READ_GUARD_RECEIPT:', 'FM_HOME: repo, FM_TASK_ID: "synthetic-worker", READ_GUARD_RECEIPT:')
 if name=='foreign-owner': s=s.replace('process.pid + "\\\\n"','"2147483647\\\\n"')
 # Re-find because edits above change positions.
 a=s.index('try {\n  await command("get_state");'); b=s.index('} catch (error) {\n  throw new Error',a)
 active=name not in ['absent','disabled','worker','foreign-owner']
 body='''try {
  await command("get_state");
  await prompt("Run controlled policy scenario");
  const observed = JSON.parse(readFileSync(receipt));
  assert.deepEqual(observed, EXPECTED);
  const sessionDir = join(agentDir, "sessions", `--${repo.slice(1).replaceAll("/", "-")}--`);
  const entries = readdirSync(sessionDir).filter(n => n.endsWith(".jsonl")).flatMap(n => readFileSync(join(sessionDir,n),"utf8").trim().split("\\n").map(l => JSON.parse(l)));
  const activated = entries.some(e => e.customType === "fm-read-repetition-activation-v1");
  assert.equal(activated, ACTIVE);
  const stopped = entries.filter(e => e.customType === "fm-read-repetition-stopped").length;
  assert.equal(stopped, STOPPED);
  console.log(JSON.stringify({ scenario: NAME, observed, activated, stopped, installedPiRPC: true }));
'''.replace('EXPECTED',json.dumps({'requests':requests,'executions':executions})).replace('ACTIVE',str(active).lower()).replace('STOPPED','1' if executions<6 else '0').replace('NAME',json.dumps(name))
 if name in ['numbered','byte']:
  body += '''  await prompt("\\u2063FIRSTMATE_OP: v1 watcher: synthetic wake");
  assert.deepEqual(JSON.parse(readFileSync(receipt)), { requests: 4, executions: 3 });
  await prompt("RESET_ONCE");
  assert.deepEqual(JSON.parse(readFileSync(receipt)), { requests: 6, executions: 4 });
  console.log(JSON.stringify({operationalResetDenied:true,userResetAllowed:true}));
'''
 s=s[:a]+body+s[b:]
 fixture.write_text(s)
 try:
  p=subprocess.run(['node',str(fixture),shutil.which('pi'),str(lab)],cwd=repo,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=55)
  (area/('round3-'+name+'.log')).write_text(p.stdout)
  results.append({'scenario':name,'exit':p.returncode,'output':p.stdout})
  print(json.dumps(results[-1]),flush=True)
  if p.returncode: break
 finally:
  fixture.unlink(missing_ok=True)
  shutil.rmtree(lab)
(area/'round3-results.json').write_text(json.dumps({'head':head,'results':results,'sourceStatus':subprocess.check_output(['git','status','--porcelain'],cwd=repo,text=True)},indent=2))
assert len(results)==len(scenarios) and all(r['exit']==0 for r in results)
