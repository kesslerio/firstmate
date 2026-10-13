import { mkdirSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import assert from 'node:assert/strict';
import path from 'node:path';
const root = process.cwd();
const { scopeForUnreadWake } = await import(pathToFileURL(path.join(root, '.pi/extensions/lib/fm-branch-dispatch.ts')));
const scratch = mkdtempSync(path.join(root, '.gate-test-tmp/routing-'));
let count = 0;
function drive(name, records, rows, trigger, expected, heartbeat = false) {
 const home = path.join(scratch, String(++count));
 const state = path.join(home, 'state');
 mkdirSync(state, {recursive:true});
 for (const [name, text] of Object.entries(records)) writeFileSync(path.join(state,name),text);
 writeFileSync(path.join(state,'.wake-queue'), rows.map((r,i)=>`1\t${i+1}\t${r[0]}\t${r[1]}\t${r[2] || `${r[0]}: ${r[1]}`}`).join('\n')+'\n');
 const env = {...process.env, FM_HOME:home, FM_STATE_OVERRIDE:state, NODE_NO_WARNINGS:'1'};
 const scope = scopeForUnreadWake(state, heartbeat);
 const output = execFileSync(process.execPath, [path.join(root,'bin/fm-branch-dispatch.mjs'),'offer'], {env,input:trigger+'\n',encoding:'utf8'});
 const actual = Object.fromEntries(output.trim().split('\n').map(line=>{ const i=line.indexOf('='); return [line.slice(0,i),line.slice(i+1)]; }));
 console.log(JSON.stringify({name,records,rows,trigger,scope,cli:output}));
 assert.equal(actual.eligible, expected.eligible, name);
 if (expected.corrupted !== undefined) {assert.equal(actual.corrupted,expected.corrupted,name); assert.equal(scope.corrupted, expected.corrupted==='1',name);}
 if (expected.rows !== undefined) {assert.equal(actual.rows,expected.rows,name); assert.equal(scope.eligibleSeqs.join(' '), expected.rows,name);}
 if (expected.task) {assert.equal(scope.taskByWakeKey['orca-terminal'],expected.task,name);assert(scope.projects.includes('/disposable/project'));}
}
const meta = 'project=/disposable/project\n';
const ordinary = {'orca.meta':meta+'terminal=orca-terminal\nwindow=orca-window\n'};
try {
 for (const key of ['orca-terminal','orca-window','orca','fm-orca-terminal']) drive('unique stale '+key,ordinary,[['stale',key]],'stale: '+key,{eligible:'1',corrupted:'0',rows:'1',task:'orca'});
 for (const key of ['orca.status','orca.turn-ended']) drive('unique signal '+key,ordinary,[['signal',key]],'signal: '+key,{eligible:'1',corrupted:'0',rows:'1'});
 drive('heartbeat includes terminal stale',ordinary,[['heartbeat','heartbeat'],['stale','orca-terminal']],'heartbeat',{eligible:'1',corrupted:'0',rows:'1 2',task:'orca'},true);
 drive('same task may share endpoint aliases',{'orca.meta':meta+'terminal=orca-terminal\nwindow=orca-terminal\n'},[['stale','orca-terminal']],'stale: orca-terminal',{eligible:'1',corrupted:'0',rows:'1',task:'orca'});
 for (const owner of ['a-owner','z-owner']) for (const field of ['terminal','window']) for (const other of ['terminal','window','task','status','turn-ended']) {
  const key = other==='task'?owner:other==='status'?owner+'.status':other==='turn-ended'?owner+'.turn-ended':'shared-endpoint';
  const records = {'orca.meta':meta+`${field}=${key}\n`,[owner+'.meta']:meta+(['terminal','window'].includes(other)?`${other}=${key}\n`:''), 'orca.status':'needs-decision: approval required [key: review]\n'};
  drive(`collision ${field}/${other} owner=${owner}`,records,[['signal',owner+'.status'],['stale',key]],'stale: '+key,{eligible:'0',corrupted:'1',rows:''});
 }
 for (const status of ['needs-decision: approval required [key: review]\n','captain-held: awaiting approval\n']) drive('decision terminal with unrelated routine '+status.trim(),{...ordinary,'orca.status':status,'other.meta':meta},[['signal','other.status'],['stale','orca-terminal']],'stale: orca-terminal',{eligible:'0',corrupted:'0',rows:'1'});
 drive('queued decision cross-key veto', {...ordinary,'other.meta':meta},[['signal','orca.status','needs-decision: orca.status'],['signal','other.status'],['stale','orca-terminal']],'stale: orca-terminal',{eligible:'0',corrupted:'0',rows:'2 3'});
 drive('unrelated task remains eligible beside decision', {...ordinary,'other.meta':meta,'orca.status':'needs-decision: approval required [key: review]\n'},[['stale','orca-terminal'],['signal','other.status']],'signal: other.status',{eligible:'1',corrupted:'0',rows:'2'});
 drive('unknown stale refuses mixed queue',ordinary,[['signal','orca.status'],['stale','unknown-terminal']],'stale: unknown-terminal',{eligible:'0',corrupted:'1',rows:''});
 drive('unknown signal refuses mixed queue',ordinary,[['signal','orca.status'],['signal','unknown.status']],'signal: unknown.status',{eligible:'0',corrupted:'1',rows:''});
 console.log(`Completed ${count} real CLI routing cases and exported-scope assertions.`);
} finally {rmSync(scratch,{recursive:true,force:true});}
