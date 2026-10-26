import type {SupabaseClient} from '@supabase/supabase-js';
import {useQuery} from '@tanstack/react-query';
import {historySessionsOptions,sessionResultsOptions} from '../../../entities/session/api/history';
import {useState} from 'react';
import type {State} from '../../../entities/queue/model/queue';
import {SessionQr} from '../../../entities/session/ui/SessionQr';
import {ExtraBadge} from '../../../entities/queue/ui/ExtraBadge';
import {sessionCaption, newestSessions} from '../../../entities/session/lib/sessionCaption';

const labels: Record<string, string> = {
    passed: 'Сдал',
    left: 'Ушёл',
    unfinished: 'Не завершил',
    failed: 'Не защитил',
    waiting: 'В очереди',
    paused: 'В ожидании',
    current: 'Сдаёт',
    extra: 'Доп. задание', deferred: 'Не по графику: ожидает'
};

export function Sessions({client,userId,state, busy, perform}: {
    client:SupabaseClient;
    userId:string;
    state: State;
    busy: boolean;
    perform: (action: string, args?: Record<string, unknown>) => Promise<void>
}) {
    const [date, setDate] = useState(() => new Intl.DateTimeFormat('en-CA', {
        timeZone: 'Asia/Almaty',
        year: 'numeric',
        month: '2-digit',
        day: '2-digit'
    }).format(new Date()));
    const [group, setGroup] = useState('');
    const [selected, setSelected] = useState('');
    const [ending, setEnding] = useState(false);
    const [historyOpen,setHistoryOpen]=useState(false);
    const sessionQuery=useQuery(historySessionsOptions(client,userId,historyOpen));
    const sessions = newestSessions(sessionQuery.data || []);
    const selectedId = sessions.some(s => s.id === selected) ? selected : sessions.find(s=>s.id===state.session?.id)?.id || sessions[0]?.id;
    const selectedSession = sessions.find(s => s.id === selectedId);
    const resultQuery=useQuery(sessionResultsOptions(client,userId,selectedId||null,historyOpen));
    const results=resultQuery.data||[];
    const historyError=sessionQuery.error?.message||resultQuery.error?.message;
    return <section className="sessions" id="sessions">
        <div className="card form-card">
            <h2>Сессия сдачи</h2>
            {state.session ? <><p><strong>{state.session.group}</strong> · {state.session.date}</p><SessionQr
                session={state.session}/><p>При завершении очередь закроется, все результаты и повторы
                сохранятся. Оставшиеся в очереди получат 💀 «Не защитил». Допзадания сохранят свой статус.</p>{ending ? <div className="actions">
                <button disabled={busy} onClick={async () => {
                    await perform('end_session');
                    setEnding(false);
                }}>Завершить и сохранить
                </button>
                <button className="ghost" disabled={busy} onClick={() => setEnding(false)}>Отмена</button>
            </div> : <button className="ghost" disabled={busy} onClick={() => setEnding(true)}>Завершить
                сессию</button>}</> : <form onSubmit={e => {
                e.preventDefault();
                perform('create_session', {date, group: group.trim()});
            }}><label htmlFor="session-date">Дата сдачи</label><input id="session-date" type="date" required
                                                                      value={date}
                                                                      onChange={e => setDate(e.target.value)}/><label
                htmlFor="session-group">Группа</label><input id="session-group" placeholder="Например, ПИ-Х-ХХ" required
                                                             maxLength={60} value={group}
                                                             onChange={e => setGroup(e.target.value)}/>
                <button className="session-submit" disabled={busy || !group.trim()}>Создать сессию</button>
            </form>}
        </div>
        <details className="card form-card admin-accordion session-history" onToggle={e=>setHistoryOpen(e.currentTarget.open)}><summary>История сдачи</summary>
        <div className="card form-card"><button className="ghost compact-button" disabled={sessionQuery.isFetching||resultQuery.isFetching} onClick={async()=>{await sessionQuery.refetch();if(selectedId)await resultQuery.refetch();}}>Обновить историю</button>{historyError&&<div className="error" role="alert">{historyError}</div>}<label htmlFor="history-session">Сессия</label><select id="history-session"
                                                                                               value={selectedId || ''}
                                                                                               onChange={e => setSelected(e.target.value)}>{!sessions.length &&
            <option value="">Нет сессий</option>}{sessions.map(s => <option key={s.id}
                                                                            value={s.id}>{sessionCaption(s)}</option>)}</select>
            <p className="hint">Время — местное. Для старых сессий показано время завершения ({Intl.DateTimeFormat().resolvedOptions().timeZone}).</p>
            {state.superadmin && selectedSession && <button className="delete-session" disabled={busy || !selectedSession.ended_at} onClick={() => {
                if (!window.confirm(`Удалить сессию «${sessionCaption(selectedSession)}»?\n\nСессия и её история будут удалены безвозвратно. Незавершённые допзадания сохранятся.`)) return;
                perform('delete_session', {target_session_id: selectedSession.id});
            }}>Удалить сессию</button>}
            {state.superadmin && selectedSession && !selectedSession.ended_at && <p className="hint">Для удаления сначала завершите сессию.</p>}
            {sessionQuery.isLoading||resultQuery.isLoading ? <p role="status">Загружаем историю…</p> : results.length ? <div className="results-scroll">
                <table>
                    <thead>
                    <tr>
                        <th>Студент</th>
                        <th>Лаба</th>
                        <th>Повторы 🔄</th>
                        <th>Результат</th>
                    </tr>
                    </thead>
                    <tbody>{results.map(r => <tr key={r.id}>
                        <td>{r.name}{r.off_schedule && <small> · Не по графику</small>}</td>
                        <td>№ {r.lab}</td>
                        <td>{r.retries}</td>
                        <td>{labels[r.outcome] || r.outcome}<ExtraBadge entry={r}/></td>
                    </tr>)}</tbody>
                </table>
            </div> : <p>В этой сессии пока нет записей.</p>}
        </div></details>
    </section>;
}
