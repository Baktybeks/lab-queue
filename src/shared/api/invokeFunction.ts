import type {SupabaseClient} from '@supabase/supabase-js';
export async function invokeFunction<T>(client:SupabaseClient,name:string,body:object):Promise<T>{
  const {data,error}=await client.functions.invoke(name,{body});
  if(error){
    let details=`Не удалось выполнить запрос. Проверьте публикацию функции ${name}.`;
    if(error.context instanceof Response){try{details=(await error.context.json()).error||details;}catch{/* Keep fallback. */}}
    throw new Error(details);
  }
  if(data?.error)throw new Error(data.error);
  return data as T;
}
