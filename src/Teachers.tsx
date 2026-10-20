import { useState } from 'react';
import type { SupabaseClient } from '@supabase/supabase-js';

export function Teachers({client}: {client: SupabaseClient}) {
  const [name,setName] = useState('');
  const [email,setEmail] = useState('');
  const [password,setPassword] = useState('');
  const [busy,setBusy] = useState(false);
  const [error,setError] = useState('');
  const [message,setMessage] = useState('');
  return <section className="card form-card teacher-form"><h2>Создать преподавателя</h2><p>Доступно только superadmin. Новый аккаунт сможет управлять сдачей, но не удалять сессии.</p>
    <form onSubmit={async e => {
      e.preventDefault();setBusy(true);setError('');setMessage('');
      try {
        const {data,error} = await client.functions.invoke('create-teacher',{body:{name:name.trim(),email:email.trim(),password}});
        if (error) {
          let details = 'Не удалось создать преподавателя. Проверьте публикацию функции create-teacher в Supabase.';
          if (error.context instanceof Response) {try {details=(await error.context.json()).error || details;} catch { /* Use safe fallback. */ }}
          throw new Error(details);
        }
        if (data?.error) throw new Error(data.error);
        setMessage(`Преподаватель ${data.name} создан. Вход: ${data.email}. Пароль — заданный вами.`);
        setName('');setEmail('');setPassword('');
      } catch(e) {setError(e instanceof Error ? e.message : 'Ошибка создания');}
      finally {setBusy(false);}
    }}>
      <label htmlFor="teacher-name">Имя и фамилия</label><input id="teacher-name" required minLength={2} maxLength={60} value={name} onChange={e => setName(e.target.value)}/>
      <label htmlFor="teacher-email">Email преподавателя</label><input id="teacher-email" type="email" required autoComplete="off" value={email} onChange={e => setEmail(e.target.value)}/>
      <label htmlFor="teacher-password">Пароль для нового аккаунта</label><input id="teacher-password" type="password" required minLength={8} maxLength={128} autoComplete="new-password" value={password} onChange={e => setPassword(e.target.value)}/>
      {error && <div className="error" role="alert">{error}</div>}{message && <p role="status">{message}</p>}
      <button disabled={busy}>{busy ? 'Создаём…' : 'Создать преподавателя'}</button>
    </form></section>;
}
