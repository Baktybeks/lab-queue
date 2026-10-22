import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';
test('Student history is private, includes closed sessions and medals, and needs no selected session',async()=>{
 const db=new PGlite();const id=(n:number)=>`00000000-0000-0000-0000-${String(n).padStart(12,'0')}`;
 try{
 await db.exec(`create role anon;create role authenticated;create role service_role;create schema auth;create table auth.users(id uuid primary key,email text,is_anonymous boolean default false,raw_user_meta_data jsonb default '{}');create function auth.uid() returns uuid language sql as $$select nullif(current_setting('app.uid',true),'')::uuid$$;`);
 await db.exec(await readFile(new URL('../supabase/schema.sql',import.meta.url),'utf8'));
 for(let n=1;n<=4;n++)await db.query('insert into auth.users(id) values($1)',[id(n)]);
 await db.query('insert into queue_private.admins values($1)',[id(1)]);await db.query('insert into queue_private.profiles(user_id,name) values($1,$2)',[id(1),'Teacher']);
 await db.query('update auth.users set is_anonymous=true where id=$1',[id(4)]);
 const actor=async(n:number)=>{await db.query("select set_config('app.uid',$1,false)",[id(n)]);};
 const action=async(a:string,p:object)=>{await db.query('select public.queue_action($1,$2::jsonb)',[a,JSON.stringify(p)]);};
 const history=async()=> (await db.query<{value:any}>('select public.queue_my_history() as value')).rows[0].value;
 await db.exec('set role authenticated');await actor(1);await action('create_session',{date:'2026-10-23',group:'Group'});
 const sid=(await db.query<{id:string}>("select public.queue_snapshot_for_session(null)->'session'->>'id' as id")).rows[0].id;
 await actor(2);await action('join',{session_id:sid,name:'Student A',lab:6});
 await actor(3);await action('join',{session_id:sid,name:'Student B',lab:4});
 await actor(1);let snapshot=(await db.query<{value:any}>('select public.queue_snapshot_for_session($1) as value',[sid])).rows[0].value;
 await action('pass',{session_id:sid,current_id:snapshot.entries.find((e:any)=>e.status==='current').id});
 snapshot=(await db.query<{value:any}>('select public.queue_snapshot_for_session($1) as value',[sid])).rows[0].value;
 await action('extra',{session_id:sid,current_id:snapshot.entries.find((e:any)=>e.status==='current').id});await action('end_session',{session_id:sid});
 await actor(2);let rows=await history();assert.equal(rows.length,1);assert.equal(rows[0].name,'Student A');assert.equal(rows[0].outcome,'passed');assert.equal(rows[0].first_try_pass,true);assert.equal(rows[0].session.teacher_name,'Teacher');assert.ok(rows[0].session.ended_at);assert.equal(rows[0].session.group,'Group');
 await actor(3);rows=await history();assert.equal(rows.length,1);assert.equal(rows[0].name,'Student B');assert.equal(rows[0].outcome,'extra');assert.equal(rows[0].extra_count,1);assert.equal(rows.some((r:any)=>r.name==='Student A'),false);
 await actor(1);assert.deepEqual(await history(),[]);
 await actor(4);await assert.rejects(history(),/Войдите/);
 await db.query("select set_config('app.uid','',false)");await assert.rejects(history(),/Войдите/);
 await db.exec('set role anon');await assert.rejects(history(),/permission denied/);
 }finally{await db.close();}
});
