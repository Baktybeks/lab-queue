import {useState} from 'react';
import {useMutation,useQuery,useQueryClient} from '@tanstack/react-query';
import {studentsOptions,renameStudent} from '../../../entities/student/api/students';
import {createStudent} from '../api/createStudent';
import type {SupabaseClient} from '@supabase/supabase-js';
import {StudentImport} from './StudentImport';
export function Students({client,userId}:{client:SupabaseClient;userId:string}) {
  const cache=useQueryClient();
  const query=useQuery(studentsOptions(client,userId));
  const students=query.data||[];const loading=query.isPending;
  const [name,setName]=useState(''),[login,setLogin]=useState(''),[password,setPassword]=useState('');
  const [search,setSearch]=useState(''),[editing,setEditing]=useState<string|null>(null),[editedName,setEditedName]=useState('');
  const [error,setError]=useState(''),[message,setMessage]=useState('');
  const mutation=useMutation({mutationFn:(work:()=>Promise<void>)=>work()});
  const busy=mutation.isPending;
  async function load(){const result=await query.refetch();if(result.error)throw result.error;}
  async function run(work:()=>Promise<void>){setError('');setMessage('');try{await mutation.mutateAsync(work);await cache.invalidateQueries({queryKey:['queue']});}catch(e){setError(e instanceof Error?e.message:'Не удалось сохранить');}}
  return <section className="card form-card teacher-form" id="students"><h2>Студенты</h2><p>Создание аккаунтов и изменение имени доступны только superadmin.</p>
    <details className="admin-accordion"><summary>Создать студента</summary><div className="accordion-content"><form onSubmit={e=>{e.preventDefault();run(async()=>{
      const data=await createStudent(client,{name:name.trim(),login:login.trim(),password});
      setName('');setLogin('');setPassword('');setMessage(`Студент ${data.name} создан. Логин: ${data.login}. Пароль — заданный вами.`);await load();
    });}}>
      <label htmlFor="new-student-name">Имя и фамилия</label><input id="new-student-name" required minLength={2} maxLength={60} value={name} onChange={e=>setName(e.target.value)}/>
      <label htmlFor="new-student-login">Логин</label><input id="new-student-login" required minLength={3} maxLength={64} pattern="[a-zA-Z0-9_]+" autoCapitalize="none" autoComplete="off" spellCheck={false} placeholder="asanov_b_r" value={login} onChange={e=>setLogin(e.target.value)}/><p className="hint">Латинские буквы, цифры и подчёркивание. Email студенту не нужен.</p>
      <label htmlFor="new-student-password">Пароль</label><input id="new-student-password" type="password" required minLength={8} maxLength={128} autoComplete="new-password" value={password} onChange={e=>setPassword(e.target.value)}/>
      <button disabled={busy}>{busy?'Сохраняем…':'Создать студента'}</button>
    </form></div></details>
    <StudentImport client={client} onImported={load}/>
    {(error||query.error)&&<div className="error" role="alert">{error||query.error?.message}</div>}{message&&<p role="status">{message}</p>}
    <details className="admin-accordion"><summary>Изменение имени студента</summary><div className="accordion-content"><label htmlFor="student-search">Найти студента</label><input id="student-search" type="search" placeholder="Имя или логин" value={search} onChange={e=>setSearch(e.target.value)}/>
    <button className="ghost compact-button" disabled={busy||loading} onClick={()=>run(load)}>Обновить список</button>
    {loading?<p role="status">Загружаем студентов…</p>:<div className="student-list">{students.filter(s=>`${s.name} ${s.login}`.toLocaleLowerCase().includes(search.toLocaleLowerCase())).map(s=><div className="student-item" key={s.id}>{editing===s.id?<form onSubmit={e=>{e.preventDefault();run(async()=>{await renameStudent(client,s.id,editedName.trim());setEditing(null);setMessage('Имя обновлено в аккаунте и открытых сессиях. История завершённых сессий сохранена.');await load();});}}><label htmlFor={`edit-${s.id}`}>Имя студента · {s.login}</label><input id={`edit-${s.id}`} required minLength={2} maxLength={60} value={editedName} onChange={e=>setEditedName(e.target.value)}/><div className="actions"><button disabled={busy}>Сохранить имя</button><button className="ghost" type="button" disabled={busy} onClick={()=>setEditing(null)}>Отмена</button></div></form>:<><div className="person"><strong>{s.name||'Имя не указано'}</strong><span>{s.login}</span></div><button className="secondary compact-button" disabled={busy} onClick={()=>{setEditing(s.id);setEditedName(s.name);}}>Изменить имя</button></>}</div>)}{!students.length&&<p>Студентов пока нет. Создайте первый аккаунт выше.</p>}</div>}
    </div></details>
  </section>;
}
