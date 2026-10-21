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
