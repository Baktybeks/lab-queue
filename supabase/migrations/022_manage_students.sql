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
