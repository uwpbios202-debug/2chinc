-- Our own letters, step 1: the 21-day security deposit statement.
--
-- Every letter names the unit owner AND Royal Orleans Condominium – Addition 1
-- (ROCA1): no unit owner acts on their own toward a tenant; they act through
-- ROCA1, with 2nd Chance Housing Inc. as managing agent (Stephen, 10/4/2026).
-- Land contracts (3446 N. 12th St.) go through foreclosure and get none of these.
--
-- Notices follow the LEASE, not the unit: any unit, any tenant, as long as the
-- tenancy is a lease in this system. Which notice periods apply comes from the
-- lease (lease_notice_rules): a Section 8 or other federally covered tenancy
-- gets 30 days for nonpayment; when that tenant leaves, the next lease at the
-- same unit starts out standard (Stephen, 10/4/2026).
--
-- Each letter now carries its own email (email_subject / email_html), and the
-- law it was checked against (law_ref, law_checked_on).
--
-- The 21-day statement comes in three versions, chosen on the Move-outs page:
--   court       the balance after the deposit is due; if unpaid, ROCA1 asks the
--               court for a judgment for the total owed
--   double_rent the tenant stayed after the tenancy ended; the statement also
--               claims twice the daily rental value for those days (§ 704.27)
--   absorbed    the balance is absorbed under the nonprofit (indigent) policy
-- Checked against Wis. Stat. §§ 704.27, 704.28, 704.10(2), 799.01(1)(d) and
-- Wis. Admin. Code ATCP 134.06, as published 10/1/2026.

alter table letter_templates add column if not exists email_subject text;
alter table letter_templates add column if not exists email_html text;
alter table letter_templates add column if not exists law_ref text;
alter table letter_templates add column if not exists law_checked_on date;

alter table move_outs add column if not exists deposit_letter text check (deposit_letter in ('court', 'double_rent', 'absorbed'));
alter table move_outs add column if not exists holdover_days int;
alter table move_outs add column if not exists holdover_claim numeric(10, 2);
alter table move_outs add column if not exists pay_by date;

insert into portal_settings (key, value) values ('deposit_balance_pay_days', '14') on conflict (key) do nothing;

-- Federally covered tenancy, per lease (a voucher belongs to the tenancy, not the unit).
alter table leases add column if not exists federal_program text check (federal_program in ('section8', 'other_federal'));
alter table leases add column if not exists federal_program_note text;

-- The notice periods this lease gets (Wis. Stat. §§ 704.17, 704.19; CARES Act
-- § 4024(c), 15 U.S.C. § 9058(c), and HUD's 30-day rule for covered tenancies).
create or replace function lease_notice_rules(p_lease uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare l leases; v_long boolean; v_fed boolean;
begin
  select * into l from leases where id = p_lease;
  if l.id is null then raise exception 'Lease not found'; end if;
  v_fed := l.federal_program is not null;
  v_long := l.lease_type = 'fixed' and l.end_date is not null and l.start_date is not null and l.end_date > (l.start_date + interval '1 year')::date;
  return jsonb_build_object(
    'federal_program', l.federal_program, 'federal_program_note', l.federal_program_note,
    'lease_kind', case when l.lease_type = 'at_will' then 'month_to_month' when v_long then 'fixed_over_1_year' else 'fixed_1_year_or_less' end,
    'nonpayment_days', case when v_fed or v_long then 30 else 5 end,
    'nonpayment_basis', case when v_fed then 'federally covered tenancy: 30-day notice (CARES Act § 4024(c); HUD), not Wisconsin''s 5 days'
                             when v_long then 'lease longer than one year: 30-day notice (Wis. Stat. § 704.17(3))'
                             when l.lease_type = 'at_will' then 'month-to-month: 5-day notice to pay or vacate (Wis. Stat. § 704.17(1p)(a))'
                             else 'lease of one year or less: 5-day notice to pay or vacate (Wis. Stat. § 704.17(2)(a))' end,
    -- 14-day notice to vacate for nonpayment, with no chance to pay: month-to-month any time in default;
    -- a lease of a year or less only within a year of an earlier nonpayment notice; never for a covered tenancy or a lease over a year.
    'nonpayment_14_day', case when v_fed or v_long then 'no' when l.lease_type = 'at_will' then 'yes' else 'after_prior_notice' end,
    'breach_cure_days', case when v_long then 30 else 5 end,
    'breach_14_day', case when v_long then 'no' when l.lease_type = 'at_will' then 'yes' else 'after_prior_notice' end,
    'termination_28_day', l.lease_type = 'at_will');
end;
$$;
revoke all on function lease_notice_rules(uuid) from public, anon, authenticated;

create or replace function lease_staff_notice_rules(p_lease uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return lease_notice_rules(p_lease);
end;
$$;

create or replace function lease_staff_set_federal_program(p_lease uuid, p_program text, p_note text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if nullif(p_program, '') is not null and p_program not in ('section8', 'other_federal') then raise exception 'Unknown program.'; end if;
  update leases set federal_program = nullif(p_program, ''), federal_program_note = nullif(trim(coalesce(p_note, '')), '') where id = p_lease;
  if not found then raise exception 'Lease not found'; end if;
  return lease_notice_rules(p_lease);
end;
$$;
revoke all on function lease_staff_notice_rules(uuid) from public, anon;
revoke all on function lease_staff_set_federal_program(uuid, text, text) from public, anon;
grant execute on function lease_staff_notice_rules(uuid) to authenticated;
grant execute on function lease_staff_set_federal_program(uuid, text, text) to authenticated;

-- What the lease required and what the tenant actually paid, from the ledger's
-- Security Deposit Liability lines (older leases without them fall
-- back to the deposit held).
create or replace function lease_deposit_terms(p_lease uuid)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'required', coalesce(sum(amount) filter (where kind = 'charge'), (select deposit_held from leases where id = p_lease), 0),
    'paid', coalesce(-sum(amount) filter (where kind = 'payment'), (select deposit_held from leases where id = p_lease), 0))
  from lease_ledger_entries where lease_id = p_lease and gl_account = 'Security Deposit Liability';
$$;
revoke all on function lease_deposit_terms(uuid) from public, anon, authenticated;

-- notice_context_body, plus: the unit owner, ROCA1, the landlord line, the
-- agent who signs, a greeting naming every tenant, and the deposit terms.
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

-- Fill any letter text with a lease's fields (letter_render_ctx's body, for
-- both the letter and its email).
create or replace function letter_fill(p_html text, p_lease uuid, p_extra jsonb)
returns text
language plpgsql stable security definer set search_path = public as $$
declare
  v_html text := p_html; ctx jsonb; k text; v text; l leases; s jsonb;
begin
  if v_html is null then return null; end if;
  select * into l from leases where id = p_lease;
  select jsonb_object_agg(key, value) into s from portal_settings;
  ctx := notice_context_body(p_lease, s->>'office_email') || jsonb_build_object(
    'Tenant_First_Name', 'Resident',
    'Org_Phone', s->>'org_phone', 'Org_Email', s->>'org_email', 'Emergency_Phone', s->>'emergency_phone',
    'Portal_URL', s->>'resident_url', 'Documents_URL', regexp_replace(s->>'resident_url', 'resident/?$', 'documents/'),
    'Zelle_Name', s->>'pay_zelle_name', 'Late_Fee_Policy', s->>'late_fee_policy',
    'Move_In_Amount', to_char(greatest((select coalesce(sum(amount), 0) from lease_ledger_entries where lease_id = p_lease), 0), 'FM$999,990.00'),
    'Checklist_Due', to_char(coalesce(l.keys_released_at::date, l.start_date, current_date) + 7, 'FMMonth FMDD, YYYY'),
    'Move_Out_Notice', case when l.lease_type = 'fixed'
      then 'Your lease ends on ' || to_char(l.end_date, 'FMMM/FMDD/YYYY') || '. We will contact you before then about renewing. If you plan to leave, tell us in writing as early as you can.'
      else 'Give us written notice at least 28 days before the end of a month. A month-to-month tenancy can only end at the end of a calendar month.' end);
  ctx := ctx || jsonb_build_object('Unit_Address', replace(ctx->>'Unit_Address', ' - ', ', Unit #'));
  ctx := ctx || coalesce(p_extra, '{}'::jsonb) - '_keep_signature';
  for k, v in select key, value from jsonb_each_text(ctx) loop
    v_html := replace(v_html, '[[' || k || ']]', replace(replace(replace(coalesce(v, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'));
  end loop;
  -- Notices keep a signature marker for the PDF builder; emails sign off by name.
  return replace(v_html, '[[Sender_Signature]]', case when coalesce((p_extra->>'_keep_signature')::boolean, false) then '[[SIGNATURE]]' else '2nd Chance Housing' end);
end;
$$;
revoke all on function letter_fill(text, uuid, jsonb) from public, anon, authenticated;

create or replace function letter_render_ctx(p_template text, p_lease uuid, p_extra jsonb)
returns text
language plpgsql stable security definer set search_path = public as $$
declare v_html text;
begin
  select html into v_html from letter_templates where legacy_id = p_template;
  if v_html is null then raise exception 'Letter % not found', p_template; end if;
  return letter_fill(v_html, p_lease, p_extra);
end;
$$;
revoke all on function letter_render_ctx(text, uuid, jsonb) from public, anon, authenticated;

-- Templates ------------------------------------------------------------------------
-- Shared top and itemization; each version has its own outcome paragraph.

do $$
declare
  head text := '<p style="text-align: center"><strong>NOTICE TO RETURN SECURITY DEPOSIT — TWENTY-ONE DAY</strong></p>
<p style="text-align: center">Wis. Stat. § 704.28 and Wis. Admin. Code § ATCP 134.06</p>
<p>[[Current_Date]]</p>
<p>Landlord: [[Landlord_Line]]. [[Landlord_Address]]. Managing agent: 2nd Chance Housing Inc.</p>
<p>To: [[Lease_All_Tenants]]<br>[[Forwarding_Address]]</p>
<p>Former premises: [[Unit_Address]]</p>
<p>Your [[Lease_Type_Label]] began [[Lease_Start_Date]]. Security deposit required by the lease: [[Lease_Deposit_Required]]. Security deposit you paid: [[Lease_Deposit_Paid]].</p>
<p>Tenancy ended: [[Tenancy_End_Date]]. Unit vacated and keys returned: [[Surrender_Date]].</p>
<p>Wisconsin law requires us, within 21 days, to return your security deposit or give you a written statement of each amount withheld from it. Each item below is listed with the amount withheld as reasonable compensation for it. Only tenant damage, waste or neglect, unpaid rent and charges, and charges listed in your lease''s Nonstandard Rental Provisions are withheld. Nothing is withheld for normal wear and tear.</p>
[[Itemization]]';
  foot text := '<p>If you believe any item on this statement is wrong, call us at [[Org_Phone]] or email [[Org_Email]].</p>
<p>This statement is sent by email, as your lease permits, and by first-class mail to the address above.</p>
<p>Dated at Milwaukee, Wisconsin, [[Current_Date]].</p>
<p>[[Sender_Signature]]</p>
<p>[[Agent_Name]], [[Agent_Title]]<br>[[Landlord_Signoff]]</p>';
  fields text[] := array['Current_Date', 'Landlord_Line', 'Landlord_Address', 'Lease_All_Tenants', 'Forwarding_Address', 'Unit_Address', 'Lease_Type_Label',
    'Lease_Start_Date', 'Lease_Deposit_Required', 'Lease_Deposit_Paid', 'Tenancy_End_Date', 'Surrender_Date', 'Itemization', 'Outcome_Text', 'Org_Phone', 'Org_Email',
    'Sender_Signature', 'Agent_Name', 'Agent_Title', 'Landlord_Signoff'];
  email_head text := '<p>Dear [[FIRST]],</p>
<p>Attached is the statement for your security deposit at [[Unit_Address]]. Wisconsin law requires it within 21 days after your tenancy ends.</p>
[[Email_Summary]]';
  email_foot text := '<p>A paper copy is also being mailed to [[Forwarding_Address]]. If that address is wrong, update it in your <a href="[[Portal_URL]]">resident portal</a> or call us at [[Org_Phone]].</p>
<p>[[Agent_Name]], [[Agent_Title]]<br>[[Landlord_Signoff]]<br>2nd Chance Housing Inc., managing agent</p>';
  law text := 'Wis. Stat. §§ 704.28, 704.10(2), 799.01(1)(d); ATCP 134.06';
begin
  insert into letter_templates (legacy_id, recipient, name, subject, description, html, fields, email_subject, email_html, law_ref, law_checked_on) values
  ('2c-deposit-court', 'Tenant', '2nd Chance — 21-Day Deposit Statement (total owed, court)', 'Notice to Return Security Deposit',
   'Move-outs page. The balance after the deposit is due by a date; if unpaid, ROCA1 asks the court for a judgment for the total owed.',
   head || '<p>[[Outcome_Text]]</p>' || foot, fields,
   'Your security deposit statement — [[Unit_Address]]',
   email_head || '<p>[[Email_Outcome]]</p>' || email_foot, law, '2026-10-04'),
  ('2c-deposit-double-rent', 'Tenant', '2nd Chance — 21-Day Deposit Statement (double rent)', 'Notice to Return Security Deposit',
   'Move-outs page. The tenant stayed after the tenancy ended: also claims twice the daily rental value for those days (Wis. Stat. § 704.27).',
   head || '<p><b>Holding over.</b> [[Holdover_Text]]</p><p>[[Outcome_Text]]</p>' || foot, fields || array['Holdover_Text'],
   'Your security deposit statement and double rent claim — [[Unit_Address]]',
   email_head || '<p>[[Holdover_Email]]</p><p>[[Email_Outcome]]</p>' || email_foot, law || ', 704.27', '2026-10-04'),
  ('2c-deposit-absorbed', 'Tenant', '2nd Chance — 21-Day Deposit Statement (balance absorbed)', 'Notice to Return Security Deposit',
   'Move-outs page. Any balance after the deposit is absorbed under the nonprofit policy for tenants who qualify as indigent.',
   head || '<p>[[Outcome_Text]]</p>' || foot, fields,
   'Your security deposit statement — [[Unit_Address]]',
   email_head || '<p>[[Email_Outcome]]</p>' || email_foot, law, '2026-10-04')
  on conflict (legacy_id) do update set html = excluded.html, fields = excluded.fields, subject = excluded.subject, description = excluded.description,
    name = excluded.name, email_subject = excluded.email_subject, email_html = excluded.email_html, law_ref = excluded.law_ref, law_checked_on = excluded.law_checked_on, active = true;
end $$;

-- The single old version is replaced by the three above.
update letter_templates set active = false where legacy_id = '2c-deposit-itemization';

-- Deposit statement ----------------------------------------------------------------

create or replace function deposit_gl_label(p text)
returns text language sql immutable as $$
  select case p when 'Rent Income' then 'Unpaid rent' when 'Rent Charge' then 'Unpaid rent' when 'Late Fee Income' then 'Unpaid late fees'
    when 'Repairs Income' then 'Repairs billed to you' when 'Cleaning and Maint Income' then 'Cleaning and maintenance billed to you'
    when 'Parking Income' then 'Unpaid parking' when 'Pet Rent Income' then 'Unpaid pet rent' when 'Leasing fine' then 'Unpaid fines'
    when 'Security Deposit Liability' then 'Security deposit not paid' else p end;
$$;

drop function if exists moveout_staff_deposit(uuid, jsonb, boolean);
create or replace function moveout_staff_deposit(p_id uuid, p_deductions jsonb, p_letter text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  m move_outs; l leases; d jsonb; r record; s jsonb;
  v_ded numeric := 0; v_unpaid numeric; v_dep numeric; v_net numeric; v_items text := ''; v_acct text := '';
  v_end date; v_days int := 0; v_daily numeric := 0; v_double numeric := 0; v_already numeric := 0; v_claim numeric := 0; v_total numeric;
  v_pay_by date; v_limit numeric; v_forum text; v_tpl text; v_out text; v_email_out text; v_hold text := ''; v_hold_email text := '';
  v_sum text; v_extra jsonb; v_acting text; v_html text; v_email text; v_subject text;
  money_ text := 'FM$999,990.00';
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if coalesce(p_letter, '') not in ('court', 'double_rent', 'absorbed') then raise exception 'Choose which deposit statement to send.'; end if;
  select * into m from move_outs where id = p_id and status in ('vacated', 'inspected');
  if m.id is null then raise exception 'Finish the inspection first (or the deposit statement was already sent).'; end if;
  if m.forwarding_address is null then raise exception 'There is no forwarding address. Ask the tenant to add it in the portal, or enter their last known address.'; end if;
  select * into l from leases where id = m.lease_id;
  select jsonb_object_agg(key, value) into s from portal_settings;

  -- Deductions entered on the inspection.
  for d in select * from jsonb_array_elements(coalesce(p_deductions, '[]'::jsonb)) loop
    if length(trim(coalesce(d->>'desc', ''))) < 3 or (d->>'amount') is null then raise exception 'Every line needs a description and an amount.'; end if;
    if coalesce(d->>'category', 'damage') not in ('damage', 'cleaning', 'other', 'credit') then raise exception 'Unknown category.'; end if;
    v_ded := v_ded + (d->>'amount')::numeric;
    v_items := v_items || '<li>' || repair_esc(trim(d->>'desc')) || ': ' || case when (d->>'amount')::numeric < 0
      then 'credit to you ' || to_char(-(d->>'amount')::numeric, money_) else to_char((d->>'amount')::numeric, money_) end || '</li>';
  end loop;
  -- Unpaid rent and charges, itemized by account (each claim described, ATCP 134.06(4)(a)).
  -- Legal charges are left off: a lease can't make a tenant pay attorney fees (§ 704.44(4m)); Stephen 10/4/2026.
  for r in select gl_account, sum(amount) amt from lease_ledger_entries where lease_id = l.id and gl_account <> 'Legal' group by gl_account having sum(amount) <> 0
           order by gl_account <> 'Rent Income', gl_account loop
    v_acct := v_acct || '<li>' || repair_esc(deposit_gl_label(r.gl_account)) || ': ' || case when r.amt < 0 then 'credit to you ' || to_char(-r.amt, money_) else to_char(r.amt, money_) end || '</li>';
  end loop;
  v_dep := coalesce(l.deposit_held, 0);
  v_unpaid := greatest((select coalesce(sum(amount), 0) from lease_ledger_entries where lease_id = l.id and gl_account <> 'Legal'), 0);
  v_net := v_dep - v_unpaid - v_ded;

  -- Holding over (§ 704.27): twice the daily rental value for each day in
  -- possession after the tenancy ended. Rent already charged for those days is
  -- in the balance above, so only the second half is added.
  v_end := coalesce(m.move_out_date, l.end_date);
  if v_end is not null and m.surrendered_on > v_end then v_days := m.surrendered_on - v_end; end if;
  if p_letter = 'double_rent' then
    if v_days <= 0 then raise exception 'The tenant did not stay past the end of the tenancy (%), so there is no double rent to claim. Choose another statement.', coalesce(to_char(v_end, 'FMMM/FMDD/YYYY'), 'no end date'); end if;
    v_daily := round(coalesce(l.rent, 0) * 12 / 365, 2);
    v_double := v_daily * 2 * v_days;
    if exists (select 1 from lease_ledger_entries e where e.lease_id = l.id and e.kind = 'charge' and e.gl_account in ('Rent Income', 'Rent Charge') and e.entry_date > v_end) then
      v_already := v_daily * v_days;
    end if;
    v_claim := v_double - v_already;
    v_hold := 'Your tenancy ended on ' || to_char(v_end, 'FMMonth FMDD, YYYY') || ', but you stayed in the unit without our consent until ' ||
      to_char(m.surrendered_on, 'FMMonth FMDD, YYYY') || ' (' || v_days || ' day' || case when v_days = 1 then '' else 's' end || '). Under Wis. Stat. § 704.27, ' ||
      'a tenant who stays after the tenancy ends owes at least twice the rental value for each of those days. Your rent of ' || to_char(l.rent, money_) ||
      ' a month is ' || to_char(v_daily, money_) || ' a day (rent × 12 ÷ 365). Twice that for ' || v_days || ' day' || case when v_days = 1 then '' else 's' end ||
      ' is <b>' || to_char(v_double, money_) || '</b>.' ||
      case when v_already > 0 then ' Rent of ' || to_char(v_already, money_) || ' for those days is already in the balance above, so the additional amount claimed is <b>' || to_char(v_claim, money_) || '</b>.' else '' end ||
      ' This amount is not taken from your security deposit; it is claimed in addition to the statement above.';
    v_hold_email := 'Because you stayed ' || v_days || ' day' || case when v_days = 1 then '' else 's' end || ' after your tenancy ended, the statement also claims double rent under Wis. Stat. § 704.27: <b>' ||
      to_char(v_claim, money_) || '</b>.';
  end if;

  v_total := greatest(-v_net, 0) + v_claim;
  v_pay_by := current_date + coalesce((s->>'deposit_balance_pay_days')::int, 14);
  v_limit := case when current_date >= date '2027-01-01' then 15000 else 10000 end;   -- 799.01(1)(d), 2025 Wis. Act 105
  v_forum := case when v_total <= v_limit then 'a small claims action in Milwaukee County Circuit Court' else 'an action in Milwaukee County Circuit Court' end;

  v_out := case
    when p_letter = 'absorbed' and v_net < 0 then
      'The amounts above are more than your security deposit by ' || to_char(-v_net, money_) || '. ' ||
      '2nd Chance Housing Inc. is a nonprofit organization. Under our policy for tenants who qualify as indigent, this balance is absorbed. ' ||
      'You owe nothing further. We are not seeking damages or double rent.'
    when v_total <= 0 then
      case when v_net > 0 then 'A refund of <b>' || to_char(v_net, money_) || '</b> is being mailed to the address above. You owe nothing further.'
           else 'Your security deposit covered the amounts above in full. Nothing is owed by either party.' end || ' We are not seeking damages or double rent.'
    else
      case when v_net > 0 then 'A refund of <b>' || to_char(v_net, money_) || '</b> is being mailed to the address above. '
           when v_net < 0 then 'The amounts above are more than your security deposit. A balance of <b>' || to_char(-v_net, money_) || '</b> remains. ' else '' end ||
      case when p_letter = 'double_rent' then 'With the double rent claimed above, the total you owe is <b>' || to_char(v_total, money_) || '</b>. '
           else 'The total you owe is <b>' || to_char(v_total, money_) || '</b>. ' end ||
      'Please pay it by <b>' || to_char(v_pay_by, 'FMMonth FMDD, YYYY') || '</b> in your resident portal, or call us to arrange payment. ' ||
      'If it is not paid by then, [[ACTING]] will file ' || v_forum || ' asking the judge for a judgment for the total owed, plus the court costs allowed by law.' ||
      case when p_letter = 'court' then ' We are not claiming double rent.' else '' end
  end;
  v_email_out := case
    when p_letter = 'absorbed' and v_net < 0 then 'Under our nonprofit policy, the remaining balance of ' || to_char(-v_net, money_) || ' is absorbed. You owe nothing further.'
    when v_total <= 0 then case when v_net > 0 then 'A refund of ' || to_char(v_net, money_) || ' is being mailed to you. You owe nothing further.' else 'Your deposit covered everything. Nothing is owed by either party.' end
    else case when v_net > 0 then 'A refund of ' || to_char(v_net, money_) || ' is being mailed to you. ' else '' end ||
      'The total you owe is <b>' || to_char(v_total, money_) || '</b>, due by <b>' || to_char(v_pay_by, 'FMMonth FMDD, YYYY') ||
      '</b>. You can pay in your resident portal. If it is not paid by then, [[ACTING]] will ask the court for a judgment for the total owed.'
  end;

  v_sum := '<p>Security deposit held: <b>' || to_char(v_dep, money_) || '</b><br>Unpaid rent and charges: <b>' || to_char(v_unpaid, money_) ||
    '</b><br>Damage and cleaning: <b>' || to_char(v_ded, money_) || '</b><br>' ||
    case when v_net >= 0 then 'Returned to you: <b>' || to_char(v_net, money_) || '</b>' else 'Balance after the deposit: <b>' || to_char(-v_net, money_) || '</b>' end || '</p>';

  update move_outs set deductions = coalesce(p_deductions, '[]'::jsonb), deposit_held = v_dep, unpaid_balance = v_unpaid,
    refund_amount = greatest(v_net, 0), balance_due = case when p_letter = 'absorbed' then greatest(-v_net, 0) else v_total end,
    absorb_balance = p_letter = 'absorbed', deposit_letter = p_letter, holdover_days = nullif(v_days, 0), holdover_claim = nullif(v_claim, 0),
    pay_by = case when p_letter <> 'absorbed' and v_total > 0 then v_pay_by end where id = p_id;

  v_tpl := case p_letter when 'court' then '2c-deposit-court' when 'double_rent' then '2c-deposit-double-rent' else '2c-deposit-absorbed' end;
  v_extra := jsonb_build_object('_keep_signature', true, 'Forwarding_Address', m.forwarding_address,
    'Surrender_Date', to_char(m.surrendered_on, 'FMMonth FMDD, YYYY'), 'Tenancy_End_Date', coalesce(to_char(least(v_end, m.surrendered_on), 'FMMonth FMDD, YYYY'), to_char(m.surrendered_on, 'FMMonth FMDD, YYYY')),
    'Outcome_Text', '[[OUTCOME]]', 'Holdover_Text', '[[HOLDOVER]]', 'Itemization', '[[ITEMS]]',
    'Email_Summary', '[[SUMMARY]]', 'Email_Outcome', '[[EMAIL_OUTCOME]]', 'Holdover_Email', '[[HOLDOVER_EMAIL]]', 'Tenant_First_Name', '[[FIRST]]');
  v_acting := notice_context_body(l.id, null)->>'Landlord_Acting';
  v_out := replace(v_out, '[[ACTING]]', repair_esc(v_acting));
  v_email_out := replace(v_email_out, '[[ACTING]]', repair_esc(replace(v_acting, ', for the unit owner,', '')));
  v_html := letter_render_ctx(v_tpl, l.id, v_extra);
  -- These parts are built here from escaped values, so they go in unescaped.
  v_html := replace(replace(replace(v_html, '[[OUTCOME]]', v_out), '[[HOLDOVER]]', v_hold), '[[ITEMS]]',
    '<p><b>Security deposit held: ' || to_char(v_dep, money_) || '</b></p>' ||
    '<p><b>Unpaid rent and charges on your account: ' || to_char(v_unpaid, money_) || '</b></p>' ||
    case when v_acct <> '' then '<ul>' || v_acct || '</ul>' else '' end ||
    case when v_items <> '' then '<p><b>Damage, cleaning and other deductions:</b></p><ul>' || v_items || '</ul>' else '<p>No deductions for damage or cleaning.</p>' end ||
    '<p><b>' || case when v_net >= 0 then 'Amount returned to you: ' || to_char(v_net, money_) else 'Balance after the deposit: ' || to_char(-v_net, money_) end || '</b></p>');
  select letter_fill(email_html, l.id, v_extra), letter_fill(email_subject, l.id, v_extra - '_keep_signature') into v_email, v_subject from letter_templates where legacy_id = v_tpl;
  v_email := replace(replace(replace(v_email, '[[SUMMARY]]', v_sum), '[[EMAIL_OUTCOME]]', v_email_out), '[[HOLDOVER_EMAIL]]', v_hold_email);

  return jsonb_build_object('ok', true, 'lease_id', l.id, 'deposit_held', v_dep, 'unpaid_balance', v_unpaid, 'deductions', v_ded, 'net', v_net,
    'holdover_days', v_days, 'holdover_claim', v_claim, 'total_owed', v_total, 'pay_by', v_pay_by,
    'template_id', (select id from letter_templates where legacy_id = v_tpl), 'subject', 'Notice to Return Security Deposit', 'html', v_html,
    'email_subject', v_subject, 'email_html', v_email);
end;
$$;
revoke all on function moveout_staff_deposit(uuid, jsonb, text) from public, anon;
grant execute on function moveout_staff_deposit(uuid, jsonb, text) to authenticated;
