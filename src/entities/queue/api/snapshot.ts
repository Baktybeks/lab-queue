import {queryOptions} from '@tanstack/react-query';
import type {SupabaseClient,User} from '@supabase/supabase-js';
import type {State} from '../model/queue';
import {profileName} from '../../user/lib/profileName.ts';
import {queryKeys} from '../../../shared/api/queryKeys.ts';

export function queueSnapshotOptions(client:SupabaseClient|null,user:User|null,sessionId:string|null){
  return queryOptions({
    queryKey:queryKeys.queue(user?.id??null,sessionId),enabled:Boolean(client&&user),
    queryFn:async({signal}):Promise<State>=>{
      if(!client||!user)throw new Error('Требуется вход');
      let {data,error}=await client.rpc('queue_live_snapshot',{target_session_id:sessionId}).abortSignal(signal);
      // Keep the existing queue usable while migration 027 is being installed.
      if(error?.code==='PGRST202'||error?.code==='42883'){
        const legacy=await client.rpc('queue_snapshot_for_session',{target_session_id:sessionId}).abortSignal(signal);
        data=legacy.data;error=legacy.error;
        if(data)data={...data,passed_count:(data.results||[]).filter((r:{session_id:string;outcome:string})=>r.session_id===data.session?.id&&r.outcome==='passed').length};
      }
      if(error)throw new Error(error.message);
      const {results:_results,sessions:_sessions,...live}=data;
      return {...live,profile_name:profileName(data.profile_name,user.user_metadata)} as State;
    },
    refetchInterval:5000,refetchIntervalInBackground:false,
  });
}
