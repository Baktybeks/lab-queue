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
