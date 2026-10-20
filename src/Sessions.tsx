import {useState} from 'react';
import type {State} from './queue';
import {SessionQr} from './SessionQr';
import {sessionCaption, newestSessions} from './sessionCaption';

const labels: Record<string, string> = {
    passed: 'Сдал',
    left: 'Ушёл',
    unfinished: 'Не завершил',
    waiting: 'В очереди',
    current: 'Сдаёт',
    extra: 'Доп. задание', deferred: 'Не по графику: ожидает'
};

export function Sessions({state, busy, perform}: {
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
    const sessions = newestSessions(state.sessions || []);
    const selectedId = sessions.some(s => s.id === selected) ? selected : state.session?.id || sessions[0]?.id;
    const selectedSession = sessions.find(s => s.id === selectedId);
    const results = (state.results || []).filter(r => r.session_id === selectedId);
    return <section className="sessions">
        <div className="card form-card">
            <h2>Сессия сдачи</h2>
            {state.session ? <><p><strong>{state.session.group}</strong> · {state.session.date}</p><SessionQr
                session={state.session}/><p>При завершении очередь закроется, все результаты и повторы
                сохранятся.</p>{ending ? <div className="actions">
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
        <div className="section-title"><h2>История сдачи</h2></div>
        <div className="card form-card"><label htmlFor="history-session">Сессия</label><select id="history-session"
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
            {results.length ? <div className="results-scroll">
                <table>
                    <thead>
                    <tr>
                        <th>Студент</th>
                        <th>Лаба</th>
                        <th>Не ответил</th>
                        <th>Результат</th>
                    </tr>
                    </thead>
                    <tbody>{results.map(r => <tr key={r.id}>
                        <td>{r.name}{r.off_schedule && <small> · Не по графику</small>}</td>
                        <td>№ {r.lab}</td>
                        <td>{r.retries}</td>
                        <td>{labels[r.outcome] || r.outcome}</td>
                    </tr>)}</tbody>
                </table>
            </div> : <p>В этой сессии пока нет записей.</p>}
        </div>
    </section>;
}
