import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { PGlite } from '@electric-sql/pglite';

test('Extra status survives session closure, resumes for same lab, and clears on readiness', async () => {
  const db = new PGlite();
  const admin = '00000000-0000-0000-0000-000000000001';
  const student = '00000000-0000-0000-0000-000000000002';
  const actor = async (id: string) => {await db.query("select set_config('app.uid',$1,false)",[id]);};
  const snapshot = async (): Promise<any> => (await db.query<{value:any}>('select public.queue_snapshot() as value')).rows[0].value;
  let sid: string;
  const act = async (action: string,args: object = {}) => {await db.query('select public.queue_action($1,$2::jsonb)',[action,JSON.stringify({session_id:sid,...args})]);};
  const open = async (date: string) => {await actor(admin);await act('create_session',{date,group:'Пи-4-26'});sid=(await snapshot()).session.id;};
  try {
    await db.exec(`create role anon;create role authenticated;create role service_role;
      create schema auth;create table auth.users(id uuid primary key,is_anonymous boolean default false,raw_user_meta_data jsonb default '{}');
      create function auth.uid() returns uuid language sql as $$ select nullif(current_setting('app.uid',true),'')::uuid $$;`);
    await db.query('insert into auth.users(id) values($1),($2)',[admin,student]);
    await db.exec(await readFile(new URL('../supabase/schema.sql',import.meta.url),'utf8'));
    await db.exec(await readFile(new URL('../supabase/migrations/016_lab_medals.sql',import.meta.url),'utf8'));
    await db.query('insert into queue_private.admins values($1)',[admin]);
    await db.exec('set role authenticated');
    await open('2026-10-21');const firstSid=sid;
    await actor(student);await act('join',{name:'Доктурбеков Азирет Жоомартович',lab:6});
    let s=await snapshot();const entryId=s.entries[0].id;
    await actor(admin);await act('extra',{current_id:entryId});await act('end_session');s=await snapshot();
    assert.equal(s.results.find((r:any)=>r.id===entryId).outcome,'extra');
    assert.equal(s.entries.length,0);
    await actor(student);await db.exec('reset role');assert.equal((await db.query('select lab from queue_private.pending_extras')).rows[0].lab,6);await db.exec('set role authenticated');
    await open('2026-10-22');
    await actor(student);await act('join',{name:'Доктурбеков Азирет Жоомартович',lab:5});
    assert.equal((await snapshot()).entries[0].status,'current');
    await act('leave');await act('join',{name:'Доктурбеков Азирет Жоомартович',lab:6});
    s=await snapshot();assert.equal(s.entries[0].status,'extra');assert.equal(s.entries[0].priority,false);
    await act('ready');s=await snapshot();assert.equal(s.entries[0].status,'current');assert.deepEqual(s.pending_extras,[]);
    await actor(admin);await act('pass',{current_id:s.entries[0].id});await act('end_session');
    await open('2026-10-23');await actor(student);await act('join',{name:'Доктурбеков Азирет Жоомартович',lab:6});
    s=await snapshot();assert.equal(s.entries[0].status,'current');
    // Simulate the already archived result shown in the screenshot and validate the targeted repair.
    await db.exec('reset role');
    await db.query("update queue_private.results set outcome='unfinished' where id=$1",[entryId]);
    await db.exec(await readFile(new URL('../supabase/restore_dokturbekov_extra.sql',import.meta.url),'utf8'));
    const old = await db.query<{outcome:string}>('select outcome from queue_private.results where session_id=$1',[firstSid]);
    assert.equal(old.rows[0].outcome,'extra');
    // A later successful pass prevents restoring a stale pending assignment.
    assert.deepEqual((await snapshot()).pending_extras,[]);
  } finally {await db.close();}
});
