import {useEffect,useRef,useState} from 'react';
import type {Session} from '@supabase/supabase-js';
import {useQueryClient} from '@tanstack/react-query';
import {supabase} from '../../../shared/api/supabase';
import {shouldResetAccount} from './authTransition';

export function useAuthSession(){
  const cache=useQueryClient();
  const [session,setSession]=useState<Session|null>(null),[ready,setReady]=useState(!supabase),[error,setError]=useState('');
  const userId=useRef<string|null>(null);
  useEffect(()=>{
    if(!supabase)return;
    let stopped=false,version=0;
    const apply=(next:Session|null)=>{if(stopped)return;const valid=next&&!next.user.is_anonymous?next:null;userId.current=valid?.user.id??null;setSession(valid);setReady(true);setError('');};
    const subscription=supabase.auth.onAuthStateChange((event,next)=>{
      version++;
      if(shouldResetAccount(event,userId.current,next?.user.id??null))cache.clear();
      apply(next);
    });
    const initialVersion=version;
    supabase.auth.getSession().then(({data,error})=>{
      if(stopped||version!==initialVersion)return;
      if(error){setError(error.message);setReady(true);}else apply(data.session);
    }).catch(e=>{if(!stopped){setError(e.message);setReady(true);}});
    return()=>{stopped=true;subscription.data.subscription.unsubscribe();};
  },[cache]);
  return {session,ready,error};
}
