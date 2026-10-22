import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = {'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization, x-client-info, apikey, content-type','Access-Control-Allow-Methods':'POST, OPTIONS'};
const reply = (status:number,body:object) => new Response(JSON.stringify(body),{status,headers:{...cors,'Content-Type':'application/json'}});
Deno.serve(async request => {
  if(request.method==='OPTIONS') return new Response('ok',{headers:cors});
  if(request.method!=='POST') return reply(405,{error:'Метод не поддерживается'});
  const url=Deno.env.get('SUPABASE_URL'),anon=Deno.env.get('SUPABASE_ANON_KEY'),secret=Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if(!url||!anon||!secret) return reply(500,{error:'Не настроены серверные ключи'});
  const authorization=request.headers.get('Authorization')||'';
  if(!authorization.startsWith('Bearer ')) return reply(401,{error:'Требуется вход'});
  try {
    const caller=createClient(url,anon,{auth:{persistSession:false,autoRefreshToken:false},global:{headers:{Authorization:authorization}}});
    const {data:identity,error:authError}=await caller.auth.getUser(authorization.slice(7));
    if(authError||!identity.user||identity.user.is_anonymous) return reply(401,{error:'Войдите в аккаунт'});
    const {data:allowed,error:roleError}=await caller.rpc('queue_is_superadmin');
    if(roleError||allowed!==true) return reply(403,{error:'Создавать студентов может только superadmin'});
    let body;
    try {body=await request.json();} catch {return reply(400,{error:'Некорректные данные'});}
    const name=typeof body?.name==='string'?body.name.trim():'';
    const login=typeof body?.login==='string'?body.login.trim().toLowerCase():'';
    const password=typeof body?.password==='string'?body.password:'';
    if(!/^[a-z0-9_]{3,64}$/.test(login)||name.length<2||name.length>60||password.length<8||password.length>128) return reply(400,{error:'Имя: 2–60 символов; логин: 3–64 латинские буквы, цифры или _; пароль: 8–128 символов'});
    const server=createClient(url,secret,{auth:{persistSession:false,autoRefreshToken:false}});
    const {data,error}=await server.auth.admin.createUser({email:`${login}@students.lab-queue.invalid`,password,email_confirm:true,user_metadata:{display_name:name,login}});
    if(error||!data.user) return reply(400,{error:['email_exists','user_already_exists'].includes(error?.code||'')?'Этот логин уже занят':'Не удалось создать студента. Проверьте логин и требования к паролю'});
    return reply(200,{id:data.user.id,name,login});
  } catch {return reply(500,{error:'Не удалось выполнить запрос. Проверьте список студентов перед повторной попыткой'});}
});
