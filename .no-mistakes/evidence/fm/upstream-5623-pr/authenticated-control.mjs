import assert from 'node:assert/strict';
import fs from 'node:fs';
import {execFileSync} from 'node:child_process';
import {ModelRuntime, DefaultResourceLoader, SettingsManager, SessionManager, createAgentSession, VERSION} from '/home/art/.npm-packages/lib/node_modules/@earendil-works/pi-coding-agent/dist/index.js';
const root=process.cwd(), lab=root+'/.sdk-auth-lab';
const evidence='/home/art/.no-mistakes/evidence/01M4SNZBKAAYXKDB2538NPVP6S';
const result={head:execFileSync('git',['rev-parse','HEAD'],{encoding:'utf8'}).trim(),sdk:VERSION,provider:'john-lan',model:'qwen3.8-flash-next',pid:process.pid,requests:0,completed:0,inputCharacterBound:0,outputCap:512,providerResponses:[],verdict:'inconclusive'};
assert.equal(result.head,'845ee710513334868cbb4bd8ea6e66986c2f55fb');
fs.writeFileSync(evidence+'/authenticated-control.pid',String(process.pid));
let session;
try {
 const runtime=await ModelRuntime.create({authPath:lab+'/agent/auth.json',modelsPath:'/home/art/.pi/agent/models.json',modelsStorePath:lab+'/agent/models-store.json',allowModelNetwork:false,refreshOnCreate:false});
 const model=runtime.getModel(result.provider,result.model); assert.ok(model);
 const auth=await runtime.checkAuth(result.provider); assert.equal(auth.type,'api_key');
 result.auth={type:auth.type,source:auth.source};
 const settings=SettingsManager.inMemory({defaultProvider:result.provider,defaultModel:result.model,defaultThinkingLevel:'off',compaction:{enabled:false},retry:{enabled:false,maxRetries:0,provider:{maxRetries:0,timeoutMs:20000}},cacheWarming:'off'});
 const loader=new DefaultResourceLoader({cwd:lab,agentDir:lab+'/agent',settingsManager:settings,noExtensions:true,noSkills:true,noContextFiles:true,noPromptTemplates:true,noThemes:true,systemPrompt:'This is an isolated provider connectivity control. Reply only OK. No tools.',extensionFactories:[pi=>{
  pi.on('before_provider_request',event=>{
   assert.equal(result.requests,0,'No retry permitted for connectivity control');
   const payload={...event.payload,max_tokens:512};
   if('max_completion_tokens' in payload) {payload.max_completion_tokens=512;delete payload.max_tokens;}
   assert.ok(!payload.tools?.length,'Control must have no tools');
   result.inputCharacterBound+=Buffer.byteLength(JSON.stringify(payload));assert.ok(result.inputCharacterBound<=160000);
   result.requests++;
   console.log(JSON.stringify({stage:'provider-request',request:result.requests,outputCap:512,inputByteBound:result.inputCharacterBound}));
   return payload;
  });
  pi.on('tool_call',()=>({block:true,reason:'No tools authorized in connectivity control'}));
 }]});
 await loader.reload();assert.deepEqual(loader.getExtensions().errors,[]);
 ({session}=await createAgentSession({cwd:lab,agentDir:lab+'/agent',modelRuntime:runtime,model,thinkingLevel:'off',tools:[],resourceLoader:loader,settingsManager:settings,sessionManager:SessionManager.create(lab,lab+'/sessions')}));
 await session.bindExtensions({mode:'sdk',onError:e=>{result.extensionError=true;}});
 session.subscribe(event=>{if(event.type==='message_end'&&event.message.role==='assistant') {
   const m=event.message;result.providerResponses.push({stopReason:m.stopReason,usage:m.usage,error:typeof m.errorMessage==='string'?m.errorMessage.replace(/https?:\/\/\S+/g,'[endpoint]'):undefined});
   if(m.stopReason!=='error'&&m.stopReason!=='aborted') result.completed++;
 }});
 await session.prompt('Reply OK.');
 assert.equal(result.completed,1,'Selected provider failed the isolated AgentSession control');
 result.verdict='control-pass';
} catch(e) {result.failure=String(e).replace(/https?:\/\/\S+/g,'[endpoint]');process.exitCode=1;}
finally {session?.dispose();fs.writeFileSync(evidence+'/authenticated-control-result.json',JSON.stringify(result,null,2)+'\n');console.log(JSON.stringify(result));}
