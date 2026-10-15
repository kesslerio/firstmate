import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import {spawnSync} from 'node:child_process';
import {pathToFileURL} from 'node:url';
const root=process.cwd();
const {scopeForUnreadWake}=await import(pathToFileURL(`${root}/.pi/extensions/lib/fm-branch-dispatch.ts`));
const fixture=fs.mkdtempSync(`${root}/.test-validation-tmp/routing-`);
let n=0;
function run(name,records,key,expected,corrupted,{afk=false,extra=false,decision=false}={}) {
 const state=`${fixture}/${++n}`; fs.mkdirSync(state);
 for(const [task,fields] of records) fs.writeFileSync(`${state}/${task}.meta`,fields);
 if(decision)fs.writeFileSync(`${state}/a.status`,'needs-decision: choose owner\n');
 if(extra)fs.writeFileSync(`${state}/other.meta`,'project=/other\n');
 fs.writeFileSync(`${state}/.wake-queue`,`1\t1\tstale\t${key}\tstale: ${key}\n`+(extra?'2\t2\tsignal\tother.status\tsignal: ready\n':''));
 const result=spawnSync(process.execPath,[`${root}/bin/fm-branch-dispatch.mjs`,'offer',...(afk?['--afk']:[])],{encoding:'utf8',env:{...process.env,FM_STATE_OVERRIDE:state},input:`stale: ${key}\n`});
 assert.equal(result.status,0,result.stderr);
 console.log(`SCENARIO ${n}: ${name}\n${result.stdout}`);
 const output=Object.fromEntries(result.stdout.trim().split('\n').map(x=>x.split('=')));
 assert.equal(output.eligible,String(+expected)); assert.equal(output.corrupted,String(+corrupted));
 const scope=scopeForUnreadWake(state,false,afk,true);
 assert.equal(scope.corrupted,corrupted);
 if(expected){assert(scope.eligibleTasks.includes('a')); assert(scope.projects.includes('/approved'));}
}
try{
 for(const key of ['term-1','fm-term-1','fm-a','a','a.status','a.turn-ended'])run(`unique alias ${key}`,[['a','project=/approved\nwindow=fm-a\nterminal=term-1\n']],key,true,false);
 run('same-owner window and terminal alias',[['a','project=/approved\nwindow=term-1\nterminal=term-1\n']],'term-1',true,false);
 run('unknown terminal',[['a','project=/approved\nterminal=term-1\n']],'unknown',false,true);
 for(const project of ['', 'project=\n']){
 run('projectless unique owner',[['a',`${project}terminal=term-1\n`]],'term-1',false,true);
 for(const reverse of [false,true])for(const otherAlias of ['a','a.status','a.turn-ended','win-1','term-1']){
 const records=[['a','project=/approved\nwindow=win-1\nterminal=term-1\n'],[reverse?'0-other':'z-other',`${project}terminal=${otherAlias}\n`]];
 run(`projectless collision ${otherAlias}; competing-owner=${reverse?'0-other':'z-other'}; field=${JSON.stringify(project)}`,reverse?records.reverse():records,'term-1',false,true,{extra:true});
 }
 for(const key of ['fm-window','fm-fm-window'])run(`projectless exact owner cannot borrow prefixed project: ${key}`,[['a',`${project}window=fm-window\n`],['window','project=/approved\n']],key,false,true);
 }
 for(const reverse of [false,true]){
 const rows=[['a','project=/approved\nterminal=term-1\n'],[reverse?'0-other':'z-other','project=/other\nwindow=term-1\n']];
 run('cross-key project-bearing conflict',reverse?rows.reverse():rows,'term-1',false,true,{extra:true});
 }
 run('open decision remains on main despite other eligible task',[['a','project=/approved\nterminal=term-1\n']],'term-1',false,false,{decision:true,extra:true});
 run('away open decision retains valid task ownership',[['a','project=/approved\nterminal=term-1\n']],'term-1',true,false,{decision:true,afk:true});
 console.log(`Completed ${n} real CLI offers plus exported scope checks.`);
}finally{fs.rmSync(fixture,{recursive:true,force:true});}
