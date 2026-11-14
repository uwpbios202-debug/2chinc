-- Landlord Recruitment Database (LRD): Milwaukee independent landlords for Navigators and the office to contact and sign up
-- (Stephen, 11/13/2026: "The mirror needs databases and here is the next database").
--
-- Source: the research workbook Milwaukee_Independent_Landlord_DB_v0.2.xlsx (prepared 2026-11-12), loaded by the generated
-- migration 20261119421000_landlord_recruitment_seed.sql (tools/landlord-db-import.mjs). Every sheet has a table here:
--   Landlord_Records -> lrd_landlords        Landlord_Properties -> lrd_properties   Recruitment_Channels -> lrd_channels
--   Business_Owner_Networks -> lrd_business_networks   Property_Managers -> lrd_property_managers   Large_Networks -> lrd_large_networks
--   Market_Profile -> lrd_market_profile     Data_Sources -> lrd_data_sources       Sources -> lrd_sources
--   Gap_Analysis -> lrd_gap_analysis         Build_Steps -> lrd_build_steps         Outreach_Log -> lrd_outreach (example row not imported)
--   README -> docs/human-mirror/LANDLORD_DB.md
--
-- The workbook's data-use guardrails are rules of this database, enforced by the functions below:
--   * First contact uses only the owner name and the City's published tax-bill/business address (postal mail, events).
--     A phone or email is stored only when the landlord opts in (lrd_log with opt_in_phone / opt_in_email).
--   * Do-Not-Contact is honored by everyone: once set, no Navigator can claim, log contact or sign the landlord up.
--   * Do-Not-Partner (screening) blocks sign-up; "Screen first" must be screened by the office before sign-up.
--   * No skip tracing, no scraping, no selecting owners by ethnicity or national origin (Gap_Analysis, Doc F rejected).
--
-- Who can use it (security definer functions only; the tables are closed to the website roles):
--   office staff (condo_staff, two-step sign-in)   read everything, edit leads and screening, assign, log, sign up
--   Housing Navigators (pilot/active)              read leads and channels, claim a lead, log their own contacts, sign up
--   Housing Navigators in Preview                  read only (same rule as the rest of the Navigator portal)
--   "View as" sessions                             read only
-- Navigators' privacy (D-20): a Navigator sees only her OWN outreach entries; another Navigator's claim shows as "another Navigator",
-- never who. A landlord she signs up becomes a nav_landlords row private to her (nav_landlord_save). Staff see all.
-- Nothing here sends email.

-- ---------------------------------------------------------------- tables
create table if not exists lrd_sources (
  source_id text primary key, title text not null, url text, source_type text,
  import_version text, imported_at timestamptz, created_at timestamptz not null default now()
);

create table if not exists lrd_channels (
  channel_id text primary key,
  channel text not null, what_it_is text, contact_access text, how_used text, verification_status text, source_ids text,
  -- office side (never changed by an import)
  our_status text not null default 'not_started' check (our_status in ('not_started', 'reached_out', 'scheduled', 'active', 'not_a_fit')),
  our_note text, our_last_contact_on date,
  staff_edited_at timestamptz, staff_edited_by text, import_version text, imported_at timestamptz,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);

create table if not exists lrd_business_networks (
  network_id text primary key,
  network text not null, who_belongs text, contact text, how_to_use text, verification_status text, source_url text,
  our_status text not null default 'not_started' check (our_status in ('not_started', 'reached_out', 'scheduled', 'active', 'not_a_fit')),
  our_note text, our_last_contact_on date,
  staff_edited_at timestamptz, staff_edited_by text, import_version text, imported_at timestamptz,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);

create table if not exists lrd_landlords (
  landlord_id text primary key,                         -- LLS-PMnn, LLS-NETnn, LLS-Xnn from the workbook; LLS-L0001... added by the office
  owner_or_company_name text not null,
  segment text, entity_type text, size_tier text, independent_flag text,
  units_known int, parcels_known int, parcels_note text,  -- parcels_note keeps text such as "~800 properties (reported)"
  tax_bill_or_business_address text, local_status text,
  phone_opt_in text, email_opt_in text,                 -- ONLY when the landlord opted in (never from skip tracing or listings)
  accepts_vouchers text, lift_member text,
  recruitment_channel text references lrd_channels(channel_id) on delete set null,
  contact_status text not null default 'Not contacted',
  do_not_contact boolean not null default false,
  eviction_filings_per_100_units numeric, code_violations_per_100_units numeric,
  screening_result text, do_not_partner_flag text,      -- as written ("Screen first", "YES - do not partner")
  do_not_partner boolean not null default false,        -- true when do_not_partner_flag starts with YES
  verification_status text, source_ids text, date_added date,
  -- office / Navigator side (never changed by an import)
  claimed_by_navigator uuid references navigators(id) on delete set null, claimed_at timestamptz,
  nav_landlord_id uuid references nav_landlords(id) on delete set null, signed_up_at timestamptz,
  is_local boolean not null default false,              -- added by the office, not from the workbook
  our_note text,
  staff_edited_at timestamptz, staff_edited_by text, import_version text, imported_at timestamptz,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index if not exists lrd_landlords_claimed on lrd_landlords (claimed_by_navigator) where claimed_by_navigator is not null;
create sequence if not exists lrd_local_seq;

create table if not exists lrd_properties (
  property_id text primary key,
  landlord_id text not null references lrd_landlords(landlord_id) on delete cascade,
  taxkey text, property_address text, units int, land_use_code text, owner_occupied text, neighborhood text, source text, date_added date,
  import_version text, imported_at timestamptz, created_at timestamptz not null default now()
);
create index if not exists lrd_properties_landlord on lrd_properties (landlord_id);

create table if not exists lrd_property_managers (
  pm_id text primary key,
  company text not null, focus text, address_listed text, source_ids text,
  landlord_id text references lrd_landlords(landlord_id) on delete set null,   -- the same company's lead row (PM01 -> LLS-PM01)
  import_version text, imported_at timestamptz, created_at timestamptz not null default now()
);

create table if not exists lrd_large_networks (
  network_key text primary key,                         -- 'rank-1' ... or 'highgrove' for the unranked row
  rank int, owner_network text not null, parcels text, units text, flag text, source_id text,
  landlord_id text references lrd_landlords(landlord_id) on delete set null,
  import_version text, imported_at timestamptz, created_at timestamptz not null default now()
);

create table if not exists lrd_market_profile (
  metric text primary key, value numeric, note text, source_id text, is_derived boolean not null default false,
  import_version text, imported_at timestamptz
);

create table if not exists lrd_data_sources (
  source_id text primary key, source text not null, what_it_contains text, access text, use_in_db text,
  adopted boolean not null default true,                -- false when the workbook says NOT ADOPTED
  import_version text, imported_at timestamptz
);

create table if not exists lrd_gap_analysis (
  id int primary key, doc text, claim_or_item text, verdict text, reason text, action_taken text,
  import_version text, imported_at timestamptz
);

create table if not exists lrd_build_steps (
  step int primary key, name text not null, action text, step_owner text,
  done_on date, done_note text,                         -- office side
  import_version text, imported_at timestamptz
);

create table if not exists lrd_outreach (
  id bigserial primary key,
  contact_date date not null default current_date,
  landlord_id text not null references lrd_landlords(landlord_id) on delete cascade,
  channel_id text references lrd_channels(channel_id) on delete set null,
  contact_method text not null check (contact_method in ('Postal mail', 'In person', 'Event', 'Phone (business line)', 'Phone (opted in)',
    'Email (opted in)', 'Through a property manager', 'Through an association', 'They contacted us', 'Other')),
  contact_person_role text,
  outcome text not null check (outcome in ('No answer yet', 'Left information', 'Interested', 'Interested - send LIFT packet',
    'Meeting set', 'Signed up', 'Not now', 'Not interested', 'Do not contact')),
  units_offered int check (units_offered is null or units_offered >= 0),
  accepts_vouchers text check (accepts_vouchers is null or accepts_vouchers in ('Yes', 'No', 'Unknown')),
  lift_interest text check (lift_interest is null or lift_interest in ('Yes', 'No', 'Unknown')),
  follow_up_date date,
  opt_in_phone text, opt_in_email text,
  do_not_contact boolean not null default false,
  notes text,
  navigator_id uuid references navigators(id) on delete set null,   -- null when the office logged it
  actor text, actor_role text,
  created_at timestamptz not null default now()
);
create index if not exists lrd_outreach_landlord on lrd_outreach (landlord_id, created_at);
create index if not exists lrd_outreach_navigator on lrd_outreach (navigator_id) where navigator_id is not null;

-- Row security on, nothing granted to the website roles: everything goes through the functions below.
do $$
declare t text;
begin
  foreach t in array array['lrd_sources', 'lrd_channels', 'lrd_business_networks', 'lrd_landlords', 'lrd_properties', 'lrd_property_managers',
    'lrd_large_networks', 'lrd_market_profile', 'lrd_data_sources', 'lrd_gap_analysis', 'lrd_build_steps', 'lrd_outreach'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from anon, authenticated', t);
    execute format('grant select, insert, update, delete on %I to service_role', t);
  end loop;
end $$;
revoke all on sequence lrd_local_seq, lrd_outreach_id_seq from anon, authenticated;
grant usage, select on sequence lrd_local_seq, lrd_outreach_id_seq to service_role;

-- ---------------------------------------------------------------- who is asking
-- 'staff', 'navigator' or 'navigator_preview'; raises otherwise. p_write true also refuses Preview and "View as".
create or replace function lrd_require(p_write boolean) returns text
language plpgsql stable security definer set search_path = public as $$
declare v text;
begin
  if staff_session_staff() then v := 'staff';
  elsif nav_me() is not null then
    v := case when exists (select 1 from navigators where id = nav_me() and status = 'preview') then 'navigator_preview' else 'navigator' end;
  end if;
  if v is null then raise exception 'Staff or Housing Navigator sign-in required' using errcode = '42501'; end if;
  if p_write then
    if v = 'navigator_preview' then
      raise exception 'Preview only: you can look around now. Contacting landlords opens once the partner and confidentiality agreements are signed.' using errcode = '42501';
    end if;
    if autopay_view_as_session() then raise exception 'Not while viewing as someone else.' using errcode = '42501'; end if;
  end if;
  return v;
end $$;

-- One lead as JSON for the caller: a Navigator never sees who else claimed it or another Navigator's notes.
create or replace function lrd_lead_json(l lrd_landlords, p_role text) returns jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(l) - 'claimed_by_navigator' - 'staff_edited_by' - 'our_note' - 'nav_landlord_id'
    || jsonb_build_object(
      'claim', case when l.claimed_by_navigator is null then null when l.claimed_by_navigator = nav_me() then 'you'
                    when p_role = 'staff' then coalesce((select n.name from navigators n where n.id = l.claimed_by_navigator), 'a Navigator')
                    else 'another Navigator' end,
      'our_note', case when p_role = 'staff' then l.our_note end,
      'nav_landlord_id', case when p_role = 'staff' or l.claimed_by_navigator = nav_me() then l.nav_landlord_id end,
      'outreach_count', (select count(*) from lrd_outreach o where o.landlord_id = l.landlord_id and (p_role = 'staff' or o.navigator_id = nav_me())),
      'last_outcome', (select o.outcome from lrd_outreach o where o.landlord_id = l.landlord_id and (p_role = 'staff' or o.navigator_id = nav_me())
                        order by o.contact_date desc, o.id desc limit 1),
      'next_follow_up', (select min(o.follow_up_date) from lrd_outreach o where o.landlord_id = l.landlord_id and o.follow_up_date >= current_date
                          and (p_role = 'staff' or o.navigator_id = nav_me())),
      'can_contact', not l.do_not_contact and l.contact_status not in ('Not targeted', 'Do not contact for partnership'),
      'can_sign_up', not l.do_not_contact and not l.do_not_partner and l.nav_landlord_id is null
                     and coalesce(l.do_not_partner_flag, '') !~* '^screen first'
                     and l.contact_status not in ('Not targeted', 'Do not contact for partnership'));
$$;

-- ---------------------------------------------------------------- reading
-- p: {q, segment, independent_only (bool), status, mine (bool), include_large (bool)}. Large networks are hidden unless include_large.
create or replace function lrd_leads(p jsonb default '{}'::jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_role text := lrd_require(false); v_q text := nullif(trim(coalesce(p->>'q', '')), '');
begin
  return coalesce((select jsonb_agg(lrd_lead_json(l, v_role) order by (l.claimed_by_navigator = nav_me()) desc nulls last, l.landlord_id)
    from lrd_landlords l
    where (coalesce((p->>'include_large')::boolean, false) or l.independent_flag is distinct from 'No')
      and (v_q is null or l.owner_or_company_name ilike '%' || v_q || '%' or l.tax_bill_or_business_address ilike '%' || v_q || '%'
           or l.landlord_id ilike v_q || '%')
      and (nullif(p->>'segment', '') is null or l.segment = p->>'segment')
      and (not coalesce((p->>'independent_only')::boolean, false) or l.independent_flag ilike 'Yes%' or l.independent_flag ilike 'Gateway%')
      and (nullif(p->>'status', '') is null or l.contact_status = p->>'status')
      and (not coalesce((p->>'mine')::boolean, false) or l.claimed_by_navigator = nav_me())), '[]'::jsonb);
end $$;

-- One lead with its properties, property-manager / large-network row, channel and outreach (a Navigator: her own entries only).
create or replace function lrd_lead(p_id text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_role text := lrd_require(false); l lrd_landlords;
begin
  select * into l from lrd_landlords where landlord_id = p_id;
  if l.landlord_id is null then raise exception 'Landlord not found.'; end if;
  return lrd_lead_json(l, v_role) || jsonb_build_object(
    'properties', coalesce((select jsonb_agg(to_jsonb(x) order by x.property_address) from lrd_properties x where x.landlord_id = l.landlord_id), '[]'::jsonb),
    'property_manager', (select to_jsonb(m) from lrd_property_managers m where m.landlord_id = l.landlord_id limit 1),
    'large_network', (select to_jsonb(n) from lrd_large_networks n where n.landlord_id = l.landlord_id limit 1),
    'channel', (select to_jsonb(c) - 'our_note' - 'staff_edited_by' from lrd_channels c where c.channel_id = l.recruitment_channel),
    'outreach', coalesce((select jsonb_agg(to_jsonb(o) - 'actor' || jsonb_build_object('by', case when o.navigator_id is null then 'Office'
                   when o.navigator_id = nav_me() then 'You' else coalesce((select n.name from navigators n where n.id = o.navigator_id), 'a Navigator') end)
                   order by o.contact_date desc, o.id desc)
                 from lrd_outreach o where o.landlord_id = l.landlord_id and (v_role = 'staff' or o.navigator_id = nav_me())), '[]'::jsonb));
end $$;

-- Where landlords gather and the reference sheets (channels, business networks, managers, large networks, market, data sources,
-- sources, gap analysis, build steps). Office notes are for staff only.
create or replace function lrd_directory() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_role text := lrd_require(false);
begin
  return jsonb_build_object(
    'role', v_role,
    'channels', coalesce((select jsonb_agg(case when v_role = 'staff' then to_jsonb(c) else to_jsonb(c) - 'our_note' - 'staff_edited_by' end order by c.channel_id) from lrd_channels c), '[]'::jsonb),
    'business_networks', coalesce((select jsonb_agg(case when v_role = 'staff' then to_jsonb(b) else to_jsonb(b) - 'our_note' - 'staff_edited_by' end order by b.network_id) from lrd_business_networks b), '[]'::jsonb),
    'property_managers', coalesce((select jsonb_agg(to_jsonb(m) order by m.pm_id) from lrd_property_managers m), '[]'::jsonb),
    'large_networks', coalesce((select jsonb_agg(to_jsonb(n) order by n.rank nulls last) from lrd_large_networks n), '[]'::jsonb),
    'market_profile', coalesce((select jsonb_agg(to_jsonb(x) order by x.is_derived, x.metric) from lrd_market_profile x), '[]'::jsonb),
    'data_sources', coalesce((select jsonb_agg(to_jsonb(x) order by x.adopted desc, x.source_id) from lrd_data_sources x), '[]'::jsonb),
    'sources', coalesce((select jsonb_agg(to_jsonb(x) order by x.source_id) from lrd_sources x), '[]'::jsonb),
    'gap_analysis', case when v_role = 'staff' then coalesce((select jsonb_agg(to_jsonb(x) order by x.id) from lrd_gap_analysis x), '[]'::jsonb) end,
    'build_steps', case when v_role = 'staff' then coalesce((select jsonb_agg(to_jsonb(x) order by x.step) from lrd_build_steps x), '[]'::jsonb) end,
    'counts', jsonb_build_object(
      'leads', (select count(*) from lrd_landlords where independent_flag is distinct from 'No'),
      'large_networks', (select count(*) from lrd_landlords where independent_flag = 'No'),
      'signed_up', (select count(*) from lrd_landlords where nav_landlord_id is not null),
      'do_not_contact', (select count(*) from lrd_landlords where do_not_contact),
      'mine', (select count(*) from lrd_landlords where claimed_by_navigator = nav_me())));
end $$;

-- ---------------------------------------------------------------- acting
-- A Navigator claims a lead (one Navigator at a time) or lets it go. Staff: p_navigator assigns (null = unassign).
create or replace function lrd_claim(p_id text, p_claim boolean, p_navigator uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_role text := lrd_require(true); l lrd_landlords;
begin
  select * into l from lrd_landlords where landlord_id = p_id for update;
  if l.landlord_id is null then raise exception 'Landlord not found.'; end if;
  if v_role = 'staff' then
    if p_claim and p_navigator is not null and not exists (select 1 from navigators where id = p_navigator) then raise exception 'Navigator not found.'; end if;
    update lrd_landlords set claimed_by_navigator = case when p_claim then p_navigator end,
      claimed_at = case when p_claim and p_navigator is not null then now() end, updated_at = now() where landlord_id = p_id;
  elsif p_claim then
    if l.do_not_contact then raise exception 'This landlord asked not to be contacted.'; end if;
    if l.contact_status in ('Not targeted', 'Do not contact for partnership') or l.do_not_partner then
      raise exception 'This one is not a landlord to recruit (%).', l.contact_status;
    end if;
    if l.claimed_by_navigator is not null and l.claimed_by_navigator <> nav_me() then
      raise exception 'Another Navigator is already contacting this landlord.';
    end if;
    update lrd_landlords set claimed_by_navigator = nav_me(), claimed_at = coalesce(claimed_at, now()), updated_at = now() where landlord_id = p_id;
  else
    if l.claimed_by_navigator is distinct from nav_me() then raise exception 'You are not contacting this landlord.'; end if;
    update lrd_landlords set claimed_by_navigator = null, claimed_at = null, updated_at = now() where landlord_id = p_id;
  end if;
  select * into l from lrd_landlords where landlord_id = p_id;
  return lrd_lead_json(l, v_role);
end $$;

-- Record one contact. p: {landlord_id, contact_date, channel_id, contact_method, contact_person_role, outcome, units_offered,
-- accepts_vouchers, lift_interest, follow_up_date, opt_in_phone, opt_in_email, do_not_contact, notes}.
-- A Navigator must hold the lead (an unclaimed lead is claimed for her). "Do not contact" stops all outreach by everyone.
create or replace function lrd_log(p jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare
  v_role text := lrd_require(true); l lrd_landlords; v_id bigint;
  v_dnc boolean := coalesce((p->>'do_not_contact')::boolean, false) or p->>'outcome' = 'Do not contact';
  v_phone text := nullif(trim(coalesce(p->>'opt_in_phone', '')), ''); v_email text := nullif(lower(trim(coalesce(p->>'opt_in_email', ''))), '');
begin
  select * into l from lrd_landlords where landlord_id = p->>'landlord_id' for update;
  if l.landlord_id is null then raise exception 'Landlord not found.'; end if;
  if l.do_not_contact then raise exception 'This landlord asked not to be contacted. Nothing was recorded.'; end if;
  if v_role <> 'staff' then
    if l.contact_status in ('Not targeted', 'Do not contact for partnership') or l.do_not_partner then
      raise exception 'This one is not a landlord to recruit (%).', l.contact_status;
    end if;
    if l.claimed_by_navigator is not null and l.claimed_by_navigator <> nav_me() then
      raise exception 'Another Navigator is already contacting this landlord.';
    end if;
  end if;
  if coalesce(p->>'outcome', '') = 'Signed up' then raise exception 'Use "Sign up" to add the landlord to your network.'; end if;
  if nullif(p->>'contact_method', '') is null then raise exception 'Choose how you contacted them.'; end if;
  if nullif(p->>'outcome', '') is null and not v_dnc then raise exception 'Choose the outcome.'; end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'That email does not look right.'; end if;
  insert into lrd_outreach (contact_date, landlord_id, channel_id, contact_method, contact_person_role, outcome, units_offered, accepts_vouchers,
    lift_interest, follow_up_date, opt_in_phone, opt_in_email, do_not_contact, notes, navigator_id, actor, actor_role)
  values (coalesce(nullif(p->>'contact_date', '')::date, current_date), l.landlord_id, nullif(p->>'channel_id', ''), p->>'contact_method',
    nullif(trim(coalesce(p->>'contact_person_role', '')), ''), case when v_dnc then 'Do not contact' else p->>'outcome' end,
    nullif(p->>'units_offered', '')::int, nullif(p->>'accepts_vouchers', ''), nullif(p->>'lift_interest', ''),
    case when v_dnc then null else nullif(p->>'follow_up_date', '')::date end,
    case when v_dnc then null else v_phone end, case when v_dnc then null else v_email end, v_dnc,
    nullif(trim(coalesce(p->>'notes', '')), ''), case when v_role = 'navigator' then nav_me() end, lower(auth.email()), v_role)
  returning id into v_id;
  update lrd_landlords set
    contact_status = case when v_dnc then 'Do not contact'
                          when p->>'outcome' in ('Interested', 'Interested - send LIFT packet', 'Meeting set') then 'Interested'
                          when p->>'outcome' in ('Not now', 'Not interested') then p->>'outcome'
                          when contact_status = 'Interested' then contact_status else 'Contacted' end,
    do_not_contact = v_dnc,
    phone_opt_in = case when v_dnc then null else coalesce(v_phone, phone_opt_in) end,
    email_opt_in = case when v_dnc then null else coalesce(v_email, email_opt_in) end,
    accepts_vouchers = coalesce(nullif(p->>'accepts_vouchers', ''), accepts_vouchers),
    claimed_by_navigator = case when v_dnc then null when v_role = 'navigator' then nav_me() else claimed_by_navigator end,
    claimed_at = case when v_dnc then null when v_role = 'navigator' then coalesce(claimed_at, now()) else claimed_at end,
    updated_at = now()
  where landlord_id = l.landlord_id;
  return v_id;
end $$;

-- Sign the landlord up: adds them to the caller's landlord network (nav_landlords, private to a Navigator per D-20; shared when the
-- office does it) and links the lead. Blocked by Do-Not-Contact, Do-Not-Partner and "Screen first" (the office screens first).
create or replace function lrd_sign_up(p_id text, p jsonb default '{}'::jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_role text := lrd_require(true); l lrd_landlords; v_nav uuid;
begin
  select * into l from lrd_landlords where landlord_id = p_id for update;
  if l.landlord_id is null then raise exception 'Landlord not found.'; end if;
  if l.nav_landlord_id is not null then raise exception 'Already signed up.'; end if;
  if l.do_not_contact then raise exception 'This landlord asked not to be contacted.'; end if;
  if l.do_not_partner or l.contact_status in ('Not targeted', 'Do not contact for partnership') then raise exception 'This landlord is not one to partner with.'; end if;
  if coalesce(l.do_not_partner_flag, '') ~* '^screen first' then raise exception 'The office must screen this landlord first.'; end if;
  if v_role = 'navigator' and l.claimed_by_navigator is not null and l.claimed_by_navigator <> nav_me() then
    raise exception 'Another Navigator is already contacting this landlord.';
  end if;
  v_nav := nav_landlord_save(jsonb_build_object(
    'name', coalesce(nullif(trim(p->>'contact_name'), ''), l.owner_or_company_name),
    'business_name', l.owner_or_company_name,
    'phone', l.phone_opt_in, 'email', l.email_opt_in,
    'mailing_address', l.tax_bill_or_business_address,
    'accepts_vouchers', case when l.accepts_vouchers ilike 'yes%' then 'true' when l.accepts_vouchers ilike 'no%' then 'false' end,
    'notes', 'Signed up from the landlord recruitment database (' || l.landlord_id || ').'
      || coalesce(' ' || nullif(trim(p->>'notes'), ''), '')));
  update lrd_landlords set nav_landlord_id = v_nav, signed_up_at = now(), contact_status = 'Signed up',
    claimed_by_navigator = case when v_role = 'navigator' then nav_me() else claimed_by_navigator end,
    claimed_at = case when v_role = 'navigator' then coalesce(claimed_at, now()) else claimed_at end, updated_at = now()
  where landlord_id = p_id;
  insert into lrd_outreach (landlord_id, contact_method, outcome, notes, navigator_id, actor, actor_role)
  values (p_id, 'Other', 'Signed up', 'Added to the landlord network.', case when v_role = 'navigator' then nav_me() end, lower(auth.email()), v_role);
  return v_nav;
end $$;

-- Office: add a lead (p without landlord_id) or change one (screening, flags, status, notes). Research columns changed here are
-- kept by later imports (staff_edited_at).
create or replace function lrd_save(p jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare v_role text := lrd_require(true); v_id text := nullif(trim(coalesce(p->>'landlord_id', '')), ''); v_who text := lower(auth.email());
begin
  if v_role <> 'staff' then raise exception 'Only the office can change a landlord record.' using errcode = '42501'; end if;
  if v_id is null then
    if length(trim(coalesce(p->>'owner_or_company_name', ''))) < 2 then raise exception 'Enter the owner or company name.'; end if;
    v_id := 'LLS-L' || lpad(nextval('lrd_local_seq')::text, 4, '0');
    insert into lrd_landlords (landlord_id, owner_or_company_name, is_local, date_added, verification_status)
    values (v_id, trim(p->>'owner_or_company_name'), true, current_date, 'Added by the office');
  elsif not exists (select 1 from lrd_landlords where landlord_id = v_id) then raise exception 'Landlord not found.';
  end if;
  update lrd_landlords set
    owner_or_company_name = coalesce(nullif(trim(p->>'owner_or_company_name'), ''), owner_or_company_name),
    segment = case when p ? 'segment' then nullif(p->>'segment', '') else segment end,
    entity_type = case when p ? 'entity_type' then nullif(p->>'entity_type', '') else entity_type end,
    size_tier = case when p ? 'size_tier' then nullif(p->>'size_tier', '') else size_tier end,
    independent_flag = case when p ? 'independent_flag' then nullif(p->>'independent_flag', '') else independent_flag end,
    units_known = case when p ? 'units_known' then nullif(p->>'units_known', '')::int else units_known end,
    tax_bill_or_business_address = case when p ? 'tax_bill_or_business_address' then nullif(trim(p->>'tax_bill_or_business_address'), '') else tax_bill_or_business_address end,
    local_status = case when p ? 'local_status' then nullif(p->>'local_status', '') else local_status end,
    recruitment_channel = case when p ? 'recruitment_channel' then nullif(p->>'recruitment_channel', '') else recruitment_channel end,
    contact_status = coalesce(nullif(p->>'contact_status', ''), contact_status),
    do_not_contact = coalesce((p->>'do_not_contact')::boolean, do_not_contact),
    eviction_filings_per_100_units = case when p ? 'eviction_filings_per_100_units' then nullif(p->>'eviction_filings_per_100_units', '')::numeric else eviction_filings_per_100_units end,
    code_violations_per_100_units = case when p ? 'code_violations_per_100_units' then nullif(p->>'code_violations_per_100_units', '')::numeric else code_violations_per_100_units end,
    screening_result = case when p ? 'screening_result' then nullif(trim(p->>'screening_result'), '') else screening_result end,
    do_not_partner_flag = case when p ? 'do_not_partner_flag' then nullif(trim(p->>'do_not_partner_flag'), '') else do_not_partner_flag end,
    do_not_partner = case when p ? 'do_not_partner_flag' then coalesce(p->>'do_not_partner_flag', '') ~* '^yes' else do_not_partner end,
    verification_status = case when p ? 'verification_status' then nullif(p->>'verification_status', '') else verification_status end,
    our_note = case when p ? 'our_note' then nullif(trim(p->>'our_note'), '') else our_note end,
    claimed_by_navigator = case when coalesce((p->>'do_not_contact')::boolean, false) then null else claimed_by_navigator end,
    staff_edited_at = now(), staff_edited_by = v_who, updated_at = now()
  where landlord_id = v_id;
  return v_id;
end $$;

-- Office: track work on a channel or business network. p: {kind: 'channel'|'network', id, our_status, our_note, our_last_contact_on}.
create or replace function lrd_channel_save(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare v_role text := lrd_require(true);
begin
  if v_role <> 'staff' then raise exception 'Only the office can change this.' using errcode = '42501'; end if;
  if p->>'kind' = 'channel' then
    update lrd_channels set our_status = coalesce(nullif(p->>'our_status', ''), our_status), our_note = nullif(trim(coalesce(p->>'our_note', '')), ''),
      our_last_contact_on = nullif(p->>'our_last_contact_on', '')::date, updated_at = now() where channel_id = p->>'id';
  elsif p->>'kind' = 'network' then
    update lrd_business_networks set our_status = coalesce(nullif(p->>'our_status', ''), our_status), our_note = nullif(trim(coalesce(p->>'our_note', '')), ''),
      our_last_contact_on = nullif(p->>'our_last_contact_on', '')::date, updated_at = now() where network_id = p->>'id';
  else raise exception 'Unknown kind.';
  end if;
  if not found then raise exception 'Not found.'; end if;
end $$;

-- ---------------------------------------------------------------- function grants
revoke all on function lrd_require(boolean), lrd_lead_json(lrd_landlords, text), lrd_leads(jsonb), lrd_lead(text), lrd_directory(),
  lrd_claim(text, boolean, uuid), lrd_log(jsonb), lrd_sign_up(text, jsonb), lrd_save(jsonb), lrd_channel_save(jsonb) from public, anon;
grant execute on function lrd_leads(jsonb), lrd_lead(text), lrd_directory(), lrd_claim(text, boolean, uuid), lrd_log(jsonb),
  lrd_sign_up(text, jsonb), lrd_save(jsonb), lrd_channel_save(jsonb) to authenticated;
revoke all on function lrd_require(boolean), lrd_lead_json(lrd_landlords, text) from authenticated;
grant execute on function lrd_require(boolean), lrd_lead_json(lrd_landlords, text), lrd_leads(jsonb), lrd_lead(text), lrd_directory(),
  lrd_claim(text, boolean, uuid), lrd_log(jsonb), lrd_sign_up(text, jsonb), lrd_save(jsonb), lrd_channel_save(jsonb) to service_role;
