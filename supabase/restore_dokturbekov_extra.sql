-- Apply AFTER migration 009. Correct only the result explicitly identified by the teacher.
begin;
do $$
declare
  matches integer;
  record_id uuid;
  student_id uuid;
begin
  select count(*),min(r.id::text)::uuid into matches,record_id
    from queue_private.results r join queue_private.sessions s on s.id = r.session_id
    where r.name = 'Доктурбеков Азирет Жоомартович' and r.lab = 6
      and s.date = date '2026-10-21' and s.ended_at is not null
      and r.outcome in ('unfinished','extra');
  if matches <> 1 then
    raise exception 'Найдено записей: %. Нужна ровно одна запись Доктурбекова, лаба 6, 21.10.2026. Данные не изменены.',matches;
  end if;
  select user_id into student_id from queue_private.results where id = record_id;
  if student_id is null then
    select id into student_id from auth.users where email = 'dokturbekov_a_zh@students.lab-queue.invalid';
  end if;
  if student_id is null then raise exception 'Не найден аккаунт студента. Данные не изменены.'; end if;
  update queue_private.results set outcome = 'extra',user_id = student_id where id = record_id;
  -- Preserve the original timestamp and never override a later completed assignment.
  if not exists(select 1 from queue_private.results newer join queue_private.results original on original.id = record_id
    where newer.user_id = student_id and newer.lab = 6 and newer.outcome = 'passed' and newer.updated_at > original.updated_at) then
    insert into queue_private.pending_extras(user_id,lab,retries)
      select student_id,lab,retries from queue_private.results where id = record_id
      on conflict(user_id,lab) do nothing;
  end if;
end;
$$;
commit;

select r.name,r.lab,r.retries,r.outcome,s.date,s."group"
from queue_private.results r join queue_private.sessions s on s.id = r.session_id
where r.name = 'Доктурбеков Азирет Жоомартович' and r.lab = 6 and s.date = date '2026-10-21';
