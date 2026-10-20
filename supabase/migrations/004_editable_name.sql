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
