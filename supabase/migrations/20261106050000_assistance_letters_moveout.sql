-- Housing assistance, follow-up (Stephen, 10/7/2026: "we drop nothing but just strengthen everything").
--  * Letters get [[Tenant_Rent_Portion]], [[Housing_Assistance_Portion]] and [[Housing_Assistance_Agency]].
--    [[Lease_Rent]] stays the full lease rent (legal notices and the lease quote it). The Online Payments letter
--    now tells the tenant the amount THEY pay, which is the full rent when no agency pays part of it.
--  * Move-out: the suggested credit for unused days is figured on the tenant's portion only; the agency's share
--    for those days is shown separately so staff adjust the agency ledger (Accounting > Housing assistance).

create or replace function notice_context_body(p_lease_id uuid, p_sender_email text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  l leases; u rental_units; p rental_properties;
  v_owner text; v_tenants text; v_first text; v_last text; v_emails text; v_rent_balance numeric; v_balance numeric;
  v_sender text; v_sender_phone text; v_sender_email text := lower(coalesce(p_sender_email, ''));
  v_greeting text; v_agent lease_agents; v_dep jsonb; v_rules jsonb; v_assoc text := 'Royal Orleans Condominium – Addition 1';
  v_condo boolean; v_owner_name text; v_landlord text; v_signoff text; v_addr text;
begin
  select * into l from leases where id = p_lease_id;
  if l.id is null then raise exception 'Lease not found'; end if;
  select * into u from rental_units where id = l.unit_id;
  select * into p from rental_properties where id = u.property_id;
  select o.name into v_owner from condo_ownerships s join condo_owners o on o.id = s.owner_id where s.unit_id = u.condo_unit_id and s.is_current order by s.start_date desc limit 1;
  select string_agg(t.name, ', ' order by t.name), string_agg(t.email, ', ' order by t.name) into v_tenants, v_emails
    from lease_tenants lt join tenants t on t.id = lt.tenant_id where lt.lease_id = l.id;
  select split_part(t.name, ' ', 1), regexp_replace(t.name, '^\S+\s*', '') into v_first, v_last
    from lease_tenants lt join tenants t on t.id = lt.tenant_id where lt.lease_id = l.id order by t.name limit 1;
  -- "Dear Jane and John" / "Dear Jane, John and Sam"
  select regexp_replace(string_agg(f, ', ' order by n), ', ([^,]+)$', ' and \1') into v_greeting
    from (select split_part(t.name, ' ', 1) f, t.name n from lease_tenants lt join tenants t on t.id = lt.tenant_id where lt.lease_id = l.id) x;
  select coalesce(sum(amount), 0) into v_balance from lease_ledger_entries where lease_id = l.id;
  v_rent_balance := lease_rent_due(l.id, current_date);
  select coalesce(a.name, s.name), coalesce(a.phone_mobile, s.phone_mobile) into v_sender, v_sender_phone
    from condo_staff s left join lease_agents a on lower(a.email) = lower(s.email) where lower(s.email) = v_sender_email;
  select * into v_agent from lease_agents where active order by created_at limit 1;
  v_dep := lease_deposit_terms(l.id);
  v_rules := lease_notice_rules(l.id);
  -- A condo unit's owner acts only through ROCA1; any other unit is 2nd Chance's own.
  v_condo := u.condo_unit_id is not null;
  v_owner_name := coalesce(v_owner, '2nd Chance Housing Inc.');
  v_landlord := case when v_condo then v_assoc || ' (ROCA1) for ' || v_owner_name || ', unit owner' else v_owner_name end;
  v_signoff := case when v_condo then 'for ' || v_owner_name || ' and ' || v_assoc || ' (ROCA1)' else 'for ' || v_owner_name end;
  v_addr := '6626 N. Bourbon St., Milwaukee, WI 53224';
  return jsonb_build_object(
    'Current_Date', to_char(current_date, 'FMMonth FMDD, YYYY'), 'Current_Month', to_char(current_date, 'FMMonth'), 'Current_Year', to_char(current_date, 'YYYY'),
    'Unit_Address_Line_1', coalesce(regexp_replace(u.address, '\s*-\s*\d+$', ''), p.street), 'Unit_Number', coalesce(u.unit_number, ''),
    'Unit_Address', coalesce(u.address, p.street) || ', ' || coalesce(p.city, 'Milwaukee') || ', ' || coalesce(p.state, 'WI') || ' ' || coalesce(p.zip, ''),
    'Unit_City_Address', coalesce(p.city, 'Milwaukee'), 'Unit_City', coalesce(p.city, 'Milwaukee'),
    'Unit_State_Address', coalesce(p.state, 'WI'), 'Unit_State', coalesce(p.state, 'WI'),
    'Unit_PostalCode_Address', coalesce(p.zip, ''), 'Unit_Postal_Code', coalesce(p.zip, ''),
    'Property_Address_Line_1', coalesce(p.street, ''), 'Property_Name', p.name,
    'Rental_Owner_Full_Name', coalesce(v_owner, '2nd Chance Housing Inc.'), 'Rental_Owners_Full_Name', coalesce(v_owner, '2nd Chance Housing Inc.'),
    'Unit_Owner', v_owner_name,
    'Association_Name', case when v_condo then v_assoc else '' end, 'Association_Short', case when v_condo then 'ROCA1' else '' end,
    'Landlord_Address', v_addr, 'Association_Address', v_addr,
    'Landlord_Line', v_landlord, 'Landlord_Signoff', v_signoff, 'Landlord_Acting', case when v_condo then 'ROCA1, for the unit owner,' else v_owner_name end,
    'Nonpayment_Notice_Days', (v_rules->>'nonpayment_days'), 'Nonpayment_Notice_Basis', v_rules->>'nonpayment_basis',
    'Federal_Program', coalesce(case l.federal_program when 'section8' then 'Section 8 (Housing Choice Voucher)' when 'other_federal' then 'federally covered tenancy' end, '')
  ) || jsonb_build_object(   -- (a function call takes at most 100 arguments)
    'Agent_Name', coalesce(v_agent.name, 'Albert Harris'), 'Agent_Title', 'Agent for Owner',
    'Tenant_First_Name', coalesce(v_first, ''), 'Tenant_Last_Name', coalesce(v_last, ''), 'Tenants_Full_Name', coalesce(v_tenants, ''),
    'Tenant_Greeting', coalesce(v_greeting, 'Resident'),
    'Lease_All_Tenants', coalesce(v_tenants, ''), 'Tenants_Email', coalesce(v_emails, ''), 'Tenant_Address_1', coalesce(u.address, p.street),
    'Lease_Rent', to_char(coalesce(l.rent, 0), 'FM$999,990.00'), 'Lease_Rent_Due_Day', '1st',
    -- Housing assistance (20261106010000): what the tenant pays themselves, and the agency's share. Lease_Rent stays the full lease rent.
    'Tenant_Rent_Portion', to_char(greatest(coalesce(l.rent, 0) - coalesce((assistance_for(l.id, current_date)).agency_portion, 0), 0), 'FM$999,990.00'),
    'Housing_Assistance_Portion', to_char(coalesce((assistance_for(l.id, current_date)).agency_portion, 0), 'FM$999,990.00'),
    'Housing_Assistance_Agency', coalesce((assistance_for(l.id, current_date)).agency_name, ''),
    'Rent_Balance', to_char(v_rent_balance, 'FM$999,990.00'), 'Account_Balance', to_char(v_balance, 'FM$999,990.00'),
    'Lease_Start_Date', to_char(l.start_date, 'FMMM/FMDD/YYYY'), 'Lease_End_Date', coalesce(to_char(l.end_date, 'FMMM/FMDD/YYYY'), 'month-to-month'),
    'Lease_Type_Label', case when l.lease_type = 'fixed' then 'lease' else 'month-to-month lease' end,
    'Lease_Security_Deposit', to_char(coalesce(l.deposit_held, 0), 'FM$999,990.00'),
    'Lease_Deposit_Required', to_char((v_dep->>'required')::numeric, 'FM$999,990.00'),
    'Lease_Deposit_Paid', to_char((v_dep->>'paid')::numeric, 'FM$999,990.00'),
    'Sender_Name', coalesce(v_sender, ''), 'Sender_Phone', coalesce(v_sender_phone, (select value from portal_settings where key = 'office_phone')),
    'Sender_Email', coalesce(v_sender_email, ''), 'Sender_URL', '2ndchinc.org',
    '_lease_label', coalesce(u.address, p.street) || ' — ' || coalesce(v_tenants, ''),
    '_sender_is_agent', exists (select 1 from lease_agents a where a.active and lower(a.email) = v_sender_email and a.signature_path is not null)
  );
end;
$$;
revoke all on function notice_context_body(uuid, text) from public, anon, authenticated;

create or replace function moveout_staff_detail(p_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare m move_outs; l leases;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into m from move_outs where id = p_id;
  select * into l from leases where id = m.lease_id;
  return jsonb_build_object('move_out', to_jsonb(m), 'rooms', (select value::jsonb from portal_settings where key = 'move_in_rooms'),
    'move_in', (select jsonb_build_object('status', c.status, 'data', c.data, 'decided_at', c.decided_at) from move_in_checklists c where c.lease_id = l.id),
    'deposit_held', l.deposit_held, 'rent', l.rent,
    'agency_portion', (assistance_for(l.id, coalesce(m.surrendered_on, current_date))).agency_portion,
    'agency', (assistance_for(l.id, coalesce(m.surrendered_on, current_date))).agency_name,
    'ledger', (select jsonb_agg(jsonb_build_object('date', e.entry_date, 'desc', e.description, 'account', e.gl_account, 'amount', e.amount) order by e.entry_date, e.id) from lease_ledger_entries e where e.lease_id = l.id),
    'balance', (select coalesce(sum(amount), 0) from lease_ledger_entries where lease_id = l.id),
    'suggested_credit', case when not m.early and m.surrendered_on is not null and m.surrendered_on < (date_trunc('month', m.surrendered_on) + interval '1 month' - interval '1 day')::date
        and exists (select 1 from lease_ledger_entries e where e.lease_id = l.id and e.kind = 'charge' and e.gl_account = 'Rent Income' and date_trunc('month', e.entry_date) = date_trunc('month', m.surrendered_on))
      then round(greatest(coalesce(l.rent, 0) - coalesce((assistance_for(l.id, m.surrendered_on)).agency_portion, 0), 0) * (extract(day from (date_trunc('month', m.surrendered_on) + interval '1 month' - interval '1 day')) - extract(day from m.surrendered_on))
                 / extract(day from (date_trunc('month', m.surrendered_on) + interval '1 month' - interval '1 day')), 2) end);
end;
$$;

update letter_templates
   set html = replace(html, 'Your rent of <b>[[Lease_Rent]]</b>', 'Your rent payment of <b>[[Tenant_Rent_Portion]]</b>'),
       fields = case when 'Tenant_Rent_Portion' = any(fields) then fields else array_append(fields, 'Tenant_Rent_Portion') end
 where legacy_id = '2c-online-payments' and html like '%Your rent of <b>[[Lease_Rent]]</b>%';
