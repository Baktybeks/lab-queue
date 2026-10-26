import type {SupabaseClient} from '@supabase/supabase-js';
import {queryOptions} from '@tanstack/react-query';
import {queryKeys} from '../../../shared/api/queryKeys';
export type Student={id:string;name:string;login:string};
export function studentsOptions(client:SupabaseClient,userId:string){
  return queryOptions({queryKey:queryKeys.students(userId),staleTime:30_000,queryFn:async({signal}):Promise<Student[]>=>{
    const {data,error}=await client.rpc('queue_students').abortSignal(signal);
    if(error)throw new Error(error.message);return data||[];
  }});
}
export async function renameStudent(client:SupabaseClient,studentId:string,name:string){
  const {error}=await client.rpc('queue_rename_student',{student_id:studentId,student_name:name});
  if(error)throw new Error(error.message);
}
