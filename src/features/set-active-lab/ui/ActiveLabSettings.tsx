import {useEffect,useState} from 'react';
import {labNumber} from '../lib/labNumber';

export function ActiveLabSettings({sessionId,currentLab,busy,error,onSave}:{sessionId:string|null;currentLab:number;busy:boolean;error:string;onSave:(lab:number)=>Promise<void>}){
  const [draft,setDraft]=useState(String(currentLab));
  useEffect(()=>{setDraft(String(currentLab));},[sessionId,currentLab]);
  const value=labNumber(draft);
  return <form className="card form-card" onSubmit={e=>{e.preventDefault();if(!busy&&value!==null)onSave(value);}}>
    <h2>Настройки сдачи</h2><label htmlFor="actual">Актуальная лабораторная</label>
    <input id="actual" type="number" inputMode="numeric" min="1" max="99" step="1" required value={draft}
      onChange={e=>setDraft(e.target.value)} onBlur={()=>{if(value!==null)setDraft(String(value));}}
      aria-describedby="actual-help actual-status"/>
    <p className="hint" id="actual-help">Применяется к новым записям. Текущий порядок сохраняется.</p>
    <div id="actual-status" aria-live="polite">{value===null?<p>Введите целый номер от 1 до 99.</p>:sessionId?<p>Сейчас сохранена лабораторная № {currentLab}.</p>:<p>Для новой сессии выбрана лабораторная № {currentLab}. Сохраните нужный номер, затем создайте сессию — она сразу откроется с ним.</p>}</div>
    {error&&<p className="error" role="alert">{error}</p>}
    <button disabled={busy||value===null}>{busy?'Сохраняем…':sessionId?'Сохранить':'Сохранить для новой сессии'}</button>
  </form>;
}
