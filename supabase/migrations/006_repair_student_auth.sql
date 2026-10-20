-- Repair missing student account migrations after sessions (002).
-- Safe to repeat. Preserves accounts, queue entries, sessions, and results.
begin;
create table if not exists queue_private.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  name text not null check (char_length(name) between 2 and 60)
);
alter table queue_private.profiles enable row level security;
alter table queue_private.results add column if not exists user_id uuid references auth.users(id) on delete set null;
update queue_private.results r set user_id = e.user_id from queue_private.entries e where r.id = e.id and r.user_id is null;
create index if not exists results_student_lab on queue_private.results(session_id,user_id,lab);
create or replace function public.queue_session_core(action text, payload jsonb default '{}'::jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  sid uuid;
  target queue_private.entries;
  new_date date;
  group_name text;
  admin boolean;
begin
  if auth.uid() is null then raise exception 'Требуется вход'; end if;
  select session_id into sid from queue_private.settings where id = 1 for update;
  select exists(select 1 from queue_private.admins where user_id = auth.uid()) into admin;
  if action in ('create_session','end_session','next','pass','extra','set_lab') and not admin then
    raise exception 'Доступ только преподавателю';
  end if;
  if action = 'create_session' then
    if sid is not null then raise exception 'Сначала завершите текущую сессию'; end if;
    new_date := (payload->>'date')::date;
    group_name := trim(payload->>'group');
    if new_date is null or group_name is null or char_length(group_name) not between 1 and 60 then
      raise exception 'Укажите дату и группу (до 60 символов)';
    end if;
    insert into queue_private.sessions(date,"group",created_by) values(new_date,group_name,auth.uid()) returning id into sid;
    update queue_private.settings set session_id = sid where id = 1;
    return;
  end if;
  if sid is null then raise exception 'Преподаватель ещё не открыл сессию сдачи'; end if;
  if sid is distinct from (payload->>'session_id')::uuid then
    raise exception 'Сессия изменилась. Обновите страницу';
  end if;
  if action = 'end_session' then
    update queue_private.results set outcome = 'unfinished', updated_at = now()
      where session_id = sid and outcome in ('current','waiting','extra');
    delete from queue_private.entries e
      where exists (
        select 1 from queue_private.results r where r.id = e.id and r.session_id = sid
      );
    update queue_private.sessions set ended_at = now() where id = sid;
    update queue_private.settings set session_id = null where id = 1;
    return;
  end if;
  if action in ('next','pass','extra') then
    select * into target from queue_private.entries where status = 'current';
  elsif action = 'leave' then
    select * into target from queue_private.entries where user_id = auth.uid();
  end if;
  -- Core validates current_id and performs the action before counting it.
  perform public.queue_action_core(action,payload);
  if action = 'next' and target.id is not null then
    update queue_private.entries set retries = retries + 1 where id = target.id;
  end if;
  if action in ('pass','leave') and target.id is not null then
    update queue_private.results set outcome = case when action = 'pass' then 'passed' else 'left' end,
      retries = target.retries, updated_at = now() where id = target.id;
  end if;
  insert into queue_private.results(id,session_id,name,lab,retries,outcome)
    select id,sid,name,lab,retries,status from queue_private.entries
    on conflict (id) do update set retries = excluded.retries,outcome = excluded.outcome,updated_at = now();
end;
$$;
create or replace function public.queue_snapshot_core() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare admin boolean;
begin
  if auth.uid() is null then raise exception 'Требуется вход'; end if;
  select exists(select 1 from queue_private.admins where user_id = auth.uid()) into admin;
  return jsonb_build_object(
    'lab',(select lab from queue_private.settings where id = 1),
    'admin',admin,
    'session',(select to_jsonb(s) - 'created_by' from queue_private.sessions s where id = (select session_id from queue_private.settings where id = 1)),
    'sessions',case when admin then coalesce((select jsonb_agg(to_jsonb(s) - 'created_by' order by date desc,id) from queue_private.sessions s),'[]'::jsonb) else '[]'::jsonb end,
    'results',case when admin then coalesce((select jsonb_agg(to_jsonb(r) order by updated_at,id) from queue_private.results r),'[]'::jsonb) else '[]'::jsonb end,
    'entries',coalesce((select jsonb_agg(jsonb_build_object(
      'id',id,'name',name,'lab',lab,'status',status,'priority',priority,'ready',ready,
      'position',position,'retries',retries,'mine',user_id = auth.uid()) order by position)
      from queue_private.entries),'[]'::jsonb)
  );
end;
$$;
create or replace function public.queue_action(action text,payload jsonb default '{}'::jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  sid uuid;
  display_name text;
  previous_retries integer := 0;
begin
  if actor is null or not exists(select 1 from auth.users where id = actor and not coalesce(is_anonymous,false)) then
    raise exception 'Войдите в аккаунт по email и паролю';
  end if;
  select session_id into sid from queue_private.settings where id = 1 for update;
  if action = 'join' then
    display_name := trim(payload->>'name');
    if display_name is null then
      select name into display_name from queue_private.profiles where user_id = actor;
    end if;
    if display_name is null then
      select trim(raw_user_meta_data->>'display_name') into display_name from auth.users where id = actor;
    end if;
    if display_name is null or char_length(display_name) not between 2 and 60 then
      raise exception 'Укажите имя и фамилию: от 2 до 60 символов';
    end if;
    insert into queue_private.profiles(user_id,name) values(actor,display_name)
      on conflict (user_id) do update set name = excluded.name;
    payload := payload || jsonb_build_object('name',display_name);
    select coalesce(max(retries),0) into previous_retries from queue_private.results
      where session_id = sid and user_id = actor and lab = (payload->>'lab')::integer;
  end if;
  perform public.queue_session_core(action,payload);
  if action = 'join' then
    update queue_private.entries set retries = previous_retries,
      priority = case when previous_retries > 0 then false else priority end,
      position = case when previous_retries > 0 and status = 'waiting'
        then (select coalesce(max(position),0)+1 from queue_private.entries where status = 'waiting') else position end
      where user_id = actor;
  end if;
  update queue_private.results r set user_id = e.user_id,retries = e.retries
    from queue_private.entries e where r.id = e.id;
end;
$$;
create or replace function public.queue_snapshot() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  saved_name text;
  metadata jsonb;
begin
  if actor is null or not exists(select 1 from auth.users where id = actor and not coalesce(is_anonymous,false)) then
    raise exception 'Войдите в аккаунт по email и паролю';
  end if;
  select raw_user_meta_data into metadata from auth.users where id = actor;
  saved_name := coalesce(
    (select nullif(trim(name),'') from queue_private.profiles where user_id = actor),
    (select nullif(trim(name),'') from queue_private.entries where user_id = actor),
    (select nullif(trim(name),'') from queue_private.results where user_id = actor order by updated_at desc,id limit 1),
    nullif(trim(metadata->>'display_name'),''),
    nullif(trim(metadata->>'full_name'),''),
    nullif(trim(metadata->>'name'),''),
    nullif(trim(concat_ws(' ',nullif(trim(metadata->>'first_name'),''),nullif(trim(metadata->>'last_name'),''))),'')
  );
  return public.queue_snapshot_core() || jsonb_build_object('profile_name',saved_name);
end;
$$;
revoke all on function public.queue_action_core(text,jsonb) from public,anon,authenticated,service_role;
revoke all on function public.queue_session_core(text,jsonb) from public,anon,authenticated,service_role;
revoke all on function public.queue_snapshot_core() from public,anon,authenticated,service_role;
revoke all on function public.queue_action(text,jsonb) from public,anon;
revoke all on function public.queue_snapshot() from public,anon;
grant execute on function public.queue_action(text,jsonb) to authenticated;
grant execute on function public.queue_snapshot() to authenticated;
commit;
