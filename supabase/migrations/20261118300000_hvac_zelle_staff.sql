-- HVAC technician follow-up (Stephen, 11/5/2026):
--   his Zelle is his phone number, (414) 377-1511;
--   tenants of the other 2nd Chance-managed units (8, 12, 18) also get the Text card;
--   2nd Chance gets the Pay card for every unit it pays for (all hvac_tenant_units except the owner-paid hvac_owner_units), on the staff Maintenance page.

update portal_settings set value = '(414) 377-1511' where key = 'hvac_tech_zelle';
update portal_settings set value = '2,3,4,5,8,11,12,14,16,18' where key = 'hvac_tenant_units';
update vendors set notes = 'HVAC technician for all 2nd Chance units (2, 3, 4, 5, 8, 11, 12, 14, 18), Unit 7 and Unit 16. Text first with ONLY the address and who to call to get in; someone must be on site. Zelle: (414) 377-1511, paid on completion: by 2nd Chance for its units, by the owners for Units 7 and 16.'
 where name = 'Daljinder Singh';

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
  if condo_is_staff() then   -- 2nd Chance: text for any served unit; pays for its own (not the owner-paid units)
    select name, coalesce(phone_mobile, condo_setting('org_phone', '')) into v_name, v_phone from condo_staff where lower(email) = lower(auth.email());
    v_out := v_out || coalesce((select jsonb_agg(jsonb_build_object('unit', u, 'address', hvac_unit_address(u), 'role', 'staff',
                                  'pays', not (u = any (repair_setting_units('hvac_owner_units'))), 'my_name', v_name, 'my_phone', v_phone) order by u::int)
      from unnest(array(select distinct x from unnest(repair_setting_units('hvac_tenant_units') || repair_setting_units('hvac_owner_units')) x)) u), '[]'::jsonb);
  end if;
  if jsonb_array_length(v_out) = 0 then return jsonb_build_object('units', '[]'::jsonb); end if;
  return jsonb_build_object('name', condo_setting('hvac_tech_name', ''), 'phone', condo_setting('hvac_tech_phone', ''),
    'zelle', nullif(condo_setting('hvac_tech_zelle', ''), ''), 'units', v_out);
end;
$$;
