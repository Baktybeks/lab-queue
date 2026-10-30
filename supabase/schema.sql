-- Execute once in Supabase SQL Editor.
create schema if not exists queue_private;
revoke all on schema queue_private from public, anon, authenticated;

create table queue_private.settings (
  id integer primary key check (id = 1),
  lab integer not null default 6 check (lab between 1 and 99)
);
insert into queue_private.settings(id) values (1);
create table queue_private.admins (user_id uuid primary key references auth.users(id) on delete cascade);
create table queue_private.entries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null unique references auth.users(id) on delete cascade,
  name text not null check (char_length(name) between 2 and 60),
  lab integer not null check (lab between 1 and 99),
  status text not null check (status in ('waiting','current','extra')),
  priority boolean not null default false,
  ready boolean not null default false,
  position bigint not null
);
create unique index one_current on queue_private.entries(status) where status = 'current';
alter table queue_private.settings enable row level security;
alter table queue_private.admins enable row level security;
alter table queue_private.entries enable row level security;

create function public.queue_snapshot() returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'Требуется вход'; end if;
  return jsonb_build_object(
    'lab', (select lab from queue_private.settings where id = 1),
    'admin', exists(select 1 from queue_private.admins where user_id = auth.uid()),
    'entries', coalesce((select jsonb_agg(jsonb_build_object(
      'id', id, 'name', name, 'lab', lab, 'status', status,
      'priority', priority, 'ready', ready, 'position', position,
      'mine', user_id = auth.uid()) order by position) from queue_private.entries), '[]'::jsonb)
  );
end;
$$;

create function public.queue_action(action text, payload jsonb default '{}'::jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  active_lab integer;
  target queue_private.entries;
  pos bigint;
  chosen_lab integer;
  chosen_name text;
begin
  if actor is null then raise exception 'Требуется вход'; end if;
  -- All writes take this lock, including empty-queue joins and repeated clicks.
  select lab into active_lab from queue_private.settings where id = 1 for update;
  if action in ('next','pass','extra','set_lab') then
    if not exists(select 1 from queue_private.admins where user_id = actor) then
      raise exception 'Доступ только преподавателю';
    end if;
  end if;

  if action = 'join' then
    chosen_name := trim(payload->>'name');
    chosen_lab := (payload->>'lab')::integer;
    if chosen_name is null or char_length(chosen_name) not between 2 and 60
      or chosen_lab is null or chosen_lab not between 1 and 99 then
      raise exception 'Укажите имя (2–60 символов) и номер лабы (1–99)';
    end if;
    if exists(select 1 from queue_private.entries where user_id = actor) then
      raise exception 'Вы уже записаны';
    end if;
    if chosen_lab = active_lab then
      select min(position) into pos from queue_private.entries
        where status = 'waiting' and not ready and not priority;
    end if;
    if pos is null then
      select coalesce(max(position),0)+1 into pos from queue_private.entries where status = 'waiting';
    else
      update queue_private.entries set position = position + 1 where status = 'waiting' and position >= pos;
    end if;
    insert into queue_private.entries(user_id,name,lab,status,priority,position)
      values(actor,chosen_name,chosen_lab,'waiting',chosen_lab = active_lab,pos);
  elsif action = 'ready' then
    select * into target from queue_private.entries where user_id = actor and status = 'extra';
    if not found then raise exception 'Вы не на доп. задании'; end if;
    select min(position) into pos from queue_private.entries where status = 'waiting' and not ready;
    if pos is null then
      select coalesce(max(position),0)+1 into pos from queue_private.entries where status = 'waiting';
    else
      update queue_private.entries set position = position + 1 where status = 'waiting' and position >= pos;
    end if;
    update queue_private.entries set status = 'waiting',ready = true,priority = false,position = pos where id = target.id;
  elsif action = 'leave' then
    delete from queue_private.entries where user_id = actor;
  elsif action = 'set_lab' then
    chosen_lab := (payload->>'lab')::integer;
    if chosen_lab is null or chosen_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    update queue_private.settings set lab = chosen_lab where id = 1;
  elsif action in ('next','pass','extra') then
    select * into target from queue_private.entries where status = 'current';
    -- A stale tab must never act on a different current student.
    if target.id is distinct from (payload->>'current_id')::uuid then
      raise exception 'Очередь изменилась. Обновите страницу и повторите действие';
    end if;
    if target.id is not null then
      if action = 'pass' then delete from queue_private.entries where id = target.id;
      else
        select coalesce(max(position),0)+1 into pos from queue_private.entries where status = 'waiting';
        update queue_private.entries set status = case when action = 'extra' then 'extra' else 'waiting' end,
          ready = false,priority = false,position = pos where id = target.id;
      end if;
    end if;
  else raise exception 'Неизвестное действие';
  end if;
  if not exists(select 1 from queue_private.entries where status = 'current') then
    update queue_private.entries set status = 'current' where id = (
      select id from queue_private.entries where status = 'waiting' order by position limit 1
    );
  end if;
end;
$$;
revoke all on function public.queue_snapshot() from public, anon;
revoke all on function public.queue_action(text,jsonb) from public, anon;
grant execute on function public.queue_snapshot() to authenticated;
grant execute on function public.queue_action(text,jsonb) to authenticated;


-- Session and results extension for new installations.
-- Run once AFTER the original schema.sql, if it was installed before sessions were added.
begin;
create table queue_private.sessions (
  id uuid primary key default gen_random_uuid(),
  date date not null,
  "group" text not null check (char_length("group") between 1 and 60),
  ended_at timestamptz,
  created_by uuid references auth.users(id) on delete set null
);
create unique index one_active_session on queue_private.sessions ((true)) where ended_at is null;
alter table queue_private.settings add column session_id uuid references queue_private.sessions(id);
alter table queue_private.entries add column retries integer not null default 0 check (retries >= 0);
create table queue_private.results (
  id uuid primary key,
  session_id uuid not null references queue_private.sessions(id),
  name text not null,
  lab integer not null,
  retries integer not null default 0,
  outcome text not null,
  updated_at timestamptz not null default now()
);
alter table queue_private.sessions enable row level security;
alter table queue_private.results enable row level security;
-- Preserve an existing queue when upgrading.
do $$
declare sid uuid;
begin
  if exists(select 1 from queue_private.entries) then
    insert into queue_private.sessions(date,"group") values ((now() at time zone 'Asia/Almaty')::date,'Перенесённая очередь') returning id into sid;
    update queue_private.settings set session_id = sid where id = 1;
    insert into queue_private.results(id,session_id,name,lab,retries,outcome)
      select id,sid,name,lab,retries,status from queue_private.entries;
  end if;
end;
$$;

alter function public.queue_action(text,jsonb) rename to queue_action_core;
-- Only the definer wrapper may invoke the original implementation.
revoke all on function public.queue_action_core(text,jsonb) from public, anon, authenticated, service_role;

create function public.queue_action(action text, payload jsonb default '{}'::jsonb) returns void
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

create or replace function public.queue_snapshot() returns jsonb
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
revoke all on function public.queue_action(text,jsonb) from public, anon;
grant execute on function public.queue_action(text,jsonb) to authenticated;
commit;


-- Student accounts extension for new installations.
-- Execute once after migration 002. Authentication: email/password instead of anonymous users.
begin;
create table queue_private.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  name text not null check (char_length(name) between 2 and 60)
);
alter table queue_private.profiles enable row level security;
alter table queue_private.results add column user_id uuid references auth.users(id) on delete set null;
update queue_private.results r set user_id = e.user_id from queue_private.entries e where r.id = e.id;
create index results_student_lab on queue_private.results(session_id,user_id,lab);

alter function public.queue_action(text,jsonb) rename to queue_session_core;
revoke all on function public.queue_session_core(text,jsonb) from public, anon, authenticated, service_role;
create function public.queue_action(action text,payload jsonb default '{}'::jsonb) returns void
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
    select name into display_name from queue_private.profiles where user_id = actor;
    if display_name is null then
      select trim(raw_user_meta_data->>'display_name') into display_name from auth.users where id = actor;
      if display_name is null or char_length(display_name) not between 2 and 60 then
        raise exception 'У аккаунта не указано имя. Обратитесь к преподавателю';
      end if;
      insert into queue_private.profiles(user_id,name) values(actor,display_name);
    end if;
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

alter function public.queue_snapshot() rename to queue_snapshot_core;
revoke all on function public.queue_snapshot_core() from public, anon, authenticated, service_role;
create function public.queue_snapshot() returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if auth.uid() is null or not exists(select 1 from auth.users where id = auth.uid() and not coalesce(is_anonymous,false)) then
    raise exception 'Войдите в аккаунт по email и паролю';
  end if;
  return public.queue_snapshot_core() || jsonb_build_object('profile_name',
    coalesce((select name from queue_private.profiles where user_id = auth.uid()),
      (select raw_user_meta_data->>'display_name' from auth.users where id = auth.uid())));
end;
$$;
revoke all on function public.queue_action(text,jsonb) from public, anon;
revoke all on function public.queue_snapshot() from public, anon;
grant execute on function public.queue_action(text,jsonb) to authenticated;
grant execute on function public.queue_snapshot() to authenticated;
commit;


-- Editable profile names.
-- Editable student name, saved atomically with joining the queue.
begin;
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

revoke all on function public.queue_action(text,jsonb) from public, anon;
grant execute on function public.queue_action(text,jsonb) to authenticated;
commit;


-- Account name lookup for older accounts.
-- Return the signed-in student's saved name, including older account formats.
begin;
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
revoke all on function public.queue_snapshot() from public, anon;
grant execute on function public.queue_snapshot() to authenticated;
commit;


-- Off-schedule students wait until the scheduled queue is empty.
-- Off-schedule students wait until the scheduled queue is empty, including repeat turns.
begin;
alter table queue_private.entries add column if not exists off_schedule boolean not null default false;
alter table queue_private.results add column if not exists off_schedule boolean not null default false;
alter table queue_private.entries drop constraint if exists entries_status_check;
alter table queue_private.entries add constraint entries_status_check check (status in ('current','waiting','extra','deferred'));

create or replace function public.queue_action(action text,payload jsonb default '{}'::jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  sid uuid;
  active_lab integer;
  admin boolean;
  target queue_private.entries;
  display_name text;
  chosen_lab integer;
  guest boolean;
  previous_retries integer;
  pos bigint;
  group_name text;
  new_date date;
begin
  if actor is null or not exists(select 1 from auth.users where id = actor and not coalesce(is_anonymous,false)) then
    raise exception 'Войдите в аккаунт по логину и паролю';
  end if;
  select session_id,lab into sid,active_lab from queue_private.settings where id = 1 for update;
  select exists(select 1 from queue_private.admins where user_id = actor) into admin;
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
    insert into queue_private.sessions(date,"group",created_by) values(new_date,group_name,actor) returning id into sid;
    update queue_private.settings set session_id = sid where id = 1;
    return;
  end if;
  if sid is null then raise exception 'Преподаватель ещё не открыл сессию сдачи'; end if;
  if sid is distinct from (payload->>'session_id')::uuid then raise exception 'Сессия изменилась. Обновите страницу'; end if;
  if action = 'end_session' then
    update queue_private.results set outcome = 'unfinished',updated_at = now()
      where session_id = sid and outcome in ('current','waiting','extra','deferred');
    for target in select e.* from queue_private.entries e join queue_private.results r on r.id = e.id where r.session_id = sid loop
      delete from queue_private.entries where id = target.id;
    end loop;
    update queue_private.sessions set ended_at = now() where id = sid;
    update queue_private.settings set session_id = null where id = 1;
    return;
  end if;
  select coalesce(max(position),0)+1 into pos from queue_private.entries;
  if action = 'join' then
    if exists(select 1 from queue_private.entries where user_id = actor) then raise exception 'Вы уже записаны'; end if;
    display_name := coalesce(trim(payload->>'name'),
      (select name from queue_private.profiles where user_id = actor),
      (select raw_user_meta_data->>'display_name' from auth.users where id = actor));
    chosen_lab := (payload->>'lab')::integer;
    guest := coalesce((payload->>'off_schedule')::boolean,false);
    if display_name is null or char_length(display_name) not between 2 and 60 then raise exception 'Укажите имя и фамилию: от 2 до 60 символов'; end if;
    if chosen_lab is null or chosen_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    insert into queue_private.profiles(user_id,name) values(actor,display_name) on conflict(user_id) do update set name = excluded.name;
    select coalesce(max(retries),0) into previous_retries from queue_private.results where session_id = sid and user_id = actor and lab = chosen_lab;
    insert into queue_private.entries(user_id,name,lab,status,priority,position,retries,off_schedule)
      values(actor,display_name,chosen_lab,'waiting',not guest and chosen_lab = active_lab and previous_retries = 0,pos,previous_retries,guest);
  elsif action = 'leave' then
    select * into target from queue_private.entries where user_id = actor;
    if target.id is not null then
      update queue_private.results set outcome = 'left',updated_at = now() where id = target.id;
      delete from queue_private.entries where id = target.id;
    end if;
  elsif action = 'ready' then
    select * into target from queue_private.entries where user_id = actor and status = 'extra';
    if target.id is null then raise exception 'Вы не на доп. задании'; end if;
    update queue_private.entries set status = 'waiting',ready = true,priority = false,position = pos where id = target.id;
  elsif action = 'set_lab' then
    chosen_lab := (payload->>'lab')::integer;
    if chosen_lab is null or chosen_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    update queue_private.settings set lab = chosen_lab where id = 1;
  elsif action in ('next','pass','extra') then
    select * into target from queue_private.entries where status = 'current';
    if target.id is distinct from (payload->>'current_id')::uuid then raise exception 'Очередь изменилась. Обновите страницу и повторите действие'; end if;
    if target.id is not null then
      if action = 'pass' then
        update queue_private.results set outcome = 'passed',updated_at = now() where id = target.id;
        delete from queue_private.entries where id = target.id;
      else
        update queue_private.entries set status = case when action = 'extra' then 'extra' else 'waiting' end,
          retries = retries + case when action = 'next' then 1 else 0 end,ready = false,priority = false,position = pos where id = target.id;
      end if;
    end if;
  else raise exception 'Неизвестное действие';
  end if;

  -- Hold guests until scheduled students leave the active queue. Returned extras keep their priority. Never interrupt current.
  if exists(select 1 from queue_private.entries where not off_schedule and status in ('current','waiting')) then
    update queue_private.entries set status = 'deferred'
      where off_schedule and status = 'waiting' and not ready;
  else
    update queue_private.entries set status = 'waiting' where status = 'deferred';
  end if;
  -- Keep ready extras first, then initial lab priority, then FIFO (including repeat turns).
  pos := 0;
  for target in select * from queue_private.entries where status = 'waiting' order by
    case when ready then 0 else 1 end,
    case when not off_schedule and retries = 0 and priority then 0 else 1 end,position,id
  loop
    pos := pos + 1;
    update queue_private.entries set position = pos where id = target.id;
  end loop;
  if not exists(select 1 from queue_private.entries where status = 'current') then
    update queue_private.entries set status = 'current' where id = (
      select id from queue_private.entries where status = 'waiting' order by position limit 1
    );
  end if;
  insert into queue_private.results(id,session_id,name,lab,retries,outcome,user_id,off_schedule)
    select id,sid,name,lab,retries,status,user_id,off_schedule from queue_private.entries
    on conflict(id) do update set retries = excluded.retries,outcome = excluded.outcome,off_schedule = excluded.off_schedule,updated_at = now();
end;
$$;

-- Preserve name resolution and admin-only history; extend the public snapshot with the flag.
create or replace function public.queue_snapshot_core() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare admin boolean;
begin
  if auth.uid() is null then raise exception 'Требуется вход'; end if;
  select exists(select 1 from queue_private.admins where user_id = auth.uid()) into admin;
  return jsonb_build_object(
    'lab',(select lab from queue_private.settings where id = 1),'admin',admin,
    'session',(select to_jsonb(s) - 'created_by' from queue_private.sessions s where id = (select session_id from queue_private.settings where id = 1)),
    'sessions',case when admin then coalesce((select jsonb_agg(to_jsonb(s) - 'created_by' order by date desc,id) from queue_private.sessions s),'[]'::jsonb) else '[]'::jsonb end,
    'results',case when admin then coalesce((select jsonb_agg(to_jsonb(r) order by updated_at,id) from queue_private.results r),'[]'::jsonb) else '[]'::jsonb end,
    'entries',coalesce((select jsonb_agg(jsonb_build_object(
      'id',id,'name',name,'lab',lab,'status',status,'priority',priority,'ready',ready,
      'position',position,'retries',retries,'mine',user_id = auth.uid(),'off_schedule',off_schedule) order by position)
      from queue_private.entries),'[]'::jsonb)
  );
end;
$$;
revoke all on function public.queue_snapshot_core() from public,anon,authenticated,service_role;
revoke all on function public.queue_action(text,jsonb) from public,anon;
grant execute on function public.queue_action(text,jsonb) to authenticated;
commit;


-- Continue unfinished extra assignments in later sessions.
-- Keep unfinished extra assignments across sessions. Run after 008.
begin;
create table if not exists queue_private.pending_extras (
  user_id uuid not null references auth.users(id) on delete cascade,
  lab integer not null check(lab between 1 and 99),
  retries integer not null default 0 check(retries >= 0),
  primary key(user_id,lab)
);
alter table queue_private.pending_extras enable row level security;
-- Backfill only explicit extra statuses; overwritten unfinished statuses cannot be inferred.
insert into queue_private.pending_extras(user_id,lab,retries)
  select user_id,lab,retries from (
    select distinct on(user_id,lab) user_id,lab,retries,outcome
    from queue_private.results where user_id is not null order by user_id,lab,updated_at desc,id desc
  ) latest where outcome = 'extra'
  on conflict(user_id,lab) do nothing;
create or replace function public.queue_action(action text,payload jsonb default '{}'::jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  sid uuid;
  active_lab integer;
  admin boolean;
  target queue_private.entries;
  display_name text;
  chosen_lab integer;
  guest boolean;
  previous_retries integer;
  pending_retries integer;
  pos bigint;
  group_name text;
  new_date date;
begin
  if actor is null or not exists(select 1 from auth.users where id = actor and not coalesce(is_anonymous,false)) then
    raise exception 'Войдите в аккаунт по логину и паролю';
  end if;
  select session_id,lab into sid,active_lab from queue_private.settings where id = 1 for update;
  select exists(select 1 from queue_private.admins where user_id = actor) into admin;
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
    insert into queue_private.sessions(date,"group",created_by) values(new_date,group_name,actor) returning id into sid;
    update queue_private.settings set session_id = sid where id = 1;
    return;
  end if;
  if sid is null then raise exception 'Преподаватель ещё не открыл сессию сдачи'; end if;
  if sid is distinct from (payload->>'session_id')::uuid then raise exception 'Сессия изменилась. Обновите страницу'; end if;
  if action = 'end_session' then
    update queue_private.results set outcome = 'unfinished',updated_at = now()
      where session_id = sid and outcome in ('current','waiting','deferred');
    for target in select e.* from queue_private.entries e join queue_private.results r on r.id = e.id where r.session_id = sid loop
      delete from queue_private.entries where id = target.id;
    end loop;
    update queue_private.sessions set ended_at = now() where id = sid;
    update queue_private.settings set session_id = null where id = 1;
    return;
  end if;
  select coalesce(max(position),0)+1 into pos from queue_private.entries;
  if action = 'join' then
    if exists(select 1 from queue_private.entries where user_id = actor) then raise exception 'Вы уже записаны'; end if;
    display_name := coalesce(trim(payload->>'name'),
      (select name from queue_private.profiles where user_id = actor),
      (select raw_user_meta_data->>'display_name' from auth.users where id = actor));
    chosen_lab := (payload->>'lab')::integer;
    guest := coalesce((payload->>'off_schedule')::boolean,false);
    if display_name is null or char_length(display_name) not between 2 and 60 then raise exception 'Укажите имя и фамилию: от 2 до 60 символов'; end if;
    if chosen_lab is null or chosen_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    insert into queue_private.profiles(user_id,name) values(actor,display_name) on conflict(user_id) do update set name = excluded.name;
    select coalesce(max(retries),0) into previous_retries from queue_private.results where session_id = sid and user_id = actor and lab = chosen_lab;
    select retries into pending_retries from queue_private.pending_extras where user_id = actor and lab = chosen_lab;
    previous_retries := greatest(previous_retries,coalesce(pending_retries,0));
    insert into queue_private.entries(user_id,name,lab,status,priority,position,retries,off_schedule)
      values(actor,display_name,chosen_lab,case when pending_retries is not null then 'extra' else 'waiting' end,
        pending_retries is null and not guest and chosen_lab = active_lab and previous_retries = 0,pos,previous_retries,guest);
  elsif action = 'leave' then
    select * into target from queue_private.entries where user_id = actor;
    if target.id is not null then
      update queue_private.results set outcome = 'left',updated_at = now() where id = target.id;
      delete from queue_private.entries where id = target.id;
    end if;
  elsif action = 'ready' then
    select * into target from queue_private.entries where user_id = actor and status = 'extra';
    if target.id is null then raise exception 'Вы не на доп. задании'; end if;
    delete from queue_private.pending_extras where user_id = actor and lab = target.lab;
    update queue_private.entries set status = 'waiting',ready = true,priority = false,position = pos where id = target.id;
  elsif action = 'set_lab' then
    chosen_lab := (payload->>'lab')::integer;
    if chosen_lab is null or chosen_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    update queue_private.settings set lab = chosen_lab where id = 1;
  elsif action in ('next','pass','extra') then
    select * into target from queue_private.entries where status = 'current';
    if target.id is distinct from (payload->>'current_id')::uuid then raise exception 'Очередь изменилась. Обновите страницу и повторите действие'; end if;
    if target.id is not null then
      if action = 'pass' then
        delete from queue_private.pending_extras where user_id = target.user_id and lab = target.lab;
        update queue_private.results set outcome = 'passed',updated_at = now() where id = target.id;
        delete from queue_private.entries where id = target.id;
      else
        update queue_private.entries set status = case when action = 'extra' then 'extra' else 'waiting' end,
          retries = retries + case when action = 'next' then 1 else 0 end,ready = false,priority = false,position = pos where id = target.id;
      end if;
    end if;
  else raise exception 'Неизвестное действие';
  end if;

  if action = 'extra' and target.id is not null then
    insert into queue_private.pending_extras(user_id,lab,retries) values(target.user_id,target.lab,target.retries)
      on conflict(user_id,lab) do update set retries = excluded.retries;
  end if;

  -- Hold guests until scheduled students leave the active queue. Returned extras keep their priority. Never interrupt current.
  if exists(select 1 from queue_private.entries where not off_schedule and status in ('current','waiting')) then
    update queue_private.entries set status = 'deferred'
      where off_schedule and status = 'waiting' and not ready;
  else
    update queue_private.entries set status = 'waiting' where status = 'deferred';
  end if;
  -- Keep ready extras first, then initial lab priority, then FIFO (including repeat turns).
  pos := 0;
  for target in select * from queue_private.entries where status = 'waiting' order by
    case when ready then 0 else 1 end,
    case when not off_schedule and retries = 0 and priority then 0 else 1 end,position,id
  loop
    pos := pos + 1;
    update queue_private.entries set position = pos where id = target.id;
  end loop;
  if not exists(select 1 from queue_private.entries where status = 'current') then
    update queue_private.entries set status = 'current' where id = (
      select id from queue_private.entries where status = 'waiting' order by position limit 1
    );
  end if;
  insert into queue_private.results(id,session_id,name,lab,retries,outcome,user_id,off_schedule)
    select id,sid,name,lab,retries,status,user_id,off_schedule from queue_private.entries
    on conflict(id) do update set retries = excluded.retries,outcome = excluded.outcome,off_schedule = excluded.off_schedule,updated_at = now();
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
  return public.queue_snapshot_core() || jsonb_build_object('profile_name',saved_name,'pending_extras',coalesce((select jsonb_agg(jsonb_build_object('lab',lab,'retries',retries) order by lab) from queue_private.pending_extras where user_id = actor),'[]'::jsonb));
end;
$$;

revoke all on function public.queue_action(text,jsonb) from public,anon;
revoke all on function public.queue_snapshot() from public,anon;
grant execute on function public.queue_action(text,jsonb) to authenticated;
grant execute on function public.queue_snapshot() to authenticated;
commit;


-- Session creation timestamps.
-- Preserve unknown timestamps for old sessions; record actual creation time for new ones.
begin;
alter table queue_private.sessions add column if not exists created_at timestamptz;
alter table queue_private.sessions alter column created_at set default clock_timestamp();
create or replace function public.queue_snapshot_core() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare admin boolean;
begin
  if auth.uid() is null then raise exception 'Требуется вход'; end if;
  select exists(select 1 from queue_private.admins where user_id = auth.uid()) into admin;
  return jsonb_build_object(
    'lab',(select lab from queue_private.settings where id = 1),'admin',admin,
    'session',(select to_jsonb(s) - 'created_by' from queue_private.sessions s where id = (select session_id from queue_private.settings where id = 1)),
    'sessions',case when admin then coalesce((select jsonb_agg(to_jsonb(s) - 'created_by' order by date desc,created_at desc nulls last,id) from queue_private.sessions s),'[]'::jsonb) else '[]'::jsonb end,
    'results',case when admin then coalesce((select jsonb_agg(to_jsonb(r) order by updated_at,id) from queue_private.results r),'[]'::jsonb) else '[]'::jsonb end,
    'entries',coalesce((select jsonb_agg(jsonb_build_object(
      'id',id,'name',name,'lab',lab,'status',status,'priority',priority,'ready',ready,
      'position',position,'retries',retries,'mine',user_id = auth.uid(),'off_schedule',off_schedule) order by position)
      from queue_private.entries),'[]'::jsonb)
  );
end;
$$;

revoke all on function public.queue_snapshot_core() from public,anon,authenticated,service_role;
commit;


-- Newest sessions first, including legacy completion times.
-- Sort newest first using creation time, or known completion time for legacy sessions.
begin;
alter table queue_private.sessions add column if not exists created_at timestamptz;
alter table queue_private.sessions alter column created_at set default clock_timestamp();
create or replace function public.queue_snapshot_core() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare admin boolean;
begin
  if auth.uid() is null then raise exception 'Требуется вход'; end if;
  select exists(select 1 from queue_private.admins where user_id = auth.uid()) into admin;
  return jsonb_build_object(
    'lab',(select lab from queue_private.settings where id = 1),'admin',admin,
    'session',(select to_jsonb(s) - 'created_by' from queue_private.sessions s where id = (select session_id from queue_private.settings where id = 1)),
    'sessions',case when admin then coalesce((select jsonb_agg(to_jsonb(s) - 'created_by' order by coalesce(created_at,ended_at) desc nulls last,date desc,id) from queue_private.sessions s),'[]'::jsonb) else '[]'::jsonb end,
    'results',case when admin then coalesce((select jsonb_agg(to_jsonb(r) order by updated_at,id) from queue_private.results r),'[]'::jsonb) else '[]'::jsonb end,
    'entries',coalesce((select jsonb_agg(jsonb_build_object(
      'id',id,'name',name,'lab',lab,'status',status,'priority',priority,'ready',ready,
      'position',position,'retries',retries,'mine',user_id = auth.uid(),'off_schedule',off_schedule) order by position)
      from queue_private.entries),'[]'::jsonb)
  );
end;
$$;

revoke all on function public.queue_snapshot_core() from public,anon,authenticated,service_role;
commit;


-- Superadmin-only deletion of completed sessions.
-- Dedicated deletion permission, granted only through SQL Editor.
begin;
create table if not exists queue_private.superadmins (
  user_id uuid primary key references queue_private.admins(user_id) on delete cascade
);
alter table queue_private.superadmins enable row level security;
create or replace function public.queue_snapshot_core() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare admin boolean;
begin
  if auth.uid() is null then raise exception 'Требуется вход'; end if;
  select exists(select 1 from queue_private.admins where user_id = auth.uid()) into admin;
  return jsonb_build_object(
    'lab',(select lab from queue_private.settings where id = 1),'admin',admin,'superadmin',exists(select 1 from queue_private.superadmins where user_id = auth.uid()),
    'session',(select to_jsonb(s) - 'created_by' from queue_private.sessions s where id = (select session_id from queue_private.settings where id = 1)),
    'sessions',case when admin then coalesce((select jsonb_agg(to_jsonb(s) - 'created_by' order by coalesce(created_at,ended_at) desc nulls last,date desc,id) from queue_private.sessions s),'[]'::jsonb) else '[]'::jsonb end,
    'results',case when admin then coalesce((select jsonb_agg(to_jsonb(r) order by updated_at,id) from queue_private.results r),'[]'::jsonb) else '[]'::jsonb end,
    'entries',coalesce((select jsonb_agg(jsonb_build_object(
      'id',id,'name',name,'lab',lab,'status',status,'priority',priority,'ready',ready,
      'position',position,'retries',retries,'mine',user_id = auth.uid(),'off_schedule',off_schedule) order by position)
      from queue_private.entries),'[]'::jsonb)
  );
end;
$$;


create or replace function public.queue_delete_session(target_session_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare active_id uuid; ended timestamptz;
begin
  if auth.uid() is null or not exists(select 1 from auth.users u join queue_private.superadmins a on a.user_id = u.id
    where u.id = auth.uid() and not coalesce(u.is_anonymous,false)) then
    raise exception 'Удалять сессии может только superadmin';
  end if;
  select session_id into active_id from queue_private.settings where id = 1 for update;
  select ended_at into ended from queue_private.sessions where id = target_session_id for update;
  if not found then raise exception 'Сессия не найдена или уже удалена'; end if;
  if active_id = target_session_id or ended is null then raise exception 'Сначала завершите сессию'; end if;
  delete from queue_private.results where session_id = target_session_id;
  delete from queue_private.sessions where id = target_session_id;
end;
$$;
revoke all on function public.queue_snapshot_core() from public,anon,authenticated,service_role;
revoke all on function public.queue_delete_session(uuid) from public,anon;
grant execute on function public.queue_delete_session(uuid) to authenticated;
commit;


-- Superadmin teacher provisioning.
begin;
create or replace function public.queue_is_superadmin() returns boolean
language sql security definer set search_path = '' as $$
  select exists(select 1 from queue_private.superadmins where user_id = auth.uid());
$$;
create or replace function public.queue_grant_teacher(teacher_id uuid,teacher_name text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if teacher_name is null or char_length(trim(teacher_name)) not between 2 and 60 then raise exception 'Укажите имя преподавателя'; end if;
  if not exists(select 1 from auth.users where id = teacher_id and not coalesce(is_anonymous,false)) then raise exception 'Аккаунт не найден'; end if;
  insert into queue_private.admins(user_id) values(teacher_id) on conflict do nothing;
  insert into queue_private.profiles(user_id,name) values(teacher_id,trim(teacher_name))
    on conflict(user_id) do update set name = excluded.name;
end;
$$;
revoke all on function public.queue_is_superadmin() from public,anon;
grant execute on function public.queue_is_superadmin() to authenticated;
revoke all on function public.queue_grant_teacher(uuid,text) from public,anon,authenticated;
grant execute on function public.queue_grant_teacher(uuid,text) to service_role;
commit;


-- Per-teacher session isolation. Run after 013. All data changes are transactional.
begin;
alter table queue_private.sessions add column if not exists lab integer not null default 6 check(lab between 1 and 99);
update queue_private.sessions s set lab = cfg.lab from queue_private.settings cfg where s.id = cfg.session_id and cfg.id = 1;
-- Assign legacy owner only when unambiguous. Otherwise only superadmin may access orphaned history.
update queue_private.sessions set created_by = (select user_id from queue_private.admins limit 1)
  where created_by is null and (select count(*) from queue_private.admins) = 1;
drop index if exists queue_private.one_active_session;
create unique index if not exists one_active_session_per_teacher on queue_private.sessions(created_by) where ended_at is null;
alter table queue_private.entries add column if not exists session_id uuid references queue_private.sessions(id);
update queue_private.entries e set session_id = r.session_id from queue_private.results r where e.id = r.id and e.session_id is null;
update queue_private.entries e set session_id = s.session_id from queue_private.settings s where e.session_id is null and s.id = 1;
alter table queue_private.entries alter column session_id set not null;
alter table queue_private.entries drop constraint if exists entries_user_id_key;
create unique index if not exists one_student_per_session on queue_private.entries(session_id,user_id);
drop index if exists queue_private.one_current;
create unique index if not exists one_current_per_session on queue_private.entries(session_id) where status = 'current';
alter table queue_private.pending_extras add column if not exists teacher_id uuid references auth.users(id);
update queue_private.pending_extras p set teacher_id = (
  select s.created_by from queue_private.results r join queue_private.sessions s on s.id = r.session_id
  where r.user_id = p.user_id and r.lab = p.lab and r.outcome = 'extra' and s.created_by is not null order by r.updated_at desc,r.id desc limit 1
) where p.teacher_id is null;
update queue_private.pending_extras set teacher_id = (select user_id from queue_private.admins limit 1)
  where teacher_id is null and (select count(*) from queue_private.admins) = 1;
alter table queue_private.pending_extras drop constraint if exists pending_extras_pkey;
create unique index if not exists one_pending_extra_per_teacher on queue_private.pending_extras(user_id,lab,teacher_id) nulls not distinct;
create or replace function public.queue_action(action text,payload jsonb default '{}'::jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  sid uuid;
  active_lab integer;
  admin boolean;
  owner_id uuid;
  superadmin boolean;
  target queue_private.entries;
  display_name text;
  chosen_lab integer;
  guest boolean;
  previous_retries integer;
  pending_retries integer;
  pos bigint;
  group_name text;
  new_date date;
begin
  if actor is null or not exists(select 1 from auth.users where id = actor and not coalesce(is_anonymous,false)) then
    raise exception 'Войдите в аккаунт по логину и паролю';
  end if;
  sid := (payload->>'session_id')::uuid;
  select exists(select 1 from queue_private.admins where user_id = actor) into admin;
  select exists(select 1 from queue_private.superadmins where user_id = actor) into superadmin;
  if action in ('create_session','end_session','next','pass','extra','set_lab') and not admin then
    raise exception 'Доступ только преподавателю';
  end if;
  if action = 'create_session' then
    perform pg_advisory_xact_lock(hashtextextended(actor::text,0));
    if exists(select 1 from queue_private.sessions where created_by = actor and ended_at is null) then raise exception 'Сначала завершите текущую сессию'; end if;
    new_date := (payload->>'date')::date;
    group_name := trim(payload->>'group');
    if new_date is null or group_name is null or char_length(group_name) not between 1 and 60 then
      raise exception 'Укажите дату и группу (до 60 символов)';
    end if;
    insert into queue_private.sessions(date,"group",created_by) values(new_date,group_name,actor) returning id into sid;
    return;
  end if;
  if sid is null then raise exception 'Выберите сессию преподавателя или откройте QR-код'; end if;
  select created_by,lab into owner_id,active_lab from queue_private.sessions where id = sid and ended_at is null for update;
  if not found then raise exception 'Сессия изменилась или завершена. Обновите страницу'; end if;
  if admin and action in ('end_session','next','pass','extra','set_lab') and owner_id is distinct from actor and not superadmin then
    raise exception 'Вы не можете управлять сессией другого преподавателя';
  end if;
  if action = 'end_session' then
    update queue_private.results set outcome = 'unfinished',updated_at = now()
      where session_id = sid and outcome in ('current','waiting','deferred');
    for target in select e.* from queue_private.entries e join queue_private.results r on r.id = e.id where r.session_id = sid loop
      delete from queue_private.entries where id = target.id;
    end loop;
    update queue_private.sessions set ended_at = now() where id = sid;

    return;
  end if;
  select coalesce(max(position),0)+1 into pos from queue_private.entries where session_id = sid;
  if action = 'join' then
    if exists(select 1 from queue_private.entries where user_id = actor and session_id = sid) then raise exception 'Вы уже записаны'; end if;
    display_name := coalesce(trim(payload->>'name'),
      (select name from queue_private.profiles where user_id = actor),
      (select raw_user_meta_data->>'display_name' from auth.users where id = actor));
    chosen_lab := (payload->>'lab')::integer;
    guest := coalesce((payload->>'off_schedule')::boolean,false);
    if display_name is null or char_length(display_name) not between 2 and 60 then raise exception 'Укажите имя и фамилию: от 2 до 60 символов'; end if;
    if chosen_lab is null or chosen_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    insert into queue_private.profiles(user_id,name) values(actor,display_name) on conflict(user_id) do update set name = excluded.name;
    select coalesce(max(retries),0) into previous_retries from queue_private.results where session_id = sid and user_id = actor and lab = chosen_lab;
    select retries into pending_retries from queue_private.pending_extras where user_id = actor and lab = chosen_lab and teacher_id = owner_id;
    previous_retries := greatest(previous_retries,coalesce(pending_retries,0));
    insert into queue_private.entries(user_id,name,lab,status,priority,position,retries,off_schedule,session_id)
      values(actor,display_name,chosen_lab,case when pending_retries is not null then 'extra' else 'waiting' end,
        pending_retries is null and not guest and chosen_lab = active_lab and previous_retries = 0,pos,previous_retries,guest,sid);
  elsif action = 'leave' then
    select * into target from queue_private.entries where user_id = actor and session_id = sid;
    if target.id is not null then
      update queue_private.results set outcome = 'left',updated_at = now() where id = target.id;
      delete from queue_private.entries where id = target.id;
    end if;
  elsif action = 'ready' then
    select * into target from queue_private.entries where user_id = actor and session_id = sid and status = 'extra';
    if target.id is null then raise exception 'Вы не на доп. задании'; end if;
    delete from queue_private.pending_extras where user_id = actor and lab = target.lab and teacher_id = owner_id;
    update queue_private.entries set status = 'waiting',ready = true,priority = false,position = pos where id = target.id;
  elsif action = 'set_lab' then
    chosen_lab := (payload->>'lab')::integer;
    if chosen_lab is null or chosen_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    update queue_private.sessions set lab = chosen_lab where id = sid;
  elsif action in ('next','pass','extra') then
    select * into target from queue_private.entries where session_id = sid and status = 'current';
    if target.id is distinct from (payload->>'current_id')::uuid then raise exception 'Очередь изменилась. Обновите страницу и повторите действие'; end if;
    if target.id is not null then
      if action = 'pass' then
        delete from queue_private.pending_extras where user_id = target.user_id and lab = target.lab and teacher_id = owner_id;
        update queue_private.results set outcome = 'passed',updated_at = now() where id = target.id;
        delete from queue_private.entries where id = target.id;
      else
        update queue_private.entries set status = case when action = 'extra' then 'extra' else 'waiting' end,
          retries = retries + case when action = 'next' then 1 else 0 end,ready = false,priority = false,position = pos where id = target.id;
      end if;
    end if;
  else raise exception 'Неизвестное действие';
  end if;

  if action = 'extra' and target.id is not null then
    insert into queue_private.pending_extras(user_id,lab,retries,teacher_id) values(target.user_id,target.lab,target.retries,owner_id)
      on conflict(user_id,lab,teacher_id) do update set retries = excluded.retries;
  end if;

  -- Hold guests until scheduled students leave the active queue. Returned extras keep their priority. Never interrupt current.
  if exists(select 1 from queue_private.entries where session_id = sid and not off_schedule and status in ('current','waiting')) then
    update queue_private.entries set status = 'deferred'
      where session_id = sid and off_schedule and status = 'waiting' and not ready;
  else
    update queue_private.entries set status = 'waiting' where session_id = sid and status = 'deferred';
  end if;
  -- Keep ready extras first, then initial lab priority, then FIFO (including repeat turns).
  pos := 0;
  for target in select * from queue_private.entries where session_id = sid and status = 'waiting' order by
    case when ready then 0 else 1 end,
    case when not off_schedule and retries = 0 and priority then 0 else 1 end,position,id
  loop
    pos := pos + 1;
    update queue_private.entries set position = pos where id = target.id;
  end loop;
  if not exists(select 1 from queue_private.entries where session_id = sid and status = 'current') then
    update queue_private.entries set status = 'current' where id = (
      select id from queue_private.entries where session_id = sid and status = 'waiting' order by position limit 1
    );
  end if;
  insert into queue_private.results(id,session_id,name,lab,retries,outcome,user_id,off_schedule)
    select id,sid,name,lab,retries,status,user_id,off_schedule from queue_private.entries where session_id = sid
    on conflict(id) do update set retries = excluded.retries,outcome = excluded.outcome,off_schedule = excluded.off_schedule,updated_at = now();
end;
$$;



-- Source fragment included in migration 014; not a standalone migration.
create or replace function public.queue_snapshot_for_session(target_session_id uuid default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  admin boolean;
  superadmin boolean;
  sid uuid := target_session_id;
  owner_id uuid;
  saved_name text;
  metadata jsonb;
begin
  if actor is null or not exists(select 1 from auth.users where id = actor and not coalesce(is_anonymous,false)) then
    raise exception 'Войдите в аккаунт по логину и паролю';
  end if;
  select exists(select 1 from queue_private.admins where user_id = actor) into admin;
  select exists(select 1 from queue_private.superadmins where user_id = actor) into superadmin;
  if sid is null and admin then
    select id into sid from queue_private.sessions where created_by = actor and ended_at is null order by created_at desc nulls last,id limit 1;
  end if;
  if sid is not null then
    if admin and not superadmin and exists(select 1 from queue_private.sessions where id = sid and created_by is distinct from actor) then
      raise exception 'Вы не можете просматривать сессию другого преподавателя';
    end if;
    select created_by into owner_id from queue_private.sessions where id = sid and ended_at is null;
    if not found then sid := null; end if;
  end if;
  select raw_user_meta_data into metadata from auth.users where id = actor;
  saved_name := coalesce(
    (select nullif(trim(name),'') from queue_private.profiles where user_id = actor),
    (select nullif(trim(name),'') from queue_private.entries where user_id = actor order by position,id limit 1),
    (select nullif(trim(name),'') from queue_private.results where user_id = actor order by updated_at desc,id limit 1),
    nullif(trim(metadata->>'display_name'),''),nullif(trim(metadata->>'full_name'),''),nullif(trim(metadata->>'name'),''),
    nullif(trim(concat_ws(' ',nullif(trim(metadata->>'first_name'),''),nullif(trim(metadata->>'last_name'),''))),'')
  );
  return jsonb_build_object(
    'admin',admin,'superadmin',superadmin,'profile_name',saved_name,
    'lab',coalesce((select lab from queue_private.sessions where id = sid),6),
    'session',(select to_jsonb(s) || jsonb_build_object('teacher_name',coalesce(p.name,'Преподаватель')) from queue_private.sessions s left join queue_private.profiles p on p.user_id = s.created_by where s.id = sid),
    'available_sessions',coalesce((select jsonb_agg(to_jsonb(s) || jsonb_build_object('teacher_name',coalesce(p.name,'Преподаватель')) order by s.created_at desc nulls last,s.id)
      from queue_private.sessions s left join queue_private.profiles p on p.user_id = s.created_by
      where s.ended_at is null and (not admin or superadmin or s.created_by = actor)),'[]'::jsonb),
    'sessions',case when admin then coalesce((select jsonb_agg(to_jsonb(s) || jsonb_build_object('teacher_name',coalesce(p.name,'Преподаватель')) order by coalesce(s.created_at,s.ended_at) desc nulls last,s.date desc,s.id)
      from queue_private.sessions s left join queue_private.profiles p on p.user_id = s.created_by where superadmin or s.created_by = actor),'[]'::jsonb) else '[]'::jsonb end,
    'results',case when admin then coalesce((select jsonb_agg(to_jsonb(r) order by r.updated_at,r.id)
      from queue_private.results r join queue_private.sessions s on s.id = r.session_id where superadmin or s.created_by = actor),'[]'::jsonb) else '[]'::jsonb end,
    'pending_extras',coalesce((select jsonb_agg(jsonb_build_object('lab',lab,'retries',retries) order by lab)
      from queue_private.pending_extras where user_id = actor and teacher_id = owner_id),'[]'::jsonb),
    'entries',coalesce((select jsonb_agg(jsonb_build_object(
      'id',id,'name',name,'lab',lab,'status',status,'priority',priority,'ready',ready,
      'position',position,'retries',retries,'mine',user_id = actor,'off_schedule',off_schedule) order by position,id)
      from queue_private.entries where session_id = sid),'[]'::jsonb)
  );
end;
$$;

-- Backwards-compatible no-argument RPC. New clients explicitly select a session.
create or replace function public.queue_snapshot() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare sid uuid;
begin
  if not exists(select 1 from queue_private.admins where user_id = auth.uid()) then
    select session_id into sid from queue_private.entries where user_id = auth.uid() order by position,id limit 1;
    if sid is null and (select count(*) from queue_private.sessions where ended_at is null) = 1 then
      select id into sid from queue_private.sessions where ended_at is null limit 1;
    end if;
  end if;
  return public.queue_snapshot_for_session(sid);
end;
$$;

create or replace function public.queue_delete_session(target_session_id uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare ended timestamptz;
begin
  if auth.uid() is null or not exists(select 1 from auth.users u join queue_private.superadmins a on a.user_id = u.id
    where u.id = auth.uid() and not coalesce(u.is_anonymous,false)) then raise exception 'Удалять сессии может только superadmin'; end if;
  select ended_at into ended from queue_private.sessions where id = target_session_id for update;
  if not found then raise exception 'Сессия не найдена или уже удалена'; end if;
  if ended is null then raise exception 'Сначала завершите сессию'; end if;
  delete from queue_private.results where session_id = target_session_id;
  delete from queue_private.sessions where id = target_session_id;
end;
$$;
revoke all on function public.queue_snapshot_for_session(uuid) from public,anon;
revoke all on function public.queue_action(text,jsonb) from public,anon;
revoke all on function public.queue_snapshot() from public,anon;
revoke all on function public.queue_delete_session(uuid) from public,anon;
grant execute on function public.queue_snapshot_for_session(uuid) to authenticated;
grant execute on function public.queue_action(text,jsonb) to authenticated;
grant execute on function public.queue_snapshot() to authenticated;
grant execute on function public.queue_delete_session(uuid) to authenticated;

update queue_private.settings set session_id = null where id = 1;
commit;


-- Persistent extra markers.
-- Persistent extra-assignment markers and FIFO return for tasks from a previous session.
begin;
alter table queue_private.entries add column if not exists had_extra boolean not null default false;
alter table queue_private.entries add column if not exists carried_extra boolean not null default false;
alter table queue_private.results add column if not exists had_extra boolean not null default false;
alter table queue_private.results add column if not exists carried_extra boolean not null default false;
alter table queue_private.pending_extras add column if not exists source_session_id uuid references queue_private.sessions(id) on delete set null;
update queue_private.entries set had_extra = true where status = 'extra';
update queue_private.results set had_extra = true where outcome = 'extra';
update queue_private.pending_extras p set source_session_id = (
 select r.session_id from queue_private.results r join queue_private.sessions s on s.id=r.session_id
 where r.user_id=p.user_id and r.lab=p.lab and s.created_by=p.teacher_id and r.outcome='extra'
 order by r.updated_at desc,r.id desc limit 1
) where p.source_session_id is null;
update queue_private.entries e set carried_extra = true from queue_private.pending_extras p
 where e.status='extra' and e.user_id=p.user_id and e.lab=p.lab
 and exists(select 1 from queue_private.sessions s where s.id=e.session_id and s.created_by=p.teacher_id)
 and p.source_session_id is distinct from e.session_id;
create or replace function public.queue_action(action text,payload jsonb default '{}'::jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  sid uuid;
  active_lab integer;
  admin boolean;
  owner_id uuid;
  superadmin boolean;
  target queue_private.entries;
  display_name text;
  chosen_lab integer;
  guest boolean;
  previous_retries integer;
  pending_retries integer;
  pending_source uuid;
  was_extra boolean;
  was_carried boolean;
  pos bigint;
  group_name text;
  new_date date;
begin
  if actor is null or not exists(select 1 from auth.users where id = actor and not coalesce(is_anonymous,false)) then
    raise exception 'Войдите в аккаунт по логину и паролю';
  end if;
  sid := (payload->>'session_id')::uuid;
  select exists(select 1 from queue_private.admins where user_id = actor) into admin;
  select exists(select 1 from queue_private.superadmins where user_id = actor) into superadmin;
  if action in ('create_session','end_session','next','pass','extra','set_lab') and not admin then
    raise exception 'Доступ только преподавателю';
  end if;
  if action = 'create_session' then
    perform pg_advisory_xact_lock(hashtextextended(actor::text,0));
    if exists(select 1 from queue_private.sessions where created_by = actor and ended_at is null) then raise exception 'Сначала завершите текущую сессию'; end if;
    new_date := (payload->>'date')::date;
    group_name := trim(payload->>'group');
    if new_date is null or group_name is null or char_length(group_name) not between 1 and 60 then
      raise exception 'Укажите дату и группу (до 60 символов)';
    end if;
    insert into queue_private.sessions(date,"group",created_by) values(new_date,group_name,actor) returning id into sid;
    return;
  end if;
  if sid is null then raise exception 'Выберите сессию преподавателя или откройте QR-код'; end if;
  select created_by,lab into owner_id,active_lab from queue_private.sessions where id = sid and ended_at is null for update;
  if not found then raise exception 'Сессия изменилась или завершена. Обновите страницу'; end if;
  if admin and action in ('end_session','next','pass','extra','set_lab') and owner_id is distinct from actor and not superadmin then
    raise exception 'Вы не можете управлять сессией другого преподавателя';
  end if;
  if action = 'end_session' then
    update queue_private.results set outcome = 'unfinished',updated_at = now()
      where session_id = sid and outcome in ('current','waiting','deferred');
    for target in select e.* from queue_private.entries e join queue_private.results r on r.id = e.id where r.session_id = sid loop
      delete from queue_private.entries where id = target.id;
    end loop;
    update queue_private.sessions set ended_at = now() where id = sid;

    return;
  end if;
  select coalesce(max(position),0)+1 into pos from queue_private.entries where session_id = sid;
  if action = 'join' then
    if exists(select 1 from queue_private.entries where user_id = actor and session_id = sid) then raise exception 'Вы уже записаны'; end if;
    display_name := coalesce(trim(payload->>'name'),
      (select name from queue_private.profiles where user_id = actor),
      (select raw_user_meta_data->>'display_name' from auth.users where id = actor));
    chosen_lab := (payload->>'lab')::integer;
    guest := coalesce((payload->>'off_schedule')::boolean,false);
    if display_name is null or char_length(display_name) not between 2 and 60 then raise exception 'Укажите имя и фамилию: от 2 до 60 символов'; end if;
    if chosen_lab is null or chosen_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    insert into queue_private.profiles(user_id,name) values(actor,display_name) on conflict(user_id) do update set name = excluded.name;
    select coalesce(max(retries),0) into previous_retries from queue_private.results where session_id = sid and user_id = actor and lab = chosen_lab;
    select retries,source_session_id into pending_retries,pending_source from queue_private.pending_extras where user_id = actor and lab = chosen_lab and teacher_id = owner_id;
    select coalesce(bool_or(r.had_extra),false),coalesce(bool_or(r.carried_extra),false) into was_extra,was_carried
      from queue_private.results r where r.session_id = sid and r.user_id = actor and r.lab = chosen_lab;
    if pending_retries is not null then was_extra := true; was_carried := pending_source is distinct from sid; end if;
    previous_retries := greatest(previous_retries,coalesce(pending_retries,0));
    insert into queue_private.entries(user_id,name,lab,status,priority,position,retries,off_schedule,session_id,had_extra,carried_extra)
      values(actor,display_name,chosen_lab,case when pending_retries is not null then 'extra' else 'waiting' end,
        pending_retries is null and not guest and chosen_lab = active_lab and previous_retries = 0 and not was_extra,pos,previous_retries,guest,sid,was_extra,was_carried);
  elsif action = 'leave' then
    select * into target from queue_private.entries where user_id = actor and session_id = sid;
    if target.id is not null then
      update queue_private.results set outcome = 'left',updated_at = now() where id = target.id;
      delete from queue_private.entries where id = target.id;
    end if;
  elsif action = 'ready' then
    select * into target from queue_private.entries where user_id = actor and session_id = sid and status = 'extra';
    if target.id is null then raise exception 'Вы не на доп. задании'; end if;
    delete from queue_private.pending_extras where user_id = actor and lab = target.lab and teacher_id = owner_id;
    update queue_private.entries set status = 'waiting',ready = not target.carried_extra,priority = false,position = pos where id = target.id;
  elsif action = 'set_lab' then
    chosen_lab := (payload->>'lab')::integer;
    if chosen_lab is null or chosen_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    update queue_private.sessions set lab = chosen_lab where id = sid;
  elsif action in ('next','pass','extra') then
    select * into target from queue_private.entries where session_id = sid and status = 'current';
    if target.id is distinct from (payload->>'current_id')::uuid then raise exception 'Очередь изменилась. Обновите страницу и повторите действие'; end if;
    if target.id is not null then
      if action = 'pass' then
        delete from queue_private.pending_extras where user_id = target.user_id and lab = target.lab and teacher_id = owner_id;
        update queue_private.results set outcome = 'passed',updated_at = now() where id = target.id;
        delete from queue_private.entries where id = target.id;
      else
        update queue_private.entries set status = case when action = 'extra' then 'extra' else 'waiting' end,
          had_extra = queue_private.entries.had_extra or action = 'extra',carried_extra = case when action = 'extra' then false else queue_private.entries.carried_extra end,
          retries = retries + case when action = 'next' then 1 else 0 end,ready = false,priority = false,position = pos where id = target.id;
      end if;
    end if;
  else raise exception 'Неизвестное действие';
  end if;

  if action = 'extra' and target.id is not null then
    insert into queue_private.pending_extras(user_id,lab,retries,teacher_id,source_session_id) values(target.user_id,target.lab,target.retries,owner_id,sid)
      on conflict(user_id,lab,teacher_id) do update set retries = excluded.retries,source_session_id = excluded.source_session_id;
  end if;

  -- Hold guests until scheduled students leave the active queue. Returned extras keep their priority. Never interrupt current.
  if exists(select 1 from queue_private.entries where session_id = sid and not off_schedule and status in ('current','waiting')) then
    update queue_private.entries set status = 'deferred'
      where session_id = sid and off_schedule and status = 'waiting' and not ready;
  else
    update queue_private.entries set status = 'waiting' where session_id = sid and status = 'deferred';
  end if;
  -- Keep ready extras first, then initial lab priority, then FIFO (including repeat turns).
  pos := 0;
  for target in select * from queue_private.entries where session_id = sid and status = 'waiting' order by
    case when ready then 0 else 1 end,
    case when not off_schedule and retries = 0 and priority then 0 else 1 end,position,id
  loop
    pos := pos + 1;
    update queue_private.entries set position = pos where id = target.id;
  end loop;
  if not exists(select 1 from queue_private.entries where session_id = sid and status = 'current') then
    update queue_private.entries set status = 'current' where id = (
      select id from queue_private.entries where session_id = sid and status = 'waiting' order by position limit 1
    );
  end if;
  insert into queue_private.results(id,session_id,name,lab,retries,outcome,user_id,off_schedule,had_extra,carried_extra)
    select id,sid,name,lab,retries,status,user_id,off_schedule,had_extra,carried_extra from queue_private.entries where session_id = sid
    on conflict(id) do update set retries = excluded.retries,outcome = excluded.outcome,off_schedule = excluded.off_schedule,had_extra = excluded.had_extra,carried_extra = excluded.carried_extra,updated_at = now();
end;
$$;




create or replace function public.queue_snapshot_for_session(target_session_id uuid default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  admin boolean;
  superadmin boolean;
  sid uuid := target_session_id;
  owner_id uuid;
  saved_name text;
  metadata jsonb;
begin
  if actor is null or not exists(select 1 from auth.users where id = actor and not coalesce(is_anonymous,false)) then
    raise exception 'Войдите в аккаунт по логину и паролю';
  end if;
  select exists(select 1 from queue_private.admins where user_id = actor) into admin;
  select exists(select 1 from queue_private.superadmins where user_id = actor) into superadmin;
  if sid is null and admin then
    select id into sid from queue_private.sessions where created_by = actor and ended_at is null order by created_at desc nulls last,id limit 1;
  end if;
  if sid is not null then
    if admin and not superadmin and exists(select 1 from queue_private.sessions where id = sid and created_by is distinct from actor) then
      raise exception 'Вы не можете просматривать сессию другого преподавателя';
    end if;
    select created_by into owner_id from queue_private.sessions where id = sid and ended_at is null;
    if not found then sid := null; end if;
  end if;
  select raw_user_meta_data into metadata from auth.users where id = actor;
  saved_name := coalesce(
    (select nullif(trim(name),'') from queue_private.profiles where user_id = actor),
    (select nullif(trim(name),'') from queue_private.entries where user_id = actor order by position,id limit 1),
    (select nullif(trim(name),'') from queue_private.results where user_id = actor order by updated_at desc,id limit 1),
    nullif(trim(metadata->>'display_name'),''),nullif(trim(metadata->>'full_name'),''),nullif(trim(metadata->>'name'),''),
    nullif(trim(concat_ws(' ',nullif(trim(metadata->>'first_name'),''),nullif(trim(metadata->>'last_name'),''))),'')
  );
  return jsonb_build_object(
    'admin',admin,'superadmin',superadmin,'profile_name',saved_name,
    'lab',coalesce((select lab from queue_private.sessions where id = sid),6),
    'session',(select to_jsonb(s) || jsonb_build_object('teacher_name',coalesce(p.name,'Преподаватель')) from queue_private.sessions s left join queue_private.profiles p on p.user_id = s.created_by where s.id = sid),
    'available_sessions',coalesce((select jsonb_agg(to_jsonb(s) || jsonb_build_object('teacher_name',coalesce(p.name,'Преподаватель')) order by s.created_at desc nulls last,s.id)
      from queue_private.sessions s left join queue_private.profiles p on p.user_id = s.created_by
      where s.ended_at is null and (not admin or superadmin or s.created_by = actor)),'[]'::jsonb),
    'sessions',case when admin then coalesce((select jsonb_agg(to_jsonb(s) || jsonb_build_object('teacher_name',coalesce(p.name,'Преподаватель')) order by coalesce(s.created_at,s.ended_at) desc nulls last,s.date desc,s.id)
      from queue_private.sessions s left join queue_private.profiles p on p.user_id = s.created_by where superadmin or s.created_by = actor),'[]'::jsonb) else '[]'::jsonb end,
    'results',case when admin then coalesce((select jsonb_agg(to_jsonb(r) order by r.updated_at,r.id)
      from queue_private.results r join queue_private.sessions s on s.id = r.session_id where superadmin or s.created_by = actor),'[]'::jsonb) else '[]'::jsonb end,
    'pending_extras',coalesce((select jsonb_agg(jsonb_build_object('lab',lab,'retries',retries) order by lab)
      from queue_private.pending_extras where user_id = actor and teacher_id = owner_id),'[]'::jsonb),
    'entries',coalesce((select jsonb_agg(jsonb_build_object(
      'id',id,'name',name,'lab',lab,'status',status,'priority',priority,'ready',ready,
      'position',position,'retries',retries,'mine',user_id = actor,'off_schedule',off_schedule,'had_extra',had_extra,'carried_extra',carried_extra) order by position,id)
      from queue_private.entries where session_id = sid),'[]'::jsonb)
  );
end;
$$;


revoke all on function public.queue_action(text,jsonb) from public,anon;
revoke all on function public.queue_snapshot_for_session(uuid) from public,anon;
grant execute on function public.queue_action(text,jsonb) to authenticated;
grant execute on function public.queue_snapshot_for_session(uuid) to authenticated;
commit;


-- Laboratory medals.
-- Laboratory medals. Existing boolean markers provide only a lower bound for historical counts.
begin;
alter table queue_private.entries add column if not exists extra_count integer not null default 0 check(extra_count>=0);
alter table queue_private.results add column if not exists extra_count integer not null default 0 check(extra_count>=0);
alter table queue_private.results add column if not exists first_try_pass boolean not null default false;
alter table queue_private.pending_extras add column if not exists extra_count integer not null default 0 check(extra_count>=0);
update queue_private.entries set extra_count=1 where had_extra and extra_count=0;
update queue_private.results set extra_count=1 where had_extra and extra_count=0;
update queue_private.pending_extras set extra_count=1 where extra_count=0;
create or replace function public.queue_action(action text,payload jsonb default '{}'::jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  sid uuid;
  active_lab integer;
  admin boolean;
  owner_id uuid;
  superadmin boolean;
  target queue_private.entries;
  display_name text;
  chosen_lab integer;
  guest boolean;
  previous_retries integer;
  pending_retries integer;
  pending_source uuid;
  extra_total integer;
  was_extra boolean;
  was_carried boolean;
  pos bigint;
  group_name text;
  new_date date;
begin
  if actor is null or not exists(select 1 from auth.users where id = actor and not coalesce(is_anonymous,false)) then
    raise exception 'Войдите в аккаунт по логину и паролю';
  end if;
  sid := (payload->>'session_id')::uuid;
  select exists(select 1 from queue_private.admins where user_id = actor) into admin;
  select exists(select 1 from queue_private.superadmins where user_id = actor) into superadmin;
  if action in ('create_session','end_session','next','pass','extra','set_lab') and not admin then
    raise exception 'Доступ только преподавателю';
  end if;
  if action = 'create_session' then
    perform pg_advisory_xact_lock(hashtextextended(actor::text,0));
    if exists(select 1 from queue_private.sessions where created_by = actor and ended_at is null) then raise exception 'Сначала завершите текущую сессию'; end if;
    new_date := (payload->>'date')::date;
    group_name := trim(payload->>'group');
    if new_date is null or group_name is null or char_length(group_name) not between 1 and 60 then
      raise exception 'Укажите дату и группу (до 60 символов)';
    end if;
    insert into queue_private.sessions(date,"group",created_by) values(new_date,group_name,actor) returning id into sid;
    return;
  end if;
  if sid is null then raise exception 'Выберите сессию преподавателя или откройте QR-код'; end if;
  select created_by,lab into owner_id,active_lab from queue_private.sessions where id = sid and ended_at is null for update;
  if not found then raise exception 'Сессия изменилась или завершена. Обновите страницу'; end if;
  if admin and action in ('end_session','next','pass','extra','set_lab') and owner_id is distinct from actor and not superadmin then
    raise exception 'Вы не можете управлять сессией другого преподавателя';
  end if;
  if action = 'end_session' then
    update queue_private.results set outcome = 'failed',updated_at = now()
      where session_id = sid and outcome in ('current','waiting','deferred');
    for target in select e.* from queue_private.entries e join queue_private.results r on r.id = e.id where r.session_id = sid loop
      delete from queue_private.entries where id = target.id;
    end loop;
    update queue_private.sessions set ended_at = now() where id = sid;

    return;
  end if;
  select coalesce(max(position),0)+1 into pos from queue_private.entries where session_id = sid;
  if action = 'join' then
    if exists(select 1 from queue_private.entries where user_id = actor and session_id = sid) then raise exception 'Вы уже записаны'; end if;
    display_name := coalesce(trim(payload->>'name'),
      (select name from queue_private.profiles where user_id = actor),
      (select raw_user_meta_data->>'display_name' from auth.users where id = actor));
    chosen_lab := (payload->>'lab')::integer;
    guest := coalesce((payload->>'off_schedule')::boolean,false);
    if display_name is null or char_length(display_name) not between 2 and 60 then raise exception 'Укажите имя и фамилию: от 2 до 60 символов'; end if;
    if chosen_lab is null or chosen_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    insert into queue_private.profiles(user_id,name) values(actor,display_name) on conflict(user_id) do update set name = excluded.name;
    select coalesce(max(retries),0) into previous_retries from queue_private.results where session_id = sid and user_id = actor and lab = chosen_lab;
    select retries,source_session_id into pending_retries,pending_source from queue_private.pending_extras where user_id = actor and lab = chosen_lab and teacher_id = owner_id;
    select coalesce(bool_or(r.had_extra),false),coalesce(bool_or(r.carried_extra),false) into was_extra,was_carried
      from queue_private.results r where r.session_id = sid and r.user_id = actor and r.lab = chosen_lab;
    if pending_retries is not null then was_extra := true; was_carried := pending_source is distinct from sid; end if;
    select coalesce(max(r.extra_count),0) into extra_total from queue_private.results r
      join queue_private.sessions s on s.id=r.session_id
      where r.user_id=actor and r.lab=chosen_lab and s.created_by=owner_id;
    extra_total := greatest(extra_total,coalesce((select extra_count from queue_private.pending_extras where user_id=actor and lab=chosen_lab and teacher_id=owner_id),0));
    previous_retries := greatest(previous_retries,coalesce(pending_retries,0));
    insert into queue_private.entries(user_id,name,lab,status,priority,position,retries,off_schedule,session_id,had_extra,carried_extra,extra_count)
      values(actor,display_name,chosen_lab,case when pending_retries is not null then 'extra' else 'waiting' end,
        pending_retries is null and not guest and chosen_lab = active_lab and previous_retries = 0 and not was_extra,pos,previous_retries,guest,sid,was_extra,was_carried,extra_total);
  elsif action = 'leave' then
    select * into target from queue_private.entries where user_id = actor and session_id = sid;
    if target.id is not null then
      update queue_private.results set outcome = 'left',updated_at = now() where id = target.id;
      delete from queue_private.entries where id = target.id;
    end if;
  elsif action = 'ready' then
    select * into target from queue_private.entries where user_id = actor and session_id = sid and status = 'extra';
    if target.id is null then raise exception 'Вы не на доп. задании'; end if;
    delete from queue_private.pending_extras where user_id = actor and lab = target.lab and teacher_id = owner_id;
    update queue_private.entries set status = 'waiting',ready = not target.carried_extra,priority = false,position = pos where id = target.id;
  elsif action = 'set_lab' then
    chosen_lab := (payload->>'lab')::integer;
    if chosen_lab is null or chosen_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    update queue_private.sessions set lab = chosen_lab where id = sid;
  elsif action in ('next','pass','extra') then
    select * into target from queue_private.entries where session_id = sid and status = 'current';
    if target.id is distinct from (payload->>'current_id')::uuid then raise exception 'Очередь изменилась. Обновите страницу и повторите действие'; end if;
    if target.id is not null then
      if action = 'pass' then
        delete from queue_private.pending_extras where user_id = target.user_id and lab = target.lab and teacher_id = owner_id;
        update queue_private.results set outcome = 'passed',first_try_pass = (
          target.retries=0 and target.extra_count=0 and not target.had_extra and not exists(
            select 1 from queue_private.results prior join queue_private.sessions s on s.id=prior.session_id
            where prior.user_id=target.user_id and prior.lab=target.lab and s.created_by=owner_id and prior.id<>target.id
              and (prior.outcome in ('failed','passed') or prior.retries>0 or prior.had_extra)
          )),updated_at = now() where id = target.id;
        delete from queue_private.entries where id = target.id;
      else
        update queue_private.entries set status = case when action = 'extra' then 'extra' else 'waiting' end,
          extra_count = extra_count + case when action = 'extra' then 1 else 0 end,
          had_extra = queue_private.entries.had_extra or action = 'extra',carried_extra = case when action = 'extra' then false else queue_private.entries.carried_extra end,
          retries = retries + case when action = 'next' then 1 else 0 end,ready = false,priority = false,position = pos where id = target.id;
      end if;
    end if;
  else raise exception 'Неизвестное действие';
  end if;

  if action = 'extra' and target.id is not null then
    insert into queue_private.pending_extras(user_id,lab,retries,teacher_id,source_session_id,extra_count) values(target.user_id,target.lab,target.retries,owner_id,sid,target.extra_count+1)
      on conflict(user_id,lab,teacher_id) do update set retries = excluded.retries,source_session_id = excluded.source_session_id,extra_count = excluded.extra_count;
  end if;

  -- Hold guests until scheduled students leave the active queue. Returned extras keep their priority. Never interrupt current.
  if exists(select 1 from queue_private.entries where session_id = sid and not off_schedule and status in ('current','waiting')) then
    update queue_private.entries set status = 'deferred'
      where session_id = sid and off_schedule and status = 'waiting' and not ready;
  else
    update queue_private.entries set status = 'waiting' where session_id = sid and status = 'deferred';
  end if;
  -- Keep ready extras first, then initial lab priority, then FIFO (including repeat turns).
  pos := 0;
  for target in select * from queue_private.entries where session_id = sid and status = 'waiting' order by
    case when ready then 0 else 1 end,
    case when not off_schedule and retries = 0 and priority then 0 else 1 end,position,id
  loop
    pos := pos + 1;
    update queue_private.entries set position = pos where id = target.id;
  end loop;
  if not exists(select 1 from queue_private.entries where session_id = sid and status = 'current') then
    update queue_private.entries set status = 'current' where id = (
      select id from queue_private.entries where session_id = sid and status = 'waiting' order by position limit 1
    );
  end if;
  insert into queue_private.results(id,session_id,name,lab,retries,outcome,user_id,off_schedule,had_extra,carried_extra,extra_count)
    select id,sid,name,lab,retries,status,user_id,off_schedule,had_extra,carried_extra,extra_count from queue_private.entries where session_id = sid
    on conflict(id) do update set retries = excluded.retries,outcome = excluded.outcome,off_schedule = excluded.off_schedule,had_extra = excluded.had_extra,carried_extra = excluded.carried_extra,extra_count = excluded.extra_count,updated_at = now();
end;
$$;





create or replace function public.queue_snapshot_for_session(target_session_id uuid default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  admin boolean;
  superadmin boolean;
  sid uuid := target_session_id;
  owner_id uuid;
  saved_name text;
  metadata jsonb;
begin
  if actor is null or not exists(select 1 from auth.users where id = actor and not coalesce(is_anonymous,false)) then
    raise exception 'Войдите в аккаунт по логину и паролю';
  end if;
  select exists(select 1 from queue_private.admins where user_id = actor) into admin;
  select exists(select 1 from queue_private.superadmins where user_id = actor) into superadmin;
  if sid is null and admin then
    select id into sid from queue_private.sessions where created_by = actor and ended_at is null order by created_at desc nulls last,id limit 1;
  end if;
  if sid is not null then
    if admin and not superadmin and exists(select 1 from queue_private.sessions where id = sid and created_by is distinct from actor) then
      raise exception 'Вы не можете просматривать сессию другого преподавателя';
    end if;
    select created_by into owner_id from queue_private.sessions where id = sid and ended_at is null;
    if not found then sid := null; end if;
  end if;
  select raw_user_meta_data into metadata from auth.users where id = actor;
  saved_name := coalesce(
    (select nullif(trim(name),'') from queue_private.profiles where user_id = actor),
    (select nullif(trim(name),'') from queue_private.entries where user_id = actor order by position,id limit 1),
    (select nullif(trim(name),'') from queue_private.results where user_id = actor order by updated_at desc,id limit 1),
    nullif(trim(metadata->>'display_name'),''),nullif(trim(metadata->>'full_name'),''),nullif(trim(metadata->>'name'),''),
    nullif(trim(concat_ws(' ',nullif(trim(metadata->>'first_name'),''),nullif(trim(metadata->>'last_name'),''))),'')
  );
  return jsonb_build_object(
    'admin',admin,'superadmin',superadmin,'profile_name',saved_name,
    'lab',coalesce((select lab from queue_private.sessions where id = sid),6),
    'session',(select to_jsonb(s) || jsonb_build_object('teacher_name',coalesce(p.name,'Преподаватель')) from queue_private.sessions s left join queue_private.profiles p on p.user_id = s.created_by where s.id = sid),
    'available_sessions',coalesce((select jsonb_agg(to_jsonb(s) || jsonb_build_object('teacher_name',coalesce(p.name,'Преподаватель')) order by s.created_at desc nulls last,s.id)
      from queue_private.sessions s left join queue_private.profiles p on p.user_id = s.created_by
      where s.ended_at is null and (not admin or superadmin or s.created_by = actor)),'[]'::jsonb),
    'sessions',case when admin then coalesce((select jsonb_agg(to_jsonb(s) || jsonb_build_object('teacher_name',coalesce(p.name,'Преподаватель')) order by coalesce(s.created_at,s.ended_at) desc nulls last,s.date desc,s.id)
      from queue_private.sessions s left join queue_private.profiles p on p.user_id = s.created_by where superadmin or s.created_by = actor),'[]'::jsonb) else '[]'::jsonb end,
    'results',case when admin then coalesce((select jsonb_agg(to_jsonb(r) order by r.updated_at,r.id)
      from queue_private.results r join queue_private.sessions s on s.id = r.session_id where superadmin or s.created_by = actor),'[]'::jsonb) else '[]'::jsonb end,
    'pending_extras',coalesce((select jsonb_agg(jsonb_build_object('lab',lab,'retries',retries) order by lab)
      from queue_private.pending_extras where user_id = actor and teacher_id = owner_id),'[]'::jsonb),
    'entries',coalesce((select jsonb_agg(jsonb_build_object(
      'id',id,'name',name,'lab',lab,'status',status,'priority',priority,'ready',ready,
      'position',position,'retries',retries,'mine',user_id = actor,'off_schedule',off_schedule,'had_extra',had_extra,'carried_extra',carried_extra,'extra_count',extra_count) order by position,id)
      from queue_private.entries where session_id = sid),'[]'::jsonb)
  );
end;
$$;



revoke all on function public.queue_action(text,jsonb) from public,anon;
revoke all on function public.queue_snapshot_for_session(uuid) from public,anon;
grant execute on function public.queue_action(text,jsonb) to authenticated;
grant execute on function public.queue_snapshot_for_session(uuid) to authenticated;
commit;


-- Undo extra assignment readiness.
-- Student can undo readiness without earning medals or changing repeat counters.
begin;
alter table queue_private.entries add column if not exists can_return_extra boolean not null default false;
update queue_private.entries set can_return_extra=true where ready and status in ('waiting','current');
create or replace function public.queue_action(action text,payload jsonb default '{}'::jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  sid uuid;
  active_lab integer;
  admin boolean;
  owner_id uuid;
  superadmin boolean;
  target queue_private.entries;
  display_name text;
  chosen_lab integer;
  guest boolean;
  previous_retries integer;
  pending_retries integer;
  pending_source uuid;
  extra_total integer;
  was_extra boolean;
  was_carried boolean;
  pos bigint;
  group_name text;
  new_date date;
begin
  if actor is null or not exists(select 1 from auth.users where id = actor and not coalesce(is_anonymous,false)) then
    raise exception 'Войдите в аккаунт по логину и паролю';
  end if;
  sid := (payload->>'session_id')::uuid;
  select exists(select 1 from queue_private.admins where user_id = actor) into admin;
  select exists(select 1 from queue_private.superadmins where user_id = actor) into superadmin;
  if action in ('create_session','end_session','next','pass','extra','set_lab') and not admin then
    raise exception 'Доступ только преподавателю';
  end if;
  if action = 'create_session' then
    perform pg_advisory_xact_lock(hashtextextended(actor::text,0));
    if exists(select 1 from queue_private.sessions where created_by = actor and ended_at is null) then raise exception 'Сначала завершите текущую сессию'; end if;
    new_date := (payload->>'date')::date;
    group_name := trim(payload->>'group');
    if new_date is null or group_name is null or char_length(group_name) not between 1 and 60 then
      raise exception 'Укажите дату и группу (до 60 символов)';
    end if;
    insert into queue_private.sessions(date,"group",created_by) values(new_date,group_name,actor) returning id into sid;
    return;
  end if;
  if sid is null then raise exception 'Выберите сессию преподавателя или откройте QR-код'; end if;
  select created_by,lab into owner_id,active_lab from queue_private.sessions where id = sid and ended_at is null for update;
  if not found then raise exception 'Сессия изменилась или завершена. Обновите страницу'; end if;
  if admin and action in ('end_session','next','pass','extra','set_lab') and owner_id is distinct from actor and not superadmin then
    raise exception 'Вы не можете управлять сессией другого преподавателя';
  end if;
  if action = 'end_session' then
    update queue_private.results set outcome = 'failed',updated_at = now()
      where session_id = sid and outcome in ('current','waiting','deferred');
    for target in select e.* from queue_private.entries e join queue_private.results r on r.id = e.id where r.session_id = sid loop
      delete from queue_private.entries where id = target.id;
    end loop;
    update queue_private.sessions set ended_at = now() where id = sid;

    return;
  end if;
  select coalesce(max(position),0)+1 into pos from queue_private.entries where session_id = sid;
  if action = 'join' then
    if exists(select 1 from queue_private.entries where user_id = actor and session_id = sid) then raise exception 'Вы уже записаны'; end if;
    display_name := coalesce(trim(payload->>'name'),
      (select name from queue_private.profiles where user_id = actor),
      (select raw_user_meta_data->>'display_name' from auth.users where id = actor));
    chosen_lab := (payload->>'lab')::integer;
    guest := coalesce((payload->>'off_schedule')::boolean,false);
    if display_name is null or char_length(display_name) not between 2 and 60 then raise exception 'Укажите имя и фамилию: от 2 до 60 символов'; end if;
    if chosen_lab is null or chosen_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    insert into queue_private.profiles(user_id,name) values(actor,display_name) on conflict(user_id) do update set name = excluded.name;
    select coalesce(max(retries),0) into previous_retries from queue_private.results where session_id = sid and user_id = actor and lab = chosen_lab;
    select retries,source_session_id into pending_retries,pending_source from queue_private.pending_extras where user_id = actor and lab = chosen_lab and teacher_id = owner_id;
    select coalesce(bool_or(r.had_extra),false),coalesce(bool_or(r.carried_extra),false) into was_extra,was_carried
      from queue_private.results r where r.session_id = sid and r.user_id = actor and r.lab = chosen_lab;
    if pending_retries is not null then was_extra := true; was_carried := pending_source is distinct from sid; end if;
    select coalesce(max(r.extra_count),0) into extra_total from queue_private.results r
      join queue_private.sessions s on s.id=r.session_id
      where r.user_id=actor and r.lab=chosen_lab and s.created_by=owner_id;
    extra_total := greatest(extra_total,coalesce((select extra_count from queue_private.pending_extras where user_id=actor and lab=chosen_lab and teacher_id=owner_id),0));
    previous_retries := greatest(previous_retries,coalesce(pending_retries,0));
    insert into queue_private.entries(user_id,name,lab,status,priority,position,retries,off_schedule,session_id,had_extra,carried_extra,extra_count)
      values(actor,display_name,chosen_lab,case when pending_retries is not null then 'extra' else 'waiting' end,
        pending_retries is null and not guest and chosen_lab = active_lab and previous_retries = 0 and not was_extra,pos,previous_retries,guest,sid,was_extra,was_carried,extra_total);
  elsif action = 'leave' then
    select * into target from queue_private.entries where user_id = actor and session_id = sid;
    if target.id is not null then
      update queue_private.results set outcome = 'left',updated_at = now() where id = target.id;
      delete from queue_private.entries where id = target.id;
    end if;
  elsif action = 'ready' then
    select * into target from queue_private.entries where user_id = actor and session_id = sid and status = 'extra';
    if target.id is null then raise exception 'Вы не на доп. задании'; end if;
    delete from queue_private.pending_extras where user_id = actor and lab = target.lab and teacher_id = owner_id;
    update queue_private.entries set status = 'waiting',can_return_extra = true,ready = not target.carried_extra,priority = false,position = pos where id = target.id;
  elsif action = 'return_extra' then
    select * into target from queue_private.entries where user_id=actor and session_id=sid
      and can_return_extra and status in ('waiting','current','deferred');
    if target.id is null then raise exception 'Вернуться можно только после готовности к допзаданию'; end if;
    update queue_private.entries set status='extra',ready=false,priority=false,can_return_extra=false where id=target.id;
    insert into queue_private.pending_extras(user_id,lab,retries,teacher_id,source_session_id,extra_count)
      values(actor,target.lab,target.retries,owner_id,case when target.carried_extra then null else sid end,target.extra_count)
      on conflict(user_id,lab,teacher_id) do update set retries=excluded.retries,source_session_id=excluded.source_session_id,extra_count=excluded.extra_count;
  elsif action = 'set_lab' then
    chosen_lab := (payload->>'lab')::integer;
    if chosen_lab is null or chosen_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    update queue_private.sessions set lab = chosen_lab where id = sid;
  elsif action in ('next','pass','extra') then
    select * into target from queue_private.entries where session_id = sid and status = 'current';
    if target.id is distinct from (payload->>'current_id')::uuid then raise exception 'Очередь изменилась. Обновите страницу и повторите действие'; end if;
    if target.id is not null then
      if action = 'pass' then
        delete from queue_private.pending_extras where user_id = target.user_id and lab = target.lab and teacher_id = owner_id;
        update queue_private.results set outcome = 'passed',first_try_pass = (
          target.retries=0 and target.extra_count=0 and not target.had_extra and not exists(
            select 1 from queue_private.results prior join queue_private.sessions s on s.id=prior.session_id
            where prior.user_id=target.user_id and prior.lab=target.lab and s.created_by=owner_id and prior.id<>target.id
              and (prior.outcome in ('failed','passed') or prior.retries>0 or prior.had_extra)
          )),updated_at = now() where id = target.id;
        delete from queue_private.entries where id = target.id;
      else
        update queue_private.entries set can_return_extra=false,status = case when action = 'extra' then 'extra' else 'waiting' end,
          extra_count = extra_count + case when action = 'extra' then 1 else 0 end,
          had_extra = queue_private.entries.had_extra or action = 'extra',carried_extra = case when action = 'extra' then false else queue_private.entries.carried_extra end,
          retries = retries + case when action = 'next' then 1 else 0 end,ready = false,priority = false,position = pos where id = target.id;
      end if;
    end if;
  else raise exception 'Неизвестное действие';
  end if;

  if action = 'extra' and target.id is not null then
    insert into queue_private.pending_extras(user_id,lab,retries,teacher_id,source_session_id,extra_count) values(target.user_id,target.lab,target.retries,owner_id,sid,target.extra_count+1)
      on conflict(user_id,lab,teacher_id) do update set retries = excluded.retries,source_session_id = excluded.source_session_id,extra_count = excluded.extra_count;
  end if;

  -- Hold guests until scheduled students leave the active queue. Returned extras keep their priority. Never interrupt current.
  if exists(select 1 from queue_private.entries where session_id = sid and not off_schedule and status in ('current','waiting')) then
    update queue_private.entries set status = 'deferred'
      where session_id = sid and off_schedule and status = 'waiting' and not ready;
  else
    update queue_private.entries set status = 'waiting' where session_id = sid and status = 'deferred';
  end if;
  -- Keep ready extras first, then initial lab priority, then FIFO (including repeat turns).
  pos := 0;
  for target in select * from queue_private.entries where session_id = sid and status = 'waiting' order by
    case when ready then 0 else 1 end,
    case when not off_schedule and retries = 0 and priority then 0 else 1 end,position,id
  loop
    pos := pos + 1;
    update queue_private.entries set position = pos where id = target.id;
  end loop;
  if not exists(select 1 from queue_private.entries where session_id = sid and status = 'current') then
    update queue_private.entries set status = 'current' where id = (
      select id from queue_private.entries where session_id = sid and status = 'waiting' order by position limit 1
    );
  end if;
  insert into queue_private.results(id,session_id,name,lab,retries,outcome,user_id,off_schedule,had_extra,carried_extra,extra_count)
    select id,sid,name,lab,retries,status,user_id,off_schedule,had_extra,carried_extra,extra_count from queue_private.entries where session_id = sid
    on conflict(id) do update set retries = excluded.retries,outcome = excluded.outcome,off_schedule = excluded.off_schedule,had_extra = excluded.had_extra,carried_extra = excluded.carried_extra,extra_count = excluded.extra_count,updated_at = now();
end;
$$;





create or replace function public.queue_snapshot_for_session(target_session_id uuid default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  admin boolean;
  superadmin boolean;
  sid uuid := target_session_id;
  owner_id uuid;
  saved_name text;
  metadata jsonb;
begin
  if actor is null or not exists(select 1 from auth.users where id = actor and not coalesce(is_anonymous,false)) then
    raise exception 'Войдите в аккаунт по логину и паролю';
  end if;
  select exists(select 1 from queue_private.admins where user_id = actor) into admin;
  select exists(select 1 from queue_private.superadmins where user_id = actor) into superadmin;
  if sid is null and admin then
    select id into sid from queue_private.sessions where created_by = actor and ended_at is null order by created_at desc nulls last,id limit 1;
  end if;
  if sid is not null then
    if admin and not superadmin and exists(select 1 from queue_private.sessions where id = sid and created_by is distinct from actor) then
      raise exception 'Вы не можете просматривать сессию другого преподавателя';
    end if;
    select created_by into owner_id from queue_private.sessions where id = sid and ended_at is null;
    if not found then sid := null; end if;
  end if;
  select raw_user_meta_data into metadata from auth.users where id = actor;
  saved_name := coalesce(
    (select nullif(trim(name),'') from queue_private.profiles where user_id = actor),
    (select nullif(trim(name),'') from queue_private.entries where user_id = actor order by position,id limit 1),
    (select nullif(trim(name),'') from queue_private.results where user_id = actor order by updated_at desc,id limit 1),
    nullif(trim(metadata->>'display_name'),''),nullif(trim(metadata->>'full_name'),''),nullif(trim(metadata->>'name'),''),
    nullif(trim(concat_ws(' ',nullif(trim(metadata->>'first_name'),''),nullif(trim(metadata->>'last_name'),''))),'')
  );
  return jsonb_build_object(
    'admin',admin,'superadmin',superadmin,'profile_name',saved_name,
    'lab',coalesce((select lab from queue_private.sessions where id = sid),6),
    'session',(select to_jsonb(s) || jsonb_build_object('teacher_name',coalesce(p.name,'Преподаватель')) from queue_private.sessions s left join queue_private.profiles p on p.user_id = s.created_by where s.id = sid),
    'available_sessions',coalesce((select jsonb_agg(to_jsonb(s) || jsonb_build_object('teacher_name',coalesce(p.name,'Преподаватель')) order by s.created_at desc nulls last,s.id)
      from queue_private.sessions s left join queue_private.profiles p on p.user_id = s.created_by
      where s.ended_at is null and (not admin or superadmin or s.created_by = actor)),'[]'::jsonb),
    'sessions',case when admin then coalesce((select jsonb_agg(to_jsonb(s) || jsonb_build_object('teacher_name',coalesce(p.name,'Преподаватель')) order by coalesce(s.created_at,s.ended_at) desc nulls last,s.date desc,s.id)
      from queue_private.sessions s left join queue_private.profiles p on p.user_id = s.created_by where superadmin or s.created_by = actor),'[]'::jsonb) else '[]'::jsonb end,
    'results',case when admin then coalesce((select jsonb_agg(to_jsonb(r) order by r.updated_at,r.id)
      from queue_private.results r join queue_private.sessions s on s.id = r.session_id where superadmin or s.created_by = actor),'[]'::jsonb) else '[]'::jsonb end,
    'pending_extras',coalesce((select jsonb_agg(jsonb_build_object('lab',lab,'retries',retries) order by lab)
      from queue_private.pending_extras where user_id = actor and teacher_id = owner_id),'[]'::jsonb),
    'entries',coalesce((select jsonb_agg(jsonb_build_object(
      'id',id,'name',name,'lab',lab,'status',status,'priority',priority,'ready',ready,
      'position',position,'retries',retries,'mine',user_id = actor,'off_schedule',off_schedule,'had_extra',had_extra,'carried_extra',carried_extra,'extra_count',extra_count,'can_return_extra',can_return_extra) order by position,id)
      from queue_private.entries where session_id = sid),'[]'::jsonb)
  );
end;
$$;




revoke all on function public.queue_action(text,jsonb) from public,anon;
revoke all on function public.queue_snapshot_for_session(uuid) from public,anon;
grant execute on function public.queue_action(text,jsonb) to authenticated;
grant execute on function public.queue_snapshot_for_session(uuid) to authenticated;
commit;


-- Manual off-schedule admission.
-- Teacher admits off-schedule students one at a time when the active queue is empty.
begin;
create or replace function public.queue_action(action text,payload jsonb default '{}'::jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  sid uuid;
  active_lab integer;
  admin boolean;
  owner_id uuid;
  superadmin boolean;
  target queue_private.entries;
  display_name text;
  chosen_lab integer;
  guest boolean;
  previous_retries integer;
  pending_retries integer;
  pending_source uuid;
  extra_total integer;
  was_extra boolean;
  was_carried boolean;
  pos bigint;
  group_name text;
  new_date date;
begin
  if actor is null or not exists(select 1 from auth.users where id = actor and not coalesce(is_anonymous,false)) then
    raise exception 'Войдите в аккаунт по логину и паролю';
  end if;
  sid := (payload->>'session_id')::uuid;
  select exists(select 1 from queue_private.admins where user_id = actor) into admin;
  select exists(select 1 from queue_private.superadmins where user_id = actor) into superadmin;
  if action in ('create_session','end_session','next','pass','extra','admit_deferred','set_lab') and not admin then
    raise exception 'Доступ только преподавателю';
  end if;
  if action = 'create_session' then
    perform pg_advisory_xact_lock(hashtextextended(actor::text,0));
    if exists(select 1 from queue_private.sessions where created_by = actor and ended_at is null) then raise exception 'Сначала завершите текущую сессию'; end if;
    new_date := (payload->>'date')::date;
    group_name := trim(payload->>'group');
    if new_date is null or group_name is null or char_length(group_name) not between 1 and 60 then
      raise exception 'Укажите дату и группу (до 60 символов)';
    end if;
    insert into queue_private.sessions(date,"group",created_by) values(new_date,group_name,actor) returning id into sid;
    return;
  end if;
  if sid is null then raise exception 'Выберите сессию преподавателя или откройте QR-код'; end if;
  select created_by,lab into owner_id,active_lab from queue_private.sessions where id = sid and ended_at is null for update;
  if not found then raise exception 'Сессия изменилась или завершена. Обновите страницу'; end if;
  if admin and action in ('end_session','next','pass','extra','admit_deferred','set_lab') and owner_id is distinct from actor and not superadmin then
    raise exception 'Вы не можете управлять сессией другого преподавателя';
  end if;
  if action = 'end_session' then
    update queue_private.results set outcome = 'failed',updated_at = now()
      where session_id = sid and outcome in ('current','waiting','deferred');
    for target in select e.* from queue_private.entries e join queue_private.results r on r.id = e.id where r.session_id = sid loop
      delete from queue_private.entries where id = target.id;
    end loop;
    update queue_private.sessions set ended_at = now() where id = sid;

    return;
  end if;
  select coalesce(max(position),0)+1 into pos from queue_private.entries where session_id = sid;
  if action = 'join' then
    if exists(select 1 from queue_private.entries where user_id = actor and session_id = sid) then raise exception 'Вы уже записаны'; end if;
    display_name := coalesce(trim(payload->>'name'),
      (select name from queue_private.profiles where user_id = actor),
      (select raw_user_meta_data->>'display_name' from auth.users where id = actor));
    chosen_lab := (payload->>'lab')::integer;
    guest := coalesce((payload->>'off_schedule')::boolean,false);
    if display_name is null or char_length(display_name) not between 2 and 60 then raise exception 'Укажите имя и фамилию: от 2 до 60 символов'; end if;
    if chosen_lab is null or chosen_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    insert into queue_private.profiles(user_id,name) values(actor,display_name) on conflict(user_id) do update set name = excluded.name;
    select coalesce(max(retries),0) into previous_retries from queue_private.results where session_id = sid and user_id = actor and lab = chosen_lab;
    select retries,source_session_id into pending_retries,pending_source from queue_private.pending_extras where user_id = actor and lab = chosen_lab and teacher_id = owner_id;
    select coalesce(bool_or(r.had_extra),false),coalesce(bool_or(r.carried_extra),false) into was_extra,was_carried
      from queue_private.results r where r.session_id = sid and r.user_id = actor and r.lab = chosen_lab;
    if pending_retries is not null then was_extra := true; was_carried := pending_source is distinct from sid; end if;
    select coalesce(max(r.extra_count),0) into extra_total from queue_private.results r
      join queue_private.sessions s on s.id=r.session_id
      where r.user_id=actor and r.lab=chosen_lab and s.created_by=owner_id;
    extra_total := greatest(extra_total,coalesce((select extra_count from queue_private.pending_extras where user_id=actor and lab=chosen_lab and teacher_id=owner_id),0));
    previous_retries := greatest(previous_retries,coalesce(pending_retries,0));
    insert into queue_private.entries(user_id,name,lab,status,priority,position,retries,off_schedule,session_id,had_extra,carried_extra,extra_count)
      values(actor,display_name,chosen_lab,case when pending_retries is not null then 'extra' when guest then 'deferred' else 'waiting' end,
        pending_retries is null and not guest and chosen_lab = active_lab and previous_retries = 0 and not was_extra,pos,previous_retries,guest,sid,was_extra,was_carried,extra_total);
  elsif action = 'leave' then
    select * into target from queue_private.entries where user_id = actor and session_id = sid;
    if target.id is not null then
      update queue_private.results set outcome = 'left',updated_at = now() where id = target.id;
      delete from queue_private.entries where id = target.id;
    end if;
  elsif action = 'ready' then
    select * into target from queue_private.entries where user_id = actor and session_id = sid and status = 'extra';
    if target.id is null then raise exception 'Вы не на доп. задании'; end if;
    delete from queue_private.pending_extras where user_id = actor and lab = target.lab and teacher_id = owner_id;
    update queue_private.entries set status = 'waiting',can_return_extra = true,ready = not target.carried_extra,priority = false,position = pos where id = target.id;
  elsif action = 'return_extra' then
    select * into target from queue_private.entries where user_id=actor and session_id=sid
      and can_return_extra and status in ('waiting','current','deferred');
    if target.id is null then raise exception 'Вернуться можно только после готовности к допзаданию'; end if;
    update queue_private.entries set status='extra',ready=false,priority=false,can_return_extra=false where id=target.id;
    insert into queue_private.pending_extras(user_id,lab,retries,teacher_id,source_session_id,extra_count)
      values(actor,target.lab,target.retries,owner_id,case when target.carried_extra then null else sid end,target.extra_count)
      on conflict(user_id,lab,teacher_id) do update set retries=excluded.retries,source_session_id=excluded.source_session_id,extra_count=excluded.extra_count;
  elsif action = 'admit_deferred' then
    if exists(select 1 from queue_private.entries where session_id=sid and status in ('current','waiting')) then
      raise exception 'Сначала дождитесь освобождения очереди';
    end if;
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status='deferred';
    if target.id is null then raise exception 'Студент больше не ожидает допуска в этой сессии'; end if;
    update queue_private.entries set status='current',ready=false,priority=false where id=target.id;
  elsif action = 'set_lab' then
    chosen_lab := (payload->>'lab')::integer;
    if chosen_lab is null or chosen_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    update queue_private.sessions set lab = chosen_lab where id = sid;
  elsif action in ('next','pass','extra') then
    select * into target from queue_private.entries where session_id = sid and status = 'current';
    if target.id is distinct from (payload->>'current_id')::uuid then raise exception 'Очередь изменилась. Обновите страницу и повторите действие'; end if;
    if target.id is not null then
      if action = 'pass' then
        delete from queue_private.pending_extras where user_id = target.user_id and lab = target.lab and teacher_id = owner_id;
        update queue_private.results set outcome = 'passed',first_try_pass = (
          target.retries=0 and target.extra_count=0 and not target.had_extra and not exists(
            select 1 from queue_private.results prior join queue_private.sessions s on s.id=prior.session_id
            where prior.user_id=target.user_id and prior.lab=target.lab and s.created_by=owner_id and prior.id<>target.id
              and (prior.outcome in ('failed','passed') or prior.retries>0 or prior.had_extra)
          )),updated_at = now() where id = target.id;
        delete from queue_private.entries where id = target.id;
      else
        update queue_private.entries set can_return_extra=false,status = case when action = 'extra' then 'extra' else 'waiting' end,
          extra_count = extra_count + case when action = 'extra' then 1 else 0 end,
          had_extra = queue_private.entries.had_extra or action = 'extra',carried_extra = case when action = 'extra' then false else queue_private.entries.carried_extra end,
          retries = retries + case when action = 'next' then 1 else 0 end,ready = false,priority = false,position = pos where id = target.id;
      end if;
    end if;
  else raise exception 'Неизвестное действие';
  end if;

  if action = 'extra' and target.id is not null then
    insert into queue_private.pending_extras(user_id,lab,retries,teacher_id,source_session_id,extra_count) values(target.user_id,target.lab,target.retries,owner_id,sid,target.extra_count+1)
      on conflict(user_id,lab,teacher_id) do update set retries = excluded.retries,source_session_id = excluded.source_session_id,extra_count = excluded.extra_count;
  end if;

  -- Hold guests until scheduled students leave the active queue. Returned extras keep their priority. Never interrupt current.
  if exists(select 1 from queue_private.entries where session_id = sid and not off_schedule and status in ('current','waiting')) then
    update queue_private.entries set status = 'deferred'
      where session_id = sid and off_schedule and status = 'waiting' and not ready;
  end if;
  -- Keep ready extras first, then initial lab priority, then FIFO (including repeat turns).
  pos := 0;
  for target in select * from queue_private.entries where session_id = sid and status = 'waiting' order by
    case when ready then 0 else 1 end,
    case when not off_schedule and retries = 0 and priority then 0 else 1 end,position,id
  loop
    pos := pos + 1;
    update queue_private.entries set position = pos where id = target.id;
  end loop;
  if not exists(select 1 from queue_private.entries where session_id = sid and status = 'current') then
    update queue_private.entries set status = 'current' where id = (
      select id from queue_private.entries where session_id = sid and status = 'waiting' order by position limit 1
    );
  end if;
  insert into queue_private.results(id,session_id,name,lab,retries,outcome,user_id,off_schedule,had_extra,carried_extra,extra_count)
    select id,sid,name,lab,retries,status,user_id,off_schedule,had_extra,carried_extra,extra_count from queue_private.entries where session_id = sid
    on conflict(id) do update set retries = excluded.retries,outcome = excluded.outcome,off_schedule = excluded.off_schedule,had_extra = excluded.had_extra,carried_extra = excluded.carried_extra,extra_count = excluded.extra_count,updated_at = now();
end;
$$;






revoke all on function public.queue_action(text,jsonb) from public,anon;
grant execute on function public.queue_action(text,jsonb) to authenticated;
commit;


-- Admit one student after the current turn.
-- Allow one student to wait after the current student; never interrupt the current turn.
begin;
alter table queue_private.entries add column if not exists manually_admitted boolean not null default false;
create or replace function public.queue_action(action text,payload jsonb default '{}'::jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  sid uuid;
  active_lab integer;
  admin boolean;
  owner_id uuid;
  superadmin boolean;
  target queue_private.entries;
  display_name text;
  chosen_lab integer;
  guest boolean;
  previous_retries integer;
  pending_retries integer;
  pending_source uuid;
  extra_total integer;
  was_extra boolean;
  was_carried boolean;
  pos bigint;
  group_name text;
  new_date date;
begin
  if actor is null or not exists(select 1 from auth.users where id = actor and not coalesce(is_anonymous,false)) then
    raise exception 'Войдите в аккаунт по логину и паролю';
  end if;
  sid := (payload->>'session_id')::uuid;
  select exists(select 1 from queue_private.admins where user_id = actor) into admin;
  select exists(select 1 from queue_private.superadmins where user_id = actor) into superadmin;
  if action in ('create_session','end_session','next','pass','extra','admit_deferred','set_lab') and not admin then
    raise exception 'Доступ только преподавателю';
  end if;
  if action = 'create_session' then
    perform pg_advisory_xact_lock(hashtextextended(actor::text,0));
    if exists(select 1 from queue_private.sessions where created_by = actor and ended_at is null) then raise exception 'Сначала завершите текущую сессию'; end if;
    new_date := (payload->>'date')::date;
    group_name := trim(payload->>'group');
    if new_date is null or group_name is null or char_length(group_name) not between 1 and 60 then
      raise exception 'Укажите дату и группу (до 60 символов)';
    end if;
    insert into queue_private.sessions(date,"group",created_by) values(new_date,group_name,actor) returning id into sid;
    return;
  end if;
  if sid is null then raise exception 'Выберите сессию преподавателя или откройте QR-код'; end if;
  select created_by,lab into owner_id,active_lab from queue_private.sessions where id = sid and ended_at is null for update;
  if not found then raise exception 'Сессия изменилась или завершена. Обновите страницу'; end if;
  if admin and action in ('end_session','next','pass','extra','admit_deferred','set_lab') and owner_id is distinct from actor and not superadmin then
    raise exception 'Вы не можете управлять сессией другого преподавателя';
  end if;
  if action = 'end_session' then
    update queue_private.results set outcome = 'failed',updated_at = now()
      where session_id = sid and outcome in ('current','waiting','deferred');
    for target in select e.* from queue_private.entries e join queue_private.results r on r.id = e.id where r.session_id = sid loop
      delete from queue_private.entries where id = target.id;
    end loop;
    update queue_private.sessions set ended_at = now() where id = sid;

    return;
  end if;
  select coalesce(max(position),0)+1 into pos from queue_private.entries where session_id = sid;
  if action = 'join' then
    if exists(select 1 from queue_private.entries where user_id = actor and session_id = sid) then raise exception 'Вы уже записаны'; end if;
    display_name := coalesce(trim(payload->>'name'),
      (select name from queue_private.profiles where user_id = actor),
      (select raw_user_meta_data->>'display_name' from auth.users where id = actor));
    chosen_lab := (payload->>'lab')::integer;
    guest := coalesce((payload->>'off_schedule')::boolean,false);
    if display_name is null or char_length(display_name) not between 2 and 60 then raise exception 'Укажите имя и фамилию: от 2 до 60 символов'; end if;
    if chosen_lab is null or chosen_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    insert into queue_private.profiles(user_id,name) values(actor,display_name) on conflict(user_id) do update set name = excluded.name;
    select coalesce(max(retries),0) into previous_retries from queue_private.results where session_id = sid and user_id = actor and lab = chosen_lab;
    select retries,source_session_id into pending_retries,pending_source from queue_private.pending_extras where user_id = actor and lab = chosen_lab and teacher_id = owner_id;
    select coalesce(bool_or(r.had_extra),false),coalesce(bool_or(r.carried_extra),false) into was_extra,was_carried
      from queue_private.results r where r.session_id = sid and r.user_id = actor and r.lab = chosen_lab;
    if pending_retries is not null then was_extra := true; was_carried := pending_source is distinct from sid; end if;
    select coalesce(max(r.extra_count),0) into extra_total from queue_private.results r
      join queue_private.sessions s on s.id=r.session_id
      where r.user_id=actor and r.lab=chosen_lab and s.created_by=owner_id;
    extra_total := greatest(extra_total,coalesce((select extra_count from queue_private.pending_extras where user_id=actor and lab=chosen_lab and teacher_id=owner_id),0));
    previous_retries := greatest(previous_retries,coalesce(pending_retries,0));
    insert into queue_private.entries(user_id,name,lab,status,priority,position,retries,off_schedule,session_id,had_extra,carried_extra,extra_count)
      values(actor,display_name,chosen_lab,case when pending_retries is not null then 'extra' when guest then 'deferred' else 'waiting' end,
        pending_retries is null and not guest and chosen_lab = active_lab and previous_retries = 0 and not was_extra,pos,previous_retries,guest,sid,was_extra,was_carried,extra_total);
  elsif action = 'leave' then
    select * into target from queue_private.entries where user_id = actor and session_id = sid;
    if target.id is not null then
      update queue_private.results set outcome = 'left',updated_at = now() where id = target.id;
      delete from queue_private.entries where id = target.id;
    end if;
  elsif action = 'ready' then
    select * into target from queue_private.entries where user_id = actor and session_id = sid and status = 'extra';
    if target.id is null then raise exception 'Вы не на доп. задании'; end if;
    delete from queue_private.pending_extras where user_id = actor and lab = target.lab and teacher_id = owner_id;
    update queue_private.entries set status = 'waiting',can_return_extra = true,ready = not target.carried_extra,priority = false,position = pos where id = target.id;
  elsif action = 'return_extra' then
    select * into target from queue_private.entries where user_id=actor and session_id=sid
      and can_return_extra and status in ('waiting','current','deferred');
    if target.id is null then raise exception 'Вернуться можно только после готовности к допзаданию'; end if;
    update queue_private.entries set status='extra',ready=false,priority=false,can_return_extra=false where id=target.id;
    insert into queue_private.pending_extras(user_id,lab,retries,teacher_id,source_session_id,extra_count)
      values(actor,target.lab,target.retries,owner_id,case when target.carried_extra then null else sid end,target.extra_count)
      on conflict(user_id,lab,teacher_id) do update set retries=excluded.retries,source_session_id=excluded.source_session_id,extra_count=excluded.extra_count;
  elsif action = 'admit_deferred' then
    if exists(select 1 from queue_private.entries where session_id=sid and status='waiting') then
      raise exception 'Сначала дождитесь освобождения очереди';
    end if;
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status='deferred';
    if target.id is null then raise exception 'Студент больше не ожидает допуска в этой сессии'; end if;
    update queue_private.entries set status='waiting',manually_admitted=true,ready=false,priority=false,position=pos where id=target.id;
  elsif action = 'set_lab' then
    chosen_lab := (payload->>'lab')::integer;
    if chosen_lab is null or chosen_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    update queue_private.sessions set lab = chosen_lab where id = sid;
  elsif action in ('next','pass','extra') then
    select * into target from queue_private.entries where session_id = sid and status = 'current';
    if target.id is distinct from (payload->>'current_id')::uuid then raise exception 'Очередь изменилась. Обновите страницу и повторите действие'; end if;
    if target.id is not null then
      if action = 'pass' then
        delete from queue_private.pending_extras where user_id = target.user_id and lab = target.lab and teacher_id = owner_id;
        update queue_private.results set outcome = 'passed',first_try_pass = (
          target.retries=0 and target.extra_count=0 and not target.had_extra and not exists(
            select 1 from queue_private.results prior join queue_private.sessions s on s.id=prior.session_id
            where prior.user_id=target.user_id and prior.lab=target.lab and s.created_by=owner_id and prior.id<>target.id
              and (prior.outcome in ('failed','passed') or prior.retries>0 or prior.had_extra)
          )),updated_at = now() where id = target.id;
        delete from queue_private.entries where id = target.id;
      else
        update queue_private.entries set manually_admitted=false,can_return_extra=false,status = case when action = 'extra' then 'extra' else 'waiting' end,
          extra_count = extra_count + case when action = 'extra' then 1 else 0 end,
          had_extra = queue_private.entries.had_extra or action = 'extra',carried_extra = case when action = 'extra' then false else queue_private.entries.carried_extra end,
          retries = retries + case when action = 'next' then 1 else 0 end,ready = false,priority = false,position = pos where id = target.id;
      end if;
    end if;
  else raise exception 'Неизвестное действие';
  end if;

  if action = 'extra' and target.id is not null then
    insert into queue_private.pending_extras(user_id,lab,retries,teacher_id,source_session_id,extra_count) values(target.user_id,target.lab,target.retries,owner_id,sid,target.extra_count+1)
      on conflict(user_id,lab,teacher_id) do update set retries = excluded.retries,source_session_id = excluded.source_session_id,extra_count = excluded.extra_count;
  end if;

  -- Hold guests until scheduled students leave the active queue. Returned extras keep their priority. Never interrupt current.
  if exists(select 1 from queue_private.entries where session_id = sid and not off_schedule and status in ('current','waiting')) then
    update queue_private.entries set status = 'deferred'
      where session_id = sid and off_schedule and status = 'waiting' and not ready and not manually_admitted;
  end if;
  -- Keep ready extras first, then initial lab priority, then FIFO (including repeat turns).
  pos := 0;
  for target in select * from queue_private.entries where session_id = sid and status = 'waiting' order by
    case when ready then 0 else 1 end,
    case when not off_schedule and retries = 0 and priority then 0 else 1 end,position,id
  loop
    pos := pos + 1;
    update queue_private.entries set position = pos where id = target.id;
  end loop;
  if not exists(select 1 from queue_private.entries where session_id = sid and status = 'current') then
    update queue_private.entries set status = 'current' where id = (
      select id from queue_private.entries where session_id = sid and status = 'waiting' order by position limit 1
    );
  end if;
  insert into queue_private.results(id,session_id,name,lab,retries,outcome,user_id,off_schedule,had_extra,carried_extra,extra_count)
    select id,sid,name,lab,retries,status,user_id,off_schedule,had_extra,carried_extra,extra_count from queue_private.entries where session_id = sid
    on conflict(id) do update set retries = excluded.retries,outcome = excluded.outcome,off_schedule = excluded.off_schedule,had_extra = excluded.had_extra,carried_extra = excluded.carried_extra,extra_count = excluded.extra_count,updated_at = now();
end;
$$;







revoke all on function public.queue_action(text,jsonb) from public,anon;
grant execute on function public.queue_action(text,jsonb) to authenticated;
commit;


-- Park unready students outside the active queue.
-- Teacher can park unready students outside the active queue without adding retries or medals.
begin;
alter table queue_private.entries drop constraint if exists entries_status_check;
alter table queue_private.entries add constraint entries_status_check check(status in ('current','waiting','extra','deferred','paused'));
create or replace function public.queue_action(action text,payload jsonb default '{}'::jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  sid uuid;
  active_lab integer;
  admin boolean;
  owner_id uuid;
  superadmin boolean;
  target queue_private.entries;
  display_name text;
  chosen_lab integer;
  guest boolean;
  previous_retries integer;
  pending_retries integer;
  pending_source uuid;
  extra_total integer;
  was_extra boolean;
  was_carried boolean;
  pos bigint;
  group_name text;
  new_date date;
begin
  if actor is null or not exists(select 1 from auth.users where id = actor and not coalesce(is_anonymous,false)) then
    raise exception 'Войдите в аккаунт по логину и паролю';
  end if;
  sid := (payload->>'session_id')::uuid;
  select exists(select 1 from queue_private.admins where user_id = actor) into admin;
  select exists(select 1 from queue_private.superadmins where user_id = actor) into superadmin;
  if action in ('create_session','end_session','next','pass','extra','admit_deferred','pause_entry','pause_waiting','resume_entry','set_lab') and not admin then
    raise exception 'Доступ только преподавателю';
  end if;
  if action = 'create_session' then
    perform pg_advisory_xact_lock(hashtextextended(actor::text,0));
    if exists(select 1 from queue_private.sessions where created_by = actor and ended_at is null) then raise exception 'Сначала завершите текущую сессию'; end if;
    new_date := (payload->>'date')::date;
    group_name := trim(payload->>'group');
    if new_date is null or group_name is null or char_length(group_name) not between 1 and 60 then
      raise exception 'Укажите дату и группу (до 60 символов)';
    end if;
    insert into queue_private.sessions(date,"group",created_by) values(new_date,group_name,actor) returning id into sid;
    return;
  end if;
  if sid is null then raise exception 'Выберите сессию преподавателя или откройте QR-код'; end if;
  select created_by,lab into owner_id,active_lab from queue_private.sessions where id = sid and ended_at is null for update;
  if not found then raise exception 'Сессия изменилась или завершена. Обновите страницу'; end if;
  if admin and action in ('end_session','next','pass','extra','admit_deferred','pause_entry','pause_waiting','resume_entry','set_lab') and owner_id is distinct from actor and not superadmin then
    raise exception 'Вы не можете управлять сессией другого преподавателя';
  end if;
  if action = 'end_session' then
    update queue_private.results set outcome = 'failed',updated_at = now()
      where session_id = sid and outcome in ('current','waiting','deferred','paused');
    for target in select e.* from queue_private.entries e join queue_private.results r on r.id = e.id where r.session_id = sid loop
      delete from queue_private.entries where id = target.id;
    end loop;
    update queue_private.sessions set ended_at = now() where id = sid;

    return;
  end if;
  select coalesce(max(position),0)+1 into pos from queue_private.entries where session_id = sid;
  if action = 'join' then
    if exists(select 1 from queue_private.entries where user_id = actor and session_id = sid) then raise exception 'Вы уже записаны'; end if;
    display_name := coalesce(trim(payload->>'name'),
      (select name from queue_private.profiles where user_id = actor),
      (select raw_user_meta_data->>'display_name' from auth.users where id = actor));
    chosen_lab := (payload->>'lab')::integer;
    guest := coalesce((payload->>'off_schedule')::boolean,false);
    if display_name is null or char_length(display_name) not between 2 and 60 then raise exception 'Укажите имя и фамилию: от 2 до 60 символов'; end if;
    if chosen_lab is null or chosen_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    insert into queue_private.profiles(user_id,name) values(actor,display_name) on conflict(user_id) do update set name = excluded.name;
    select coalesce(max(retries),0) into previous_retries from queue_private.results where session_id = sid and user_id = actor and lab = chosen_lab;
    select retries,source_session_id into pending_retries,pending_source from queue_private.pending_extras where user_id = actor and lab = chosen_lab and teacher_id = owner_id;
    select coalesce(bool_or(r.had_extra),false),coalesce(bool_or(r.carried_extra),false) into was_extra,was_carried
      from queue_private.results r where r.session_id = sid and r.user_id = actor and r.lab = chosen_lab;
    if pending_retries is not null then was_extra := true; was_carried := pending_source is distinct from sid; end if;
    select coalesce(max(r.extra_count),0) into extra_total from queue_private.results r
      join queue_private.sessions s on s.id=r.session_id
      where r.user_id=actor and r.lab=chosen_lab and s.created_by=owner_id;
    extra_total := greatest(extra_total,coalesce((select extra_count from queue_private.pending_extras where user_id=actor and lab=chosen_lab and teacher_id=owner_id),0));
    previous_retries := greatest(previous_retries,coalesce(pending_retries,0));
    insert into queue_private.entries(user_id,name,lab,status,priority,position,retries,off_schedule,session_id,had_extra,carried_extra,extra_count)
      values(actor,display_name,chosen_lab,case when pending_retries is not null then 'extra' when guest then 'deferred' else 'waiting' end,
        pending_retries is null and not guest and chosen_lab = active_lab and previous_retries = 0 and not was_extra,pos,previous_retries,guest,sid,was_extra,was_carried,extra_total);
  elsif action = 'leave' then
    select * into target from queue_private.entries where user_id = actor and session_id = sid;
    if target.id is not null then
      update queue_private.results set outcome = 'left',updated_at = now() where id = target.id;
      delete from queue_private.entries where id = target.id;
    end if;
  elsif action = 'ready' then
    select * into target from queue_private.entries where user_id = actor and session_id = sid and status = 'extra';
    if target.id is null then raise exception 'Вы не на доп. задании'; end if;
    delete from queue_private.pending_extras where user_id = actor and lab = target.lab and teacher_id = owner_id;
    update queue_private.entries set status = 'waiting',can_return_extra = true,ready = not target.carried_extra,priority = false,position = pos where id = target.id;
  elsif action = 'return_extra' then
    select * into target from queue_private.entries where user_id=actor and session_id=sid
      and can_return_extra and status in ('waiting','current','deferred','paused');
    if target.id is null then raise exception 'Вернуться можно только после готовности к допзаданию'; end if;
    update queue_private.entries set status='extra',ready=false,priority=false,can_return_extra=false where id=target.id;
    insert into queue_private.pending_extras(user_id,lab,retries,teacher_id,source_session_id,extra_count)
      values(actor,target.lab,target.retries,owner_id,case when target.carried_extra then null else sid end,target.extra_count)
      on conflict(user_id,lab,teacher_id) do update set retries=excluded.retries,source_session_id=excluded.source_session_id,extra_count=excluded.extra_count;
  elsif action = 'pause_entry' then
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status in ('current','waiting');
    if target.id is null then raise exception 'Студент больше не находится в очереди'; end if;
    update queue_private.entries set status='paused',ready=false,priority=false,manually_admitted=false,position=pos where id=target.id;
  elsif action = 'pause_waiting' then
    update queue_private.entries set status='paused',ready=false,priority=false,manually_admitted=false where session_id=sid and status='waiting';
  elsif action = 'resume_entry' then
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status='paused';
    if target.id is null then raise exception 'Студент больше не находится в ожидании'; end if;
    update queue_private.entries set status='waiting',ready=false,priority=false,manually_admitted=true,position=pos where id=target.id;
  elsif action = 'admit_deferred' then
    if exists(select 1 from queue_private.entries where session_id=sid and status='waiting') then
      raise exception 'Сначала дождитесь освобождения очереди';
    end if;
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status='deferred';
    if target.id is null then raise exception 'Студент больше не ожидает допуска в этой сессии'; end if;
    update queue_private.entries set status='waiting',manually_admitted=true,ready=false,priority=false,position=pos where id=target.id;
  elsif action = 'set_lab' then
    chosen_lab := (payload->>'lab')::integer;
    if chosen_lab is null or chosen_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    update queue_private.sessions set lab = chosen_lab where id = sid;
  elsif action in ('next','pass','extra') then
    select * into target from queue_private.entries where session_id = sid and status = 'current';
    if target.id is distinct from (payload->>'current_id')::uuid then raise exception 'Очередь изменилась. Обновите страницу и повторите действие'; end if;
    if target.id is not null then
      if action = 'pass' then
        delete from queue_private.pending_extras where user_id = target.user_id and lab = target.lab and teacher_id = owner_id;
        update queue_private.results set outcome = 'passed',first_try_pass = (
          target.retries=0 and target.extra_count=0 and not target.had_extra and not exists(
            select 1 from queue_private.results prior join queue_private.sessions s on s.id=prior.session_id
            where prior.user_id=target.user_id and prior.lab=target.lab and s.created_by=owner_id and prior.id<>target.id
              and (prior.outcome in ('failed','passed') or prior.retries>0 or prior.had_extra)
          )),updated_at = now() where id = target.id;
        delete from queue_private.entries where id = target.id;
      else
        update queue_private.entries set manually_admitted=false,can_return_extra=false,status = case when action = 'extra' then 'extra' else 'waiting' end,
          extra_count = extra_count + case when action = 'extra' then 1 else 0 end,
          had_extra = queue_private.entries.had_extra or action = 'extra',carried_extra = case when action = 'extra' then false else queue_private.entries.carried_extra end,
          retries = retries + case when action = 'next' then 1 else 0 end,ready = false,priority = false,position = pos where id = target.id;
      end if;
    end if;
  else raise exception 'Неизвестное действие';
  end if;

  if action = 'extra' and target.id is not null then
    insert into queue_private.pending_extras(user_id,lab,retries,teacher_id,source_session_id,extra_count) values(target.user_id,target.lab,target.retries,owner_id,sid,target.extra_count+1)
      on conflict(user_id,lab,teacher_id) do update set retries = excluded.retries,source_session_id = excluded.source_session_id,extra_count = excluded.extra_count;
  end if;

  -- Hold guests until scheduled students leave the active queue. Returned extras keep their priority. Never interrupt current.
  if exists(select 1 from queue_private.entries where session_id = sid and not off_schedule and status in ('current','waiting')) then
    update queue_private.entries set status = 'deferred'
      where session_id = sid and off_schedule and status = 'waiting' and not ready and not manually_admitted;
  end if;
  -- Keep ready extras first, then initial lab priority, then FIFO (including repeat turns).
  pos := 0;
  for target in select * from queue_private.entries where session_id = sid and status = 'waiting' order by
    case when ready then 0 else 1 end,
    case when not off_schedule and retries = 0 and priority then 0 else 1 end,position,id
  loop
    pos := pos + 1;
    update queue_private.entries set position = pos where id = target.id;
  end loop;
  if not exists(select 1 from queue_private.entries where session_id = sid and status = 'current') then
    update queue_private.entries set status = 'current' where id = (
      select id from queue_private.entries where session_id = sid and status = 'waiting' order by position limit 1
    );
  end if;
  insert into queue_private.results(id,session_id,name,lab,retries,outcome,user_id,off_schedule,had_extra,carried_extra,extra_count)
    select id,sid,name,lab,retries,status,user_id,off_schedule,had_extra,carried_extra,extra_count from queue_private.entries where session_id = sid
    on conflict(id) do update set retries = excluded.retries,outcome = excluded.outcome,off_schedule = excluded.off_schedule,had_extra = excluded.had_extra,carried_extra = excluded.carried_extra,extra_count = excluded.extra_count,updated_at = now();
end;
$$;








revoke all on function public.queue_action(text,jsonb) from public,anon;
grant execute on function public.queue_action(text,jsonb) to authenticated;
commit;


-- Auto-call one off-schedule student into an empty queue.
-- Automatically call one off-schedule student only when the active queue is completely empty.
begin;
create or replace function queue_private.promote_available(sid uuid) returns void
language plpgsql set search_path = '' as $$
begin
  perform 1 from queue_private.sessions where id=sid and ended_at is null for update;
  if not found then return; end if;
  if exists(select 1 from queue_private.entries where session_id=sid and status='current') then return; end if;
  if not exists(select 1 from queue_private.entries where session_id=sid and status='waiting') then
    update queue_private.entries set status='waiting',manually_admitted=true,ready=false,priority=false where id=(
      select id from queue_private.entries where session_id=sid and status='deferred' order by position,id limit 1
    );
  end if;
  update queue_private.entries set status='current' where id=(
    select id from queue_private.entries where session_id=sid and status='waiting' order by position,id limit 1
  );
end;
$$;
revoke all on function queue_private.promote_available(uuid) from public,anon,authenticated,service_role;
create or replace function public.queue_action(action text,payload jsonb default '{}'::jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  sid uuid;
  active_lab integer;
  admin boolean;
  owner_id uuid;
  superadmin boolean;
  target queue_private.entries;
  display_name text;
  chosen_lab integer;
  guest boolean;
  previous_retries integer;
  pending_retries integer;
  pending_source uuid;
  extra_total integer;
  was_extra boolean;
  was_carried boolean;
  pos bigint;
  group_name text;
  new_date date;
begin
  if actor is null or not exists(select 1 from auth.users where id = actor and not coalesce(is_anonymous,false)) then
    raise exception 'Войдите в аккаунт по логину и паролю';
  end if;
  sid := (payload->>'session_id')::uuid;
  select exists(select 1 from queue_private.admins where user_id = actor) into admin;
  select exists(select 1 from queue_private.superadmins where user_id = actor) into superadmin;
  if action in ('create_session','end_session','next','pass','extra','admit_deferred','pause_entry','pause_waiting','resume_entry','set_lab') and not admin then
    raise exception 'Доступ только преподавателю';
  end if;
  if action = 'create_session' then
    perform pg_advisory_xact_lock(hashtextextended(actor::text,0));
    if exists(select 1 from queue_private.sessions where created_by = actor and ended_at is null) then raise exception 'Сначала завершите текущую сессию'; end if;
    new_date := (payload->>'date')::date;
    group_name := trim(payload->>'group');
    if new_date is null or group_name is null or char_length(group_name) not between 1 and 60 then
      raise exception 'Укажите дату и группу (до 60 символов)';
    end if;
    insert into queue_private.sessions(date,"group",created_by) values(new_date,group_name,actor) returning id into sid;
    return;
  end if;
  if sid is null then raise exception 'Выберите сессию преподавателя или откройте QR-код'; end if;
  select created_by,lab into owner_id,active_lab from queue_private.sessions where id = sid and ended_at is null for update;
  if not found then raise exception 'Сессия изменилась или завершена. Обновите страницу'; end if;
  if admin and action in ('end_session','next','pass','extra','admit_deferred','pause_entry','pause_waiting','resume_entry','set_lab') and owner_id is distinct from actor and not superadmin then
    raise exception 'Вы не можете управлять сессией другого преподавателя';
  end if;
  if action = 'end_session' then
    update queue_private.results set outcome = 'failed',updated_at = now()
      where session_id = sid and outcome in ('current','waiting','deferred','paused');
    for target in select e.* from queue_private.entries e join queue_private.results r on r.id = e.id where r.session_id = sid loop
      delete from queue_private.entries where id = target.id;
    end loop;
    update queue_private.sessions set ended_at = now() where id = sid;

    return;
  end if;
  select coalesce(max(position),0)+1 into pos from queue_private.entries where session_id = sid;
  if action = 'join' then
    if exists(select 1 from queue_private.entries where user_id = actor and session_id = sid) then raise exception 'Вы уже записаны'; end if;
    display_name := coalesce(trim(payload->>'name'),
      (select name from queue_private.profiles where user_id = actor),
      (select raw_user_meta_data->>'display_name' from auth.users where id = actor));
    chosen_lab := (payload->>'lab')::integer;
    guest := coalesce((payload->>'off_schedule')::boolean,false);
    if display_name is null or char_length(display_name) not between 2 and 60 then raise exception 'Укажите имя и фамилию: от 2 до 60 символов'; end if;
    if chosen_lab is null or chosen_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    insert into queue_private.profiles(user_id,name) values(actor,display_name) on conflict(user_id) do update set name = excluded.name;
    select coalesce(max(retries),0) into previous_retries from queue_private.results where session_id = sid and user_id = actor and lab = chosen_lab;
    select retries,source_session_id into pending_retries,pending_source from queue_private.pending_extras where user_id = actor and lab = chosen_lab and teacher_id = owner_id;
    select coalesce(bool_or(r.had_extra),false),coalesce(bool_or(r.carried_extra),false) into was_extra,was_carried
      from queue_private.results r where r.session_id = sid and r.user_id = actor and r.lab = chosen_lab;
    if pending_retries is not null then was_extra := true; was_carried := pending_source is distinct from sid; end if;
    select coalesce(max(r.extra_count),0) into extra_total from queue_private.results r
      join queue_private.sessions s on s.id=r.session_id
      where r.user_id=actor and r.lab=chosen_lab and s.created_by=owner_id;
    extra_total := greatest(extra_total,coalesce((select extra_count from queue_private.pending_extras where user_id=actor and lab=chosen_lab and teacher_id=owner_id),0));
    previous_retries := greatest(previous_retries,coalesce(pending_retries,0));
    insert into queue_private.entries(user_id,name,lab,status,priority,position,retries,off_schedule,session_id,had_extra,carried_extra,extra_count)
      values(actor,display_name,chosen_lab,case when pending_retries is not null then 'extra' when guest then 'deferred' else 'waiting' end,
        pending_retries is null and not guest and chosen_lab = active_lab and previous_retries = 0 and not was_extra,pos,previous_retries,guest,sid,was_extra,was_carried,extra_total);
  elsif action = 'leave' then
    select * into target from queue_private.entries where user_id = actor and session_id = sid;
    if target.id is not null then
      update queue_private.results set outcome = 'left',updated_at = now() where id = target.id;
      delete from queue_private.entries where id = target.id;
    end if;
  elsif action = 'ready' then
    select * into target from queue_private.entries where user_id = actor and session_id = sid and status = 'extra';
    if target.id is null then raise exception 'Вы не на доп. задании'; end if;
    delete from queue_private.pending_extras where user_id = actor and lab = target.lab and teacher_id = owner_id;
    update queue_private.entries set status = 'waiting',can_return_extra = true,ready = not target.carried_extra,priority = false,position = pos where id = target.id;
  elsif action = 'return_extra' then
    select * into target from queue_private.entries where user_id=actor and session_id=sid
      and can_return_extra and status in ('waiting','current','deferred','paused');
    if target.id is null then raise exception 'Вернуться можно только после готовности к допзаданию'; end if;
    update queue_private.entries set status='extra',ready=false,priority=false,can_return_extra=false where id=target.id;
    insert into queue_private.pending_extras(user_id,lab,retries,teacher_id,source_session_id,extra_count)
      values(actor,target.lab,target.retries,owner_id,case when target.carried_extra then null else sid end,target.extra_count)
      on conflict(user_id,lab,teacher_id) do update set retries=excluded.retries,source_session_id=excluded.source_session_id,extra_count=excluded.extra_count;
  elsif action = 'pause_entry' then
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status in ('current','waiting');
    if target.id is null then raise exception 'Студент больше не находится в очереди'; end if;
    update queue_private.entries set status='paused',ready=false,priority=false,manually_admitted=false,position=pos where id=target.id;
  elsif action = 'pause_waiting' then
    update queue_private.entries set status='paused',ready=false,priority=false,manually_admitted=false where session_id=sid and status='waiting';
  elsif action = 'resume_entry' then
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status='paused';
    if target.id is null then raise exception 'Студент больше не находится в ожидании'; end if;
    update queue_private.entries set status='waiting',ready=false,priority=false,manually_admitted=true,position=pos where id=target.id;
  elsif action = 'admit_deferred' then
    if exists(select 1 from queue_private.entries where session_id=sid and status='waiting') then
      raise exception 'Сначала дождитесь освобождения очереди';
    end if;
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status='deferred';
    if target.id is null then raise exception 'Студент больше не ожидает допуска в этой сессии'; end if;
    update queue_private.entries set status='waiting',manually_admitted=true,ready=false,priority=false,position=pos where id=target.id;
  elsif action = 'set_lab' then
    chosen_lab := (payload->>'lab')::integer;
    if chosen_lab is null or chosen_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    update queue_private.sessions set lab = chosen_lab where id = sid;
  elsif action in ('next','pass','extra') then
    select * into target from queue_private.entries where session_id = sid and status = 'current';
    if target.id is distinct from (payload->>'current_id')::uuid then raise exception 'Очередь изменилась. Обновите страницу и повторите действие'; end if;
    if target.id is not null then
      if action = 'pass' then
        delete from queue_private.pending_extras where user_id = target.user_id and lab = target.lab and teacher_id = owner_id;
        update queue_private.results set outcome = 'passed',first_try_pass = (
          target.retries=0 and target.extra_count=0 and not target.had_extra and not exists(
            select 1 from queue_private.results prior join queue_private.sessions s on s.id=prior.session_id
            where prior.user_id=target.user_id and prior.lab=target.lab and s.created_by=owner_id and prior.id<>target.id
              and (prior.outcome in ('failed','passed') or prior.retries>0 or prior.had_extra)
          )),updated_at = now() where id = target.id;
        delete from queue_private.entries where id = target.id;
      else
        update queue_private.entries set manually_admitted=false,can_return_extra=false,status = case when action = 'extra' then 'extra' else 'waiting' end,
          extra_count = extra_count + case when action = 'extra' then 1 else 0 end,
          had_extra = queue_private.entries.had_extra or action = 'extra',carried_extra = case when action = 'extra' then false else queue_private.entries.carried_extra end,
          retries = retries + case when action = 'next' then 1 else 0 end,ready = false,priority = false,position = pos where id = target.id;
      end if;
    end if;
  else raise exception 'Неизвестное действие';
  end if;

  if action = 'extra' and target.id is not null then
    insert into queue_private.pending_extras(user_id,lab,retries,teacher_id,source_session_id,extra_count) values(target.user_id,target.lab,target.retries,owner_id,sid,target.extra_count+1)
      on conflict(user_id,lab,teacher_id) do update set retries = excluded.retries,source_session_id = excluded.source_session_id,extra_count = excluded.extra_count;
  end if;

  -- Hold guests until scheduled students leave the active queue. Returned extras keep their priority. Never interrupt current.
  if exists(select 1 from queue_private.entries where session_id = sid and not off_schedule and status in ('current','waiting')) then
    update queue_private.entries set status = 'deferred'
      where session_id = sid and off_schedule and status = 'waiting' and not ready and not manually_admitted;
  end if;
  -- Keep ready extras first, then initial lab priority, then FIFO (including repeat turns).
  pos := 0;
  for target in select * from queue_private.entries where session_id = sid and status = 'waiting' order by
    case when ready then 0 else 1 end,
    case when not off_schedule and retries = 0 and priority then 0 else 1 end,position,id
  loop
    pos := pos + 1;
    update queue_private.entries set position = pos where id = target.id;
  end loop;
  perform queue_private.promote_available(sid);
  insert into queue_private.results(id,session_id,name,lab,retries,outcome,user_id,off_schedule,had_extra,carried_extra,extra_count)
    select id,sid,name,lab,retries,status,user_id,off_schedule,had_extra,carried_extra,extra_count from queue_private.entries where session_id = sid
    on conflict(id) do update set retries = excluded.retries,outcome = excluded.outcome,off_schedule = excluded.off_schedule,had_extra = excluded.had_extra,carried_extra = excluded.carried_extra,extra_count = excluded.extra_count,updated_at = now();
end;
$$;









-- Also reconcile sessions already in the empty state shown in the screenshot.
do $$
declare selected uuid;
begin
  for selected in select id from queue_private.sessions where ended_at is null order by id for update loop
    perform queue_private.promote_available(selected);
    update queue_private.results r set outcome=e.status,updated_at=now()
      from queue_private.entries e where r.id=e.id and e.session_id=selected and r.outcome is distinct from e.status;
  end loop;
end;
$$;
revoke all on function public.queue_action(text,jsonb) from public,anon;
grant execute on function public.queue_action(text,jsonb) to authenticated;
commit;

-- Superadmin student management.
begin;
create or replace function public.queue_students() returns jsonb
language plpgsql security definer set search_path = '' as $$
begin
  if not public.queue_is_superadmin() then raise exception 'Доступ только superadmin'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',u.id,'login',case when u.email like '%@students.lab-queue.invalid' then split_part(u.email,'@',1) else u.email end,
    'name',coalesce(nullif(trim(p.name),''),nullif(trim(u.raw_user_meta_data->>'display_name'),''),u.raw_user_meta_data->>'full_name','')) order by coalesce(p.name,u.raw_user_meta_data->>'display_name',''),u.id)
    from auth.users u left join queue_private.profiles p on p.user_id=u.id
    where not coalesce(u.is_anonymous,false)
      and not exists(select 1 from queue_private.admins a where a.user_id=u.id)
      and not exists(select 1 from queue_private.superadmins a where a.user_id=u.id)), '[]'::jsonb);
end;
$$;
create or replace function public.queue_rename_student(student_id uuid,student_name text) returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not public.queue_is_superadmin() then raise exception 'Доступ только superadmin'; end if;
  if student_name is null or char_length(trim(student_name)) not between 2 and 60 then raise exception 'Имя: от 2 до 60 символов'; end if;
  perform 1 from auth.users where id=student_id and not coalesce(is_anonymous,false) for update;
  if not found or exists(select 1 from queue_private.admins where user_id=student_id) or exists(select 1 from queue_private.superadmins where user_id=student_id) then raise exception 'Студент не найден'; end if;
  insert into queue_private.profiles(user_id,name) values(student_id,trim(student_name)) on conflict(user_id) do update set name=excluded.name;
  update auth.users set raw_user_meta_data=coalesce(raw_user_meta_data,'{}'::jsonb)||jsonb_build_object('display_name',trim(student_name)) where id=student_id;
  update queue_private.entries e set name=trim(student_name) from queue_private.sessions s where e.session_id=s.id and s.ended_at is null and e.user_id=student_id;
  -- Closed history keeps the name recorded at the time of submission.
  update queue_private.results r set name=trim(student_name) from queue_private.sessions s where r.session_id=s.id and s.ended_at is null and r.user_id=student_id;
end;
$$;
revoke all on function public.queue_students() from public,anon;
revoke all on function public.queue_rename_student(uuid,text) from public,anon;
grant execute on function public.queue_students() to authenticated;
grant execute on function public.queue_rename_student(uuid,text) to authenticated;
commit;

-- Private student submission history.
begin;
create or replace function public.queue_my_history() returns jsonb
language plpgsql security definer set search_path = '' as $$
declare actor uuid := auth.uid();
begin
  if actor is null or not exists(select 1 from auth.users where id=actor and not coalesce(is_anonymous,false)) then
    raise exception 'Войдите в аккаунт';
  end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
    'id',r.id,'session_id',s.id,'name',r.name,'lab',r.lab,'retries',r.retries,
    'outcome',r.outcome,'off_schedule',r.off_schedule,'had_extra',r.had_extra,
    'carried_extra',r.carried_extra,'extra_count',r.extra_count,'first_try_pass',r.first_try_pass,
    'updated_at',r.updated_at,
    'session',jsonb_build_object('id',s.id,'date',s.date,'group',s."group",'created_at',s.created_at,'ended_at',s.ended_at,
      'teacher_name',coalesce(p.name,nullif(u.raw_user_meta_data->>'display_name',''),'Преподаватель'))
    ) order by coalesce(s.created_at,s.ended_at) desc nulls last,s.date desc,r.updated_at desc,r.id)
    from queue_private.results r join queue_private.sessions s on s.id=r.session_id
    left join queue_private.profiles p on p.user_id=s.created_by
    left join auth.users u on u.id=s.created_by
    where r.user_id=actor), '[]'::jsonb);
end;
$$;
revoke all on function public.queue_my_history() from public,anon;
grant execute on function public.queue_my_history() to authenticated;
commit;

-- Restore legacy extra assignments.
-- Restore a known extra assignment from before the app was introduced.
begin;
create or replace function public.queue_action(action text,payload jsonb default '{}'::jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  sid uuid;
  active_lab integer;
  admin boolean;
  owner_id uuid;
  superadmin boolean;
  target queue_private.entries;
  display_name text;
  chosen_lab integer;
  guest boolean;
  previous_retries integer;
  pending_retries integer;
  pending_source uuid;
  extra_total integer;
  was_extra boolean;
  was_carried boolean;
  pos bigint;
  group_name text;
  new_date date;
begin
  if actor is null or not exists(select 1 from auth.users where id = actor and not coalesce(is_anonymous,false)) then
    raise exception 'Войдите в аккаунт по логину и паролю';
  end if;
  sid := (payload->>'session_id')::uuid;
  select exists(select 1 from queue_private.admins where user_id = actor) into admin;
  select exists(select 1 from queue_private.superadmins where user_id = actor) into superadmin;
  if action in ('create_session','end_session','next','pass','extra','restore_extra','admit_deferred','pause_entry','pause_waiting','resume_entry','set_lab') and not admin then
    raise exception 'Доступ только преподавателю';
  end if;
  if action = 'create_session' then
    perform pg_advisory_xact_lock(hashtextextended(actor::text,0));
    if exists(select 1 from queue_private.sessions where created_by = actor and ended_at is null) then raise exception 'Сначала завершите текущую сессию'; end if;
    new_date := (payload->>'date')::date;
    group_name := trim(payload->>'group');
    if new_date is null or group_name is null or char_length(group_name) not between 1 and 60 then
      raise exception 'Укажите дату и группу (до 60 символов)';
    end if;
    insert into queue_private.sessions(date,"group",created_by) values(new_date,group_name,actor) returning id into sid;
    return;
  end if;
  if sid is null then raise exception 'Выберите сессию преподавателя или откройте QR-код'; end if;
  select created_by,lab into owner_id,active_lab from queue_private.sessions where id = sid and ended_at is null for update;
  if not found then raise exception 'Сессия изменилась или завершена. Обновите страницу'; end if;
  if admin and action in ('end_session','next','pass','extra','restore_extra','admit_deferred','pause_entry','pause_waiting','resume_entry','set_lab') and owner_id is distinct from actor and not superadmin then
    raise exception 'Вы не можете управлять сессией другого преподавателя';
  end if;
  if action = 'end_session' then
    update queue_private.results set outcome = 'failed',updated_at = now()
      where session_id = sid and outcome in ('current','waiting','deferred','paused');
    for target in select e.* from queue_private.entries e join queue_private.results r on r.id = e.id where r.session_id = sid loop
      delete from queue_private.entries where id = target.id;
    end loop;
    update queue_private.sessions set ended_at = now() where id = sid;

    return;
  end if;
  select coalesce(max(position),0)+1 into pos from queue_private.entries where session_id = sid;
  if action = 'join' then
    if exists(select 1 from queue_private.entries where user_id = actor and session_id = sid) then raise exception 'Вы уже записаны'; end if;
    display_name := coalesce(trim(payload->>'name'),
      (select name from queue_private.profiles where user_id = actor),
      (select raw_user_meta_data->>'display_name' from auth.users where id = actor));
    chosen_lab := (payload->>'lab')::integer;
    guest := coalesce((payload->>'off_schedule')::boolean,false);
    if display_name is null or char_length(display_name) not between 2 and 60 then raise exception 'Укажите имя и фамилию: от 2 до 60 символов'; end if;
    if chosen_lab is null or chosen_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    insert into queue_private.profiles(user_id,name) values(actor,display_name) on conflict(user_id) do update set name = excluded.name;
    select coalesce(max(retries),0) into previous_retries from queue_private.results where session_id = sid and user_id = actor and lab = chosen_lab;
    select retries,source_session_id into pending_retries,pending_source from queue_private.pending_extras where user_id = actor and lab = chosen_lab and teacher_id = owner_id;
    select coalesce(bool_or(r.had_extra),false),coalesce(bool_or(r.carried_extra),false) into was_extra,was_carried
      from queue_private.results r where r.session_id = sid and r.user_id = actor and r.lab = chosen_lab;
    if pending_retries is not null then was_extra := true; was_carried := pending_source is distinct from sid; end if;
    select coalesce(max(r.extra_count),0) into extra_total from queue_private.results r
      join queue_private.sessions s on s.id=r.session_id
      where r.user_id=actor and r.lab=chosen_lab and s.created_by=owner_id;
    extra_total := greatest(extra_total,coalesce((select extra_count from queue_private.pending_extras where user_id=actor and lab=chosen_lab and teacher_id=owner_id),0));
    previous_retries := greatest(previous_retries,coalesce(pending_retries,0));
    insert into queue_private.entries(user_id,name,lab,status,priority,position,retries,off_schedule,session_id,had_extra,carried_extra,extra_count)
      values(actor,display_name,chosen_lab,case when pending_retries is not null then 'extra' when guest then 'deferred' else 'waiting' end,
        pending_retries is null and not guest and chosen_lab = active_lab and previous_retries = 0 and not was_extra,pos,previous_retries,guest,sid,was_extra,was_carried,extra_total);
  elsif action = 'leave' then
    select * into target from queue_private.entries where user_id = actor and session_id = sid;
    if target.id is not null then
      update queue_private.results set outcome = 'left',updated_at = now() where id = target.id;
      delete from queue_private.entries where id = target.id;
    end if;
  elsif action = 'ready' then
    select * into target from queue_private.entries where user_id = actor and session_id = sid and status = 'extra';
    if target.id is null then raise exception 'Вы не на доп. задании'; end if;
    delete from queue_private.pending_extras where user_id = actor and lab = target.lab and teacher_id = owner_id;
    update queue_private.entries set status = 'waiting',can_return_extra = true,ready = not target.carried_extra,priority = false,position = pos where id = target.id;
  elsif action = 'return_extra' then
    select * into target from queue_private.entries where user_id=actor and session_id=sid
      and can_return_extra and status in ('waiting','current','deferred','paused');
    if target.id is null then raise exception 'Вернуться можно только после готовности к допзаданию'; end if;
    update queue_private.entries set status='extra',ready=false,priority=false,can_return_extra=false where id=target.id;
    insert into queue_private.pending_extras(user_id,lab,retries,teacher_id,source_session_id,extra_count)
      values(actor,target.lab,target.retries,owner_id,case when target.carried_extra then null else sid end,target.extra_count)
      on conflict(user_id,lab,teacher_id) do update set retries=excluded.retries,source_session_id=excluded.source_session_id,extra_count=excluded.extra_count;
  elsif action = 'restore_extra' then
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status in ('current','waiting','deferred','paused');
    if target.id is null then raise exception 'Студент больше не находится в очереди'; end if;
    update queue_private.entries set status='extra',ready=false,priority=false,manually_admitted=false,can_return_extra=false,
      had_extra=true,carried_extra=true,extra_count=greatest(extra_count,1) where id=target.id;
    insert into queue_private.pending_extras(user_id,lab,retries,teacher_id,source_session_id,extra_count)
      values(target.user_id,target.lab,target.retries,owner_id,null,greatest(target.extra_count,1))
      on conflict(user_id,lab,teacher_id) do update set retries=greatest(queue_private.pending_extras.retries,excluded.retries),
        source_session_id=null,extra_count=greatest(queue_private.pending_extras.extra_count,excluded.extra_count);
  elsif action = 'pause_entry' then
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status in ('current','waiting');
    if target.id is null then raise exception 'Студент больше не находится в очереди'; end if;
    update queue_private.entries set status='paused',ready=false,priority=false,manually_admitted=false,position=pos where id=target.id;
  elsif action = 'pause_waiting' then
    update queue_private.entries set status='paused',ready=false,priority=false,manually_admitted=false where session_id=sid and status='waiting';
  elsif action = 'resume_entry' then
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status='paused';
    if target.id is null then raise exception 'Студент больше не находится в ожидании'; end if;
    update queue_private.entries set status='waiting',ready=false,priority=false,manually_admitted=true,position=pos where id=target.id;
  elsif action = 'admit_deferred' then
    if exists(select 1 from queue_private.entries where session_id=sid and status='waiting') then
      raise exception 'Сначала дождитесь освобождения очереди';
    end if;
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status='deferred';
    if target.id is null then raise exception 'Студент больше не ожидает допуска в этой сессии'; end if;
    update queue_private.entries set status='waiting',manually_admitted=true,ready=false,priority=false,position=pos where id=target.id;
  elsif action = 'set_lab' then
    chosen_lab := (payload->>'lab')::integer;
    if chosen_lab is null or chosen_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    update queue_private.sessions set lab = chosen_lab where id = sid;
  elsif action in ('next','pass','extra') then
    select * into target from queue_private.entries where session_id = sid and status = 'current';
    if target.id is distinct from (payload->>'current_id')::uuid then raise exception 'Очередь изменилась. Обновите страницу и повторите действие'; end if;
    if target.id is not null then
      if action = 'pass' then
        delete from queue_private.pending_extras where user_id = target.user_id and lab = target.lab and teacher_id = owner_id;
        update queue_private.results set outcome = 'passed',first_try_pass = (
          target.retries=0 and target.extra_count=0 and not target.had_extra and not exists(
            select 1 from queue_private.results prior join queue_private.sessions s on s.id=prior.session_id
            where prior.user_id=target.user_id and prior.lab=target.lab and s.created_by=owner_id and prior.id<>target.id
              and (prior.outcome in ('failed','passed') or prior.retries>0 or prior.had_extra)
          )),updated_at = now() where id = target.id;
        delete from queue_private.entries where id = target.id;
      else
        update queue_private.entries set manually_admitted=false,can_return_extra=false,status = case when action = 'extra' then 'extra' else 'waiting' end,
          extra_count = extra_count + case when action = 'extra' then 1 else 0 end,
          had_extra = queue_private.entries.had_extra or action = 'extra',carried_extra = case when action = 'extra' then false else queue_private.entries.carried_extra end,
          retries = retries + case when action = 'next' then 1 else 0 end,ready = false,priority = false,position = pos where id = target.id;
      end if;
    end if;
  else raise exception 'Неизвестное действие';
  end if;

  if action = 'extra' and target.id is not null then
    insert into queue_private.pending_extras(user_id,lab,retries,teacher_id,source_session_id,extra_count) values(target.user_id,target.lab,target.retries,owner_id,sid,target.extra_count+1)
      on conflict(user_id,lab,teacher_id) do update set retries = excluded.retries,source_session_id = excluded.source_session_id,extra_count = excluded.extra_count;
  end if;

  -- Hold guests until scheduled students leave the active queue. Returned extras keep their priority. Never interrupt current.
  if exists(select 1 from queue_private.entries where session_id = sid and not off_schedule and status in ('current','waiting')) then
    update queue_private.entries set status = 'deferred'
      where session_id = sid and off_schedule and status = 'waiting' and not ready and not manually_admitted;
  end if;
  -- Keep ready extras first, then initial lab priority, then FIFO (including repeat turns).
  pos := 0;
  for target in select * from queue_private.entries where session_id = sid and status = 'waiting' order by
    case when ready then 0 else 1 end,
    case when not off_schedule and retries = 0 and priority then 0 else 1 end,position,id
  loop
    pos := pos + 1;
    update queue_private.entries set position = pos where id = target.id;
  end loop;
  perform queue_private.promote_available(sid);
  insert into queue_private.results(id,session_id,name,lab,retries,outcome,user_id,off_schedule,had_extra,carried_extra,extra_count)
    select id,sid,name,lab,retries,status,user_id,off_schedule,had_extra,carried_extra,extra_count from queue_private.entries where session_id = sid
    on conflict(id) do update set retries = excluded.retries,outcome = excluded.outcome,off_schedule = excluded.off_schedule,had_extra = excluded.had_extra,carried_extra = excluded.carried_extra,extra_count = excluded.extra_count,updated_at = now();
end;
$$;
revoke all on function public.queue_action(text,jsonb) from public,anon;
grant execute on function public.queue_action(text,jsonb) to authenticated;
commit;

-- Preserve admission across repeat attempts.
-- Keep admitted off-schedule students in the normal queue after Next.
begin;
create or replace function public.queue_action(action text,payload jsonb default '{}'::jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  sid uuid;
  active_lab integer;
  admin boolean;
  owner_id uuid;
  superadmin boolean;
  target queue_private.entries;
  display_name text;
  chosen_lab integer;
  guest boolean;
  previous_retries integer;
  pending_retries integer;
  pending_source uuid;
  extra_total integer;
  was_extra boolean;
  was_carried boolean;
  pos bigint;
  group_name text;
  new_date date;
begin
  if actor is null or not exists(select 1 from auth.users where id = actor and not coalesce(is_anonymous,false)) then
    raise exception 'Войдите в аккаунт по логину и паролю';
  end if;
  sid := (payload->>'session_id')::uuid;
  select exists(select 1 from queue_private.admins where user_id = actor) into admin;
  select exists(select 1 from queue_private.superadmins where user_id = actor) into superadmin;
  if action in ('create_session','end_session','next','pass','extra','restore_extra','admit_deferred','pause_entry','pause_waiting','resume_entry','set_lab') and not admin then
    raise exception 'Доступ только преподавателю';
  end if;
  if action = 'create_session' then
    perform pg_advisory_xact_lock(hashtextextended(actor::text,0));
    if exists(select 1 from queue_private.sessions where created_by = actor and ended_at is null) then raise exception 'Сначала завершите текущую сессию'; end if;
    new_date := (payload->>'date')::date;
    group_name := trim(payload->>'group');
    if new_date is null or group_name is null or char_length(group_name) not between 1 and 60 then
      raise exception 'Укажите дату и группу (до 60 символов)';
    end if;
    insert into queue_private.sessions(date,"group",created_by) values(new_date,group_name,actor) returning id into sid;
    return;
  end if;
  if sid is null then raise exception 'Выберите сессию преподавателя или откройте QR-код'; end if;
  select created_by,lab into owner_id,active_lab from queue_private.sessions where id = sid and ended_at is null for update;
  if not found then raise exception 'Сессия изменилась или завершена. Обновите страницу'; end if;
  if admin and action in ('end_session','next','pass','extra','restore_extra','admit_deferred','pause_entry','pause_waiting','resume_entry','set_lab') and owner_id is distinct from actor and not superadmin then
    raise exception 'Вы не можете управлять сессией другого преподавателя';
  end if;
  if action = 'end_session' then
    update queue_private.results set outcome = 'failed',updated_at = now()
      where session_id = sid and outcome in ('current','waiting','deferred','paused');
    for target in select e.* from queue_private.entries e join queue_private.results r on r.id = e.id where r.session_id = sid loop
      delete from queue_private.entries where id = target.id;
    end loop;
    update queue_private.sessions set ended_at = now() where id = sid;

    return;
  end if;
  select coalesce(max(position),0)+1 into pos from queue_private.entries where session_id = sid;
  if action = 'join' then
    if exists(select 1 from queue_private.entries where user_id = actor and session_id = sid) then raise exception 'Вы уже записаны'; end if;
    display_name := coalesce(trim(payload->>'name'),
      (select name from queue_private.profiles where user_id = actor),
      (select raw_user_meta_data->>'display_name' from auth.users where id = actor));
    chosen_lab := (payload->>'lab')::integer;
    guest := coalesce((payload->>'off_schedule')::boolean,false);
    if display_name is null or char_length(display_name) not between 2 and 60 then raise exception 'Укажите имя и фамилию: от 2 до 60 символов'; end if;
    if chosen_lab is null or chosen_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    insert into queue_private.profiles(user_id,name) values(actor,display_name) on conflict(user_id) do update set name = excluded.name;
    select coalesce(max(retries),0) into previous_retries from queue_private.results where session_id = sid and user_id = actor and lab = chosen_lab;
    select retries,source_session_id into pending_retries,pending_source from queue_private.pending_extras where user_id = actor and lab = chosen_lab and teacher_id = owner_id;
    select coalesce(bool_or(r.had_extra),false),coalesce(bool_or(r.carried_extra),false) into was_extra,was_carried
      from queue_private.results r where r.session_id = sid and r.user_id = actor and r.lab = chosen_lab;
    if pending_retries is not null then was_extra := true; was_carried := pending_source is distinct from sid; end if;
    select coalesce(max(r.extra_count),0) into extra_total from queue_private.results r
      join queue_private.sessions s on s.id=r.session_id
      where r.user_id=actor and r.lab=chosen_lab and s.created_by=owner_id;
    extra_total := greatest(extra_total,coalesce((select extra_count from queue_private.pending_extras where user_id=actor and lab=chosen_lab and teacher_id=owner_id),0));
    previous_retries := greatest(previous_retries,coalesce(pending_retries,0));
    insert into queue_private.entries(user_id,name,lab,status,priority,position,retries,off_schedule,session_id,had_extra,carried_extra,extra_count)
      values(actor,display_name,chosen_lab,case when pending_retries is not null then 'extra' when guest then 'deferred' else 'waiting' end,
        pending_retries is null and not guest and chosen_lab = active_lab and previous_retries = 0 and not was_extra,pos,previous_retries,guest,sid,was_extra,was_carried,extra_total);
  elsif action = 'leave' then
    select * into target from queue_private.entries where user_id = actor and session_id = sid;
    if target.id is not null then
      update queue_private.results set outcome = 'left',updated_at = now() where id = target.id;
      delete from queue_private.entries where id = target.id;
    end if;
  elsif action = 'ready' then
    select * into target from queue_private.entries where user_id = actor and session_id = sid and status = 'extra';
    if target.id is null then raise exception 'Вы не на доп. задании'; end if;
    delete from queue_private.pending_extras where user_id = actor and lab = target.lab and teacher_id = owner_id;
    update queue_private.entries set status = 'waiting',can_return_extra = true,ready = not target.carried_extra,priority = false,position = pos where id = target.id;
  elsif action = 'return_extra' then
    select * into target from queue_private.entries where user_id=actor and session_id=sid
      and can_return_extra and status in ('waiting','current','deferred','paused');
    if target.id is null then raise exception 'Вернуться можно только после готовности к допзаданию'; end if;
    update queue_private.entries set status='extra',ready=false,priority=false,can_return_extra=false where id=target.id;
    insert into queue_private.pending_extras(user_id,lab,retries,teacher_id,source_session_id,extra_count)
      values(actor,target.lab,target.retries,owner_id,case when target.carried_extra then null else sid end,target.extra_count)
      on conflict(user_id,lab,teacher_id) do update set retries=excluded.retries,source_session_id=excluded.source_session_id,extra_count=excluded.extra_count;
  elsif action = 'restore_extra' then
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status in ('current','waiting','deferred','paused');
    if target.id is null then raise exception 'Студент больше не находится в очереди'; end if;
    update queue_private.entries set status='extra',ready=false,priority=false,manually_admitted=false,can_return_extra=false,
      had_extra=true,carried_extra=true,extra_count=greatest(extra_count,1) where id=target.id;
    insert into queue_private.pending_extras(user_id,lab,retries,teacher_id,source_session_id,extra_count)
      values(target.user_id,target.lab,target.retries,owner_id,null,greatest(target.extra_count,1))
      on conflict(user_id,lab,teacher_id) do update set retries=greatest(queue_private.pending_extras.retries,excluded.retries),
        source_session_id=null,extra_count=greatest(queue_private.pending_extras.extra_count,excluded.extra_count);
  elsif action = 'pause_entry' then
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status in ('current','waiting');
    if target.id is null then raise exception 'Студент больше не находится в очереди'; end if;
    update queue_private.entries set status='paused',ready=false,priority=false,manually_admitted=false,position=pos where id=target.id;
  elsif action = 'pause_waiting' then
    update queue_private.entries set status='paused',ready=false,priority=false,manually_admitted=false where session_id=sid and status='waiting';
  elsif action = 'resume_entry' then
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status='paused';
    if target.id is null then raise exception 'Студент больше не находится в ожидании'; end if;
    update queue_private.entries set status='waiting',ready=false,priority=false,manually_admitted=true,position=pos where id=target.id;
  elsif action = 'admit_deferred' then
    if exists(select 1 from queue_private.entries where session_id=sid and status='waiting') then
      raise exception 'Сначала дождитесь освобождения очереди';
    end if;
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status='deferred';
    if target.id is null then raise exception 'Студент больше не ожидает допуска в этой сессии'; end if;
    update queue_private.entries set status='waiting',manually_admitted=true,ready=false,priority=false,position=pos where id=target.id;
  elsif action = 'set_lab' then
    chosen_lab := (payload->>'lab')::integer;
    if chosen_lab is null or chosen_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    update queue_private.sessions set lab = chosen_lab where id = sid;
  elsif action in ('next','pass','extra') then
    select * into target from queue_private.entries where session_id = sid and status = 'current';
    if target.id is distinct from (payload->>'current_id')::uuid then raise exception 'Очередь изменилась. Обновите страницу и повторите действие'; end if;
    if target.id is not null then
      if action = 'pass' then
        delete from queue_private.pending_extras where user_id = target.user_id and lab = target.lab and teacher_id = owner_id;
        update queue_private.results set outcome = 'passed',first_try_pass = (
          target.retries=0 and target.extra_count=0 and not target.had_extra and not exists(
            select 1 from queue_private.results prior join queue_private.sessions s on s.id=prior.session_id
            where prior.user_id=target.user_id and prior.lab=target.lab and s.created_by=owner_id and prior.id<>target.id
              and (prior.outcome in ('failed','passed') or prior.retries>0 or prior.had_extra)
          )),updated_at = now() where id = target.id;
        delete from queue_private.entries where id = target.id;
      else
        update queue_private.entries set manually_admitted=(action = 'next' and target.off_schedule),can_return_extra=false,status = case when action = 'extra' then 'extra' else 'waiting' end,
          extra_count = extra_count + case when action = 'extra' then 1 else 0 end,
          had_extra = queue_private.entries.had_extra or action = 'extra',carried_extra = case when action = 'extra' then false else queue_private.entries.carried_extra end,
          retries = retries + case when action = 'next' then 1 else 0 end,ready = false,priority = false,position = pos where id = target.id;
      end if;
    end if;
  else raise exception 'Неизвестное действие';
  end if;

  if action = 'extra' and target.id is not null then
    insert into queue_private.pending_extras(user_id,lab,retries,teacher_id,source_session_id,extra_count) values(target.user_id,target.lab,target.retries,owner_id,sid,target.extra_count+1)
      on conflict(user_id,lab,teacher_id) do update set retries = excluded.retries,source_session_id = excluded.source_session_id,extra_count = excluded.extra_count;
  end if;

  -- Hold guests until scheduled students leave the active queue. Returned extras keep their priority. Never interrupt current.
  if exists(select 1 from queue_private.entries where session_id = sid and not off_schedule and status in ('current','waiting')) then
    update queue_private.entries set status = 'deferred'
      where session_id = sid and off_schedule and status = 'waiting' and not ready and not manually_admitted;
  end if;
  -- Keep ready extras first, then initial lab priority, then FIFO (including repeat turns).
  pos := 0;
  for target in select * from queue_private.entries where session_id = sid and status = 'waiting' order by
    case when ready then 0 else 1 end,
    case when not off_schedule and retries = 0 and priority then 0 else 1 end,position,id
  loop
    pos := pos + 1;
    update queue_private.entries set position = pos where id = target.id;
  end loop;
  perform queue_private.promote_available(sid);
  insert into queue_private.results(id,session_id,name,lab,retries,outcome,user_id,off_schedule,had_extra,carried_extra,extra_count)
    select id,sid,name,lab,retries,status,user_id,off_schedule,had_extra,carried_extra,extra_count from queue_private.entries where session_id = sid
    on conflict(id) do update set retries = excluded.retries,outcome = excluded.outcome,off_schedule = excluded.off_schedule,had_extra = excluded.had_extra,carried_extra = excluded.carried_extra,extra_count = excluded.extra_count,updated_at = now();
end;
$$;
revoke all on function public.queue_action(text,jsonb) from public,anon;
grant execute on function public.queue_action(text,jsonb) to authenticated;

-- Recover active students already returned to deferred by the old Next action.
do $$
declare sid uuid;
begin
  for sid in select id from queue_private.sessions where ended_at is null order by id for update loop
    with recovered as (
      select id,(select coalesce(max(position),0) from queue_private.entries where session_id=sid)
        +row_number() over(order by position,id) as new_position
      from queue_private.entries where session_id=sid and status='deferred' and retries>0
    )
    update queue_private.entries e set status='waiting',manually_admitted=true,ready=false,priority=false,position=r.new_position
      from recovered r where e.id=r.id;
    perform queue_private.promote_available(sid);
    update queue_private.results r set outcome=e.status,updated_at=now() from queue_private.entries e
      where r.id=e.id and e.session_id=sid and r.outcome is distinct from e.status;
  end loop;
end;
$$;
commit;

-- Priority admission for completed legacy extras.
-- Teacher priority admission of completed legacy extra assignments.
begin;
create or replace function public.queue_action(action text,payload jsonb default '{}'::jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  sid uuid;
  active_lab integer;
  admin boolean;
  owner_id uuid;
  superadmin boolean;
  target queue_private.entries;
  display_name text;
  chosen_lab integer;
  guest boolean;
  previous_retries integer;
  pending_retries integer;
  pending_source uuid;
  extra_total integer;
  was_extra boolean;
  was_carried boolean;
  pos bigint;
  group_name text;
  new_date date;
begin
  if actor is null or not exists(select 1 from auth.users where id = actor and not coalesce(is_anonymous,false)) then
    raise exception 'Войдите в аккаунт по логину и паролю';
  end if;
  sid := (payload->>'session_id')::uuid;
  select exists(select 1 from queue_private.admins where user_id = actor) into admin;
  select exists(select 1 from queue_private.superadmins where user_id = actor) into superadmin;
  if action in ('create_session','end_session','next','pass','extra','restore_extra','admit_ready_extra','admit_deferred','pause_entry','pause_waiting','resume_entry','set_lab') and not admin then
    raise exception 'Доступ только преподавателю';
  end if;
  if action = 'create_session' then
    perform pg_advisory_xact_lock(hashtextextended(actor::text,0));
    if exists(select 1 from queue_private.sessions where created_by = actor and ended_at is null) then raise exception 'Сначала завершите текущую сессию'; end if;
    new_date := (payload->>'date')::date;
    group_name := trim(payload->>'group');
    if new_date is null or group_name is null or char_length(group_name) not between 1 and 60 then
      raise exception 'Укажите дату и группу (до 60 символов)';
    end if;
    insert into queue_private.sessions(date,"group",created_by) values(new_date,group_name,actor) returning id into sid;
    return;
  end if;
  if sid is null then raise exception 'Выберите сессию преподавателя или откройте QR-код'; end if;
  select created_by,lab into owner_id,active_lab from queue_private.sessions where id = sid and ended_at is null for update;
  if not found then raise exception 'Сессия изменилась или завершена. Обновите страницу'; end if;
  if admin and action in ('end_session','next','pass','extra','restore_extra','admit_ready_extra','admit_deferred','pause_entry','pause_waiting','resume_entry','set_lab') and owner_id is distinct from actor and not superadmin then
    raise exception 'Вы не можете управлять сессией другого преподавателя';
  end if;
  if action = 'end_session' then
    update queue_private.results set outcome = 'failed',updated_at = now()
      where session_id = sid and outcome in ('current','waiting','deferred','paused');
    for target in select e.* from queue_private.entries e join queue_private.results r on r.id = e.id where r.session_id = sid loop
      delete from queue_private.entries where id = target.id;
    end loop;
    update queue_private.sessions set ended_at = now() where id = sid;

    return;
  end if;
  select coalesce(max(position),0)+1 into pos from queue_private.entries where session_id = sid;
  if action = 'join' then
    if exists(select 1 from queue_private.entries where user_id = actor and session_id = sid) then raise exception 'Вы уже записаны'; end if;
    display_name := coalesce(trim(payload->>'name'),
      (select name from queue_private.profiles where user_id = actor),
      (select raw_user_meta_data->>'display_name' from auth.users where id = actor));
    chosen_lab := (payload->>'lab')::integer;
    guest := coalesce((payload->>'off_schedule')::boolean,false);
    if display_name is null or char_length(display_name) not between 2 and 60 then raise exception 'Укажите имя и фамилию: от 2 до 60 символов'; end if;
    if chosen_lab is null or chosen_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    insert into queue_private.profiles(user_id,name) values(actor,display_name) on conflict(user_id) do update set name = excluded.name;
    select coalesce(max(retries),0) into previous_retries from queue_private.results where session_id = sid and user_id = actor and lab = chosen_lab;
    select retries,source_session_id into pending_retries,pending_source from queue_private.pending_extras where user_id = actor and lab = chosen_lab and teacher_id = owner_id;
    select coalesce(bool_or(r.had_extra),false),coalesce(bool_or(r.carried_extra),false) into was_extra,was_carried
      from queue_private.results r where r.session_id = sid and r.user_id = actor and r.lab = chosen_lab;
    if pending_retries is not null then was_extra := true; was_carried := pending_source is distinct from sid; end if;
    select coalesce(max(r.extra_count),0) into extra_total from queue_private.results r
      join queue_private.sessions s on s.id=r.session_id
      where r.user_id=actor and r.lab=chosen_lab and s.created_by=owner_id;
    extra_total := greatest(extra_total,coalesce((select extra_count from queue_private.pending_extras where user_id=actor and lab=chosen_lab and teacher_id=owner_id),0));
    previous_retries := greatest(previous_retries,coalesce(pending_retries,0));
    insert into queue_private.entries(user_id,name,lab,status,priority,position,retries,off_schedule,session_id,had_extra,carried_extra,extra_count)
      values(actor,display_name,chosen_lab,case when pending_retries is not null then 'extra' when guest then 'deferred' else 'waiting' end,
        pending_retries is null and not guest and chosen_lab = active_lab and previous_retries = 0 and not was_extra,pos,previous_retries,guest,sid,was_extra,was_carried,extra_total);
  elsif action = 'leave' then
    select * into target from queue_private.entries where user_id = actor and session_id = sid;
    if target.id is not null then
      update queue_private.results set outcome = 'left',updated_at = now() where id = target.id;
      delete from queue_private.entries where id = target.id;
    end if;
  elsif action = 'ready' then
    select * into target from queue_private.entries where user_id = actor and session_id = sid and status = 'extra';
    if target.id is null then raise exception 'Вы не на доп. задании'; end if;
    delete from queue_private.pending_extras where user_id = actor and lab = target.lab and teacher_id = owner_id;
    update queue_private.entries set status = 'waiting',can_return_extra = true,ready = not target.carried_extra,priority = false,position = pos where id = target.id;
  elsif action = 'return_extra' then
    select * into target from queue_private.entries where user_id=actor and session_id=sid
      and can_return_extra and status in ('waiting','current','deferred','paused');
    if target.id is null then raise exception 'Вернуться можно только после готовности к допзаданию'; end if;
    update queue_private.entries set status='extra',ready=false,priority=false,can_return_extra=false where id=target.id;
    insert into queue_private.pending_extras(user_id,lab,retries,teacher_id,source_session_id,extra_count)
      values(actor,target.lab,target.retries,owner_id,case when target.carried_extra then null else sid end,target.extra_count)
      on conflict(user_id,lab,teacher_id) do update set retries=excluded.retries,source_session_id=excluded.source_session_id,extra_count=excluded.extra_count;
  elsif action = 'restore_extra' then
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status in ('current','waiting','deferred','paused');
    if target.id is null then raise exception 'Студент больше не находится в очереди'; end if;
    update queue_private.entries set status='extra',ready=false,priority=false,manually_admitted=false,can_return_extra=false,
      had_extra=true,carried_extra=true,extra_count=greatest(extra_count,1) where id=target.id;
    insert into queue_private.pending_extras(user_id,lab,retries,teacher_id,source_session_id,extra_count)
      values(target.user_id,target.lab,target.retries,owner_id,null,greatest(target.extra_count,1))
      on conflict(user_id,lab,teacher_id) do update set retries=greatest(queue_private.pending_extras.retries,excluded.retries),
        source_session_id=null,extra_count=greatest(queue_private.pending_extras.extra_count,excluded.extra_count);
  elsif action = 'admit_ready_extra' then
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid
      and status in ('waiting','deferred','paused','extra') and not ready;
    if target.id is null then raise exception 'Студент уже вызван или очередь изменилась'; end if;
    update queue_private.entries set status='waiting',ready=true,priority=false,manually_admitted=true,can_return_extra=true,
      had_extra=true,carried_extra=true,extra_count=greatest(extra_count,1),position=pos where id=target.id;
    delete from queue_private.pending_extras where user_id=target.user_id and lab=target.lab and teacher_id=owner_id;
  elsif action = 'pause_entry' then
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status in ('current','waiting');
    if target.id is null then raise exception 'Студент больше не находится в очереди'; end if;
    update queue_private.entries set status='paused',ready=false,priority=false,manually_admitted=false,position=pos where id=target.id;
  elsif action = 'pause_waiting' then
    update queue_private.entries set status='paused',ready=false,priority=false,manually_admitted=false where session_id=sid and status='waiting';
  elsif action = 'resume_entry' then
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status='paused';
    if target.id is null then raise exception 'Студент больше не находится в ожидании'; end if;
    update queue_private.entries set status='waiting',ready=false,priority=false,manually_admitted=true,position=pos where id=target.id;
  elsif action = 'admit_deferred' then
    if exists(select 1 from queue_private.entries where session_id=sid and status='waiting') then
      raise exception 'Сначала дождитесь освобождения очереди';
    end if;
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status='deferred';
    if target.id is null then raise exception 'Студент больше не ожидает допуска в этой сессии'; end if;
    update queue_private.entries set status='waiting',manually_admitted=true,ready=false,priority=false,position=pos where id=target.id;
  elsif action = 'set_lab' then
    chosen_lab := (payload->>'lab')::integer;
    if chosen_lab is null or chosen_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    update queue_private.sessions set lab = chosen_lab where id = sid;
  elsif action in ('next','pass','extra') then
    select * into target from queue_private.entries where session_id = sid and status = 'current';
    if target.id is distinct from (payload->>'current_id')::uuid then raise exception 'Очередь изменилась. Обновите страницу и повторите действие'; end if;
    if target.id is not null then
      if action = 'pass' then
        delete from queue_private.pending_extras where user_id = target.user_id and lab = target.lab and teacher_id = owner_id;
        update queue_private.results set outcome = 'passed',first_try_pass = (
          target.retries=0 and target.extra_count=0 and not target.had_extra and not exists(
            select 1 from queue_private.results prior join queue_private.sessions s on s.id=prior.session_id
            where prior.user_id=target.user_id and prior.lab=target.lab and s.created_by=owner_id and prior.id<>target.id
              and (prior.outcome in ('failed','passed') or prior.retries>0 or prior.had_extra)
          )),updated_at = now() where id = target.id;
        delete from queue_private.entries where id = target.id;
      else
        update queue_private.entries set manually_admitted=(action = 'next' and target.off_schedule),can_return_extra=false,status = case when action = 'extra' then 'extra' else 'waiting' end,
          extra_count = extra_count + case when action = 'extra' then 1 else 0 end,
          had_extra = queue_private.entries.had_extra or action = 'extra',carried_extra = case when action = 'extra' then false else queue_private.entries.carried_extra end,
          retries = retries + case when action = 'next' then 1 else 0 end,ready = false,priority = false,position = pos where id = target.id;
      end if;
    end if;
  else raise exception 'Неизвестное действие';
  end if;

  if action = 'extra' and target.id is not null then
    insert into queue_private.pending_extras(user_id,lab,retries,teacher_id,source_session_id,extra_count) values(target.user_id,target.lab,target.retries,owner_id,sid,target.extra_count+1)
      on conflict(user_id,lab,teacher_id) do update set retries = excluded.retries,source_session_id = excluded.source_session_id,extra_count = excluded.extra_count;
  end if;

  -- Hold guests until scheduled students leave the active queue. Returned extras keep their priority. Never interrupt current.
  if exists(select 1 from queue_private.entries where session_id = sid and not off_schedule and status in ('current','waiting')) then
    update queue_private.entries set status = 'deferred'
      where session_id = sid and off_schedule and status = 'waiting' and not ready and not manually_admitted;
  end if;
  -- Keep ready extras first, then initial lab priority, then FIFO (including repeat turns).
  pos := 0;
  for target in select * from queue_private.entries where session_id = sid and status = 'waiting' order by
    case when ready then 0 else 1 end,
    case when not off_schedule and retries = 0 and priority then 0 else 1 end,position,id
  loop
    pos := pos + 1;
    update queue_private.entries set position = pos where id = target.id;
  end loop;
  perform queue_private.promote_available(sid);
  insert into queue_private.results(id,session_id,name,lab,retries,outcome,user_id,off_schedule,had_extra,carried_extra,extra_count)
    select id,sid,name,lab,retries,status,user_id,off_schedule,had_extra,carried_extra,extra_count from queue_private.entries where session_id = sid
    on conflict(id) do update set retries = excluded.retries,outcome = excluded.outcome,off_schedule = excluded.off_schedule,had_extra = excluded.had_extra,carried_extra = excluded.carried_extra,extra_count = excluded.extra_count,updated_at = now();
end;
$$;
revoke all on function public.queue_action(text,jsonb) from public,anon;
grant execute on function public.queue_action(text,jsonb) to authenticated;

commit;

-- Lightweight live queue and lazy history.
-- Separate live queue polling from on-demand teacher history.
begin;
create index if not exists queue_results_session_idx on queue_private.results(session_id);
create or replace function public.queue_live_snapshot(target_session_id uuid default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  admin boolean;
  superadmin boolean;
  sid uuid := target_session_id;
  owner_id uuid;
  saved_name text;
  metadata jsonb;
begin
  if actor is null or not exists(select 1 from auth.users where id = actor and not coalesce(is_anonymous,false)) then
    raise exception 'Войдите в аккаунт по логину и паролю';
  end if;
  select exists(select 1 from queue_private.admins where user_id = actor) into admin;
  select exists(select 1 from queue_private.superadmins where user_id = actor) into superadmin;
  if sid is null and admin then
    select id into sid from queue_private.sessions where created_by = actor and ended_at is null order by created_at desc nulls last,id limit 1;
  end if;
  if sid is not null then
    if admin and not superadmin and exists(select 1 from queue_private.sessions where id = sid and created_by is distinct from actor) then
      raise exception 'Вы не можете просматривать сессию другого преподавателя';
    end if;
    select created_by into owner_id from queue_private.sessions where id = sid and ended_at is null;
    if not found then sid := null; end if;
  end if;
  select raw_user_meta_data into metadata from auth.users where id = actor;
  saved_name := coalesce(
    (select nullif(trim(name),'') from queue_private.profiles where user_id = actor),
    (select nullif(trim(name),'') from queue_private.entries where user_id = actor order by position,id limit 1),
    (select nullif(trim(name),'') from queue_private.results where user_id = actor order by updated_at desc,id limit 1),
    nullif(trim(metadata->>'display_name'),''),nullif(trim(metadata->>'full_name'),''),nullif(trim(metadata->>'name'),''),
    nullif(trim(concat_ws(' ',nullif(trim(metadata->>'first_name'),''),nullif(trim(metadata->>'last_name'),''))),'')
  );
  return jsonb_build_object(
    'admin',admin,'superadmin',superadmin,'profile_name',saved_name,
    'lab',coalesce((select lab from queue_private.sessions where id = sid),6),
    'session',(select to_jsonb(s) || jsonb_build_object('teacher_name',coalesce(p.name,'Преподаватель')) from queue_private.sessions s left join queue_private.profiles p on p.user_id = s.created_by where s.id = sid),
    'available_sessions',coalesce((select jsonb_agg(to_jsonb(s) || jsonb_build_object('teacher_name',coalesce(p.name,'Преподаватель')) order by s.created_at desc nulls last,s.id)
      from queue_private.sessions s left join queue_private.profiles p on p.user_id = s.created_by
      where s.ended_at is null and (not admin or superadmin or s.created_by = actor)),'[]'::jsonb),
    'passed_count',case when admin then (select count(*) from queue_private.results where session_id=sid and outcome='passed') else 0 end,
    'pending_extras',coalesce((select jsonb_agg(jsonb_build_object('lab',lab,'retries',retries) order by lab)
      from queue_private.pending_extras where user_id = actor and teacher_id = owner_id),'[]'::jsonb),
    'entries',coalesce((select jsonb_agg(jsonb_build_object(
      'id',id,'name',name,'lab',lab,'status',status,'priority',priority,'ready',ready,
      'position',position,'retries',retries,'mine',user_id = actor,'off_schedule',off_schedule,'had_extra',had_extra,'carried_extra',carried_extra,'extra_count',extra_count,'can_return_extra',can_return_extra) order by position,id)
      from queue_private.entries where session_id = sid),'[]'::jsonb)
  );
end;
$$;

create or replace function public.queue_history_sessions() returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); superadmin boolean;
begin
  if actor is null or not exists(select 1 from auth.users where id=actor and not coalesce(is_anonymous,false))
    or not exists(select 1 from queue_private.admins where user_id=actor) then raise exception 'Доступ только преподавателю'; end if;
  select exists(select 1 from queue_private.superadmins where user_id=actor) into superadmin;
  return coalesce((select jsonb_agg(to_jsonb(s)||jsonb_build_object('teacher_name',coalesce(p.name,'Преподаватель'))
    order by coalesce(s.created_at,s.ended_at) desc nulls last,s.date desc,s.id)
    from queue_private.sessions s left join queue_private.profiles p on p.user_id=s.created_by
    where superadmin or s.created_by=actor),'[]'::jsonb);
end;
$$;
create or replace function public.queue_session_results(target_session_id uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); owner_id uuid;
begin
  if actor is null or not exists(select 1 from auth.users where id=actor and not coalesce(is_anonymous,false))
    or not exists(select 1 from queue_private.admins where user_id=actor) then raise exception 'Доступ только преподавателю'; end if;
  select created_by into owner_id from queue_private.sessions where id=target_session_id;
  if not found then raise exception 'Сессия не найдена'; end if;
  if owner_id is distinct from actor and not exists(select 1 from queue_private.superadmins where user_id=actor) then raise exception 'Вы не можете просматривать историю другого преподавателя'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'session_id',r.session_id,'name',r.name,'lab',r.lab,
    'retries',r.retries,'outcome',r.outcome,'updated_at',r.updated_at,'off_schedule',r.off_schedule,'had_extra',r.had_extra,
    'carried_extra',r.carried_extra,'extra_count',r.extra_count,'first_try_pass',r.first_try_pass) order by r.updated_at,r.id)
    from queue_private.results r where r.session_id=target_session_id),'[]'::jsonb);
end;
$$;
revoke all on function public.queue_live_snapshot(uuid) from public,anon;
revoke all on function public.queue_history_sessions() from public,anon;
revoke all on function public.queue_session_results(uuid) from public,anon;
grant execute on function public.queue_live_snapshot(uuid) to authenticated;
grant execute on function public.queue_history_sessions() to authenticated;
grant execute on function public.queue_session_results(uuid) to authenticated;
commit;

-- Atomic initial session laboratory number.
-- Set the initial lab in the same transaction that opens a session.
begin;
create or replace function public.queue_action(action text,payload jsonb default '{}'::jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  sid uuid;
  active_lab integer;
  admin boolean;
  owner_id uuid;
  superadmin boolean;
  target queue_private.entries;
  display_name text;
  chosen_lab integer;
  guest boolean;
  previous_retries integer;
  pending_retries integer;
  pending_source uuid;
  extra_total integer;
  was_extra boolean;
  was_carried boolean;
  pos bigint;
  group_name text;
  new_date date;
begin
  if actor is null or not exists(select 1 from auth.users where id = actor and not coalesce(is_anonymous,false)) then
    raise exception 'Войдите в аккаунт по логину и паролю';
  end if;
  sid := (payload->>'session_id')::uuid;
  select exists(select 1 from queue_private.admins where user_id = actor) into admin;
  select exists(select 1 from queue_private.superadmins where user_id = actor) into superadmin;
  if action in ('create_session','end_session','next','pass','extra','restore_extra','admit_ready_extra','admit_deferred','pause_entry','pause_waiting','resume_entry','set_lab') and not admin then
    raise exception 'Доступ только преподавателю';
  end if;
  if action = 'create_session' then
    perform pg_advisory_xact_lock(hashtextextended(actor::text,0));
    if exists(select 1 from queue_private.sessions where created_by = actor and ended_at is null) then raise exception 'Сначала завершите текущую сессию'; end if;
    new_date := (payload->>'date')::date;
    group_name := trim(payload->>'group');
    if new_date is null or group_name is null or char_length(group_name) not between 1 and 60 then
      raise exception 'Укажите дату и группу (до 60 символов)';
    end if;
    active_lab := coalesce((payload->>'lab')::integer,6);
    if active_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    insert into queue_private.sessions(date,"group",created_by,lab) values(new_date,group_name,actor,active_lab) returning id into sid;
    return;
  end if;
  if sid is null then raise exception 'Выберите сессию преподавателя или откройте QR-код'; end if;
  select created_by,lab into owner_id,active_lab from queue_private.sessions where id = sid and ended_at is null for update;
  if not found then raise exception 'Сессия изменилась или завершена. Обновите страницу'; end if;
  if admin and action in ('end_session','next','pass','extra','restore_extra','admit_ready_extra','admit_deferred','pause_entry','pause_waiting','resume_entry','set_lab') and owner_id is distinct from actor and not superadmin then
    raise exception 'Вы не можете управлять сессией другого преподавателя';
  end if;
  if action = 'end_session' then
    update queue_private.results set outcome = 'failed',updated_at = now()
      where session_id = sid and outcome in ('current','waiting','deferred','paused');
    for target in select e.* from queue_private.entries e join queue_private.results r on r.id = e.id where r.session_id = sid loop
      delete from queue_private.entries where id = target.id;
    end loop;
    update queue_private.sessions set ended_at = now() where id = sid;

    return;
  end if;
  select coalesce(max(position),0)+1 into pos from queue_private.entries where session_id = sid;
  if action = 'join' then
    if exists(select 1 from queue_private.entries where user_id = actor and session_id = sid) then raise exception 'Вы уже записаны'; end if;
    display_name := coalesce(trim(payload->>'name'),
      (select name from queue_private.profiles where user_id = actor),
      (select raw_user_meta_data->>'display_name' from auth.users where id = actor));
    chosen_lab := (payload->>'lab')::integer;
    guest := coalesce((payload->>'off_schedule')::boolean,false);
    if display_name is null or char_length(display_name) not between 2 and 60 then raise exception 'Укажите имя и фамилию: от 2 до 60 символов'; end if;
    if chosen_lab is null or chosen_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    insert into queue_private.profiles(user_id,name) values(actor,display_name) on conflict(user_id) do update set name = excluded.name;
    select coalesce(max(retries),0) into previous_retries from queue_private.results where session_id = sid and user_id = actor and lab = chosen_lab;
    select retries,source_session_id into pending_retries,pending_source from queue_private.pending_extras where user_id = actor and lab = chosen_lab and teacher_id = owner_id;
    select coalesce(bool_or(r.had_extra),false),coalesce(bool_or(r.carried_extra),false) into was_extra,was_carried
      from queue_private.results r where r.session_id = sid and r.user_id = actor and r.lab = chosen_lab;
    if pending_retries is not null then was_extra := true; was_carried := pending_source is distinct from sid; end if;
    select coalesce(max(r.extra_count),0) into extra_total from queue_private.results r
      join queue_private.sessions s on s.id=r.session_id
      where r.user_id=actor and r.lab=chosen_lab and s.created_by=owner_id;
    extra_total := greatest(extra_total,coalesce((select extra_count from queue_private.pending_extras where user_id=actor and lab=chosen_lab and teacher_id=owner_id),0));
    previous_retries := greatest(previous_retries,coalesce(pending_retries,0));
    insert into queue_private.entries(user_id,name,lab,status,priority,position,retries,off_schedule,session_id,had_extra,carried_extra,extra_count)
      values(actor,display_name,chosen_lab,case when pending_retries is not null then 'extra' when guest then 'deferred' else 'waiting' end,
        pending_retries is null and not guest and chosen_lab = active_lab and previous_retries = 0 and not was_extra,pos,previous_retries,guest,sid,was_extra,was_carried,extra_total);
  elsif action = 'leave' then
    select * into target from queue_private.entries where user_id = actor and session_id = sid;
    if target.id is not null then
      update queue_private.results set outcome = 'left',updated_at = now() where id = target.id;
      delete from queue_private.entries where id = target.id;
    end if;
  elsif action = 'ready' then
    select * into target from queue_private.entries where user_id = actor and session_id = sid and status = 'extra';
    if target.id is null then raise exception 'Вы не на доп. задании'; end if;
    delete from queue_private.pending_extras where user_id = actor and lab = target.lab and teacher_id = owner_id;
    update queue_private.entries set status = 'waiting',can_return_extra = true,ready = not target.carried_extra,priority = false,position = pos where id = target.id;
  elsif action = 'return_extra' then
    select * into target from queue_private.entries where user_id=actor and session_id=sid
      and can_return_extra and status in ('waiting','current','deferred','paused');
    if target.id is null then raise exception 'Вернуться можно только после готовности к допзаданию'; end if;
    update queue_private.entries set status='extra',ready=false,priority=false,can_return_extra=false where id=target.id;
    insert into queue_private.pending_extras(user_id,lab,retries,teacher_id,source_session_id,extra_count)
      values(actor,target.lab,target.retries,owner_id,case when target.carried_extra then null else sid end,target.extra_count)
      on conflict(user_id,lab,teacher_id) do update set retries=excluded.retries,source_session_id=excluded.source_session_id,extra_count=excluded.extra_count;
  elsif action = 'restore_extra' then
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status in ('current','waiting','deferred','paused');
    if target.id is null then raise exception 'Студент больше не находится в очереди'; end if;
    update queue_private.entries set status='extra',ready=false,priority=false,manually_admitted=false,can_return_extra=false,
      had_extra=true,carried_extra=true,extra_count=greatest(extra_count,1) where id=target.id;
    insert into queue_private.pending_extras(user_id,lab,retries,teacher_id,source_session_id,extra_count)
      values(target.user_id,target.lab,target.retries,owner_id,null,greatest(target.extra_count,1))
      on conflict(user_id,lab,teacher_id) do update set retries=greatest(queue_private.pending_extras.retries,excluded.retries),
        source_session_id=null,extra_count=greatest(queue_private.pending_extras.extra_count,excluded.extra_count);
  elsif action = 'admit_ready_extra' then
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid
      and status in ('waiting','deferred','paused','extra') and not ready;
    if target.id is null then raise exception 'Студент уже вызван или очередь изменилась'; end if;
    update queue_private.entries set status='waiting',ready=true,priority=false,manually_admitted=true,can_return_extra=true,
      had_extra=true,carried_extra=true,extra_count=greatest(extra_count,1),position=pos where id=target.id;
    delete from queue_private.pending_extras where user_id=target.user_id and lab=target.lab and teacher_id=owner_id;
  elsif action = 'pause_entry' then
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status in ('current','waiting');
    if target.id is null then raise exception 'Студент больше не находится в очереди'; end if;
    update queue_private.entries set status='paused',ready=false,priority=false,manually_admitted=false,position=pos where id=target.id;
  elsif action = 'pause_waiting' then
    update queue_private.entries set status='paused',ready=false,priority=false,manually_admitted=false where session_id=sid and status='waiting';
  elsif action = 'resume_entry' then
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status='paused';
    if target.id is null then raise exception 'Студент больше не находится в ожидании'; end if;
    update queue_private.entries set status='waiting',ready=false,priority=false,manually_admitted=true,position=pos where id=target.id;
  elsif action = 'admit_deferred' then
    if exists(select 1 from queue_private.entries where session_id=sid and status='waiting') then
      raise exception 'Сначала дождитесь освобождения очереди';
    end if;
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status='deferred';
    if target.id is null then raise exception 'Студент больше не ожидает допуска в этой сессии'; end if;
    update queue_private.entries set status='waiting',manually_admitted=true,ready=false,priority=false,position=pos where id=target.id;
  elsif action = 'set_lab' then
    chosen_lab := (payload->>'lab')::integer;
    if chosen_lab is null or chosen_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    update queue_private.sessions set lab = chosen_lab where id = sid;
  elsif action in ('next','pass','extra') then
    select * into target from queue_private.entries where session_id = sid and status = 'current';
    if target.id is distinct from (payload->>'current_id')::uuid then raise exception 'Очередь изменилась. Обновите страницу и повторите действие'; end if;
    if target.id is not null then
      if action = 'pass' then
        delete from queue_private.pending_extras where user_id = target.user_id and lab = target.lab and teacher_id = owner_id;
        update queue_private.results set outcome = 'passed',first_try_pass = (
          target.retries=0 and target.extra_count=0 and not target.had_extra and not exists(
            select 1 from queue_private.results prior join queue_private.sessions s on s.id=prior.session_id
            where prior.user_id=target.user_id and prior.lab=target.lab and s.created_by=owner_id and prior.id<>target.id
              and (prior.outcome in ('failed','passed') or prior.retries>0 or prior.had_extra)
          )),updated_at = now() where id = target.id;
        delete from queue_private.entries where id = target.id;
      else
        update queue_private.entries set manually_admitted=(action = 'next' and target.off_schedule),can_return_extra=false,status = case when action = 'extra' then 'extra' else 'waiting' end,
          extra_count = extra_count + case when action = 'extra' then 1 else 0 end,
          had_extra = queue_private.entries.had_extra or action = 'extra',carried_extra = case when action = 'extra' then false else queue_private.entries.carried_extra end,
          retries = retries + case when action = 'next' then 1 else 0 end,ready = false,priority = false,position = pos where id = target.id;
      end if;
    end if;
  else raise exception 'Неизвестное действие';
  end if;

  if action = 'extra' and target.id is not null then
    insert into queue_private.pending_extras(user_id,lab,retries,teacher_id,source_session_id,extra_count) values(target.user_id,target.lab,target.retries,owner_id,sid,target.extra_count+1)
      on conflict(user_id,lab,teacher_id) do update set retries = excluded.retries,source_session_id = excluded.source_session_id,extra_count = excluded.extra_count;
  end if;

  -- Hold guests until scheduled students leave the active queue. Returned extras keep their priority. Never interrupt current.
  if exists(select 1 from queue_private.entries where session_id = sid and not off_schedule and status in ('current','waiting')) then
    update queue_private.entries set status = 'deferred'
      where session_id = sid and off_schedule and status = 'waiting' and not ready and not manually_admitted;
  end if;
  -- Keep ready extras first, then initial lab priority, then FIFO (including repeat turns).
  pos := 0;
  for target in select * from queue_private.entries where session_id = sid and status = 'waiting' order by
    case when ready then 0 else 1 end,
    case when not off_schedule and retries = 0 and priority then 0 else 1 end,position,id
  loop
    pos := pos + 1;
    update queue_private.entries set position = pos where id = target.id;
  end loop;
  perform queue_private.promote_available(sid);
  insert into queue_private.results(id,session_id,name,lab,retries,outcome,user_id,off_schedule,had_extra,carried_extra,extra_count)
    select id,sid,name,lab,retries,status,user_id,off_schedule,had_extra,carried_extra,extra_count from queue_private.entries where session_id = sid
    on conflict(id) do update set retries = excluded.retries,outcome = excluded.outcome,off_schedule = excluded.off_schedule,had_extra = excluded.had_extra,carried_extra = excluded.carried_extra,extra_count = excluded.extra_count,updated_at = now();
end;
$$;
revoke all on function public.queue_action(text,jsonb) from public,anon;
grant execute on function public.queue_action(text,jsonb) to authenticated;

commit;

-- Repair first-attempt priority after legacy session creation.
-- Set the initial lab in the same transaction that opens a session.
begin;
create or replace function public.queue_action(action text,payload jsonb default '{}'::jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  sid uuid;
  active_lab integer;
  admin boolean;
  owner_id uuid;
  superadmin boolean;
  target queue_private.entries;
  display_name text;
  chosen_lab integer;
  guest boolean;
  previous_retries integer;
  pending_retries integer;
  pending_source uuid;
  extra_total integer;
  was_extra boolean;
  was_carried boolean;
  pos bigint;
  group_name text;
  new_date date;
begin
  if actor is null or not exists(select 1 from auth.users where id = actor and not coalesce(is_anonymous,false)) then
    raise exception 'Войдите в аккаунт по логину и паролю';
  end if;
  sid := (payload->>'session_id')::uuid;
  select exists(select 1 from queue_private.admins where user_id = actor) into admin;
  select exists(select 1 from queue_private.superadmins where user_id = actor) into superadmin;
  if action in ('create_session','end_session','next','pass','extra','restore_extra','admit_ready_extra','admit_deferred','pause_entry','pause_waiting','resume_entry','set_lab') and not admin then
    raise exception 'Доступ только преподавателю';
  end if;
  if action = 'create_session' then
    perform pg_advisory_xact_lock(hashtextextended(actor::text,0));
    if exists(select 1 from queue_private.sessions where created_by = actor and ended_at is null) then raise exception 'Сначала завершите текущую сессию'; end if;
    new_date := (payload->>'date')::date;
    group_name := trim(payload->>'group');
    if new_date is null or group_name is null or char_length(group_name) not between 1 and 60 then
      raise exception 'Укажите дату и группу (до 60 символов)';
    end if;
    active_lab := coalesce((payload->>'lab')::integer,6);
    if active_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    insert into queue_private.sessions(date,"group",created_by,lab) values(new_date,group_name,actor,active_lab) returning id into sid;
    return;
  end if;
  if sid is null then raise exception 'Выберите сессию преподавателя или откройте QR-код'; end if;
  select created_by,lab into owner_id,active_lab from queue_private.sessions where id = sid and ended_at is null for update;
  if not found then raise exception 'Сессия изменилась или завершена. Обновите страницу'; end if;
  if admin and action in ('end_session','next','pass','extra','restore_extra','admit_ready_extra','admit_deferred','pause_entry','pause_waiting','resume_entry','set_lab') and owner_id is distinct from actor and not superadmin then
    raise exception 'Вы не можете управлять сессией другого преподавателя';
  end if;
  if action = 'end_session' then
    update queue_private.results set outcome = 'failed',updated_at = now()
      where session_id = sid and outcome in ('current','waiting','deferred','paused');
    for target in select e.* from queue_private.entries e join queue_private.results r on r.id = e.id where r.session_id = sid loop
      delete from queue_private.entries where id = target.id;
    end loop;
    update queue_private.sessions set ended_at = now() where id = sid;

    return;
  end if;
  select coalesce(max(position),0)+1 into pos from queue_private.entries where session_id = sid;
  if action = 'join' then
    if exists(select 1 from queue_private.entries where user_id = actor and session_id = sid) then raise exception 'Вы уже записаны'; end if;
    display_name := coalesce(trim(payload->>'name'),
      (select name from queue_private.profiles where user_id = actor),
      (select raw_user_meta_data->>'display_name' from auth.users where id = actor));
    chosen_lab := (payload->>'lab')::integer;
    guest := coalesce((payload->>'off_schedule')::boolean,false);
    if display_name is null or char_length(display_name) not between 2 and 60 then raise exception 'Укажите имя и фамилию: от 2 до 60 символов'; end if;
    if chosen_lab is null or chosen_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    insert into queue_private.profiles(user_id,name) values(actor,display_name) on conflict(user_id) do update set name = excluded.name;
    select coalesce(max(retries),0) into previous_retries from queue_private.results where session_id = sid and user_id = actor and lab = chosen_lab;
    select retries,source_session_id into pending_retries,pending_source from queue_private.pending_extras where user_id = actor and lab = chosen_lab and teacher_id = owner_id;
    select coalesce(bool_or(r.had_extra),false),coalesce(bool_or(r.carried_extra),false) into was_extra,was_carried
      from queue_private.results r where r.session_id = sid and r.user_id = actor and r.lab = chosen_lab;
    if pending_retries is not null then was_extra := true; was_carried := pending_source is distinct from sid; end if;
    select coalesce(max(r.extra_count),0) into extra_total from queue_private.results r
      join queue_private.sessions s on s.id=r.session_id
      where r.user_id=actor and r.lab=chosen_lab and s.created_by=owner_id;
    extra_total := greatest(extra_total,coalesce((select extra_count from queue_private.pending_extras where user_id=actor and lab=chosen_lab and teacher_id=owner_id),0));
    previous_retries := greatest(previous_retries,coalesce(pending_retries,0));
    insert into queue_private.entries(user_id,name,lab,status,priority,position,retries,off_schedule,session_id,had_extra,carried_extra,extra_count)
      values(actor,display_name,chosen_lab,case when pending_retries is not null then 'extra' when guest then 'deferred' else 'waiting' end,
        pending_retries is null and not guest and chosen_lab = active_lab and previous_retries = 0 and not was_extra,pos,previous_retries,guest,sid,was_extra,was_carried,extra_total);
  elsif action = 'leave' then
    select * into target from queue_private.entries where user_id = actor and session_id = sid;
    if target.id is not null then
      update queue_private.results set outcome = 'left',updated_at = now() where id = target.id;
      delete from queue_private.entries where id = target.id;
    end if;
  elsif action = 'ready' then
    select * into target from queue_private.entries where user_id = actor and session_id = sid and status = 'extra';
    if target.id is null then raise exception 'Вы не на доп. задании'; end if;
    delete from queue_private.pending_extras where user_id = actor and lab = target.lab and teacher_id = owner_id;
    update queue_private.entries set status = 'waiting',can_return_extra = true,ready = not target.carried_extra,priority = false,position = pos where id = target.id;
  elsif action = 'return_extra' then
    select * into target from queue_private.entries where user_id=actor and session_id=sid
      and can_return_extra and status in ('waiting','current','deferred','paused');
    if target.id is null then raise exception 'Вернуться можно только после готовности к допзаданию'; end if;
    update queue_private.entries set status='extra',ready=false,priority=false,can_return_extra=false where id=target.id;
    insert into queue_private.pending_extras(user_id,lab,retries,teacher_id,source_session_id,extra_count)
      values(actor,target.lab,target.retries,owner_id,case when target.carried_extra then null else sid end,target.extra_count)
      on conflict(user_id,lab,teacher_id) do update set retries=excluded.retries,source_session_id=excluded.source_session_id,extra_count=excluded.extra_count;
  elsif action = 'restore_extra' then
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status in ('current','waiting','deferred','paused');
    if target.id is null then raise exception 'Студент больше не находится в очереди'; end if;
    update queue_private.entries set status='extra',ready=false,priority=false,manually_admitted=false,can_return_extra=false,
      had_extra=true,carried_extra=true,extra_count=greatest(extra_count,1) where id=target.id;
    insert into queue_private.pending_extras(user_id,lab,retries,teacher_id,source_session_id,extra_count)
      values(target.user_id,target.lab,target.retries,owner_id,null,greatest(target.extra_count,1))
      on conflict(user_id,lab,teacher_id) do update set retries=greatest(queue_private.pending_extras.retries,excluded.retries),
        source_session_id=null,extra_count=greatest(queue_private.pending_extras.extra_count,excluded.extra_count);
  elsif action = 'admit_ready_extra' then
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid
      and status in ('waiting','deferred','paused','extra') and not ready;
    if target.id is null then raise exception 'Студент уже вызван или очередь изменилась'; end if;
    update queue_private.entries set status='waiting',ready=true,priority=false,manually_admitted=true,can_return_extra=true,
      had_extra=true,carried_extra=true,extra_count=greatest(extra_count,1),position=pos where id=target.id;
    delete from queue_private.pending_extras where user_id=target.user_id and lab=target.lab and teacher_id=owner_id;
  elsif action = 'pause_entry' then
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status in ('current','waiting');
    if target.id is null then raise exception 'Студент больше не находится в очереди'; end if;
    update queue_private.entries set status='paused',ready=false,priority=false,manually_admitted=false,position=pos where id=target.id;
  elsif action = 'pause_waiting' then
    update queue_private.entries set status='paused',ready=false,priority=false,manually_admitted=false where session_id=sid and status='waiting';
  elsif action = 'resume_entry' then
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status='paused';
    if target.id is null then raise exception 'Студент больше не находится в ожидании'; end if;
    update queue_private.entries set status='waiting',ready=false,priority=false,manually_admitted=true,position=pos where id=target.id;
  elsif action = 'admit_deferred' then
    if exists(select 1 from queue_private.entries where session_id=sid and status='waiting') then
      raise exception 'Сначала дождитесь освобождения очереди';
    end if;
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status='deferred';
    if target.id is null then raise exception 'Студент больше не ожидает допуска в этой сессии'; end if;
    update queue_private.entries set status='waiting',manually_admitted=true,ready=false,priority=false,position=pos where id=target.id;
  elsif action = 'set_lab' then
    chosen_lab := (payload->>'lab')::integer;
    if chosen_lab is null or chosen_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    update queue_private.sessions set lab = chosen_lab where id = sid;
  elsif action in ('next','pass','extra') then
    select * into target from queue_private.entries where session_id = sid and status = 'current';
    if target.id is distinct from (payload->>'current_id')::uuid then raise exception 'Очередь изменилась. Обновите страницу и повторите действие'; end if;
    if target.id is not null then
      if action = 'pass' then
        delete from queue_private.pending_extras where user_id = target.user_id and lab = target.lab and teacher_id = owner_id;
        update queue_private.results set outcome = 'passed',first_try_pass = (
          target.retries=0 and target.extra_count=0 and not target.had_extra and not exists(
            select 1 from queue_private.results prior join queue_private.sessions s on s.id=prior.session_id
            where prior.user_id=target.user_id and prior.lab=target.lab and s.created_by=owner_id and prior.id<>target.id
              and (prior.outcome in ('failed','passed') or prior.retries>0 or prior.had_extra)
          )),updated_at = now() where id = target.id;
        delete from queue_private.entries where id = target.id;
      else
        update queue_private.entries set manually_admitted=(action = 'next' and target.off_schedule),can_return_extra=false,status = case when action = 'extra' then 'extra' else 'waiting' end,
          extra_count = extra_count + case when action = 'extra' then 1 else 0 end,
          had_extra = queue_private.entries.had_extra or action = 'extra',carried_extra = case when action = 'extra' then false else queue_private.entries.carried_extra end,
          retries = retries + case when action = 'next' then 1 else 0 end,ready = false,priority = false,position = pos where id = target.id;
      end if;
    end if;
  else raise exception 'Неизвестное действие';
  end if;

  if action = 'extra' and target.id is not null then
    insert into queue_private.pending_extras(user_id,lab,retries,teacher_id,source_session_id,extra_count) values(target.user_id,target.lab,target.retries,owner_id,sid,target.extra_count+1)
      on conflict(user_id,lab,teacher_id) do update set retries = excluded.retries,source_session_id = excluded.source_session_id,extra_count = excluded.extra_count;
  end if;

  -- Hold guests until scheduled students leave the active queue. Returned extras keep their priority. Never interrupt current.
  if exists(select 1 from queue_private.entries where session_id = sid and not off_schedule and status in ('current','waiting')) then
    update queue_private.entries set status = 'deferred'
      where session_id = sid and off_schedule and status = 'waiting' and not ready and not manually_admitted;
  end if;
  -- Keep ready extras first, then initial lab priority, then FIFO (including repeat turns).
  pos := 0;
  for target in select * from queue_private.entries where session_id = sid and status = 'waiting' order by
    case when ready then 0 else 1 end,
    case when not off_schedule and retries = 0 and priority then 0 else 1 end,position,id
  loop
    pos := pos + 1;
    update queue_private.entries set position = pos where id = target.id;
  end loop;
  perform queue_private.promote_available(sid);
  insert into queue_private.results(id,session_id,name,lab,retries,outcome,user_id,off_schedule,had_extra,carried_extra,extra_count)
    select id,sid,name,lab,retries,status,user_id,off_schedule,had_extra,carried_extra,extra_count from queue_private.entries where session_id = sid
    on conflict(id) do update set retries = excluded.retries,outcome = excluded.outcome,off_schedule = excluded.off_schedule,had_extra = excluded.had_extra,carried_extra = excluded.carried_extra,extra_count = excluded.extra_count,updated_at = now();
end;
$$;
revoke all on function public.queue_action(text,jsonb) from public,anon;
grant execute on function public.queue_action(text,jsonb) to authenticated;



-- Restore eligible initial waiting entries without undoing explicit admission/resume decisions.
do $$
declare selected uuid; n bigint; entry_id uuid;
begin
  for selected in select id from queue_private.sessions where ended_at is null order by id for update loop
    update queue_private.entries e set priority=true from queue_private.sessions s
      where s.id=selected and e.session_id=s.id and e.status='waiting' and e.lab=s.lab
        and not e.off_schedule and e.retries=0 and not e.had_extra and not e.carried_extra
        and e.extra_count=0 and not e.ready and not e.manually_admitted;
    n:=0;
    for entry_id in select id from queue_private.entries where session_id=selected and status='waiting'
      order by case when ready then 0 else 1 end,case when not off_schedule and retries=0 and priority then 0 else 1 end,position,id loop
      n:=n+1;update queue_private.entries set position=n where id=entry_id;
    end loop;
  end loop;
end;
$$;
commit;

-- Recalculate waiting priorities on active lab changes.
-- Set the initial lab in the same transaction that opens a session.
begin;
create or replace function public.queue_action(action text,payload jsonb default '{}'::jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  sid uuid;
  active_lab integer;
  admin boolean;
  owner_id uuid;
  superadmin boolean;
  target queue_private.entries;
  display_name text;
  chosen_lab integer;
  guest boolean;
  previous_retries integer;
  pending_retries integer;
  pending_source uuid;
  extra_total integer;
  was_extra boolean;
  was_carried boolean;
  pos bigint;
  group_name text;
  new_date date;
begin
  if actor is null or not exists(select 1 from auth.users where id = actor and not coalesce(is_anonymous,false)) then
    raise exception 'Войдите в аккаунт по логину и паролю';
  end if;
  sid := (payload->>'session_id')::uuid;
  select exists(select 1 from queue_private.admins where user_id = actor) into admin;
  select exists(select 1 from queue_private.superadmins where user_id = actor) into superadmin;
  if action in ('create_session','end_session','next','pass','extra','restore_extra','admit_ready_extra','admit_deferred','pause_entry','pause_waiting','resume_entry','set_lab') and not admin then
    raise exception 'Доступ только преподавателю';
  end if;
  if action = 'create_session' then
    perform pg_advisory_xact_lock(hashtextextended(actor::text,0));
    if exists(select 1 from queue_private.sessions where created_by = actor and ended_at is null) then raise exception 'Сначала завершите текущую сессию'; end if;
    new_date := (payload->>'date')::date;
    group_name := trim(payload->>'group');
    if new_date is null or group_name is null or char_length(group_name) not between 1 and 60 then
      raise exception 'Укажите дату и группу (до 60 символов)';
    end if;
    active_lab := coalesce((payload->>'lab')::integer,6);
    if active_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    insert into queue_private.sessions(date,"group",created_by,lab) values(new_date,group_name,actor,active_lab) returning id into sid;
    return;
  end if;
  if sid is null then raise exception 'Выберите сессию преподавателя или откройте QR-код'; end if;
  select created_by,lab into owner_id,active_lab from queue_private.sessions where id = sid and ended_at is null for update;
  if not found then raise exception 'Сессия изменилась или завершена. Обновите страницу'; end if;
  if admin and action in ('end_session','next','pass','extra','restore_extra','admit_ready_extra','admit_deferred','pause_entry','pause_waiting','resume_entry','set_lab') and owner_id is distinct from actor and not superadmin then
    raise exception 'Вы не можете управлять сессией другого преподавателя';
  end if;
  if action = 'end_session' then
    update queue_private.results set outcome = 'failed',updated_at = now()
      where session_id = sid and outcome in ('current','waiting','deferred','paused');
    for target in select e.* from queue_private.entries e join queue_private.results r on r.id = e.id where r.session_id = sid loop
      delete from queue_private.entries where id = target.id;
    end loop;
    update queue_private.sessions set ended_at = now() where id = sid;

    return;
  end if;
  select coalesce(max(position),0)+1 into pos from queue_private.entries where session_id = sid;
  if action = 'join' then
    if exists(select 1 from queue_private.entries where user_id = actor and session_id = sid) then raise exception 'Вы уже записаны'; end if;
    display_name := coalesce(trim(payload->>'name'),
      (select name from queue_private.profiles where user_id = actor),
      (select raw_user_meta_data->>'display_name' from auth.users where id = actor));
    chosen_lab := (payload->>'lab')::integer;
    guest := coalesce((payload->>'off_schedule')::boolean,false);
    if display_name is null or char_length(display_name) not between 2 and 60 then raise exception 'Укажите имя и фамилию: от 2 до 60 символов'; end if;
    if chosen_lab is null or chosen_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    insert into queue_private.profiles(user_id,name) values(actor,display_name) on conflict(user_id) do update set name = excluded.name;
    select coalesce(max(retries),0) into previous_retries from queue_private.results where session_id = sid and user_id = actor and lab = chosen_lab;
    select retries,source_session_id into pending_retries,pending_source from queue_private.pending_extras where user_id = actor and lab = chosen_lab and teacher_id = owner_id;
    select coalesce(bool_or(r.had_extra),false),coalesce(bool_or(r.carried_extra),false) into was_extra,was_carried
      from queue_private.results r where r.session_id = sid and r.user_id = actor and r.lab = chosen_lab;
    if pending_retries is not null then was_extra := true; was_carried := pending_source is distinct from sid; end if;
    select coalesce(max(r.extra_count),0) into extra_total from queue_private.results r
      join queue_private.sessions s on s.id=r.session_id
      where r.user_id=actor and r.lab=chosen_lab and s.created_by=owner_id;
    extra_total := greatest(extra_total,coalesce((select extra_count from queue_private.pending_extras where user_id=actor and lab=chosen_lab and teacher_id=owner_id),0));
    previous_retries := greatest(previous_retries,coalesce(pending_retries,0));
    insert into queue_private.entries(user_id,name,lab,status,priority,position,retries,off_schedule,session_id,had_extra,carried_extra,extra_count)
      values(actor,display_name,chosen_lab,case when pending_retries is not null then 'extra' when guest then 'deferred' else 'waiting' end,
        pending_retries is null and not guest and chosen_lab = active_lab and previous_retries = 0 and not was_extra,pos,previous_retries,guest,sid,was_extra,was_carried,extra_total);
  elsif action = 'leave' then
    select * into target from queue_private.entries where user_id = actor and session_id = sid;
    if target.id is not null then
      update queue_private.results set outcome = 'left',updated_at = now() where id = target.id;
      delete from queue_private.entries where id = target.id;
    end if;
  elsif action = 'ready' then
    select * into target from queue_private.entries where user_id = actor and session_id = sid and status = 'extra';
    if target.id is null then raise exception 'Вы не на доп. задании'; end if;
    delete from queue_private.pending_extras where user_id = actor and lab = target.lab and teacher_id = owner_id;
    update queue_private.entries set status = 'waiting',can_return_extra = true,ready = not target.carried_extra,priority = false,position = pos where id = target.id;
  elsif action = 'return_extra' then
    select * into target from queue_private.entries where user_id=actor and session_id=sid
      and can_return_extra and status in ('waiting','current','deferred','paused');
    if target.id is null then raise exception 'Вернуться можно только после готовности к допзаданию'; end if;
    update queue_private.entries set status='extra',ready=false,priority=false,can_return_extra=false where id=target.id;
    insert into queue_private.pending_extras(user_id,lab,retries,teacher_id,source_session_id,extra_count)
      values(actor,target.lab,target.retries,owner_id,case when target.carried_extra then null else sid end,target.extra_count)
      on conflict(user_id,lab,teacher_id) do update set retries=excluded.retries,source_session_id=excluded.source_session_id,extra_count=excluded.extra_count;
  elsif action = 'restore_extra' then
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status in ('current','waiting','deferred','paused');
    if target.id is null then raise exception 'Студент больше не находится в очереди'; end if;
    update queue_private.entries set status='extra',ready=false,priority=false,manually_admitted=false,can_return_extra=false,
      had_extra=true,carried_extra=true,extra_count=greatest(extra_count,1) where id=target.id;
    insert into queue_private.pending_extras(user_id,lab,retries,teacher_id,source_session_id,extra_count)
      values(target.user_id,target.lab,target.retries,owner_id,null,greatest(target.extra_count,1))
      on conflict(user_id,lab,teacher_id) do update set retries=greatest(queue_private.pending_extras.retries,excluded.retries),
        source_session_id=null,extra_count=greatest(queue_private.pending_extras.extra_count,excluded.extra_count);
  elsif action = 'admit_ready_extra' then
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid
      and status in ('waiting','deferred','paused','extra') and not ready;
    if target.id is null then raise exception 'Студент уже вызван или очередь изменилась'; end if;
    update queue_private.entries set status='waiting',ready=true,priority=false,manually_admitted=true,can_return_extra=true,
      had_extra=true,carried_extra=true,extra_count=greatest(extra_count,1),position=pos where id=target.id;
    delete from queue_private.pending_extras where user_id=target.user_id and lab=target.lab and teacher_id=owner_id;
  elsif action = 'pause_entry' then
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status in ('current','waiting');
    if target.id is null then raise exception 'Студент больше не находится в очереди'; end if;
    update queue_private.entries set status='paused',ready=false,priority=false,manually_admitted=false,position=pos where id=target.id;
  elsif action = 'pause_waiting' then
    update queue_private.entries set status='paused',ready=false,priority=false,manually_admitted=false where session_id=sid and status='waiting';
  elsif action = 'resume_entry' then
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status='paused';
    if target.id is null then raise exception 'Студент больше не находится в ожидании'; end if;
    update queue_private.entries set status='waiting',ready=false,priority=false,manually_admitted=true,position=pos where id=target.id;
  elsif action = 'admit_deferred' then
    if exists(select 1 from queue_private.entries where session_id=sid and status='waiting') then
      raise exception 'Сначала дождитесь освобождения очереди';
    end if;
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status='deferred';
    if target.id is null then raise exception 'Студент больше не ожидает допуска в этой сессии'; end if;
    update queue_private.entries set status='waiting',manually_admitted=true,ready=false,priority=false,position=pos where id=target.id;
  elsif action = 'set_lab' then
    chosen_lab := (payload->>'lab')::integer;
    if chosen_lab is null or chosen_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    update queue_private.sessions set lab = chosen_lab where id = sid;
    update queue_private.entries set priority=(lab=chosen_lab and not off_schedule and retries=0 and not had_extra
      and not carried_extra and extra_count=0 and not ready and not manually_admitted)
      where session_id=sid and status='waiting';
  elsif action in ('next','pass','extra') then
    select * into target from queue_private.entries where session_id = sid and status = 'current';
    if target.id is distinct from (payload->>'current_id')::uuid then raise exception 'Очередь изменилась. Обновите страницу и повторите действие'; end if;
    if target.id is not null then
      if action = 'pass' then
        delete from queue_private.pending_extras where user_id = target.user_id and lab = target.lab and teacher_id = owner_id;
        update queue_private.results set outcome = 'passed',first_try_pass = (
          target.retries=0 and target.extra_count=0 and not target.had_extra and not exists(
            select 1 from queue_private.results prior join queue_private.sessions s on s.id=prior.session_id
            where prior.user_id=target.user_id and prior.lab=target.lab and s.created_by=owner_id and prior.id<>target.id
              and (prior.outcome in ('failed','passed') or prior.retries>0 or prior.had_extra)
          )),updated_at = now() where id = target.id;
        delete from queue_private.entries where id = target.id;
      else
        update queue_private.entries set manually_admitted=(action = 'next' and target.off_schedule),can_return_extra=false,status = case when action = 'extra' then 'extra' else 'waiting' end,
          extra_count = extra_count + case when action = 'extra' then 1 else 0 end,
          had_extra = queue_private.entries.had_extra or action = 'extra',carried_extra = case when action = 'extra' then false else queue_private.entries.carried_extra end,
          retries = retries + case when action = 'next' then 1 else 0 end,ready = false,priority = false,position = pos where id = target.id;
      end if;
    end if;
  else raise exception 'Неизвестное действие';
  end if;

  if action = 'extra' and target.id is not null then
    insert into queue_private.pending_extras(user_id,lab,retries,teacher_id,source_session_id,extra_count) values(target.user_id,target.lab,target.retries,owner_id,sid,target.extra_count+1)
      on conflict(user_id,lab,teacher_id) do update set retries = excluded.retries,source_session_id = excluded.source_session_id,extra_count = excluded.extra_count;
  end if;

  -- Hold guests until scheduled students leave the active queue. Returned extras keep their priority. Never interrupt current.
  if exists(select 1 from queue_private.entries where session_id = sid and not off_schedule and status in ('current','waiting')) then
    update queue_private.entries set status = 'deferred'
      where session_id = sid and off_schedule and status = 'waiting' and not ready and not manually_admitted;
  end if;
  -- Keep ready extras first, then initial lab priority, then FIFO (including repeat turns).
  pos := 0;
  for target in select * from queue_private.entries where session_id = sid and status = 'waiting' order by
    case when ready then 0 else 1 end,
    case when not off_schedule and retries = 0 and priority then 0 else 1 end,position,id
  loop
    pos := pos + 1;
    update queue_private.entries set position = pos where id = target.id;
  end loop;
  perform queue_private.promote_available(sid);
  insert into queue_private.results(id,session_id,name,lab,retries,outcome,user_id,off_schedule,had_extra,carried_extra,extra_count)
    select id,sid,name,lab,retries,status,user_id,off_schedule,had_extra,carried_extra,extra_count from queue_private.entries where session_id = sid
    on conflict(id) do update set retries = excluded.retries,outcome = excluded.outcome,off_schedule = excluded.off_schedule,had_extra = excluded.had_extra,carried_extra = excluded.carried_extra,extra_count = excluded.extra_count,updated_at = now();
end;
$$;
revoke all on function public.queue_action(text,jsonb) from public,anon;
grant execute on function public.queue_action(text,jsonb) to authenticated;




-- Reconcile active waiting queues with each session's current lab.
do $$
declare selected uuid; n bigint; entry_id uuid;
begin
  for selected in select id from queue_private.sessions where ended_at is null order by id for update loop
    update queue_private.entries e set priority=(e.lab=s.lab and not e.off_schedule and e.retries=0 and not e.had_extra
      and not e.carried_extra and e.extra_count=0 and not e.ready and not e.manually_admitted)
      from queue_private.sessions s where s.id=selected and e.session_id=s.id and e.status='waiting';
    n:=0;
    for entry_id in select id from queue_private.entries where session_id=selected and status='waiting'
      order by case when ready then 0 else 1 end,case when not off_schedule and retries=0 and priority then 0 else 1 end,position,id loop
      n:=n+1;update queue_private.entries set position=n where id=entry_id;
    end loop;
  end loop;
end;
$$;
commit;

-- Manual admission into a busy queue.
-- Set the initial lab in the same transaction that opens a session.
begin;
alter table queue_private.entries add column if not exists called_next boolean not null default false;
create or replace function public.queue_action(action text,payload jsonb default '{}'::jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  sid uuid;
  active_lab integer;
  admin boolean;
  owner_id uuid;
  superadmin boolean;
  target queue_private.entries;
  display_name text;
  chosen_lab integer;
  guest boolean;
  previous_retries integer;
  pending_retries integer;
  pending_source uuid;
  extra_total integer;
  was_extra boolean;
  was_carried boolean;
  pos bigint;
  group_name text;
  new_date date;
begin
  if actor is null or not exists(select 1 from auth.users where id = actor and not coalesce(is_anonymous,false)) then
    raise exception 'Войдите в аккаунт по логину и паролю';
  end if;
  sid := (payload->>'session_id')::uuid;
  select exists(select 1 from queue_private.admins where user_id = actor) into admin;
  select exists(select 1 from queue_private.superadmins where user_id = actor) into superadmin;
  if action in ('create_session','end_session','next','pass','extra','restore_extra','admit_ready_extra','admit_deferred','pause_entry','pause_waiting','resume_entry','set_lab') and not admin then
    raise exception 'Доступ только преподавателю';
  end if;
  if action = 'create_session' then
    perform pg_advisory_xact_lock(hashtextextended(actor::text,0));
    if exists(select 1 from queue_private.sessions where created_by = actor and ended_at is null) then raise exception 'Сначала завершите текущую сессию'; end if;
    new_date := (payload->>'date')::date;
    group_name := trim(payload->>'group');
    if new_date is null or group_name is null or char_length(group_name) not between 1 and 60 then
      raise exception 'Укажите дату и группу (до 60 символов)';
    end if;
    active_lab := coalesce((payload->>'lab')::integer,6);
    if active_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    insert into queue_private.sessions(date,"group",created_by,lab) values(new_date,group_name,actor,active_lab) returning id into sid;
    return;
  end if;
  if sid is null then raise exception 'Выберите сессию преподавателя или откройте QR-код'; end if;
  select created_by,lab into owner_id,active_lab from queue_private.sessions where id = sid and ended_at is null for update;
  if not found then raise exception 'Сессия изменилась или завершена. Обновите страницу'; end if;
  if admin and action in ('end_session','next','pass','extra','restore_extra','admit_ready_extra','admit_deferred','pause_entry','pause_waiting','resume_entry','set_lab') and owner_id is distinct from actor and not superadmin then
    raise exception 'Вы не можете управлять сессией другого преподавателя';
  end if;
  if action = 'end_session' then
    update queue_private.results set outcome = 'failed',updated_at = now()
      where session_id = sid and outcome in ('current','waiting','deferred','paused');
    for target in select e.* from queue_private.entries e join queue_private.results r on r.id = e.id where r.session_id = sid loop
      delete from queue_private.entries where id = target.id;
    end loop;
    update queue_private.sessions set ended_at = now() where id = sid;

    return;
  end if;
  select coalesce(max(position),0)+1 into pos from queue_private.entries where session_id = sid;
  if action = 'join' then
    if exists(select 1 from queue_private.entries where user_id = actor and session_id = sid) then raise exception 'Вы уже записаны'; end if;
    display_name := coalesce(trim(payload->>'name'),
      (select name from queue_private.profiles where user_id = actor),
      (select raw_user_meta_data->>'display_name' from auth.users where id = actor));
    chosen_lab := (payload->>'lab')::integer;
    guest := coalesce((payload->>'off_schedule')::boolean,false);
    if display_name is null or char_length(display_name) not between 2 and 60 then raise exception 'Укажите имя и фамилию: от 2 до 60 символов'; end if;
    if chosen_lab is null or chosen_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    insert into queue_private.profiles(user_id,name) values(actor,display_name) on conflict(user_id) do update set name = excluded.name;
    select coalesce(max(retries),0) into previous_retries from queue_private.results where session_id = sid and user_id = actor and lab = chosen_lab;
    select retries,source_session_id into pending_retries,pending_source from queue_private.pending_extras where user_id = actor and lab = chosen_lab and teacher_id = owner_id;
    select coalesce(bool_or(r.had_extra),false),coalesce(bool_or(r.carried_extra),false) into was_extra,was_carried
      from queue_private.results r where r.session_id = sid and r.user_id = actor and r.lab = chosen_lab;
    if pending_retries is not null then was_extra := true; was_carried := pending_source is distinct from sid; end if;
    select coalesce(max(r.extra_count),0) into extra_total from queue_private.results r
      join queue_private.sessions s on s.id=r.session_id
      where r.user_id=actor and r.lab=chosen_lab and s.created_by=owner_id;
    extra_total := greatest(extra_total,coalesce((select extra_count from queue_private.pending_extras where user_id=actor and lab=chosen_lab and teacher_id=owner_id),0));
    previous_retries := greatest(previous_retries,coalesce(pending_retries,0));
    insert into queue_private.entries(user_id,name,lab,status,priority,position,retries,off_schedule,session_id,had_extra,carried_extra,extra_count)
      values(actor,display_name,chosen_lab,case when pending_retries is not null then 'extra' when guest then 'deferred' else 'waiting' end,
        pending_retries is null and not guest and chosen_lab = active_lab and previous_retries = 0 and not was_extra,pos,previous_retries,guest,sid,was_extra,was_carried,extra_total);
  elsif action = 'leave' then
    select * into target from queue_private.entries where user_id = actor and session_id = sid;
    if target.id is not null then
      update queue_private.results set outcome = 'left',updated_at = now() where id = target.id;
      delete from queue_private.entries where id = target.id;
    end if;
  elsif action = 'ready' then
    select * into target from queue_private.entries where user_id = actor and session_id = sid and status = 'extra';
    if target.id is null then raise exception 'Вы не на доп. задании'; end if;
    delete from queue_private.pending_extras where user_id = actor and lab = target.lab and teacher_id = owner_id;
    update queue_private.entries set status = 'waiting',can_return_extra = true,ready = not target.carried_extra,priority = false,position = pos where id = target.id;
  elsif action = 'return_extra' then
    select * into target from queue_private.entries where user_id=actor and session_id=sid
      and can_return_extra and status in ('waiting','current','deferred','paused');
    if target.id is null then raise exception 'Вернуться можно только после готовности к допзаданию'; end if;
    update queue_private.entries set status='extra',ready=false,priority=false,can_return_extra=false where id=target.id;
    insert into queue_private.pending_extras(user_id,lab,retries,teacher_id,source_session_id,extra_count)
      values(actor,target.lab,target.retries,owner_id,case when target.carried_extra then null else sid end,target.extra_count)
      on conflict(user_id,lab,teacher_id) do update set retries=excluded.retries,source_session_id=excluded.source_session_id,extra_count=excluded.extra_count;
  elsif action = 'restore_extra' then
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status in ('current','waiting','deferred','paused');
    if target.id is null then raise exception 'Студент больше не находится в очереди'; end if;
    update queue_private.entries set status='extra',ready=false,priority=false,manually_admitted=false,can_return_extra=false,
      had_extra=true,carried_extra=true,extra_count=greatest(extra_count,1) where id=target.id;
    insert into queue_private.pending_extras(user_id,lab,retries,teacher_id,source_session_id,extra_count)
      values(target.user_id,target.lab,target.retries,owner_id,null,greatest(target.extra_count,1))
      on conflict(user_id,lab,teacher_id) do update set retries=greatest(queue_private.pending_extras.retries,excluded.retries),
        source_session_id=null,extra_count=greatest(queue_private.pending_extras.extra_count,excluded.extra_count);
  elsif action = 'admit_ready_extra' then
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid
      and status in ('waiting','deferred','paused','extra') and not ready;
    if target.id is null then raise exception 'Студент уже вызван или очередь изменилась'; end if;
    update queue_private.entries set status='waiting',ready=true,priority=false,manually_admitted=true,can_return_extra=true,
      had_extra=true,carried_extra=true,extra_count=greatest(extra_count,1),position=pos where id=target.id;
    delete from queue_private.pending_extras where user_id=target.user_id and lab=target.lab and teacher_id=owner_id;
  elsif action = 'pause_entry' then
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status in ('current','waiting');
    if target.id is null then raise exception 'Студент больше не находится в очереди'; end if;
    update queue_private.entries set status='paused',ready=false,priority=false,manually_admitted=false,position=pos where id=target.id;
  elsif action = 'pause_waiting' then
    update queue_private.entries set status='paused',ready=false,priority=false,manually_admitted=false where session_id=sid and status='waiting';
  elsif action = 'resume_entry' then
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status='paused';
    if target.id is null then raise exception 'Студент больше не находится в ожидании'; end if;
    update queue_private.entries set status='waiting',ready=false,priority=false,manually_admitted=true,position=pos where id=target.id;
  elsif action = 'admit_deferred' then
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status='deferred';
    if target.id is null then raise exception 'Студент больше не ожидает допуска в этой сессии'; end if;
    update queue_private.entries set status='waiting',manually_admitted=true,called_next=true,ready=false,priority=false,position=pos where id=target.id;
  elsif action = 'set_lab' then
    chosen_lab := (payload->>'lab')::integer;
    if chosen_lab is null or chosen_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    update queue_private.sessions set lab = chosen_lab where id = sid;
    update queue_private.entries set priority=(lab=chosen_lab and not off_schedule and retries=0 and not had_extra
      and not carried_extra and extra_count=0 and not ready and not manually_admitted)
      where session_id=sid and status='waiting';
  elsif action in ('next','pass','extra') then
    select * into target from queue_private.entries where session_id = sid and status = 'current';
    if target.id is distinct from (payload->>'current_id')::uuid then raise exception 'Очередь изменилась. Обновите страницу и повторите действие'; end if;
    if target.id is not null then
      if action = 'pass' then
        delete from queue_private.pending_extras where user_id = target.user_id and lab = target.lab and teacher_id = owner_id;
        update queue_private.results set outcome = 'passed',first_try_pass = (
          target.retries=0 and target.extra_count=0 and not target.had_extra and not exists(
            select 1 from queue_private.results prior join queue_private.sessions s on s.id=prior.session_id
            where prior.user_id=target.user_id and prior.lab=target.lab and s.created_by=owner_id and prior.id<>target.id
              and (prior.outcome in ('failed','passed') or prior.retries>0 or prior.had_extra)
          )),updated_at = now() where id = target.id;
        delete from queue_private.entries where id = target.id;
      else
        update queue_private.entries set manually_admitted=(action = 'next' and target.off_schedule),can_return_extra=false,status = case when action = 'extra' then 'extra' else 'waiting' end,
          extra_count = extra_count + case when action = 'extra' then 1 else 0 end,
          had_extra = queue_private.entries.had_extra or action = 'extra',carried_extra = case when action = 'extra' then false else queue_private.entries.carried_extra end,
          retries = retries + case when action = 'next' then 1 else 0 end,ready = false,priority = false,position = pos where id = target.id;
      end if;
    end if;
  else raise exception 'Неизвестное действие';
  end if;

  if action = 'extra' and target.id is not null then
    insert into queue_private.pending_extras(user_id,lab,retries,teacher_id,source_session_id,extra_count) values(target.user_id,target.lab,target.retries,owner_id,sid,target.extra_count+1)
      on conflict(user_id,lab,teacher_id) do update set retries = excluded.retries,source_session_id = excluded.source_session_id,extra_count = excluded.extra_count;
  end if;

  -- Hold guests until scheduled students leave the active queue. Returned extras keep their priority. Never interrupt current.
  if exists(select 1 from queue_private.entries where session_id = sid and not off_schedule and status in ('current','waiting')) then
    update queue_private.entries set status = 'deferred'
      where session_id = sid and off_schedule and status = 'waiting' and not ready and not manually_admitted;
  end if;
  -- Keep ready extras first, then initial lab priority, then FIFO (including repeat turns).
  pos := 0;
  for target in select * from queue_private.entries where session_id = sid and status = 'waiting' order by
    case when called_next then 0 when ready then 1 else 2 end,
    case when not off_schedule and retries = 0 and priority then 0 else 1 end,position,id
  loop
    pos := pos + 1;
    update queue_private.entries set position = pos where id = target.id;
  end loop;
  perform queue_private.promote_available(sid);
  update queue_private.entries set called_next=false where session_id=sid and status<>'waiting' and called_next;
  insert into queue_private.results(id,session_id,name,lab,retries,outcome,user_id,off_schedule,had_extra,carried_extra,extra_count)
    select id,sid,name,lab,retries,status,user_id,off_schedule,had_extra,carried_extra,extra_count from queue_private.entries where session_id = sid
    on conflict(id) do update set retries = excluded.retries,outcome = excluded.outcome,off_schedule = excluded.off_schedule,had_extra = excluded.had_extra,carried_extra = excluded.carried_extra,extra_count = excluded.extra_count,updated_at = now();
end;
$$;
revoke all on function public.queue_action(text,jsonb) from public,anon;
grant execute on function public.queue_action(text,jsonb) to authenticated;




commit;

-- Admit off-schedule students at the normal queue tail.
-- Set the initial lab in the same transaction that opens a session.
begin;
alter table queue_private.entries add column if not exists called_next boolean not null default false;
create or replace function public.queue_action(action text,payload jsonb default '{}'::jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  sid uuid;
  active_lab integer;
  admin boolean;
  owner_id uuid;
  superadmin boolean;
  target queue_private.entries;
  display_name text;
  chosen_lab integer;
  guest boolean;
  previous_retries integer;
  pending_retries integer;
  pending_source uuid;
  extra_total integer;
  was_extra boolean;
  was_carried boolean;
  pos bigint;
  group_name text;
  new_date date;
begin
  if actor is null or not exists(select 1 from auth.users where id = actor and not coalesce(is_anonymous,false)) then
    raise exception 'Войдите в аккаунт по логину и паролю';
  end if;
  sid := (payload->>'session_id')::uuid;
  select exists(select 1 from queue_private.admins where user_id = actor) into admin;
  select exists(select 1 from queue_private.superadmins where user_id = actor) into superadmin;
  if action in ('create_session','end_session','next','pass','extra','restore_extra','admit_ready_extra','admit_deferred','pause_entry','pause_waiting','resume_entry','set_lab') and not admin then
    raise exception 'Доступ только преподавателю';
  end if;
  if action = 'create_session' then
    perform pg_advisory_xact_lock(hashtextextended(actor::text,0));
    if exists(select 1 from queue_private.sessions where created_by = actor and ended_at is null) then raise exception 'Сначала завершите текущую сессию'; end if;
    new_date := (payload->>'date')::date;
    group_name := trim(payload->>'group');
    if new_date is null or group_name is null or char_length(group_name) not between 1 and 60 then
      raise exception 'Укажите дату и группу (до 60 символов)';
    end if;
    active_lab := coalesce((payload->>'lab')::integer,6);
    if active_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    insert into queue_private.sessions(date,"group",created_by,lab) values(new_date,group_name,actor,active_lab) returning id into sid;
    return;
  end if;
  if sid is null then raise exception 'Выберите сессию преподавателя или откройте QR-код'; end if;
  select created_by,lab into owner_id,active_lab from queue_private.sessions where id = sid and ended_at is null for update;
  if not found then raise exception 'Сессия изменилась или завершена. Обновите страницу'; end if;
  if admin and action in ('end_session','next','pass','extra','restore_extra','admit_ready_extra','admit_deferred','pause_entry','pause_waiting','resume_entry','set_lab') and owner_id is distinct from actor and not superadmin then
    raise exception 'Вы не можете управлять сессией другого преподавателя';
  end if;
  if action = 'end_session' then
    update queue_private.results set outcome = 'failed',updated_at = now()
      where session_id = sid and outcome in ('current','waiting','deferred','paused');
    for target in select e.* from queue_private.entries e join queue_private.results r on r.id = e.id where r.session_id = sid loop
      delete from queue_private.entries where id = target.id;
    end loop;
    update queue_private.sessions set ended_at = now() where id = sid;

    return;
  end if;
  select coalesce(max(position),0)+1 into pos from queue_private.entries where session_id = sid;
  if action = 'join' then
    if exists(select 1 from queue_private.entries where user_id = actor and session_id = sid) then raise exception 'Вы уже записаны'; end if;
    display_name := coalesce(trim(payload->>'name'),
      (select name from queue_private.profiles where user_id = actor),
      (select raw_user_meta_data->>'display_name' from auth.users where id = actor));
    chosen_lab := (payload->>'lab')::integer;
    guest := coalesce((payload->>'off_schedule')::boolean,false);
    if display_name is null or char_length(display_name) not between 2 and 60 then raise exception 'Укажите имя и фамилию: от 2 до 60 символов'; end if;
    if chosen_lab is null or chosen_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    insert into queue_private.profiles(user_id,name) values(actor,display_name) on conflict(user_id) do update set name = excluded.name;
    select coalesce(max(retries),0) into previous_retries from queue_private.results where session_id = sid and user_id = actor and lab = chosen_lab;
    select retries,source_session_id into pending_retries,pending_source from queue_private.pending_extras where user_id = actor and lab = chosen_lab and teacher_id = owner_id;
    select coalesce(bool_or(r.had_extra),false),coalesce(bool_or(r.carried_extra),false) into was_extra,was_carried
      from queue_private.results r where r.session_id = sid and r.user_id = actor and r.lab = chosen_lab;
    if pending_retries is not null then was_extra := true; was_carried := pending_source is distinct from sid; end if;
    select coalesce(max(r.extra_count),0) into extra_total from queue_private.results r
      join queue_private.sessions s on s.id=r.session_id
      where r.user_id=actor and r.lab=chosen_lab and s.created_by=owner_id;
    extra_total := greatest(extra_total,coalesce((select extra_count from queue_private.pending_extras where user_id=actor and lab=chosen_lab and teacher_id=owner_id),0));
    previous_retries := greatest(previous_retries,coalesce(pending_retries,0));
    insert into queue_private.entries(user_id,name,lab,status,priority,position,retries,off_schedule,session_id,had_extra,carried_extra,extra_count)
      values(actor,display_name,chosen_lab,case when pending_retries is not null then 'extra' when guest then 'deferred' else 'waiting' end,
        pending_retries is null and not guest and chosen_lab = active_lab and previous_retries = 0 and not was_extra,pos,previous_retries,guest,sid,was_extra,was_carried,extra_total);
  elsif action = 'leave' then
    select * into target from queue_private.entries where user_id = actor and session_id = sid;
    if target.id is not null then
      update queue_private.results set outcome = 'left',updated_at = now() where id = target.id;
      delete from queue_private.entries where id = target.id;
    end if;
  elsif action = 'ready' then
    select * into target from queue_private.entries where user_id = actor and session_id = sid and status = 'extra';
    if target.id is null then raise exception 'Вы не на доп. задании'; end if;
    delete from queue_private.pending_extras where user_id = actor and lab = target.lab and teacher_id = owner_id;
    update queue_private.entries set status = 'waiting',can_return_extra = true,ready = not target.carried_extra,priority = false,position = pos where id = target.id;
  elsif action = 'return_extra' then
    select * into target from queue_private.entries where user_id=actor and session_id=sid
      and can_return_extra and status in ('waiting','current','deferred','paused');
    if target.id is null then raise exception 'Вернуться можно только после готовности к допзаданию'; end if;
    update queue_private.entries set status='extra',ready=false,priority=false,can_return_extra=false where id=target.id;
    insert into queue_private.pending_extras(user_id,lab,retries,teacher_id,source_session_id,extra_count)
      values(actor,target.lab,target.retries,owner_id,case when target.carried_extra then null else sid end,target.extra_count)
      on conflict(user_id,lab,teacher_id) do update set retries=excluded.retries,source_session_id=excluded.source_session_id,extra_count=excluded.extra_count;
  elsif action = 'restore_extra' then
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status in ('current','waiting','deferred','paused');
    if target.id is null then raise exception 'Студент больше не находится в очереди'; end if;
    update queue_private.entries set status='extra',ready=false,priority=false,manually_admitted=false,can_return_extra=false,
      had_extra=true,carried_extra=true,extra_count=greatest(extra_count,1) where id=target.id;
    insert into queue_private.pending_extras(user_id,lab,retries,teacher_id,source_session_id,extra_count)
      values(target.user_id,target.lab,target.retries,owner_id,null,greatest(target.extra_count,1))
      on conflict(user_id,lab,teacher_id) do update set retries=greatest(queue_private.pending_extras.retries,excluded.retries),
        source_session_id=null,extra_count=greatest(queue_private.pending_extras.extra_count,excluded.extra_count);
  elsif action = 'admit_ready_extra' then
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid
      and status in ('waiting','deferred','paused','extra') and not ready;
    if target.id is null then raise exception 'Студент уже вызван или очередь изменилась'; end if;
    update queue_private.entries set status='waiting',ready=true,priority=false,manually_admitted=true,can_return_extra=true,
      had_extra=true,carried_extra=true,extra_count=greatest(extra_count,1),position=pos where id=target.id;
    delete from queue_private.pending_extras where user_id=target.user_id and lab=target.lab and teacher_id=owner_id;
  elsif action = 'pause_entry' then
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status in ('current','waiting');
    if target.id is null then raise exception 'Студент больше не находится в очереди'; end if;
    update queue_private.entries set status='paused',ready=false,priority=false,manually_admitted=false,position=pos where id=target.id;
  elsif action = 'pause_waiting' then
    update queue_private.entries set status='paused',ready=false,priority=false,manually_admitted=false where session_id=sid and status='waiting';
  elsif action = 'resume_entry' then
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status='paused';
    if target.id is null then raise exception 'Студент больше не находится в ожидании'; end if;
    update queue_private.entries set status='waiting',ready=false,priority=false,manually_admitted=true,position=pos where id=target.id;
  elsif action = 'admit_deferred' then
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status='deferred';
    if target.id is null then raise exception 'Студент больше не ожидает допуска в этой сессии'; end if;
    update queue_private.entries set status='waiting',manually_admitted=true,called_next=false,ready=false,priority=false,position=pos where id=target.id;
  elsif action = 'set_lab' then
    chosen_lab := (payload->>'lab')::integer;
    if chosen_lab is null or chosen_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    update queue_private.sessions set lab = chosen_lab where id = sid;
    update queue_private.entries set priority=(lab=chosen_lab and not off_schedule and retries=0 and not had_extra
      and not carried_extra and extra_count=0 and not ready and not manually_admitted)
      where session_id=sid and status='waiting';
  elsif action in ('next','pass','extra') then
    select * into target from queue_private.entries where session_id = sid and status = 'current';
    if target.id is distinct from (payload->>'current_id')::uuid then raise exception 'Очередь изменилась. Обновите страницу и повторите действие'; end if;
    if target.id is not null then
      if action = 'pass' then
        delete from queue_private.pending_extras where user_id = target.user_id and lab = target.lab and teacher_id = owner_id;
        update queue_private.results set outcome = 'passed',first_try_pass = (
          target.retries=0 and target.extra_count=0 and not target.had_extra and not exists(
            select 1 from queue_private.results prior join queue_private.sessions s on s.id=prior.session_id
            where prior.user_id=target.user_id and prior.lab=target.lab and s.created_by=owner_id and prior.id<>target.id
              and (prior.outcome in ('failed','passed') or prior.retries>0 or prior.had_extra)
          )),updated_at = now() where id = target.id;
        delete from queue_private.entries where id = target.id;
      else
        update queue_private.entries set manually_admitted=(action = 'next' and target.off_schedule),can_return_extra=false,status = case when action = 'extra' then 'extra' else 'waiting' end,
          extra_count = extra_count + case when action = 'extra' then 1 else 0 end,
          had_extra = queue_private.entries.had_extra or action = 'extra',carried_extra = case when action = 'extra' then false else queue_private.entries.carried_extra end,
          retries = retries + case when action = 'next' then 1 else 0 end,ready = false,priority = false,position = pos where id = target.id;
      end if;
    end if;
  else raise exception 'Неизвестное действие';
  end if;

  if action = 'extra' and target.id is not null then
    insert into queue_private.pending_extras(user_id,lab,retries,teacher_id,source_session_id,extra_count) values(target.user_id,target.lab,target.retries,owner_id,sid,target.extra_count+1)
      on conflict(user_id,lab,teacher_id) do update set retries = excluded.retries,source_session_id = excluded.source_session_id,extra_count = excluded.extra_count;
  end if;

  -- Hold guests until scheduled students leave the active queue. Returned extras keep their priority. Never interrupt current.
  if exists(select 1 from queue_private.entries where session_id = sid and not off_schedule and status in ('current','waiting')) then
    update queue_private.entries set status = 'deferred'
      where session_id = sid and off_schedule and status = 'waiting' and not ready and not manually_admitted;
  end if;
  -- Keep ready extras first, then initial lab priority, then FIFO (including repeat turns).
  pos := 0;
  for target in select * from queue_private.entries where session_id = sid and status = 'waiting' order by
    case when called_next then 0 when ready then 1 else 2 end,
    case when not off_schedule and retries = 0 and priority then 0 else 1 end,position,id
  loop
    pos := pos + 1;
    update queue_private.entries set position = pos where id = target.id;
  end loop;
  perform queue_private.promote_available(sid);
  update queue_private.entries set called_next=false where session_id=sid and status<>'waiting' and called_next;
  insert into queue_private.results(id,session_id,name,lab,retries,outcome,user_id,off_schedule,had_extra,carried_extra,extra_count)
    select id,sid,name,lab,retries,status,user_id,off_schedule,had_extra,carried_extra,extra_count from queue_private.entries where session_id = sid
    on conflict(id) do update set retries = excluded.retries,outcome = excluded.outcome,off_schedule = excluded.off_schedule,had_extra = excluded.had_extra,carried_extra = excluded.carried_extra,extra_count = excluded.extra_count,updated_at = now();
end;
$$;
revoke all on function public.queue_action(text,jsonb) from public,anon;
grant execute on function public.queue_action(text,jsonb) to authenticated;




do $$
begin
 perform 1 from queue_private.sessions where ended_at is null order by id for update;
 with moved as (
  select e.id,(select coalesce(max(x.position),0) from queue_private.entries x where x.session_id=e.session_id)
   +row_number() over(partition by e.session_id order by e.position,e.id) as new_position
  from queue_private.entries e join queue_private.sessions s on s.id=e.session_id
  where s.ended_at is null and e.status='waiting' and e.called_next
 ) update queue_private.entries e set position=m.new_position,called_next=false from moved m where e.id=m.id;
end;
$$;
commit;
