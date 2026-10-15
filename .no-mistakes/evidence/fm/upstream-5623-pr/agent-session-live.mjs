import assert from 'node:assert/strict';
import fs from 'node:fs';
import {execFileSync,spawnSync} from 'node:child_process';
import {ModelRuntime,DefaultResourceLoader,SettingsManager,SessionManager,createAgentSession,createEventBus,VERSION} from '/home/art/.npm-packages/lib/node_modules/@earendil-works/pi-coding-agent/dist/index.js';
const root=process.cwd(),lab=root+'/.sdk-auth-lab',state=lab+'/state';
const evidence='/home/art/.no-mistakes/evidence/01M4SNZBKAAYXKDB2538NPVP6S';
const results={head:execFileSync('git',['rev-parse','HEAD'],{encoding:'utf8'}).trim(),sdk:VERSION,pid:process.pid,requests:0,inputByteBound:0,responses:[],events:[],checks:[],verdict:'inconclusive'};
assert.equal(results.head,'845ee710513334868cbb4bd8ea6e66986c2f55fb');
fs.writeFileSync(evidence+'/agent-session-live.pid',String(process.pid));
for(const d of [state,lab+'/config',lab+'/sessions'])fs.mkdirSync(d,{recursive:true});
const deadline=Date.now()+290000;
const wait=async pred=>{while(!pred()){if(Date.now()>deadline)throw Error('Lab deadline');await new Promise(r=>setTimeout(r,30));}};
const log=x=>{results.events.push(x);console.log(JSON.stringify(x));};
const runOutcome=args=>{const r=spawnSync('bash',[root+'/bin/fm-branch-outcome.sh',...args],{env:process.env,encoding:'utf8',timeout:10000});assert.equal(r.status,0,r.stderr);return r.stdout.trim();};
let session,mode='cancel',customStarts=0,settled=0,errors=[],bus=createEventBus();
try{
 const runtime=await ModelRuntime.create({authPath:lab+'/agent/auth.json',modelsPath:'/home/art/.pi/agent/models.json',modelsStorePath:lab+'/agent/models-store.json',allowModelNetwork:false,refreshOnCreate:false});
 const model=runtime.getModel('john-lan','qwen3.8-flash-next');assert.ok(model);
 const auth=await runtime.getAuth(model);assert.ok(auth.auth.apiKey);
 // Supported in-memory provider registration lets the branch resolve only this
 // selected provider without a credential file or global configuration writes.
 const config={baseUrl:model.baseUrl,api:model.api,apiKey:auth.auth.apiKey,models:[{...model,maxTokens:512}]};
 runtime.registerProvider(model.provider,config);
 const settings=SettingsManager.inMemory({defaultProvider:model.provider,defaultModel:model.id,defaultThinkingLevel:'off',compaction:{enabled:false},retry:{enabled:false,maxRetries:0,provider:{maxRetries:0,timeoutMs:20000}},cacheWarming:'off'});
 const loader=new DefaultResourceLoader({cwd:lab,agentDir:lab+'/agent',eventBus:bus,settingsManager:settings,noExtensions:true,noSkills:true,noContextFiles:true,noPromptTemplates:true,noThemes:true,systemPrompt:'Isolated SDK lifecycle test. Reply OK to every input. No tools are enabled.',additionalExtensionPaths:[root+'/.pi/extensions/fm-branch-supervision.ts',root+'/.pi/extensions/fm-primary-pi-watch.ts'],extensionFactories:[{name:'lab-observer',factory:pi=>{
  pi.on('before_agent_start',event=>{
   const custom=event.messageType==='custom';
   log({event:'before_agent_start',mode,type:event.messageType,customType:custom?event.message.customType:undefined});
   if(custom&&event.message.customType==='fm-branch-process'){
    customStarts++;
    if(mode==='cancel')fs.writeFileSync(state+'/.afk-contract','Owned disposable test presence record');
   }
  });
  pi.on('context',event=>{log({event:'context',mode,processingPresent:event.messages.some(m=>m.customType==='fm-branch-process')});});
  pi.on('before_provider_request',event=>{
   assert.ok(results.requests<9,'Total cap including preceding control is ten');
   const payload={...event.payload,max_tokens:512};if('max_completion_tokens'in payload){payload.max_completion_tokens=512;delete payload.max_tokens;}
   assert.ok(!payload.tools?.length,'No executable tools in primary');
   results.inputByteBound+=Buffer.byteLength(JSON.stringify(payload));assert.ok(results.inputByteBound+490<=160000);
   results.requests++;log({event:'provider_request',mode,number:results.requests,outputCap:512});return payload;
  });
  pi.on('tool_call',()=>({block:true,reason:'Tools are outside this lab flow'}));
  pi.on('agent_settled',event=>{settled++;log({event:'agent_settled',mode,aborted:event.aborted});});
  pi.on('session_shutdown',event=>log({event:'session_shutdown',reason:event.reason}));
 }}]});
 await loader.reload();assert.deepEqual(loader.getExtensions().errors,[]);
 results.extensions=loader.getExtensions().extensions.map(e=>e.path);
 fs.rmSync(state+'/.lock',{force:true});
 ({session}=await createAgentSession({cwd:lab,agentDir:lab+'/agent',modelRuntime:runtime,model,thinkingLevel:'off',tools:[],resourceLoader:loader,settingsManager:settings,sessionManager:SessionManager.create(lab,lab+'/sessions')}));
 await session.bindExtensions({mode:'sdk',onError:e=>{errors.push(e.message);}});
 session.subscribe(event=>{
  if(event.type==='message_start')log({event:'message_start',mode,role:event.message.role,customType:event.message.customType});
  if(event.type==='message_end'&&event.message.role==='assistant'){
   const m=event.message;results.responses.push({mode,stopReason:m.stopReason,usage:m.usage});
   log({event:'response',mode,stopReason:m.stopReason});
  }
 });
 fs.writeFileSync(state+'/.lock',process.pid+'\n');
 runOutcome(['append','--task','probe','--verdict','captain','--summary','Owned disposable processing cancellation evidence']);
 await session.prompt('Lifecycle control: reply OK.');
 await wait(()=>session.isIdle&&customStarts>=1&&settled>=2);
 assert.equal(results.requests,1,'Cancelled dedicated run must not reach provider');
 assert.ok(results.events.some(e=>e.event==='agent_settled'&&e.aborted));
 assert.ok(runOutcome(['unprocessed']).length>0,'Cancelled work remains unprocessed');
 assert.ok(results.events.some(e=>e.event==='context'&&e.processingPresent===false));
 results.checks.push('Matching dedicated custom run cancelled before provider; outcome remains unprocessed');
 // While away, an unrelated custom turn remains a real, allowed provider run.
 mode='unrelated';const before=results.requests;
 await session.sendCustomMessage({customType:'lab-unrelated',content:'Unrelated custom control; reply OK.',display:false},{triggerTurn:true});
 await wait(()=>session.isIdle);
 assert.equal(results.requests,before+1);
 results.checks.push('Unrelated custom turn allowed while away');
 assert.deepEqual(errors,[]);
 results.verdict='partial-pass';
}catch(e){results.failure=String(e).replace(/https?:\/\/\S+/g,'[endpoint]');process.exitCode=1;}
finally{
 fs.rmSync(state+'/.lock',{force:true});
 if(session){await session.abort();session.dispose();}
 results.errors=errors;
 fs.writeFileSync(evidence+'/agent-session-live-result.json',JSON.stringify(results,null,2)+'\n');
 console.log(JSON.stringify({verdict:results.verdict,checks:results.checks,requests:results.requests,failure:results.failure}));
}
