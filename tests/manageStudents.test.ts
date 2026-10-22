import {test} from 'node:test';
import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {PGlite} from '@electric-sql/pglite';
test('Only superadmin lists and renames students; teachers and closed history are protected',async()=>{
 const db=new PGlite();const id=(n:number)=>`00000000-0000-0000-0000-${String(n).padStart(12,'0')}`;
 try{
 await db.exec(`create role anon;create role authenticated;create role service_role;create schema auth;create table auth.users(id uuid primary key,email text,is_anonymous boolean default false,raw_user_meta_data jsonb default '{}');create function auth.uid() returns uuid language sql as $$select nullif(current_setting('app.uid',true),'')::uuid$$;`);
 await db.exec(await readFile(new URL('../supabase/schema.sql',import.meta.url),'utf8'));
 for(let n=1;n<=3;n++)await db.query('insert into auth.users(id,email,raw_user_meta_data) values($1,$2,$3)',[id(n),`person${n}@students.lab-queue.invalid`,JSON.stringify({display_name:`Person ${n}`,login:`person${n}`})]);
 await db.query('insert into queue_private.admins values($1),($2)',[id(1),id(2)]);await db.query('insert into queue_private.superadmins values($1)',[id(1)]);
 const actor=async(n:number)=>{await db.query("select set_config('app.uid',$1,false)",[id(n)]);};
 await db.exec('set role authenticated');
 for(const n of [2,3]){await actor(n);await assert.rejects(db.query('select public.queue_students()'),/superadmin/);await assert.rejects(db.query('select public.queue_rename_student($1,$2)',[id(3),'New Name']),/superadmin/);}
 await actor(1);let rows=await db.query<{value:any}>('select public.queue_students() as value');assert.equal(rows.rows[0].value.length,1);assert.equal(rows.rows[0].value[0].login,'person3');
 await assert.rejects(db.query('select public.queue_rename_student($1,$2)',[id(2),'Teacher changed']),/Студент не найден/);
 await assert.rejects(db.query('select public.queue_rename_student($1,$2)',[id(3),'x']),/Имя/);
 await db.query("select public.queue_action('create_session',$1)",[JSON.stringify({date:'2026-10-23',group:'Test'})]);
 const sid=(await db.query<{id:string}>('select (public.queue_snapshot_for_session(null)->\'session\'->>\'id\') as id')).rows[0].id;
 await actor(3);await db.query("select public.queue_action('join',$1)",[JSON.stringify({session_id:sid,name:'Old Name',lab:6})]);
 await actor(1);await db.query('select public.queue_rename_student($1,$2)',[id(3),'New Name']);
 let snapshot=(await db.query<{value:any}>('select public.queue_snapshot_for_session($1) as value',[sid])).rows[0].value;assert.equal(snapshot.entries[0].name,'New Name');assert.equal(snapshot.results[0].name,'New Name');
 await db.query("select public.queue_action('end_session',$1)",[JSON.stringify({session_id:sid})]);await db.query('select public.queue_rename_student($1,$2)',[id(3),'Latest Name']);
 snapshot=(await db.query<{value:any}>('select public.queue_snapshot_for_session(null) as value')).rows[0].value;assert.equal(snapshot.results[0].name,'New Name');
 await actor(3);snapshot=(await db.query<{value:any}>('select public.queue_snapshot_for_session(null) as value')).rows[0].value;assert.equal(snapshot.profile_name,'Latest Name');
 await db.exec('reset role');const meta=(await db.query<{raw_user_meta_data:any}>('select raw_user_meta_data from auth.users where id=$1',[id(3)])).rows[0].raw_user_meta_data;assert.equal(meta.display_name,'Latest Name');assert.equal(meta.login,'person3');
 await db.exec('set role anon');await assert.rejects(db.query('select public.queue_students()'),/permission denied/);
 }finally{await db.close();}
});
