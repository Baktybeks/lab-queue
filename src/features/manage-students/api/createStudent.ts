import type {SupabaseClient} from '@supabase/supabase-js';
import {invokeFunction} from '../../../shared/api/invokeFunction';
export function createStudent(client:SupabaseClient,input:{name:string;login:string;password:string}){
  return invokeFunction<{id:string;name:string;login:string}>(client,'create-student',input);
}
