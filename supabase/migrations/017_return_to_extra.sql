-- Student can undo readiness without earning medals or changing repeat counters.
begin;
alter table queue_private.entries add column if not exists can_return_extra boolean not null default false;
update queue_private.entries set can_return_extra=true where ready and status in ('waiting','current');
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
  if action in ('create_session','end_session','next','pass','extra','set_lab') and not admin then
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
    insert into queue_private.sessions(date,"group",created_by) values(new_date,group_name,actor) returning id into sid;
    return;
  end if;
  if sid is null then raise exception 'Выберите сессию преподавателя или откройте QR-код'; end if;
  select created_by,lab into owner_id,active_lab from queue_private.sessions where id = sid and ended_at is null for update;
  if not found then raise exception 'Сессия изменилась или завершена. Обновите страницу'; end if;
  if admin and action in ('end_session','next','pass','extra','set_lab') and owner_id is distinct from actor and not superadmin then
    raise exception 'Вы не можете управлять сессией другого преподавателя';
  end if;
  if action = 'end_session' then
    update queue_private.results set outcome = 'failed',updated_at = now()
      where session_id = sid and outcome in ('current','waiting','deferred');
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
      values(actor,display_name,chosen_lab,case when pending_retries is not null then 'extra' else 'waiting' end,
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
      and can_return_extra and status in ('waiting','current','deferred');
    if target.id is null then raise exception 'Вернуться можно только после готовности к допзаданию'; end if;
    update queue_private.entries set status='extra',ready=false,priority=false,can_return_extra=false where id=target.id;
    insert into queue_private.pending_extras(user_id,lab,retries,teacher_id,source_session_id,extra_count)
      values(actor,target.lab,target.retries,owner_id,case when target.carried_extra then null else sid end,target.extra_count)
      on conflict(user_id,lab,teacher_id) do update set retries=excluded.retries,source_session_id=excluded.source_session_id,extra_count=excluded.extra_count;
  elsif action = 'set_lab' then
    chosen_lab := (payload->>'lab')::integer;
    if chosen_lab is null or chosen_lab not between 1 and 99 then raise exception 'Номер лабы: 1–99'; end if;
    update queue_private.sessions set lab = chosen_lab where id = sid;
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
        update queue_private.entries set can_return_extra=false,status = case when action = 'extra' then 'extra' else 'waiting' end,
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
      where session_id = sid and off_schedule and status = 'waiting' and not ready;
  else
    update queue_private.entries set status = 'waiting' where session_id = sid and status = 'deferred';
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
  if not exists(select 1 from queue_private.entries where session_id = sid and status = 'current') then
    update queue_private.entries set status = 'current' where id = (
      select id from queue_private.entries where session_id = sid and status = 'waiting' order by position limit 1
    );
  end if;
  insert into queue_private.results(id,session_id,name,lab,retries,outcome,user_id,off_schedule,had_extra,carried_extra,extra_count)
    select id,sid,name,lab,retries,status,user_id,off_schedule,had_extra,carried_extra,extra_count from queue_private.entries where session_id = sid
    on conflict(id) do update set retries = excluded.retries,outcome = excluded.outcome,off_schedule = excluded.off_schedule,had_extra = excluded.had_extra,carried_extra = excluded.carried_extra,extra_count = excluded.extra_count,updated_at = now();
end;
$$;





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
      'position',position,'retries',retries,'mine',user_id = actor,'off_schedule',off_schedule,'had_extra',had_extra,'carried_extra',carried_extra,'extra_count',extra_count,'can_return_extra',can_return_extra) order by position,id)
      from queue_private.entries where session_id = sid),'[]'::jsonb)
  );
end;
$$;




revoke all on function public.queue_action(text,jsonb) from public,anon;
revoke all on function public.queue_snapshot_for_session(uuid) from public,anon;
grant execute on function public.queue_action(text,jsonb) to authenticated;
grant execute on function public.queue_snapshot_for_session(uuid) to authenticated;
commit;
