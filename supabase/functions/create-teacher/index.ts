import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = {'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization, x-client-info, apikey, content-type','Access-Control-Allow-Methods':'POST, OPTIONS'};
const reply = (status: number,body: object) => new Response(JSON.stringify(body),{status,headers:{...cors,'Content-Type':'application/json'}});

Deno.serve(async request => {
  if (request.method === 'OPTIONS') return new Response('ok',{headers:cors});
  if (request.method !== 'POST') return reply(405,{error:'Метод не поддерживается'});
  const url = Deno.env.get('SUPABASE_URL');
  const anon = Deno.env.get('SUPABASE_ANON_KEY');
  const secret = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!url || !anon || !secret) return reply(500,{error:'Не настроены серверные ключи функции'});
  const authorization = request.headers.get('Authorization') || '';
  if (!authorization.startsWith('Bearer ')) return reply(401,{error:'Требуется вход'});
  const caller = createClient(url,anon,{auth:{persistSession:false,autoRefreshToken:false},global:{headers:{Authorization:authorization}}});
  const {data:identity,error:authError} = await caller.auth.getUser(authorization.slice(7));
  if (authError || !identity.user || identity.user.is_anonymous) return reply(401,{error:'Войдите в аккаунт'});
  const {data:allowed,error:roleError} = await caller.rpc('queue_is_superadmin');
  if (roleError || allowed !== true) return reply(403,{error:'Создавать преподавателей может только superadmin'});
  let body: {email?: unknown; name?: unknown; password?: unknown};
  try {body = await request.json();} catch {return reply(400,{error:'Некорректные данные'});}
  if (!body || typeof body !== 'object') return reply(400,{error:'Некорректные данные'});
  const email = typeof body.email === 'string' ? body.email.trim().toLowerCase() : '';
  const name = typeof body.name === 'string' ? body.name.trim() : '';
  const password = typeof body.password === 'string' ? body.password : '';
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || email.length > 254 || name.length < 2 || name.length > 60 || password.length < 8 || password.length > 128) {
    return reply(400,{error:'Проверьте email, имя (2–60 символов) и пароль (8–128 символов)'});
  }
  const server = createClient(url,secret,{auth:{persistSession:false,autoRefreshToken:false}});
  try {
    const {data,error} = await server.auth.admin.createUser({email,password,email_confirm:true,user_metadata:{display_name:name}});
    if (error || !data.user) return reply(400,{error:error?.code === 'email_exists' ? 'Аккаунт с таким email уже существует' : 'Не удалось создать аккаунт. Проверьте email и требования к паролю'});
    const granted = await server.rpc('queue_grant_teacher',{teacher_id:data.user.id,teacher_name:name});
    if (granted.error) {
      const rollback = await server.auth.admin.deleteUser(data.user.id);
      return reply(500,{error:rollback.error ? 'Аккаунт создан, но права не выданы. Проверьте пользователя в Supabase' : 'Не удалось выдать права. Проверьте миграцию 013 и повторите создание'});
    }
    return reply(200,{email,name});
  } catch {return reply(500,{error:'Не удалось выполнить запрос. Проверьте пользователя в Supabase перед повторной попыткой'});}
});
