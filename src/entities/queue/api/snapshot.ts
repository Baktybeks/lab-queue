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
      const {data,error}=await client.rpc('queue_snapshot_for_session',{target_session_id:sessionId}).abortSignal(signal);
      if(error)throw new Error(error.message);
      return {...data,profile_name:profileName(data.profile_name,user.user_metadata)} as State;
    },
    refetchInterval:5000,refetchIntervalInBackground:false,
  });
}
