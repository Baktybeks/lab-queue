import type {SupabaseClient} from '@supabase/supabase-js';
import {invokeFunction} from '../../../shared/api/invokeFunction';
export function createTeacher(client:SupabaseClient,input:{name:string;email:string;password:string}){
  return invokeFunction<{name:string;email:string}>(client,'create-teacher',input);
}
