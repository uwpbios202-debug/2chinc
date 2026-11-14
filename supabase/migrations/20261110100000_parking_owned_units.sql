-- Owners see the stalls of every unit they own shaded on the parking map, whether or not they live there.
-- An owner who owns 13 (lives there), 15 and 17 (tenants, or vacant) sees all three stalls shaded: a tenant's stall
-- shows the tenant's vehicles, a vacant one shows "vacant" and that it is theirs to use. Same map for everyone else.
-- Adds 'owned' (unit + occupancy) to parking_lot_mine; nothing else about it changes.
create or replace function parking_lot_mine(p_date date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not vehicle_can_view() then raise exception 'Resident or owner sign-in required' using errcode = '42501'; end if;
  return parking_lot_core(coalesce(p_date, current_date), false) || jsonb_build_object(
    'my_units', coalesce((select jsonb_agg(jsonb_build_object('unit', unit_number, 'kind', kind) order by unit_number) from parking_my_units()), '[]'::jsonb),
    'owned', coalesce((select jsonb_agg(jsonb_build_object('unit', cu.unit_number, 'occupancy', cu.occupancy) order by nullif(regexp_replace(cu.unit_number, '\D', '', 'g'), '')::int)
        from condo_ownerships s join condo_units cu on cu.id = s.unit_id
       where s.is_current and s.owner_id = condo_owner_for_email(auth.email()) and condo_session_ok()
         and exists (select 1 from parking_stalls st where st.home_unit = cu.unit_number and st.active)), '[]'::jsonb),
    'office_phone', (select value from portal_settings where key = 'org_phone'),
    'unit_stalls', coalesce((select jsonb_agg(home_unit order by map_row, map_pos) from parking_stalls where kind = 'unit' and active), '[]'::jsonb),
    'swaps', coalesce((select jsonb_agg(parking_swap_row(w, false) order by w.start_date desc) from parking_swaps w
      where (w.unit_a in (select unit_number from parking_my_units()) or w.unit_b in (select unit_number from parking_my_units()))
        and (w.status = 'pending' or (w.status in ('accepted', 'ended') and w.end_date >= current_date - 30))), '[]'::jsonb));
end;
$$;
revoke all on function parking_lot_mine(date) from public, anon;
grant execute on function parking_lot_mine(date) to authenticated;
