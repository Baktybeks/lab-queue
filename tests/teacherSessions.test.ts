import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { PGlite } from '@electric-sql/pglite';

const id = (n: number) => `00000000-0000-0000-0000-${String(n).padStart(12,'0')}`;
async function setup(legacy = false) {
  const db = new PGlite();
  await db.exec(`create role anon;create role authenticated;create role service_role;
    create schema auth;create table auth.users(id uuid primary key,is_anonymous boolean default false,raw_user_meta_data jsonb default '{}');
    create function auth.uid() returns uuid language sql as $$ select nullif(current_setting('app.uid',true),'')::uuid $$;`);
  for(let n=1;n<=4;n++) await db.query('insert into auth.users(id) values($1)',[id(n)]);
  const schema = await readFile(new URL('../supabase/schema.sql',import.meta.url),'utf8');
  await db.exec(legacy ? schema.split('-- Per-teacher session isolation.')[0] : schema);
  await db.query('insert into queue_private.admins values($1),($2),($3)',[id(1),id(2),id(4)]);
  await db.query('insert into queue_private.superadmins values($1)',[id(4)]);
  const actor = async (n: number) => {await db.query("select set_config('app.uid',$1,false)",[id(n)]);};
  const snapshot = async (sid: string | null = null): Promise<any> => (await db.query<{value:any}>(legacy ? 'select public.queue_snapshot() as value' : 'select public.queue_snapshot_for_session($1) as value',legacy ? [] : [sid])).rows[0].value;
  const action = async (name: string,sid: string | null = null,args: object = {}) => {await db.query('select public.queue_action($1,$2::jsonb)',[name,JSON.stringify({session_id:sid,...args})]);};
  return {db,actor,snapshot,action};
}

test('Teachers have independent active sessions, labs, histories, counters, and extra assignments', async () => {
  const {db,actor,snapshot,action} = await setup();
  try {
    await db.exec('set role authenticated');
    await actor(1);await action('create_session',null,{date:'2026-10-21',group:'Группа А'});const a=(await snapshot()).session.id;
    await actor(2);await action('create_session',null,{date:'2026-10-21',group:'Группа Б'});const b=(await snapshot()).session.id;
    assert.notEqual(a,b);
    await assert.rejects(action('create_session',null,{date:'2026-10-21',group:'Вторая Б'}),/Сначала завершите/);
    await action('set_lab',b,{lab:8});
    await actor(1);assert.equal((await snapshot()).lab,6);
    await assert.rejects(snapshot(b),/другого преподавателя/);
    await assert.rejects(action('end_session',b),/другого преподавателя/);
    await actor(3);
    assert.equal((await snapshot()).session,null);
    assert.equal((await snapshot()).available_sessions.length,2);
    await action('join',a,{name:'Один студент',lab:6});
    await action('join',b,{name:'Один студент',lab:6});
    let s=await snapshot(a);const entryA=s.entries[0].id;
    assert.equal(s.entries.length,1);assert.equal(s.entries[0].status,'current');
    s=await snapshot(b);const entryB=s.entries[0].id;
    assert.notEqual(entryA,entryB);assert.equal(s.entries[0].status,'current');assert.equal(s.lab,8);
    await actor(1);await action('next',a,{current_id:entryA});
    await actor(2);assert.equal((await snapshot(b)).entries[0].retries,0);
    await assert.rejects(action('pass',a,{current_id:entryA}),/другого преподавателя/);
    await action('extra',b,{current_id:entryB});
    await actor(1);await action('extra',a,{current_id:entryA});await action('end_session',a);
    s=await snapshot();assert.equal(s.results.every((r:any)=>r.session_id===a),true);assert.equal(s.sessions.length,1);
    await action('create_session',null,{date:'2026-10-22',group:'Новая А'});const nextA=(await snapshot()).session.id;
    await actor(3);await action('join',nextA,{name:'Один студент',lab:6});
    assert.equal((await snapshot(nextA)).entries[0].status,'extra');assert.equal((await snapshot(nextA)).entries[0].retries,1);
    await action('ready',nextA);assert.deepEqual((await snapshot(nextA)).pending_extras,[]);
    assert.equal((await snapshot(b)).pending_extras[0].lab,6);
    assert.equal((await snapshot(b)).entries[0].status,'extra');
    await actor(4);s=await snapshot(b);assert.equal(s.superadmin,true);assert.equal(s.available_sessions.length,2);assert.equal(s.sessions.length,3);
    await db.query('select public.queue_delete_session($1)',[a]);
    assert.equal((await snapshot(b)).entries[0].status,'extra');
    await actor(2);await action('end_session',b);
    await actor(1);assert.equal((await snapshot(nextA)).entries.length,1);
  } finally {await db.close();}
});

test('Upgrade preserves existing queues, owner, lab settings, results, and pending extras', async () => {
  const {db,actor,snapshot,action} = await setup(true);
  try {
    await actor(1);await action('create_session',null,{date:'2026-10-21',group:'Старая группа'});const sid=(await snapshot()).session.id;
    await action('set_lab',sid,{lab:8});
    await actor(3);await action('join',sid,{name:'Студент',lab:8});const entry=(await snapshot()).entries[0].id;
    await actor(1);await action('extra',sid,{current_id:entry});
    const migration=await readFile(new URL('../supabase/migrations/014_teacher_sessions.sql',import.meta.url),'utf8');
    await db.exec(migration);
    await db.exec(migration);
    const s=(await db.query<{value:any}>('select public.queue_snapshot_for_session($1) as value',[sid])).rows[0].value;
    assert.equal(s.session.created_by,id(1));assert.equal(s.lab,8);assert.equal(s.entries[0].id,entry);assert.equal(s.entries[0].status,'extra');
    const pending=(await db.query<{teacher_id:string}>('select teacher_id from queue_private.pending_extras')).rows[0];
    assert.equal(pending.teacher_id,id(1));
    await actor(2);await action('create_session',null,{date:'2026-10-21',group:'Другая группа'});
    const other=(await db.query<{value:any}>('select public.queue_snapshot_for_session(null) as value')).rows[0].value;
    assert.equal(other.lab,6);assert.equal(other.entries.length,0);
  } finally {await db.close();}
});

test('Extra markers persist, while carried tasks return to FIFO instead of jumping ahead', async () => {
  const {db,actor,snapshot,action}=await setup();
  try {
    await db.query('insert into auth.users(id) values($1)',[id(5)]);
    await db.exec('set role authenticated');
    await actor(1);await action('create_session',null,{date:'2026-10-21',group:'А'});let sid=(await snapshot()).session.id;
    await actor(3);await action('join',sid,{name:'С допзаданием',lab:6});let entry=(await snapshot(sid)).entries[0];
    await actor(1);await action('extra',sid,{current_id:entry.id});
    await actor(5);await action('join',sid,{name:'Другой студент',lab:6});
    await actor(3);await action('ready',sid);let s=await snapshot(sid);
    entry=s.entries.find((e:any)=>e.mine);assert.equal(entry.had_extra,true);assert.equal(entry.ready,true);
    await actor(1);await action('next',sid,{current_id:s.entries.find((e:any)=>e.status==='current').id});
    await action('next',sid,{current_id:entry.id});
    s=await snapshot(sid);assert.equal(s.entries.find((e:any)=>e.id===entry.id).had_extra,true);
    await action('pass',sid,{current_id:s.entries.find((e:any)=>e.status==='current').id});
    await action('extra',sid,{current_id:entry.id});await action('end_session',sid);
    await action('create_session',null,{date:'2026-10-22',group:'А'});sid=(await snapshot()).session.id;
    await actor(5);await action('join',sid,{name:'Первый сегодня',lab:5});
    await actor(3);await action('join',sid,{name:'С допзаданием',lab:6});
    s=await snapshot(sid);entry=s.entries.find((e:any)=>e.mine);
    assert.equal(entry.carried_extra,true);assert.equal(entry.status,'extra');
    await actor(2);await action('join',sid,{name:'Уже в очереди',lab:5});
    await actor(3);await action('ready',sid);s=await snapshot(sid);entry=s.entries.find((e:any)=>e.mine);
    assert.equal(entry.ready,false);assert.equal(entry.priority,false);assert.equal(entry.had_extra,true);assert.equal(entry.carried_extra,true);
    assert.equal(s.entries.filter((e:any)=>e.status==='waiting').sort((a:any,b:any)=>a.position-b.position).at(-1).id,entry.id);
    await actor(1);await action('end_session',sid);s=await snapshot();
    assert.equal(s.results.find((r:any)=>r.id===entry.id).had_extra,true);
    assert.equal(s.results.find((r:any)=>r.id===entry.id).carried_extra,true);
  } finally {await db.close();}
});

test('Medals count only issued extras; gold requires first success; session end records failure except pending extras', async () => {
  const {db,actor,snapshot,action}=await setup();
  try {
    await db.query('insert into auth.users(id) values($1)',[id(5)]);
    await db.exec('set role authenticated');
    await actor(1);await action('create_session',null,{date:'2026-10-21',group:'А'});let sid=(await snapshot()).session.id;
    await actor(3);await action('join',sid,{name:'Первый раз',lab:6});let entry=(await snapshot(sid)).entries[0];
    await actor(1);await action('pass',sid,{current_id:entry.id});
    assert.equal((await snapshot(sid)).results.find((r:any)=>r.id===entry.id).first_try_pass,true);
    await actor(3);await action('join',sid,{name:'Первый раз',lab:6});entry=(await snapshot(sid)).entries[0];
    await actor(1);await action('pass',sid,{current_id:entry.id});
    assert.equal((await snapshot(sid)).results.find((r:any)=>r.id===entry.id).first_try_pass,false);
    await actor(5);await action('join',sid,{name:'С допами',lab:7});entry=(await snapshot(sid)).entries[0];
    for(let count=1;count<=2;count++) {
      await actor(1);await action('extra',sid,{current_id:entry.id});
      await actor(5);assert.equal((await snapshot(sid)).entries[0].extra_count,count);
      await action('ready',sid);assert.equal((await snapshot(sid)).entries[0].extra_count,count);
    }
    await actor(1);await action('next',sid,{current_id:entry.id});
    let s=await snapshot(sid);assert.equal(s.entries[0].extra_count,2);assert.equal(s.entries[0].retries,1);
    await action('extra',sid,{current_id:entry.id});await action('end_session',sid);
    s=await snapshot();let result=s.results.find((r:any)=>r.id===entry.id);assert.equal(result.outcome,'extra');assert.equal(result.extra_count,3);
    await action('create_session',null,{date:'2026-10-22',group:'А'});sid=(await snapshot()).session.id;
    await actor(5);await action('join',sid,{name:'С допами',lab:7});s=await snapshot(sid);entry=s.entries[0];
    assert.equal(entry.extra_count,3);assert.equal(entry.carried_extra,true);
    await action('ready',sid);assert.equal((await snapshot(sid)).entries[0].extra_count,3);
    await actor(1);await action('end_session',sid);result=(await snapshot()).results.find((r:any)=>r.id===entry.id);
    assert.equal(result.outcome,'failed');assert.equal(result.first_try_pass,false);assert.equal(result.extra_count,3);
  } finally {await db.close();}
});

test('Student can undo extra readiness, including carried extras, without additional medals or retries', async () => {
  const {db,actor,snapshot,action}=await setup();
  try {
    await db.exec('set role authenticated');
    await actor(1);await action('create_session',null,{date:'2026-10-21',group:'А'});let sid=(await snapshot()).session.id;
    await actor(3);await action('join',sid,{name:'Студент',lab:6});let entry=(await snapshot(sid)).entries[0];
    await assert.rejects(action('return_extra',sid),/Вернуться можно только/);
    await actor(1);await action('extra',sid,{current_id:entry.id});
    await actor(2);await action('join',sid,{name:'Другой',lab:6});
    await actor(3);await action('ready',sid);await action('return_extra',sid);
    let s=await snapshot(sid);entry=s.entries.find((e:any)=>e.mine);
    assert.equal(entry.status,'extra');assert.equal(entry.extra_count,1);assert.equal(entry.retries,0);
    await assert.rejects(action('return_extra',sid),/Вернуться можно только/);
    await actor(2);await assert.rejects(action('return_extra',sid),/Вернуться можно только/);
    await actor(3);await action('ready',sid);
    await actor(1);s=await snapshot(sid);await action('next',sid,{current_id:s.entries.find((e:any)=>e.status==='current').id});
    await actor(3);assert.equal((await snapshot(sid)).entries.find((e:any)=>e.mine).status,'current');
    await action('return_extra',sid);s=await snapshot(sid);assert.notEqual(s.entries.find((e:any)=>e.status==='current').id,entry.id);
    await actor(1);await action('end_session',sid);await action('create_session',null,{date:'2026-10-22',group:'А'});sid=(await snapshot()).session.id;
    await actor(2);await action('join',sid,{name:'Другой',lab:6});
    await actor(3);await action('join',sid,{name:'Студент',lab:6});await action('ready',sid);await action('return_extra',sid);
    s=await snapshot(sid);entry=s.entries.find((e:any)=>e.mine);
    assert.equal(entry.status,'extra');assert.equal(entry.carried_extra,true);assert.equal(entry.extra_count,1);assert.equal(entry.retries,0);
    await action('ready',sid);s=await snapshot(sid);assert.equal(s.entries.find((e:any)=>e.mine).ready,false);
    await actor(1);await action('next',sid,{current_id:s.entries.find((e:any)=>e.status==='current').id});
    s=await snapshot(sid);await action('next',sid,{current_id:s.entries.find((e:any)=>e.status==='current').id});
    await actor(3);await assert.rejects(action('return_extra',sid),/Вернуться можно только/);
  } finally {await db.close();}
});

test('Only the owning teacher can admit one deferred student after the current turn', async () => {
  const {db,actor,snapshot,action}=await setup();
  try {
    await db.query('insert into auth.users(id) values($1),($2)',[id(5),id(6)]);
    await db.exec('set role authenticated');
    await actor(1);await action('create_session',null,{date:'2026-10-21',group:'А'});const sid=(await snapshot()).session.id;
    await actor(3);await action('join',sid,{name:'Готовится',lab:6});let s=await snapshot(sid);const regular=s.entries[0].id;
    await actor(5);await action('join',sid,{name:'Гость 1',lab:6,off_schedule:true});const guest1=(await snapshot(sid)).entries.find((e:any)=>e.mine).id;
    await actor(6);await action('join',sid,{name:'Гость 2',lab:6,off_schedule:true});const guest2=(await snapshot(sid)).entries.find((e:any)=>e.mine).id;
    await assert.rejects(action('admit_deferred',sid,{entry_id:guest2}),/только преподавателю/);
    await actor(2);await assert.rejects(action('admit_deferred',sid,{entry_id:guest2}),/другого преподавателя/);
    await actor(1);await action('admit_deferred',sid,{entry_id:guest1});s=await snapshot(sid);
    assert.equal(s.entries.find((e:any)=>e.id===regular).status,'current');
    assert.equal(s.entries.find((e:any)=>e.id===guest1).status,'waiting');
    await assert.rejects(action('admit_deferred',sid,{entry_id:guest2}),/освобождения очереди/);
    await action('set_lab',sid,{lab:5});
    assert.equal((await snapshot(sid)).entries.find((e:any)=>e.id===guest1).status,'waiting');
    await action('extra',sid,{current_id:regular});s=await snapshot(sid);
    assert.equal(s.entries.find((e:any)=>e.id===guest1).status,'current');
    assert.equal(s.entries.find((e:any)=>e.id===guest2).status,'deferred');
    assert.equal(s.entries.find((e:any)=>e.id===regular).status,'extra');
    assert.equal(s.entries.find((e:any)=>e.id===guest1).extra_count,0);
    assert.equal(s.entries.find((e:any)=>e.id===guest1).retries,0);
    await action('admit_deferred',sid,{entry_id:guest2});
    await assert.rejects(action('admit_deferred',sid,{entry_id:guest2}),/освобождения очереди/);
    assert.equal((await snapshot(sid)).entries.find((e:any)=>e.id===guest2).status,'waiting');
    await action('pass',sid,{current_id:guest1});
    await actor(3);await action('ready',sid);
    await actor(1);await action('next',sid,{current_id:guest2});s=await snapshot(sid);
    assert.equal(s.entries.find((e:any)=>e.status==='current').id,regular);
  } finally {await db.close();}
});

test('Teacher can park and resume students to free admission without altering counters', async () => {
  const {db,actor,snapshot,action}=await setup();
  try {
    await db.query('insert into auth.users(id) values($1),($2)',[id(5),id(6)]);
    await db.exec('set role authenticated');
    await actor(1);await action('create_session',null,{date:'2026-10-21',group:'А'});const sid=(await snapshot()).session.id;
    await actor(3);await action('join',sid,{name:'Текущий',lab:6});const current=(await snapshot(sid)).entries.find((e:any)=>e.mine).id;
    await actor(5);await action('join',sid,{name:'Не готов',lab:6});const waiting=(await snapshot(sid)).entries.find((e:any)=>e.mine).id;
    await actor(6);await action('join',sid,{name:'Не по графику',lab:6,off_schedule:true});const guest=(await snapshot(sid)).entries.find((e:any)=>e.mine).id;
    await assert.rejects(action('pause_waiting',sid),/только преподавателю/);
    await actor(2);await assert.rejects(action('pause_entry',sid,{entry_id:waiting}),/другого преподавателя/);
    await actor(1);await action('pause_waiting',sid);let s=await snapshot(sid);
    assert.equal(s.entries.find((e:any)=>e.id===current).status,'current');assert.equal(s.entries.find((e:any)=>e.id===waiting).status,'paused');
    await action('admit_deferred',sid,{entry_id:guest});await action('pause_entry',sid,{entry_id:current});
    s=await snapshot(sid);assert.equal(s.entries.find((e:any)=>e.status==='current').id,guest);
    assert.equal(s.entries.find((e:any)=>e.id===current).retries,0);assert.equal(s.entries.find((e:any)=>e.id===current).extra_count,0);
    await action('resume_entry',sid,{entry_id:waiting});await action('resume_entry',sid,{entry_id:current});s=await snapshot(sid);
    const ordered=s.entries.filter((e:any)=>e.status==='waiting').sort((a:any,b:any)=>a.position-b.position);
    assert.deepEqual(ordered.map((e:any)=>e.id),[waiting,current]);assert.equal(ordered[1].priority,false);
    await assert.rejects(action('resume_entry',sid,{entry_id:current}),/больше не находится/);
    await action('pause_entry',sid,{entry_id:waiting});await action('end_session',sid);s=await snapshot();
    assert.equal(s.results.find((r:any)=>r.id===waiting).outcome,'failed');assert.equal(s.results.find((r:any)=>r.id===waiting).retries,0);
  } finally {await db.close();}
});

test('An empty queue automatically calls only one off-schedule student and leaves extra/paused students untouched', async () => {
  const {db,actor,snapshot,action}=await setup();
  try {
    await db.query('insert into auth.users(id) values($1),($2)',[id(5),id(6)]);
    await db.exec('set role authenticated');
    await actor(1);await action('create_session',null,{date:'2026-10-22',group:'А'});const sid=(await snapshot()).session.id;
    await actor(3);await action('join',sid,{name:'Основной',lab:6});const main=(await snapshot(sid)).entries[0].id;
    await actor(5);await action('join',sid,{name:'Гость первый',lab:6,off_schedule:true});const guest1=(await snapshot(sid)).entries.find((e:any)=>e.mine).id;
    await actor(6);await action('join',sid,{name:'Гость второй',lab:6,off_schedule:true});const guest2=(await snapshot(sid)).entries.find((e:any)=>e.mine).id;
    await actor(1);await action('extra',sid,{current_id:main});let s=await snapshot(sid);
    assert.equal(s.entries.find((e:any)=>e.status==='current').id,guest1);
    assert.equal(s.entries.find((e:any)=>e.id===guest2).status,'deferred');
    assert.equal(s.entries.find((e:any)=>e.id===main).status,'extra');
    assert.equal(s.entries.find((e:any)=>e.id===guest1).retries,0);assert.equal(s.entries.find((e:any)=>e.id===guest1).extra_count,0);
    await action('pause_entry',sid,{entry_id:guest1});s=await snapshot(sid);
    assert.equal(s.entries.find((e:any)=>e.status==='current').id,guest2);assert.equal(s.entries.find((e:any)=>e.id===guest1).status,'paused');
    await action('pass',sid,{current_id:guest2});s=await snapshot(sid);
    assert.equal(s.entries.some((e:any)=>e.status==='current'),false);
    await actor(5);await action('leave',sid);await action('join',sid,{name:'Гость первый',lab:6,off_schedule:true});s=await snapshot(sid);
    assert.equal(s.entries.find((e:any)=>e.status==='current').name,'Гость первый');
    await db.exec('reset role');
    // Reproduce an already-empty session from the old implementation and reconcile on upgrade.
    await db.query("update queue_private.entries set status='deferred' where session_id=$1 and status='current'",[sid]);
    await db.exec(await readFile(new URL('../supabase/migrations/021_auto_call_off_schedule.sql',import.meta.url),'utf8'));
    await actor(1);s=await snapshot(sid);assert.equal(s.entries.filter((e:any)=>e.status==='current').length,1);
    assert.equal(s.results.find((r:any)=>r.id===s.entries.find((e:any)=>e.status==='current').id).outcome,'current');
  } finally {await db.close();}
});

test('Teacher restores old extra assignments from any queue status without priority or duplicate medals',async()=>{
 const {db,actor,snapshot,action}=await setup();
 try{
 for(const n of [5,6,7])await db.query('insert into auth.users(id) values($1)',[id(n)]);
 await db.exec('set role authenticated');await actor(1);await action('create_session',null,{date:'2026-10-23',group:'Legacy'});const sid=(await snapshot()).session.id;
 await actor(3);await action('join',sid,{name:'Current',lab:6});const current=(await snapshot(sid)).entries.find((e:any)=>e.mine).id;
 const entries:any={};for(const n of [5,6,7]){await actor(n);await action('join',sid,{name:`Student ${n}`,lab:6,off_schedule:n===6});entries[n]=(await snapshot(sid)).entries.find((e:any)=>e.mine).id;}
 await assert.rejects(action('restore_extra',sid,{entry_id:entries[6]}),/преподавателю/);
 await actor(2);await assert.rejects(action('restore_extra',sid,{entry_id:entries[6]}),/другого преподавателя/);
 await actor(1);await action('pause_entry',sid,{entry_id:entries[7]});
 for(const n of [5,6,7]){await action('restore_extra',sid,{entry_id:entries[n]});const e=(await snapshot(sid)).entries.find((e:any)=>e.id===entries[n]);assert.equal(e.status,'extra');assert.equal(e.carried_extra,true);assert.equal(e.extra_count,1);assert.equal(e.retries,0);await assert.rejects(action('restore_extra',sid,{entry_id:entries[n]}),/больше не находится/);}
 assert.equal((await snapshot(sid)).entries.find((e:any)=>e.status==='current').id,current);
 await actor(5);await action('ready',sid);let s=await snapshot(sid);let e=s.entries.find((e:any)=>e.mine);assert.equal(e.status,'waiting');assert.equal(e.ready,false);assert.equal(e.priority,false);assert.equal(e.extra_count,1);
 await actor(1);await action('restore_extra',sid,{entry_id:current});s=await snapshot(sid);assert.equal(s.entries.find((e:any)=>e.id===current).status,'extra');assert.equal(s.entries.find((e:any)=>e.status==='current').id,entries[5]);
 await action('end_session',sid);await action('create_session',null,{date:'2026-10-24',group:'Next'});const nextSid=(await snapshot()).session.id;
 await actor(6);await action('join',nextSid,{name:'Student 6',lab:6});e=(await snapshot(nextSid)).entries.find((e:any)=>e.mine);assert.equal(e.status,'extra');assert.equal(e.carried_extra,true);assert.equal(e.extra_count,1);
 }finally{await db.close();}
});

test('Automatically admitted off-schedule student stays FIFO after Next and old deferred retries are repaired',async()=>{
 const {db,actor,snapshot,action}=await setup();
 try{
 await db.query('insert into auth.users(id) values($1)',[id(5)]);await db.exec('set role authenticated');await actor(1);await action('create_session',null,{date:'2026-10-26',group:'Retry'});const sid=(await snapshot()).session.id;
 await actor(5);await action('join',sid,{name:'Guest',lab:1,off_schedule:true});let s=await snapshot(sid);const guest=s.entries.find((e:any)=>e.mine).id;assert.equal(s.entries.find((e:any)=>e.id===guest).status,'current');
 await actor(3);await action('join',sid,{name:'Scheduled',lab:6});const main=(await snapshot(sid)).entries.find((e:any)=>e.mine).id;
 await actor(1);await action('next',sid,{current_id:guest});s=await snapshot(sid);assert.equal(s.entries.find((e:any)=>e.id===main).status,'current');assert.equal(s.entries.find((e:any)=>e.id===guest).status,'waiting');assert.equal(s.entries.find((e:any)=>e.id===guest).retries,1);
 await action('next',sid,{current_id:main});s=await snapshot(sid);assert.equal(s.entries.find((e:any)=>e.id===guest).status,'current');
 await action('next',sid,{current_id:guest});s=await snapshot(sid);assert.equal(s.entries.find((e:any)=>e.id===guest).status,'waiting');assert.equal(s.entries.find((e:any)=>e.id===guest).retries,2);
 await db.exec('reset role');await db.query("update queue_private.entries set status='deferred',manually_admitted=false where id=$1",[guest]);await db.query("update queue_private.results set outcome='deferred' where id=$1",[guest]);
 await db.exec(await readFile(new URL('../supabase/migrations/025_keep_admitted_retries.sql',import.meta.url),'utf8'));s=await snapshot(sid);assert.equal(s.entries.find((e:any)=>e.id===guest).status,'waiting');assert.equal(s.entries.find((e:any)=>e.id===main).status,'current');assert.equal(s.results.find((r:any)=>r.id===guest).outcome,'waiting');assert.equal(s.entries.find((e:any)=>e.id===guest).retries,2);
 }finally{await db.close();}
});

test('Teacher admits completed legacy extras ahead of normal queue with FIFO and no interruption',async()=>{
 const {db,actor,snapshot,action}=await setup();
 try{
 for(const n of [5,6])await db.query('insert into auth.users(id) values($1)',[id(n)]);
 await db.exec('set role authenticated');await actor(1);await action('create_session',null,{date:'2026-10-26',group:'Priority'});const sid=(await snapshot()).session.id;
 await actor(3);await action('join',sid,{name:'Current',lab:6});const current=(await snapshot(sid)).entries.find((e:any)=>e.mine).id;
 const guests:any={};for(const n of [5,6]){await actor(n);await action('join',sid,{name:`Guest ${n}`,lab:1,off_schedule:true});guests[n]=(await snapshot(sid)).entries.find((e:any)=>e.mine).id;}
 await assert.rejects(action('admit_ready_extra',sid,{entry_id:guests[5]}),/преподавателю/);await actor(2);await assert.rejects(action('admit_ready_extra',sid,{entry_id:guests[5]}),/другого преподавателя/);
 await actor(1);await action('restore_extra',sid,{entry_id:guests[5]});await action('admit_ready_extra',sid,{entry_id:guests[5]});await assert.rejects(action('admit_ready_extra',sid,{entry_id:guests[5]}),/уже вызван/);await action('admit_ready_extra',sid,{entry_id:guests[6]});
 let s=await snapshot(sid);assert.equal(s.entries.find((e:any)=>e.status==='current').id,current);let waiting=s.entries.filter((e:any)=>e.status==='waiting').sort((a:any,b:any)=>a.position-b.position);assert.deepEqual(waiting.map((e:any)=>e.id),[guests[5],guests[6]]);assert.equal(waiting[0].extra_count,1);assert.equal(waiting[0].retries,0);assert.equal(waiting[0].carried_extra,true);
 await action('next',sid,{current_id:current});s=await snapshot(sid);assert.equal(s.entries.find((e:any)=>e.status==='current').id,guests[5]);
 await actor(5);await action('return_extra',sid);s=await snapshot(sid);assert.equal(s.entries.find((e:any)=>e.mine).status,'extra');assert.equal(s.entries.find((e:any)=>e.mine).extra_count,1);assert.equal(s.entries.find((e:any)=>e.status==='current').id,guests[6]);
 await actor(1);await action('pass',sid,{current_id:guests[6]});await action('pause_entry',sid,{entry_id:current});await action('admit_ready_extra',sid,{entry_id:guests[5]});s=await snapshot(sid);assert.equal(s.entries.find((e:any)=>e.status==='current').id,guests[5]);assert.equal(s.entries.find((e:any)=>e.id===guests[5]).extra_count,1);
 }finally{await db.close();}
});

test('Light queue excludes archives; on-demand results are scoped to one authorized session',async()=>{
 const {db,actor,snapshot,action}=await setup();
 try{
 await db.exec('set role authenticated');
 await actor(1);await action('create_session',null,{date:'2026-10-26',group:'A'});const a=(await snapshot()).session.id;
 await actor(2);await action('create_session',null,{date:'2026-10-26',group:'B'});const b=(await snapshot()).session.id;
 await actor(3);await action('join',a,{name:'Student A',lab:6});const student=(await snapshot(a)).entries.find((e:any)=>e.mine).id;
 const live=async(sid:string|null)=>(await db.query<{value:any}>('select public.queue_live_snapshot($1) as value',[sid])).rows[0].value;
 const list=async()=>(await db.query<{value:any}>('select public.queue_history_sessions() as value')).rows[0].value;
 const results=async(sid:string)=>(await db.query<{value:any}>('select public.queue_session_results($1) as value',[sid])).rows[0].value;
 await assert.rejects(list(),/преподавателю/);await assert.rejects(results(a),/преподавателю/);
 await actor(1);let s=await live(null);assert.equal(s.session.id,a);assert.equal(s.entries[0].id,student);assert.equal('results' in s,false);assert.equal('sessions' in s,false);assert.equal(s.passed_count,0);assert.equal((await list()).length,1);assert.equal((await results(a)).length,1);
 await assert.rejects(results(b),/другого преподавателя/);await assert.rejects(live(b),/другого преподавателя/);
 await action('pass',a,{current_id:student});s=await live(null);assert.equal(s.passed_count,1);assert.equal(s.entries.length,0);assert.equal('results' in s,false);
 await action('end_session',a);assert.equal((await results(a))[0].outcome,'passed');assert.equal((await live(null)).session,null);
 await actor(2);assert.equal((await results(b)).length,0);await assert.rejects(results(a),/другого преподавателя/);
 await actor(4);assert.equal((await list()).length,2);assert.equal((await results(a))[0].name,'Student A');assert.deepEqual(await results(b),[]);await assert.rejects(results(id(99)),/не найдена/);
 await db.query("select set_config('app.uid','',false)");await assert.rejects(list(),/преподавателю/);await assert.rejects(live(null),/Войдите/);
 await db.exec('set role anon');await assert.rejects(list(),/permission denied/);await assert.rejects(results(a),/permission denied/);await assert.rejects(live(null),/permission denied/);
 }finally{await db.close();}
});

test('Session opens atomically with the chosen initial lab; invalid choices never open a session',async()=>{
 const {db,actor,snapshot,action}=await setup();
 try{
 await db.exec('set role authenticated');await actor(1);await action('create_session',null,{date:'2026-10-28',group:'Lab 8',lab:8});let s=await snapshot();const sid=s.session.id;assert.equal(s.lab,8);assert.equal(s.session.lab,8);
 await actor(2);await assert.rejects(action('create_session',null,{date:'2026-10-28',group:'Invalid',lab:100}),/Номер лабы/);assert.equal((await snapshot()).session,null);await action('create_session',null,{date:'2026-10-28',group:'Lab 4',lab:4});assert.equal((await snapshot()).lab,4);
 await actor(3);await action('join',sid,{name:'First student',lab:8});s=await snapshot(sid);assert.equal(s.lab,8);assert.equal(s.entries.find((e:any)=>e.mine).priority,true);
 await actor(1);await action('set_lab',sid,{lab:7});assert.equal((await snapshot()).lab,7);
 await actor(4);await action('create_session',null,{date:'2026-10-28',group:'Old client'});assert.equal((await snapshot()).lab,6);
 }finally{await db.close();}
});

test('Students joining after an active lab change get the new lab priority',async()=>{
 const {db,actor,snapshot,action}=await setup();
 try{
 await db.query('insert into auth.users(id) values($1),($2)',[id(5),id(6)]);await db.exec('set role authenticated');await actor(1);await action('create_session',null,{date:'2026-10-30',group:'Priority change',lab:6});const sid=(await snapshot()).session.id;
 await actor(3);await action('join',sid,{name:'Current',lab:6});await actor(5);await action('join',sid,{name:'Older work',lab:2});await actor(1);await action('set_lab',sid,{lab:7});
 await actor(6);await action('join',sid,{name:'New actual work',lab:7});const s=await snapshot(sid);const mine=s.entries.find((e:any)=>e.mine);assert.equal(s.lab,7);assert.equal(mine.priority,true);assert.equal(s.entries.filter((e:any)=>e.status==='waiting').sort((a:any,b:any)=>a.position-b.position)[0].id,mine.id);
 }finally{await db.close();}
});

test('Priority repair upgrades legacy creation and restores eligible waiting students without interrupting current',async()=>{
 const {db,actor,snapshot,action}=await setup();try{
 await db.query('insert into auth.users(id) values($1),($2)',[id(5),id(6)]);await db.exec('set role authenticated');await actor(1);await action('create_session',null,{date:'2026-10-30',group:'Repair',lab:6});const sid=(await snapshot()).session.id;
 await actor(3);await action('join',sid,{name:'Current',lab:2});const current=(await snapshot(sid)).entries.find((e:any)=>e.mine).id;
 await actor(5);await action('join',sid,{name:'Lab seven',lab:7});const seven=(await snapshot(sid)).entries.find((e:any)=>e.mine).id;
 await actor(6);await action('join',sid,{name:'Old lab',lab:2});await actor(1);await action('set_lab',sid,{lab:7});await db.exec('reset role');await db.query('update queue_private.entries set priority=false where id=$1',[seven]);assert.equal((await snapshot(sid)).entries.find((e:any)=>e.id===seven).priority,false);
 await db.exec('reset role');await db.exec(await readFile(new URL('../supabase/migrations/029_repair_initial_priority.sql',import.meta.url),'utf8'));let s=await snapshot(sid);assert.equal(s.entries.find((e:any)=>e.status==='current').id,current);assert.equal(s.entries.find((e:any)=>e.id===seven).priority,true);assert.equal(s.entries.filter((e:any)=>e.status==='waiting').sort((a:any,b:any)=>a.position-b.position)[0].id,seven);
 await db.exec(await readFile(new URL('../supabase/migrations/029_repair_initial_priority.sql',import.meta.url),'utf8'));s=await snapshot(sid);assert.equal(s.entries.find((e:any)=>e.id===seven).retries,0);
 }finally{await db.close();}
});

test('Changing the actual lab recalculates existing waiting priority without interrupting current',async()=>{
 const {db,actor,snapshot,action}=await setup();try{
 await db.query('insert into auth.users(id) values($1),($2)',[id(5),id(6)]);await db.exec('set role authenticated');await actor(1);await action('create_session',null,{date:'2026-10-30',group:'Reorder',lab:7});const sid=(await snapshot()).session.id;
 await actor(3);await action('join',sid,{name:'Current',lab:2});const current=(await snapshot(sid)).entries.find((e:any)=>e.mine).id;
 await actor(5);await action('join',sid,{name:'Seven',lab:7});const seven=(await snapshot(sid)).entries.find((e:any)=>e.mine).id;
 await actor(6);await action('join',sid,{name:'Six',lab:6});const six=(await snapshot(sid)).entries.find((e:any)=>e.mine).id;
 await actor(1);await action('set_lab',sid,{lab:6});let s=await snapshot(sid);assert.equal(s.entries.find((e:any)=>e.status==='current').id,current);assert.equal(s.entries.find((e:any)=>e.id===seven).priority,false);assert.equal(s.entries.find((e:any)=>e.id===six).priority,true);assert.equal(s.entries.filter((e:any)=>e.status==='waiting').sort((a:any,b:any)=>a.position-b.position)[0].id,six);
 await action('set_lab',sid,{lab:7});s=await snapshot(sid);assert.equal(s.entries.find((e:any)=>e.id===seven).priority,true);assert.equal(s.entries.find((e:any)=>e.id===six).priority,false);
 await action('next',sid,{current_id:current});await action('next',sid,{current_id:seven});await action('set_lab',sid,{lab:7});s=await snapshot(sid);assert.equal(s.entries.find((e:any)=>e.id===seven).priority,false);assert.equal(s.entries.find((e:any)=>e.id===seven).retries,1);
 }finally{await db.close();}
});
