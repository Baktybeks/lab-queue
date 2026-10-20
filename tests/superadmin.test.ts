import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { PGlite } from '@electric-sql/pglite';

test('Only superadmin can delete closed sessions; teacher grants require the server role', async () => {
  const db = new PGlite();
  const id = (n: number) => `00000000-0000-0000-0000-${String(n).padStart(12,'0')}`;
  const actor = async (n: number) => {await db.query("select set_config('app.uid',$1,false)",[id(n)]);};
  const snapshot = async (): Promise<any> => (await db.query<{value:any}>('select public.queue_snapshot() as value')).rows[0].value;
  const remove = (n: number) => db.query('select public.queue_delete_session($1)',[id(n)]);
  try {
    await db.exec(`create role anon;create role authenticated;create role service_role;
      create schema auth;create table auth.users(id uuid primary key,email text,is_anonymous boolean default false,raw_user_meta_data jsonb default '{}');
      create function auth.uid() returns uuid language sql as $$ select nullif(current_setting('app.uid',true),'')::uuid $$;`);
    for (let n=1;n<=4;n++) await db.query('insert into auth.users(id,email) values($1,$2)',[id(n),n===2?'superadmin@mail.ru':`user${n}@example.com`]);
    await db.exec(await readFile(new URL('../supabase/schema.sql',import.meta.url),'utf8'));

    await db.query('insert into queue_private.admins values($1)',[id(1)]);
    await db.exec(await readFile(new URL('../supabase/grant_superadmin.sql',import.meta.url),'utf8'));
    for(let n=10;n<=12;n++) await db.query(`insert into queue_private.sessions(id,date,"group",ended_at) values($1,'2026-10-21','ПИ',case when $2 then now() else null end)`,[id(n),n!==12]);
    await db.query('update queue_private.settings set session_id=$1 where id=1',[id(12)]);
    await db.query(`insert into queue_private.results(id,session_id,name,lab,retries,outcome,user_id) values($1,$2,'Студент',6,0,'extra',$3),($4,$5,'Другой',6,0,'passed',$3)`,[id(20),id(10),id(3),id(21),id(11)]);
    await db.query('insert into queue_private.pending_extras(user_id,lab) values($1,6)',[id(3)]);
    await db.exec('set role authenticated');
    await actor(3);await assert.rejects(remove(10),/только superadmin/);
    await assert.rejects(db.query('select public.queue_grant_teacher($1,$2)',[id(4),'Преподаватель']),/permission denied/);
    await actor(1);assert.equal((await snapshot()).superadmin,false);await assert.rejects(remove(10),/только superadmin/);
    await actor(2);assert.equal((await snapshot()).superadmin,true);
    await assert.rejects(remove(12),/Сначала завершите/);
    await remove(10);
    await assert.rejects(remove(10),/не найдена/);
    const s=await snapshot();assert.equal(s.sessions.length,2);assert.equal(s.results.length,1);
    await actor(3);await db.exec('reset role');assert.equal((await db.query('select * from queue_private.pending_extras')).rows.length,1);
    await db.exec('reset role;set role service_role');
    await db.query('select public.queue_grant_teacher($1,$2)',[id(4),'Новый преподаватель']);
    await db.exec('reset role;set role authenticated');
    await actor(4);const teacher=await snapshot();assert.equal(teacher.admin,true);assert.equal(teacher.superadmin,false);assert.equal(teacher.profile_name,'Новый преподаватель');
    await assert.rejects(remove(11),/только superadmin/);
  } finally {await db.close();}
});
