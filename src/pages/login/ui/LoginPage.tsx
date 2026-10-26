import type {SupabaseClient} from '@supabase/supabase-js';
import {AuthPanel} from '../../../features/auth/ui/AuthPanel';
import {Header} from '../../../widgets/header/ui/Header';
export function LoginPage({client,ready,error,onRetry,onLogout}:{client:SupabaseClient;ready:boolean;error:string;onRetry:()=>Promise<void>;onLogout:()=>Promise<void>}){
  return <div className="app"><Header/><main className="auth-page"><div className="eyebrow">ЛАБОРАТОРНЫЕ РАБОТЫ</div><h1>Готов? Занимай очередь.</h1><p className="auth-description">Войди в аккаунт, чтобы открыть сессию сдачи.</p>
    {error&&<div className="error" role="alert">{error}<button onClick={()=>onRetry().catch(()=>{})}>Повторить</button></div>}
    {ready?<AuthPanel client={client} onLogin={onRetry}/>:<div className="card form-card"><p role="status">Проверяем аккаунт и права доступа…</p>{error&&<button className="ghost" onClick={onLogout}>Выйти из аккаунта</button>}</div>}
  </main></div>;
}
