-- Smoke alarms, quick walk-around (Stephen, 11/5/2026): "for 5 years all alarms work; minimize data entry".
-- Walk around, sound each alarm, stop only at one that does not work and tick its boxes. Then one tap records every
-- other alarm (not yet checked this month) as "Sounded when tested".

create or replace function alarm_check_all_ok(p_building text)
returns int
language plpgsql volatile security definer set search_path = public as $$
declare v_n int; v_month date := date_trunc('month', now() at time zone 'America/Chicago')::date;
begin
  if not alarm_can_check() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if p_building is not null and p_building not in ('6622', '6626') then raise exception 'Choose the building.'; end if;
  insert into alarm_checks (alarm_id, check_month, findings, status, checked_by)
  select p.id, v_month, array['sounded'], 'ok', auth.email()
    from alarm_points p
   where p.active and (p_building is null or p.building = p_building)
     and not exists (select 1 from alarm_checks c where c.alarm_id = p.id and c.check_month = v_month);
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke all on function alarm_check_all_ok(text) from public, anon;
grant execute on function alarm_check_all_ok(text) to authenticated;

-- Where each alarm is, in walking order, from Stephen's 11/5/2026 emails "6622 Smoke" and "6626 SMOKE" (photos ordered by
-- the time they were taken). 6626 has 6 alarms: its photos 5 and 4 were a wide shot and a close-up of the same one
-- (Basement rear stairs), so the extra row is removed (no checks yet).
update alarm_points p set name = v.loc, sort = v.sort
  from (values
    ('6622', 'Alarm 2', 'Basement front', 10), ('6622', 'Alarm 3', 'Basement rear', 20), ('6622', 'Alarm 1', 'First floor rear', 30),
    ('6622', 'Alarm 6', 'First floor mid', 40), ('6622', 'Alarm 4', 'First floor front', 50), ('6622', 'Alarm 5', 'Second floor front', 60),
    ('6622', 'Alarm 7', 'Second floor rear', 70),
    ('6626', 'Alarm 6', 'Basement stairs', 10), ('6626', 'Alarm 4', 'Basement rear stairs', 20), ('6626', 'Alarm 7', 'First floor rear', 30),
    ('6626', 'Alarm 3', 'First floor front', 40), ('6626', 'Alarm 2', 'Second floor front', 50), ('6626', 'Alarm 1', 'Second floor rear', 60)
  ) v(building, old_name, loc, sort)
 where p.building = v.building and p.name = v.old_name;
delete from alarm_points p where p.building = '6626' and p.name = 'Alarm 5' and not exists (select 1 from alarm_checks c where c.alarm_id = p.id);
