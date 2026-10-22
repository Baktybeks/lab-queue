import {useEffect,useState} from 'react';
import type {SupabaseClient} from '@supabase/supabase-js';
type Student={id:string;name:string;login:string};
export function Students({client}:{client:SupabaseClient}) {
  const [students,setStudents]=useState<Student[]>([]);
  const [name,setName]=useState(''),[login,setLogin]=useState(''),[password,setPassword]=useState('');
  const [query,setQuery]=useState(''),[editing,setEditing]=useState<string|null>(null),[editedName,setEditedName]=useState('');
  const [busy,setBusy]=useState(false),[loading,setLoading]=useState(true),[error,setError]=useState(''),[message,setMessage]=useState('');
  async function load(){const {data,error}=await client.rpc('queue_students');if(error)throw error;setStudents(data||[]);}
  useEffect(()=>{load().catch(e=>setError(e.message)).finally(()=>setLoading(false));},[client]);
  async function run(work:()=>Promise<void>){setBusy(true);setError('');setMessage('');try{await work();}catch(e){setError(e instanceof Error?e.message:'Не удалось сохранить');}finally{setBusy(false);}}
  return <section className="card form-card teacher-form" id="students"><h2>Студенты</h2><p>Создание аккаунтов и изменение имени доступны только superadmin.</p>
    <form onSubmit={e=>{e.preventDefault();run(async()=>{
      const {data,error}=await client.functions.invoke('create-student',{body:{name:name.trim(),login:login.trim(),password}});
      if(error){let details='Не удалось создать студента. Проверьте публикацию функции create-student.';if(error.context instanceof Response){try{details=(await error.context.json()).error||details;}catch{ /* Keep fallback. */ }}throw new Error(details);}
      if(data?.error)throw new Error(data.error);
      setName('');setLogin('');setPassword('');setMessage(`Студент ${data.name} создан. Логин: ${data.login}. Пароль — заданный вами.`);await load();
    });}}>
      <label htmlFor="new-student-name">Имя и фамилия</label><input id="new-student-name" required minLength={2} maxLength={60} value={name} onChange={e=>setName(e.target.value)}/>
      <label htmlFor="new-student-login">Логин</label><input id="new-student-login" required minLength={3} maxLength={64} pattern="[a-zA-Z0-9_]+" autoCapitalize="none" autoComplete="off" spellCheck={false} placeholder="asanov_b_r" value={login} onChange={e=>setLogin(e.target.value)}/><p className="hint">Латинские буквы, цифры и подчёркивание. Email студенту не нужен.</p>
      <label htmlFor="new-student-password">Пароль</label><input id="new-student-password" type="password" required minLength={8} maxLength={128} autoComplete="new-password" value={password} onChange={e=>setPassword(e.target.value)}/>
      <button disabled={busy}>{busy?'Сохраняем…':'Создать студента'}</button>
    </form>
    {error&&<div className="error" role="alert">{error}</div>}{message&&<p role="status">{message}</p>}
    <label htmlFor="student-search">Найти студента</label><input id="student-search" type="search" placeholder="Имя или логин" value={query} onChange={e=>setQuery(e.target.value)}/>
    <button className="ghost compact-button" disabled={busy||loading} onClick={()=>run(load)}>Обновить список</button>
    {loading?<p role="status">Загружаем студентов…</p>:<div className="student-list">{students.filter(s=>`${s.name} ${s.login}`.toLocaleLowerCase().includes(query.toLocaleLowerCase())).map(s=><div className="student-item" key={s.id}>{editing===s.id?<form onSubmit={e=>{e.preventDefault();run(async()=>{const {error}=await client.rpc('queue_rename_student',{student_id:s.id,student_name:editedName.trim()});if(error)throw error;setEditing(null);setMessage('Имя обновлено в аккаунте и открытых сессиях. История завершённых сессий сохранена.');await load();});}}><label htmlFor={`edit-${s.id}`}>Имя студента · {s.login}</label><input id={`edit-${s.id}`} required minLength={2} maxLength={60} value={editedName} onChange={e=>setEditedName(e.target.value)}/><div className="actions"><button disabled={busy}>Сохранить имя</button><button className="ghost" type="button" disabled={busy} onClick={()=>setEditing(null)}>Отмена</button></div></form>:<><div className="person"><strong>{s.name||'Имя не указано'}</strong><span>{s.login}</span></div><button className="secondary compact-button" disabled={busy} onClick={()=>{setEditing(s.id);setEditedName(s.name);}}>Изменить имя</button></>}</div>)}{!students.length&&<p>Студентов пока нет. Создайте первый аккаунт выше.</p>}</div>}
  </section>;
}
