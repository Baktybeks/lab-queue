import {queryOptions} from '@tanstack/react-query';
import type {SupabaseClient} from '@supabase/supabase-js';
import type {LabSession,Result} from '../../queue/model/queue';

export function historySessionsOptions(client:SupabaseClient,userId:string,open:boolean){
  return queryOptions({queryKey:['teacher-sessions',userId],enabled:open,staleTime:60_000,
    refetchOnWindowFocus:false,refetchOnReconnect:false,
    queryFn:async({signal}):Promise<LabSession[]>=>{
      const {data,error}=await client.rpc('queue_history_sessions').abortSignal(signal);
      if(error)throw new Error(error.message);return data||[];
    },
  });
}
export function sessionResultsOptions(client:SupabaseClient,userId:string,sessionId:string|null,open:boolean){
  return queryOptions({queryKey:['teacher-results',userId,sessionId],enabled:open&&Boolean(sessionId),staleTime:30_000,
    refetchOnWindowFocus:false,refetchOnReconnect:false,
    queryFn:async({signal}):Promise<Result[]>=>{
      const {data,error}=await client.rpc('queue_session_results',{target_session_id:sessionId}).abortSignal(signal);
      if(error)throw new Error(error.message);return data||[];
    },
  });
}
