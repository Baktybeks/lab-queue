-- First create superadmin@mail.ru in Authentication > Users with a password and Auto Confirm enabled.
begin;
do $$
declare account_id uuid;
begin
  select id into account_id from auth.users where lower(email) = 'superadmin@mail.ru' and not coalesce(is_anonymous,false);
  if account_id is null then raise exception 'Сначала создайте superadmin@mail.ru в Authentication → Users'; end if;
  insert into queue_private.admins(user_id) values(account_id) on conflict do nothing;
  insert into queue_private.superadmins(user_id) values(account_id) on conflict do nothing;
  insert into queue_private.profiles(user_id,name) values(account_id,'Суперадминистратор') on conflict do nothing;
end;
$$;
commit;
