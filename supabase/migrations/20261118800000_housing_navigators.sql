-- Community Housing Partnership: Housing Navigators (Stephen, 11/11/2026).
--
-- A Housing Navigator is an outside person (first: a Milwaukee housing navigator who works with veterans, older adults on
-- fixed incomes and social workers) who brings people who need housing AND landlords who have housing. 2nd Chance
-- Housing Inc coordinates and approves, and pays the Navigator directly (independent contractor, W-9 first).
--
--   * navigators            the Navigator, the vetting checklist (meeting, agreement, W-9, insurance, confidentiality,
--                           state business status) and pilot limits. Sign-in only while status is pilot or active, with the
--                           emailed code AND an authenticator app (like staff; role 'navigator' in mfa_required_roles).
--   * nav_landlords         outside landlords (the housing network). Each is shared with every Navigator unless the
--                           Navigator who added it keeps it to herself (shared = false). No landlord login.
--   * nav_units             their units: rent, deposit, utilities, accessibility, vouchers, inspection, availability.
--   * nav_referrals         a person who needs housing, with their signed consent, income, assistance and the
--                           affordability gap (rent - what they can pay - confirmed assistance). Pipeline:
--                           draft -> submitted -> reviewing -> searching -> matched -> approved -> moved_in -> closed.
--                           The office accepts, approves the placement (gap check) and closes. The Navigator drafts,
--                           submits, matches a unit and records the move-in.
--   * nav_followups         30, 60, 90 days, 6 and 12 months after move-in.
--   * nav_pay_plan          what 2nd Chance pays the Navigator, per milestone (editable on the staff page).
--   * nav_earnings          each payment earned: earned -> approved (office) -> paid (office records how). No money moves here.
--   * nav_events            the audit trail and the case notes.
--
-- A Navigator sees ONLY her own referrals, the landlords she added plus the shared ones, her pay. Never other Navigators'
-- people, never staff-only notes. Staff (two-step sign-in) see everything on https://2ndchinc.org/staff/navigators/ .
-- The tenant never pays a Navigator anything.
-- Rows are reached only through the functions below; the tables have no policies.

-- ---------------------------------------------------------------- tables
create table if not exists navigators (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  email text not null,
  phone text,
  business_name text,
  dfi_entity_id text,
  dfi_status text,
  dfi_checked_on date,
  status text not null default 'prospect' check (status in ('prospect', 'pilot', 'active', 'paused', 'ended')),
  pilot_start date,
  pilot_end date,
  max_open_referrals int not null default 5 check (max_open_referrals between 0 and 500),
  chk_meeting date,
  chk_agreement date,
  chk_w9 date,
  chk_insurance date,
  chk_confidentiality date,
  chk_business_good_standing date,
  pay_method text,
  notes text,                       -- staff only
  invited_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create unique index if not exists navigators_email_idx on navigators (lower(email));
alter table navigators enable row level security;

create table if not exists nav_landlords (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  business_name text,
  email text,
  phone text,
  mailing_address text,
  accepts_vouchers boolean,
  accepts_assistance boolean,
  requirements text,                -- the landlord's own tenant requirements
  agreement_status text not null default 'none' check (agreement_status in ('none', 'talking', 'sent', 'signed')),
  agreement_on date,
  status text not null default 'prospect' check (status in ('prospect', 'active', 'paused', 'ended')),
  shared boolean not null default true,
  added_by_navigator uuid references navigators(id) on delete set null,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table nav_landlords enable row level security;

create table if not exists nav_units (
  id uuid primary key default gen_random_uuid(),
  landlord_id uuid not null references nav_landlords(id) on delete cascade,
  address text not null,
  unit_label text,
  city text not null default 'Milwaukee',
  zip text,
  bedrooms numeric(3,1),
  bathrooms numeric(3,1),
  rent numeric(10,2),
  deposit numeric(10,2),
  application_fee numeric(10,2),
  utilities_included text,
  accessibility text,
  ground_floor boolean,
  accepts_vouchers boolean,
  pets text,
  inspection_status text not null default 'not_inspected' check (inspection_status in ('not_inspected', 'scheduled', 'passed', 'failed')),
  inspected_on date,
  status text not null default 'available' check (status in ('available', 'reserved', 'occupied', 'maintenance', 'off_market')),
  available_on date,
  notes text,
  added_by_navigator uuid references navigators(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists nav_units_landlord_idx on nav_units (landlord_id);
alter table nav_units enable row level security;

create table if not exists nav_referrals (
  id uuid primary key default gen_random_uuid(),
  ref_no bigint generated always as identity,
  navigator_id uuid references navigators(id) on delete restrict,
  first_name text not null,
  last_name text,
  phone text,
  email text,
  reach_note text,                  -- where or how to reach them (shelter, a relative's phone ...)
  pathway text not null default 'other' check (pathway in ('veteran', 'senior', 'benefits', 'returning_citizen', 'family', 'other')),
  housing_situation text check (housing_situation in ('street', 'shelter', 'transitional', 'doubled_up', 'at_risk', 'seeking_independent', 'other')),
  veteran boolean,
  household_size int check (household_size between 1 and 20),
  bedrooms_needed numeric(3,1),
  income_monthly numeric(10,2),
  income_sources text[] not null default '{}',
  income_verified_on date,
  contribution_monthly numeric(10,2),   -- what the person can pay toward rent each month
  assistance_monthly numeric(10,2),
  assistance_source text,
  assistance_confirmed boolean not null default false,
  move_in_by date,
  areas text,
  accessibility_needs text,
  accommodation_request text,
  support_name text,
  support_agency text,
  support_phone text,
  support_email text,
  consent_name text,
  consent_on date,
  consent_version text,
  consent_withdrawn_on date,
  status text not null default 'draft' check (status in ('draft', 'submitted', 'reviewing', 'searching', 'matched', 'approved', 'moved_in', 'closed')),
  close_reason text check (close_reason in ('housed_elsewhere', 'not_eligible', 'no_contact', 'declined', 'left_housing', 'consent_withdrawn', 'duplicate', 'other')),
  nav_unit_id uuid references nav_units(id) on delete set null,
  rental_unit_id uuid references rental_units(id) on delete set null,
  unit_rent numeric(10,2),
  move_in_on date,
  gap_override_note text,
  staff_notes text,                 -- staff only
  submitted_at timestamptz,
  accepted_at timestamptz,
  matched_at timestamptz,
  approved_at timestamptz,
  approved_by text,
  moved_in_at timestamptz,
  closed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists nav_referrals_nav_idx on nav_referrals (navigator_id, status);
alter table nav_referrals enable row level security;

create table if not exists nav_followups (
  id uuid primary key default gen_random_uuid(),
  referral_id uuid not null references nav_referrals(id) on delete cascade,
  mark text not null check (mark in ('d30', 'd60', 'd90', 'm6', 'm12')),
  due_on date not null,
  done_on date,
  outcome text check (outcome in ('stable', 'concern', 'at_risk', 'left', 'unreachable')),
  rent_current boolean,
  note text,
  done_by text,
  reminded_at timestamptz,
  created_at timestamptz not null default now(),
  unique (referral_id, mark)
);
alter table nav_followups enable row level security;

create table if not exists nav_pay_plan (
  key text primary key check (key in ('intake', 'placement', 'retention_90', 'retention_365', 'landlord_first')),
  label text not null,
  amount numeric(10,2) not null default 0 check (amount >= 0),
  active boolean not null default true,
  description text,
  sort int not null default 0,
  updated_at timestamptz not null default now(),
  updated_by text
);
alter table nav_pay_plan enable row level security;

-- The starting proposal (Stephen: "build what you think; she can tweak it"). Paid by 2nd Chance Housing Inc for
-- housing-navigation SERVICES at milestones, never a commission charged to the person housed.
insert into nav_pay_plan (key, label, amount, active, description, sort) values
  ('intake', 'Intake accepted', 0, false, 'Complete intake with signed consent, accepted by the office. Off during the pilot so pay follows results.', 1),
  ('placement', 'Move-in', 250, true, 'The person moves into an approved unit. Includes the housing search, landlord contact, application help and move-in day.', 2),
  ('retention_90', 'Still housed at 90 days', 100, true, 'The 30, 60 and 90-day check-ins are done and the person is still housed.', 3),
  ('retention_365', 'Still housed at 12 months', 200, true, 'The 6 and 12-month check-ins are done and the person is still housed.', 4),
  ('landlord_first', 'New landlord, first placement', 100, true, 'A landlord the Navigator brought in houses its first person through the program.', 5)
on conflict (key) do nothing;

create table if not exists nav_earnings (
  id uuid primary key default gen_random_uuid(),
  navigator_id uuid not null references navigators(id) on delete restrict,
  referral_id uuid references nav_referrals(id) on delete set null,
  landlord_id uuid references nav_landlords(id) on delete set null,
  kind text not null,
  label text not null,
  amount numeric(10,2) not null check (amount >= 0),
  status text not null default 'earned' check (status in ('earned', 'approved', 'paid', 'void')),
  earned_on date not null default (now() at time zone 'America/Chicago')::date,
  approved_at timestamptz,
  approved_by text,
  paid_on date,
  paid_method text,
  paid_ref text,
  note text,
  created_at timestamptz not null default now()
);
create unique index if not exists nav_earnings_ref_kind_idx on nav_earnings (navigator_id, referral_id, kind) where referral_id is not null and status <> 'void';
create unique index if not exists nav_earnings_ll_kind_idx on nav_earnings (navigator_id, landlord_id, kind) where landlord_id is not null and status <> 'void';
alter table nav_earnings enable row level security;

create table if not exists nav_events (
  id bigint generated always as identity primary key,
  referral_id uuid references nav_referrals(id) on delete cascade,
  navigator_id uuid references navigators(id) on delete set null,
  landlord_id uuid references nav_landlords(id) on delete set null,
  unit_id uuid references nav_units(id) on delete set null,
  actor text,
  actor_role text,
  action text not null,
  private boolean not null default false,   -- staff-only notes
  detail text,
  created_at timestamptz not null default now()
);
create index if not exists nav_events_ref_idx on nav_events (referral_id, created_at);
alter table nav_events enable row level security;

-- Grants (new tables need them from 10/30/2026): edge functions only; the pages go through the functions below.
revoke all on navigators, nav_landlords, nav_units, nav_referrals, nav_followups, nav_pay_plan, nav_earnings, nav_events from anon, authenticated;
grant all on navigators, nav_landlords, nav_units, nav_referrals, nav_followups, nav_pay_plan, nav_earnings, nav_events to service_role;

insert into portal_settings (key, value) values
  ('session_idle_days_navigator', '14'),
  ('session_max_days_navigator', '30')
on conflict (key) do nothing;
update portal_settings set value = value || ',navigator'
 where key = 'mfa_required_roles' and not ('navigator' = any (string_to_array(replace(value, ' ', ''), ',')));

-- ---------------------------------------------------------------- who is signed in
create or replace function navigator_is_me() returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and exists (select 1 from navigators where status in ('pilot', 'active') and lower(email) = lower(auth.email()));
$$;

-- The signed-in Navigator's id, only with a full (two-step, fresh) session.
create or replace function nav_me() returns uuid
language sql stable security definer set search_path = public as $$
  select n.id from navigators n where condo_session_ok() and n.status in ('pilot', 'active') and lower(n.email) = lower(auth.email());
$$;

create or replace function nav_actor_role() returns text
language sql stable security definer set search_path = public as $$
  select case when staff_session_staff() then 'staff' when nav_me() is not null then 'navigator' else null end;
$$;

create or replace function nav_log(p_action text, p_detail text, p_referral uuid default null, p_navigator uuid default null,
                                   p_landlord uuid default null, p_unit uuid default null, p_private boolean default false) returns void
language sql security definer set search_path = public as $$
  insert into nav_events (referral_id, navigator_id, landlord_id, unit_id, actor, actor_role, action, private, detail)
  values (p_referral, coalesce(p_navigator, nav_me()), p_landlord, p_unit, lower(auth.email()), nav_actor_role(), p_action, p_private, p_detail);
$$;

create or replace function nav_email(p_to text, p_subject text, p_body text, p_kind text) returns void
language sql security definer set search_path = public as $$
  insert into email_outbox (to_email, subject, html, kind)
  select p_to, p_subject,
    '<div style="font-family:Arial,sans-serif;max-width:680px;color:#1b2430">' || p_body
    || '<p style="color:#667;font-size:12px">2nd Chance Housing Inc · Community Housing Partnership</p></div>', p_kind
  where coalesce(trim(p_to), '') <> '';
$$;

create or replace function nav_ref_label(r nav_referrals) returns text
language sql immutable as $$ select 'R-' || lpad(r.ref_no::text, 4, '0'); $$;

-- Can the signed-in person act on this referral? Staff: any. Navigator: her own.
create or replace function nav_can_ref(p_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select staff_session_staff() or exists (select 1 from nav_referrals r where r.id = p_id and r.navigator_id = nav_me());
$$;

create or replace function nav_can_see_landlord(p_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select staff_session_staff() or (nav_me() is not null and exists (select 1 from nav_landlords l where l.id = p_id and (l.shared or l.added_by_navigator = nav_me())));
$$;

create or replace function nav_can_edit_landlord(p_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select staff_session_staff() or (nav_me() is not null and exists (select 1 from nav_landlords l where l.id = p_id and l.added_by_navigator = nav_me()));
$$;

-- ---------------------------------------------------------------- shapes returned to the pages
create or replace function nav_unit_json(u nav_units) returns jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(u) - 'added_by_navigator' || jsonb_build_object('mine', u.added_by_navigator is not null and u.added_by_navigator = nav_me());
$$;

create or replace function nav_gap(r nav_referrals) returns numeric
language sql immutable as $$
  select case when r.unit_rent is null then null
              else round(r.unit_rent - coalesce(r.contribution_monthly, 0) - case when r.assistance_confirmed then coalesce(r.assistance_monthly, 0) else 0 end, 2) end;
$$;

create or replace function nav_referral_json(r nav_referrals, p_full boolean) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_staff boolean := staff_session_staff(); v jsonb; v_unit jsonb;
begin
  v := to_jsonb(r) - 'staff_notes' || jsonb_build_object('label', nav_ref_label(r), 'gap', nav_gap(r),
        'navigator', (select name from navigators where id = r.navigator_id));
  if v_staff then v := v || jsonb_build_object('staff_notes', r.staff_notes); end if;
  if r.nav_unit_id is not null then
    select jsonb_build_object('kind', 'network', 'id', u.id, 'address', u.address, 'unit_label', u.unit_label, 'rent', u.rent, 'deposit', u.deposit,
             'landlord', coalesce(l.business_name, l.name), 'landlord_phone', l.phone, 'landlord_email', l.email)
      into v_unit from nav_units u join nav_landlords l on l.id = u.landlord_id where u.id = r.nav_unit_id;
  elsif r.rental_unit_id is not null then
    select jsonb_build_object('kind', '2nd Chance', 'id', ru.id, 'address', ru.address, 'unit_label', ru.unit_number, 'rent', r.unit_rent,
             'landlord', '2nd Chance Housing')
      into v_unit from rental_units ru where ru.id = r.rental_unit_id;
  end if;
  v := v || jsonb_build_object('unit', v_unit);
  if p_full then
    v := v || jsonb_build_object(
      'events', coalesce((select jsonb_agg(jsonb_build_object('at', e.created_at, 'who', e.actor_role, 'action', e.action, 'detail', e.detail, 'private', e.private) order by e.created_at desc)
                 from nav_events e where e.referral_id = r.id and (v_staff or not e.private)), '[]'::jsonb),
      'followups', coalesce((select jsonb_agg(to_jsonb(f) order by f.due_on) from nav_followups f where f.referral_id = r.id), '[]'::jsonb));
  end if;
  return v;
end;
$$;

-- ---------------------------------------------------------------- earnings
create or replace function nav_earn(p_nav uuid, p_kind text, p_referral uuid, p_landlord uuid, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare p nav_pay_plan;
begin
  if p_nav is null then return; end if;
  select * into p from nav_pay_plan where key = p_kind;
  if not found or not p.active or p.amount <= 0 then return; end if;
  insert into nav_earnings (navigator_id, referral_id, landlord_id, kind, label, amount, note)
  values (p_nav, p_referral, p_landlord, p_kind, p.label, p.amount, p_note)
  on conflict do nothing;
end;
$$;

-- ---------------------------------------------------------------- Navigator home (and the staff view of one Navigator)
create or replace function nav_home() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_me uuid := nav_me(); n navigators; v_today date := (now() at time zone 'America/Chicago')::date;
begin
  if v_me is null then raise exception 'Navigator two-step sign-in required' using errcode = '42501'; end if;
  select * into n from navigators where id = v_me;
  return jsonb_build_object(
    'me', jsonb_build_object('name', n.name, 'status', n.status, 'pilot_start', n.pilot_start, 'pilot_end', n.pilot_end,
            'max_open_referrals', n.max_open_referrals, 'w9_on_file', n.chk_w9 is not null, 'agreement_signed', n.chk_agreement is not null),
    'open_referrals', (select count(*) from nav_referrals where navigator_id = v_me and status not in ('closed')),
    'referrals', coalesce((select jsonb_agg(nav_referral_json(r, false) order by r.updated_at desc) from nav_referrals r where r.navigator_id = v_me), '[]'::jsonb),
    'followups_due', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'referral_id', r.id, 'label', nav_ref_label(r), 'name', r.first_name || coalesce(' ' || r.last_name, ''),
                         'mark', f.mark, 'due_on', f.due_on, 'overdue', f.due_on < v_today) order by f.due_on)
                       from nav_followups f join nav_referrals r on r.id = f.referral_id
                      where r.navigator_id = v_me and f.done_on is null and f.due_on <= v_today + 7 and r.status = 'moved_in'), '[]'::jsonb),
    'plan', coalesce((select jsonb_agg(to_jsonb(p) - 'updated_by' order by p.sort) from nav_pay_plan p), '[]'::jsonb),
    'earnings', coalesce((select jsonb_agg(jsonb_build_object('id', e.id, 'label', e.label, 'amount', e.amount, 'status', e.status, 'earned_on', e.earned_on,
                         'paid_on', e.paid_on, 'paid_method', e.paid_method, 'paid_ref', e.paid_ref,
                         'referral', (select nav_ref_label(r) from nav_referrals r where r.id = e.referral_id),
                         'landlord', (select coalesce(l.business_name, l.name) from nav_landlords l where l.id = e.landlord_id)) order by e.created_at desc)
                  from nav_earnings e where e.navigator_id = v_me and e.status <> 'void'), '[]'::jsonb),
    'paid_this_year', (select coalesce(sum(amount), 0) from nav_earnings where navigator_id = v_me and status = 'paid'
                         and extract(year from paid_on) = extract(year from v_today)),
    'consent_text', nav_consent_text()
  );
end;
$$;

create or replace function nav_consent_text() returns text
language sql immutable as $$
  select 'I agree that 2nd Chance Housing Inc and my Housing Navigator may collect the information on this form and share it with each other, '
      || 'with my support worker named here, and with the landlords I choose to apply to, only to help me find and keep a home. '
      || 'Landlords see only what my rental application needs, never my case notes. '
      || 'I can stop this sharing at any time by telling my Navigator or the office (info@2ndchinc.org). '
      || 'I do not pay my Navigator or 2nd Chance Housing anything for this help.';
$$;

-- ---------------------------------------------------------------- referrals
create or replace function nav_referral_get(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r nav_referrals;
begin
  if not nav_can_ref(p_id) then raise exception 'Not found.' using errcode = '42501'; end if;
  select * into r from nav_referrals where id = p_id;
  return nav_referral_json(r, true);
end;
$$;

-- Create or update a referral's details (never its status). p: a JSON object of the fields on the form.
create or replace function nav_referral_save(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_role text := nav_actor_role(); v_me uuid := nav_me(); v_id uuid := nullif(p->>'id', '')::uuid; r nav_referrals; n navigators;
  t text;
begin
  if v_role is null then raise exception 'Two-step sign-in required' using errcode = '42501'; end if;
  if length(trim(coalesce(p->>'first_name', ''))) < 1 then raise exception 'Enter the person''s first name.'; end if;
  if v_id is null then
    if v_role = 'navigator' then
      select * into n from navigators where id = v_me;
      if (select count(*) from nav_referrals where navigator_id = v_me and status <> 'closed') >= n.max_open_referrals then
        raise exception 'You have % open referrals, the most allowed right now. Close one or ask the office to raise the limit.', n.max_open_referrals;
      end if;
    end if;
    insert into nav_referrals (navigator_id, first_name) values (case when v_role = 'navigator' then v_me else nullif(p->>'navigator_id', '')::uuid end, trim(p->>'first_name'))
      returning id into v_id;
    perform nav_log('created', null, v_id);
  else
    if not nav_can_ref(v_id) then raise exception 'Not found.' using errcode = '42501'; end if;
    select * into r from nav_referrals where id = v_id;
    if r.status = 'closed' and v_role <> 'staff' then raise exception 'This referral is closed. Ask the office to reopen it.'; end if;
  end if;

  update nav_referrals set
    first_name = trim(p->>'first_name'),
    last_name = nullif(trim(coalesce(p->>'last_name', '')), ''),
    phone = nullif(trim(coalesce(p->>'phone', '')), ''),
    email = nullif(lower(trim(coalesce(p->>'email', ''))), ''),
    reach_note = nullif(trim(coalesce(p->>'reach_note', '')), ''),
    pathway = coalesce(nullif(p->>'pathway', ''), 'other'),
    housing_situation = nullif(p->>'housing_situation', ''),
    veteran = case when p ? 'veteran' and p->>'veteran' in ('true', 'false') then (p->>'veteran')::boolean else null end,
    household_size = nullif(p->>'household_size', '')::int,
    bedrooms_needed = nullif(p->>'bedrooms_needed', '')::numeric,
    income_monthly = nullif(p->>'income_monthly', '')::numeric,
    income_sources = coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p->'income_sources', '[]'::jsonb)) x
                                 where x in ('ss', 'ssi', 'ssdi', 'va', 'pension', 'employment', 'child_support', 'other')), '{}'),
    income_verified_on = case when v_role = 'staff' then nullif(p->>'income_verified_on', '')::date else income_verified_on end,
    contribution_monthly = nullif(p->>'contribution_monthly', '')::numeric,
    assistance_monthly = nullif(p->>'assistance_monthly', '')::numeric,
    assistance_source = nullif(trim(coalesce(p->>'assistance_source', '')), ''),
    assistance_confirmed = coalesce((p->>'assistance_confirmed')::boolean, false),
    move_in_by = nullif(p->>'move_in_by', '')::date,
    areas = nullif(trim(coalesce(p->>'areas', '')), ''),
    accessibility_needs = nullif(trim(coalesce(p->>'accessibility_needs', '')), ''),
    accommodation_request = nullif(trim(coalesce(p->>'accommodation_request', '')), ''),
    support_name = nullif(trim(coalesce(p->>'support_name', '')), ''),
    support_agency = nullif(trim(coalesce(p->>'support_agency', '')), ''),
    support_phone = nullif(trim(coalesce(p->>'support_phone', '')), ''),
    support_email = nullif(lower(trim(coalesce(p->>'support_email', ''))), ''),
    staff_notes = case when v_role = 'staff' and p ? 'staff_notes' then nullif(trim(coalesce(p->>'staff_notes', '')), '') else staff_notes end,
    navigator_id = case when v_role = 'staff' and p ? 'navigator_id' then nullif(p->>'navigator_id', '')::uuid else navigator_id end,
    updated_at = now()
  where id = v_id;

  -- Consent: the person types their own full name on the Navigator's screen. Recorded once with the date and text version.
  t := trim(coalesce(p->>'consent_name', ''));
  if t <> '' then
    update nav_referrals set consent_name = t, consent_on = (now() at time zone 'America/Chicago')::date, consent_version = 'nav-consent-2026-11', consent_withdrawn_on = null
     where id = v_id and (consent_name is distinct from t or consent_on is null);
    if found then perform nav_log('consent_signed', 'Consent signed by ' || t, v_id); end if;
  end if;
  if v_id = nullif(p->>'id', '')::uuid then perform nav_log('updated', null, v_id); end if;
  return v_id;
end;
$$;

create or replace function nav_referral_withdraw_consent(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not nav_can_ref(p_id) then raise exception 'Not found.' using errcode = '42501'; end if;
  update nav_referrals set consent_withdrawn_on = (now() at time zone 'America/Chicago')::date, status = 'closed', close_reason = 'consent_withdrawn',
         closed_at = now(), updated_at = now() where id = p_id;
  update nav_units u set status = 'available', updated_at = now() from nav_referrals r
   where r.id = p_id and u.id = r.nav_unit_id and u.status = 'reserved';
  perform nav_log('consent_withdrawn', 'The person withdrew consent. Referral closed; no more sharing.', p_id);
  perform nav_email('info@2ndchinc.org', 'Housing Navigator: consent withdrawn', '<p>Consent was withdrawn on referral ' ||
    (select nav_ref_label(r) from nav_referrals r where r.id = p_id) || '. The referral is closed. Stop sharing this person''s information.</p>'
    || '<p>https://2ndchinc.org/staff/navigators/</p>', 'nav_office');
end;
$$;

create or replace function nav_note(p_id uuid, p_text text, p_private boolean default false) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not nav_can_ref(p_id) then raise exception 'Not found.' using errcode = '42501'; end if;
  if length(trim(coalesce(p_text, ''))) < 2 then raise exception 'Write the note first.'; end if;
  perform nav_log('note', left(trim(p_text), 4000), p_id, null, null, null, coalesce(p_private, false) and staff_session_staff());
  update nav_referrals set updated_at = now() where id = p_id;
end;
$$;

-- Every status move goes through here. Who may do which step:
--   Navigator: draft -> submitted; searching -> matched (pick a unit); matched -> searching (unmatch); approved -> moved_in.
--   Office:    any of the above, plus submitted -> reviewing / searching (accept), reviewing -> searching,
--              matched -> approved (placement approval, gap check), any -> closed, closed -> searching (reopen).
create or replace function nav_referral_step(p_id uuid, p_to text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_role text := nav_actor_role(); r nav_referrals; u nav_units; l nav_landlords; v_gap numeric; v_note text := nullif(trim(coalesce(p->>'note', '')), '');
  v_date date; v_ok boolean := false; v_label text; v_who text;
begin
  if v_role is null or not nav_can_ref(p_id) then raise exception 'Not found.' using errcode = '42501'; end if;
  select * into r from nav_referrals where id = p_id for update;
  v_label := nav_ref_label(r);
  v_who := r.first_name || coalesce(' ' || left(r.last_name, 1) || '.', '');

  if p_to = 'submitted' and r.status = 'draft' then
    if r.consent_on is null or r.consent_name is null then raise exception 'The person must sign the consent (type their full name) before you submit.'; end if;
    if r.phone is null and r.email is null and r.reach_note is null then raise exception 'Add a phone, an email or how to reach the person.'; end if;
    update nav_referrals set status = 'submitted', submitted_at = now(), updated_at = now() where id = p_id;
    perform nav_email('info@2ndchinc.org', 'Housing Navigator: new referral ' || v_label,
      '<p>' || repair_esc(coalesce((select name from navigators where id = r.navigator_id), 'A Navigator')) || ' submitted referral <b>' || v_label || '</b> ('
      || repair_esc(r.pathway) || '). Review it at https://2ndchinc.org/staff/navigators/</p>', 'nav_office');
    v_ok := true;

  elsif p_to in ('reviewing', 'searching') and v_role = 'staff' and r.status in ('submitted', 'reviewing', 'closed') then
    if r.status = 'closed' and r.moved_in_at is not null then raise exception 'This person was already housed through this referral. Start a new referral for a new housing search.'; end if;
    update nav_referrals set status = p_to, accepted_at = coalesce(accepted_at, case when p_to = 'searching' then now() end),
           close_reason = null, closed_at = null, updated_at = now() where id = p_id;
    if p_to = 'searching' and r.accepted_at is null then perform nav_earn(r.navigator_id, 'intake', p_id, null, v_label); end if;
    perform nav_email((select email from navigators where id = r.navigator_id), 'Referral ' || v_label || ': ' || case when p_to = 'searching' then 'accepted, start the housing search' else 'under review' end,
      '<p>Referral <b>' || v_label || '</b> (' || repair_esc(v_who) || ') is now <b>' || case when p_to = 'searching' then 'accepted: search for housing' else 'under review by the office' end || '</b>.'
      || coalesce('<br>Note from the office: ' || repair_esc(v_note), '') || '</p><p>https://2ndchinc.org/navigator/</p>', 'nav_navigator');
    v_ok := true;

  elsif p_to = 'matched' and r.status = 'searching' then
    if nullif(p->>'nav_unit_id', '') is not null then
      select * into u from nav_units where id = (p->>'nav_unit_id')::uuid for update;
      if not found or not nav_can_see_landlord(u.landlord_id) then raise exception 'Unit not found.'; end if;
      if u.status not in ('available') then raise exception 'That unit is not available (it is %).', u.status; end if;
      update nav_units set status = 'reserved', updated_at = now() where id = u.id;
      update nav_referrals set status = 'matched', nav_unit_id = u.id, rental_unit_id = null, unit_rent = u.rent, matched_at = now(), updated_at = now() where id = p_id;
      v_note := coalesce(v_note || ' · ', '') || u.address || coalesce(' ' || u.unit_label, '');
    elsif nullif(p->>'rental_unit_id', '') is not null and v_role = 'staff' then
      if nullif(p->>'rent', '') is null then raise exception 'Enter the monthly rent for this unit.'; end if;
      update nav_referrals set status = 'matched', rental_unit_id = (p->>'rental_unit_id')::uuid, nav_unit_id = null, unit_rent = (p->>'rent')::numeric,
             matched_at = now(), updated_at = now() where id = p_id;
    else raise exception 'Pick a unit.';
    end if;
    select * into r from nav_referrals where id = p_id;
    perform nav_email('info@2ndchinc.org', 'Housing Navigator: ' || v_label || ' matched, needs placement approval',
      '<p>Referral <b>' || v_label || '</b> was matched to a unit. Rent ' || to_char(r.unit_rent, 'FM$999,990.00') || ', affordability gap '
      || coalesce(to_char(nav_gap(r), 'FM$999,990.00'), 'unknown') || '. Approve or send back at https://2ndchinc.org/staff/navigators/</p>', 'nav_office');
    v_ok := true;

  elsif p_to = 'searching' and r.status in ('matched', 'approved') then
    update nav_units set status = 'available', updated_at = now() where id = r.nav_unit_id and status = 'reserved';
    update nav_referrals set status = 'searching', nav_unit_id = null, rental_unit_id = null, unit_rent = null, matched_at = null,
           approved_at = null, approved_by = null, updated_at = now() where id = p_id;
    v_note := coalesce(v_note, 'Unit released; back to searching');
    v_ok := true;

  elsif p_to = 'approved' and v_role = 'staff' and r.status = 'matched' then
    v_gap := nav_gap(r);
    if v_gap is null then raise exception 'No rent on the matched unit.'; end if;
    if v_gap > 0 and v_note is null then
      raise exception 'The person is short % a month (rent minus what they can pay minus confirmed assistance). Write how the gap is covered to approve anyway.', to_char(v_gap, 'FM$999,990.00');
    end if;
    if r.income_verified_on is null and v_note is null then raise exception 'Income is not marked verified. Verify it (Edit, Income verified on) or write why you approve anyway.'; end if;
    update nav_referrals set status = 'approved', approved_at = now(), approved_by = lower(auth.email()), gap_override_note = case when v_gap > 0 then v_note end, updated_at = now() where id = p_id;
    perform nav_email((select email from navigators where id = r.navigator_id), 'Referral ' || v_label || ': placement approved',
      '<p>The office approved the placement for <b>' || v_label || '</b> (' || repair_esc(v_who) || '). When the person moves in, record the move-in date on the portal.</p><p>https://2ndchinc.org/navigator/</p>', 'nav_navigator');
    v_ok := true;

  elsif p_to = 'moved_in' and r.status = 'approved' then
    v_date := coalesce(nullif(p->>'move_in_on', '')::date, (now() at time zone 'America/Chicago')::date);
    if v_date > (now() at time zone 'America/Chicago')::date + 1 then raise exception 'Record the move-in on or after the day it happens.'; end if;
    update nav_referrals set status = 'moved_in', move_in_on = v_date, moved_in_at = now(), updated_at = now() where id = p_id;
    update nav_units set status = 'occupied', updated_at = now() where id = r.nav_unit_id;
    insert into nav_followups (referral_id, mark, due_on) values
      (p_id, 'd30', v_date + 30), (p_id, 'd60', v_date + 60), (p_id, 'd90', v_date + 90), (p_id, 'm6', (v_date + interval '6 months')::date), (p_id, 'm12', (v_date + interval '12 months')::date)
      on conflict do nothing;
    perform nav_earn(r.navigator_id, 'placement', p_id, null, v_label);
    if r.nav_unit_id is not null then
      select ll.* into l from nav_units uu join nav_landlords ll on ll.id = uu.landlord_id where uu.id = r.nav_unit_id;
      if l.added_by_navigator = r.navigator_id and not exists (select 1 from nav_referrals x join nav_units xu on xu.id = x.nav_unit_id
            where xu.landlord_id = l.id and x.id <> p_id and x.moved_in_at is not null) then
        perform nav_earn(r.navigator_id, 'landlord_first', null, l.id, coalesce(l.business_name, l.name));
      end if;
    end if;
    perform nav_email('info@2ndchinc.org', 'Housing Navigator: ' || v_label || ' moved in',
      '<p>Referral <b>' || v_label || '</b> moved in on ' || to_char(v_date, 'FMMonth FMDD, YYYY') || '. Follow-ups are scheduled; any pay earned waits for your approval at https://2ndchinc.org/staff/navigators/</p>', 'nav_office');
    v_note := coalesce(v_note || ' · ', '') || 'Moved in ' || to_char(v_date, 'MM/DD/YYYY');
    v_ok := true;

  elsif p_to = 'closed' and v_role = 'staff' and r.status <> 'closed' then
    if nullif(p->>'close_reason', '') is null then raise exception 'Pick why it is closing.'; end if;
    update nav_units set status = 'available', updated_at = now() where id = r.nav_unit_id and status = 'reserved';
    update nav_referrals set status = 'closed', close_reason = p->>'close_reason', closed_at = now(), updated_at = now() where id = p_id;
    perform nav_email((select email from navigators where id = r.navigator_id), 'Referral ' || v_label || ': closed',
      '<p>The office closed referral <b>' || v_label || '</b> (' || repair_esc(replace(p->>'close_reason', '_', ' ')) || ').' || coalesce('<br>Note: ' || repair_esc(v_note), '') || '</p>', 'nav_navigator');
    v_ok := true;
  end if;

  if not v_ok then raise exception 'That step is not allowed now (the referral is %).', replace(r.status, '_', ' '); end if;
  perform nav_log('status_' || p_to, v_note, p_id);
  return nav_referral_get(p_id);
end;
$$;

create or replace function nav_followup_save(p_id uuid, p_outcome text, p_rent_current boolean, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare f nav_followups; r nav_referrals;
begin
  select * into f from nav_followups where id = p_id;
  if not found or not nav_can_ref(f.referral_id) then raise exception 'Not found.' using errcode = '42501'; end if;
  if p_outcome not in ('stable', 'concern', 'at_risk', 'left', 'unreachable') then raise exception 'Pick how the person is doing.'; end if;
  if p_outcome in ('concern', 'at_risk', 'left', 'unreachable') and length(trim(coalesce(p_note, ''))) < 5 then raise exception 'Write a short note on what is happening.'; end if;
  update nav_followups set done_on = (now() at time zone 'America/Chicago')::date, outcome = p_outcome, rent_current = p_rent_current,
         note = nullif(trim(coalesce(p_note, '')), ''), done_by = lower(auth.email()) where id = p_id;
  select * into r from nav_referrals where id = f.referral_id;
  perform nav_log('followup_' || f.mark, p_outcome || coalesce(' · ' || trim(p_note), ''), r.id);
  -- Retention pay: every check-in up to the milestone is recorded and the milestone one says still housed (in any order;
  -- nav_earn never pays the same milestone twice).
  if r.status = 'moved_in' then
    if (select count(*) from nav_followups where referral_id = r.id and mark in ('d30', 'd60', 'd90') and done_on is not null) = 3
       and exists (select 1 from nav_followups where referral_id = r.id and mark = 'd90' and outcome in ('stable', 'concern')) then
      perform nav_earn(r.navigator_id, 'retention_90', r.id, null, nav_ref_label(r));
    end if;
    if (select count(*) from nav_followups where referral_id = r.id and mark in ('m6', 'm12') and done_on is not null) = 2
       and exists (select 1 from nav_followups where referral_id = r.id and mark = 'm12' and outcome in ('stable', 'concern')) then
      perform nav_earn(r.navigator_id, 'retention_365', r.id, null, nav_ref_label(r));
    end if;
  end if;
  if p_outcome in ('at_risk', 'left', 'unreachable') then
    perform nav_email('info@2ndchinc.org', 'Housing Navigator: ' || nav_ref_label(r) || ' check-in needs attention',
      '<p>The ' || replace(replace(replace(replace(replace(f.mark, 'd30', '30-day'), 'd60', '60-day'), 'd90', '90-day'), 'm6', '6-month'), 'm12', '12-month')
      || ' check-in for <b>' || nav_ref_label(r) || '</b> says: <b>' || replace(p_outcome, '_', ' ') || '</b>.<br>' || repair_esc(coalesce(p_note, ''))
      || '</p><p>https://2ndchinc.org/staff/navigators/</p>', 'nav_office');
  end if;
end;
$$;

-- ---------------------------------------------------------------- the housing network
create or replace function nav_network() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_staff boolean := staff_session_staff(); v_me uuid := nav_me();
begin
  if not v_staff and v_me is null then raise exception 'Two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(
      (to_jsonb(l) - 'notes' - 'added_by_navigator') || jsonb_build_object(
        'mine', l.added_by_navigator is not null and l.added_by_navigator = v_me,
        'added_by', case when v_staff then (select name from navigators where id = l.added_by_navigator) end,
        'notes', case when v_staff or l.added_by_navigator = v_me then l.notes end,
        'placements', (select count(*) from nav_referrals x join nav_units xu on xu.id = x.nav_unit_id where xu.landlord_id = l.id and x.moved_in_at is not null),
        'units', coalesce((select jsonb_agg(nav_unit_json(u) order by u.address, u.unit_label) from nav_units u where u.landlord_id = l.id), '[]'::jsonb))
      order by coalesce(l.business_name, l.name))
    from nav_landlords l where v_staff or l.shared or l.added_by_navigator = v_me), '[]'::jsonb);
end;
$$;

create or replace function nav_landlord_save(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_role text := nav_actor_role(); v_id uuid := nullif(p->>'id', '')::uuid;
begin
  if v_role is null then raise exception 'Two-step sign-in required' using errcode = '42501'; end if;
  if length(trim(coalesce(p->>'name', ''))) < 2 then raise exception 'Enter the landlord''s name.'; end if;
  if v_id is null then
    insert into nav_landlords (name, added_by_navigator) values (trim(p->>'name'), case when v_role = 'navigator' then nav_me() end) returning id into v_id;
    perform nav_log('landlord_added', trim(p->>'name'), null, null, v_id);
    if v_role = 'navigator' then
      perform nav_email('info@2ndchinc.org', 'Housing Navigator: new landlord added',
        '<p>' || repair_esc((select name from navigators where id = nav_me())) || ' added a landlord to the housing network: <b>' || repair_esc(trim(p->>'name')) || '</b>. See https://2ndchinc.org/staff/navigators/#network</p>', 'nav_office');
    end if;
  elsif not nav_can_edit_landlord(v_id) then
    raise exception 'Only the office or the Navigator who added this landlord can change it.' using errcode = '42501';
  end if;
  update nav_landlords set
    name = trim(p->>'name'),
    business_name = nullif(trim(coalesce(p->>'business_name', '')), ''),
    email = nullif(lower(trim(coalesce(p->>'email', ''))), ''),
    phone = nullif(trim(coalesce(p->>'phone', '')), ''),
    mailing_address = nullif(trim(coalesce(p->>'mailing_address', '')), ''),
    accepts_vouchers = case when p->>'accepts_vouchers' in ('true', 'false') then (p->>'accepts_vouchers')::boolean end,
    accepts_assistance = case when p->>'accepts_assistance' in ('true', 'false') then (p->>'accepts_assistance')::boolean end,
    requirements = nullif(trim(coalesce(p->>'requirements', '')), ''),
    agreement_status = case when v_role = 'staff' then coalesce(nullif(p->>'agreement_status', ''), agreement_status) else agreement_status end,
    agreement_on = case when v_role = 'staff' then nullif(p->>'agreement_on', '')::date else agreement_on end,
    status = case when v_role = 'staff' then coalesce(nullif(p->>'status', ''), status) else status end,
    shared = coalesce((p->>'shared')::boolean, shared),
    notes = nullif(trim(coalesce(p->>'notes', '')), ''),
    updated_at = now()
  where id = v_id;
  return v_id;
end;
$$;

create or replace function nav_unit_save(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_role text := nav_actor_role(); v_id uuid := nullif(p->>'id', '')::uuid; v_ll uuid := nullif(p->>'landlord_id', '')::uuid; v_old nav_units;
begin
  if v_role is null then raise exception 'Two-step sign-in required' using errcode = '42501'; end if;
  if v_id is not null then select * into v_old from nav_units where id = v_id; v_ll := v_old.landlord_id; end if;
  if v_ll is null or not nav_can_edit_landlord(v_ll) then raise exception 'Only the office or the Navigator who added this landlord can change its units.' using errcode = '42501'; end if;
  if length(trim(coalesce(p->>'address', ''))) < 4 then raise exception 'Enter the street address.'; end if;
  if v_id is null then
    insert into nav_units (landlord_id, address, added_by_navigator) values (v_ll, trim(p->>'address'), case when v_role = 'navigator' then nav_me() end) returning id into v_id;
    perform nav_log('unit_added', trim(p->>'address'), null, null, v_ll, v_id);
  end if;
  -- Reserved and occupied follow the referral steps; here only the free states can be chosen (the office may set any).
  if v_role <> 'staff' and v_old.status in ('reserved', 'occupied') and coalesce(p->>'status', v_old.status) <> v_old.status then
    raise exception 'This unit is % through a referral; it changes when that referral moves on.', v_old.status;
  end if;
  update nav_units set
    address = trim(p->>'address'),
    unit_label = nullif(trim(coalesce(p->>'unit_label', '')), ''),
    city = coalesce(nullif(trim(coalesce(p->>'city', '')), ''), 'Milwaukee'),
    zip = nullif(trim(coalesce(p->>'zip', '')), ''),
    bedrooms = nullif(p->>'bedrooms', '')::numeric,
    bathrooms = nullif(p->>'bathrooms', '')::numeric,
    rent = nullif(p->>'rent', '')::numeric,
    deposit = nullif(p->>'deposit', '')::numeric,
    application_fee = nullif(p->>'application_fee', '')::numeric,
    utilities_included = nullif(trim(coalesce(p->>'utilities_included', '')), ''),
    accessibility = nullif(trim(coalesce(p->>'accessibility', '')), ''),
    ground_floor = case when p->>'ground_floor' in ('true', 'false') then (p->>'ground_floor')::boolean end,
    accepts_vouchers = case when p->>'accepts_vouchers' in ('true', 'false') then (p->>'accepts_vouchers')::boolean end,
    pets = nullif(trim(coalesce(p->>'pets', '')), ''),
    inspection_status = case when v_role = 'staff' then coalesce(nullif(p->>'inspection_status', ''), inspection_status) else inspection_status end,
    inspected_on = case when v_role = 'staff' then nullif(p->>'inspected_on', '')::date else inspected_on end,
    status = case when v_role = 'staff' or coalesce(p->>'status', status) in ('available', 'maintenance', 'off_market') then coalesce(nullif(p->>'status', ''), status) else status end,
    available_on = nullif(p->>'available_on', '')::date,
    notes = nullif(trim(coalesce(p->>'notes', '')), ''),
    updated_at = now()
  where id = v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------- office (staff two-step sign-in)
create or replace function nav_staff_overview() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_today date := (now() at time zone 'America/Chicago')::date;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'navigators', coalesce((select jsonb_agg(to_jsonb(n) || jsonb_build_object(
        'open_referrals', (select count(*) from nav_referrals where navigator_id = n.id and status <> 'closed'),
        'placed', (select count(*) from nav_referrals where navigator_id = n.id and moved_in_at is not null),
        'owed', (select coalesce(sum(amount), 0) from nav_earnings where navigator_id = n.id and status in ('earned', 'approved')),
        'paid_this_year', (select coalesce(sum(amount), 0) from nav_earnings where navigator_id = n.id and status = 'paid' and extract(year from paid_on) = extract(year from v_today)))
      order by n.created_at) from navigators n), '[]'::jsonb),
    'referrals', coalesce((select jsonb_agg(nav_referral_json(r, false) order by r.updated_at desc) from nav_referrals r), '[]'::jsonb),
    'earnings', coalesce((select jsonb_agg(to_jsonb(e) || jsonb_build_object('navigator', n.name,
        'referral', (select nav_ref_label(r) from nav_referrals r where r.id = e.referral_id)) order by e.created_at desc)
      from nav_earnings e join navigators n on n.id = e.navigator_id), '[]'::jsonb),
    'plan', coalesce((select jsonb_agg(to_jsonb(p) order by p.sort) from nav_pay_plan p), '[]'::jsonb),
    'followups_due', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'referral_id', r.id, 'label', nav_ref_label(r), 'mark', f.mark, 'due_on', f.due_on,
                       'navigator', (select name from navigators where id = r.navigator_id)) order by f.due_on)
      from nav_followups f join nav_referrals r on r.id = f.referral_id where f.done_on is null and f.due_on <= v_today and r.status = 'moved_in'), '[]'::jsonb),
    'our_units', coalesce((select jsonb_agg(jsonb_build_object('id', ru.id, 'label', coalesce(ru.address, '') || coalesce(' Unit ' || ru.unit_number, '')) order by ru.unit_number)
      from rental_units ru), '[]'::jsonb),
    'stats', nav_stats()
  );
end;
$$;

-- The board numbers (staff page dashboard).
create or replace function nav_stats() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_today date := (now() at time zone 'America/Chicago')::date;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'referrals', (select count(*) from nav_referrals where status <> 'draft'),
    'open', (select count(*) from nav_referrals where status in ('submitted', 'reviewing', 'searching', 'matched', 'approved')),
    'placed', (select count(*) from nav_referrals where moved_in_at is not null),
    'avg_days_to_place', (select round(avg(move_in_on - (submitted_at at time zone 'America/Chicago')::date)) from nav_referrals where move_in_on is not null and submitted_at is not null),
    'by_pathway', coalesce((select jsonb_object_agg(pathway, c) from (select pathway, count(*) c from nav_referrals where status <> 'draft' group by pathway) s), '{}'::jsonb),
    'units_available', (select count(*) from nav_units where status = 'available'),
    'units_total', (select count(*) from nav_units where status <> 'off_market'),
    'units_occupied', (select count(*) from nav_units where status = 'occupied'),
    'landlords_active', (select count(*) from nav_landlords where status = 'active'),
    'landlords_total', (select count(*) from nav_landlords),
    'navigators_active', (select count(*) from navigators where status in ('pilot', 'active')),
    'retained_90', (select count(*) from nav_followups where mark = 'd90' and outcome in ('stable', 'concern')),
    'checked_90', (select count(*) from nav_followups where mark = 'd90' and done_on is not null),
    'retained_365', (select count(*) from nav_followups where mark = 'm12' and outcome in ('stable', 'concern')),
    'checked_365', (select count(*) from nav_followups where mark = 'm12' and done_on is not null),
    'followups_overdue', (select count(*) from nav_followups f join nav_referrals r on r.id = f.referral_id where f.done_on is null and f.due_on < v_today and r.status = 'moved_in'),
    'paid_this_year', (select coalesce(sum(amount), 0) from nav_earnings where status = 'paid' and extract(year from paid_on) = extract(year from v_today)),
    'owed', (select coalesce(sum(amount), 0) from nav_earnings where status in ('earned', 'approved'))
  );
end;
$$;

create or replace function nav_staff_navigator_save(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_email text := lower(trim(coalesce(p->>'email', '')));
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if length(trim(coalesce(p->>'name', ''))) < 2 then raise exception 'Enter the Navigator''s name.'; end if;
  if v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then raise exception 'Enter a valid email address.'; end if;
  if coalesce(p->>'status', 'prospect') in ('pilot', 'active') and (nullif(p->>'chk_agreement', '') is null or nullif(p->>'chk_confidentiality', '') is null) then
    raise exception 'Before a pilot or active status (which lets the Navigator sign in), record the signed partner agreement and the confidentiality agreement dates.';
  end if;
  if v_id is null then
    insert into navigators (name, email) values (trim(p->>'name'), v_email) returning id into v_id;
  end if;
  update navigators set
    name = trim(p->>'name'), email = v_email,
    phone = nullif(trim(coalesce(p->>'phone', '')), ''),
    business_name = nullif(trim(coalesce(p->>'business_name', '')), ''),
    dfi_entity_id = nullif(trim(coalesce(p->>'dfi_entity_id', '')), ''),
    dfi_status = nullif(trim(coalesce(p->>'dfi_status', '')), ''),
    dfi_checked_on = nullif(p->>'dfi_checked_on', '')::date,
    status = coalesce(nullif(p->>'status', ''), status),
    pilot_start = nullif(p->>'pilot_start', '')::date,
    pilot_end = nullif(p->>'pilot_end', '')::date,
    max_open_referrals = coalesce(nullif(p->>'max_open_referrals', '')::int, max_open_referrals),
    chk_meeting = nullif(p->>'chk_meeting', '')::date,
    chk_agreement = nullif(p->>'chk_agreement', '')::date,
    chk_w9 = nullif(p->>'chk_w9', '')::date,
    chk_insurance = nullif(p->>'chk_insurance', '')::date,
    chk_confidentiality = nullif(p->>'chk_confidentiality', '')::date,
    chk_business_good_standing = nullif(p->>'chk_business_good_standing', '')::date,
    pay_method = nullif(trim(coalesce(p->>'pay_method', '')), ''),
    notes = nullif(trim(coalesce(p->>'notes', '')), ''),
    updated_at = now()
  where id = v_id;
  perform nav_log('navigator_saved', trim(p->>'name') || ' · ' || coalesce(p->>'status', 'prospect'), null, v_id);
  return v_id;
end;
$$;

-- Emails the Navigator how to sign in. Only for pilot or active Navigators; the office presses the button.
create or replace function nav_staff_invite(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare n navigators;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into n from navigators where id = p_id;
  if not found then raise exception 'Navigator not found.'; end if;
  if n.status not in ('pilot', 'active') then raise exception 'Set the Navigator to Pilot or Active first.'; end if;
  perform nav_email(n.email, 'Your Housing Navigator sign-in at 2nd Chance Housing',
    '<p>Hello ' || repair_esc(split_part(n.name, ' ', 1)) || ',</p>'
    || '<p>Welcome to the 2nd Chance Housing Community Housing Partnership. Your Navigator portal is ready.</p>'
    || '<ol><li>Open <a href="https://2ndchinc.org/navigator/">https://2ndchinc.org/navigator/</a> on your phone or computer.</li>'
    || '<li>Type this email address (' || repair_esc(n.email) || ') and tap <b>Email me a code</b>. Enter the 6-digit code we email you.</li>'
    || '<li>The first time, the page asks you to set up an <b>authenticator app</b> (Google Authenticator, Microsoft Authenticator or Authy) for a second code. It takes about a minute. '
    || 'This keeps the people you help safe.</li></ol>'
    || '<p>In the portal you add the people you are helping (with their signed consent), the landlords and units you work with, record move-ins and check-ins, and see your pay.</p>'
    || '<p>Questions: reply to this email or write to info@2ndchinc.org.</p><p>2nd Chance Housing Inc</p>', 'nav_invite');
  update navigators set invited_at = now() where id = p_id;
  perform nav_log('navigator_invited', n.email, null, p_id);
end;
$$;

create or replace function nav_staff_plan_save(p_key text, p_amount numeric, p_active boolean, p_description text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if p_amount is null or p_amount < 0 or p_amount > 10000 then raise exception 'Enter an amount from $0 to $10,000.'; end if;
  update nav_pay_plan set amount = round(p_amount, 2), active = coalesce(p_active, active), description = coalesce(nullif(trim(coalesce(p_description, '')), ''), description),
         updated_at = now(), updated_by = lower(auth.email()) where key = p_key;
  if not found then raise exception 'Unknown pay item.'; end if;
  perform nav_log('pay_plan', p_key || ' ' || to_char(p_amount, 'FM$999,990.00') || case when p_active then ' on' else ' off' end);
end;
$$;

-- approve | pay | void | unapprove. Paying records how it was paid; no money moves through the site.
create or replace function nav_staff_earning(p_id uuid, p_action text, p_method text default null, p_ref text default null, p_paid_on date default null, p_note text default null) returns void
language plpgsql security definer set search_path = public as $$
declare e nav_earnings; n navigators;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into e from nav_earnings where id = p_id for update;
  if not found then raise exception 'Not found.'; end if;
  select * into n from navigators where id = e.navigator_id;
  if p_action = 'approve' and e.status = 'earned' then
    update nav_earnings set status = 'approved', approved_at = now(), approved_by = lower(auth.email()), note = coalesce(nullif(trim(coalesce(p_note, '')), ''), note) where id = p_id;
  elsif p_action = 'unapprove' and e.status = 'approved' then
    update nav_earnings set status = 'earned', approved_at = null, approved_by = null where id = p_id;
  elsif p_action = 'pay' and e.status = 'approved' then
    if n.chk_w9 is null then raise exception 'No W-9 on file for this Navigator. Record the W-9 date first (needed for the 1099).'; end if;
    if nullif(trim(coalesce(p_method, '')), '') is null then raise exception 'Say how it was paid (Zelle, check ...).'; end if;
    update nav_earnings set status = 'paid', paid_on = coalesce(p_paid_on, (now() at time zone 'America/Chicago')::date), paid_method = trim(p_method),
           paid_ref = nullif(trim(coalesce(p_ref, '')), '') where id = p_id;
    perform nav_email(n.email, 'Payment sent: ' || e.label || ' ' || to_char(e.amount, 'FM$999,990.00'),
      '<p>Hello ' || repair_esc(split_part(n.name, ' ', 1)) || ',</p><p>2nd Chance Housing Inc paid you <b>' || to_char(e.amount, 'FM$999,990.00') || '</b> for <b>' || repair_esc(e.label) || '</b>'
      || ' by ' || repair_esc(trim(p_method)) || '. Your pay history is on the Pay tab at https://2ndchinc.org/navigator/</p>', 'nav_paid');
  elsif p_action = 'void' and e.status in ('earned', 'approved') then
    if length(trim(coalesce(p_note, ''))) < 3 then raise exception 'Write why it is voided.'; end if;
    update nav_earnings set status = 'void', note = trim(p_note) where id = p_id;
  else
    raise exception 'That is not allowed now (it is %).', e.status;
  end if;
  perform nav_log('earning_' || p_action, e.label || ' ' || to_char(e.amount, 'FM$999,990.00') || coalesce(' · ' || p_method, ''), e.referral_id, e.navigator_id);
end;
$$;

-- ---------------------------------------------------------------- daily check-in reminders
-- Each check-in due today or overdue, not yet reminded: one email to its Navigator, one summary to the office.
create or replace function nav_followup_reminders() returns int
language plpgsql security definer set search_path = public as $$
declare v_today date := (now() at time zone 'America/Chicago')::date; x record; v_n int := 0; v_list text := '';
begin
  for x in
    select f.id, f.mark, f.due_on, r.id rid, nav_ref_label(r) label, n.email, n.name
      from nav_followups f join nav_referrals r on r.id = f.referral_id left join navigators n on n.id = r.navigator_id
     where f.done_on is null and f.reminded_at is null and f.due_on <= v_today and r.status = 'moved_in'
     order by f.due_on
  loop
    perform nav_email(x.email, 'Check-in due: ' || x.label,
      '<p>Hello ' || repair_esc(split_part(coalesce(x.name, ''), ' ', 1)) || ',</p><p>The ' || replace(replace(replace(replace(replace(x.mark, 'd30', '30-day'), 'd60', '60-day'), 'd90', '90-day'), 'm6', '6-month'), 'm12', '12-month')
      || ' check-in for <b>' || x.label || '</b> was due ' || to_char(x.due_on, 'FMMonth FMDD') || '. Visit or call, then record it at https://2ndchinc.org/navigator/</p>', 'nav_followup');
    v_list := v_list || '<li>' || x.label || ': ' || x.mark || ' due ' || to_char(x.due_on, 'MM/DD') || coalesce(' (' || repair_esc(x.name) || ')', '') || '</li>';
    update nav_followups set reminded_at = now() where id = x.id;
    v_n := v_n + 1;
  end loop;
  if v_n > 0 then
    perform nav_email('info@2ndchinc.org', 'Housing Navigator: ' || v_n || ' check-in' || case when v_n = 1 then '' else 's' end || ' due',
      '<ul>' || v_list || '</ul><p>https://2ndchinc.org/staff/navigators/</p>', 'nav_office');
  end if;
  return v_n;
end;
$$;

-- ---------------------------------------------------------------- sign-in: add the Navigator role everywhere roles are listed
create or replace function public.condo_email_on_file(p_email text) returns boolean
language sql stable security definer set search_path = public as $function$
  select condo_owner_for_email(p_email) is not null
      or exists (select 1 from condo_staff where lower(email) = lower(p_email))
      or exists (select 1 from lease_agents where active and lower(email) = lower(p_email))
      or exists (select 1 from resident_tenant_ids(p_email))
      or exists (select 1 from field_staff where active and lower(email) = lower(p_email))
      or exists (select 1 from contractor_vendor_ids(p_email))
      or exists (select 1 from investors where active and lower(email) = lower(p_email))
      or exists (select 1 from land_contract_sellers where active and lower(email) = lower(p_email))
      or exists (select 1 from caseworkers where active and lower(email) = lower(p_email))
      or exists (select 1 from unit_occupants where active and lower(email) = lower(p_email))
      or exists (select 1 from navigators where status in ('pilot', 'active') and lower(email) = lower(p_email));
$function$;

create or replace function public.mfa_required() returns boolean
language sql stable security definer set search_path = public as $function$
  with r as (select string_to_array(replace(coalesce((select value from portal_settings where key = 'mfa_required_roles'), ''), ' ', ''), ',') as roles)
  select auth.uid() is not null and exists (select 1 from r where
       ('staff' = any (r.roles) and exists (select 1 from condo_staff where lower(email) = lower(auth.email())))
    or ('field' = any (r.roles) and exists (select 1 from field_staff where active and lower(email) = lower(auth.email())))
    or ('agent' = any (r.roles) and exists (select 1 from lease_agents where active and lower(email) = lower(auth.email())))
    or ('owner' = any (r.roles) and condo_owner_for_email(auth.email()) is not null)
    or ('resident' = any (r.roles) and exists (select 1 from resident_tenant_ids(auth.email())))
    or ('contractor' = any (r.roles) and exists (select 1 from contractor_vendor_ids(auth.email())))
    or ('navigator' = any (r.roles) and exists (select 1 from navigators where status in ('pilot', 'active') and lower(email) = lower(auth.email()))));
$function$;

create or replace function public.session_role() returns text
language sql stable security definer set search_path = public as $function$
  select case when condo_is_staff() then 'staff' when condo_owner_for_email(auth.email()) is not null then 'owner'
              when exists (select 1 from lease_agents where active and lower(email) = lower(auth.email())) then 'agent'
              when exists (select 1 from resident_tenant_ids(auth.email())) then 'resident'
              when field_is_staff() then 'field' when exists (select 1 from contractor_vendor_ids(auth.email())) then 'contractor'
              when seller_is_me() then 'seller'
              when caseworker_is_me() then 'caseworker'
              when navigator_is_me() then 'navigator'
              when occupant_is_me() and not investor_is_me() then 'occupant'
              else 'investor' end;
$function$;

create or replace function public.condo_whoami() returns jsonb
language plpgsql stable security definer set search_path = public as $function$
declare
  v_owner uuid := condo_owner_for_email(auth.email());
  v_staff boolean := condo_is_staff();
  v_agent uuid := (select id from lease_agents where active and lower(email) = lower(auth.email()));
  v_resident boolean := exists (select 1 from resident_tenant_ids(auth.email()));
  v_field boolean := field_is_staff();
  v_contractor boolean := exists (select 1 from contractor_vendor_ids(auth.email()));
  v_investor boolean := investor_is_me();
  v_seller boolean := seller_is_me();
  v_caseworker boolean := caseworker_is_me();
  v_navigator boolean := navigator_is_me();
  v_occupant boolean := occupant_is_me();
  v_phone text;
  v_name text;
begin
  if auth.uid() is null then
    return jsonb_build_object('role', 'none');
  end if;
  if not session_fresh() then   -- this remembered device has expired: the page signs out and asks for a new code
    return jsonb_build_object('role', 'expired');
  end if;
  v_phone := condo_mfa_phone_for(auth.email());
  if not (v_staff or v_owner is not null or v_agent is not null or v_resident or v_field or v_contractor or v_investor or v_seller or v_caseworker or v_navigator or v_occupant) then
    return jsonb_build_object('role', 'none');
  end if;
  select case when o = 4 and n ~* '\m(inc|llc|ltd|corp|trust|association|company|housing)\M'
              then regexp_replace(trim(n), '[,.]?\s*(inc|llc|ltd|corp)\.?$', '', 'i')
              else split_part(trim(n), ' ', 1) end into v_name from (
    select name as n, 1 as o from condo_staff where lower(email) = lower(auth.email())
    union all select name, 2 from field_staff where active and lower(email) = lower(auth.email())
    union all select name, 3 from portal_admins where lower(email) = lower(auth.email())
    union all select name, 4 from condo_owners where id = v_owner
    union all select name, 5 from land_contract_sellers where active and lower(email) = lower(auth.email())
    union all select name, 6 from caseworkers where active and lower(email) = lower(auth.email())
    union all select name, 7 from unit_occupants where active and lower(email) = lower(auth.email())
    union all select name, 8 from navigators where status in ('pilot', 'active') and lower(email) = lower(auth.email())
  ) s where coalesce(trim(n), '') <> '' order by o limit 1;
  return jsonb_build_object(
    'role', case when v_staff then 'staff' when v_owner is not null then 'owner' when v_agent is not null then 'agent' when v_resident then 'resident'
                 when v_field then 'field' when v_contractor then 'contractor' when v_seller then 'seller' when v_caseworker then 'caseworker'
                 when v_navigator then 'navigator' when v_occupant and not v_investor then 'occupant' else 'investor' end,
    'is_owner', v_owner is not null,
    'is_agent', v_agent is not null,
    'is_resident', v_resident,
    'is_field', v_field,
    'is_contractor', v_contractor,
    'is_investor', v_investor,
    'is_seller', v_seller,
    'is_caseworker', v_caseworker,
    'is_navigator', v_navigator,
    'first_name', v_name,
    'mfa_required', mfa_required(),
    'verified', condo_session_ok(),
    'phone_hint', condo_mask_phone(v_phone),
    'has_phone', v_phone is not null and length(regexp_replace(v_phone, '\D', '', 'g')) >= 10
  );
end;
$function$;

-- ---------------------------------------------------------------- function grants
do $g$
declare f text;
begin
  -- Internal helpers: never callable from the pages.
  foreach f in array array['nav_log(text,text,uuid,uuid,uuid,uuid,boolean)', 'nav_email(text,text,text,text)', 'nav_earn(uuid,text,uuid,uuid,text)',
                           'nav_followup_reminders()', 'nav_referral_json(nav_referrals,boolean)', 'nav_unit_json(nav_units)'] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
  -- Page calls: each checks the signed-in person itself.
  foreach f in array array['navigator_is_me()', 'nav_me()', 'nav_actor_role()', 'nav_can_ref(uuid)', 'nav_can_see_landlord(uuid)', 'nav_can_edit_landlord(uuid)',
                           'nav_home()', 'nav_referral_get(uuid)', 'nav_referral_save(jsonb)', 'nav_referral_withdraw_consent(uuid)', 'nav_note(uuid,text,boolean)',
                           'nav_referral_step(uuid,text,jsonb)', 'nav_followup_save(uuid,text,boolean,text)', 'nav_network()', 'nav_landlord_save(jsonb)',
                           'nav_unit_save(jsonb)', 'nav_staff_overview()', 'nav_stats()', 'nav_staff_navigator_save(jsonb)', 'nav_staff_invite(uuid)',
                           'nav_staff_plan_save(text,numeric,boolean,text)', 'nav_staff_earning(uuid,text,text,text,date,text)'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
end;
$g$;

-- ---------------------------------------------------------------- the daily job (8:15 a.m. Central = 14:15 UTC), sends at once through outbox-flush
do $do$
declare v_secret text;
begin
  select substring(command from $r$'x-cycle-secret', '([^']+)'$r$) into v_secret from cron.job where jobname = 'bank-sync';
  if v_secret is null then raise exception 'Could not find the cycle secret on the bank-sync job'; end if;
  perform cron.unschedule('nav-followup-reminders') where exists (select 1 from cron.job where jobname = 'nav-followup-reminders');
  perform cron.schedule('nav-followup-reminders', '15 14 * * *', format($c$
    select case when nav_followup_reminders() > 0 then net.http_post(url := 'https://hvnsgwfcjpakvhhkfsuy.supabase.co/functions/v1/outbox-flush',
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-cycle-secret', %L), body := '{}'::jsonb) end;
  $c$, v_secret));
end;
$do$;
