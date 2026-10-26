import {useRef,useState} from 'react';
import type {SupabaseClient} from '@supabase/supabase-js';
import {parseStudentImport} from '../lib/parseStudentBatch';

const example='[\n  {"name": "Асанов Бек Русланович", "login": "asanov_b_r"},\n  {"name": "Иванов Иван Иванович", "login": "ivanov_i_i", "password": "Student2026!"}\n]';
export function StudentImport({client,onImported}:{client:SupabaseClient;onImported:()=>Promise<void>}){
  const [text,setText]=useState(''),[password,setPassword]=useState(''),[busy,setBusy]=useState(false),[error,setError]=useState(''),[progress,setProgress]=useState('');
  const [results,setResults]=useState<{login:string;status:string}[]>([]);
  const cancelled=useRef(false);
  return <details className="admin-accordion"><summary>Добавить студентов через JSON</summary><div className="accordion-content"><p>Вставьте массив студентов или выберите .json файл. До 500 записей за импорт. Уже существующие аккаунты пропускаются, их пароли не меняются.</p><details className="json-help"><summary>Какой JSON нужен?</summary><pre>{example}</pre><p><b>name</b> — имя, 2–60 символов. <b>login</b> — уникальный логин, 3–64 латинские буквы, цифры или _. <b>password</b> — пароль от 8 символов. Если его нет в записи, используется общий пароль ниже.</p></details>
    <form onSubmit={async e=>{e.preventDefault();setError('');setResults([]);let students;try{students=parseStudentImport(text,password);}catch(e){setError(e instanceof Error?e.message:'Ошибка JSON');return;}
      setBusy(true);cancelled.current=false;setText('');setPassword('');
      try{
        const {data,error}=await client.rpc('queue_students');if(error)throw new Error(error.message);
        const existing=new Set<string>((data||[]).map((s:{login:string})=>s.login.toLowerCase()));
        for(let index=0;index<students.length;index++){
          if(cancelled.current)break;
          const student=students[index];setProgress(`Обрабатываем ${index+1} из ${students.length}: ${student.login}`);
          let status='Создан';
          if(existing.has(student.login)){status='Уже существует — пропущен';}
          else{try{const {data,error}=await client.functions.invoke('create-student',{body:student});if(error){let details='Ошибка запроса. Проверьте аккаунт перед повторным импортом.';if(error.context instanceof Response){try{details=(await error.context.json()).error||details;}catch{ /* Safe fallback. */ }}throw new Error(details);}if(data?.error)throw new Error(data.error);existing.add(student.login);}catch(e){status=e instanceof Error?e.message:'Не удалось создать';}}
          student.password='';setResults(previous=>[...previous,{login:student.login,status}]);
        }
        setProgress(cancelled.current?'Импорт остановлен. Уже созданные аккаунты сохранены.':'Импорт завершён.');await onImported();
      }catch(e){setError(e instanceof Error?e.message:'Ошибка импорта');}finally{students.forEach(s=>s.password='');setBusy(false);}
    }}>
      <label htmlFor="students-json-file">Загрузить JSON</label><input id="students-json-file" type="file" accept=".json,application/json" disabled={busy} onChange={async e=>{const file=e.target.files?.[0];if(!file)return;if(file.size>1_000_000){setError('Размер файла — до 1 МБ.');return;}try{setText(await file.text());setError('');}catch{setError('Не удалось прочитать файл.');}e.target.value='';}}/>
      <label htmlFor="students-json">Список студентов</label><textarea id="students-json" rows={9} required spellCheck={false} disabled={busy} value={text} onChange={e=>setText(e.target.value)} placeholder={example}/>
      <label htmlFor="students-common-password">Общий пароль для записей без password</label><input id="students-common-password" type="password" autoComplete="new-password" disabled={busy} value={password} onChange={e=>setPassword(e.target.value)}/>
      <div className="actions"><button disabled={busy}>{busy?'Импортируем…':'Создать студентов из JSON'}</button>{busy&&<button className="ghost" type="button" onClick={()=>{cancelled.current=true;setProgress('Останавливаем после текущего запроса…');}}>Остановить</button>}</div>
    </form>{error&&<div className="error" role="alert">{error}</div>}<p role="status">{progress}</p>{results.length>0&&<div className="import-results"><ul>{results.map(r=><li key={r.login}><strong>{r.login}</strong> — {r.status}</li>)}</ul></div>}
  </div></details>;
}
