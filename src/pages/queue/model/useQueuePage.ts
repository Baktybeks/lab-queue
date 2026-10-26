import {useEffect,useRef,useState} from 'react';
import {useQuery,useQueryClient} from '@tanstack/react-query';
import {supabase as remote} from '../../../shared/api/supabase';
import {useAuthSession} from '../../../features/auth/model/useAuthSession';
import {useQueueAction} from '../../../features/manage-queue/model/useQueueAction';
import {queueSnapshotOptions} from '../../../entities/queue/api/snapshot';
import {ordered} from '../../../entities/queue/model/queue';
import {empty,readDemo,performDemo} from '../../../entities/queue/model/demo';

export function useQueuePage(){
  const auth=useAuthSession(),cache=useQueryClient();
  const [requestedSession,setRequestedSession]=useState(()=>new URLSearchParams(location.search).get('session'));
  const snapshot=useQuery({...queueSnapshotOptions(remote,auth.session?.user??null,requestedSession),
    placeholderData:(previous,previousQuery)=>previousQuery?.queryKey[1]===auth.session?.user.id?previous:undefined,
  });
  const command=useQueueAction();
  const [demo,setDemo]=useState(remote?empty:readDemo);
  const state=remote?snapshot.data??empty:demo;
  const [localError,setError]=useState(''),[notice,setNotice]=useState('');
  const [name,setName]=useState(''),[lab,setLab]=useState('6'),[offSchedule,setOffSchedule]=useState(false),[activeLab,setActiveLab]=useState('6');
  const running=useRef(false);
  const isAdmin=Boolean(remote&&state.admin),adminView=isAdmin;
  const current=state.entries.find(e=>e.status==='current'),waiting=ordered(state.entries),mine=state.entries.find(e=>e.mine);
  const extras=state.entries.filter(e=>e.status==='extra'),paused=state.entries.filter(e=>e.status==='paused'),deferred=state.entries.filter(e=>e.status==='deferred');
  const wrongSession=Boolean(requestedSession&&state.session?.id!==requestedSession);
  const busy=command.isPending||snapshot.isPlaceholderData;
  const connected=!remote||Boolean(snapshot.data&&!snapshot.isError&&snapshot.fetchStatus!=='paused');
  const signedIn=Boolean(auth.session&&snapshot.data);
  const authReady=auth.ready&&(!auth.session||!snapshot.isPending);
  const error=localError||auth.error||snapshot.error?.message||'';
  useEffect(()=>{setActiveLab(String(state.lab));},[state.lab]);
  useEffect(()=>{if(remote)setName(state.profile_name||'');},[state.profile_name]);
  useEffect(()=>{if(remote)return;const sync=()=>setDemo(readDemo());window.addEventListener('storage',sync);return()=>window.removeEventListener('storage',sync);},[]);
  async function refresh(){
    if(!remote){setDemo(readDemo());return;}
    if(!auth.session)return;
    const result=await snapshot.refetch();if(result.error)throw result.error;
  }
  async function perform(action:string,args:Record<string,unknown>={}){
    if(running.current||busy)return;
    if(action==='delete_session'&&!state.superadmin){setError('Удалять сессии может только superadmin');return;}
    if(remote&&action==='join'&&wrongSession){setError('Эта сессия закрыта. Отсканируйте QR текущей сессии');return;}
    if(['next','pass','extra','restore_extra','admit_ready_extra','admit_deferred','pause_entry','pause_waiting','resume_entry','set_lab','create_session','end_session'].includes(action)&&!isAdmin){setError('Управление доступно только преподавателю после входа по паролю');return;}
    running.current=true;setError('');setNotice('');
    try{
      if(remote){
        const payload={...args,session_id:action==='join'?requestedSession||state.session?.id||null:state.session?.id??null,
          ...(['next','pass','extra'].includes(action)?{current_id:current?.id??null}:{}),
        };
        await command.mutateAsync({action,payload});
        if(action==='create_session')await selectSession(null);
      }else setDemo(performDemo(action,args));
      setNotice('Сохранено');
    }catch(e){setError(e instanceof Error?e.message:'Не удалось выполнить действие');}
    finally{running.current=false;}
  }
  async function selectSession(id:string|null){
    setError('');setRequestedSession(id);
    const url=new URL(location.href);if(id)url.searchParams.set('session',id);else url.searchParams.delete('session');history.replaceState(null,'',url);
  }
  async function logout(){
    if(!remote)return;
    const {error}=await remote.auth.signOut();
    if(error){setError(error.message);return;}
    cache.clear();setName('');setError('');
  }
  return {userId:auth.session?.user.id??'demo',state,adminView,isAdmin,busy,error,setError,notice,name,setName,lab,setLab,offSchedule,setOffSchedule,activeLab,setActiveLab,connected,signedIn,authReady,requestedSession,wrongSession,current,waiting,mine,extras,paused,deferred,refresh,perform,selectSession,logout,remote};
}
