-- Fix end_session for Supabase safeupdate. Run after student authentication migrations.
-- Replaces the function only; applying this file does not delete queue entries.
begin;
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
revoke all on function public.queue_session_core(text,jsonb) from public,anon,authenticated,service_role;
commit;
