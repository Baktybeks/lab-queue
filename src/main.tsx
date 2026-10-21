import React, { useEffect, useRef, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { createClient } from '@supabase/supabase-js';
import { ordered, insert, promote, type State } from './queue';
import './style.css';
import { Sessions } from './Sessions';
import { AuthPanel } from './AuthPanel';
import { profileName } from './profileName';
import { Header } from './Header';
import { Teachers } from './Teachers';
import { ExtraBadge } from './ExtraBadge';
import { MedalLegend } from './MedalLegend';

const env = (import.meta as unknown as { env: Record<string,string> }).env;
const remote = env.VITE_SUPABASE_URL && env.VITE_SUPABASE_ANON_KEY ? createClient(env.VITE_SUPABASE_URL, env.VITE_SUPABASE_ANON_KEY) : null;
const demoKey = 'lab-queue-demo-v1';
const empty: State = { lab: 6, entries: [], admin: false };
function readDemo(): State { try { return JSON.parse(localStorage.getItem(demoKey) || 'null') || structuredClone(empty); } catch { return structuredClone(empty); } }

function App() {
  const [state,setState] = useState<State>(remote ? empty : readDemo);
  const adminView = Boolean(remote && state.admin);
  const authGeneration = useRef(0);
  const [busy,setBusy] = useState(false);
  const [error,setError] = useState('');
  const [notice,setNotice] = useState('');
  const [name,setName] = useState('');
  const [lab,setLab] = useState(6);
  const [offSchedule,setOffSchedule] = useState(false);
  const [activeLab,setActiveLab] = useState(6);
  const [connected,setConnected] = useState(!remote);
  const [signedIn,setSignedIn] = useState(false);
  const [authReady,setAuthReady] = useState(!remote);
  const [requestedSession,setRequestedSession] = useState(() => new URLSearchParams(location.search).get('session'));
  const selectedSessionRef = useRef(requestedSession);
  const wrongSession = Boolean(requestedSession && state.session?.id !== requestedSession);
  const current = state.entries.find(e => e.status === 'current');
  const waiting = ordered(state.entries);
  const mine = state.entries.find(e => e.mine);
  const extras = state.entries.filter(e => e.status === 'extra');
  const deferred = state.entries.filter(e => e.status === 'deferred');
  async function refresh() {
    if (!remote) { setState(readDemo()); return; }
    const generation = authGeneration.current;
    const auth = await remote.auth.getSession();
    if (generation !== authGeneration.current) return;
    if (auth.error) throw auth.error;
    if (!auth.data.session || auth.data.session.user.is_anonymous) {
      setSignedIn(false); setAuthReady(true); setState(structuredClone(empty)); return;
    }
    const {data,error} = await remote.rpc('queue_snapshot_for_session',{target_session_id:selectedSessionRef.current});
    if (generation !== authGeneration.current) return;
    if (error) { setConnected(false); throw error; }
    setSignedIn(true); setAuthReady(true);
    setConnected(true); setState({...data,profile_name:profileName(data.profile_name,auth.data.session.user.user_metadata)} as State);
  }
  useEffect(() => {
    let stopped = false;
    let refreshing = false;
    const update = async () => {
      if (stopped || refreshing || document.hidden) return;
      refreshing = true;
      try { await refresh(); } catch(e) { if (!stopped) setError(e instanceof Error ? e.message : 'Не удалось обновить очередь'); }
      finally { refreshing = false; }
    };
    update();
    const authChange = remote?.auth.onAuthStateChange((event) => {
      if (event === 'SIGNED_OUT' || event === 'SIGNED_IN') {
        authGeneration.current++;
        setState(structuredClone(empty)); setSignedIn(false); setAuthReady(event === 'SIGNED_OUT');
      }
      window.setTimeout(() => { if (!stopped) update(); },0);
    });
    const interval = window.setInterval(update, 5000);
    window.addEventListener('storage',update);
    document.addEventListener('visibilitychange',update);
    return () => { stopped = true; authChange?.data.subscription.unsubscribe(); clearInterval(interval); window.removeEventListener('storage',update); document.removeEventListener('visibilitychange',update); };
  },[]);
  useEffect(() => { setActiveLab(state.lab); },[state.lab]);
  useEffect(() => { if (remote) setName(state.profile_name || ''); },[state.profile_name]);
  async function perform(action: string, args: Record<string,unknown> = {}) {
    if (busy) return;
    if (action === 'delete_session' && !state.superadmin) { setError('Удалять сессии может только superadmin'); return; }
    if (remote && action === 'join' && wrongSession) { setError('Эта сессия закрыта. Отсканируйте QR текущей сессии'); return; }
    if (['next','pass','extra','set_lab','create_session','end_session'].includes(action) && (!remote || !state.admin)) {
      setError('Управление доступно только преподавателю после входа по паролю');
      return;
    }
    setBusy(true); setError(''); setNotice('');
    try {
      if (remote) {
        const payload = ['next','pass','extra'].includes(action) ? { ...args, current_id: current?.id ?? null } : args;
        const {error} = action === 'delete_session'
          ? await remote.rpc('queue_delete_session',{target_session_id:args.target_session_id})
          : await remote.rpc('queue_action',{action, payload: { ...payload, session_id: action === 'join' ? requestedSession || state.session?.id || null : state.session?.id ?? null }});
        if (error) throw error;
        if (action === 'create_session') { selectedSessionRef.current = null; setRequestedSession(null); const url=new URL(location.href); url.searchParams.delete('session'); history.replaceState(null,'',url); }
        await refresh();
      } else {
        const next = readDemo();
        const student = next.entries.find(e => e.mine);
        const now = next.entries.find(e => e.status === 'current');
        if (action === 'join' && !student) {
          next.entries = insert(next.entries,{ id: crypto.randomUUID(), name: String(args.name), lab: Number(args.lab), status: 'waiting', off_schedule: Boolean(args.off_schedule), priority: !args.off_schedule && Number(args.lab) === next.lab, ready: false, position: 0, mine: true });
        }
        if (action === 'ready' && student?.status === 'extra') {
          student.status = 'waiting'; student.can_return_extra = true; student.ready = !student.carried_extra; student.priority = false;
          next.entries = insert(next.entries.filter(e => e.id !== student.id),student);
        }
        if (action === 'return_extra' && student?.can_return_extra) {
          student.status = 'extra'; student.ready = false; student.priority = false; student.can_return_extra = false;
        }
        if (action === 'leave') next.entries = next.entries.filter(e => !e.mine);
        if (['next','pass','extra'].includes(action) && now) {
          next.entries = next.entries.filter(e => e.id !== now.id);
          promote(next.entries);
          now.ready = false; now.priority = false; now.can_return_extra = false;
          if (action === 'next') { now.status = 'waiting'; next.entries = insert(next.entries,now); }
          if (action === 'extra') { now.extra_count = (now.extra_count || 0) + 1; now.had_extra = true; now.carried_extra = false; now.status = 'extra'; next.entries.push(now); }
        }
        if (action === 'set_lab') {
          next.lab = Number(args.lab);
          // Priority is assigned on joining; changing the lab affects future registrations.
        }
        promote(next.entries);
        localStorage.setItem(demoKey,JSON.stringify(next)); setState(next);
      }
      setNotice('Сохранено');
    } catch(e) { setError(e instanceof Error ? e.message : 'Не удалось выполнить действие'); }
    finally { setBusy(false); }
  }
  async function selectSession(id: string | null) {
    authGeneration.current++;
    selectedSessionRef.current = id; setRequestedSession(id);
    const url = new URL(location.href);
    if (id) url.searchParams.set('session',id); else url.searchParams.delete('session');
    history.replaceState(null,'',url);
    setError(''); setBusy(true);
    try { await refresh(); } catch(e) {setError(e instanceof Error ? e.message : 'Не удалось открыть сессию');}
    finally {setBusy(false);}
  }
  async function logout() {
    if (!remote) return;
    const {error} = await remote.auth.signOut();
    if (error) { setError(error.message); return; }
    authGeneration.current++;
    setState(structuredClone(empty)); setSignedIn(false); setAuthReady(true); setName(''); setError('');
  }
  if (remote && (!authReady || !signedIn)) return <div className="app">
    <Header/>
    <main className="auth-page"><div className="eyebrow">ЛАБОРАТОРНЫЕ РАБОТЫ</div><h1>Готов? Занимай очередь.</h1><p className="auth-description">Войди в аккаунт, чтобы открыть сессию сдачи.</p>
      {error && <div className="error" role="alert">{error}<button onClick={() => refresh().then(() => setError('')).catch(e => setError(e.message))}>Повторить</button></div>}
      {authReady ? <AuthPanel client={remote} onLogin={refresh}/> : <div className="card form-card"><p role="status">Проверяем аккаунт и права доступа…</p>{error && <button className="ghost" onClick={logout}>Выйти из аккаунта</button>}</div>}
    </main></div>;
  const isAdmin = Boolean(remote && state.admin);
  return <div className="app">
    <Header name={state.profile_name || mine?.name} admin={isAdmin} superadmin={state.superadmin} onLogout={remote ? logout : undefined}/>
    {!remote && <div className="demo">Демонстрация на этом устройстве. Вход преподавателя и управление доступны после подключения Supabase.</div>}
    <main><div className="eyebrow">ЛАБОРАТОРНЫЕ РАБОТЫ <span>•</span> {adminView ? 'ПАНЕЛЬ ПРЕПОДАВАТЕЛЯ' : 'БЕЗ ТОЛПЫ У КАБИНЕТА'}</div>
    <div className="intro"><div><h1>{adminView ? 'Всё по порядку.' : 'Готов? Занимай очередь.'}</h1><p>{adminView ? 'Управляй сдачей, а порядок мы сохраним.' : 'Запишись, готовься и следи за своей очередью.'}</p></div><span className={'live ' + (!connected ? 'offline' : '')}>● {remote ? connected ? 'Обновляется каждые 5 с' : 'Нет связи' : 'Локальный режим'}</span></div>
    {error && <div className="error" role="alert">{error}<button onClick={() => refresh().then(() => setError('')).catch(e => setError(e.message))}>Повторить</button></div>}
    {(state.available_sessions?.length || state.superadmin) ? <div className="session-picker card form-card"><label htmlFor="active-session">{isAdmin ? 'Активная сессия преподавателя' : 'Выбери сессию преподавателя или открой QR-код'}</label><select id="active-session" disabled={busy} value={state.session?.id || ''} onChange={e => selectSession(e.target.value || null)}><option value="">{isAdmin ? 'Моя сессия' : 'Выберите сессию'}</option>{state.available_sessions?.map(s => <option key={s.id} value={s.id}>{s.teacher_name} · {s.group} · {s.date}</option>)}</select></div> : null}
    <div className="session-banner">{remote && !signedIn ? 'Войди в аккаунт, чтобы открыть сессию и очередь.' : wrongSession ? 'Ссылка ведёт на закрытую сессию. Попроси преподавателя показать новый QR-код.' : state.session ? <>Сессия: <strong>{state.session.group}</strong> · {state.session.date} · {state.session.teacher_name}</> : remote ? 'Выбери сессию преподавателя или дождись её открытия.' : 'Демонстрационная очередь'}</div>
    <div className="layout"><section className="queue-column">
      <div className="current card"><div className="label">СЕЙЧАС СДАЁТ <span className="pulse"/></div><h2>{current?.name || 'Пока никого'}</h2><p>{current ? `Лабораторная № ${current.lab}` : 'Первый записавшийся начнёт сдачу'}</p>{current && <ExtraBadge entry={current}/ >}{current && <span className="ticket">01 <span>у преподавателя</span></span>}
      {adminView && isAdmin && current && <div className="actions"><button disabled={busy} onClick={() => perform('pass')}>✓ Сдал</button><button className="secondary" disabled={busy} onClick={() => perform('next')}>Следующий →</button><button className="ghost" disabled={busy} onClick={() => perform('extra')}>Доп. задание</button></div>}</div>
      <div className="section-title"><h2>Дальше по очереди <span>{waiting.length}</span></h2><span>Всё в своём темпе</span></div>
      <div className="card queue-list">{waiting.length ? waiting.map((entry,index) => <div className={'row ' + (entry.mine ? 'my-row' : '')} key={entry.id}><span className="number">{String(index+2).padStart(2,'0')}</span><div className="person"><strong>{entry.name}{entry.mine && <small>это ты</small>}</strong><span>Лабораторная № {entry.lab}{entry.off_schedule ? ' · Не по графику' : ''}</span></div><ExtraBadge entry={entry}/>{entry.ready ? <span className="badge ready">Готов с доп.</span> : entry.priority ? <span className="badge">Приоритет</span> : <span className="plain-status">В очереди</span>}</div>) : <div className="empty">Здесь появятся следующие студенты.<br/><span>Можно спокойно занять своё место.</span></div>}</div>
      <div className="section-title"><h2>На доп. задании <span>{extras.length}</span></h2></div><div className="card">{extras.length ? extras.map(e => <div className="row" key={e.id}><span className="extra-icon">↻</span><div className="person"><strong>{e.name}</strong><span>Лабораторная № {e.lab}</span><ExtraBadge entry={e}/></div><span className="plain-status">Готовится</span></div>) : <div className="empty compact">Сейчас никто не выполняет доп. задание</div>}</div>
      {deferred.length > 0 && <><div className="section-title"><h2>Не по графику <span>{deferred.length}</span></h2></div><div className="card">{deferred.map(e => <div className="row" key={e.id}><div className="person"><strong>{e.name}</strong><span>Лабораторная № {e.lab}</span><ExtraBadge entry={e}/></div><span className="badge">Ожидает допуска</span></div>)}</div></>}
      {adminView && isAdmin && <Sessions state={state} busy={busy} perform={perform}/> }
      {remote && state.superadmin && <Teachers client={remote}/>}
    </section><aside>
      <div className="lab-note"><span>АКТУАЛЬНАЯ РАБОТА</span><div>Лабораторная <strong>№ {state.lab}</strong></div><p>Приоритет при первой записи.<br/>После пропуска — в конец очереди.</p></div>
      {adminView ? isAdmin ? <div className="card form-card"><h2>Настройки сдачи</h2><label htmlFor="actual">Актуальная лабораторная</label><input id="actual" type="number" min="1" max="99" value={activeLab} onChange={e => setActiveLab(Number(e.target.value))}/><p className="hint">Применяется к новым записям. Текущий порядок сохраняется.</p><button disabled={busy || !state.session || activeLab < 1 || activeLab > 99} onClick={() => perform('set_lab',{lab:activeLab})}>Сохранить</button></div> : null : mine ? <div className="card form-card"><span className="label">ТВОЯ ЗАПИСЬ</span><h2>{mine.name}</h2><ExtraBadge entry={mine}/><p>{mine.status === 'deferred' ? 'Ты не по графику. Дождись, пока основная очередь освободится, включая повторные попытки.' : mine.status === 'extra' ? 'Выполняй доп. задание. Когда закончишь, нажми кнопку ниже.' : mine.status === 'current' ? 'Твой черёд! Подходи к преподавателю.' : `Твоя позиция: ${waiting.findIndex(e => e.id === mine.id)+2}`}</p>{mine.status === 'extra' && <button disabled={busy} onClick={() => perform('ready')}>✓ Готово, вернуться</button>}{mine.can_return_extra && mine.status !== 'extra' && <button className="ghost" disabled={busy} onClick={() => perform('return_extra')}>↩ Вернуться к допзаданию</button>}{mine.ready && <p className="hint">Вернёшься после текущего и тех, кто нажал «Готово» раньше.</p>}<button className="ghost" disabled={busy} onClick={() => perform('leave')}>Уйти из очереди</button></div> : <form className="card form-card" onSubmit={e => { e.preventDefault(); if (!window.confirm('Подготовь отчёт по лабораторной работе перед сдачей.\n\nОтчёт готов? Встать в очередь?')) return; perform('join',{name:name.trim(),lab,off_schedule:offSchedule}); }}><h2>Занять очередь</h2><p>Пара секунд — и можно готовиться.</p>{state.pending_extras?.some(e => e.lab === lab) && <div className="pending-extra-note">По лабораторной № {lab} осталось допзадание. После записи продолжишь его выполнять. После «Готово» встанешь в конец очереди без приоритета.</div>}<label htmlFor="name">Имя и фамилия</label><input id="name" placeholder="Имя и фамилия" required minLength={2} maxLength={60} value={name} onChange={e => setName(e.target.value)}/><label className="checkbox-label"><input type="checkbox" checked={offSchedule} onChange={e => setOffSchedule(e.target.checked)}/>Сдаю не по графику (другая группа или подгруппа)</label>{offSchedule && <p className="hint">Ты попадёшь в очередь, когда основные студенты завершат сдачу или перейдут на допзадание. Повторные попытки основных тоже нужно дождаться.</p>}<label htmlFor="lab">Номер лабораторной</label><input id="lab" type="number" min="1" max="99" required value={lab} onChange={e => setLab(Number(e.target.value))}/><button disabled={busy || !connected || Boolean(remote && (!state.session || wrongSession))}>{busy ? 'Сохраняем…' : 'Встать в очередь →'}</button><p className="hint">Оставь эту страницу под рукой — здесь будет твой статус.</p></form>}
      <div className="how"><h3>Как это работает</h3><p><b>01</b> Запишись со своего телефона</p><p><b>02</b> Следи за местом в очереди</p><p><b>03</b> Подходи, когда настанет твой черёд</p></div>
    </aside></div><MedalLegend/><div className="sr-only" role="status">{notice}</div></main><footer><span>лаба / меньше ожидания, больше дела</span><span>Удачной сдачи ✳</span></footer>
  </div>;
}
createRoot(document.getElementById('root')!).render(<App/>);
