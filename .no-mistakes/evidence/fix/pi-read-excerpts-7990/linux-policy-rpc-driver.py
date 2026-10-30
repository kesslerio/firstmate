import pathlib, subprocess, json, shutil
base=pathlib.Path('/home/art/.local/share/fm-7990-linux-validation-20261030-1')
repo=base/'repo'
assert subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip()=='8a21e6ff77846f2cbd1ce4eddf6320431d7fdf17'
original=(repo/'tests/fixtures/fm-read-repetition-live.mjs').read_text()
cases=[('absent',None,{},None,6),('disabled',{'enabled':False},{},None,6),('repeat-limit',{'enabled':True,'repeatLimit':2},{},None,2),('window',{'enabled':True,'windowMs':1000},{},'await new Promise(r => setTimeout(r, 1100));',6),('output-change',{'enabled':True},{},None,5),('error-reset',{'enabled':True},{},None,6),('nonzero-reset',{'enabled':True},{},None,6),('worker',{'enabled':True},{'FM_TASK_ID':'synthetic-worker'},None,6),('foreign-owner',{'enabled':True},{},None,6),('write',{'enabled':True},{},None,6),('substitution',{'enabled':True},{},None,6),('nested-shell',{'enabled':True},{},None,6),('unknown-option',{'enabled':True},{},None,6)]
commands={'write':'sed -i s/a/b/ fixture','substitution':'cat $(echo fixture)','nested-shell':"bash -c 'cat fixture'",'unknown-option':'nl -ba -v180 --unknown fixture'}
for name,config,env,delay,expected in cases:
    lab=base/('policy-rpc-'+name)
    fixture=repo/('tests/fixtures/.policy-rpc-'+name+'.mjs')
    assert not lab.exists() and not fixture.exists()
    s=original.replace("i < 200", "i < 1000")
    configline='writeFileSync(join(repo, "config/read-repetition.json"), \'{"enabled":true}\');'
    s=s.replace(configline,'' if config is None else 'writeFileSync(join(repo, "config/read-repetition.json"), '+json.dumps(json.dumps(config))+');')
    start=s.index('command: ',s.index('const calls ='))
    end=s.index(' }, { id:',start)
    s=s[:start]+'command: '+json.dumps(commands.get(name,'nl -ba -v180 fixture'))+s[end:]
    if env:
        s=s.replace('env: { PATH:', 'env: { '+', '.join(k+': '+json.dumps(v) for k,v in env.items())+', PATH:')
    if name=='foreign-owner':
        s=s.replace('process.pid + "\\\\n");','"1\\\\n");',1)
    # Change only the fake tool response; guard and extension remain committed bytes.
    s=s.replace('executions++; save(); return', 'executions++; save(); '+(delay or '')+' return')
    if name=='output-change':
        s=s.replace('text: "unchanged fixture"','text: executions < 3 ? "first output" : "second output"')
    if name=='error-reset':
        s=s.replace('return { content:', 'if (executions === 3) throw new Error("synthetic failure"); return { content:')
    if name=='nonzero-reset':
        s=s.replace('details: {}','details: { exitCode: executions === 3 ? 1 : 0 }')
    a=s.index('  assert.deepEqual(JSON.parse(readFileSync(receipt))')
    b=s.index('\n} catch (error)',a)
    requests=expected+1
    stopped=expected<6 or name in ['error-reset','nonzero-reset']
    if name in ['error-reset','nonzero-reset']: s=s.replace('calls(6)', 'calls(8)')
    s=s[:a]+f'''  assert.deepEqual(JSON.parse(readFileSync(receipt)), {{ requests: {requests}, executions: {expected} }});
  const sessionDir = join(agentDir, "sessions", `--${{repo.slice(1).replaceAll("/", "-")}}--`);
  const files = readdirSync(sessionDir).filter(n => n.endsWith(".jsonl"));
  assert.equal(files.length, 1);
  const entries = readFileSync(join(sessionDir, files[0]), "utf8").trim().split("\\n").map(l => JSON.parse(l));
  assert.equal(entries.filter(e => e.customType === "fm-read-repetition-stopped").length, {1 if stopped else 0});
  assert.equal(entries.some(e => e.customType === "fm-read-repetition-activation-v1"), {str(name not in ['absent','disabled','worker','foreign-owner']).lower()});
  console.log(JSON.stringify({{ scenario: {json.dumps(name)}, installedPiRPC: "passed", executions: {expected}, requests: {requests}, stopped: {str(stopped).lower()} }}));'''+s[b:]
    fixture.write_text(s)
    try:
        result=subprocess.run(['timeout','-k','5s','60s','node',str(fixture),'/home/art/.npm-packages/bin/pi',str(lab)],cwd=repo,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        print(result.stdout,flush=True)
        assert result.returncode==0,(name,result.returncode)
    finally:
        fixture.unlink()
        if lab.exists(): shutil.rmtree(lab)
print('All 13 installed-Pi policy scenarios passed; each fixture verified process-group cleanup.')
subprocess.run(['git','status','--short'],cwd=repo,check=True)
