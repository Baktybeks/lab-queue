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
  },onSuccess:async()=>{
    await Promise.all([
      cache.invalidateQueries({queryKey:['queue']}),
      cache.invalidateQueries({queryKey:['student-history']}),
    ]);
  }});
}
