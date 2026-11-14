-- Unit 6's parking-and-keys person sees ONLY the glass entry door code and their unit's basement front door code (Stephen, 11/4/2026).
-- Not the unit entry door key code(s) or any other key point. Tenants and owners see what they saw before.

create or replace function keys_mine()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_units text[];
  -- Signed in only as a parking-and-keys person (not also a tenant or an owner): glass door and basement codes only.
  v_occ_only boolean := exists (select 1 from occupant_my_units())
                        and not exists (select 1 from vehicle_my_units())
                        and condo_owner_for_email(auth.email()) is null;
begin
  select coalesce(array_agg(u), '{}') into v_units from key_my_units() u;
  if cardinality(v_units) = 0 then raise exception 'Sign-in required' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object('name', p.name || case when c.slot > 1 then ' ' || c.slot else '' end, 'building', p.building, 'kind', p.kind,
             'unit', c.unit_number, 'slot', c.slot, 'code', c.code, 'note', p.note, 'updated_at', c.updated_at) order by p.sort, p.name, c.unit_number, c.slot)
    from key_points p join key_codes c on c.point_id = p.id
    where p.active
      and (not v_occ_only or (p.kind = 'door' and p.audience = 'building') or (p.kind = 'basement' and p.audience = 'unit'))
      and (
      (p.audience = 'building' and (p.building = 'both' or exists (
         select 1 from condo_units cu where cu.unit_number = any (v_units) and split_part(cu.address, ' ', 1) = p.building)))
      or (p.audience = 'unit' and c.unit_number = any (v_units)))
  ), '[]'::jsonb);
end;
$$;
revoke all on function keys_mine() from public, anon;
grant execute on function keys_mine() to authenticated;
