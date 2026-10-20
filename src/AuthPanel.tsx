import { useState } from 'react';
import type { SupabaseClient } from '@supabase/supabase-js';
import { authError } from './authError';
import { loginEmail } from './loginEmail';

export function AuthPanel({client,onLogin}: {client: SupabaseClient; onLogin: () => Promise<void>}) {
  const [login,setLogin] = useState('');
  const [password,setPassword] = useState('');
  const [busy,setBusy] = useState(false);
  const [error,setError] = useState('');
  return <form className="card form-card" onSubmit={async e => {
    e.preventDefault(); setBusy(true); setError('');
    try {
      const {error} = await client.auth.signInWithPassword({email:loginEmail(login),password});
      if (error) throw error;
      await onLogin(); setPassword('');
    } catch(e) { setError(authError(e)); }
    finally { setBusy(false); }
  }}><h2>Вход в систему</h2><p>Студентам — выданный логин, преподавателю — email своего аккаунта.</p>
    <label htmlFor="student-login">Логин или email</label><input id="student-login" type="text" autoComplete="username" autoCapitalize="none" spellCheck={false} placeholder="логин" required value={login} onChange={e => setLogin(e.target.value)}/>
    <label htmlFor="student-password">Пароль</label><input id="student-password" type="password" autoComplete="current-password" required value={password} onChange={e => setPassword(e.target.value)}/>
    {error && <div className="error" role="alert">{error}</div>}
    <button disabled={busy}>{busy ? 'Подождите…' : 'Войти'}</button>
  </form>;
}
