import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { PGlite } from '@electric-sql/pglite';

test('Off-schedule guests wait through repeated turns, then join FIFO; extras and current remain protected', async () => {
  const db = new PGlite();
  const id = (n: number) => `00000000-0000-0000-0000-${String(n).padStart(12,'0')}`;
  const actor = async (n: number) => {await db.query("select set_config('app.uid',$1,false)",[id(n)]);};
  const snapshot = async (): Promise<any> => (await db.query<{value:any}>('select public.queue_snapshot() as value')).rows[0].value;
  let sid: string;
  const act = async (action: string,payload: object = {}) => {await db.query('select public.queue_action($1,$2::jsonb)',[action,JSON.stringify({session_id:sid,...payload})]);};
  const turn = async (action: string) => {await actor(1);const s=await snapshot();await act(action,{current_id:s.entries.find((e:any)=>e.status==='current')?.id});};
  try {
    await db.exec(`create role anon;create role authenticated;create role service_role;
      create schema auth;create table auth.users(id uuid primary key,is_anonymous boolean default false,raw_user_meta_data jsonb default '{}');
      create function auth.uid() returns uuid language sql as $$ select nullif(current_setting('app.uid',true),'')::uuid $$;`);
    for(let n=1;n<=5;n++) await db.query('insert into auth.users(id) values($1)',[id(n)]);
    await db.exec(await readFile(new URL('../supabase/schema.sql',import.meta.url),'utf8'));
    // Reapplying the migration must preserve existing users and work without renaming functions.
    await db.exec(await readFile(new URL('../supabase/migrations/016_lab_medals.sql',import.meta.url),'utf8'));
    await db.query('insert into queue_private.admins values($1)',[id(1)]);
    await db.exec('set role authenticated');
    await actor(1);await act('create_session',{date:'2026-10-21',group:'ПИ-4-26'});sid=(await snapshot()).session.id;
    await actor(2);await act('join',{name:'Основной А',lab:5});
    await actor(3);await act('join',{name:'Основной Б',lab:6});
    await actor(4);await act('join',{name:'Гость А',lab:6,off_schedule:true});
    let s=await snapshot();
    assert.equal(s.entries.find((e:any)=>e.mine).status,'deferred');
    await assert.rejects(act('ready'),/не на доп/);
    await actor(5);await act('join',{name:'Гость Б',lab:6,off_schedule:true});
    await turn('next');await turn('next');
    s=await snapshot();
    assert.equal(s.entries.filter((e:any)=>e.status==='deferred').length,2);
    assert.equal(s.entries.find((e:any)=>e.status==='current').name,'Основной А');
    // Both main students have retries, but guests must still remain outside the queue.
    assert.equal(s.entries.find((e:any)=>e.name==='Основной Б').retries,1);
    await turn('pass');await turn('extra');
    s=await snapshot();
    assert.equal(s.entries.find((e:any)=>e.status==='current').name,'Гость А');
    assert.equal(s.entries.find((e:any)=>e.name==='Гость Б').status,'waiting');
    // A scheduled student returning ready is next, without interrupting the current guest.
    await actor(3);await act('ready');s=await snapshot();
    assert.equal(s.entries.find((e:any)=>e.status==='current').name,'Гость А');
    assert.equal(s.entries.find((e:any)=>e.name==='Гость Б').status,'deferred');
    await turn('pass');s=await snapshot();
    assert.equal(s.entries.find((e:any)=>e.status==='current').name,'Основной Б');
    await turn('next');s=await snapshot();
    assert.equal(s.entries.find((e:any)=>e.name==='Гость Б').status,'deferred');
    await turn('pass');s=await snapshot();
    assert.equal(s.entries.find((e:any)=>e.status==='current').name,'Гость Б');
    await turn('end_session');s=await snapshot();
    assert.equal(s.entries.length,0);
    assert.equal(s.results.find((r:any)=>r.name==='Гость Б').off_schedule,true);
    assert.equal(s.results.find((r:any)=>r.name==='Гость Б').outcome,'failed');
  } finally {await db.close();}
});
