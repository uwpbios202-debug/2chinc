-- "I don't have a vehicle" today, a vehicle next week (Stephen, 11/8/2026): registering a vehicle or a loaner for a stall clears that
-- stall's earlier "no vehicle" answer, so the office lists, the stock-take and the tow page never show a stale "no vehicle".
-- (A regular visitor answer is kept.) Works for every way a vehicle is saved (tenants, owners, Unit 6's person, staff).
-- No new table, so no new grants.

create or replace function vehicle_clears_no_vehicle()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'active' and new.kind in ('own', 'loaner') then
    update parking_declarations set no_vehicle = false, declared_at = now() where unit_number = new.unit_number and no_vehicle;
  end if;
  return new;
end;
$$;
revoke all on function vehicle_clears_no_vehicle() from public, anon, authenticated;

drop trigger if exists vehicles_clear_no_vehicle on vehicles;
create trigger vehicles_clear_no_vehicle after insert or update of status, kind on vehicles
  for each row execute function vehicle_clears_no_vehicle();
