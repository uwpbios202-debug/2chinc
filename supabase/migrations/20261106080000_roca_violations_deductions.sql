-- ROCA1 violations (deliberated fines) and rent deductions / owner distributions (Stephen, 10/7/2026):
-- "assessments and liens and violations can be either manually added or added as a result of an automation from a
-- deliberated process and then those are taken out [of the rent]."
-- Builds on 20261106060000_roca_governance_core.sql (resolutions, votes, roca_exec_<kind>, roca_auto_<name>).
--
-- Sources (the ROCA1 governing documents):
--   Rules & Regulations 2024 (ratified, 2025-04-13_ROCA1 Rules_2024_ratified.pdf)
--     §10 Enforcement of Rules: complaint → written notice → either a hearing, or a fine notice with fourteen (14)
--         days to request a hearing in writing; no request → the fine becomes final. Board hearings: majority vote,
--         the Chairperson votes only to break a tie, directors involved in the dispute don't hear it, written decision
--         within five (5) business days. Violation Verdict 1: the fine is charged to the assessment account of the
--         Unit Owner in which the guilty person resides, collectible like assessments.
--     §11 FINES/FEES 2: parking offenses are fined immediately, without warning.
--     §11 PAYMENT OF FINES/FEES 1: "Payments are applied to fines and fees outstanding balance first."
--     §5 General: "A board decision is necessary to waive fees."
--   By-Laws 2020 §1502(a): a written request for a hearing BEFORE the fine is imposed suspends the fine until the
--     hearing; fines are Special Assessments and collectible as such. The board "has authority to assess daily fines
--     for continuing violations" (Rules §10.4).
--   Property Management Agreements (2020-06-18_ROCA1 PMA.pdf template): rents go to the Manager's account; the
--     Manager withholds compensation from tenants' payments only — management fee 0% of gross rents; a 3.0%
--     collection fee only when rent is paid by card. 2020-03-06_ROCA1 PMA.pdf (Unit 1, prior owner): 3.1%
--     commission, $150 operating reserve, "allow AGENT to withhold the correct ROCA1 association fees".
--     The Unit 16 PMA (2023-07-24) is encrypted and was not read. Per-unit terms are kept in roca_pma_terms and
--     default to 0% until the signed agreement for that unit is entered.
-- Money separation (ROADMAP): rent sits in 2nd Chance Housing's account and dues are ROCA1's. A distribution is a
-- statement; the association ledger is credited ONLY when staff record the transfer to ROCA1's account.

-- ===========================================================================
-- A. Violations
-- ===========================================================================
create table if not exists roca_fine_schedule (
  code text primary key,
  section text not null,                 -- where it is in Rules & Regulations 2024
  title text not null,
  amount numeric(12,2),                  -- null = not a fixed amount (towing, % of rent): staff enter the amount
  basis text not null check (basis in ('occurrence', 'call', 'incident', 'day', 'week', 'month', 'night', 'other')),
  cap_amount numeric(12,2),              -- e.g. "$5.00 per day up to $100.00 per month"
  cap_basis text check (cap_basis in ('month')),
  accrues boolean not null default false, -- continuing: keeps accruing until cured ("accumulate monthly until resolved")
  immediate boolean not null default false, -- fined without warning (parking, Rules §11 FINES/FEES 2)
  amount_note text,
  charged_to text not null default 'owner' check (charged_to in ('owner', 'occupant')),
  active boolean not null default true
);

insert into roca_fine_schedule (code, section, title, amount, basis, cap_amount, cap_basis, accrues, immediate, amount_note, charged_to) values
  ('condition',        '§2 Condition of Units',            'Condition of unit',                         100.00, 'month', null, null, true,  false, 'Fines accumulate monthly per incidence until resolved', 'owner'),
  ('exterior',         '§2 Exterior Changes',              'Exterior change without approval',           100.00, 'month', null, null, true,  false, 'Fines accumulate monthly per incidence until resolved', 'owner'),
  ('mailbox',          '§2 Exterior Changes 6',            'Mailbox without a proper lock',               15.00, 'month', null, null, true,  false, 'Levied monthly until a lock is in place', 'owner'),
  ('window_treatment', '§2 Interior Window Treatments',     'Non-conforming window treatment',             10.00, 'month', null, null, true,  false, 'Fines accumulate monthly per incidence until resolved', 'owner'),
  ('nuisance',         '§2 Nuisances',                     'Nuisance',                                    25.00, 'call',  null, null, false, false, 'Per call', 'owner'),
  ('smoking',          '§2 Nuisances',                     'Smoking',                                     25.00, 'occurrence', null, null, false, false, null, 'owner'),
  ('hazardous',        '§2 Nuisances',                     'Hazardous discharge',                         25.00, 'occurrence', null, null, false, false, null, 'owner'),
  ('litter',           '§2 Garbage',                       'Litter',                                       5.00, 'occurrence', null, null, false, false, null, 'owner'),
  ('building_materials','§2 Garbage',                      'Building materials in garbage',               25.00, 'occurrence', null, null, false, false, null, 'owner'),
  ('barbecue',         '§2 Garbage',                       'Barbecue',                                    50.00, 'occurrence', null, null, false, false, null, 'owner'),
  ('barbecue_debris',  '§2 Garbage',                       'Barbecue debris not cleared',                 50.00, 'occurrence', null, null, false, false, null, 'owner'),
  ('oversized_litter', '§2 Garbage',                       'Oversized litter',                           150.00, 'occurrence', null, null, false, false, null, 'owner'),
  ('unassigned_vehicle','§2 Parking 3',                    'Unregistered / unassigned vehicle',           50.00, 'occurrence', null, null, false, true,  null, 'owner'),
  ('vehicle_storage',  '§2 Parking 5',                     'Vehicle storage',                             35.00, 'week',  null, null, true,  true,  null, 'owner'),
  ('parking_stall',    '§2 Parking',                       'Parking stall violation',                     null,  'other', null, null, false, true,  'Towing at the vehicle owner''s expense', 'owner'),
  ('vehicle_type',     '§2 Parking',                       'Vehicle type',                                 5.00, 'day',  100.00, 'month', true, true, '$5.00 per day up to $100.00 per month', 'owner'),
  ('inoperable_vehicle','§2 Parking',                      'Inoperable, restricted or unregistered vehicle', null, 'other', null, null, false, true, 'Towing', 'owner'),
  ('encroachment',     '§2 Parking',                       'Parking encroachment',                         5.50, 'occurrence', null, null, false, true, null, 'owner'),
  ('commercial_vehicle','§2 Parking',                      'Commercial vehicle',                           2.50, 'day',   50.00, 'month', true, true, '$2.50 per day up to $50.00 per month', 'owner'),
  ('repair_washing',   '§2 Parking',                       'Vehicle repair or washing',                   35.00, 'occurrence', null, null, false, true, null, 'owner'),
  ('parking_garbage',  '§2 Parking 13',                    'Garbage in parking stall',                     5.00, 'occurrence', null, null, false, true, null, 'owner'),
  ('unassigned_parking','§2 Parking 14',                   'Parking in another unit''s stall',            35.00, 'occurrence', null, null, false, true, null, 'owner'),
  ('fire_lane',        '§2 Parking',                       'Fire lane parking',                           55.00, 'occurrence', null, null, false, true, null, 'owner'),
  ('snow_non_removal', '§2 Parking',                       'Vehicle not removed (snow)',                 105.00, 'occurrence', null, null, false, true, null, 'owner'),
  ('snow_failure',     '§2 Parking',                       'Failure to remove snow',                      35.00, 'occurrence', null, null, false, true, null, 'owner'),
  ('guest_stall',      '§2 Parking 25',                    'Guest occupying a stall',                     25.00, 'occurrence', null, null, false, true, 'Charged to the occupant of the unit', 'occupant'),
  ('laundry',          '§2 Laundry Room',                  'Laundry room',                                15.00, 'occurrence', null, null, false, false, null, 'owner'),
  ('laundry_overflow', '§2 Laundry Room',                  'Laundry overflow',                            95.00, 'occurrence', null, null, false, false, null, 'owner'),
  ('door_propped',     '§2 Security 3',                    'Entry door propped open',                     25.00, 'occurrence', null, null, false, false, null, 'owner'),
  ('dog_size',         '§3 Pets',                          'Dog larger than the size limit',               7.00, 'day',  145.00, 'month', true, false, '$7.00 per day not to exceed $145.00 per month', 'owner'),
  ('pet_visit',        '§3 Pets',                          'Pet visit',                                  100.00, 'occurrence', null, null, false, false, null, 'owner'),
  ('pet_dropping',     '§3 Pets',                          'Pet dropping',                                25.00, 'occurrence', null, null, false, false, null, 'owner'),
  ('leash',            '§3 Pets',                          'Leash',                                       50.00, 'occurrence', null, null, false, false, null, 'owner'),
  ('cat',              '§3 Pets',                          'Cat',                                         20.00, 'occurrence', null, null, false, false, null, 'owner'),
  ('visitor_pet',      '§3 Pets — Visitors 1',             'Visitor pet',                                 50.00, 'occurrence', null, null, false, false, null, 'owner'),
  ('visitor_occupancy','§3 Pets — Visitors 2',             'Visitor over 13 nights in 12 months',         25.00, 'night', null, null, false, false, '$25 per day not to exceed one half (1/2) the monthly rent; charged to the Lessee', 'occupant'),
  ('rent_collection',  '§5 Leasing of Units',              'Direct rent collection by a Class C member',  null,  'incident', null, null, false, false, '100% of rent collected per incident', 'owner'),
  ('false_owner_occupancy','§5 Ownership 4',               'False claim of owner occupancy',             750.00, 'month', null, null, true, false, 'Non-compliant fee each month the unit remains indirectly occupied', 'owner'),
  ('leasing',          '§5 General',                       'Class C member directly leasing (leasing fine)', 700.00, 'month', null, null, true, false, 'Due by the 9th; $25 late fee on the 10th; lien on the 16th of the following month if unpaid', 'owner'),
  ('prohibited_move',  '§6 Move-In/Move-Out 1',            'Prohibited move',                            150.00, 'occurrence', null, null, false, false, null, 'owner'),
  ('construction_material','§7 Construction 1',            'Construction material in ROCA1 container',  150.00, 'occurrence', null, null, false, false, null, 'owner'),
  ('construction_cleaning','§7 Construction 2',            'Cleaning after construction',               200.00, 'occurrence', null, null, false, false, null, 'owner'),
  ('device_install',   '§9 Video Recording Devices',       'Device installation',                        15.00, 'day',  215.00, 'month', true, false, '$15.00 per day per device not to exceed $215 per month per device', 'owner'),
  ('device_pointing',  '§9 Video Recording Devices',       'Device pointing',                            15.00, 'day',  215.00, 'month', true, false, '$15.00 per day per device not to exceed $215 per month per device', 'owner'),
  ('device_login',     '§9 Video Recording Devices',       'Device login ID and password not provided',  15.00, 'day',  215.00, 'month', true, false, '$15.00 per day per device not to exceed $215 per month per device', 'owner'),
  ('other',            'Rules §10',                        'Other violation (amount set by the board)',   null,  'other', null, null, false, false, 'Enter the amount', 'owner')
on conflict (code) do nothing;

-- Widen condo_violations (existing statuses all kept).
alter table condo_violations drop constraint if exists condo_violations_status_check;
alter table condo_violations add constraint condo_violations_status_check check (status in
  ('open', 'notice_sent', 'fined', 'cured', 'dismissed',                                   -- original
   'hearing_requested', 'hearing_scheduled', 'final', 'waived'));                          -- 20261106080000
alter table condo_violations
  add column if not exists fine_code text references roca_fine_schedule(code),
  add column if not exists process text check (process in ('fine_notice', 'hearing')),
  add column if not exists complaint_source text,
  add column if not exists continuing boolean not null default false,
  add column if not exists bill_tenant boolean not null default false,
  add column if not exists lease_id uuid references leases(id),
  add column if not exists notice_sent_at timestamptz,
  add column if not exists appeal_deadline date,
  add column if not exists hearing_requested_at timestamptz,
  add column if not exists hearing_request_note text,
  add column if not exists hearing_at timestamptz,
  add column if not exists hearing_place text,
  add column if not exists resolution_id uuid references roca_resolutions(id),
  add column if not exists decision_due date,
  add column if not exists decision_note text,
  add column if not exists final_at timestamptz,
  add column if not exists accrued_through date,
  add column if not exists cured_on date;

create table if not exists roca_violation_charges (
  id bigint generated always as identity primary key,
  violation_id bigint not null references condo_violations(id),
  kind text not null check (kind in ('fine', 'accrual', 'waiver', 'tenant_fine', 'tenant_waiver')),
  period_from date not null,
  period_to date not null,
  amount numeric(12,2) not null,
  condo_entry_id bigint references condo_ledger_entries(id),
  lease_entry_id bigint references lease_ledger_entries(id),
  resolution_id uuid references roca_resolutions(id),
  created_by text,
  created_at timestamptz not null default now()
);
create unique index if not exists roca_violation_charges_once on roca_violation_charges (violation_id, kind, period_from) where kind in ('fine', 'accrual', 'tenant_fine');
alter table roca_fine_schedule enable row level security;
alter table roca_violation_charges enable row level security;

insert into portal_settings (key, value) values
  ('roca_appeal_days', '14'),                  -- Rules §10.3
  ('roca_hearing_place', '6626 N. Bourbon St., Milwaukee, WI 53224 (lobby) or by video call'),
  ('roca_deduction_order', 'fines_fees,assessments,dues_current,older_balance')  -- Rules §11 PAYMENT OF FINES/FEES 1
on conflict (key) do nothing;

-- Business day n days after d (weekends and court holidays skipped) — "within five (5) business days".
create or replace function roca_business_days_after(p_day date, p_n int)
returns date language plpgsql stable set search_path = public as $$
declare d date := p_day; k int := 0;
begin
  while k < p_n loop
    d := d + 1;
    if extract(isodow from d) < 6 and not exists (select 1 from court_holidays h where h.day = d) then k := k + 1; end if;
  end loop;
  return d;
end;
$$;

create or replace function roca_unit_owner_on(p_unit text, p_day date)
returns table (owner_id uuid, name text, email text)
language sql stable security definer set search_path = public as $$
  select o.id, o.name, o.email from condo_ownerships s join condo_units u on u.id = s.unit_id join condo_owners o on o.id = s.owner_id
  where u.unit_number = p_unit and (s.start_date is null or s.start_date <= p_day) and (s.end_date is null or s.end_date >= p_day)
  order by s.is_current desc, s.start_date desc nulls last limit 1;
$$;
revoke all on function roca_unit_owner_on(text, date) from public, anon, authenticated;

-- The 2nd Chance lease on a condo unit on a day (for tenant pass-through and occupant notices).
create or replace function roca_unit_lease_on(p_unit text, p_day date)
returns uuid
language sql stable security definer set search_path = public as $$
  select l.id from leases l join rental_units ru on ru.id = l.unit_id join condo_units cu on cu.id = ru.condo_unit_id
  where cu.unit_number = p_unit and coalesce(l.start_date, p_day) <= p_day and (l.end_date is null or l.end_date >= p_day) and l.status in ('active', 'past')
  order by l.start_date desc nulls last limit 1;
$$;
revoke all on function roca_unit_lease_on(text, date) from public, anon, authenticated;

create or replace function roca_violation_row(v condo_violations)
returns jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(v) || jsonb_build_object(
    'unit', (select unit_number from condo_units where id = v.unit_id),
    'owner', (select name from condo_owners where id = v.owner_id),
    'schedule', (select to_jsonb(f) from roca_fine_schedule f where f.code = v.fine_code),
    'charged', coalesce((select sum(amount) from roca_violation_charges c where c.violation_id = v.id and c.kind in ('fine', 'accrual', 'waiver')), 0),
    'tenant_charged', coalesce((select sum(amount) from roca_violation_charges c where c.violation_id = v.id and c.kind in ('tenant_fine', 'tenant_waiver')), 0),
    'charges', coalesce((select jsonb_agg(to_jsonb(c) order by c.period_from, c.id) from roca_violation_charges c where c.violation_id = v.id), '[]'::jsonb),
    'resolution', (select jsonb_build_object('id', r.id, 'number', r.number, 'status', r.status, 'title', r.title) from roca_resolutions r where r.id = v.resolution_id),
    'waivers', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'number', r.number, 'status', r.status, 'amount', r.payload->'amount')) from roca_resolutions r
                         where r.kind = 'fine_waiver' and (r.payload->>'violation_id')::bigint = v.id), '[]'::jsonb));
$$;
revoke all on function roca_violation_row(condo_violations) from public, anon, authenticated;

-- Post one fine/accrual to the owner's association ledger (and the tenant's lease ledger when billed through).
create or replace function roca_violation_post(p_id bigint, p_kind text, p_from date, p_to date, p_amount numeric, p_desc text, p_res uuid, p_by text)
returns numeric
language plpgsql volatile security definer set search_path = public as $$
declare v condo_violations; v_unit text; v_acct uuid; v_ce bigint; v_le bigint; f roca_fine_schedule;
begin
  select * into v from condo_violations where id = p_id;
  select unit_number into v_unit from condo_units where id = v.unit_id;
  select * into f from roca_fine_schedule where code = v.fine_code;
  if coalesce(p_amount, 0) <= 0 then return 0; end if;
  if exists (select 1 from roca_violation_charges where violation_id = p_id and kind = p_kind and period_from = p_from) then return 0; end if;
  v_acct := roca_unit_account(v_unit);
  if v_acct is null then raise exception 'Unit % has no association account to charge.', v_unit; end if;
  insert into condo_ledger_entries (account_id, gl_account, entry_date, kind, raw_type, description, amount, origin, entered_by, correction_note)
  values (v_acct, 'Fines', greatest(p_to, p_from), 'charge', 'Fine', p_desc, p_amount, 'billing', p_by,
          'Violation #' || p_id || coalesce(' (' || f.section || ')', '') || '; Rules & Regulations 2024 §10' || coalesce('; resolution ' || (select number from roca_resolutions where id = p_res), ''))
  returning id into v_ce;
  insert into roca_violation_charges (violation_id, kind, period_from, period_to, amount, condo_entry_id, resolution_id, created_by)
  values (p_id, p_kind, p_from, p_to, p_amount, v_ce, p_res, p_by);
  if v.bill_tenant and v.lease_id is not null then
    insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, description, amount, source, correction_note)
    values (v.lease_id, 'Association Fines', greatest(p_to, p_from), 'charge', 'Charge', 'ROCA1 fine passed through: ' || p_desc, p_amount, 'roca_violation',
            'Association violation #' || p_id || ' billed to the tenant (lease: parking addendum cost recovery; ROCA1 Rules incorporated)')
    returning id into v_le;
    insert into roca_violation_charges (violation_id, kind, period_from, period_to, amount, lease_entry_id, resolution_id, created_by)
    values (p_id, 'tenant_fine', p_from, p_to, p_amount, v_le, p_res, p_by);
  end if;
  return p_amount;
end;
$$;
revoke all on function roca_violation_post(bigint, text, date, date, numeric, text, uuid, text) from public, anon, authenticated;

create or replace function roca_violation_label(v condo_violations)
returns text language sql stable security definer set search_path = public as $$
  select coalesce((select title from roca_fine_schedule where code = v.fine_code), v.category) || ' — Unit ' || (select unit_number from condo_units where id = v.unit_id);
$$;
revoke all on function roca_violation_label(condo_violations) from public, anon, authenticated;

-- Email the owner (and the tenant when the fine is passed through).
create or replace function roca_violation_email(p_id bigint, p_subject text, p_html text)
returns int
language plpgsql volatile security definer set search_path = public as $$
declare v condo_violations; o record; n int := 0;
begin
  select * into v from condo_violations where id = p_id;
  select * into o from condo_owners where id = v.owner_id;
  if o.email is not null then
    insert into email_outbox (to_email, subject, html, kind) values (o.email, p_subject,
      '<p>Dear ' || repair_esc(coalesce(o.name, 'Owner')) || ',</p>' || p_html || '<p>Royal Orleans Condominium Association – Addition 1 (ROCA1)</p>', 'roca_violation');
    n := 1;
  end if;
  if v.bill_tenant and v.lease_id is not null then
    n := n + lease_email_tenants(v.lease_id, p_subject, p_html || '<p>Royal Orleans Condominium Association – Addition 1 (ROCA1), through 2nd Chance Housing</p>', 'roca_violation');
  end if;
  return n;
end;
$$;
revoke all on function roca_violation_email(bigint, text, text) from public, anon, authenticated;

-- First fine amount for a violation: the override, else the schedule amount for one period.
create or replace function roca_violation_amount(v condo_violations)
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce(v.fine_amount, (select amount from roca_fine_schedule where code = v.fine_code));
$$;
revoke all on function roca_violation_amount(condo_violations) from public, anon, authenticated;

-- Make the fine final and post it (no hearing requested in time, or a board decision).
create or replace function roca_violation_finalize(p_id bigint, p_res uuid, p_by text)
returns numeric
language plpgsql volatile security definer set search_path = public as $$
declare v condo_violations; v_amt numeric; v_posted numeric; f roca_fine_schedule;
begin
  select * into v from condo_violations where id = p_id for update;
  select * into f from roca_fine_schedule where code = v.fine_code;
  v_amt := roca_violation_amount(v);
  if coalesce(v_amt, 0) <= 0 then raise exception 'Violation #% has no fine amount. Enter one first.', p_id; end if;
  v_posted := roca_violation_post(p_id, 'fine', v.observed_date, current_date, v_amt,
    roca_violation_label(v) || ': ' || left(v.description, 120), p_res, p_by);
  update condo_violations set status = 'final', fine_amount = v_amt, final_at = now(),
    -- A continuing fine accrues from the day of the written notice (the notice says it continues until cured).
    accrued_through = case when v.continuing then coalesce((v.notice_sent_at at time zone 'America/Chicago')::date, current_date) end, updated_at = now() where id = p_id;
  return v_posted;
end;
$$;
revoke all on function roca_violation_finalize(bigint, uuid, text) from public, anon, authenticated;

-- Accrue a continuing violation up to p_today. Monthly basis: one fine per full month after the final date.
-- Day/week/night basis: completed calendar months, capped per month where the schedule says so.
create or replace function roca_violation_accrue(p_id bigint, p_today date, p_live boolean)
returns numeric
language plpgsql volatile security definer set search_path = public as $$
declare v condo_violations; f roca_fine_schedule; d date; m_end date; n int; amt numeric; total numeric := 0; v_rate numeric;
begin
  select * into v from condo_violations where id = p_id;
  select * into f from roca_fine_schedule where code = v.fine_code;
  if not v.continuing or v.status <> 'final' or v.accrued_through is null or f.code is null then return 0; end if;
  v_rate := coalesce(v.fine_amount, f.amount);
  d := v.accrued_through;
  loop
    if f.basis = 'month' then
      m_end := (d + interval '1 month')::date;
      exit when m_end > p_today;
      amt := v_rate;
    elsif f.basis in ('day', 'night', 'week') then
      m_end := (date_trunc('month', d + 1) + interval '1 month' - interval '1 day')::date;
      exit when m_end >= p_today or m_end <= d;
      n := m_end - d;
      amt := case when f.basis = 'week' then floor(n / 7.0) * v_rate else n * v_rate end;
      if f.cap_amount is not null then amt := least(amt, f.cap_amount); end if;
    else
      exit;
    end if;
    if p_live then
      perform roca_violation_post(p_id, 'accrual', d + 1, m_end, amt,
        roca_violation_label(v) || ': continuing, ' || to_char(d + 1, 'FMMM/FMDD/YYYY') || '–' || to_char(m_end, 'FMMM/FMDD/YYYY'), null, 'automation');
      update condo_violations set accrued_through = m_end, updated_at = now() where id = p_id;
    end if;
    total := total + amt;
    d := m_end;
  end loop;
  return total;
end;
$$;
revoke all on function roca_violation_accrue(bigint, date, boolean) from public, anon, authenticated;

-- The Records page overview (20261103000000) counts open violations and unpaid fines by status: count the new
-- statuses too. Patched in place so the rest of that function stays exactly as it is.
do $patch$
declare d text; d2 text;
begin
  d := pg_get_functiondef('public.condo_staff_records_overview()'::regprocedure);
  d2 := replace(d, $q$v.status in ('open', 'notice_sent', 'fined')$q$, $q$v.status in ('open', 'notice_sent', 'fined', 'hearing_requested', 'hearing_scheduled', 'final')$q$);
  d2 := replace(d2, $q$v.status = 'fined')$q$, $q$v.status in ('fined', 'final'))$q$);
  if d2 = d and position('hearing_requested' in d) = 0 then raise exception 'condo_staff_records_overview changed; update this patch'; end if;
  execute d2;
end
$patch$;

-- ---------------------------------------------------------------------------
-- Staff
create or replace function roca_fine_schedule_list()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform roca_staff_check();
  return coalesce((select jsonb_agg(to_jsonb(f) order by f.section, f.title) from roca_fine_schedule f where f.active), '[]'::jsonb);
end;
$$;
revoke all on function roca_fine_schedule_list() from public, anon;
grant execute on function roca_fine_schedule_list() to authenticated;

create or replace function roca_violations_staff_list(p_all boolean default false)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform roca_staff_check();
  return coalesce((select jsonb_agg(roca_violation_row(v) order by (v.status in ('hearing_requested', 'open')) desc, v.observed_date desc, v.id desc)
    from condo_violations v where coalesce(p_all, false) or v.status not in ('cured', 'dismissed', 'waived') or v.updated_at > now() - interval '60 days'), '[]'::jsonb);
end;
$$;
revoke all on function roca_violations_staff_list(boolean) from public, anon;
grant execute on function roca_violations_staff_list(boolean) to authenticated;

-- A complaint. Source: staff, owner, occupant, board, inspection, maintenance (Rules §10.1).
create or replace function roca_violation_create(p_unit text, p_code text, p_description text, p_observed date, p_complainant text,
  p_source text, p_amount numeric, p_continuing boolean, p_bill_tenant boolean)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v condo_violations; f roca_fine_schedule; v_unit uuid; v_day date := coalesce(p_observed, current_date); v_lease uuid;
begin
  perform roca_staff_check();
  select id into v_unit from condo_units where unit_number = trim(p_unit);
  if v_unit is null then raise exception 'Unit % isn''t on file.', p_unit; end if;
  select * into f from roca_fine_schedule where code = p_code and active;
  if f.code is null then raise exception 'Choose a rule from the fine schedule.'; end if;
  if length(coalesce(trim(p_description), '')) < 5 then raise exception 'Describe what happened (who, when, where).'; end if;
  if f.amount is null and coalesce(p_amount, 0) <= 0 then raise exception 'This rule has no fixed amount (%). Enter the fine amount.', coalesce(f.amount_note, 'set by the board'); end if;
  v_lease := roca_unit_lease_on(trim(p_unit), v_day);
  if coalesce(p_bill_tenant, false) and v_lease is null then raise exception 'No 2nd Chance lease on Unit % on that day, so there''s no tenant to bill.', p_unit; end if;
  insert into condo_violations (unit_id, owner_id, category, description, observed_date, reported_by, entered_by, fine_code, fine_amount, complaint_source,
    continuing, bill_tenant, lease_id)
  values (v_unit, (select owner_id from roca_unit_owner_on(trim(p_unit), v_day)), f.title, trim(p_description), v_day, nullif(trim(coalesce(p_complainant, '')), ''),
    lower(auth.email()), f.code, nullif(p_amount, 0), coalesce(nullif(p_source, ''), 'staff'), coalesce(p_continuing, f.accrues), coalesce(p_bill_tenant, false), v_lease)
  returning * into v;
  return roca_violation_row(v);
end;
$$;
revoke all on function roca_violation_create(text, text, text, date, text, text, numeric, boolean, boolean) from public, anon;
grant execute on function roca_violation_create(text, text, text, date, text, text, numeric, boolean, boolean) to authenticated;

-- Written notice (Rules §10.2–10.3). 'fine_notice': the fine and 14 days to ask for a hearing in writing.
-- 'hearing': notice of a hearing (time, place, right to counsel, evidence, possible fine + costs + lien).
create or replace function roca_violation_notice(p_id bigint, p_process text, p_hearing_at timestamptz, p_place text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v condo_violations; v_days int := coalesce((select value from portal_settings where key = 'roca_appeal_days'), '14')::int; v_amt numeric; v_html text; f roca_fine_schedule;
begin
  perform roca_staff_check();
  select * into v from condo_violations where id = p_id for update;
  if v.id is null then raise exception 'Violation not found'; end if;
  if v.status not in ('open', 'notice_sent') then raise exception 'A notice can be sent only for an open violation (this one is %).', v.status; end if;
  select * into f from roca_fine_schedule where code = v.fine_code;
  v_amt := roca_violation_amount(v);
  if p_process = 'fine_notice' then
    update condo_violations set status = 'notice_sent', process = 'fine_notice', notice_sent_at = now(), appeal_deadline = current_date + v_days, updated_at = now()
     where id = p_id returning * into v;
    v_html := '<p>This is written notice of a violation of the ROCA1 Rules &amp; Regulations at <b>Unit ' || repair_esc((select unit_number from condo_units where id = v.unit_id)) || '</b>:</p>'
      || '<p><b>' || repair_esc(roca_violation_label(v)) || '</b>' || coalesce(' (' || repair_esc(f.section) || ')', '') || ', observed ' || to_char(v.observed_date, 'FMMM/FMDD/YYYY') || '.<br>'
      || repair_esc(v.description) || '</p>'
      || '<p>A fine of <b>' || to_char(v_amt, 'FM$999,990.00') || '</b>' || case when v.continuing then ' ' || coalesce(repair_esc(f.amount_note), 'continuing until the violation is cured') else '' end
      || ' is assessed under the fine schedule' || case when f.immediate then ' (parking offenses are fined without warning, Rules §11)' else '' end || '. It will be charged to the unit''s association account.</p>'
      || '<p><b>You may appeal.</b> Request a hearing in writing by <b>' || to_char(v.appeal_deadline, 'FMMonth FMDD, YYYY') || '</b> (fourteen days) in the owner portal (https://2ndchinc.org/association-owners/roca1/#violations) or by email. '
      || 'A timely request suspends the fine until the board hears it (By-Laws §1502). If no request is made, the fine becomes final (Rules §10.4).</p>'
      || case when v.bill_tenant then '<p>Because the violation was caused at a unit 2nd Chance Housing leases, the fine is also billed to the tenant under the lease.</p>' else '' end;
    perform roca_violation_email(p_id, 'Notice of violation and fine — ' || roca_violation_label(v), v_html);
  elsif p_process = 'hearing' then
    if p_hearing_at is null or p_hearing_at < now() then raise exception 'Choose a hearing date and time in the future.'; end if;
    update condo_violations set process = 'hearing', notice_sent_at = now(), updated_at = now() where id = p_id;
    return roca_violation_schedule_hearing_core(p_id, p_hearing_at, p_place);
  else
    raise exception 'Choose fine_notice or hearing.';
  end if;
  return roca_violation_row(v);
end;
$$;

-- Schedule a hearing (on the owner's request, or as the first notice) and draft the board's decision.
create or replace function roca_violation_schedule_hearing_core(p_id bigint, p_at timestamptz, p_place text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v condo_violations; v_res uuid; v_place text := coalesce(nullif(trim(coalesce(p_place, '')), ''), (select value from portal_settings where key = 'roca_hearing_place'));
  v_amt numeric; v_unit text;
begin
  select * into v from condo_violations where id = p_id for update;
  v_unit := (select unit_number from condo_units where id = v.unit_id);
  v_amt := roca_violation_amount(v);
  if v.resolution_id is null then
    v_res := roca_resolution_propose('violation_decision', 'Hearing: ' || roca_violation_label(v),
      'RESOLVED, that after a hearing held ' || to_char(p_at at time zone 'America/Chicago', 'FMMonth FMDD, YYYY at FMHH12:MI AM') || ', the Board finds by a preponderance of the evidence that the violation at Unit '
      || v_unit || ' (' || roca_violation_label(v) || ') occurred, and imposes a fine of ' || to_char(v_amt, 'FM$999,990.00')
      || ' charged to the Unit Owner''s assessment account (Rules & Regulations 2024 §10). A NO vote dismisses the complaint.'
      || E'\n\nDirectors directly or indirectly involved in the dispute must vote "recused". The Chairperson votes only to break a tie.',
      'board_hearing', jsonb_build_object('violation_id', p_id, 'amount', v_amt, 'unit', v_unit), 'manual', null, coalesce(lower(auth.email()), 'automation'));
  else
    v_res := v.resolution_id;
  end if;
  update condo_violations set status = 'hearing_scheduled', hearing_at = p_at, hearing_place = v_place, resolution_id = v_res,
    decision_due = roca_business_days_after((p_at at time zone 'America/Chicago')::date, 5), updated_at = now()
   where id = p_id returning * into v;
  perform roca_violation_email(p_id, 'Notice of hearing — ' || roca_violation_label(v),
    '<p>The ROCA1 Board of Directors will hold a hearing on the complaint below.</p>'
    || '<p><b>' || repair_esc(roca_violation_label(v)) || '</b>, observed ' || to_char(v.observed_date, 'FMMM/FMDD/YYYY') || ': ' || repair_esc(v.description) || '</p>'
    || '<ul><li><b>When:</b> ' || to_char(p_at at time zone 'America/Chicago', 'FMDay, FMMonth FMDD, YYYY at FMHH12:MI AM') || '</li><li><b>Where:</b> ' || repair_esc(v_place) || '</li>'
    || '<li>You have the right to counsel.</li><li>Evidence will be received and a record made whether or not you attend.</li>'
    || '<li>If a violation is found, a fine may be imposed under the fine schedule (here ' || to_char(v_amt, 'FM$999,990.00') || '), plus costs and actual attorney fees incurred by ROCA1.</li>'
    || '<li>Any fine imposed may be secured by filing a lien against the unit, as prescribed by law.</li></ul>'
    || '<p>The Board''s written decision will be sent within five business days of the hearing (by ' || to_char(v.decision_due, 'FMMonth FMDD, YYYY') || ').</p>');
  return roca_violation_row(v);
end;
$$;
revoke all on function roca_violation_schedule_hearing_core(bigint, timestamptz, text) from public, anon, authenticated;
revoke all on function roca_violation_notice(bigint, text, timestamptz, text) from public, anon;
grant execute on function roca_violation_notice(bigint, text, timestamptz, text) to authenticated;

create or replace function roca_violation_schedule_hearing(p_id bigint, p_at timestamptz, p_place text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v condo_violations;
begin
  perform roca_staff_check();
  select * into v from condo_violations where id = p_id;
  if v.status not in ('hearing_requested', 'hearing_scheduled', 'open', 'notice_sent') then raise exception 'This violation is % — no hearing can be scheduled.', v.status; end if;
  if p_at is null or p_at < now() then raise exception 'Choose a hearing date and time in the future.'; end if;
  if v.resolution_id is not null and (select status from roca_resolutions where id = v.resolution_id) <> 'draft' then
    raise exception 'The board is already deciding this one (resolution %).', (select number from roca_resolutions where id = v.resolution_id); end if;
  update condo_violations set process = 'hearing' where id = p_id;
  return roca_violation_schedule_hearing_core(p_id, p_at, p_place);
end;
$$;
revoke all on function roca_violation_schedule_hearing(bigint, timestamptz, text) from public, anon;
grant execute on function roca_violation_schedule_hearing(bigint, timestamptz, text) to authenticated;

-- Staff: finalize now (e.g. the owner said in writing they won't appeal) — only after the notice.
create or replace function roca_violation_finalize_staff(p_id bigint, p_note text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v condo_violations;
begin
  perform roca_staff_check();
  select * into v from condo_violations where id = p_id;
  if v.status <> 'notice_sent' then raise exception 'Only a violation whose fine notice was sent can be made final here.'; end if;
  if v.appeal_deadline >= current_date and length(coalesce(trim(p_note), '')) < 5 then
    raise exception 'The appeal window is open until %. Say why it is final early (e.g. the owner waived a hearing in writing).', to_char(v.appeal_deadline, 'FMMM/FMDD/YYYY'); end if;
  perform roca_violation_finalize(p_id, null, lower(auth.email()));
  update condo_violations set decision_note = nullif(trim(coalesce(p_note, '')), '') where id = p_id returning * into v;
  return roca_violation_row(v);
end;
$$;
revoke all on function roca_violation_finalize_staff(bigint, text) from public, anon;
grant execute on function roca_violation_finalize_staff(bigint, text) to authenticated;

create or replace function roca_violation_cure(p_id bigint, p_cured_on date, p_note text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v condo_violations;
begin
  perform roca_staff_check();
  if length(coalesce(trim(p_note), '')) < 3 then raise exception 'Say how it was cured.'; end if;
  -- Cured stops accruals; any fine already charged stays owed.
  update condo_violations set status = 'cured', cured_on = coalesce(p_cured_on, current_date), continuing = false,
    resolved_date = coalesce(p_cured_on, current_date), resolution_note = trim(p_note), updated_at = now()
   where id = p_id and status not in ('dismissed', 'waived', 'cured') returning * into v;
  if v.id is null then raise exception 'Violation not found or already closed.'; end if;
  return roca_violation_row(v);
end;
$$;
revoke all on function roca_violation_cure(bigint, date, text) from public, anon;
grant execute on function roca_violation_cure(bigint, date, text) to authenticated;

create or replace function roca_violation_dismiss(p_id bigint, p_note text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v condo_violations;
begin
  perform roca_staff_check();
  if length(coalesce(trim(p_note), '')) < 3 then raise exception 'Say why it is dismissed.'; end if;
  if exists (select 1 from roca_violation_charges where violation_id = p_id and kind in ('fine', 'accrual')) then
    raise exception 'A fine was already charged. Removing it needs a board decision: propose a waiver.'; end if;
  update condo_violations set status = 'dismissed', resolved_date = current_date, resolution_note = trim(p_note), continuing = false, updated_at = now()
   where id = p_id and status not in ('final', 'cured', 'waived', 'dismissed') returning * into v;
  if v.id is null then raise exception 'Only a violation not yet fined can be dismissed.'; end if;
  if v.resolution_id is not null then
    update roca_resolutions set status = 'withdrawn', decided_at = now(), decided_by = lower(auth.email()), updated_at = now(),
      origin_note = concat_ws(' · ', origin_note, 'Withdrawn: complaint dismissed') where id = v.resolution_id and status in ('draft', 'voting');
  end if;
  if v.notice_sent_at is not null then
    perform roca_violation_email(p_id, 'Violation dismissed — ' || roca_violation_label(v), '<p>The complaint (' || repair_esc(roca_violation_label(v)) || ') has been dismissed. No fine is owed. ' || repair_esc(trim(p_note)) || '</p>');
  end if;
  return roca_violation_row(v);
end;
$$;
revoke all on function roca_violation_dismiss(bigint, text) from public, anon;
grant execute on function roca_violation_dismiss(bigint, text) to authenticated;

-- Waiving a fine needs a board decision (Rules §5: "A board decision is necessary to waive fees").
create or replace function roca_violation_propose_waiver(p_id bigint, p_amount numeric, p_reason text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v condo_violations; v_charged numeric; v_res uuid; r roca_resolutions;
begin
  perform roca_staff_check();
  select * into v from condo_violations where id = p_id;
  select coalesce(sum(amount), 0) into v_charged from roca_violation_charges where violation_id = p_id and kind in ('fine', 'accrual', 'waiver');
  if v_charged <= 0 then raise exception 'Nothing has been charged on this violation to waive.'; end if;
  if coalesce(p_amount, 0) <= 0 or p_amount > v_charged then raise exception 'Waive between $0.01 and %.', to_char(v_charged, 'FM$999,990.00'); end if;
  if length(coalesce(trim(p_reason), '')) < 5 then raise exception 'Give the reason for the waiver.'; end if;
  v_res := roca_resolution_propose('fine_waiver', 'Waive ' || to_char(p_amount, 'FM$999,990.00') || ' of the fine: ' || roca_violation_label(v),
    'RESOLVED, that the Board waives ' || to_char(p_amount, 'FM$999,990.00') || ' of the fine charged for ' || roca_violation_label(v) || ' (violation #' || p_id || '). Reason: ' || trim(p_reason)
    || E'\nThe fine stays on the ledger; the waiver is posted as a credit (Rules & Regulations 2024 §5: a board decision is necessary to waive fees).',
    'board_majority_all', jsonb_build_object('violation_id', p_id, 'amount', p_amount, 'reason', trim(p_reason)), 'manual', null, lower(auth.email()));
  select * into r from roca_resolutions where id = v_res;
  return roca_row(r);
end;
$$;
revoke all on function roca_violation_propose_waiver(bigint, numeric, text) from public, anon;
grant execute on function roca_violation_propose_waiver(bigint, numeric, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Executors (called by the governance core when a resolution is adopted)
create or replace function roca_exec_violation_decision(p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare r roca_resolutions; v condo_violations; v_vid bigint; v_amt numeric; v_posted numeric;
begin
  select * into r from roca_resolutions where id = p_id;
  v_vid := (r.payload->>'violation_id')::bigint;
  select * into v from condo_violations where id = v_vid for update;
  if v.id is null then raise exception 'Violation % not found', v_vid; end if;
  v_amt := coalesce((r.payload->>'amount')::numeric, roca_violation_amount(v));
  update condo_violations set fine_amount = v_amt where id = v_vid;
  v_posted := roca_violation_finalize(v_vid, p_id, 'resolution ' || r.number);
  update condo_violations set decision_note = 'Board found the violation occurred (resolution ' || r.number || ').' where id = v_vid returning * into v;
  perform roca_violation_email(v_vid, 'Board decision — ' || roca_violation_label(v),
    '<p>After the hearing, the Board of Directors found by a preponderance of the evidence that the violation occurred: <b>' || repair_esc(roca_violation_label(v)) || '</b>.</p>'
    || '<p>A fine of <b>' || to_char(v_amt, 'FM$999,990.00') || '</b> has been charged to the unit''s association account' || case when v.continuing then ', and continues to accrue under the fine schedule until the violation is cured' else '' end
    || '. Fines are collectible in the same manner as assessments (Rules &amp; Regulations 2024 §10). The decision of the Board is final.</p><p>Resolution ' || r.number || '.</p>');
  return jsonb_build_object('violation_id', v_vid, 'fine_posted', v_posted);
end;
$$;
revoke all on function roca_exec_violation_decision(uuid) from public, anon, authenticated;

create or replace function roca_exec_fine_waiver(p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare r roca_resolutions; v condo_violations; v_vid bigint; v_amt numeric; v_acct uuid; v_ce bigint; v_le bigint; v_tenant numeric; v_charged numeric;
begin
  select * into r from roca_resolutions where id = p_id;
  v_vid := (r.payload->>'violation_id')::bigint; v_amt := (r.payload->>'amount')::numeric;
  select * into v from condo_violations where id = v_vid for update;
  v_acct := roca_unit_account((select unit_number from condo_units where id = v.unit_id));
  insert into condo_ledger_entries (account_id, gl_account, entry_date, kind, raw_type, description, amount, origin, entered_by, correction_note)
  values (v_acct, 'Fines', current_date, 'credit', 'Fine waived', 'Fine waived by the Board: ' || roca_violation_label(v), -v_amt, 'staff', 'resolution ' || r.number,
          'Violation #' || v_vid || '; waiver adopted as resolution ' || r.number || ' (Rules & Regulations 2024 §5). The fine line stays on the ledger.')
  returning id into v_ce;
  insert into roca_violation_charges (violation_id, kind, period_from, period_to, amount, condo_entry_id, resolution_id, created_by)
  values (v_vid, 'waiver', current_date, current_date, -v_amt, v_ce, p_id, 'resolution ' || r.number);
  -- The tenant's pass-through charge is credited by the same amount, up to what the tenant was billed.
  select coalesce(sum(amount), 0) into v_tenant from roca_violation_charges where violation_id = v_vid and kind in ('tenant_fine', 'tenant_waiver');
  if v_tenant > 0 and v.lease_id is not null then
    insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, description, amount, source, correction_note)
    values (v.lease_id, 'Association Fines', current_date, 'credit', 'Credit', 'ROCA1 fine waived by the Board', -least(v_amt, v_tenant), 'roca_violation', 'Association violation #' || v_vid || '; resolution ' || r.number)
    returning id into v_le;
    insert into roca_violation_charges (violation_id, kind, period_from, period_to, amount, lease_entry_id, resolution_id, created_by)
    values (v_vid, 'tenant_waiver', current_date, current_date, -least(v_amt, v_tenant), v_le, p_id, 'resolution ' || r.number);
  end if;
  select coalesce(sum(amount), 0) into v_charged from roca_violation_charges where violation_id = v_vid and kind in ('fine', 'accrual', 'waiver');
  update condo_violations set status = case when v_charged <= 0 then 'waived' else status end,
    continuing = case when v_charged <= 0 then false else continuing end, updated_at = now() where id = v_vid returning * into v;
  perform roca_violation_email(v_vid, 'Fine waived — ' || roca_violation_label(v),
    '<p>The Board waived <b>' || to_char(v_amt, 'FM$999,990.00') || '</b> of the fine for ' || repair_esc(roca_violation_label(v)) || ' (resolution ' || r.number || '). It is credited to the unit''s association account.</p>');
  return jsonb_build_object('violation_id', v_vid, 'credited', v_amt);
end;
$$;
revoke all on function roca_exec_fine_waiver(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Automation: appeal windows that passed, continuing fines, hearings the board rejected.
create or replace function roca_auto_violations(p_today date, p_live boolean)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v condo_violations; n_final int := 0; amt_final numeric := 0; n_acc int := 0; amt_acc numeric := 0; n_dis int := 0; a numeric; late jsonb := '[]'::jsonb;
begin
  -- 1. Fine notices whose 14-day window passed with no hearing request → final (Rules §10.4).
  for v in select * from condo_violations where status = 'notice_sent' and process = 'fine_notice' and appeal_deadline < p_today loop
    n_final := n_final + 1; amt_final := amt_final + coalesce(roca_violation_amount(v), 0);
    if p_live then
      perform roca_violation_finalize(v.id, null, 'automation');
      perform roca_violation_email(v.id, 'Fine is final — ' || roca_violation_label(v),
        '<p>No hearing was requested by ' || to_char(v.appeal_deadline, 'FMMonth FMDD, YYYY') || ', so the fine of <b>' || to_char(roca_violation_amount(v), 'FM$999,990.00')
        || '</b> for ' || repair_esc(roca_violation_label(v)) || ' is final and has been charged to the unit''s association account (Rules &amp; Regulations 2024 §10.4).</p>');
    end if;
  end loop;
  -- 2. Continuing violations accrue until cured.
  for v in select * from condo_violations where status = 'final' and continuing loop
    a := roca_violation_accrue(v.id, p_today, p_live);
    if a > 0 then n_acc := n_acc + 1; amt_acc := amt_acc + a; end if;
  end loop;
  -- 3. Hearings the board decided against (resolution rejected) → dismissed, and the decision sent.
  for v in select cv.* from condo_violations cv join roca_resolutions r on r.id = cv.resolution_id
           where r.status = 'rejected' and cv.status in ('hearing_scheduled', 'hearing_requested') loop
    n_dis := n_dis + 1;
    if p_live then
      update condo_violations set status = 'dismissed', resolved_date = p_today, decision_note = 'Board did not find a violation (resolution ' || (select number from roca_resolutions where id = v.resolution_id) || ').', updated_at = now() where id = v.id;
      perform roca_violation_email(v.id, 'Board decision — complaint dismissed', '<p>After the hearing, the Board did not find a violation (' || repair_esc(roca_violation_label(v)) || '). The complaint is dismissed and no fine is owed.</p>');
    end if;
  end loop;
  -- 4. Written decisions running late (5 business days) — staff alert in the result.
  select coalesce(jsonb_agg(jsonb_build_object('violation_id', id, 'decision_due', decision_due)), '[]'::jsonb) into late
    from condo_violations where status = 'hearing_scheduled' and decision_due < p_today;
  return jsonb_build_object('finalized', n_final, 'finalized_amount', amt_final, 'accrued_violations', n_acc, 'accrued_amount', amt_acc, 'dismissed', n_dis, 'decisions_overdue', late);
end;
$$;
revoke all on function roca_auto_violations(date, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Owners: their units' violations; request a hearing in writing within the window.
create or replace function roca_my_unit_numbers()
returns setof text language sql stable security definer set search_path = public as $$
  select u.unit_number from condo_ownerships s join condo_units u on u.id = s.unit_id
  where s.is_current and s.owner_id = condo_owner_for_email(auth.email()) and condo_session_ok();
$$;
revoke all on function roca_my_unit_numbers() from public, anon, authenticated;

create or replace function roca_violations_mine()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if condo_owner_for_email(auth.email()) is null or not condo_session_ok() then raise exception 'Sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object('appeal_days', (select value from portal_settings where key = 'roca_appeal_days'),
    'violations', coalesce((select jsonb_agg(roca_violation_row(v) - 'entered_by' - 'reported_by' - 'lease_id' - 'charges' order by v.observed_date desc, v.id desc)
      from condo_violations v join condo_units u on u.id = v.unit_id
      where u.unit_number in (select roca_my_unit_numbers()) and v.notice_sent_at is not null), '[]'::jsonb));
end;
$$;
revoke all on function roca_violations_mine() from public, anon;
grant execute on function roca_violations_mine() to authenticated;

create or replace function roca_violation_request_hearing(p_id bigint, p_note text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v condo_violations;
begin
  select v2.* into v from condo_violations v2 join condo_units u on u.id = v2.unit_id
   where v2.id = p_id and u.unit_number in (select roca_my_unit_numbers()) for update;
  if v.id is null then raise exception 'That violation isn''t at your unit.' using errcode = '42501'; end if;
  if v.status <> 'notice_sent' or v.process <> 'fine_notice' then raise exception 'A hearing can be requested only on a fine notice that isn''t final yet.'; end if;
  if v.appeal_deadline < current_date then raise exception 'The fourteen days to request a hearing ended on %. Contact the board.', to_char(v.appeal_deadline, 'FMMM/FMDD/YYYY'); end if;
  if length(coalesce(trim(p_note), '')) < 10 then raise exception 'Say briefly why you dispute it (this is your written request).'; end if;
  update condo_violations set status = 'hearing_requested', hearing_requested_at = now(), hearing_request_note = trim(p_note), updated_at = now() where id = p_id returning * into v;
  perform office_alert('roca_alert_email', 'roca_violation', 'Hearing requested — ' || roca_violation_label(v),
    '<p>The owner requested a hearing in writing on ' || to_char(current_date, 'FMMM/FMDD/YYYY') || ' (by the ' || to_char(v.appeal_deadline, 'FMMM/FMDD') || ' deadline). The fine is suspended until the board hears it (By-Laws §1502).</p><p>“'
    || repair_esc(trim(p_note)) || '”</p><p>Schedule the hearing: https://2ndchinc.org/association-owners/roca1/violations/</p>');
  return roca_violations_mine();
end;
$$;
revoke all on function roca_violation_request_hearing(bigint, text) from public, anon;
grant execute on function roca_violation_request_hearing(bigint, text) to authenticated;

-- ===========================================================================
-- B. Rent deductions / owner distributions
-- ===========================================================================
create table if not exists roca_pma_terms (
  unit_number text primary key,
  mgmt_fee_pct numeric(6,3) not null default 0,          -- % of gross rents collected
  card_fee_pct numeric(6,3) not null default 0,          -- % of rents paid by card (2020 PMA template: 3.0%)
  operating_reserve numeric(12,2) not null default 0,    -- kept on account (2020-03-06 PMA: $150)
  source_document text,
  note text,
  updated_by text,
  updated_at timestamptz not null default now()
);

create table if not exists roca_distributions (
  id uuid primary key default gen_random_uuid(),
  unit_number text not null,
  month date not null,                                   -- first day of the statement month
  owner_id uuid references condo_owners(id),
  owner_name text,
  owner_is_2ch boolean not null default false,           -- 2nd Chance's own unit: the net stays with 2nd Chance
  lease_ids uuid[],
  rent_collected numeric(12,2) not null default 0,       -- tenant payments posted in the month
  card_collected numeric(12,2) not null default 0,
  agency_collected numeric(12,2) not null default 0,     -- housing-assistance agency payments
  balance_due numeric(12,2) not null default 0,          -- association balance available to pay at calculation
  deductions jsonb not null default '[]'::jsonb,         -- [{category, gl_account, amount}]
  deduction_total numeric(12,2) not null default 0,
  mgmt_fee numeric(12,2) not null default 0,
  card_fee numeric(12,2) not null default 0,
  other_deductions jsonb not null default '[]'::jsonb,   -- [{label, amount, by}]
  other_total numeric(12,2) not null default 0,
  reserve_held numeric(12,2) not null default 0,
  net_to_owner numeric(12,2) not null default 0,
  shortfall numeric(12,2) not null default 0,            -- association balance still owed after this statement
  status text not null default 'calculated' check (status in ('calculated', 'approved', 'transferred', 'paid', 'reversed')),
  calc_at timestamptz not null default now(), calc_by text,
  approved_at timestamptz, approved_by text,
  transfer_date date, transfer_reference text, transferred_by text, condo_entry_ids bigint[],
  paid_date date, paid_method text, paid_reference text, paid_by text,
  reversed_at timestamptz, reversed_by text, reverse_reason text,
  notes text,
  created_at timestamptz not null default now()
);
create unique index if not exists roca_distributions_one on roca_distributions (unit_number, month) where status <> 'reversed';
alter table roca_pma_terms enable row level security;
alter table roca_distributions enable row level security;

create or replace function roca_gl_category(p_gl text)
returns text language sql immutable as $$
  select case when p_gl ~* 'assess' then 'assessments'
              when p_gl ~* '^association (fee|dues)' then 'dues'
              else 'fines_fees' end;   -- fines, late fees, interest, legal, repairs, cleaning, parking, other
$$;

-- What a unit owes ROCA1, by GL account, in the deduction order (Rules §11: fines & fees first).
-- Categories: fines_fees, assessments, dues_current (dues charged in the statement month), older_balance (earlier dues).
-- Each GL's open amount = its net (the original application of past payments); a GL paid ahead (negative) is applied
-- to the others in the same order.
create or replace function roca_unit_open_items(p_unit text, p_month date, p_as_of date)
returns table (category text, gl_account text, open numeric, ord int)
language plpgsql stable security definer set search_path = public as $$
declare v_order text[] := string_to_array(coalesce((select value from portal_settings where key = 'roca_deduction_order'), 'fines_fees,assessments,dues_current,older_balance'), ',');
  cats text[]; gls text[]; amts numeric[]; ords int[]; i int; j int; credit numeric := 0; take numeric; older_neg numeric;
begin
  select array_agg(x.cat order by coalesce(array_position(v_order, x.cat), 99), x.gl), array_agg(x.gl order by coalesce(array_position(v_order, x.cat), 99), x.gl),
         array_agg(x.amt order by coalesce(array_position(v_order, x.cat), 99), x.gl), array_agg(coalesce(array_position(v_order, x.cat), 99) order by coalesce(array_position(v_order, x.cat), 99), x.gl)
    into cats, gls, amts, ords
  from (
    select case when roca_gl_category(e.gl_account) = 'dues' then
                  case when e.kind = 'charge' and date_trunc('month', e.entry_date) = date_trunc('month', p_month) then 'dues_current' else 'older_balance' end
                else roca_gl_category(e.gl_account) end as cat,
           e.gl_account gl, sum(e.amount) amt
    from condo_ledger_entries e join condo_ledger_accounts a on a.id = e.account_id join condo_units u on u.id = a.unit_id
    where u.unit_number = p_unit and not a.excluded and e.entry_date <= p_as_of
    group by 1, 2
  ) x;
  if cats is null then return; end if;
  -- Dues payments sit on the dues GL as a whole: a negative older-dues net is applied to the current month's dues first.
  for i in 1 .. array_length(cats, 1) loop
    if cats[i] = 'older_balance' and amts[i] < 0 then
      for j in 1 .. array_length(cats, 1) loop
        if cats[j] = 'dues_current' and gls[j] = gls[i] and amts[j] > 0 then
          take := least(amts[j], -amts[i]); amts[j] := amts[j] - take; amts[i] := amts[i] + take;
        end if;
      end loop;
    end if;
  end loop;
  -- Any GL still negative (paid ahead) is a credit applied to the rest in order.
  for i in 1 .. array_length(cats, 1) loop
    if amts[i] < 0 then credit := credit - amts[i]; amts[i] := 0; end if;
  end loop;
  for i in 1 .. array_length(cats, 1) loop
    exit when credit <= 0;
    take := least(credit, amts[i]); amts[i] := amts[i] - take; credit := credit - take;
  end loop;
  for i in 1 .. array_length(cats, 1) loop
    if amts[i] > 0 then category := cats[i]; gl_account := gls[i]; open := round(amts[i], 2); ord := ords[i]; return next; end if;
  end loop;
end;
$$;
revoke all on function roca_unit_open_items(text, date, date) from public, anon, authenticated;

-- Calculate (or recalculate) one unit-month statement. Returns the statement; saves it when p_save.
create or replace function roca_distribution_calc(p_unit text, p_month date, p_save boolean, p_by text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare m date := date_trunc('month', p_month)::date; m_end date := (date_trunc('month', p_month) + interval '1 month' - interval '1 day')::date;
  d roca_distributions; o record; t roca_pma_terms; v_leases uuid[]; v_rent numeric; v_card numeric; v_agency numeric := 0; v_cash numeric;
  v_reserved numeric; v_bal numeric; v_avail numeric; r record; take numeric; v_ded jsonb := '[]'::jsonb; v_ded_total numeric := 0;
  v_other jsonb := '[]'::jsonb; v_other_total numeric := 0; v_id uuid; v_left numeric;
begin
  select * into d from roca_distributions where unit_number = p_unit and month = m and status <> 'reversed';
  if d.id is not null and d.status <> 'calculated' then return to_jsonb(d); end if;   -- approved or later: frozen
  if d.id is not null then v_other := d.other_deductions; v_other_total := d.other_total; end if;
  select array_agg(l.id) into v_leases from leases l join rental_units ru on ru.id = l.unit_id join condo_units cu on cu.id = ru.condo_unit_id
   where cu.unit_number = p_unit;
  if v_leases is null then raise exception 'Unit % has no 2nd Chance lease.', p_unit; end if;
  select coalesce(-sum(e.amount), 0), coalesce(-sum(e.amount) filter (where e.method = 'card'), 0) into v_rent, v_card
    from lease_ledger_entries e where e.lease_id = any (v_leases) and e.kind in ('payment', 'reversal') and e.gl_account !~* 'deposit'
     and e.entry_date between m and m_end;
  if to_regclass('public.assistance_ledger') is not null then
    execute 'select coalesce(-sum(amount), 0) from assistance_ledger where lease_id = any ($1) and kind = ''payment'' and entry_date between $2 and $3'
      into v_agency using v_leases, m, m_end;
  end if;
  select * into o from roca_unit_owner_on(p_unit, m_end);
  select * into t from roca_pma_terms where unit_number = p_unit;
  v_cash := greatest(v_rent + v_agency, 0);
  -- What is already earmarked in other approved statements for this unit (not yet transferred).
  select coalesce(sum(deduction_total), 0) into v_reserved from roca_distributions where unit_number = p_unit and status = 'approved' and month <> m;
  v_bal := greatest(roca_unit_balance(p_unit, greatest(m_end, current_date)) - v_reserved, 0);
  v_avail := least(v_cash, v_bal);
  -- Deductions to ROCA1 first (PMA: "withhold the correct ROCA1 association fees"), in the Rules §11 order.
  v_left := v_avail;
  for r in select * from roca_unit_open_items(p_unit, m, greatest(m_end, current_date)) loop
    exit when v_left <= 0;
    take := least(v_left, r.open);
    v_ded := v_ded || jsonb_build_object('category', r.category, 'gl_account', r.gl_account, 'amount', take);
    v_ded_total := v_ded_total + take; v_left := v_left - take;
  end loop;
  -- Manager's compensation, from tenants' payments only, out of what is left.
  v_left := v_cash - v_ded_total;
  d.mgmt_fee := least(greatest(v_left, 0), round(v_rent * coalesce(t.mgmt_fee_pct, 0) / 100, 2));
  v_left := v_left - d.mgmt_fee;
  d.card_fee := least(greatest(v_left, 0), round(v_card * coalesce(t.card_fee_pct, 0) / 100, 2));
  v_left := v_left - d.card_fee - v_other_total;
  d.reserve_held := least(greatest(v_left, 0), coalesce(t.operating_reserve, 0));
  v_left := v_left - d.reserve_held;
  if p_save then
    if d.id is null then
      insert into roca_distributions (unit_number, month, calc_by) values (p_unit, m, p_by) returning id into v_id;
    else v_id := d.id; end if;
    update roca_distributions set owner_id = o.owner_id, owner_name = o.name, owner_is_2ch = o.name ~* '^2nd Chance', lease_ids = v_leases,
      rent_collected = v_rent, card_collected = v_card, agency_collected = v_agency, balance_due = v_bal, deductions = v_ded, deduction_total = v_ded_total,
      mgmt_fee = d.mgmt_fee, card_fee = d.card_fee, reserve_held = d.reserve_held, net_to_owner = greatest(v_left, 0),
      shortfall = greatest(v_bal - v_ded_total, 0), calc_at = now(), calc_by = p_by
    where id = v_id returning * into d;
    return to_jsonb(d);
  end if;
  return jsonb_build_object('unit_number', p_unit, 'month', m, 'owner_name', o.name, 'rent_collected', v_rent, 'agency_collected', v_agency, 'balance_due', v_bal,
    'deductions', v_ded, 'deduction_total', v_ded_total, 'mgmt_fee', d.mgmt_fee, 'card_fee', d.card_fee, 'other_total', v_other_total, 'reserve_held', d.reserve_held,
    'net_to_owner', greatest(v_left, 0), 'shortfall', greatest(v_bal - v_ded_total, 0), 'preview', true);
end;
$$;
revoke all on function roca_distribution_calc(text, date, boolean, text) from public, anon, authenticated;

-- Units with a 2nd Chance lease on them during the month (or rent posted in it).
create or replace function roca_distribution_units(p_month date)
returns setof text language sql stable security definer set search_path = public as $$
  select distinct cu.unit_number from leases l join rental_units ru on ru.id = l.unit_id join condo_units cu on cu.id = ru.condo_unit_id
  where cu.unit_number ~ '^\d+$'
    and ((coalesce(l.start_date, p_month) <= (date_trunc('month', p_month) + interval '1 month - 1 day')::date and (l.end_date is null or l.end_date >= date_trunc('month', p_month)::date))
      or exists (select 1 from lease_ledger_entries e where e.lease_id = l.id and e.kind = 'payment' and date_trunc('month', e.entry_date) = date_trunc('month', p_month)));
$$;
revoke all on function roca_distribution_units(date) from public, anon, authenticated;

create or replace function roca_auto_distributions(p_today date, p_live boolean)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare m date := (date_trunc('month', p_today) - interval '1 month')::date; u text; out jsonb := '[]'::jsonb; s jsonb;
begin
  if extract(day from p_today) < 5 then return jsonb_build_object('note', 'Statements for last month are calculated on or after the 5th.'); end if;
  for u in select x from roca_distribution_units(m) x order by roca_unit_sort(x) loop
    if exists (select 1 from roca_distributions where unit_number = u and month = m and status <> 'calculated' and status <> 'reversed') then continue; end if;
    s := roca_distribution_calc(u, m, p_live, 'automation');
    out := out || jsonb_build_object('unit', u, 'rent', s->'rent_collected', 'to_roca1', s->'deduction_total', 'net', s->'net_to_owner');
  end loop;
  return jsonb_build_object('month', m, 'statements', out);
end;
$$;
revoke all on function roca_auto_distributions(date, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Staff
create or replace function roca_distribution_row(d roca_distributions)
returns jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(d) || jsonb_build_object('month_label', to_char(d.month, 'FMMonth YYYY'),
    'terms', (select to_jsonb(t) from roca_pma_terms t where t.unit_number = d.unit_number),
    'association_balance_now', roca_unit_balance(d.unit_number));
$$;
revoke all on function roca_distribution_row(roca_distributions) from public, anon, authenticated;

create or replace function roca_distributions_staff_list(p_month date)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare m date := date_trunc('month', coalesce(p_month, current_date - interval '1 month'))::date;
begin
  perform roca_staff_check();
  return jsonb_build_object('month', m,
    'statements', coalesce((select jsonb_agg(roca_distribution_row(d) order by roca_unit_sort(d.unit_number)) from roca_distributions d where d.month = m and d.status <> 'reversed'), '[]'::jsonb),
    'reversed', coalesce((select jsonb_agg(roca_distribution_row(d)) from roca_distributions d where d.month = m and d.status = 'reversed'), '[]'::jsonb),
    'units_without', coalesce((select jsonb_agg(x order by roca_unit_sort(x)) from roca_distribution_units(m) x
                               where not exists (select 1 from roca_distributions d where d.unit_number = x and d.month = m and d.status <> 'reversed')), '[]'::jsonb),
    'terms', coalesce((select jsonb_agg(to_jsonb(t) order by roca_unit_sort(t.unit_number)) from roca_pma_terms t), '[]'::jsonb),
    'order', (select value from portal_settings where key = 'roca_deduction_order'));
end;
$$;
revoke all on function roca_distributions_staff_list(date) from public, anon;
grant execute on function roca_distributions_staff_list(date) to authenticated;

create or replace function roca_distribution_calc_staff(p_month date, p_unit text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare m date := date_trunc('month', p_month)::date; u text;
begin
  perform roca_staff_check();
  if m >= date_trunc('month', current_date) then raise exception 'Statements are for a finished month.'; end if;
  for u in select x from roca_distribution_units(m) x where p_unit is null or x = p_unit loop
    perform roca_distribution_calc(u, m, true, lower(auth.email()));
  end loop;
  return roca_distributions_staff_list(m);
end;
$$;
revoke all on function roca_distribution_calc_staff(date, text) from public, anon;
grant execute on function roca_distribution_calc_staff(date, text) to authenticated;

create or replace function roca_distribution_other(p_id uuid, p_label text, p_amount numeric)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare d roca_distributions;
begin
  perform roca_staff_check();
  select * into d from roca_distributions where id = p_id;
  if d.status <> 'calculated' then raise exception 'Only a calculated statement can change. Un-approve it first.'; end if;
  if p_amount is null or p_amount = 0 then
    -- remove by label
    update roca_distributions set other_deductions = coalesce((select jsonb_agg(x) from jsonb_array_elements(other_deductions) x where x->>'label' <> p_label), '[]'::jsonb) where id = p_id;
  else
    if length(coalesce(trim(p_label), '')) < 3 then raise exception 'Describe the deduction (e.g. repair invoice #, per the management agreement).'; end if;
    update roca_distributions set other_deductions = other_deductions || jsonb_build_object('label', trim(p_label), 'amount', p_amount, 'by', lower(auth.email())) where id = p_id;
  end if;
  update roca_distributions set other_total = coalesce((select sum((x->>'amount')::numeric) from jsonb_array_elements(other_deductions) x), 0) where id = p_id;
  perform roca_distribution_calc(d.unit_number, d.month, true, lower(auth.email()));
  select * into d from roca_distributions where id = p_id;
  return roca_distribution_row(d);
end;
$$;
revoke all on function roca_distribution_other(uuid, text, numeric) from public, anon;
grant execute on function roca_distribution_other(uuid, text, numeric) to authenticated;

create or replace function roca_distribution_approve(p_id uuid, p_approve boolean)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare d roca_distributions;
begin
  perform roca_staff_check();
  if p_approve then
    perform roca_distribution_calc(unit_number, month, true, lower(auth.email())) from roca_distributions where id = p_id and status = 'calculated';
    update roca_distributions set status = 'approved', approved_at = now(), approved_by = lower(auth.email()) where id = p_id and status = 'calculated' returning * into d;
  else
    update roca_distributions set status = 'calculated', approved_at = null, approved_by = null where id = p_id and status = 'approved' returning * into d;
  end if;
  if d.id is null then raise exception 'That statement can''t be % now.', case when p_approve then 'approved' else 'un-approved' end; end if;
  return roca_distribution_row(d);
end;
$$;
revoke all on function roca_distribution_approve(uuid, boolean) from public, anon;
grant execute on function roca_distribution_approve(uuid, boolean) to authenticated;

-- The money moved from 2nd Chance's rent account to ROCA1's account: only now is the association ledger credited.
create or replace function roca_distribution_transfer(p_id uuid, p_date date, p_reference text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare d roca_distributions; x jsonb; v_acct uuid; v_ids bigint[] := '{}'; v_id bigint; v_bal numeric;
  CAT jsonb := '{"fines_fees":"fines & fees","assessments":"special assessments","dues_current":"association dues","older_balance":"past-due dues"}';
begin
  perform roca_staff_check();
  select * into d from roca_distributions where id = p_id for update;
  if d.status <> 'approved' then raise exception 'Approve the statement before recording the transfer.'; end if;
  if length(coalesce(trim(p_reference), '')) < 2 then raise exception 'Enter the transfer reference (bank confirmation or check number).'; end if;
  v_bal := roca_unit_balance(d.unit_number, greatest(coalesce(p_date, current_date), current_date));
  if d.deduction_total > v_bal + 0.004 then
    raise exception 'Unit % now owes only % (it was paid another way since). Un-approve and recalculate first.', d.unit_number, to_char(v_bal, 'FM$999,990.00'); end if;
  v_acct := roca_unit_account(d.unit_number);
  for x in select * from jsonb_array_elements(d.deductions) loop
    if (x->>'amount')::numeric <= 0 then continue; end if;
    insert into condo_ledger_entries (account_id, gl_account, entry_date, kind, raw_type, method, check_number, description, amount, origin, entered_by, correction_note)
    values (v_acct, x->>'gl_account', coalesce(p_date, current_date), 'payment', 'Payment', 'rent_deduction', left(trim(p_reference), 40),
      'Paid from rent collected — ' || to_char(d.month, 'FMMonth YYYY') || ' (' || coalesce(CAT->>(x->>'category'), x->>'category') || ')', -(x->>'amount')::numeric, 'staff', lower(auth.email()),
      'Rent deduction statement ' || d.id || '; transferred from 2nd Chance Housing''s rent account to ROCA1''s account, ref ' || trim(p_reference))
    returning id into v_id;
    v_ids := v_ids || v_id;
  end loop;
  update roca_distributions set status = case when owner_is_2ch then 'paid' else 'transferred' end, transfer_date = coalesce(p_date, current_date), transfer_reference = trim(p_reference),
    transferred_by = lower(auth.email()), condo_entry_ids = v_ids,
    paid_date = case when owner_is_2ch then coalesce(p_date, current_date) end, paid_method = case when owner_is_2ch then 'retained by 2nd Chance' end
   where id = p_id returning * into d;
  if not d.owner_is_2ch and (select email from condo_owners where id = d.owner_id) is not null then
    insert into email_outbox (to_email, subject, html, kind) values ((select email from condo_owners where id = d.owner_id),
      'Unit ' || d.unit_number || ' rent statement — ' || to_char(d.month, 'FMMonth YYYY'),
      '<p>Dear ' || repair_esc(coalesce(d.owner_name, 'Owner')) || ',</p><p>Your statement for Unit ' || d.unit_number || ', ' || to_char(d.month, 'FMMonth YYYY') || ':</p><ul>'
      || '<li>Rent collected: ' || to_char(d.rent_collected + d.agency_collected, 'FM$999,990.00') || '</li>'
      || '<li>Paid to ROCA1 from the rent (your association account): ' || to_char(d.deduction_total, 'FM$999,990.00') || '</li>'
      || case when d.mgmt_fee + d.card_fee > 0 then '<li>Management fees: ' || to_char(d.mgmt_fee + d.card_fee, 'FM$999,990.00') || '</li>' else '' end
      || case when d.other_total <> 0 then '<li>Other deductions: ' || to_char(d.other_total, 'FM$999,990.00') || '</li>' else '' end
      || case when d.reserve_held > 0 then '<li>Kept as operating reserve: ' || to_char(d.reserve_held, 'FM$999,990.00') || '</li>' else '' end
      || '<li><b>Net to you: ' || to_char(d.net_to_owner, 'FM$999,990.00') || '</b></li></ul>'
      || case when d.shortfall > 0 then '<p>Your association account still shows ' || to_char(d.shortfall, 'FM$999,990.00') || ' owed after this payment.</p>' else '' end
      || '<p>The full statement is in the owner portal: https://2ndchinc.org/association-owners/roca1/#statements</p><p>2nd Chance Housing, for ROCA1</p>', 'roca_distribution');
  end if;
  return roca_distribution_row(d);
end;
$$;
revoke all on function roca_distribution_transfer(uuid, date, text) from public, anon;
grant execute on function roca_distribution_transfer(uuid, date, text) to authenticated;

create or replace function roca_distribution_paid(p_id uuid, p_date date, p_method text, p_reference text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare d roca_distributions;
begin
  perform roca_staff_check();
  update roca_distributions set status = 'paid', paid_date = coalesce(p_date, current_date), paid_method = nullif(trim(coalesce(p_method, '')), ''),
    paid_reference = nullif(trim(coalesce(p_reference, '')), ''), paid_by = lower(auth.email())
   where id = p_id and status = 'transferred' returning * into d;
  if d.id is null then raise exception 'Record the transfer to ROCA1 first.'; end if;
  return roca_distribution_row(d);
end;
$$;
revoke all on function roca_distribution_paid(uuid, date, text, text) from public, anon;
grant execute on function roca_distribution_paid(uuid, date, text, text) to authenticated;

-- Undo a recorded transfer: reversal lines (the payments stay on the ledger), statement marked reversed.
create or replace function roca_distribution_reverse(p_id uuid, p_reason text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare d roca_distributions; e record;
begin
  perform roca_staff_check();
  if length(coalesce(trim(p_reason), '')) < 5 then raise exception 'Say why it is reversed.'; end if;
  select * into d from roca_distributions where id = p_id for update;
  if d.status not in ('transferred', 'paid', 'approved', 'calculated') then raise exception 'Already reversed.'; end if;
  for e in select * from condo_ledger_entries where id = any (coalesce(d.condo_entry_ids, '{}')) loop
    insert into condo_ledger_entries (account_id, gl_account, entry_date, kind, raw_type, method, description, amount, origin, entered_by, correction_note, reverses_entry_id)
    values (e.account_id, e.gl_account, current_date, 'reversal', 'Reversal', e.method, 'Reversal: ' || e.description, -e.amount, 'staff', lower(auth.email()), 'Reversed: ' || trim(p_reason), e.id);
  end loop;
  update roca_distributions set status = 'reversed', reversed_at = now(), reversed_by = lower(auth.email()), reverse_reason = trim(p_reason) where id = p_id returning * into d;
  return roca_distribution_row(d);
end;
$$;
revoke all on function roca_distribution_reverse(uuid, text) from public, anon;
grant execute on function roca_distribution_reverse(uuid, text) to authenticated;

create or replace function roca_pma_terms_save(p_unit text, p_mgmt numeric, p_card numeric, p_reserve numeric, p_source text, p_note text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
begin
  perform roca_staff_check();
  if not exists (select 1 from condo_units where unit_number = p_unit) then raise exception 'Unit % isn''t on file.', p_unit; end if;
  if length(coalesce(trim(p_source), '')) < 3 then raise exception 'Name the signed management agreement these terms come from.'; end if;
  insert into roca_pma_terms (unit_number, mgmt_fee_pct, card_fee_pct, operating_reserve, source_document, note, updated_by)
  values (p_unit, coalesce(p_mgmt, 0), coalesce(p_card, 0), coalesce(p_reserve, 0), trim(p_source), nullif(trim(coalesce(p_note, '')), ''), lower(auth.email()))
  on conflict (unit_number) do update set mgmt_fee_pct = excluded.mgmt_fee_pct, card_fee_pct = excluded.card_fee_pct, operating_reserve = excluded.operating_reserve,
    source_document = excluded.source_document, note = excluded.note, updated_by = excluded.updated_by, updated_at = now();
  return (select to_jsonb(t) from roca_pma_terms t where t.unit_number = p_unit);
end;
$$;
revoke all on function roca_pma_terms_save(text, numeric, numeric, numeric, text, text) from public, anon;
grant execute on function roca_pma_terms_save(text, numeric, numeric, numeric, text, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Owners: their statements (approved or later), current units only.
create or replace function roca_distributions_mine()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_owner uuid := condo_owner_for_email(auth.email());
begin
  if v_owner is null or not condo_session_ok() then raise exception 'Sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(roca_distribution_row(d) - 'calc_by' - 'approved_by' - 'transferred_by' - 'paid_by' - 'reversed_by' - 'lease_ids' - 'terms'
      order by d.month desc, roca_unit_sort(d.unit_number))
    from roca_distributions d where d.owner_id = v_owner and d.status in ('approved', 'transferred', 'paid')), '[]'::jsonb);
end;
$$;
revoke all on function roca_distributions_mine() from public, anon;
grant execute on function roca_distributions_mine() to authenticated;
