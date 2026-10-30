-- Set the initial lab in the same transaction that opens a session.
begin;
create or replace function public.queue_action(action text,payload jsonb default '{}'::jsonb) returns void
language plpgsql security definer set search_path = '' as $$
declare
  actor uuid := auth.uid();
  sid uuid;
  active_lab integer;
  admin boolean;
  owner_id uuid;
  superadmin boolean;
  target queue_private.entries;
  display_name text;
  chosen_lab integer;
  guest boolean;
  previous_retries integer;
  pending_retries integer;
  pending_source uuid;
  extra_total integer;
  was_extra boolean;
  was_carried boolean;
  pos bigint;
  group_name text;
  new_date date;
begin
  if actor is null or not exists(select 1 from auth.users where id = actor and not coalesce(is_anonymous,false)) then
    raise exception 'Войдите в аккаунт по логину и паролю';
  end if;
  sid := (payload->>'session_id')::uuid;
  select exists(select 1 from queue_private.admins where user_id = actor) into admin;
  select exists(select 1 from queue_private.superadmins where user_id = actor) into superadmin;
  if action in ('create_session','end_session','next','pass','extra','restore_extra','admit_ready_extra','admit_deferred','pause_entry','pause_waiting','resume_entry','set_lab') and not admin then
    raise exception 'Доступ только преподавателю';
  end if;
  if action = 'create_session' then
    perform pg_advisory_xact_lock(hashtextextended(actor::text,0));
    if exists(select 1 from queue_private.sessions where created_by = actor and ended_at is null) then raise exception 'Сначала завершите текущую сессию'; end if;
    new_date := (payload->>'date')::date;
    group_name := trim(payload->>'group');
    if new_date is null or group_name is null or char_length(group_name) not between 1 and 60 then
      raise exception 'Укажите дату и группу (до 60 символов)';
    end if;
    active_lab := coalesce((payload->>'lab')::integer,6);
    if active_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    insert into queue_private.sessions(date,"group",created_by,lab) values(new_date,group_name,actor,active_lab) returning id into sid;
    return;
  end if;
  if sid is null then raise exception 'Выберите сессию преподавателя или откройте QR-код'; end if;
  select created_by,lab into owner_id,active_lab from queue_private.sessions where id = sid and ended_at is null for update;
  if not found then raise exception 'Сессия изменилась или завершена. Обновите страницу'; end if;
  if admin and action in ('end_session','next','pass','extra','restore_extra','admit_ready_extra','admit_deferred','pause_entry','pause_waiting','resume_entry','set_lab') and owner_id is distinct from actor and not superadmin then
    raise exception 'Вы не можете управлять сессией другого преподавателя';
  end if;
  if action = 'end_session' then
    update queue_private.results set outcome = 'failed',updated_at = now()
      where session_id = sid and outcome in ('current','waiting','deferred','paused');
    for target in select e.* from queue_private.entries e join queue_private.results r on r.id = e.id where r.session_id = sid loop
      delete from queue_private.entries where id = target.id;
    end loop;
    update queue_private.sessions set ended_at = now() where id = sid;

    return;
  end if;
  select coalesce(max(position),0)+1 into pos from queue_private.entries where session_id = sid;
  if action = 'join' then
    if exists(select 1 from queue_private.entries where user_id = actor and session_id = sid) then raise exception 'Вы уже записаны'; end if;
    display_name := coalesce(trim(payload->>'name'),
      (select name from queue_private.profiles where user_id = actor),
      (select raw_user_meta_data->>'display_name' from auth.users where id = actor));
    chosen_lab := (payload->>'lab')::integer;
    guest := coalesce((payload->>'off_schedule')::boolean,false);
    if display_name is null or char_length(display_name) not between 2 and 60 then raise exception 'Укажите имя и фамилию: от 2 до 60 символов'; end if;
    if chosen_lab is null or chosen_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    insert into queue_private.profiles(user_id,name) values(actor,display_name) on conflict(user_id) do update set name = excluded.name;
    select coalesce(max(retries),0) into previous_retries from queue_private.results where session_id = sid and user_id = actor and lab = chosen_lab;
    select retries,source_session_id into pending_retries,pending_source from queue_private.pending_extras where user_id = actor and lab = chosen_lab and teacher_id = owner_id;
    select coalesce(bool_or(r.had_extra),false),coalesce(bool_or(r.carried_extra),false) into was_extra,was_carried
      from queue_private.results r where r.session_id = sid and r.user_id = actor and r.lab = chosen_lab;
    if pending_retries is not null then was_extra := true; was_carried := pending_source is distinct from sid; end if;
    select coalesce(max(r.extra_count),0) into extra_total from queue_private.results r
      join queue_private.sessions s on s.id=r.session_id
      where r.user_id=actor and r.lab=chosen_lab and s.created_by=owner_id;
    extra_total := greatest(extra_total,coalesce((select extra_count from queue_private.pending_extras where user_id=actor and lab=chosen_lab and teacher_id=owner_id),0));
    previous_retries := greatest(previous_retries,coalesce(pending_retries,0));
    insert into queue_private.entries(user_id,name,lab,status,priority,position,retries,off_schedule,session_id,had_extra,carried_extra,extra_count)
      values(actor,display_name,chosen_lab,case when pending_retries is not null then 'extra' when guest then 'deferred' else 'waiting' end,
        pending_retries is null and not guest and chosen_lab = active_lab and previous_retries = 0 and not was_extra,pos,previous_retries,guest,sid,was_extra,was_carried,extra_total);
  elsif action = 'leave' then
    select * into target from queue_private.entries where user_id = actor and session_id = sid;
    if target.id is not null then
      update queue_private.results set outcome = 'left',updated_at = now() where id = target.id;
      delete from queue_private.entries where id = target.id;
    end if;
  elsif action = 'ready' then
    select * into target from queue_private.entries where user_id = actor and session_id = sid and status = 'extra';
    if target.id is null then raise exception 'Вы не на доп. задании'; end if;
    delete from queue_private.pending_extras where user_id = actor and lab = target.lab and teacher_id = owner_id;
    update queue_private.entries set status = 'waiting',can_return_extra = true,ready = not target.carried_extra,priority = false,position = pos where id = target.id;
  elsif action = 'return_extra' then
    select * into target from queue_private.entries where user_id=actor and session_id=sid
      and can_return_extra and status in ('waiting','current','deferred','paused');
    if target.id is null then raise exception 'Вернуться можно только после готовности к допзаданию'; end if;
    update queue_private.entries set status='extra',ready=false,priority=false,can_return_extra=false where id=target.id;
    insert into queue_private.pending_extras(user_id,lab,retries,teacher_id,source_session_id,extra_count)
      values(actor,target.lab,target.retries,owner_id,case when target.carried_extra then null else sid end,target.extra_count)
      on conflict(user_id,lab,teacher_id) do update set retries=excluded.retries,source_session_id=excluded.source_session_id,extra_count=excluded.extra_count;
  elsif action = 'restore_extra' then
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status in ('current','waiting','deferred','paused');
    if target.id is null then raise exception 'Студент больше не находится в очереди'; end if;
    update queue_private.entries set status='extra',ready=false,priority=false,manually_admitted=false,can_return_extra=false,
      had_extra=true,carried_extra=true,extra_count=greatest(extra_count,1) where id=target.id;
    insert into queue_private.pending_extras(user_id,lab,retries,teacher_id,source_session_id,extra_count)
      values(target.user_id,target.lab,target.retries,owner_id,null,greatest(target.extra_count,1))
      on conflict(user_id,lab,teacher_id) do update set retries=greatest(queue_private.pending_extras.retries,excluded.retries),
        source_session_id=null,extra_count=greatest(queue_private.pending_extras.extra_count,excluded.extra_count);
  elsif action = 'admit_ready_extra' then
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid
      and status in ('waiting','deferred','paused','extra') and not ready;
    if target.id is null then raise exception 'Студент уже вызван или очередь изменилась'; end if;
    update queue_private.entries set status='waiting',ready=true,priority=false,manually_admitted=true,can_return_extra=true,
      had_extra=true,carried_extra=true,extra_count=greatest(extra_count,1),position=pos where id=target.id;
    delete from queue_private.pending_extras where user_id=target.user_id and lab=target.lab and teacher_id=owner_id;
  elsif action = 'pause_entry' then
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status in ('current','waiting');
    if target.id is null then raise exception 'Студент больше не находится в очереди'; end if;
    update queue_private.entries set status='paused',ready=false,priority=false,manually_admitted=false,position=pos where id=target.id;
  elsif action = 'pause_waiting' then
    update queue_private.entries set status='paused',ready=false,priority=false,manually_admitted=false where session_id=sid and status='waiting';
  elsif action = 'resume_entry' then
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status='paused';
    if target.id is null then raise exception 'Студент больше не находится в ожидании'; end if;
    update queue_private.entries set status='waiting',ready=false,priority=false,manually_admitted=true,position=pos where id=target.id;
  elsif action = 'admit_deferred' then
    if exists(select 1 from queue_private.entries where session_id=sid and status='waiting') then
      raise exception 'Сначала дождитесь освобождения очереди';
    end if;
    select * into target from queue_private.entries where id=(payload->>'entry_id')::uuid and session_id=sid and status='deferred';
    if target.id is null then raise exception 'Студент больше не ожидает допуска в этой сессии'; end if;
    update queue_private.entries set status='waiting',manually_admitted=true,ready=false,priority=false,position=pos where id=target.id;
  elsif action = 'set_lab' then
    chosen_lab := (payload->>'lab')::integer;
    if chosen_lab is null or chosen_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    update queue_private.sessions set lab = chosen_lab where id = sid;
    update queue_private.entries set priority=(lab=chosen_lab and not off_schedule and retries=0 and not had_extra
      and not carried_extra and extra_count=0 and not ready and not manually_admitted)
      where session_id=sid and status='waiting';
  elsif action in ('next','pass','extra') then
    select * into target from queue_private.entries where session_id = sid and status = 'current';
    if target.id is distinct from (payload->>'current_id')::uuid then raise exception 'Очередь изменилась. Обновите страницу и повторите действие'; end if;
    if target.id is not null then
      if action = 'pass' then
        delete from queue_private.pending_extras where user_id = target.user_id and lab = target.lab and teacher_id = owner_id;
        update queue_private.results set outcome = 'passed',first_try_pass = (
          target.retries=0 and target.extra_count=0 and not target.had_extra and not exists(
            select 1 from queue_private.results prior join queue_private.sessions s on s.id=prior.session_id
            where prior.user_id=target.user_id and prior.lab=target.lab and s.created_by=owner_id and prior.id<>target.id
              and (prior.outcome in ('failed','passed') or prior.retries>0 or prior.had_extra)
          )),updated_at = now() where id = target.id;
        delete from queue_private.entries where id = target.id;
      else
        update queue_private.entries set manually_admitted=(action = 'next' and target.off_schedule),can_return_extra=false,status = case when action = 'extra' then 'extra' else 'waiting' end,
          extra_count = extra_count + case when action = 'extra' then 1 else 0 end,
          had_extra = queue_private.entries.had_extra or action = 'extra',carried_extra = case when action = 'extra' then false else queue_private.entries.carried_extra end,
          retries = retries + case when action = 'next' then 1 else 0 end,ready = false,priority = false,position = pos where id = target.id;
      end if;
    end if;
  else raise exception 'Неизвестное действие';
  end if;

  if action = 'extra' and target.id is not null then
    insert into queue_private.pending_extras(user_id,lab,retries,teacher_id,source_session_id,extra_count) values(target.user_id,target.lab,target.retries,owner_id,sid,target.extra_count+1)
      on conflict(user_id,lab,teacher_id) do update set retries = excluded.retries,source_session_id = excluded.source_session_id,extra_count = excluded.extra_count;
  end if;

  -- Hold guests until scheduled students leave the active queue. Returned extras keep their priority. Never interrupt current.
  if exists(select 1 from queue_private.entries where session_id = sid and not off_schedule and status in ('current','waiting')) then
    update queue_private.entries set status = 'deferred'
      where session_id = sid and off_schedule and status = 'waiting' and not ready and not manually_admitted;
  end if;
  -- Keep ready extras first, then initial lab priority, then FIFO (including repeat turns).
  pos := 0;
  for target in select * from queue_private.entries where session_id = sid and status = 'waiting' order by
    case when ready then 0 else 1 end,
    case when not off_schedule and retries = 0 and priority then 0 else 1 end,position,id
  loop
    pos := pos + 1;
    update queue_private.entries set position = pos where id = target.id;
  end loop;
  perform queue_private.promote_available(sid);
  insert into queue_private.results(id,session_id,name,lab,retries,outcome,user_id,off_schedule,had_extra,carried_extra,extra_count)
    select id,sid,name,lab,retries,status,user_id,off_schedule,had_extra,carried_extra,extra_count from queue_private.entries where session_id = sid
    on conflict(id) do update set retries = excluded.retries,outcome = excluded.outcome,off_schedule = excluded.off_schedule,had_extra = excluded.had_extra,carried_extra = excluded.carried_extra,extra_count = excluded.extra_count,updated_at = now();
end;
$$;
revoke all on function public.queue_action(text,jsonb) from public,anon;
grant execute on function public.queue_action(text,jsonb) to authenticated;




-- Reconcile active waiting queues with each session's current lab.
do $$
declare selected uuid; n bigint; entry_id uuid;
begin
  for selected in select id from queue_private.sessions where ended_at is null order by id for update loop
    update queue_private.entries e set priority=(e.lab=s.lab and not e.off_schedule and e.retries=0 and not e.had_extra
      and not e.carried_extra and e.extra_count=0 and not e.ready and not e.manually_admitted)
      from queue_private.sessions s where s.id=selected and e.session_id=s.id and e.status='waiting';
    n:=0;
    for entry_id in select id from queue_private.entries where session_id=selected and status='waiting'
      order by case when ready then 0 else 1 end,case when not off_schedule and retries=0 and priority then 0 else 1 end,position,id loop
      n:=n+1;update queue_private.entries set position=n where id=entry_id;
    end loop;
  end loop;
end;
$$;
commit;
