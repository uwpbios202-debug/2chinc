-- Repair request categories: 2nd Chance does not service appliances, so "appliance" goes.
-- Added: keys & locks, doors, windows, faucets/toilets/sinks (fixtures).

update maintenance_requests set category = 'other' where category = 'appliance';

alter table maintenance_requests drop constraint if exists maintenance_requests_category_check;
alter table maintenance_requests add constraint maintenance_requests_category_check
  check (category in ('plumbing', 'fixtures', 'keys', 'doors', 'windows', 'heat', 'electric', 'pests', 'other'));

create or replace function repair_category_label(p_category text)
returns text
language sql immutable as $$
  select case p_category when 'plumbing' then 'Plumbing' when 'fixtures' then 'Faucet, toilet & sink' when 'keys' then 'Keys & locks'
    when 'doors' then 'Doors' when 'windows' then 'Windows' when 'heat' then 'Heat' when 'electric' then 'Electric'
    when 'pests' then 'Pests' when 'other' then 'Other' else 'Not set' end;
$$;

-- The request-creating function checks the category against the same list; swap the list in place.
do $$
declare d text;
begin
  select pg_get_functiondef(p.oid) into d from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'public' and p.proname = 'resident_create_request' and p.prokind = 'f';
  if d is null or position('''pests'', ''appliance'', ''other''' in d) = 0 then
    raise exception 'resident_create_request does not contain the expected category list';
  end if;
  execute replace(d, '''plumbing'', ''heat'', ''electric'', ''pests'', ''appliance'', ''other''',
                     '''plumbing'', ''fixtures'', ''keys'', ''doors'', ''windows'', ''heat'', ''electric'', ''pests'', ''other''');
end $$;
