-- Detailed money categories for a room-rental operator in Milwaukee (Stephen, 11/11/2026: "no surprise expenses").
-- One row per category: what it is, when it usually comes (monthly, yearly, one-time, as needed), whether it is a start-up
-- cost, and a help note (who usually pays, due dates, Wisconsin/Milwaukee rules). Old category keys are kept so past entries
-- still read; the general ones are switched off for new entries.

create table if not exists nav_money_categories (
  key text primary key,
  kind text not null check (kind in ('expense', 'income')),
  grp text not null,
  label text not null,
  freq text not null check (freq in ('monthly', 'yearly', 'one_time', 'as_needed')),
  startup boolean not null default false,
  help text,
  sort int not null default 0,
  active boolean not null default true
);
alter table nav_money_categories enable row level security;
revoke all on nav_money_categories from anon, authenticated;
grant all on nav_money_categories to service_role;

insert into nav_money_categories (key, kind, grp, label, freq, startup, sort, help) values
-- Lease & rent
('rent_to_landlord', 'expense', 'Lease & rent', 'Rent to the landlord', 'monthly', false, 100, 'Your monthly rent under the lease with the property owner.'),
('deposit_paid', 'expense', 'Lease & rent', 'Security deposit paid to the landlord', 'one_time', true, 101, 'Refundable at the end of your lease if there is no damage, but it is cash out now.'),
('prepaid_rent', 'expense', 'Lease & rent', 'First or last month''s rent paid up front', 'one_time', true, 102, 'Some landlords want first and last month at signing.'),
('lease_fees', 'expense', 'Lease & rent', 'Lease application or admin fee', 'one_time', true, 103, null),
('lease_passthrough', 'expense', 'Lease & rent', 'Charges your lease passes on (tax share, insurance share, common areas)', 'monthly', false, 104, 'Read the lease: some make the tenant pay part of the owner''s property tax, insurance or upkeep.'),
('landlord_late_fees', 'expense', 'Lease & rent', 'Late fees paid to the landlord', 'as_needed', false, 105, 'Plan $0 and keep a cash cushion so rent is never late.'),
('parking_storage', 'expense', 'Lease & rent', 'Parking, garage or storage unit', 'monthly', false, 106, null),
-- Utilities
('electric', 'expense', 'Utilities', 'Electric (We Energies)', 'monthly', false, 200, 'Shared houses use more: lights, laundry, window air conditioners.'),
('gas_heat', 'expense', 'Utilities', 'Natural gas / heat (We Energies)', 'monthly', false, 201, 'Winter bills can be 3 to 4 times summer bills. Budget the yearly average every month, or ask We Energies for budget billing.'),
('water_sewer', 'expense', 'Utilities', 'Water, sewer and storm water (Milwaukee Water Works)', 'monthly', false, 202, 'One bill covers water, sewer, storm water and the local sewerage charge. Often the owner pays: check your lease. Unpaid water bills go onto the owner''s property tax bill.'),
('trash_recycling', 'expense', 'Utilities', 'Trash, recycling, bulk pickup or dumpster', 'monthly', false, 203, 'City garbage is usually paid by the owner through the tax bill. Extra carts, bulk pickup of old furniture, or a private dumpster cost extra.'),
('utilities', 'expense', 'Utilities', 'Utilities (one combined bill)', 'monthly', false, 204, 'Use when one bill covers several utilities.'),
('internet_phone', 'expense', 'Utilities', 'Internet / Wi-Fi', 'monthly', false, 205, 'Residents expect Wi-Fi in shared housing.'),
('tv_streaming', 'expense', 'Utilities', 'TV / streaming', 'monthly', false, 206, null),
('house_phone', 'expense', 'Utilities', 'House phone or emergency phone for residents', 'monthly', false, 207, null),
('utility_deposits', 'expense', 'Utilities', 'Utility deposits and connection fees', 'one_time', true, 208, 'We Energies and internet providers may charge a deposit or setup fee for a new account in your name.'),
-- Furniture & furnishings
('beds_mattresses', 'expense', 'Furniture & furnishings', 'Beds, frames and mattresses', 'one_time', true, 300, 'One per room, plus a spare mattress for quick replacement.'),
('mattress_covers', 'expense', 'Furniture & furnishings', 'Mattress and pillow encasements (bed-bug proof)', 'one_time', true, 301, 'Cheap protection that can save a bed-bug treatment and a mattress.'),
('furniture', 'expense', 'Furniture & furnishings', 'Dressers, nightstands, other bedroom furniture', 'one_time', true, 302, null),
('living_dining', 'expense', 'Furniture & furnishings', 'Living room and dining furniture', 'one_time', true, 303, null),
('lamps_lighting', 'expense', 'Furniture & furnishings', 'Lamps and light fixtures', 'one_time', true, 304, null),
('window_coverings', 'expense', 'Furniture & furnishings', 'Blinds and curtains', 'one_time', true, 305, 'Every bedroom window needs a covering for privacy.'),
('rugs_shelving', 'expense', 'Furniture & furnishings', 'Rugs, mats, shelving, hooks, mirrors', 'one_time', true, 306, null),
('furniture_moving', 'expense', 'Furniture & furnishings', 'Delivery, moving truck or movers', 'one_time', true, 307, null),
-- Appliances
('appliances', 'expense', 'Appliances', 'Large appliances (refrigerator, stove, washer, dryer)', 'one_time', true, 400, 'Check what the landlord provides first.'),
('small_appliances', 'expense', 'Appliances', 'Small appliances (microwave, toaster, coffee maker, vacuum)', 'one_time', true, 401, null),
('ac_fans', 'expense', 'Appliances', 'Window air conditioners and fans', 'one_time', true, 402, 'Summer heat is a health risk for older residents.'),
('appliance_repair', 'expense', 'Appliances', 'Appliance repair, parts and warranties', 'as_needed', false, 403, null),
-- Household supplies
('bedding_linens', 'expense', 'Household supplies', 'Bedding, pillows and towels', 'one_time', true, 500, 'Plan a fresh set for each new resident.'),
('household', 'expense', 'Household supplies', 'Kitchen and household basics (dishes, pots, utensils)', 'one_time', true, 501, null),
('cleaning', 'expense', 'Household supplies', 'Cleaning supplies', 'monthly', false, 502, 'Prices include sales tax: 7.9% in the City of Milwaukee.'),
('paper_goods', 'expense', 'Household supplies', 'Toilet paper, paper towels, trash bags', 'monthly', false, 503, null),
('laundry_supplies', 'expense', 'Household supplies', 'Laundry supplies', 'monthly', false, 504, null),
('bulbs_batteries', 'expense', 'Household supplies', 'Light bulbs, batteries, furnace and water filters', 'monthly', false, 505, null),
('first_aid', 'expense', 'Household supplies', 'First aid kit and supplies', 'yearly', false, 506, null),
-- Safety & compliance
('smoke_co_alarms', 'expense', 'Safety & compliance', 'Smoke and carbon monoxide alarms', 'one_time', true, 600, 'Wisconsin requires smoke alarms on every level and CO alarms where there are fuel-burning appliances; plan one in every bedroom. Test monthly.'),
('fire_extinguishers', 'expense', 'Safety & compliance', 'Fire extinguishers and yearly service', 'yearly', false, 601, 'One in the kitchen and one per floor.'),
('locks_keys', 'expense', 'Safety & compliance', 'Bedroom door locks, rekeying, key copies', 'one_time', true, 602, 'Rekey when you take the unit and each time a resident leaves.'),
('outdoor_lighting_cameras', 'expense', 'Safety & compliance', 'Outdoor lighting or common-area cameras', 'one_time', false, 603, 'Cameras only in shared outside areas, never inside rooms or bathrooms.'),
('lead_safety', 'expense', 'Safety & compliance', 'Lead-safe work and testing (homes built before 1978)', 'as_needed', false, 604, 'Most Milwaukee housing is older. Paint work in pre-1978 homes must follow lead-safe rules; the City can order lead hazards fixed.'),
('pest_control', 'expense', 'Safety & compliance', 'Pest control (routine)', 'monthly', false, 605, null),
('bed_bug_treatment', 'expense', 'Safety & compliance', 'Bed bug inspection and treatment', 'as_needed', false, 606, 'Shared living raises the risk. One whole-unit treatment can cost hundreds of dollars or more; keep a reserve.'),
('air_quality_tests', 'expense', 'Safety & compliance', 'Radon, mold or air-quality testing', 'as_needed', false, 607, null),
-- Repairs & upkeep
('repairs', 'expense', 'Repairs & upkeep', 'General repairs', 'as_needed', false, 700, 'Check your lease: which repairs are yours and which are the landlord''s.'),
('plumbing', 'expense', 'Repairs & upkeep', 'Plumbing and drain cleaning', 'as_needed', false, 701, 'More people means more clogs; a drain snake pays for itself.'),
('electrical', 'expense', 'Repairs & upkeep', 'Electrical', 'as_needed', false, 702, null),
('furnace_service', 'expense', 'Repairs & upkeep', 'Furnace / heating service and filters', 'yearly', false, 703, 'A fall tune-up prevents winter no-heat emergencies.'),
('painting_patching', 'expense', 'Repairs & upkeep', 'Painting and patching between residents', 'as_needed', false, 704, null),
('turnover_cleaning', 'expense', 'Repairs & upkeep', 'Deep cleaning between residents', 'as_needed', false, 705, null),
('carpet_cleaning', 'expense', 'Repairs & upkeep', 'Carpet and upholstery cleaning', 'yearly', false, 706, null),
('handyman_labor', 'expense', 'Repairs & upkeep', 'Handyman or contractor labor', 'as_needed', false, 707, null),
('snow_lawn', 'expense', 'Repairs & upkeep', 'Snow removal, salt and lawn care', 'monthly', false, 708, 'Check the lease. Milwaukee requires sidewalks to be cleared soon after snow stops; the City fines and bills for missed walks.'),
('tools_equipment', 'expense', 'Repairs & upkeep', 'Tools and equipment', 'one_time', true, 709, null),
('damage_unrecovered', 'expense', 'Repairs & upkeep', 'Resident damage not covered by the deposit', 'as_needed', false, 710, null),
('repair_reserve', 'expense', 'Repairs & upkeep', 'Savings for big repairs and replacements (reserve)', 'monthly', false, 711, 'Set aside a fixed amount each month so a broken washer, furnace part or water damage is not a surprise.'),
-- Insurance
('general_liability', 'expense', 'Insurance', 'General liability insurance', 'yearly', false, 800, 'Covers you if someone is hurt or property is damaged. The landlord''s policy does not cover your business.'),
('contents_insurance', 'expense', 'Insurance', 'Renter''s / contents insurance for your furniture and appliances', 'yearly', false, 801, 'The landlord''s insurance does not cover what you own.'),
('auto_business', 'expense', 'Insurance', 'Auto insurance (business use)', 'yearly', false, 802, 'A personal auto policy may not cover business driving or driving residents.'),
('professional_liability', 'expense', 'Insurance', 'Professional liability (errors and omissions)', 'yearly', false, 803, null),
('workers_comp', 'expense', 'Insurance', 'Workers'' compensation (if you have employees)', 'yearly', false, 804, 'Wisconsin requires it once you have employees above the state''s thresholds.'),
('insurance', 'expense', 'Insurance', 'Insurance (other)', 'yearly', false, 805, null),
-- Licenses, permits & registrations
('dfi_reinstatement', 'expense', 'Licenses, permits & registrations', 'Wisconsin DFI LLC reinstatement', 'one_time', true, 900, 'To bring a dissolved LLC back; see https://dfi.wi.gov for the current fee and any back annual reports owed.'),
('dfi_annual_report', 'expense', 'Licenses, permits & registrations', 'Wisconsin DFI annual report', 'yearly', false, 901, 'Due every year by the end of the calendar quarter of the LLC''s anniversary month. Missing it leads to dissolution.'),
('registered_agent', 'expense', 'Licenses, permits & registrations', 'Registered agent service (if you use one)', 'yearly', false, 902, null),
('rooming_house_license', 'expense', 'Licenses, permits & registrations', 'City of Milwaukee rooming house license (if required)', 'yearly', false, 903, 'Renting separate rooms to unrelated people can make a unit a rooming house under city code, which needs a license and inspections, and zoning must allow it. Ask the Department of Neighborhood Services BEFORE renting rooms.'),
('zoning_occupancy', 'expense', 'Licenses, permits & registrations', 'Zoning approval, occupancy permit or code-compliance inspection', 'one_time', true, 904, null),
('rental_registration', 'expense', 'Licenses, permits & registrations', 'City rental registration or inspection fees (if required)', 'yearly', false, 905, null),
('care_license', 'expense', 'Licenses, permits & registrations', 'State license for care services (adult family home / CBRF)', 'yearly', false, 906, 'Only if you provide personal care, supervision or medication help. Housing alone needs no care license (Wisconsin DHS).'),
('licenses_other', 'expense', 'Licenses, permits & registrations', 'Other licenses and permits', 'as_needed', false, 907, null),
-- Taxes
('property_tax', 'expense', 'Taxes', 'Property tax (if you own the property or the lease passes it on)', 'yearly', false, 1000, 'City of Milwaukee tax bills come in December; the first installment is due January 31.'),
('personal_property_tax', 'expense', 'Taxes', 'Personal property tax', 'yearly', false, 1001, 'Wisconsin ended the business personal property tax starting in 2024, so furniture and appliances should owe $0. Keep this line only if a bill arrives.'),
('federal_income_tax', 'expense', 'Taxes', 'Federal income tax (quarterly estimates)', 'yearly', false, 1002, 'You are paid on a 1099 with nothing withheld. Pay estimates April 15, June 15, September 15 and January 15 (Form 1040-ES).'),
('self_employment_tax', 'expense', 'Taxes', 'Self-employment tax (Social Security and Medicare, 15.3%)', 'yearly', false, 1003, 'Owed on your net profit and paid with your federal estimates.'),
('wi_income_tax', 'expense', 'Taxes', 'Wisconsin income tax (quarterly estimates)', 'yearly', false, 1004, 'Form 1-ES, on the same four dates.'),
('payroll_taxes', 'expense', 'Taxes', 'Payroll taxes (if you have employees)', 'monthly', false, 1005, 'Employer Social Security and Medicare, plus federal and Wisconsin unemployment tax.'),
('room_tax', 'expense', 'Taxes', 'Sales and room tax on short stays (under 30 days)', 'as_needed', false, 1006, 'Rentals of 30 days or more are not taxed. Nightly or weekly stays are.'),
('tax_penalties', 'expense', 'Taxes', 'Tax penalties and interest', 'as_needed', false, 1007, 'Plan $0: pay estimates on time.'),
-- Professional & office
('accounting', 'expense', 'Professional & office', 'Bookkeeping and tax preparation', 'yearly', false, 1100, null),
('legal', 'expense', 'Professional & office', 'Attorney (leases, agreements, advice)', 'as_needed', false, 1101, null),
('eviction_costs', 'expense', 'Professional & office', 'Eviction filing, service and court costs', 'as_needed', false, 1102, 'Milwaukee County small-claims filing plus service. Ask the office for its eviction cost sheet.'),
('bank_fees', 'expense', 'Professional & office', 'Bank and payment fees', 'monthly', false, 1103, null),
('business_phone', 'expense', 'Professional & office', 'Business phone and data plan', 'monthly', false, 1104, null),
('software', 'expense', 'Professional & office', 'Software and apps', 'monthly', false, 1105, null),
('mileage_gas', 'expense', 'Professional & office', 'Mileage, gas and parking (driving to units and residents)', 'monthly', false, 1106, 'Keep a mileage log; business miles are tax-deductible at the IRS rate.'),
('postage_printing', 'expense', 'Professional & office', 'Postage, certified mail, printing, notary', 'as_needed', false, 1107, null),
('advertising', 'expense', 'Professional & office', 'Advertising rooms', 'as_needed', false, 1108, null),
('office_supplies', 'expense', 'Professional & office', 'Office supplies', 'monthly', false, 1109, null),
('training', 'expense', 'Professional & office', 'Training and certifications', 'yearly', false, 1110, null),
-- Residents & program
('welcome_kits', 'expense', 'Residents & program', 'Move-in welcome kits', 'as_needed', false, 1200, null),
('resident_transport', 'expense', 'Residents & program', 'Bus passes or rides for residents', 'as_needed', false, 1201, null),
('house_manager', 'expense', 'Residents & program', 'House manager stipend or rent credit', 'monthly', false, 1202, null),
('cleaning_service', 'expense', 'Residents & program', 'Cleaning service for shared areas', 'monthly', false, 1203, null),
('food_meals', 'expense', 'Residents & program', 'Food or meals (only if you provide them)', 'monthly', false, 1204, 'Providing meals can change licensing; ask before offering board.'),
('vacancy_allowance', 'expense', 'Residents & program', 'Empty rooms and unpaid rent allowance (planning only)', 'monthly', false, 1205, 'Plan for a room sitting empty between residents and missed rent; many operators plan 5 to 10% of full rent.'),
('other_expense', 'expense', 'Residents & program', 'Other expense', 'as_needed', false, 1299, null),
-- Old general key kept for past entries
('fees', 'expense', 'Licenses, permits & registrations', 'Fees, licenses, taxes (general, old)', 'as_needed', false, 999, null),
-- Money in
('resident_rent', 'income', 'Money in', 'Resident rent', 'monthly', false, 2000, null),
('agency_payment', 'income', 'Money in', 'Agency / county payment', 'monthly', false, 2001, null),
('va_payment', 'income', 'Money in', 'VA / HUD-VASH / SSVF payment', 'monthly', false, 2002, null),
('payee_payment', 'income', 'Money in', 'Payment from a representative payee', 'monthly', false, 2003, null),
('resident_deposit', 'income', 'Money in', 'Deposit from a resident', 'as_needed', false, 2004, 'A deposit is held for the resident, not income to spend. Wisconsin requires returning it, with an itemized list of any deductions, within 21 days after they move out.'),
('late_fees_received', 'income', 'Money in', 'Late fees from residents', 'as_needed', false, 2005, null),
('utility_reimb', 'income', 'Money in', 'Utility reimbursements from residents', 'monthly', false, 2006, null),
('damage_reimb', 'income', 'Money in', 'Damage reimbursements', 'as_needed', false, 2007, null),
('laundry_vending', 'income', 'Money in', 'Laundry or vending income', 'monthly', false, 2008, null),
('grants_donations', 'income', 'Money in', 'Grants or donations', 'as_needed', false, 2009, null),
('deposit_refund', 'income', 'Money in', 'Deposit refunded to you (landlord or utility)', 'as_needed', false, 2010, null),
('other_income', 'income', 'Money in', 'Other income', 'as_needed', false, 2099, null)
on conflict (key) do update set kind = excluded.kind, grp = excluded.grp, label = excluded.label, freq = excluded.freq,
  startup = excluded.startup, help = excluded.help, sort = excluded.sort;
update nav_money_categories set active = false where key = 'fees';

alter table nav_unit_money drop constraint if exists nav_unit_money_category_check;
alter table nav_unit_money drop constraint if exists nav_unit_money_category_fk;
alter table nav_unit_money add constraint nav_unit_money_category_fk foreign key (category) references nav_money_categories(key);
alter table nav_unit_budget drop constraint if exists nav_unit_budget_frequency_check;
alter table nav_unit_budget add constraint nav_unit_budget_frequency_check check (frequency in ('monthly', 'yearly', 'one_time'));
alter table nav_unit_budget drop constraint if exists nav_unit_budget_category_fk;
alter table nav_unit_budget add constraint nav_unit_budget_category_fk foreign key (category) references nav_money_categories(key);

create or replace function nav_categories() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(to_jsonb(c) order by c.sort), '[]'::jsonb) from nav_money_categories c;
$$;
revoke all on function nav_categories() from public, anon;
grant execute on function nav_categories() to authenticated, service_role;

create or replace function nav_money_save(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_role text := nav_actor_role(); v_id uuid := nullif(p->>'id', '')::uuid; v_unit uuid := nullif(p->>'unit_id', '')::uuid; v_old nav_unit_money;
        v_kind text; v_cat text := p->>'category'; v_receipts text[];
begin
  if v_id is not null then select * into v_old from nav_unit_money where id = v_id; v_unit := v_old.unit_id; end if;
  if v_role is null or v_unit is null or not nav_can_manage_unit(v_unit::text) then raise exception 'Not your unit' using errcode = '42501'; end if;
  select kind into v_kind from nav_money_categories where key = v_cat and (active or v_cat = v_old.category);
  if v_kind is null then raise exception 'Pick what it was for.'; end if;
  if nullif(p->>'amount', '') is null or (p->>'amount')::numeric <= 0 then raise exception 'Enter the amount.'; end if;
  if nullif(p->>'entry_date', '') is null then raise exception 'Enter the date.'; end if;
  if (p->>'entry_date')::date > (now() at time zone 'America/Chicago')::date + 31 then raise exception 'That date is too far ahead.'; end if;
  select coalesce(array_agg(x), '{}') into v_receipts from jsonb_array_elements_text(coalesce(p->'receipts', '[]'::jsonb)) x where split_part(x, '/', 1) = v_unit::text;
  if v_id is null then
    insert into nav_unit_money (unit_id, kind, category, amount, entry_date, created_by)
    values (v_unit, v_kind, v_cat, (p->>'amount')::numeric, (p->>'entry_date')::date, lower(auth.email())) returning id into v_id;
  elsif v_old.voided then raise exception 'This entry was voided.';
  end if;
  update nav_unit_money set kind = v_kind, category = v_cat, amount = round((p->>'amount')::numeric, 2), entry_date = (p->>'entry_date')::date,
         room_id = (select id from nav_rooms where id = nullif(p->>'room_id', '')::uuid and unit_id = v_unit),
         referral_id = (select id from nav_referrals where id = nullif(p->>'referral_id', '')::uuid and nav_unit_id = v_unit),
         party = nullif(trim(coalesce(p->>'party', '')), ''), description = nullif(trim(coalesce(p->>'description', '')), ''),
         receipts = v_receipts, updated_at = now()
   where id = v_id;
  perform nav_log('money_' || case when v_old.id is null then 'added' else 'changed' end,
    v_kind || ' ' || v_cat || ' ' || to_char((p->>'amount')::numeric, 'FM$999,990.00'), null, null, null, v_unit);
  return v_id;
end;
$$;

create or replace function nav_budget_save(p_unit uuid, p_lines jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare v_role text := nav_actor_role();
begin
  if v_role is null or not nav_can_manage_unit(p_unit::text) then raise exception 'Not your unit' using errcode = '42501'; end if;
  delete from nav_unit_budget where unit_id = p_unit;
  insert into nav_unit_budget (unit_id, category, frequency, amount, note)
  select p_unit, x->>'category', x->>'frequency', round((x->>'amount')::numeric, 2), nullif(trim(coalesce(x->>'note', '')), '')
    from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) x
   where coalesce(x->>'amount', '') ~ '^[0-9]+(\.[0-9]+)?$' and (x->>'amount')::numeric > 0 and x->>'frequency' in ('monthly', 'yearly', 'one_time')
     and exists (select 1 from nav_money_categories c where c.key = x->>'category')
  on conflict do nothing;
  perform nav_log('budget_saved', null, null, null, null, p_unit);
end;
$$;

create or replace function nav_unit_file(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare u nav_units; v_today date := (now() at time zone 'America/Chicago')::date; v_month date := date_trunc('month', (now() at time zone 'America/Chicago'))::date;
        v_write boolean;
begin
  if not nav_can_manage_unit(p_id::text) then raise exception 'Not your unit' using errcode = '42501'; end if;
  select * into u from nav_units where id = p_id;
  v_write := staff_session_staff() or exists (select 1 from navigators where id = nav_me() and status in ('preview', 'pilot', 'active'));
  return jsonb_build_object(
    'can_write', v_write,
    'role', case when staff_session_staff() then 'staff' else 'navigator' end,
    'unit', nav_unit_json(u),
    'landlord', (select jsonb_build_object('id', l.id, 'name', l.name, 'business_name', l.business_name, 'phone', l.phone, 'email', l.email) from nav_landlords l where l.id = u.landlord_id),
    'navigators', case when staff_session_staff() then coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name) order by name) from navigators), '[]'::jsonb) end,
    'operated_by_navigator', case when staff_session_staff() then u.operated_by_navigator end,
    'rooms', coalesce((select jsonb_agg(to_jsonb(r) || jsonb_build_object('occupant', (
        select jsonb_build_object('referral_id', x.id, 'label', nav_ref_label(x), 'name', x.first_name || coalesce(' ' || left(x.last_name, 1) || '.', ''), 'status', x.status, 'move_in_on', x.move_in_on)
          from nav_referrals x where x.nav_room_id = r.id and x.status in ('matched', 'approved', 'moved_in') order by x.updated_at desc limit 1)) order by r.sort, r.label)
      from nav_rooms r where r.unit_id = p_id), '[]'::jsonb),
    'budget', coalesce((select jsonb_agg(to_jsonb(b) order by b.frequency, b.category) from nav_unit_budget b where b.unit_id = p_id), '[]'::jsonb),
    'money', coalesce((select jsonb_agg(to_jsonb(m) || jsonb_build_object('room', (select label from nav_rooms where id = m.room_id),
        'referral', (select nav_ref_label(x) from nav_referrals x where x.id = m.referral_id)) order by m.entry_date desc, m.created_at desc)
      from nav_unit_money m where m.unit_id = p_id), '[]'::jsonb),
    'months', coalesce((select jsonb_agg(jsonb_build_object('month', to_char(mo, 'YYYY-MM'),
        'income', (select coalesce(sum(amount), 0) from nav_unit_money where unit_id = p_id and not voided and kind = 'income' and date_trunc('month', entry_date) = mo),
        'expense', (select coalesce(sum(amount), 0) from nav_unit_money where unit_id = p_id and not voided and kind = 'expense' and date_trunc('month', entry_date) = mo)) order by mo desc)
      from generate_series(v_month - interval '11 months', v_month, interval '1 month') mo), '[]'::jsonb),
    'totals', jsonb_build_object(
      'income', (select coalesce(sum(amount), 0) from nav_unit_money where unit_id = p_id and not voided and kind = 'income'),
      'expense', (select coalesce(sum(amount), 0) from nav_unit_money where unit_id = p_id and not voided and kind = 'expense'),
      'startup', (select coalesce(sum(amount), 0) from nav_unit_money where unit_id = p_id and not voided and category in (select key from nav_money_categories where startup)),
      'potential_rent', case when u.room_mode then (select coalesce(sum(monthly_rate), 0) from nav_rooms where unit_id = p_id and status <> 'offline') else u.rent end,
      'occupied_rent', case when u.room_mode then (select coalesce(sum(monthly_rate), 0) from nav_rooms where unit_id = p_id and status = 'occupied') end,
      'rooms', (select count(*) from nav_rooms where unit_id = p_id and status <> 'offline'),
      'rooms_occupied', (select count(*) from nav_rooms where unit_id = p_id and status = 'occupied')),
    'inspections', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'inspected_on', i.inspected_on, 'purpose', i.purpose, 'status', i.status,
        'needs_repair', (select count(*) from jsonb_each(coalesce(i.data -> 'items', '{}'::jsonb)) x where x.value ->> 's' = 'Needs repair')) order by i.inspected_on desc, i.created_at desc)
      from inspections i where i.property_id = 'nav' and i.unit = p_id::text), '[]'::jsonb),
    'residents', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'label', nav_ref_label(x), 'name', x.first_name || coalesce(' ' || left(x.last_name, 1) || '.', ''),
        'status', x.status, 'room', (select label from nav_rooms where id = x.nav_room_id), 'move_in_on', x.move_in_on, 'unit_rent', x.unit_rent) order by x.updated_at desc)
      from nav_referrals x where x.nav_unit_id = p_id and (staff_session_staff() or x.navigator_id = nav_me())), '[]'::jsonb)
  );
end;
$$;
