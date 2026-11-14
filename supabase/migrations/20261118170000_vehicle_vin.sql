-- Vehicle VIN (Stephen, 11/3/2026). When a tenant registers their own vehicle or a loaner they may type or speak its VIN; the portal looks it
-- up in NHTSA's free vPIC decoder (in the browser, no key) and fills in year, make and model for them to check. The VIN is kept with the
-- vehicle for the office (and a tow request), never shown to other residents. Optional: older or imported vehicles may not decode.
-- No new table, so no new grants.

alter table vehicles add column if not exists vin text;
alter table vehicles drop constraint if exists vehicles_vin_check;
alter table vehicles add constraint vehicles_vin_check check (vin is null or vin ~ '^[A-HJ-NPR-Z0-9]{11,17}$');

-- Set the VIN on a vehicle the signed-in tenant just registered (called right after resident_vehicle_save).
create or replace function resident_vehicle_set_vin(p_id uuid, p_vin text)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare v_vin text := upper(regexp_replace(coalesce(p_vin, ''), '[^A-Za-z0-9]', '', 'g'));
begin
  if not exists (select 1 from vehicles v where v.id = p_id and v.status = 'active' and v.kind in ('own', 'loaner')
                   and v.unit_number in (select u from vehicle_my_units() u)) then
    raise exception 'Vehicle not found.' using errcode = '42501';
  end if;
  if v_vin <> '' and v_vin !~ '^[A-HJ-NPR-Z0-9]{17}$' then raise exception 'A VIN has 17 letters and numbers (never I, O or Q).'; end if;
  update vehicles set vin = nullif(v_vin, ''), updated_at = now() where id = p_id;
end;
$$;
revoke all on function resident_vehicle_set_vin(uuid, text) from public, anon;
grant execute on function resident_vehicle_set_vin(uuid, text) to authenticated;
