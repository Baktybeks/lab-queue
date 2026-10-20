-- Read-only: inspect the actually installed RPC functions without changing data.
select
  p.proname as function_name,
  p.prosrc ~* 'delete[[:space:]]+from[[:space:]]+queue_private[.]entries[[:space:]]*;' as has_old_delete,
  position('where exists' in lower(p.prosrc)) > 0 as has_scoped_delete,
  position('queue_session_core' in p.prosrc) > 0 as calls_session_core
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in ('queue_action','queue_session_core','queue_action_core')
  and p.prokind = 'f'
order by p.proname;
