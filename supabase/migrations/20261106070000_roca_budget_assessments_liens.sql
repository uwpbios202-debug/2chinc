-- ROCA1 budget, special assessments and liens (Stephen, 10/7/2026), built on 20261106060000_roca_governance_core.
-- Every special assessment, lien filing, lien satisfaction and foreclosure is the result of an adopted RESOLUTION;
-- automations only propose them (origin 'automation') or carry out what was already adopted.
--
-- Governing documents (copies read 10/7/2026):
--   Declaration (2 May 1973, retyped 01/2020)  files/legacy-files/ROCA1/2021-02-27_Declaration_digitized_2020.pdf
--     ¶7  every residential unit 0.06% → common expenses shared equally (1/16 each)
--     ¶16 common expenses and assessments are a personal debt and a lien on the unit until paid
--   By-Laws (revised 3/21/2020)                 files/legacy-files/ROCA1/2020-04-23_ByLaws Apr 2020.pdf
--     §1500(1) the Board adopts the budget at least 30 days before the fiscal year and sends each owner the budget
--              and a statement of their General Assessment
--     §1500(3) repairs to protect the common property are "specially assessed to the unit owner responsible"
--     §1500(4) notice of annual Assessment: amount for the unit, how determined, 1/16th ... due on the first of each month
--     §1500(5) Special Assessment "upon the majority vote of all the Directors"; notice to each owner of the amount,
--              the due date and the reason
--     §1500(6) late penalty 12% of the entire Assessment after 15 days  ← conflicts with Rules 2024 §11 ($25 late fee);
--              kept as a setting, OFF by default
--   Action by Written Consent 1/16/2025          files/legacy-files/ROCA1/2025-01-18_ROCA1_Ratified ByLaws 2025.pdf
--     E. ROCA1 holds no reserve account; F. an owner stays Class B until liens are satisfied
--   Action by Written Consent 2/19/2025          mine/6622 N bourbon/budget/Liens/ROCA1_Ratified Lien Actions.pdf
--     A. evaluate balances in October of every odd year
--     B. satisfactions 11476132–11476140 recorded; no other outstanding ROCA1 liens
--     C. record a Statement of Condominium Lien in January of every even year for balances > $1,290; refile every 23 months;
--        liens 11476130 (Unit 1) and 11476131 (Unit 12) filed January 2025
--     D. foreclosure for Association Fee > $10,320; Unit 8 (PIN 1450458000) foreclosure initiated
--   Rules & Regulations 2024 (ratified)          files/legacy-files/ROCA1/2025-04-13_ROCA1 Rules_2024_ratified.pdf
--     §11(4) delinquent $430 → lien  ← conflicts with action C ($1,290); the later, more specific member action is the
--            default (setting roca_lien_threshold)
--     §4/§10 legal and recording costs are charged back to the owner
--   Budget FY2025                                mine/6622 N bourbon/budget/2022 Budget/ROCA1 Budget_2025_Jan.pdf
--
-- Decision: there is NO vote-less path for a special assessment, not even a single-unit charge-back. §1500(3) says the
-- cost is specially assessed to the responsible owner, and §1500(5) makes every Special Assessment a majority vote of all
-- the Directors (and the 1/16/2025 action E says there is no reserve fund to front repairs). Staff get a one-click
-- "propose charge-back" that drafts the board resolution.

insert into portal_settings (key, value) values
  ('roca_lien_threshold', '1290'),            -- action C (2/19/2025); Rules 2024 §11(4) says 430
  ('roca_foreclosure_threshold', '10320'),    -- action D (2/19/2025), association-fee balance
  ('roca_lien_refile_months', '23'),          -- action C
  ('roca_assessment_penalty', 'off'),         -- By-Laws §1500(6) 12% penalty: 'on' to post it
  ('roca_assessment_penalty_pct', '12'),
  ('roca_assessment_penalty_days', '15'),
  ('roca_budget_alerted_on', '')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- Budget
create table if not exists roca_budgets (
  id uuid primary key default gen_random_uuid(),
  fiscal_year int not null unique,
  status text not null default 'draft' check (status in ('draft', 'proposed', 'adopted', 'on_file')),  -- on_file: in use, no adoption record found
  monthly_dues numeric(12,2) not null default 215,   -- the General Assessment per unit per month
  carry_forward numeric(12,2) not null default 0,
  printed_totals jsonb,                               -- totals exactly as printed on the source document
  resolution_id uuid references roca_resolutions(id),
  source_document text,
  notes text,
  created_by text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists roca_budget_lines (
  id uuid primary key default gen_random_uuid(),
  budget_id uuid not null references roca_budgets(id) on delete cascade,
  grp text not null check (grp in ('INCOME', 'ADMINISTRATIVE', 'UTILITIES', 'GROUNDS', 'BUILDINGS')),
  code text not null,
  name text not null,
  months numeric(12,2)[] not null default array_fill(0::numeric, array[12]),
  annual numeric(12,2) not null default 0,            -- as printed; normally the sum of months
  note text,
  sort int not null default 0,
  check (array_length(months, 1) = 12)
);
create index if not exists roca_budget_lines_idx on roca_budget_lines (budget_id, sort);

create table if not exists roca_expenses (
  id uuid primary key default gen_random_uuid(),
  expense_date date not null,
  budget_code text not null,
  vendor text,
  amount numeric(12,2) not null check (amount > 0),
  memo text,
  paid_from text not null default 'ROCA1',            -- association money only (never 2nd Chance's rent account)
  receipt_path text,
  voided_at timestamptz, void_note text,              -- never deleted
  entered_by text,
  created_at timestamptz not null default now()
);
create index if not exists roca_expenses_date_idx on roca_expenses (expense_date);

-- A dues change from an adopted budget, applied to condo_ownerships.fee (what condo_billing_post_month bills) on its date.
create table if not exists roca_dues_changes (
  id uuid primary key default gen_random_uuid(),
  budget_id uuid references roca_budgets(id),
  monthly_fee numeric(12,2) not null,
  effective_month date not null,
  applied_at timestamptz,
  applied_result jsonb,
  created_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Special assessments
create table if not exists roca_assessments (
  id uuid primary key default gen_random_uuid(),
  resolution_id uuid not null references roca_resolutions(id),
  title text not null,
  reason text not null,
  total numeric(12,2) not null check (total > 0),
  allocation text not null check (allocation in ('equal_16', 'per_unit', 'single_unit')),
  installments int not null default 1 check (installments between 1 and 60),
  first_due date not null,
  status text not null default 'scheduled' check (status in ('scheduled', 'complete', 'cancelled')),
  cost_reference text,                                -- invoice / repair the charge-back is for
  created_at timestamptz not null default now()
);

create table if not exists roca_assessment_charges (
  id uuid primary key default gen_random_uuid(),
  assessment_id uuid not null references roca_assessments(id),
  unit_number text not null,
  installment int not null,
  due_date date not null,
  amount numeric(12,2) not null,
  ledger_entry_id bigint references condo_ledger_entries(id),
  posted_at timestamptz,
  penalty_entry_id bigint references condo_ledger_entries(id),
  notice_sent_at timestamptz,
  unique (assessment_id, unit_number, installment)
);
create index if not exists roca_assessment_charges_due_idx on roca_assessment_charges (due_date) where ledger_entry_id is null;

-- ---------------------------------------------------------------------------
-- Liens
create table if not exists roca_liens (
  id uuid primary key default gen_random_uuid(),
  unit_number text not null,
  account_id uuid references condo_ledger_accounts(id),
  amount_claimed numeric(12,2),
  as_of date,
  status text not null check (status in ('approved', 'recorded', 'satisfaction_approved', 'satisfied', 'released', 'foreclosure')),
  rod_document text,                                  -- Register of Deeds document number of the Statement of Condominium Lien
  recorded_on date,
  refile_due date,
  refile_alerted_at timestamptz,
  satisfaction_document text,
  satisfied_on date,
  filing_resolution_id uuid references roca_resolutions(id),
  satisfaction_resolution_id uuid references roca_resolutions(id),
  foreclosure_resolution_id uuid references roca_resolutions(id),
  filing_cost numeric(12,2),
  filing_cost_entry_id bigint references condo_ledger_entries(id),
  source_document text,
  notes text,
  created_by text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists roca_liens_unit_idx on roca_liens (unit_number, status);

alter table roca_budgets enable row level security;
alter table roca_budget_lines enable row level security;
alter table roca_expenses enable row level security;
alter table roca_dues_changes enable row level security;
alter table roca_assessments enable row level security;
alter table roca_assessment_charges enable row level security;
alter table roca_liens enable row level security;
-- No policies: everything goes through the functions below.

-- A unit in foreclosure is under lien too (core checked 'recorded' only).
create or replace function roca_unit_has_lien(p_unit text)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from roca_liens where unit_number = p_unit and status in ('recorded', 'satisfaction_approved', 'foreclosure'));
$$;
revoke all on function roca_unit_has_lien(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Helpers
create or replace function roca_units()
returns setof text language sql stable security definer set search_path = public as $$
  select unit_number from condo_units where unit_number ~ '^\d+$' order by roca_unit_sort(unit_number);
$$;
revoke all on function roca_units() from public, anon, authenticated;

create or replace function roca_unit_owner(p_unit text)
returns table (owner_id uuid, name text, email text)
language sql stable security definer set search_path = public as $$
  select o.id, o.name, o.email from condo_units u join condo_ownerships s on s.unit_id = u.id and s.is_current
  join condo_owners o on o.id = s.owner_id where u.unit_number = p_unit order by s.start_date desc nulls last limit 1;
$$;
revoke all on function roca_unit_owner(text) from public, anon, authenticated;

-- Association-fee part of a unit's balance (action D measures "Association Fee").
create or replace function roca_unit_fee_balance(p_unit text, p_as_of date default current_date)
returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(sum(e.amount), 0)::numeric(12,2) from condo_ledger_entries e join condo_ledger_accounts a on a.id = e.account_id
  join condo_units u on u.id = a.unit_id where u.unit_number = p_unit and not a.excluded and e.gl_account = 'Association Fee Income' and e.entry_date <= p_as_of;
$$;
revoke all on function roca_unit_fee_balance(text, date) from public, anon, authenticated;

-- Post a charge to a unit's billing account. Returns the entry id.
create or replace function roca_post_charge(p_unit text, p_gl text, p_date date, p_amount numeric, p_raw text, p_desc text, p_origin text, p_by text, p_note text)
returns bigint
language plpgsql volatile security definer set search_path = public as $$
declare v_acct uuid; v_id bigint;
begin
  v_acct := condo_billing_account((select id from condo_units where unit_number = p_unit));
  if v_acct is null then raise exception 'Unit % has no current owner account.', p_unit; end if;
  insert into condo_ledger_entries (account_id, gl_account, entry_date, kind, raw_type, description, amount, origin, entered_by, correction_note)
  values (v_acct, p_gl, p_date, case when p_gl = 'Late Fee Income' then 'late_fee' else 'charge' end, p_raw, p_desc, p_amount, p_origin, p_by, p_note)
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function roca_post_charge(text, text, date, numeric, text, text, text, text, text) from public, anon, authenticated;

create or replace function roca_email_owner(p_unit text, p_subject text, p_html text, p_kind text)
returns boolean
language plpgsql volatile security definer set search_path = public as $$
declare o record;
begin
  select * into o from roca_unit_owner(p_unit);
  if o.email is null then return false; end if;
  insert into email_outbox (to_email, subject, html, kind)
  values (o.email, p_subject, '<p>Dear ' || repair_esc(coalesce(o.name, 'Owner')) || ',</p>' || p_html || '<p>Royal Orleans Condominium Association – Addition 1 (ROCA1)<br>6626 N. Bourbon St., Milwaukee, WI 53224 · '
    || coalesce((select value from portal_settings where key = 'org_phone'), '') || '</p>', p_kind);
  return true;
end;
$$;
revoke all on function roca_email_owner(text, text, text, text) from public, anon, authenticated;

create or replace function roca_money(n numeric) returns text language sql immutable as $$ select to_char(coalesce(n, 0), 'FM$999,999,990.00'); $$;

-- Budget totals: income, expenditures, shortfall (expenditures − income − carry forward).
create or replace function roca_budget_totals(p_budget uuid)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'income', coalesce(sum(annual) filter (where grp = 'INCOME'), 0),
    'expenditures', coalesce(sum(annual) filter (where grp <> 'INCOME'), 0),
    'by_group', (select jsonb_object_agg(grp, t) from (select grp, sum(annual) t from roca_budget_lines where budget_id = p_budget group by grp) g),
    'carry_forward', (select carry_forward from roca_budgets where id = p_budget),
    'shortfall', greatest(coalesce(sum(annual) filter (where grp <> 'INCOME'), 0) - coalesce(sum(annual) filter (where grp = 'INCOME'), 0)
                 - (select carry_forward from roca_budgets where id = p_budget), 0))
  from roca_budget_lines where budget_id = p_budget;
$$;
revoke all on function roca_budget_totals(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Seed: FY2025 budget, exactly as printed. Month columns read from the PDF's layout. One printed rounding:
-- 211 Electronic Services $177.38 × 12 = $2,128.56, printed $2,128.50 (the printed annual is kept).
do $$
declare v_b uuid; v_lines jsonb;
begin
  if exists (select 1 from roca_budgets where fiscal_year = 2025) then return; end if;
  insert into roca_budgets (fiscal_year, status, monthly_dues, carry_forward, printed_totals, source_document, notes, created_by)
  values (2025, 'on_file', 215, 6000,
    jsonb_build_object('total_expenditures', 65731.50, 'total_income', 38700.00, 'carry_forward', 6000.00, 'over_budget', 21031.50,
      'essential_services', 37103.00, 'total_administrative', 12243.50, 'total_utilities', 20918.00, 'total_grounds', 9370.00, 'total_buildings_commons', 23200.00),
    'mine/6622 N bourbon/budget/2022 Budget/ROCA1 Budget_2025_Jan.pdf',
    'Titled "ROCA1 FY 2025" (pages also say "2022 BUDGET UPDATE" and the totals say "2024" — template leftovers). Unit 8 is budgeted at $0 income (in foreclosure); its dues are still billed. "ESSENTIAL SERVICES $37,103.00" is printed without explanation. No adoption record was found, so the status is "on file".',
    'import')
  returning id into v_b;
  insert into roca_budget_lines (budget_id, grp, code, name, months, annual, sort)
  select v_b, 'INCOME', '101', 'Association Fees — Unit ' || u,
         array_fill(case when u = '8' then 0 else 215 end::numeric, array[12]), case when u = '8' then 0 else 2580 end, 100 + roca_unit_sort(u)
  from unnest(array['1','2','3','4','5','6','7','8','11','12','13','14','15','16','17','18']) u;
  insert into roca_budget_lines (budget_id, grp, code, name, months, annual, note, sort)
  select v_b, g, c, n, m, a, case when c = '211' then 'Printed annual $2,128.50; 12 × $177.38 = $2,128.56.' end, c::int * 10
  from (values
  ('INCOME', '102', 'Late Fees', array[0,0,0,0,0,0,0,0,0,0,0,0]::numeric[], 0.00),
  ('INCOME', '103', 'Interests Fees', array[0,0,0,0,0,0,0,0,0,0,0,0]::numeric[], 0.00),
  ('INCOME', '104', 'Interest on deposit', array[0,0,0,0,0,0,0,0,0,0,0,0]::numeric[], 0.00),
  ('INCOME', '105', 'Liens', array[0,0,0,0,0,0,0,0,0,0,0,0]::numeric[], 0.00),
  ('INCOME', '106', 'Special Assessments', array[0,0,0,0,0,0,0,0,0,0,0,0]::numeric[], 0.00),
  ('ADMINISTRATIVE', '201', 'Accounting', array[0,0,0,0,0,0,0,0,0,0,0,0]::numeric[], 0.00),
  ('ADMINISTRATIVE', '202', 'Insurance', array[770,770,770,770,770,770,770,770,770,770,770,770]::numeric[], 9240.00),
  ('ADMINISTRATIVE', '203', 'Legal', array[0,0,0,175,0,175,0,175,0,175,0,175]::numeric[], 875.00),
  ('ADMINISTRATIVE', '204', 'Office Supplies', array[0,0,0,0,0,0,0,0,0,0,0,0]::numeric[], 0.00),
  ('ADMINISTRATIVE', '205', 'Postage', array[0,0,0,0,0,0,0,0,0,0,0,0]::numeric[], 0.00),
  ('ADMINISTRATIVE', '206', 'Repairs & Maintenance', array[0,0,0,0,0,0,0,0,0,0,0,0]::numeric[], 0.00),
  ('ADMINISTRATIVE', '207', 'Salaries', array[0,0,0,0,0,0,0,0,0,0,0,0]::numeric[], 0.00),
  ('ADMINISTRATIVE', '208', 'Secretary Payroll Taxes', array[0,0,0,0,0,0,0,0,0,0,0,0]::numeric[], 0.00),
  ('ADMINISTRATIVE', '209', 'Printing', array[0,0,0,0,0,0,0,0,0,0,0,0]::numeric[], 0.00),
  ('ADMINISTRATIVE', '210', 'Banking', array[0,0,0,0,0,0,0,0,0,0,0,0]::numeric[], 0.00),
  ('ADMINISTRATIVE', '211', 'Electronic Services', array[177.38,177.38,177.38,177.38,177.38,177.38,177.38,177.38,177.38,177.38,177.38,177.38]::numeric[], 2128.50),
  ('UTILITIES', '301', 'Electric & Gas', array[500,500,500,500,500,500,500,500,500,500,500,500]::numeric[], 6000.00),
  ('UTILITIES', '302', 'Garbage', array[0,0,0,0,0,0,0,0,0,0,0,0]::numeric[], 0.00),
  ('UTILITIES', '303', 'Water / Sewer', array[0,0,3100,0,0,3100,0,0,3100,0,0,3100]::numeric[], 12400.00),
  ('UTILITIES', '304', 'Water Heater Rental', array[189,189,189,189,189,189,189,189,189,189,189,189]::numeric[], 2268.00),
  ('UTILITIES', '305', 'Fire Safety', array[250,0,0,0,0,0,0,0,0,0,0,0]::numeric[], 250.00),
  ('UTILITIES', '306', 'Wireless Internet Service', array[0,0,0,0,0,0,0,0,0,0,0,0]::numeric[], 0.00),
  ('UTILITIES', '307', 'Surveillance', array[0,0,0,0,0,0,0,0,0,0,0,0]::numeric[], 0.00),
  ('GROUNDS', '401', 'Equip Operations & Maint', array[250,150,50,0,0,150,0,0,150,0,0,0]::numeric[], 750.00),
  ('GROUNDS', '402', 'Landscaping', array[215,215,215,215,215,215,215,215,215,215,215,215]::numeric[], 2580.00),
  ('GROUNDS', '403', 'Snow Plow', array[140,140,240,0,0,0,0,0,0,0,360,480]::numeric[], 1360.00),
  ('GROUNDS', '404', 'Salt Walkway', array[30,20,0,0,0,0,0,0,0,0,30,20]::numeric[], 100.00),
  ('GROUNDS', '405', 'Groundskeeper', array[0,0,0,0,0,0,0,0,0,0,0,0]::numeric[], 0.00),
  ('GROUNDS', '406', 'Tru Green', array[0,135,210,0,135,210,0,135,210,0,135,210]::numeric[], 1380.00),
  ('GROUNDS', '407', 'Tree/Shrubbery Service', array[0,0,0,0,220,0,0,0,0,0,0,0]::numeric[], 220.00),
  ('GROUNDS', '408', 'Lobby Cleaning', array[215,215,215,215,215,215,215,215,215,215,215,215]::numeric[], 2580.00),
  ('GROUNDS', '409', 'Debris Disposal', array[0,0,0,0,0,0,0,0,0,0,0,0]::numeric[], 0.00),
  ('GROUNDS', '410', 'Miscellaneous', array[0,0,0,0,400,0,0,0,0,0,0,0]::numeric[], 400.00),
  ('BUILDINGS', '501', 'Roof "Repair"', array[8000,0,0,0,0,0,0,0,0,0,0,0]::numeric[], 8000.00),
  ('BUILDINGS', '502', 'Roof Replacement', array[0,0,0,0,0,0,0,0,0,0,0,0]::numeric[], 0.00),
  ('BUILDINGS', '503', 'Basement Protection', array[0,0,0,0,0,0,0,0,0,0,0,0]::numeric[], 0.00),
  ('BUILDINGS', '504', 'Window Well Protection', array[0,0,0,0,0,0,0,0,0,0,0,0]::numeric[], 0.00),
  ('BUILDINGS', '505', 'Door Replacement (Rear)', array[4000,0,0,0,0,400,0,0,0,0,0,0]::numeric[], 4400.00),
  ('BUILDINGS', '506', 'Window Replacement', array[0,0,0,0,0,0,0,0,0,0,0,0]::numeric[], 0.00),
  ('BUILDINGS', '507', 'Lobby Repair', array[0,0,0,0,0,0,0,0,0,0,0,0]::numeric[], 0.00),
  ('BUILDINGS', '508', 'Hallways', array[0,0,0,0,0,0,0,0,0,0,0,0]::numeric[], 0.00),
  ('BUILDINGS', '509', 'Walkway repairs', array[0,0,0,0,0,0,0,0,0,0,0,0]::numeric[], 0.00),
  ('BUILDINGS', '510', 'Bulb Replacement', array[150,0,0,0,0,150,0,0,0,0,0,0]::numeric[], 300.00),
  ('BUILDINGS', '511', 'Plumbing', array[8000,0,0,0,0,0,0,0,0,0,0,0]::numeric[], 8000.00),
  ('BUILDINGS', '512', 'Parking Lot', array[2500,0,0,0,0,0,0,0,0,0,0,0]::numeric[], 2500.00),
  ('BUILDINGS', '513', 'Common Area Cleaning', array[0,0,0,0,0,0,0,0,0,0,0,0]::numeric[], 0.00)
  ) as x(g, c, n, m, a);
end $$;

-- Seed: the two signed member actions of 2025 (history; nothing is re-executed) and the liens they name.
do $$
declare v_1 uuid; v_2 uuid;
begin
  if not exists (select 1 from roca_resolutions where source_document = 'files/legacy-files/ROCA1/2025-01-18_ROCA1_Ratified ByLaws 2025.pdf') then
    insert into roca_resolutions (kind, title, body, threshold, status, origin, origin_note, proposed_by, decided_at, decided_by, source_document, number, executed_at, execution_result)
    values ('rule', 'Action by Written Consent of the Members (1/16/2025): addresses, member classes D and E, reserve funds, liens, animals',
      'A. Unit Owners must keep an updated street mailing and electronic mailing address on file.' || E'\n' ||
      'B. Class D = units purchased before the rental cap of 1/1/1994 (may lease outside ROCA1 management; expires the later of 2/28/2025 or when the current occupant vacates). Class E = deed holders who have not lived in the unit for more than 30 months and/or hold no ROCA1 key; must pay the greater of 50% of fees owed, $6,450.00, or 30 months of fees, and reimburse property taxes ROCA1 paid for them, to receive keys.' || E'\n' ||
      'C. Class E members have no leasing rights and no right to occupy until requirement 0602(e) is met.' || E'\n' ||
      'D. Only members per Section 0602 have inspection and copying rights.' || E'\n' ||
      'E. ROCA1 does not hold or maintain a reserve account (Doc# 09222171, filed 4/21/2006).' || E'\n' ||
      'F. A Unit Owner becomes and remains a Class B member until liens are satisfied.' || E'\n' ||
      'G. No animals without board approval for non-owner occupants.',
      'members_consent', 'adopted', 'historical', 'Adopted before this system; signed 1/16–1/18/2025 by e-signature. Recorded from the signed document on file.',
      'import', '2025-01-18', 'import', 'files/legacy-files/ROCA1/2025-01-18_ROCA1_Ratified ByLaws 2025.pdf', '2025-H01', now(),
      jsonb_build_object('note', 'Historical: already in effect.'))
    returning id into v_1;
  end if;
  if not exists (select 1 from roca_resolutions where source_document = 'mine/6622 N bourbon/budget/Liens/ROCA1_Ratified Lien Actions.pdf') then
    insert into roca_resolutions (kind, title, body, threshold, status, origin, origin_note, proposed_by, decided_at, decided_by, source_document, number, executed_at, execution_result, payload)
    values ('lien_filing', 'Action by Written Consent of the Members (2/19/2025): lien evaluation, satisfactions, filing schedule, Unit 8 foreclosure',
      'A. ROCA1 will evaluate Owner Association Fee balances during October of every odd year.' || E'\n' ||
      'B. Lien satisfactions recorded: 11476132 (Unit 1), 11476133 (Unit 2), 11476134 (Unit 3), 11476135 (Unit 4), 11476136 (Unit 11), 11476137 (Unit 13), 11476138 (Unit 16), 11476139 and 11476140 (Unit 17). No other outstanding ROCA1 liens.' || E'\n' ||
      'C. ROCA1 will record a Statement of Condominium Lien in January of every even year for Owners with a balance greater than $1,290; liens filed every 23 months thereafter. Filed January 2025: 11476130 (Unit 1), 11476131 (Unit 12).' || E'\n' ||
      'D. ROCA1 will pursue a Judgment of Foreclosure for Association Fee greater than $10,320.00. Unit 8 (PIN 1450458000) balance greater than $70,000; foreclosure filing initiated.',
      'members_consent', 'adopted', 'historical', 'Adopted before this system; Secretary (Unit 7) to notarize the signatures. Recorded from the signed document on file.',
      'import', '2025-02-19', 'import', 'mine/6622 N bourbon/budget/Liens/ROCA1_Ratified Lien Actions.pdf', '2025-H02', now(),
      jsonb_build_object('note', 'Historical: already carried out; the liens are seeded in roca_liens.'),
      jsonb_build_object('units', jsonb_build_array(jsonb_build_object('unit', '1'), jsonb_build_object('unit', '12'))))
    returning id into v_2;
  else
    select id into v_2 from roca_resolutions where source_document = 'mine/6622 N bourbon/budget/Liens/ROCA1_Ratified Lien Actions.pdf';
  end if;

  if not exists (select 1 from roca_liens) then
    insert into roca_liens (unit_number, account_id, status, rod_document, recorded_on, refile_due, filing_resolution_id, source_document, notes, created_by)
    select x.u, roca_unit_account(x.u), 'recorded', x.doc, date '2025-01-11', (date '2025-01-11' + interval '23 months')::date, v_2, x.src,
      'Statement of Condominium Lien filed January 2025 (2/19/2025 action C). Recorded date taken from the file date 2025-01-11; check the recorded copy. Amount claimed not in the files read.', 'import'
    from (values ('1', '11476130', 'files/legacy-files/ROCA1/2025-01-11_11476130 lien_unit 1.pdf'),
                 ('12', '11476131', 'files/legacy-files/ROCA1/2025-01-11_11476131_lien_unit 12.pdf')) x(u, doc, src);
    insert into roca_liens (unit_number, account_id, status, satisfaction_document, satisfaction_resolution_id, source_document, notes, created_by)
    select x.u, roca_unit_account(x.u), 'satisfied', x.doc, v_2, 'mine/6622 N bourbon/budget/Liens/ROCA1_Ratified Lien Actions.pdf',
      'Satisfaction recorded on or before 2/19/2025 (action B). The original lien''s document number is not in the files read.', 'import'
    from (values ('1', '11476132'), ('2', '11476133'), ('3', '11476134'), ('4', '11476135'), ('11', '11476136'),
                 ('13', '11476137'), ('16', '11476138'), ('17', '11476139'), ('17', '11476140')) x(u, doc);
    insert into roca_liens (unit_number, account_id, status, foreclosure_resolution_id, source_document, notes, created_by)
    values ('8', roca_unit_account('8'), 'foreclosure', v_2, 'mine/6622 N bourbon/budget/Liens/ROCA1_Ratified Lien Actions.pdf',
      'Foreclosure filing initiated per 2/19/2025 action D (balance over $70,000 including late fees and interest). Lien and case numbers not in the files read.', 'import');
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Executors (called by roca_resolution_execute on adoption)

-- budget: payload {budget_id}. §1500(1)/(4).
create or replace function roca_exec_budget(p_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r roca_resolutions; b roca_budgets; t jsonb; u text; n int := 0; v_change boolean := false; v_cur numeric;
begin
  select * into r from roca_resolutions where id = p_id;
  select * into b from roca_budgets where id = (r.payload->>'budget_id')::uuid;
  if b.id is null then raise exception 'The resolution names no budget (payload budget_id).'; end if;
  update roca_budgets set status = 'adopted', resolution_id = p_id, updated_at = now() where id = b.id;
  t := roca_budget_totals(b.id);
  select mode() within group (order by fee) into v_cur from condo_ownerships where is_current;
  if v_cur is distinct from b.monthly_dues then
    insert into roca_dues_changes (budget_id, monthly_fee, effective_month) values (b.id, b.monthly_dues, make_date(b.fiscal_year, 1, 1));
    v_change := true;
  end if;
  for u in select * from roca_units() loop
    if roca_email_owner(u, 'ROCA1 ' || b.fiscal_year || ' budget and your annual assessment — Unit ' || u,
      '<p>The Board of Directors adopted the ROCA1 budget for fiscal year ' || b.fiscal_year || ' (resolution ' || coalesce(r.number, '') || ').</p>'
      || '<p><b>Your General Assessment for Unit ' || u || ': ' || roca_money(b.monthly_dues * 12) || ' for the year, due as ' || roca_money(b.monthly_dues)
      || ' on the first day of each month.</b></p>'
      || '<p>How it was determined: the budget plans ' || roca_money((t->>'expenditures')::numeric) || ' of common expenses and '
      || roca_money((t->>'income')::numeric) || ' of income. Under the Declaration (¶7, ¶16) every unit carries an equal one-sixteenth share of the common expenses.'
      || case when (t->>'shortfall')::numeric > 0 then ' The budget shows a shortfall of ' || roca_money((t->>'shortfall')::numeric) || ' after carry-forward; any special assessment to cover it would be a separate board decision with its own notice.' else '' end
      || '</p><p>The full budget is in your owner portal. By-Laws §1500(3): if, within fifteen days after the annual membership meeting, members holding more than 50% of the votes petition the Board, a meeting will be called to review the budget.</p>',
      'roca_budget') then n := n + 1; end if;
  end loop;
  return jsonb_build_object('budget', b.fiscal_year, 'owners_notified', n, 'dues_change_scheduled', v_change, 'monthly_dues', b.monthly_dues);
end;
$$;
revoke all on function roca_exec_budget(uuid) from public, anon, authenticated;

-- special_assessment: payload {title, reason, total, allocation equal_16|per_unit|single_unit, units {"8": 1200} (per_unit/single_unit),
-- installments, first_due (date), cost_reference}. §1500(5): notice of amount, due date and reason to each owner.
create or replace function roca_exec_special_assessment(p_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r roca_resolutions; p jsonb; a roca_assessments; v_alloc jsonb := '{}'::jsonb; u text; v_share numeric; v_cents int; v_n int; i int;
  v_inst numeric; v_rem numeric; v_units text[]; n_notice int := 0; v_sched text;
begin
  select * into r from roca_resolutions where id = p_id; p := r.payload;
  if coalesce((p->>'total')::numeric, 0) <= 0 then raise exception 'The resolution has no total (payload total).'; end if;
  if p->>'first_due' is null then raise exception 'The resolution has no first due date (payload first_due).'; end if;
  v_n := greatest(coalesce((p->>'installments')::int, 1), 1);
  insert into roca_assessments (resolution_id, title, reason, total, allocation, installments, first_due, cost_reference)
  values (p_id, coalesce(p->>'title', r.title), coalesce(p->>'reason', r.body, r.title), (p->>'total')::numeric, coalesce(p->>'allocation', 'equal_16'), v_n, (p->>'first_due')::date, p->>'cost_reference')
  returning * into a;
  if a.allocation = 'equal_16' then
    v_units := array(select * from roca_units());
    v_cents := round(a.total * 100)::int;
    for i in 1 .. array_length(v_units, 1) loop
      -- equal shares; leftover cents go to the first units so the shares add up to the total exactly
      v_share := (v_cents / array_length(v_units, 1) + case when i <= v_cents % array_length(v_units, 1) then 1 else 0 end) / 100.0;
      v_alloc := v_alloc || jsonb_build_object(v_units[i], v_share);
    end loop;
  else
    v_alloc := coalesce(p->'units', '{}'::jsonb);
    if v_alloc = '{}'::jsonb then raise exception 'List the units and amounts (payload units).'; end if;
    if a.allocation = 'single_unit' and (select count(*) from jsonb_object_keys(v_alloc)) <> 1 then raise exception 'A single-unit charge-back names exactly one unit.'; end if;
    if abs((select sum(value::numeric) from jsonb_each_text(v_alloc)) - a.total) > 0.009 then raise exception 'The unit amounts don''t add up to the total.'; end if;
  end if;
  for u, v_share in select key, value::numeric from jsonb_each_text(v_alloc) loop
    if not exists (select 1 from condo_units where unit_number = u) then raise exception 'Unit % isn''t on file.', u; end if;
    v_inst := floor(v_share * 100 / v_n) / 100; v_rem := v_share - v_inst * v_n;
    v_sched := '';
    for i in 1 .. v_n loop
      insert into roca_assessment_charges (assessment_id, unit_number, installment, due_date, amount)
      values (a.id, u, i, (a.first_due + ((i - 1) || ' months')::interval)::date, v_inst + case when i = v_n then v_rem else 0 end);
      v_sched := v_sched || '<li>' || to_char((a.first_due + ((i - 1) || ' months')::interval)::date, 'FMMonth FMDD, YYYY') || ': ' || roca_money(v_inst + case when i = v_n then v_rem else 0 end) || '</li>';
    end loop;
    if roca_email_owner(u, 'Notice of Special Assessment — Unit ' || u || ': ' || a.title,
      '<p>By resolution ' || coalesce(r.number, '') || ', adopted by the Board of Directors, ROCA1 has levied a Special Assessment (By-Laws §1500(5)).</p>'
      || '<p><b>Amount assessed to Unit ' || u || ': ' || roca_money(v_share) || '</b>' || case when a.allocation = 'equal_16' then ' (one-sixteenth of ' || roca_money(a.total) || ', Declaration ¶7)' else '' end || '.</p>'
      || '<p><b>Due:</b></p><ul>' || v_sched || '</ul><p><b>Reason:</b> ' || repair_esc(a.reason) || '</p>'
      || '<p>It will appear on your association account on each due date. Questions: reply to this email or call the office.</p>', 'roca_assessment') then
      update roca_assessment_charges set notice_sent_at = now() where assessment_id = a.id and unit_number = u;
      n_notice := n_notice + 1;
    end if;
  end loop;
  return jsonb_build_object('assessment_id', a.id, 'units', (select count(*) from jsonb_object_keys(v_alloc)), 'installments', v_n, 'notices', n_notice);
end;
$$;
revoke all on function roca_exec_special_assessment(uuid) from public, anon, authenticated;

-- lien_filing: payload {units: [{unit, amount}], as_of}. Each becomes an APPROVED lien; staff record the ROD number when filed.
create or replace function roca_exec_lien_filing(p_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r roca_resolutions; x jsonb; v_made jsonb := '[]'::jsonb; v_skip jsonb := '[]'::jsonb; v_amt numeric;
begin
  select * into r from roca_resolutions where id = p_id;
  for x in select * from jsonb_array_elements(coalesce(r.payload->'units', '[]'::jsonb)) loop
    if exists (select 1 from roca_liens where unit_number = x->>'unit' and status in ('approved', 'recorded', 'satisfaction_approved', 'foreclosure')) then
      v_skip := v_skip || jsonb_build_array(x->>'unit'); continue;
    end if;
    v_amt := coalesce((x->>'amount')::numeric, roca_unit_balance(x->>'unit'));
    insert into roca_liens (unit_number, account_id, amount_claimed, as_of, status, filing_resolution_id, notes, created_by)
    values (x->>'unit', roca_unit_account(x->>'unit'), v_amt, coalesce((r.payload->>'as_of')::date, current_date), 'approved', p_id,
            'Approved by resolution ' || coalesce(r.number, '') || '; record the Statement of Condominium Lien with the Register of Deeds and enter its document number.', 'resolution');
    v_made := v_made || jsonb_build_array(x->>'unit');
    perform roca_email_owner(x->>'unit', 'Statement of Condominium Lien to be recorded — Unit ' || (x->>'unit'),
      '<p>By resolution ' || coalesce(r.number, '') || ', ROCA1 will record a Statement of Condominium Lien against Unit ' || repair_esc(x->>'unit')
      || ' for unpaid assessments of ' || roca_money(v_amt) || ' (Declaration ¶16; Wis. Stat. §703.165). Recording costs are charged to the unit''s account (Rules & Regulations).</p>'
      || '<p>Paying the balance in full before it is recorded avoids the lien and its costs. Call the office to arrange payment.</p>', 'roca_lien');
  end loop;
  perform office_alert('roca_alert_email', 'roca_lien', 'Liens approved — record them with the Register of Deeds',
    '<p>Resolution ' || coalesce(r.number, '') || ' approved liens for unit(s) ' || coalesce((select string_agg(value #>> '{}', ', ') from jsonb_array_elements(v_made)), 'none')
    || '. Record each Statement of Condominium Lien and enter its document number on the Board page (Liens).</p>');
  return jsonb_build_object('approved', v_made, 'skipped_existing_lien', v_skip);
end;
$$;
revoke all on function roca_exec_lien_filing(uuid) from public, anon, authenticated;

-- lien_satisfaction: payload {lien_ids: [...]} or {units: [{unit}]}. Liens become satisfaction_approved; staff record the satisfaction.
create or replace function roca_exec_lien_satisfaction(p_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r roca_resolutions; v_ids uuid[]; v_n int;
begin
  select * into r from roca_resolutions where id = p_id;
  v_ids := array(select (value #>> '{}')::uuid from jsonb_array_elements(coalesce(r.payload->'lien_ids', '[]'::jsonb)))
        || array(select l.id from roca_liens l join jsonb_array_elements(coalesce(r.payload->'units', '[]'::jsonb)) x on x->>'unit' = l.unit_number where l.status = 'recorded');
  update roca_liens set status = 'satisfaction_approved', satisfaction_resolution_id = p_id, updated_at = now() where id = any(v_ids) and status = 'recorded';
  get diagnostics v_n = row_count;
  perform office_alert('roca_alert_email', 'roca_lien', 'Lien satisfactions approved — record them',
    '<p>Resolution ' || coalesce(r.number, '') || ' approved ' || v_n || ' lien satisfaction(s). Record each satisfaction with the Register of Deeds and enter its document number on the Board page.</p>');
  return jsonb_build_object('satisfaction_approved', v_n);
end;
$$;
revoke all on function roca_exec_lien_satisfaction(uuid) from public, anon, authenticated;

-- foreclosure: payload {units: [{unit, amount}]}. The unit's lien (or a new record) goes to 'foreclosure' and a collections step is logged.
create or replace function roca_exec_foreclosure(p_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r roca_resolutions; x jsonb; v_done jsonb := '[]'::jsonb; v_unit uuid;
begin
  select * into r from roca_resolutions where id = p_id;
  for x in select * from jsonb_array_elements(coalesce(r.payload->'units', '[]'::jsonb)) loop
    if exists (select 1 from roca_liens where unit_number = x->>'unit' and status = 'foreclosure') then continue; end if;
    update roca_liens set status = 'foreclosure', foreclosure_resolution_id = p_id, updated_at = now()
     where id = (select id from roca_liens where unit_number = x->>'unit' and status in ('recorded', 'approved') order by recorded_on desc nulls last limit 1);
    if not found then
      insert into roca_liens (unit_number, account_id, amount_claimed, as_of, status, foreclosure_resolution_id, notes, created_by)
      values (x->>'unit', roca_unit_account(x->>'unit'), coalesce((x->>'amount')::numeric, roca_unit_balance(x->>'unit')), current_date, 'foreclosure', p_id,
              'Foreclosure approved by resolution ' || coalesce(r.number, '') || '.', 'resolution');
    end if;
    select id into v_unit from condo_units where unit_number = x->>'unit';
    insert into condo_collection_steps (unit_id, account_id, step, step_date, amount, note, entered_by)
    values (v_unit, roca_unit_account(x->>'unit'), 'foreclosure', current_date, coalesce((x->>'amount')::numeric, roca_unit_balance(x->>'unit')),
            'Judgment of foreclosure to be pursued per resolution ' || coalesce(r.number, ''), 'resolution');
    v_done := v_done || jsonb_build_array(x->>'unit');
  end loop;
  perform office_alert('roca_alert_email', 'roca_lien', 'Foreclosure approved', '<p>Resolution ' || coalesce(r.number, '') || ' approved foreclosure for unit(s) '
    || coalesce((select string_agg(value #>> '{}', ', ') from jsonb_array_elements(v_done)), 'none') || '. Engage the attorney and log each step under Collections.</p>');
  return jsonb_build_object('foreclosure', v_done);
end;
$$;
revoke all on function roca_exec_foreclosure(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Automations (run by roca_automation_run; p_live = false → report only)

-- Post special-assessment installments on their due date; optional §1500(6) penalty.
create or replace function roca_auto_assessments(p_today date, p_live boolean)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare c record; v_id bigint; n int := 0; n_pen int := 0; v_due jsonb := '[]'::jsonb;
  v_pen boolean := coalesce((select value from portal_settings where key = 'roca_assessment_penalty'), 'off') = 'on';
  v_pct numeric := coalesce((select value from portal_settings where key = 'roca_assessment_penalty_pct'), '12')::numeric;
  v_days int := coalesce((select value from portal_settings where key = 'roca_assessment_penalty_days'), '15')::int;
begin
  for c in select ch.*, a.title, a.status a_status, r.number from roca_assessment_charges ch join roca_assessments a on a.id = ch.assessment_id
           join roca_resolutions r on r.id = a.resolution_id
           where ch.ledger_entry_id is null and ch.due_date <= p_today and a.status = 'scheduled' order by ch.due_date, ch.unit_number loop
    v_due := v_due || jsonb_build_array(jsonb_build_object('unit', c.unit_number, 'amount', c.amount, 'due', c.due_date));
    if p_live then
      v_id := roca_post_charge(c.unit_number, 'Special Assessment', c.due_date, c.amount, 'Special assessment',
        'Special assessment ' || coalesce(c.number, '') || ': ' || c.title || case when (select installments from roca_assessments where id = c.assessment_id) > 1 then ' (installment ' || c.installment || ')' else '' end,
        'billing', 'automation', 'Resolution ' || coalesce(c.number, ''));
      update roca_assessment_charges set ledger_entry_id = v_id, posted_at = now() where id = c.id;
      n := n + 1;
    end if;
  end loop;
  if p_live then
    update roca_assessments a set status = 'complete' where status = 'scheduled'
      and not exists (select 1 from roca_assessment_charges ch where ch.assessment_id = a.id and ch.ledger_entry_id is null);
  end if;
  if v_pen then
    for c in select ch.*, r.number from roca_assessment_charges ch join roca_assessments a on a.id = ch.assessment_id join roca_resolutions r on r.id = a.resolution_id
             where ch.ledger_entry_id is not null and ch.penalty_entry_id is null and ch.due_date + v_days < p_today and roca_unit_balance(ch.unit_number, p_today) > 0 loop
      if p_live then
        v_id := roca_post_charge(c.unit_number, 'Late Fee Income', p_today, round(c.amount * v_pct / 100, 2), 'Late penalty',
          'Late penalty ' || v_pct || '% on special assessment ' || coalesce(c.number, ''), 'billing', 'automation', 'By-Laws §1500(6)');
        update roca_assessment_charges set penalty_entry_id = v_id where id = c.id;
      end if;
      n_pen := n_pen + 1;
    end loop;
  end if;
  return jsonb_build_object('installments_due', jsonb_array_length(v_due), 'posted', n, 'penalties', n_pen, 'penalty_setting', case when v_pen then 'on' else 'off' end, 'due', v_due);
end;
$$;
revoke all on function roca_auto_assessments(date, boolean) from public, anon, authenticated;

-- Budget: apply scheduled dues changes; from October 1 remind staff that next year's budget must be adopted 30 days before (§1500(1)).
create or replace function roca_auto_budget(p_today date, p_live boolean)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare d record; v_applied int := 0; v_next int := extract(year from p_today)::int + 1; v_alert boolean := false; v_last text;
begin
  for d in select * from roca_dues_changes where applied_at is null and effective_month <= p_today loop
    if p_live then
      update condo_ownerships set fee = d.monthly_fee where is_current and coalesce(fee_frequency, 'Monthly') = 'Monthly';
      update roca_dues_changes set applied_at = now(), applied_result = jsonb_build_object('fee', d.monthly_fee) where id = d.id;
    end if;
    v_applied := v_applied + 1;
  end loop;
  if extract(month from p_today) >= 10 and not exists (select 1 from roca_budgets where fiscal_year = v_next and status = 'adopted') then
    v_last := (select value from portal_settings where key = 'roca_budget_alerted_on');
    if coalesce(nullif(v_last, '')::date, date '2000-01-01') <= p_today - 7 then
      v_alert := true;
      if p_live then
        perform office_alert('roca_alert_email', 'roca_budget', 'ROCA1 ' || v_next || ' budget not adopted yet',
          '<p>By-Laws §1500(1): the Board adopts the budget at least 30 days before the fiscal year (by ' || to_char(make_date(v_next - 1, 12, 1), 'FMMonth FMDD, YYYY')
          || '). There is no adopted ' || v_next || ' budget yet. Copy last year''s on the Board page, adjust it, and propose it.</p>');
        update portal_settings set value = p_today::text where key = 'roca_budget_alerted_on';
      end if;
    end if;
  end if;
  return jsonb_build_object('dues_changes_applied', v_applied, 'next_year_budget_missing_alert', v_alert, 'next_year', v_next);
end;
$$;
revoke all on function roca_auto_budget(date, boolean) from public, anon, authenticated;

-- Units already covered by an open (draft/voting) resolution of this kind.
create or replace function roca_units_pending(p_kind text)
returns setof text language sql stable security definer set search_path = public as $$
  select distinct x->>'unit' from roca_resolutions r cross join lateral jsonb_array_elements(coalesce(r.payload->'units', '[]'::jsonb)) x
  where r.kind = p_kind and r.status in ('draft', 'voting');
$$;
revoke all on function roca_units_pending(text) from public, anon, authenticated;

-- Liens: evaluation (October of odd years, action A) / filing season (January of even years, action C); refiles (23 months);
-- satisfactions when paid; foreclosure over the action D threshold. Proposes resolutions only.
create or replace function roca_auto_liens(p_today date, p_live boolean)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_thr numeric := coalesce((select value from portal_settings where key = 'roca_lien_threshold'), '1290')::numeric;
  v_fc numeric := coalesce((select value from portal_settings where key = 'roca_foreclosure_threshold'), '10320')::numeric;
  v_m int := extract(month from p_today); v_y int := extract(year from p_today);
  v_eval boolean; v_file jsonb := '[]'::jsonb; v_sat jsonb := '[]'::jsonb; v_fcl jsonb := '[]'::jsonb; v_refile jsonb := '[]'::jsonb;
  u text; l record; v_new jsonb := '{}'::jsonb;
begin
  v_eval := (v_m = 10 and v_y % 2 = 1) or (v_m = 1 and v_y % 2 = 0);
  if v_eval and not exists (select 1 from roca_resolutions where kind = 'lien_filing' and origin = 'automation' and proposed_at > p_today - 120) then
    for u in select * from roca_units() loop
      if roca_unit_balance(u, p_today) > v_thr
         and not exists (select 1 from roca_liens where unit_number = u and status in ('approved', 'recorded', 'satisfaction_approved', 'foreclosure'))
         and u not in (select * from roca_units_pending('lien_filing')) then
        v_file := v_file || jsonb_build_array(jsonb_build_object('unit', u, 'amount', roca_unit_balance(u, p_today)));
      end if;
    end loop;
    if jsonb_array_length(v_file) > 0 and p_live then
      v_new := v_new || jsonb_build_object('lien_filing', roca_resolution_propose('lien_filing',
        'Record Statements of Condominium Lien (' || case when v_m = 10 then 'October ' || v_y || ' evaluation' else 'January ' || v_y || ' filing' end || ')',
        'RESOLVED, that ROCA1 record a Statement of Condominium Lien with the Register of Deeds against each unit listed, whose balance exceeds '
        || roca_money(v_thr) || ' (Action by Written Consent of 2/19/2025, C): '
        || (select string_agg('Unit ' || (x->>'unit') || ' ' || roca_money((x->>'amount')::numeric), '; ') from jsonb_array_elements(v_file) x) || '.',
        'members_consent', jsonb_build_object('units', v_file, 'as_of', p_today), 'automation',
        'Threshold ' || roca_money(v_thr) || ' from the 2/19/2025 action (Rules 2024 §11(4) says $430 — setting roca_lien_threshold).', 'automation'));
    end if;
  end if;
  -- Refiles: action C, every 23 months. Alert once, 30 days ahead.
  for l in select * from roca_liens where status = 'recorded' and refile_due is not null and refile_due <= p_today + 30 and refile_alerted_at is null loop
    v_refile := v_refile || jsonb_build_array(jsonb_build_object('unit', l.unit_number, 'rod_document', l.rod_document, 'refile_due', l.refile_due));
    if p_live then update roca_liens set refile_alerted_at = now() where id = l.id; end if;
  end loop;
  if jsonb_array_length(v_refile) > 0 and p_live then
    perform office_alert('roca_alert_email', 'roca_lien', 'Liens due for refiling',
      '<p>Action C (2/19/2025) refiles liens every 23 months. Due: ' || (select string_agg('Unit ' || (x->>'unit') || ' (' || coalesce(x->>'rod_document', '?') || ', ' || (x->>'refile_due') || ')', '; ') from jsonb_array_elements(v_refile) x) || '.</p>');
  end if;
  -- Satisfaction: a recorded lien on a unit that now owes nothing.
  for l in select distinct unit_number from roca_liens where status = 'recorded' loop
    if roca_unit_balance(l.unit_number, p_today) <= 0 and l.unit_number not in (select * from roca_units_pending('lien_satisfaction')) then
      v_sat := v_sat || jsonb_build_array(jsonb_build_object('unit', l.unit_number));
    end if;
  end loop;
  if jsonb_array_length(v_sat) > 0 and p_live then
    v_new := v_new || jsonb_build_object('lien_satisfaction', roca_resolution_propose('lien_satisfaction', 'Satisfy paid liens',
      'RESOLVED, that ROCA1 record a Satisfaction of Lien for each unit listed, whose balance is paid in full: '
      || (select string_agg('Unit ' || (x->>'unit'), ', ') from jsonb_array_elements(v_sat) x) || '.',
      'members_consent', jsonb_build_object('units', v_sat), 'automation', 'Same form as the 2/19/2025 action B (members'' written consent). Staff may change who decides while it is a draft.', 'automation'));
  end if;
  -- Foreclosure: association-fee balance over the action D threshold, not already in foreclosure.
  for u in select * from roca_units() loop
    if roca_unit_fee_balance(u, p_today) > v_fc and not exists (select 1 from roca_liens where unit_number = u and status = 'foreclosure')
       and u not in (select * from roca_units_pending('foreclosure')) then
      v_fcl := v_fcl || jsonb_build_array(jsonb_build_object('unit', u, 'amount', roca_unit_balance(u, p_today), 'fee_balance', roca_unit_fee_balance(u, p_today)));
    end if;
  end loop;
  if jsonb_array_length(v_fcl) > 0 and p_live then
    v_new := v_new || jsonb_build_object('foreclosure', roca_resolution_propose('foreclosure', 'Pursue judgment of foreclosure',
      'RESOLVED, that ROCA1 pursue a Judgment of Foreclosure against each unit listed, whose Association Fee balance exceeds ' || roca_money(v_fc)
      || ' (Action by Written Consent of 2/19/2025, D): ' || (select string_agg('Unit ' || (x->>'unit') || ' fees ' || roca_money((x->>'fee_balance')::numeric), '; ') from jsonb_array_elements(v_fcl) x) || '.',
      'members_consent', jsonb_build_object('units', v_fcl), 'automation', 'Same form as the 2/19/2025 action D.', 'automation'));
  end if;
  return jsonb_build_object('evaluation_window', v_eval, 'threshold', v_thr, 'would_file', v_file, 'refile_due', v_refile,
    'would_satisfy', v_sat, 'foreclosure_threshold', v_fc, 'would_foreclose', v_fcl, 'proposed', v_new);
end;
$$;
revoke all on function roca_auto_liens(date, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Staff: budget
create or replace function roca_budget_json(b roca_budgets)
returns jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(b) || jsonb_build_object(
    'totals', roca_budget_totals(b.id),
    'resolution', (select jsonb_build_object('id', r.id, 'number', r.number, 'status', r.status) from roca_resolutions r where r.id = b.resolution_id
                   or (r.kind = 'budget' and r.payload->>'budget_id' = b.id::text and r.status in ('draft', 'voting')) order by r.proposed_at desc limit 1),
    'lines', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'grp', l.grp, 'code', l.code, 'name', l.name, 'months', l.months, 'annual', l.annual, 'note', l.note,
        'actual', case when l.grp = 'INCOME' then null else (select coalesce(sum(x.amount), 0) from roca_expenses x where x.voided_at is null and x.budget_code = l.code
                     and extract(year from x.expense_date) = b.fiscal_year) end) order by l.sort, l.code) from roca_budget_lines l where l.budget_id = b.id), '[]'::jsonb),
    'actual_income', (select jsonb_build_object(
        'dues_collected', -coalesce(sum(e.amount) filter (where e.kind = 'payment' and e.gl_account = 'Association Fee Income'), 0),
        'all_collected', -coalesce(sum(e.amount) filter (where e.kind = 'payment'), 0),
        'dues_billed', coalesce(sum(e.amount) filter (where e.kind = 'charge' and e.gl_account = 'Association Fee Income'), 0))
      from condo_ledger_entries e join condo_ledger_accounts a on a.id = e.account_id and not a.excluded
      where extract(year from e.entry_date) = b.fiscal_year),
    'actual_expenses', (select coalesce(sum(amount), 0) from roca_expenses where voided_at is null and extract(year from expense_date) = b.fiscal_year),
    'expenses', coalesce((select jsonb_agg(to_jsonb(x) order by x.expense_date desc) from roca_expenses x where extract(year from x.expense_date) = b.fiscal_year), '[]'::jsonb));
$$;
revoke all on function roca_budget_json(roca_budgets) from public, anon, authenticated;

create or replace function roca_budgets_staff()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform roca_staff_check();
  return jsonb_build_object('budgets', coalesce((select jsonb_agg(roca_budget_json(b) order by b.fiscal_year desc) from roca_budgets b), '[]'::jsonb),
    'current_dues', (select mode() within group (order by fee) from condo_ownerships where is_current),
    'dues_changes', coalesce((select jsonb_agg(to_jsonb(d) order by d.effective_month desc) from roca_dues_changes d), '[]'::jsonb));
end;
$$;
revoke all on function roca_budgets_staff() from public, anon;
grant execute on function roca_budgets_staff() to authenticated;

-- Start next year's budget as a copy of an existing one (draft).
create or replace function roca_budget_copy(p_from_year int, p_to_year int)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare f roca_budgets; b roca_budgets;
begin
  perform roca_staff_check();
  select * into f from roca_budgets where fiscal_year = p_from_year;
  if f.id is null then raise exception 'No % budget to copy.', p_from_year; end if;
  if exists (select 1 from roca_budgets where fiscal_year = p_to_year) then raise exception 'A % budget already exists.', p_to_year; end if;
  insert into roca_budgets (fiscal_year, status, monthly_dues, carry_forward, notes, created_by)
  values (p_to_year, 'draft', f.monthly_dues, 0, 'Copied from ' || p_from_year || '.', lower(auth.email())) returning * into b;
  insert into roca_budget_lines (budget_id, grp, code, name, months, annual, note, sort)
  select b.id, grp, code, name, months, annual, note, sort from roca_budget_lines where budget_id = f.id;
  return roca_budget_json(b);
end;
$$;
revoke all on function roca_budget_copy(int, int) from public, anon;
grant execute on function roca_budget_copy(int, int) to authenticated;

create or replace function roca_budget_set(p_budget uuid, p_monthly_dues numeric, p_carry_forward numeric, p_notes text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare b roca_budgets;
begin
  perform roca_staff_check();
  if coalesce(p_monthly_dues, -1) < 0 then raise exception 'Enter the monthly dues.'; end if;
  update roca_budgets set monthly_dues = p_monthly_dues, carry_forward = coalesce(p_carry_forward, 0), notes = p_notes, updated_at = now()
   where id = p_budget and status = 'draft' returning * into b;
  if b.id is null then raise exception 'Only a draft budget can be changed.'; end if;
  update roca_budget_lines set months = array_fill(p_monthly_dues, array[12]), annual = p_monthly_dues * 12
   where budget_id = b.id and code = '101';
  return roca_budget_json(b);
end;
$$;
revoke all on function roca_budget_set(uuid, numeric, numeric, text) from public, anon;
grant execute on function roca_budget_set(uuid, numeric, numeric, text) to authenticated;

-- Add or change a line (p_line null = new). Annual = sum of months.
create or replace function roca_budget_line_save(p_budget uuid, p_line uuid, p_grp text, p_code text, p_name text, p_months numeric[], p_note text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare b roca_budgets;
begin
  perform roca_staff_check();
  select * into b from roca_budgets where id = p_budget;
  if b.status <> 'draft' then raise exception 'Only a draft budget can be changed.'; end if;
  if coalesce(array_length(p_months, 1), 0) <> 12 then raise exception 'Give twelve monthly amounts.'; end if;
  if p_line is null then
    insert into roca_budget_lines (budget_id, grp, code, name, months, annual, note, sort)
    values (p_budget, p_grp, trim(p_code), trim(p_name), p_months, (select sum(x) from unnest(p_months) x), p_note, coalesce(nullif(regexp_replace(p_code, '\D', '', 'g'), '')::int * 10, 9999));
  else
    update roca_budget_lines set grp = p_grp, code = trim(p_code), name = trim(p_name), months = p_months, annual = (select sum(x) from unnest(p_months) x), note = p_note
     where id = p_line and budget_id = p_budget;
  end if;
  return roca_budget_json(b);
end;
$$;
revoke all on function roca_budget_line_save(uuid, uuid, text, text, text, numeric[], text) from public, anon;
grant execute on function roca_budget_line_save(uuid, uuid, text, text, text, numeric[], text) to authenticated;

create or replace function roca_budget_line_delete(p_line uuid)
returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  perform roca_staff_check();
  delete from roca_budget_lines l using roca_budgets b where l.id = p_line and b.id = l.budget_id and b.status = 'draft';
  if not found then raise exception 'Only a line of a draft budget can be removed.'; end if;
end;
$$;
revoke all on function roca_budget_line_delete(uuid) from public, anon;
grant execute on function roca_budget_line_delete(uuid) to authenticated;

-- Draft the board resolution adopting a budget (§1500(1): majority of all directors).
create or replace function roca_budget_propose(p_budget uuid)
returns uuid
language plpgsql volatile security definer set search_path = public as $$
declare b roca_budgets; t jsonb; v_id uuid;
begin
  perform roca_staff_check();
  select * into b from roca_budgets where id = p_budget;
  if b.status not in ('draft', 'proposed', 'on_file') then raise exception 'This budget is already adopted.'; end if;
  t := roca_budget_totals(b.id);
  v_id := roca_resolution_propose('budget', 'Adopt the ' || b.fiscal_year || ' budget',
    'RESOLVED, that the Board of Directors adopts the ROCA1 budget for fiscal year ' || b.fiscal_year || ': common expenses ' || roca_money((t->>'expenditures')::numeric)
    || ', income ' || roca_money((t->>'income')::numeric) || ', carry-forward ' || roca_money(b.carry_forward) || ', and a General Assessment of ' || roca_money(b.monthly_dues)
    || ' per unit per month, due on the first of each month (By-Laws §1500(1), (4)).',
    'board_majority_all', jsonb_build_object('budget_id', b.id), 'manual', null, lower(auth.email()));
  update roca_budgets set status = 'proposed', updated_at = now() where id = b.id and status = 'draft';
  return v_id;
end;
$$;
revoke all on function roca_budget_propose(uuid) from public, anon;
grant execute on function roca_budget_propose(uuid) to authenticated;

-- Draft a special assessment covering the budget's shortfall, split 1/16 (Declaration ¶7).
create or replace function roca_shortfall_propose(p_budget uuid, p_installments int, p_first_due date)
returns uuid
language plpgsql volatile security definer set search_path = public as $$
declare b roca_budgets; t jsonb; v_short numeric;
begin
  perform roca_staff_check();
  select * into b from roca_budgets where id = p_budget;
  t := roca_budget_totals(b.id); v_short := (t->>'shortfall')::numeric;
  if v_short <= 0 then raise exception 'This budget shows no shortfall.'; end if;
  return roca_assessment_draft('Special assessment: ' || b.fiscal_year || ' budget shortfall',
    'The ' || b.fiscal_year || ' budget plans ' || roca_money((t->>'expenditures')::numeric) || ' of common expenses against ' || roca_money((t->>'income')::numeric)
    || ' of income and ' || roca_money(b.carry_forward) || ' carried forward, a shortfall of ' || roca_money(v_short) || '.',
    v_short, 'equal_16', null, coalesce(p_installments, 1), p_first_due, null);
end;
$$;
revoke all on function roca_shortfall_propose(uuid, int, date) from public, anon;
grant execute on function roca_shortfall_propose(uuid, int, date) to authenticated;

create or replace function roca_expense_add(p_date date, p_code text, p_vendor text, p_amount numeric, p_memo text, p_receipt text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare x roca_expenses;
begin
  perform roca_staff_check();
  if p_date is null or coalesce(p_amount, 0) <= 0 or coalesce(trim(p_code), '') = '' then raise exception 'Enter the date, budget code and amount.'; end if;
  insert into roca_expenses (expense_date, budget_code, vendor, amount, memo, receipt_path, entered_by)
  values (p_date, trim(p_code), nullif(trim(coalesce(p_vendor, '')), ''), p_amount, nullif(trim(coalesce(p_memo, '')), ''), nullif(trim(coalesce(p_receipt, '')), ''), lower(auth.email()))
  returning * into x;
  return to_jsonb(x);
end;
$$;
revoke all on function roca_expense_add(date, text, text, numeric, text, text) from public, anon;
grant execute on function roca_expense_add(date, text, text, numeric, text, text) to authenticated;

create or replace function roca_expense_void(p_id uuid, p_note text)
returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  perform roca_staff_check();
  if length(coalesce(trim(p_note), '')) < 3 then raise exception 'Say why it is voided.'; end if;
  update roca_expenses set voided_at = now(), void_note = trim(p_note) || ' (' || lower(auth.email()) || ')' where id = p_id and voided_at is null;
  if not found then raise exception 'Expense not found or already voided.'; end if;
end;
$$;
revoke all on function roca_expense_void(uuid, text) from public, anon;
grant execute on function roca_expense_void(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Staff: special assessments
-- Draft the board resolution for an assessment (every assessment, incl. a single-unit charge-back, is a board vote: §1500(5)).
create or replace function roca_assessment_draft(p_title text, p_reason text, p_total numeric, p_allocation text, p_units jsonb,
  p_installments int, p_first_due date, p_cost_reference text)
returns uuid
language plpgsql volatile security definer set search_path = public as $$
declare v_body text;
begin
  perform roca_staff_check();
  if coalesce(p_total, 0) <= 0 then raise exception 'Enter the total.'; end if;
  if p_first_due is null then raise exception 'Enter the first due date.'; end if;
  if length(coalesce(trim(p_reason), '')) < 5 then raise exception 'State the reason (owners receive it in the notice).'; end if;
  if p_allocation not in ('equal_16', 'per_unit', 'single_unit') then raise exception 'Choose how it is shared.'; end if;
  v_body := 'RESOLVED, that the Board of Directors levies a Special Assessment of ' || roca_money(p_total)
    || case p_allocation when 'equal_16' then ', shared equally by the 16 units (one-sixteenth each, Declaration ¶7)'
         when 'single_unit' then ' against Unit ' || (select string_agg(k, ', ') from jsonb_object_keys(p_units) k) || ', the unit owner responsible (By-Laws §1500(3))'
         else ' allocated: ' || (select string_agg('Unit ' || key || ' ' || roca_money(value::numeric), '; ') from jsonb_each_text(p_units)) end
    || ', due ' || case when coalesce(p_installments, 1) > 1 then 'in ' || p_installments || ' monthly installments starting ' else 'on ' end
    || to_char(p_first_due, 'FMMonth FMDD, YYYY') || '. Reason: ' || trim(p_reason) || coalesce(' (' || nullif(trim(coalesce(p_cost_reference, '')), '') || ')', '') || ' (By-Laws §1500(5)).';
  return roca_resolution_propose('special_assessment', trim(p_title), v_body, 'board_majority_all',
    jsonb_build_object('title', trim(p_title), 'reason', trim(p_reason), 'total', p_total, 'allocation', p_allocation, 'units', coalesce(p_units, '{}'::jsonb),
      'installments', coalesce(p_installments, 1), 'first_due', p_first_due, 'cost_reference', p_cost_reference), 'manual', null, lower(auth.email()));
end;
$$;
revoke all on function roca_assessment_draft(text, text, numeric, text, jsonb, int, date, text) from public, anon;
grant execute on function roca_assessment_draft(text, text, numeric, text, jsonb, int, date, text) to authenticated;

create or replace function roca_assessments_staff()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform roca_staff_check();
  return coalesce((select jsonb_agg(to_jsonb(a) || jsonb_build_object('number', r.number,
      'charges', (select jsonb_agg(to_jsonb(c) order by roca_unit_sort(c.unit_number), c.installment) from roca_assessment_charges c where c.assessment_id = a.id),
      'posted', (select coalesce(sum(amount), 0) from roca_assessment_charges c where c.assessment_id = a.id and c.ledger_entry_id is not null)) order by a.created_at desc)
    from roca_assessments a join roca_resolutions r on r.id = a.resolution_id), '[]'::jsonb);
end;
$$;
revoke all on function roca_assessments_staff() from public, anon;
grant execute on function roca_assessments_staff() to authenticated;

-- ---------------------------------------------------------------------------
-- Staff: liens
create or replace function roca_lien_json(l roca_liens)
returns jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(l) || jsonb_build_object('balance', roca_unit_balance(l.unit_number), 'fee_balance', roca_unit_fee_balance(l.unit_number),
    'owner', (select name from roca_unit_owner(l.unit_number)),
    'filing_number', (select number from roca_resolutions where id = l.filing_resolution_id),
    'satisfaction_number', (select number from roca_resolutions where id = l.satisfaction_resolution_id),
    'foreclosure_number', (select number from roca_resolutions where id = l.foreclosure_resolution_id));
$$;
revoke all on function roca_lien_json(roca_liens) from public, anon, authenticated;

create or replace function roca_liens_staff()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform roca_staff_check();
  return jsonb_build_object(
    'liens', coalesce((select jsonb_agg(roca_lien_json(l) order by (l.status in ('satisfied', 'released')), roca_unit_sort(l.unit_number), l.recorded_on desc nulls last) from roca_liens l), '[]'::jsonb),
    'settings', (select jsonb_object_agg(key, value) from portal_settings where key in ('roca_lien_threshold', 'roca_foreclosure_threshold', 'roca_lien_refile_months')),
    'units', coalesce((select jsonb_agg(jsonb_build_object('unit', u, 'balance', roca_unit_balance(u), 'fee_balance', roca_unit_fee_balance(u), 'has_lien', roca_unit_has_lien(u))) from roca_units() u), '[]'::jsonb));
end;
$$;
revoke all on function roca_liens_staff() from public, anon;
grant execute on function roca_liens_staff() to authenticated;

-- Staff record the Register of Deeds filing: document number, date, and the recording cost (charged to the owner, Rules §4/§10).
create or replace function roca_lien_record(p_id uuid, p_rod text, p_recorded_on date, p_amount numeric, p_cost numeric)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare l roca_liens; v_e bigint; v_months int := coalesce((select value from portal_settings where key = 'roca_lien_refile_months'), '23')::int;
begin
  perform roca_staff_check();
  if length(coalesce(trim(p_rod), '')) < 3 or p_recorded_on is null then raise exception 'Enter the Register of Deeds document number and the date recorded.'; end if;
  select * into l from roca_liens where id = p_id for update;
  if l.status <> 'approved' then raise exception 'Only an approved lien can be recorded.'; end if;
  if coalesce(p_cost, 0) > 0 then
    v_e := roca_post_charge(l.unit_number, 'Legal', p_recorded_on, p_cost, 'Lien recording cost', 'Statement of Condominium Lien recorded, doc ' || trim(p_rod), 'staff', lower(auth.email()),
      'Recording/filing cost charged to the owner (Rules & Regulations §4, §10).');
  end if;
  update roca_liens set status = 'recorded', rod_document = trim(p_rod), recorded_on = p_recorded_on, amount_claimed = coalesce(p_amount, amount_claimed),
    refile_due = (p_recorded_on + (v_months || ' months')::interval)::date, filing_cost = nullif(p_cost, 0), filing_cost_entry_id = v_e, updated_at = now()
   where id = p_id returning * into l;
  insert into condo_collection_steps (unit_id, account_id, step, step_date, amount, note, entered_by)
  values ((select id from condo_units where unit_number = l.unit_number), l.account_id, 'lien', p_recorded_on, l.amount_claimed, 'Statement of Condominium Lien recorded, doc ' || l.rod_document, lower(auth.email()));
  perform roca_email_owner(l.unit_number, 'Statement of Condominium Lien recorded — Unit ' || l.unit_number,
    '<p>ROCA1 recorded a Statement of Condominium Lien against Unit ' || l.unit_number || ' with the Milwaukee County Register of Deeds on '
    || to_char(p_recorded_on, 'FMMonth FMDD, YYYY') || ' (document ' || repair_esc(l.rod_document) || ') for ' || roca_money(l.amount_claimed) || '.</p>'
    || '<p>While the lien is recorded the unit is a Class B member (Action of 1/16/2025, F) and may not vote. The lien is satisfied of record once the balance is paid in full.</p>', 'roca_lien');
  return roca_lien_json(l);
end;
$$;
revoke all on function roca_lien_record(uuid, text, date, numeric, numeric) from public, anon;
grant execute on function roca_lien_record(uuid, text, date, numeric, numeric) to authenticated;

-- Staff record the recorded Satisfaction of Lien.
create or replace function roca_lien_satisfy(p_id uuid, p_doc text, p_date date)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare l roca_liens;
begin
  perform roca_staff_check();
  if length(coalesce(trim(p_doc), '')) < 3 or p_date is null then raise exception 'Enter the satisfaction document number and date.'; end if;
  update roca_liens set status = 'satisfied', satisfaction_document = trim(p_doc), satisfied_on = p_date, updated_at = now()
   where id = p_id and status = 'satisfaction_approved' returning * into l;
  if l.id is null then raise exception 'Only a lien whose satisfaction was approved by resolution can be marked satisfied.'; end if;
  insert into condo_collection_steps (unit_id, account_id, step, step_date, note, entered_by)
  values ((select id from condo_units where unit_number = l.unit_number), l.account_id, 'resolved', p_date, 'Satisfaction of lien recorded, doc ' || l.satisfaction_document, lower(auth.email()));
  perform roca_email_owner(l.unit_number, 'Lien satisfied — Unit ' || l.unit_number,
    '<p>ROCA1 recorded a Satisfaction of Lien for Unit ' || l.unit_number || ' on ' || to_char(p_date, 'FMMonth FMDD, YYYY') || ' (document ' || repair_esc(l.satisfaction_document) || '). Thank you.</p>', 'roca_lien');
  return roca_lien_json(l);
end;
$$;
revoke all on function roca_lien_satisfy(uuid, text, date) from public, anon;
grant execute on function roca_lien_satisfy(uuid, text, date) to authenticated;

create or replace function roca_lien_note(p_id uuid, p_note text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare l roca_liens;
begin
  perform roca_staff_check();
  update roca_liens set notes = concat_ws(E'\n', notes, to_char(now(), 'MM/DD/YYYY') || ' ' || lower(auth.email()) || ': ' || trim(p_note)), updated_at = now() where id = p_id returning * into l;
  return roca_lien_json(l);
end;
$$;
revoke all on function roca_lien_note(uuid, text) from public, anon;
grant execute on function roca_lien_note(uuid, text) to authenticated;

-- Staff: draft a lien filing / satisfaction / foreclosure resolution by hand.
create or replace function roca_lien_propose(p_kind text, p_units text[], p_note text)
returns uuid
language plpgsql volatile security definer set search_path = public as $$
declare v_units jsonb;
begin
  perform roca_staff_check();
  if p_kind not in ('lien_filing', 'lien_satisfaction', 'foreclosure') then raise exception 'Choose filing, satisfaction or foreclosure.'; end if;
  if coalesce(array_length(p_units, 1), 0) = 0 then raise exception 'Choose at least one unit.'; end if;
  select jsonb_agg(jsonb_build_object('unit', u, 'amount', roca_unit_balance(u), 'fee_balance', roca_unit_fee_balance(u))) into v_units from unnest(p_units) u;
  return roca_resolution_propose(p_kind,
    case p_kind when 'lien_filing' then 'Record Statements of Condominium Lien' when 'lien_satisfaction' then 'Satisfy liens' else 'Pursue judgment of foreclosure' end
      || ': Unit ' || array_to_string(p_units, ', '),
    case p_kind when 'lien_filing' then 'RESOLVED, that ROCA1 record a Statement of Condominium Lien against: '
                when 'lien_satisfaction' then 'RESOLVED, that ROCA1 record a Satisfaction of Lien for: '
                else 'RESOLVED, that ROCA1 pursue a Judgment of Foreclosure against: ' end
      || (select string_agg('Unit ' || (x->>'unit') || ' (balance ' || roca_money((x->>'amount')::numeric) || ')', '; ') from jsonb_array_elements(v_units) x) || '.'
      || coalesce(' ' || nullif(trim(coalesce(p_note, '')), ''), ''),
    'members_consent', jsonb_build_object('units', v_units, 'as_of', current_date), 'manual', null, lower(auth.email()));
end;
$$;
revoke all on function roca_lien_propose(text, text[], text) from public, anon;
grant execute on function roca_lien_propose(text, text[], text) to authenticated;

create or replace function roca_automation_staff()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform roca_staff_check();
  return jsonb_build_object('mode', coalesce((select value from portal_settings where key = 'automation_mode'), 'off'),
    'runs', coalesce((select jsonb_agg(to_jsonb(r) order by r.created_at desc) from (select * from roca_automation_runs order by created_at desc limit 20) r), '[]'::jsonb),
    'settings', (select jsonb_object_agg(key, value) from portal_settings where key like 'roca\_%'));
end;
$$;
revoke all on function roca_automation_staff() from public, anon;
grant execute on function roca_automation_staff() to authenticated;

-- ---------------------------------------------------------------------------
-- Owner portal: the special assessments and liens on the owner's current units, and the current budget.
create or replace function roca_my_assessments_liens()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_owner uuid := condo_owner_for_email(auth.email()); v_units text[];
begin
  if not condo_session_ok() or v_owner is null then raise exception 'Sign-in required' using errcode = '42501'; end if;
  v_units := array(select u.unit_number from condo_ownerships s join condo_units u on u.id = s.unit_id where s.owner_id = v_owner and s.is_current);
  return jsonb_build_object('units', to_jsonb(v_units),
    'assessments', coalesce((select jsonb_agg(jsonb_build_object('unit', c.unit_number, 'title', a.title, 'reason', a.reason, 'number', r.number, 'installment', c.installment,
        'installments', a.installments, 'due_date', c.due_date, 'amount', c.amount, 'posted', c.ledger_entry_id is not null) order by c.due_date, c.unit_number)
      from roca_assessment_charges c join roca_assessments a on a.id = c.assessment_id join roca_resolutions r on r.id = a.resolution_id
      where c.unit_number = any(v_units) and a.status <> 'cancelled'), '[]'::jsonb),
    'liens', coalesce((select jsonb_agg(jsonb_build_object('unit', l.unit_number, 'status', l.status, 'rod_document', l.rod_document, 'recorded_on', l.recorded_on,
        'amount_claimed', l.amount_claimed, 'satisfaction_document', l.satisfaction_document, 'satisfied_on', l.satisfied_on, 'refile_due', l.refile_due)
        order by l.recorded_on desc nulls last) from roca_liens l where l.unit_number = any(v_units)), '[]'::jsonb),
    'budget', (select jsonb_build_object('fiscal_year', b.fiscal_year, 'status', b.status, 'monthly_dues', b.monthly_dues, 'totals', roca_budget_totals(b.id),
        'lines', (select jsonb_agg(jsonb_build_object('grp', l.grp, 'code', l.code, 'name', l.name, 'annual', l.annual) order by l.sort) from roca_budget_lines l where l.budget_id = b.id and l.grp <> 'INCOME'))
      from roca_budgets b where b.status in ('adopted', 'on_file') order by b.fiscal_year desc limit 1));
end;
$$;
revoke all on function roca_my_assessments_liens() from public, anon;
grant execute on function roca_my_assessments_liens() to authenticated;
