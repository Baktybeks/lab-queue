import {useEffect,useRef,useState} from 'react';
import type {SupabaseClient} from '@supabase/supabase-js';
import type {Result,LabSession} from './queue';
import {ExtraBadge} from './ExtraBadge';
import {sessionCaption} from './sessionCaption';

type HistoryRow=Result & {session:LabSession};
const labels:Record<string,string>={passed:'Сдал',failed:'Не защитил',unfinished:'Не завершил',left:'Ушёл из очереди',waiting:'В очереди',current:'Сейчас сдаёшь',extra:'На допзадании',deferred:'Ожидаешь допуска',paused:'В ожидании'};

export function StudentHistory({client,revision}:{client:SupabaseClient;revision:string}) {
  const [rows,setRows]=useState<HistoryRow[]>([]),[loading,setLoading]=useState(true),[error,setError]=useState('');
  const [lab,setLab]=useState(''),[teacher,setTeacher]=useState(''),[outcome,setOutcome]=useState('');
  const request=useRef(0);
  async function load(){const generation=++request.current;setLoading(true);try{const {data,error}=await client.rpc('queue_my_history');if(error)throw new Error(error.message);if(generation===request.current){setRows(data||[]);setError('');}}catch(e){if(generation===request.current)setError(e instanceof Error?e.message:'Не удалось загрузить историю');}finally{if(generation===request.current)setLoading(false);}}
  useEffect(()=>{load();return()=>{request.current++;};},[client,revision]);
  const teachers=[...new Set(rows.map(r=>r.session.teacher_name||'Преподаватель'))].sort();
  const filtered=rows.filter(r=>(!lab||String(r.lab)===lab)&&(!teacher||r.session.teacher_name===teacher)&&(!outcome||r.outcome===outcome));
  return <section className="card form-card student-history" id="my-history"><div className="section-title"><h2>Моя история сдачи</h2><button className="ghost compact-button" disabled={loading} onClick={load}>{loading?'Загружаем…':'Обновить'}</button></div><p>Твои записи у всех преподавателей, включая прошлые сессии. Самые новые — сверху.</p>
    <div className="history-stats"><div><strong>{rows.filter(r=>r.outcome==='passed').length}</strong><span>успешных сдач</span></div><div><strong>{rows.filter(r=>r.first_try_pass).length}</strong><span>с первой попытки 🥇</span></div><div><strong>{rows.length}</strong><span>записей в истории</span></div></div>
    <div className="history-filters"><label>Лабораторная<select value={lab} onChange={e=>setLab(e.target.value)}><option value="">Все работы</option>{[...new Set(rows.map(r=>r.lab))].sort((a,b)=>a-b).map(n=><option key={n} value={n}>№ {n}</option>)}</select></label><label>Преподаватель<select value={teacher} onChange={e=>setTeacher(e.target.value)}><option value="">Все преподаватели</option>{teachers.map(t=><option key={t}>{t}</option>)}</select></label><label>Результат<select value={outcome} onChange={e=>setOutcome(e.target.value)}><option value="">Все результаты</option>{Object.entries(labels).map(([key,label])=><option key={key} value={key}>{label}</option>)}</select></label></div>
    {error&&<div className="error" role="alert">Не удалось загрузить историю: {error}</div>}
    {!error&&!rows.length&&!loading&&<div className="empty">История пока пуста.<br/><span>После записи на защиту здесь появится твоя лабораторная.</span></div>}
    {!error&&rows.length>0&&(filtered.length?<div className="history-records">{filtered.map(r=><article className="history-record" key={r.id}><div className="history-record-head"><h3>Лабораторная № {r.lab}</h3><span className={'history-outcome outcome-'+r.outcome}>{labels[r.outcome]||r.outcome}</span></div><p>{sessionCaption(r.session)}</p><span className="history-retries">Повторы через «Следующий»: {r.retries}{r.off_schedule?' · Не по графику':''}</span><ExtraBadge entry={r}/></article>)}</div>:<div className="empty">Нет записей с выбранными фильтрами.</div>)}
    <p className="hint">Счётчики и медали показаны на момент записи. Их нельзя складывать между сессиями: перенесённое допзадание может сохранять прежний счётчик.</p>
  </section>;
}
