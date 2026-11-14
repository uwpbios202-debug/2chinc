-- Units not allowed to park because of an association-dues violation (Stephen, 10/13/2026: Unit 8).
-- The parking lot map shows their stall in red with "NO PARKING". Setting parking_blocked_units = comma list of unit numbers.
insert into portal_settings (key, value) values ('parking_blocked_units', '8') on conflict (key) do nothing;

create or replace function parking_blocked_units()
returns text[]
language sql stable security definer set search_path = public as $$
  select case when auth.uid() is null then '{}'::text[]
    else coalesce((select array_agg(trim(x)) from unnest(string_to_array(condo_setting('parking_blocked_units', ''), ',')) x where trim(x) <> ''), '{}') end;
$$;
revoke all on function parking_blocked_units() from public, anon;
grant execute on function parking_blocked_units() to authenticated;
