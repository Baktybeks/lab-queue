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
