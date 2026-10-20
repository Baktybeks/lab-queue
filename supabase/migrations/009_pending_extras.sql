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
