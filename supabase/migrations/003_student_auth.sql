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
