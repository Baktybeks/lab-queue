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
