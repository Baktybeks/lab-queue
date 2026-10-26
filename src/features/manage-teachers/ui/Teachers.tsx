import { useState } from 'react';
import {useMutation} from '@tanstack/react-query';
import {createTeacher} from '../api/createTeacher';
import type { SupabaseClient } from '@supabase/supabase-js';

export function Teachers({client}: {client: SupabaseClient}) {
  const [name,setName] = useState('');
  const [email,setEmail] = useState('');
  const [password,setPassword] = useState('');
  const mutation=useMutation({mutationFn:(input:{name:string;email:string;password:string})=>createTeacher(client,input)});
  const busy=mutation.isPending;
  const [error,setError] = useState('');
  const [message,setMessage] = useState('');
  return <details className="card form-card teacher-form admin-accordion"><summary>Создать преподавателя</summary><div className="accordion-content"><p>Доступно только superadmin. Новый аккаунт сможет управлять сдачей, но не удалять сессии.</p>
    <form onSubmit={async e => {
      e.preventDefault();setError('');setMessage('');
      try {
        const data=await mutation.mutateAsync({name:name.trim(),email:email.trim(),password});
        setMessage(`Преподаватель ${data.name} создан. Вход: ${data.email}. Пароль — заданный вами.`);
        setName('');setEmail('');setPassword('');
      } catch(e) {setError(e instanceof Error ? e.message : 'Ошибка создания');}

    }}>
      <label htmlFor="teacher-name">Имя и фамилия</label><input id="teacher-name" required minLength={2} maxLength={60} value={name} onChange={e => setName(e.target.value)}/>
      <label htmlFor="teacher-email">Email преподавателя</label><input id="teacher-email" type="email" required autoComplete="off" value={email} onChange={e => setEmail(e.target.value)}/>
      <label htmlFor="teacher-password">Пароль для нового аккаунта</label><input id="teacher-password" type="password" required minLength={8} maxLength={128} autoComplete="new-password" value={password} onChange={e => setPassword(e.target.value)}/>
      {error && <div className="error" role="alert">{error}</div>}{message && <p role="status">{message}</p>}
      <button disabled={busy}>{busy ? 'Создаём…' : 'Создать преподавателя'}</button>
    </form></div></details>;
}
