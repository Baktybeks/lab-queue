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
