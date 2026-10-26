import {queryOptions} from '@tanstack/react-query';
import type {SupabaseClient} from '@supabase/supabase-js';
import type {Result,LabSession} from '../../queue/model/queue';
import {queryKeys} from '../../../shared/api/queryKeys';
export type HistoryRow=Result & {session:LabSession};
export function studentHistoryOptions(client:SupabaseClient,userId:string){
  return queryOptions({queryKey:queryKeys.history(userId),staleTime:15_000,queryFn:async({signal}):Promise<HistoryRow[]>=>{
    const {data,error}=await client.rpc('queue_my_history').abortSignal(signal);
    if(error)throw new Error(error.message);return data||[];
  }});
}
