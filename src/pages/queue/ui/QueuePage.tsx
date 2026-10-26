import {QueueBoard} from '../../../widgets/queue-board/ui/QueueBoard';
import {LoginPage} from '../../login/ui/LoginPage';
import { Header } from '../../../widgets/header/ui/Header';
import { Sidebar, StudentOverview, SessionSummary } from '../../../widgets/dashboard-shell/ui/Dashboard';
import { Teachers } from '../../../features/manage-teachers/ui/Teachers';
import { Students } from '../../../features/manage-students/ui/Students';
import { StudentHistory } from '../../../widgets/student-history/ui/StudentHistory';
import { Sessions } from '../../../widgets/session-panel/ui/Sessions';
import { ExtraBadge } from '../../../entities/queue/ui/ExtraBadge';
import { MedalLegend } from '../../../entities/queue/ui/MedalLegend';
import {useQueuePage} from '../model/useQueuePage';
export function QueuePage(){
  const {userId,state,adminView,isAdmin,busy,error,setError,notice,name,setName,lab,setLab,offSchedule,setOffSchedule,activeLab,setActiveLab,connected,signedIn,authReady,requestedSession,wrongSession,current,waiting,mine,extras,paused,deferred,refresh,perform,selectSession,logout,remote}=useQueuePage();
  function restoreExtra(entry: {id:string;name:string}) {
    if (window.confirm(`Отметить, что ${entry.name} уже был на допзадании до этого занятия?\n\nОн перейдёт в допзадание с отметкой прошлого занятия и минимум одной 🧠. После готовности вернётся без приоритета.`)) perform('restore_extra',{entry_id:entry.id});
  }
  function readyExtraButton(entry: {id:string;name:string;ready?:boolean}) {
    return !entry.ready && <button className="secondary compact-button" disabled={busy} onClick={() => {
      if(window.confirm(`${entry.name}: старое допзадание готово? Вызвать с приоритетом после текущего сдающего?`)) perform('admit_ready_extra',{entry_id:entry.id});
    }}>Допзадание готово — вызвать следующим</button>;
  }
  if (remote && (!authReady || !signedIn)) return <LoginPage client={remote} ready={authReady} error={error} onRetry={refresh} onLogout={logout}/>;
  return <div className="app dashboard-app">
    <Sidebar admin={isAdmin}/>
    <Header name={state.profile_name || mine?.name} admin={isAdmin} superadmin={state.superadmin} onLogout={remote ? logout : undefined}/>
    {!remote && <div className="demo">Демонстрация на этом устройстве. Вход преподавателя и управление доступны после подключения Supabase.</div>}
    <main><div className="eyebrow">ЛАБОРАТОРНЫЕ РАБОТЫ <span>•</span> {adminView ? 'ПАНЕЛЬ ПРЕПОДАВАТЕЛЯ' : 'БЕЗ ТОЛПЫ У КАБИНЕТА'}</div>
    <div className={'intro ' + (!isAdmin ? 'student-intro' : '')}><div><h1>{adminView ? 'Всё по порядку.' : 'Готов? Занимай очередь.'}</h1><p>{adminView ? 'Управляй сдачей, а порядок мы сохраним.' : 'Запишись, готовься и следи за своей очередью.'}</p></div><span className={'live ' + (!connected ? 'offline' : '')}>● {remote ? connected ? 'Обновляется каждые 5 с' : 'Нет связи' : 'Локальный режим'}</span></div>
    {error && <div className="error" role="alert">{error}<button onClick={() => refresh().then(() => setError('')).catch(e => setError(e.message))}>Повторить</button></div>}
    {(state.available_sessions?.length || state.superadmin) ? <div className="session-picker card form-card"><label htmlFor="active-session">{isAdmin ? 'Активная сессия преподавателя' : 'Выбери сессию преподавателя или открой QR-код'}</label><select id="active-session" disabled={busy} value={state.session?.id || ''} onChange={e => selectSession(e.target.value || null)}><option value="">{isAdmin ? 'Моя сессия' : 'Выберите сессию'}</option>{state.available_sessions?.map(s => <option key={s.id} value={s.id}>{s.teacher_name} · {s.group} · {s.date}</option>)}</select></div> : null}
    <div className="session-banner">{remote && !signedIn ? 'Войди в аккаунт, чтобы открыть сессию и очередь.' : wrongSession ? 'Ссылка ведёт на закрытую сессию. Попроси преподавателя показать новый QR-код.' : state.session ? <>Сессия: <strong>{state.session.group}</strong> · {state.session.date} · {state.session.teacher_name}</> : remote ? 'Выбери сессию преподавателя или дождись её открытия.' : 'Демонстрационная очередь'}</div>
    {!isAdmin && <StudentOverview mine={mine} ahead={Math.max(0,waiting.findIndex(e=>e.id===mine?.id)) + (current ? 1 : 0)}/>}
    <div className={"layout " + (!isAdmin ? "student-layout" : "")} id="queue"><section className="queue-column" id="queue-list">
      <QueueBoard {...{current,waiting,extras,paused,deferred,adminView,isAdmin,busy,perform,restoreExtra,readyExtraButton}}/>
      {remote && !isAdmin && <StudentHistory client={remote} userId={userId} revision={JSON.stringify([state.session?.id,state.entries.map(e=>[e.id,e.status,e.retries,e.extra_count])])}/>}
      {adminView && isAdmin && <Sessions state={state} busy={busy} perform={perform}/> }
      {remote && state.superadmin && <><Teachers client={remote}/><Students client={remote} userId={userId}/></>}
    </section><aside id="registration"><SessionSummary state={state}/>
      <div className="lab-note"><span>АКТУАЛЬНАЯ РАБОТА</span><div>Лабораторная <strong>№ {state.lab}</strong></div><p>Приоритет при первой записи.<br/>После пропуска — в конец очереди.</p></div>
      {adminView ? isAdmin ? <div className="card form-card"><h2>Настройки сдачи</h2><label htmlFor="actual">Актуальная лабораторная</label><input id="actual" type="number" inputMode="numeric" min="1" max="99" value={activeLab} onChange={e => setActiveLab(e.target.value)}/><p className="hint">Применяется к новым записям. Текущий порядок сохраняется.</p><button disabled={busy || !state.session || !/^([1-9]|[1-9][0-9])$/.test(activeLab)} onClick={() => perform('set_lab',{lab:Number(activeLab)})}>Сохранить</button></div> : null : mine ? <div className="card form-card student-registration" id="student-registration"><span className="label">ТВОЯ ЗАПИСЬ</span><h2>{mine.name}</h2><ExtraBadge entry={mine}/><p>{mine.status === 'paused' ? 'Преподаватель перевёл тебя в ожидание. Когда будешь готов, сообщи ему — он вернёт тебя в очередь.' : mine.status === 'deferred' ? 'Ты не по графику. Когда основная очередь освободится, первый студент не по графику будет вызван автоматически. Преподаватель также может вызвать тебя вручную.' : mine.status === 'extra' ? 'Выполняй доп. задание. Когда закончишь, нажми кнопку ниже.' : mine.status === 'current' ? 'Твой черёд! Подходи к преподавателю.' : `Твоя позиция: ${waiting.findIndex(e => e.id === mine.id)+2}`}</p>{mine.status === 'extra' && <button disabled={busy} onClick={() => perform('ready')}>✓ Готово, вернуться</button>}{mine.can_return_extra && mine.status !== 'extra' && <button className="ghost" disabled={busy} onClick={() => perform('return_extra')}>↩ Вернуться к допзаданию</button>}{mine.ready && <p className="hint">Вернёшься после текущего и тех, кто нажал «Готово» раньше.</p>}<button className="ghost" disabled={busy} onClick={() => perform('leave')}>Уйти из очереди</button></div> : <form className="card form-card student-registration" id="student-registration" onSubmit={e => { e.preventDefault(); if (!window.confirm('Подготовь отчёт по лабораторной работе перед сдачей.\n\nОтчёт готов? Встать в очередь?')) return; perform('join',{name:name.trim(),lab:Number(lab),off_schedule:offSchedule}); }}><h2>Занять очередь</h2><p>Пара секунд — и можно готовиться.</p>{state.pending_extras?.some(e => e.lab === Number(lab)) && <div className="pending-extra-note">По лабораторной № {lab} осталось допзадание. После записи продолжишь его выполнять. После «Готово» встанешь в конец очереди без приоритета.</div>}<label htmlFor="name">Имя и фамилия</label><input id="name" placeholder="Имя и фамилия" required minLength={2} maxLength={60} value={name} onChange={e => setName(e.target.value)}/><label className="checkbox-label"><input type="checkbox" checked={offSchedule} onChange={e => setOffSchedule(e.target.checked)}/>Сдаю не по графику (другая группа или подгруппа)</label>{offSchedule && <p className="hint">Когда нет текущего сдающего и основная очередь пуста, первый из списка «Не по графику» вызывается автоматически. Остальные продолжают ждать.</p>}<label htmlFor="lab">Номер лабораторной</label><input id="lab" type="number" inputMode="numeric" min="1" max="99" required value={lab} onChange={e => setLab(e.target.value)}/><button disabled={busy || !connected || Boolean(remote && (!state.session || wrongSession))}>{busy ? 'Сохраняем…' : 'Встать в очередь →'}</button><p className="hint">Оставь эту страницу под рукой — здесь будет твой статус.</p></form>}
      <div className="how" id="guide"><h3>Как это работает</h3><p><b>01</b> Запишись со своего телефона</p><p><b>02</b> Следи за местом в очереди</p><p><b>03</b> Подходи, когда настанет твой черёд</p></div>
    </aside></div><MedalLegend/><div className="sr-only" role="status">{notice}</div></main><footer><span>лаба / меньше ожидания, больше дела</span><span>Удачной сдачи ✳</span></footer>
    {!isAdmin && <nav className="mobile-bottom-nav" aria-label="Быстрые действия студента">
      <button className="mobile-nav-link" onClick={() => document.getElementById('queue-list')?.scrollIntoView({block:'start'})}><span aria-hidden="true">◷</span>Очередь</button>
      <button className="mobile-nav-primary" onClick={() => document.getElementById('student-registration')?.scrollIntoView({block:'start'})}>{mine ? 'Моя запись' : 'Занять очередь'}</button>
      {remote && <button className="mobile-nav-link" onClick={() => { const history=document.getElementById('my-history'); if(history instanceof HTMLDetailsElement)history.open=true;history?.scrollIntoView({block:'start'}); }}><span aria-hidden="true">▦</span>История</button>}
    </nav>}
  </div>;
}
