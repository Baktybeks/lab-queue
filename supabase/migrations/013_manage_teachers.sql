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
