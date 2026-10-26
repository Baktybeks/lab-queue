import {useMutation,useQueryClient} from '@tanstack/react-query';
import {supabase} from '../../../shared/api/supabase';
export type QueueCommand={action:string;payload:Record<string,unknown>};
export function useQueueAction(){
  const cache=useQueryClient();
  return useMutation({mutationFn:async({action,payload}:QueueCommand)=>{
    if(!supabase)throw new Error('Не подключён Supabase');
    const {error}=action==='delete_session'
      ? await supabase.rpc('queue_delete_session',{target_session_id:payload.target_session_id})
      : await supabase.rpc('queue_action',{action,payload});
    if(error)throw new Error(error.message);
  },onSuccess:async(_data,command)=>{
    await Promise.all([
      cache.invalidateQueries({queryKey:['queue']}),
      cache.invalidateQueries({queryKey:['student-history']}),
      cache.invalidateQueries({queryKey:['teacher-sessions'],refetchType:['create_session','end_session','delete_session'].includes(command.action)?'active':'none'}),
      cache.invalidateQueries({queryKey:['teacher-results'],predicate:query=>query.queryKey[2]===(command.payload.target_session_id||command.payload.session_id),refetchType:command.action==='delete_session'?'none':'active'}),
    ]);
  }});
}
