-- HVAC technician: Daljinder Singh (Stephen, 11/5/2026). He serves every unit owned by 2nd Chance Housing Inc, Unit 7 and Unit 16.
--   Tenants of hvac_tenant_units and owners of hvac_owner_units see a "Text the HVAC technician" card (resident Requests, owner Repairs).
--   The first text is ONLY the address and who to call to get into the building and unit. The site does not send texts: the button opens
--   the person's own phone with the message filled in, and they send it themselves. Someone must be on site when he arrives.
--   Owners in hvac_owner_units (7, 16) pay him themselves by Zelle when the work is done (a Pay card explains it; no money goes through the site).
--   2nd Chance pays for its own units (tenants see no Pay card).

insert into portal_settings (key, value) values
  ('hvac_tech_name', 'Daljinder Singh'),
  ('hvac_tech_phone', '(414) 377-1511'),
  ('hvac_tech_zelle', ''),                               -- his Zelle phone/email once known; empty = "ask him by text"
  ('hvac_tenant_units', '2,3,4,5,11,14,16'),
  ('hvac_owner_units', '7,16'),
  ('unit_city_line', 'Milwaukee, WI 53224')
on conflict (key) do nothing;

insert into vendors (name, category, contact_name, mobile, notes)
select 'Daljinder Singh', 'HVAC', 'Daljinder Singh', '(414) 377-1511',
       'HVAC technician for all 2nd Chance Housing units, Unit 7 and Unit 16. Text first with ONLY the address and who to call to get in; someone must be on site. Accepts Zelle; the owners of Units 7 and 16 pay him on completion.'
where not exists (select 1 from vendors where name = 'Daljinder Singh');

-- "6622 North Bourbon Street - 16" -> "6622 N Bourbon St, Unit 16, Milwaukee, WI 53224"
create or replace function hvac_unit_address(p_unit text) returns text
language sql stable security definer set search_path = public as $$
  select replace(replace(split_part(u.address, ' - ', 1), 'North ', 'N '), ' Street', ' St') || ', Unit ' || u.unit_number || ', ' || condo_setting('unit_city_line', 'Milwaukee, WI 53224')
    from rental_units u where u.unit_number = p_unit limit 1;
$$;

-- What the signed-in tenant and/or owner may use: the technician's contact, each unit's address, and their own name and phone to prefill "who to call".
create or replace function hvac_tech_mine() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_ids uuid[]; v_owner uuid; v_out jsonb := '[]'::jsonb; v_name text; v_phone text;
begin
  if not condo_session_ok() then raise exception 'Two-step sign-in required' using errcode = '42501'; end if;
  v_ids := array(select resident_me());
  v_owner := condo_owner_for_email(auth.email());
  if cardinality(v_ids) > 0 then
    select name, phone into v_name, v_phone from tenants where id = v_ids[1];
    v_out := v_out || coalesce((select jsonb_agg(distinct jsonb_build_object('unit', u.unit_number, 'address', hvac_unit_address(u.unit_number), 'role', 'tenant', 'pays', false,
                                  'my_name', v_name, 'my_phone', v_phone))
      from leases l join rental_units u on u.id = l.unit_id
      where l.status in ('active', 'future') and exists (select 1 from lease_tenants x where x.lease_id = l.id and x.tenant_id = any (v_ids))
        and u.unit_number = any (repair_setting_units('hvac_tenant_units'))), '[]'::jsonb);
  end if;
  if v_owner is not null then
    select name, coalesce(phone_mobile, phone_home, phone_work) into v_name, v_phone from condo_owners where id = v_owner;
    v_out := v_out || coalesce((select jsonb_agg(jsonb_build_object('unit', cu.unit_number, 'address', hvac_unit_address(cu.unit_number), 'role', 'owner', 'pays', true,
                                  'my_name', v_name, 'my_phone', v_phone) order by cu.unit_number::int)
      from condo_ownerships s join condo_units cu on cu.id = s.unit_id
      where s.is_current and s.owner_id = v_owner and cu.unit_number = any (repair_setting_units('hvac_owner_units'))), '[]'::jsonb);
  end if;
  if jsonb_array_length(v_out) = 0 then return jsonb_build_object('units', '[]'::jsonb); end if;
  return jsonb_build_object('name', condo_setting('hvac_tech_name', ''), 'phone', condo_setting('hvac_tech_phone', ''),
    'zelle', nullif(condo_setting('hvac_tech_zelle', ''), ''), 'units', v_out);
end;
$$;

revoke all on function hvac_unit_address(text) from public, anon, authenticated;
grant execute on function hvac_unit_address(text) to service_role;
revoke all on function hvac_tech_mine() from public, anon;
grant execute on function hvac_tech_mine() to authenticated, service_role;
