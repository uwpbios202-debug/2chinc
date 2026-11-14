-- CHPMS: Community Housing Partnership Management System, the Milwaukee housing resource directory (Stephen, 11/12/2026:
-- "build this system and verify Navigators can access this system as well as all staff").
--
-- Source: the research workbook Milwaukee_Housing_Resources_CHPMS_v2.xlsx (114 organizations, 79 programs, sources and
-- verification history), loaded by the generated migration 20261119090000_chpms_seed_v2.sql (tools/chpms-import.mjs).
-- The workbook's own rules carry over: no amount is ever estimated ("Not publicly disclosed" stays as written), conflicting
-- facts keep both values, and status must be re-checked by phone before a client referral.
--
-- Who can use it (all through security definer functions; the tables are closed to the website roles):
--   office staff (condo_staff, two-step sign-in)      read, edit, log checks, make and manage every referral
--   field staff (field_staff, two-step sign-in)       read, log checks, make and manage their own referrals
--   Housing Navigators (pilot/active)                 read, log checks, make and manage their own referrals
--   Housing Navigators in Preview                     read only (same rule as the rest of the Navigator portal)
--   "View as" sessions                                read only (never act as someone else)
-- Pages: https://2ndchinc.org/staff/resources/ (office and field staff) and the Resources tab of https://2ndchinc.org/navigator/ .
--
-- Referrals to outside programs are recorded here; the site never emails an outside organization. The person sending the referral
-- uses their own email or phone (the page prepares the text). The office is emailed (info@) when a Navigator or field staff member
-- records a referral; that email carries no client phone or email.
-- Differs from the 11/11 rental assistance directory (aid_orgs, https://2ndchinc.org/staff/aid/), which is left as it is.

-- ---------------------------------------------------------------- tables
create table if not exists chpms_orgs (
  org_id text primary key,
  legal_name text not null,
  dba text, org_type text, classification_codes text, classifications text, priority_tier int,
  website text, physical_address text, main_phone text, general_email text,
  service_area text, service_area_source_ids text, languages text, accepts_outside_referrals text,
  verification_status text not null default 'Needs Confirmation', verification_notes text,
  source_ids text, primary_source_url text, provenance text, date_accessed date,
  -- office side (never changed by an import)
  is_local boolean not null default false,                -- added by the office, not from the workbook
  our_relationship text not null default 'none' check (our_relationship in ('none', 'contacted', 'talking', 'partner', 'do_not_refer')),
  our_note text,
  our_checked_on date, our_checked_by text,
  staff_edited_at timestamptz, staff_edited_by text,      -- set when the office changes a research field: imports then leave the row alone
  import_version text, imported_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists chpms_programs (
  program_id text primary key,
  org_id text not null references chpms_orgs(org_id) on delete cascade,
  program_name text not null,
  assistance_form text, payment_goes_to text, max_assistance text, months_covered text, frequency text,
  pays_security_deposit text, pays_arrears text, pays_application_fees text, moving_assistance text,
  current_status text, waiting_list text, application_window text, funding_dependency text, income_limits text,
  landlord_agreement_required text, eligibility_summary text, how_to_apply text, referral_requirement text,
  application_url text, intake_phone text,
  direct_financial text,                                  -- as written in the workbook ("Yes", "Yes (to landlords)", "Org grants only" ...)
  is_direct_financial boolean not null default false,     -- true when that text starts with Yes
  amount_publicly_disclosed text,
  verification_status text not null default 'Needs Confirmation',
  source_ids text, notes text, provenance text, date_accessed date,
  self_referral text, agency_referral_required text, landlord_can_initiate text, application_method text, currently_open text, procedure_source_ids text,
  is_local boolean not null default false,
  our_note text,
  staff_edited_at timestamptz, staff_edited_by text,
  import_version text, imported_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists chpms_programs_org on chpms_programs (org_id);

create table if not exists chpms_program_assist (
  program_id text not null references chpms_programs(program_id) on delete cascade,
  category text not null check (category in ('Emergency rental assistance', 'Monthly rental assistance', 'Security deposit assistance',
    'First month''s rent', 'Last month''s rent', 'Eviction prevention', 'Utility assistance', 'Moving expenses', 'Furniture and household items',
    'Transitional housing', 'Permanent housing', 'Housing vouchers', 'Rapid rehousing', 'Supportive housing', 'Case management',
    'Housing navigation', 'Landlord mediation', 'Financial counseling', 'Benefits enrollment', 'Other housing support')),
  provided boolean not null default false,
  source_ids text,
  primary key (program_id, category)
);

create table if not exists chpms_program_pops (
  program_id text not null references chpms_programs(program_id) on delete cascade,
  population text not null check (population in ('Veterans', 'Seniors', 'Fixed income (SS/SSI/SSDI/VA)', 'Families with children',
    'Experiencing homelessness', 'At risk of eviction', 'Disabilities', 'Returning citizens', 'Low-income working', 'No current income')),
  primary key (program_id, population)
);

create table if not exists chpms_eligibility (
  elig_id text primary key,
  program_id text not null references chpms_programs(program_id) on delete cascade,
  requirement_type text, requirement text, source_id text
);
create index if not exists chpms_eligibility_program on chpms_eligibility (program_id);

create table if not exists chpms_contacts (
  contact_id text primary key,
  org_id text not null references chpms_orgs(org_id) on delete cascade,
  contact_type text, name_if_public text, phone text, email text, source_id text
);
create index if not exists chpms_contacts_org on chpms_contacts (org_id);

create table if not exists chpms_landlord (
  org_id text primary key references chpms_orgs(org_id) on delete cascade,
  works_with_private_landlords text, recruits_landlords text, landlord_network text, pays_landlords_directly text,
  landlord_incentives text, tenant_placement text, stabilization_support text, partnership_contact text, onboarding text, source_ids text
);

create table if not exists chpms_org_links (
  rel_id text primary key,
  from_org text not null references chpms_orgs(org_id) on delete cascade,
  to_org text not null references chpms_orgs(org_id) on delete cascade,
  relationship text, source_ids text
);

create table if not exists chpms_pathways (
  population text not null, step int not null, step_name text, what_happens text, responsible_organizations text,
  primary key (population, step)
);

create table if not exists chpms_funding (
  funding_id text primary key,
  funding_level text, funding_agency text, program text, available_to text, receiving_org text, service_delivery_org text,
  population text, assistance_type text, funding_period text, accepting_apps_or_awarding text, source_ids text
);

create table if not exists chpms_gaps (
  seq int primary key, kind text, finding text, source_ids text
);

create table if not exists chpms_sources (
  source_id text primary key, title text, url text, publisher text, source_type text, date_accessed date
);

create table if not exists chpms_research_log (
  seq int primary key,
  log text not null check (log in ('discovery', 'conflict', 'merge')),
  entry_type text,
  data jsonb not null default '{}'::jsonb
);

-- Verification history from the workbook (from_import) plus every check the office, field staff or a Navigator logs.
create table if not exists chpms_checks (
  id bigserial primary key,
  verification_id text unique,                            -- VH001 ... for imported rows
  record_type text not null check (record_type in ('org', 'program')),
  record_id text not null,
  checked_on date not null default current_date,
  status text,                                            -- workbook status label, or the office edit summary
  result text check (result in ('open', 'limited', 'waitlist', 'paused', 'closed', 'no_answer', 'wrong_number', 'other')),
  funds_today text check (funds_today in ('unknown', 'available', 'low', 'none')),
  method text,
  notes text,
  by_email text, by_name text,
  by_role text not null default 'research' check (by_role in ('research', 'staff', 'field', 'navigator')),
  from_import boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists chpms_checks_record on chpms_checks (record_type, record_id, checked_on desc, id desc);

create sequence if not exists chpms_local_seq;
create sequence if not exists chpms_referral_no_seq;

-- Referrals of a person to an outside program.
create table if not exists chpms_referrals (
  id uuid primary key default gen_random_uuid(),
  ref_no bigint not null default nextval('chpms_referral_no_seq') unique,
  org_id text references chpms_orgs(org_id) on delete set null,
  program_id text references chpms_programs(program_id) on delete set null,
  org_name text not null,                                 -- kept so the referral still reads right if the directory row changes
  program_name text,
  made_by_email text not null, made_by_name text, made_by_role text not null check (made_by_role in ('staff', 'field', 'navigator')),
  navigator_id uuid references navigators(id) on delete set null,
  nav_referral_id uuid references nav_referrals(id) on delete set null,
  first_name text not null, last_name text not null, phone text, email text,
  household_size int check (household_size between 1 and 20),
  population text, help_needed text[] not null default '{}',
  notes text,
  consent_name text not null, consent_on date not null,
  status text not null default 'new' check (status in ('new', 'sent', 'in_process', 'approved', 'denied', 'closed', 'withdrawn')),
  status_checked_on date,                                 -- the day the program was confirmed open before sending (workbook rule)
  sent_how text check (sent_how in ('email', 'phone', 'online', 'walk_in', 'fax', 'other')), sent_on date,
  approved_amount_cents int check (approved_amount_cents >= 0),
  outcome_note text, closed_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  closed_at timestamptz,
  check (coalesce(trim(phone), '') <> '' or coalesce(trim(email), '') <> '')
);
create index if not exists chpms_referrals_maker on chpms_referrals (lower(made_by_email), created_at desc);
create index if not exists chpms_referrals_status on chpms_referrals (status);

create table if not exists chpms_referral_events (
  id bigserial primary key,
  referral_id uuid not null references chpms_referrals(id) on delete cascade,
  at timestamptz not null default now(),
  actor_email text, actor_name text, actor_role text,
  action text not null,
  detail text
);
create index if not exists chpms_referral_events_ref on chpms_referral_events (referral_id, at);

-- Row security on, nothing granted to the website roles: everything goes through the functions below.
do $$
declare t text;
begin
  foreach t in array array['chpms_orgs', 'chpms_programs', 'chpms_program_assist', 'chpms_program_pops', 'chpms_eligibility', 'chpms_contacts',
    'chpms_landlord', 'chpms_org_links', 'chpms_pathways', 'chpms_funding', 'chpms_gaps', 'chpms_sources', 'chpms_research_log', 'chpms_checks',
    'chpms_referrals', 'chpms_referral_events'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on %I from anon, authenticated', t);
    execute format('grant select, insert, update, delete on %I to service_role', t);
  end loop;
end $$;
revoke all on sequence chpms_local_seq, chpms_referral_no_seq, chpms_checks_id_seq, chpms_referral_events_id_seq from anon, authenticated;
grant usage, select on sequence chpms_local_seq, chpms_referral_no_seq to service_role;
grant usage, select on sequence chpms_checks_id_seq, chpms_referral_events_id_seq to service_role;

-- ---------------------------------------------------------------- who is asking
-- 'staff', 'field', 'navigator', 'navigator_preview' or null.
create or replace function chpms_role() returns text
language plpgsql stable security definer set search_path = public as $$
begin
  if staff_session_staff() then return 'staff'; end if;
  if condo_session_ok() and field_is_staff() then return 'field'; end if;
  if nav_me() is not null then
    return case when exists (select 1 from navigators where id = nav_me() and status = 'preview') then 'navigator_preview' else 'navigator' end;
  end if;
  return null;
end $$;

-- Raises unless the caller may read (p_write false) or act (p_write true). Returns the role.
create or replace function chpms_require(p_write boolean) returns text
language plpgsql stable security definer set search_path = public as $$
declare v text := chpms_role();
begin
  if v is null then raise exception 'Staff or Housing Navigator sign-in required' using errcode = '42501'; end if;
  if p_write then
    if v = 'navigator_preview' then
      raise exception 'Preview only: you can look around now. Logging checks and referring people opens once the partner and confidentiality agreements are signed.' using errcode = '42501';
    end if;
    if autopay_view_as_session() then raise exception 'Not while viewing as someone else.' using errcode = '42501'; end if;
  end if;
  return v;
end $$;

create or replace function chpms_my_name() returns text
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select nullif(trim(name), '') from condo_staff where lower(email) = lower(auth.email()) limit 1),
    (select nullif(trim(name), '') from field_staff where active and lower(email) = lower(auth.email()) limit 1),
    (select nullif(trim(name), '') from navigators where lower(email) = lower(auth.email()) limit 1),
    lower(auth.email()));
$$;

-- ---------------------------------------------------------------- reading
create or replace function chpms_check_json(c chpms_checks) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', c.id, 'checked_on', c.checked_on, 'status', c.status, 'result', c.result, 'funds_today', c.funds_today,
    'method', c.method, 'notes', c.notes, 'by_name', c.by_name, 'by_role', c.by_role, 'from_import', c.from_import);
$$;

-- Everything the directory screens need in one call.
create or replace function chpms_directory() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_role text := chpms_require(false);
begin
  return jsonb_build_object(
    'role', v_role,
    'can_edit', v_role = 'staff',
    'can_act', v_role in ('staff', 'field', 'navigator') and not autopay_view_as_session(),
    'view_as', autopay_view_as_session(),
    'version', condo_setting('chpms_version', ''),
    'readme', condo_setting('chpms_readme', ''),
    'orgs', coalesce((select jsonb_agg(to_jsonb(o) - 'staff_edited_by' - 'our_checked_by' || jsonb_build_object(
        'last_check', (select chpms_check_json(c) from chpms_checks c where c.record_type = 'org' and c.record_id = o.org_id and not c.from_import
                        order by c.checked_on desc, c.id desc limit 1),
        'programs', coalesce((select jsonb_agg(to_jsonb(p) - 'staff_edited_by' || jsonb_build_object(
            'assist', coalesce((select jsonb_agg(a.category order by a.category) from chpms_program_assist a where a.program_id = p.program_id and a.provided), '[]'::jsonb),
            'pops', coalesce((select jsonb_agg(x.population order by x.population) from chpms_program_pops x where x.program_id = p.program_id), '[]'::jsonb),
            'eligibility', coalesce((select jsonb_agg(jsonb_build_object('type', e.requirement_type, 'requirement', e.requirement, 'source', e.source_id) order by e.elig_id)
                                     from chpms_eligibility e where e.program_id = p.program_id), '[]'::jsonb),
            'last_check', (select chpms_check_json(c) from chpms_checks c where c.record_type = 'program' and c.record_id = p.program_id and not c.from_import
                            order by c.checked_on desc, c.id desc limit 1))
            order by p.program_name) from chpms_programs p where p.org_id = o.org_id), '[]'::jsonb),
        'contacts', coalesce((select jsonb_agg(to_jsonb(k) order by k.contact_id) from chpms_contacts k where k.org_id = o.org_id), '[]'::jsonb),
        'landlord', (select to_jsonb(l) from chpms_landlord l where l.org_id = o.org_id),
        'links_out', coalesce((select jsonb_agg(jsonb_build_object('org_id', r.to_org, 'relationship', r.relationship, 'source_ids', r.source_ids) order by r.rel_id)
                               from chpms_org_links r where r.from_org = o.org_id), '[]'::jsonb),
        'links_in', coalesce((select jsonb_agg(jsonb_build_object('org_id', r.from_org, 'relationship', r.relationship, 'source_ids', r.source_ids) order by r.rel_id)
                              from chpms_org_links r where r.to_org = o.org_id), '[]'::jsonb))
      order by o.legal_name) from chpms_orgs o), '[]'::jsonb),
    'sources', coalesce((select jsonb_object_agg(s.source_id, jsonb_build_object('title', s.title, 'url', s.url, 'publisher', s.publisher, 'type', s.source_type))
                         from chpms_sources s), '{}'::jsonb),
    'my_people', case when v_role = 'navigator' then coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'name', trim(r.first_name || ' ' || coalesce(r.last_name, '')),
        'phone', r.phone, 'email', r.email, 'household_size', r.household_size, 'veteran', r.veteran) order by r.first_name)
        from nav_referrals r where r.navigator_id = nav_me() and r.status <> 'closed' and r.consent_withdrawn_on is null), '[]'::jsonb) else '[]'::jsonb end
  );
end $$;

-- Population pathways, funding map, gaps and the research logs (the "About the data" and "Pathways" screens).
create or replace function chpms_extras() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform chpms_require(false);
  return jsonb_build_object(
    'pathways', coalesce((select jsonb_agg(to_jsonb(p) order by p.population, p.step) from chpms_pathways p), '[]'::jsonb),
    'funding', coalesce((select jsonb_agg(to_jsonb(f) order by f.funding_id) from chpms_funding f), '[]'::jsonb),
    'gaps', coalesce((select jsonb_agg(to_jsonb(g) order by g.seq) from chpms_gaps g), '[]'::jsonb),
    'log', coalesce((select jsonb_agg(to_jsonb(l) order by l.seq) from chpms_research_log l), '[]'::jsonb),
    'checks_recent', coalesce((select jsonb_agg(x order by (x->>'id')::bigint desc) from (
        select chpms_check_json(c) || jsonb_build_object('record_type', c.record_type, 'record_id', c.record_id) x
        from chpms_checks c where not c.from_import order by c.id desc limit 50) s), '[]'::jsonb));
end $$;

-- Full verification history of one organization or program (research rows and every later check).
create or replace function chpms_history(p_type text, p_id text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform chpms_require(false);
  return coalesce((select jsonb_agg(chpms_check_json(c) order by c.checked_on desc, c.id desc)
                   from chpms_checks c where c.record_type = p_type and c.record_id = p_id), '[]'::jsonb);
end $$;

-- ---------------------------------------------------------------- logging a check (staff, field staff, Navigators)
create or replace function chpms_check_log(p jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_role text := chpms_require(true); v_type text := p->>'record_type'; v_rec text := p->>'record_id'; v_id bigint;
        v_on date := coalesce(nullif(p->>'checked_on', '')::date, current_date); v_org text;
begin
  if v_type = 'org' then select org_id into v_org from chpms_orgs where org_id = v_rec;
  elsif v_type = 'program' then select org_id into v_org from chpms_programs where program_id = v_rec;
  else raise exception 'Unknown record type'; end if;
  if v_org is null then raise exception 'That organization or program is not in the directory.'; end if;
  if v_on > current_date then raise exception 'The date of the check cannot be in the future.'; end if;
  if v_on < current_date - 60 then raise exception 'Log checks within 60 days of making them.'; end if;
  if nullif(p->>'result', '') is null then raise exception 'Choose what you found out.'; end if;
  if length(coalesce(p->>'notes', '')) > 2000 then raise exception 'Notes are too long (2,000 characters at most).'; end if;
  if (select count(*) from chpms_checks where lower(by_email) = lower(auth.email()) and created_at > now() - interval '1 day') >= 100 then
    raise exception 'That is 100 checks in a day; try again tomorrow or ask the office.';
  end if;
  insert into chpms_checks (record_type, record_id, checked_on, result, funds_today, method, notes, by_email, by_name, by_role)
  values (v_type, v_rec, v_on, p->>'result', nullif(p->>'funds_today', ''), nullif(trim(p->>'method'), ''), nullif(trim(p->>'notes'), ''),
          lower(auth.email()), chpms_my_name(), v_role)
  returning id into v_id;
  if v_role = 'staff' then
    update chpms_orgs set our_checked_on = greatest(coalesce(our_checked_on, v_on), v_on), our_checked_by = chpms_my_name(), updated_at = now() where org_id = v_org;
  end if;
  return v_id;
end $$;

-- ---------------------------------------------------------------- office edits (staff only)
create or replace function chpms_org_save(p jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare v_role text := chpms_require(true); v_id text := nullif(trim(p->>'org_id'), ''); o chpms_orgs; n chpms_orgs; v_changed text[] := '{}';
begin
  if v_role <> 'staff' then raise exception 'Only the office edits the directory. Use "Log a check" to report what you found out.' using errcode = '42501'; end if;
  if coalesce(trim(p->>'legal_name'), '') = '' then raise exception 'The organization''s name is required.'; end if;
  if coalesce(p->>'verification_status', 'Needs Confirmation') not in ('Verified – Current', 'Verified – Limited', 'Verified – Limited (imported)', 'Needs Confirmation', 'Unverified Lead', 'Inactive/Expired') then
    raise exception 'Unknown verification status'; end if;
  if v_id is null then
    v_id := 'L-ORG' || lpad(nextval('chpms_local_seq')::text, 3, '0');
    insert into chpms_orgs (org_id, legal_name, is_local, provenance, date_accessed) values (v_id, trim(p->>'legal_name'), true, 'Added by the office', current_date);
  end if;
  select * into o from chpms_orgs where org_id = v_id;
  if o.org_id is null then raise exception 'Organization not found.'; end if;
  update chpms_orgs set
    legal_name = trim(p->>'legal_name'), dba = nullif(trim(p->>'dba'), ''), org_type = nullif(trim(p->>'org_type'), ''),
    website = nullif(trim(p->>'website'), ''), physical_address = nullif(trim(p->>'physical_address'), ''), main_phone = nullif(trim(p->>'main_phone'), ''),
    general_email = nullif(trim(p->>'general_email'), ''), service_area = nullif(trim(p->>'service_area'), ''), languages = nullif(trim(p->>'languages'), ''),
    accepts_outside_referrals = nullif(trim(p->>'accepts_outside_referrals'), ''),
    verification_status = coalesce(nullif(p->>'verification_status', ''), verification_status), verification_notes = nullif(trim(p->>'verification_notes'), ''),
    our_relationship = coalesce(nullif(p->>'our_relationship', ''), our_relationship), our_note = nullif(trim(p->>'our_note'), ''), updated_at = now()
  where org_id = v_id returning * into n;
  select array_agg(k) into v_changed from jsonb_each(to_jsonb(n)) e(k, v)
   where k in ('legal_name', 'dba', 'org_type', 'website', 'physical_address', 'main_phone', 'general_email', 'service_area', 'languages',
               'accepts_outside_referrals', 'verification_status', 'verification_notes') and v is distinct from to_jsonb(o)->k;
  if coalesce(array_length(v_changed, 1), 0) > 0 then
    update chpms_orgs set staff_edited_at = now(), staff_edited_by = chpms_my_name() where org_id = v_id;
    insert into chpms_checks (record_type, record_id, status, method, notes, by_email, by_name, by_role)
    values ('org', v_id, n.verification_status, 'Office edit', 'Changed: ' || array_to_string(v_changed, ', '), lower(auth.email()), chpms_my_name(), 'staff');
  end if;
  return v_id;
end $$;

create or replace function chpms_program_save(p jsonb) returns text
language plpgsql security definer set search_path = public as $$
declare v_role text := chpms_require(true); v_id text := nullif(trim(p->>'program_id'), ''); o chpms_programs; n chpms_programs; v_changed text[] := '{}';
        v_assist_before text; v_pops_before text;
begin
  if v_role <> 'staff' then raise exception 'Only the office edits the directory. Use "Log a check" to report what you found out.' using errcode = '42501'; end if;
  if coalesce(trim(p->>'program_name'), '') = '' then raise exception 'The program''s name is required.'; end if;
  if coalesce(p->>'verification_status', 'Needs Confirmation') not in ('Verified – Current', 'Verified – Limited', 'Verified – Limited (imported)', 'Needs Confirmation', 'Unverified Lead', 'Inactive/Expired') then
    raise exception 'Unknown verification status'; end if;
  if v_id is null then
    if not exists (select 1 from chpms_orgs where org_id = p->>'org_id') then raise exception 'Organization not found.'; end if;
    v_id := 'L-PRG' || lpad(nextval('chpms_local_seq')::text, 3, '0');
    insert into chpms_programs (program_id, org_id, program_name, is_local, provenance, date_accessed) values (v_id, p->>'org_id', trim(p->>'program_name'), true, 'Added by the office', current_date);
    insert into chpms_program_assist (program_id, category, provided)
      select v_id, c, false from unnest(array['Emergency rental assistance', 'Monthly rental assistance', 'Security deposit assistance', 'First month''s rent',
        'Last month''s rent', 'Eviction prevention', 'Utility assistance', 'Moving expenses', 'Furniture and household items', 'Transitional housing',
        'Permanent housing', 'Housing vouchers', 'Rapid rehousing', 'Supportive housing', 'Case management', 'Housing navigation', 'Landlord mediation',
        'Financial counseling', 'Benefits enrollment', 'Other housing support']) c;
  end if;
  select * into o from chpms_programs where program_id = v_id;
  if o.program_id is null then raise exception 'Program not found.'; end if;
  select string_agg(category, ',' order by category) into v_assist_before from chpms_program_assist where program_id = v_id and provided;
  select string_agg(population, ',' order by population) into v_pops_before from chpms_program_pops where program_id = v_id;
  update chpms_programs set
    program_name = trim(p->>'program_name'), assistance_form = nullif(trim(p->>'assistance_form'), ''), payment_goes_to = nullif(trim(p->>'payment_goes_to'), ''),
    max_assistance = nullif(trim(p->>'max_assistance'), ''), months_covered = nullif(trim(p->>'months_covered'), ''), frequency = nullif(trim(p->>'frequency'), ''),
    current_status = nullif(trim(p->>'current_status'), ''), waiting_list = nullif(trim(p->>'waiting_list'), ''), application_window = nullif(trim(p->>'application_window'), ''),
    income_limits = nullif(trim(p->>'income_limits'), ''), eligibility_summary = nullif(trim(p->>'eligibility_summary'), ''), how_to_apply = nullif(trim(p->>'how_to_apply'), ''),
    referral_requirement = nullif(trim(p->>'referral_requirement'), ''), application_url = nullif(trim(p->>'application_url'), ''), intake_phone = nullif(trim(p->>'intake_phone'), ''),
    is_direct_financial = coalesce((p->>'is_direct_financial')::boolean, is_direct_financial),
    verification_status = coalesce(nullif(p->>'verification_status', ''), verification_status), notes = nullif(trim(p->>'notes'), ''),
    our_note = nullif(trim(p->>'our_note'), ''), updated_at = now()
  where program_id = v_id returning * into n;
  if p ? 'assist' then
    update chpms_program_assist set provided = category in (select jsonb_array_elements_text(p->'assist')) where program_id = v_id;
  end if;
  if p ? 'pops' then
    delete from chpms_program_pops where program_id = v_id;
    insert into chpms_program_pops (program_id, population) select v_id, x from jsonb_array_elements_text(p->'pops') x on conflict do nothing;
  end if;
  select array_agg(k) into v_changed from jsonb_each(to_jsonb(n)) e(k, v)
   where k in ('program_name', 'assistance_form', 'payment_goes_to', 'max_assistance', 'months_covered', 'frequency', 'current_status', 'waiting_list',
               'application_window', 'income_limits', 'eligibility_summary', 'how_to_apply', 'referral_requirement', 'application_url', 'intake_phone',
               'is_direct_financial', 'verification_status', 'notes') and v is distinct from to_jsonb(o)->k;
  if coalesce((select string_agg(category, ',' order by category) from chpms_program_assist where program_id = v_id and provided), '') <> coalesce(v_assist_before, '') then
    v_changed := array_append(coalesce(v_changed, '{}'), 'kinds of help'); end if;
  if coalesce((select string_agg(population, ',' order by population) from chpms_program_pops where program_id = v_id), '') <> coalesce(v_pops_before, '') then
    v_changed := array_append(coalesce(v_changed, '{}'), 'who it serves'); end if;
  if coalesce(array_length(v_changed, 1), 0) > 0 then
    update chpms_programs set staff_edited_at = now(), staff_edited_by = chpms_my_name() where program_id = v_id;
    insert into chpms_checks (record_type, record_id, status, method, notes, by_email, by_name, by_role)
    values ('program', v_id, n.verification_status, 'Office edit', 'Changed: ' || array_to_string(v_changed, ', '), lower(auth.email()), chpms_my_name(), 'staff');
  end if;
  return v_id;
end $$;

-- Only rows the office added can be deleted; workbook rows are marked Inactive/Expired instead.
create or replace function chpms_delete_local(p_kind text, p_id text) returns void
language plpgsql security definer set search_path = public as $$
declare v_role text := chpms_require(true);
begin
  if v_role <> 'staff' then raise exception 'Only the office edits the directory.' using errcode = '42501'; end if;
  if p_kind = 'org' then
    if not exists (select 1 from chpms_orgs where org_id = p_id and is_local) then raise exception 'Only organizations the office added can be deleted; mark this one Inactive/Expired instead.'; end if;
    delete from chpms_orgs where org_id = p_id;
  elsif p_kind = 'program' then
    if not exists (select 1 from chpms_programs where program_id = p_id and is_local) then raise exception 'Only programs the office added can be deleted; mark this one Inactive/Expired instead.'; end if;
    delete from chpms_programs where program_id = p_id;
  else raise exception 'Unknown kind'; end if;
end $$;

-- ---------------------------------------------------------------- referrals to outside programs
create or replace function chpms_ref_can(r chpms_referrals) returns boolean
language sql stable security definer set search_path = public as $$
  select staff_session_staff() or (chpms_role() in ('field', 'navigator', 'navigator_preview') and lower(r.made_by_email) = lower(auth.email()));
$$;

create or replace function chpms_ref_event(p_ref uuid, p_action text, p_detail text) returns void
language sql security definer set search_path = public as $$
  insert into chpms_referral_events (referral_id, actor_email, actor_name, actor_role, action, detail)
  values (p_ref, lower(auth.email()), chpms_my_name(), chpms_role(), p_action, p_detail);
$$;

create or replace function chpms_referral_json(r chpms_referrals, p_full boolean) returns jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(r) - 'made_by_email' || jsonb_build_object(
    'mine', lower(r.made_by_email) = lower(auth.email()),
    'org', (select jsonb_build_object('org_id', o.org_id, 'legal_name', o.legal_name, 'main_phone', o.main_phone, 'general_email', o.general_email,
                                      'website', o.website, 'physical_address', o.physical_address) from chpms_orgs o where o.org_id = r.org_id),
    'program', (select jsonb_build_object('program_id', p.program_id, 'program_name', p.program_name, 'intake_phone', p.intake_phone,
                                          'application_url', p.application_url, 'how_to_apply', p.how_to_apply, 'current_status', p.current_status)
                from chpms_programs p where p.program_id = r.program_id),
    'events', case when p_full then coalesce((select jsonb_agg(jsonb_build_object('at', e.at, 'by', e.actor_name, 'role', e.actor_role, 'action', e.action, 'detail', e.detail) order by e.at, e.id)
                                              from chpms_referral_events e where e.referral_id = r.id), '[]'::jsonb) else null end);
$$;

create or replace function chpms_referral_save(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_role text := chpms_require(true); v_id uuid := nullif(p->>'id', '')::uuid; r chpms_referrals; o chpms_orgs; pr chpms_programs;
        v_nav uuid := nullif(p->>'nav_referral_id', '')::uuid; v_help text[]; v_new boolean := false;
begin
  select * into o from chpms_orgs where org_id = p->>'org_id';
  if o.org_id is null then raise exception 'Pick the organization you are referring to.'; end if;
  if nullif(p->>'program_id', '') is not null then
    select * into pr from chpms_programs where program_id = p->>'program_id' and org_id = o.org_id;
    if pr.program_id is null then raise exception 'That program does not belong to this organization.'; end if;
  end if;
  if o.our_relationship = 'do_not_refer' then raise exception 'The office has marked % "Do not refer". Ask the office first.', o.legal_name; end if;
  if coalesce(trim(p->>'first_name'), '') = '' or coalesce(trim(p->>'last_name'), '') = '' then raise exception 'First and last name are required.'; end if;
  if coalesce(trim(p->>'phone'), '') = '' and coalesce(trim(p->>'email'), '') = '' then raise exception 'Give a phone number or an email so the program can reach the person.'; end if;
  if coalesce(trim(p->>'email'), '') <> '' and trim(p->>'email') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'That email address does not look right.'; end if;
  if coalesce((p->>'consent')::boolean, false) is not true or coalesce(trim(p->>'consent_name'), '') = '' then
    raise exception 'The person must agree to the referral and type their own name.';
  end if;
  if length(coalesce(p->>'notes', '')) > 2000 then raise exception 'Notes are too long (2,000 characters at most).'; end if;
  select coalesce(array_agg(x), '{}') into v_help from jsonb_array_elements_text(coalesce(p->'help_needed', '[]'::jsonb)) x
   where x in ('Emergency rental assistance', 'Monthly rental assistance', 'Security deposit assistance', 'First month''s rent', 'Last month''s rent',
               'Eviction prevention', 'Utility assistance', 'Moving expenses', 'Furniture and household items', 'Transitional housing', 'Permanent housing',
               'Housing vouchers', 'Rapid rehousing', 'Supportive housing', 'Case management', 'Housing navigation', 'Landlord mediation',
               'Financial counseling', 'Benefits enrollment', 'Other housing support');
  if v_nav is not null then
    if v_role = 'navigator' and not exists (select 1 from nav_referrals where id = v_nav and navigator_id = nav_me()) then raise exception 'That person is not one of yours.'; end if;
    if v_role = 'field' then v_nav := null; end if;
  end if;
  if v_id is null then
    if (select count(*) from chpms_referrals where lower(made_by_email) = lower(auth.email()) and created_at > now() - interval '1 day') >= 30 then
      raise exception 'That is 30 referrals in a day; ask the office if you need more.';
    end if;
    insert into chpms_referrals (org_id, program_id, org_name, program_name, made_by_email, made_by_name, made_by_role, navigator_id, nav_referral_id,
                                 first_name, last_name, consent_name, consent_on)
    values (o.org_id, pr.program_id, o.legal_name, pr.program_name, lower(auth.email()), chpms_my_name(), v_role,
            case when v_role = 'navigator' then nav_me() else (select navigator_id from nav_referrals where id = v_nav) end, v_nav,
            trim(p->>'first_name'), trim(p->>'last_name'), trim(p->>'consent_name'), current_date)
    returning id into v_id;
    v_new := true;
  end if;
  select * into r from chpms_referrals where id = v_id;
  if r.id is null or not chpms_ref_can(r) then raise exception 'Not found.' using errcode = '42501'; end if;
  if not v_new and r.status <> 'new' then raise exception 'This referral has been sent; add a note instead of changing it.'; end if;
  update chpms_referrals set org_id = o.org_id, program_id = pr.program_id, org_name = o.legal_name, program_name = pr.program_name,
    nav_referral_id = coalesce(v_nav, nav_referral_id),
    first_name = trim(p->>'first_name'), last_name = trim(p->>'last_name'), phone = nullif(trim(p->>'phone'), ''), email = nullif(lower(trim(p->>'email')), ''),
    household_size = nullif(p->>'household_size', '')::int, population = nullif(trim(p->>'population'), ''), help_needed = v_help,
    notes = nullif(trim(p->>'notes'), ''), consent_name = trim(p->>'consent_name'),
    status_checked_on = nullif(p->>'status_checked_on', '')::date, updated_at = now()
  where id = v_id;
  perform chpms_ref_event(v_id, case when v_new then 'created' else 'edited' end,
    o.legal_name || coalesce(' / ' || pr.program_name, '') || case when v_new then '. Consent given by ' || trim(p->>'consent_name') || ' on ' || to_char(current_date, 'MM/DD/YYYY') else '' end);
  if v_new and r.nav_referral_id is not null then
    perform nav_log('outside_referral', 'Referred to ' || o.legal_name || coalesce(' / ' || pr.program_name, '') || ' (resource directory referral #' || r.ref_no || ')', r.nav_referral_id);
  end if;
  -- The office hears about referrals made by field staff and Navigators (no phone or email of the person in the email).
  if v_new and v_role <> 'staff' then
    perform nav_email('info@2ndchinc.org', 'Resource referral #' || r.ref_no || ': ' || o.legal_name,
      '<p>' || repair_esc(chpms_my_name()) || ' (' || case v_role when 'navigator' then 'Housing Navigator' else 'field staff' end || ') referred '
      || repair_esc(trim(p->>'first_name')) || ' ' || repair_esc(left(trim(p->>'last_name'), 1)) || '. to <b>' || repair_esc(o.legal_name) || '</b>'
      || coalesce(' (' || repair_esc(pr.program_name) || ')', '') || '.</p>'
      || case when cardinality(v_help) > 0 then '<p>Help needed: ' || repair_esc(array_to_string(v_help, ', ')) || '</p>' else '' end
      || '<p>Open it at <a href="https://2ndchinc.org/staff/resources/#referrals/' || v_id || '">https://2ndchinc.org/staff/resources/#referrals/' || v_id || '</a></p>',
      'chpms_referral');
  end if;
  return v_id;
end $$;

-- Move a referral along: sent, in_process, approved, denied, closed, withdrawn, reopen, note.
create or replace function chpms_referral_step(p_id uuid, p_action text, p jsonb default '{}'::jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare v_role text := chpms_require(true); r chpms_referrals; v_detail text := nullif(trim(p->>'note'), ''); v_amt int;
begin
  select * into r from chpms_referrals where id = p_id;
  if r.id is null or not chpms_ref_can(r) then raise exception 'Not found.' using errcode = '42501'; end if;
  if length(coalesce(v_detail, '')) > 2000 then raise exception 'The note is too long (2,000 characters at most).'; end if;
  if r.status in ('closed', 'withdrawn') and p_action not in ('note', 'reopen') then raise exception 'This referral is closed. Reopen it first.'; end if;
  if p_action = 'sent' then
    if coalesce(p->>'sent_how', '') not in ('email', 'phone', 'online', 'walk_in', 'fax', 'other') then raise exception 'How was it sent?'; end if;
    update chpms_referrals set status = 'sent', sent_how = p->>'sent_how', sent_on = coalesce(nullif(p->>'sent_on', '')::date, current_date), updated_at = now() where id = p_id;
    v_detail := 'Sent by ' || replace(p->>'sent_how', '_', '-') || ' on ' || to_char(coalesce(nullif(p->>'sent_on', '')::date, current_date), 'MM/DD/YYYY') || coalesce('. ' || v_detail, '');
  elsif p_action = 'in_process' then
    update chpms_referrals set status = 'in_process', updated_at = now() where id = p_id;
  elsif p_action = 'approved' then
    v_amt := case when coalesce(p->>'amount', '') ~ '^\d+(\.\d{1,2})?$' then round((p->>'amount')::numeric * 100)::int end;
    update chpms_referrals set status = 'approved', approved_amount_cents = v_amt, outcome_note = coalesce(v_detail, outcome_note), updated_at = now() where id = p_id;
    v_detail := 'Approved' || coalesce(' for $' || to_char(v_amt / 100.0, 'FM999,990.00'), '') || coalesce('. ' || v_detail, '');
  elsif p_action = 'denied' then
    update chpms_referrals set status = 'denied', outcome_note = coalesce(v_detail, outcome_note), updated_at = now() where id = p_id;
  elsif p_action in ('closed', 'withdrawn') then
    update chpms_referrals set status = p_action, closed_reason = coalesce(v_detail, closed_reason), closed_at = now(), updated_at = now() where id = p_id;
  elsif p_action = 'reopen' then
    if r.status not in ('closed', 'withdrawn') then raise exception 'It is not closed.'; end if;
    update chpms_referrals set status = case when r.sent_on is not null then 'sent' else 'new' end, closed_at = null, updated_at = now() where id = p_id;
  elsif p_action = 'note' then
    if v_detail is null then raise exception 'Write the note first.'; end if;
  else raise exception 'Unknown step'; end if;
  perform chpms_ref_event(p_id, p_action, v_detail);
end $$;

create or replace function chpms_referrals_list() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_role text := chpms_require(false);
begin
  return coalesce((select jsonb_agg(chpms_referral_json(r, false) order by r.created_at desc) from chpms_referrals r
                   where v_role = 'staff' or lower(r.made_by_email) = lower(auth.email())), '[]'::jsonb);
end $$;

create or replace function chpms_referral_get(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r chpms_referrals;
begin
  perform chpms_require(false);
  select * into r from chpms_referrals where id = p_id;
  if r.id is null or not chpms_ref_can(r) then raise exception 'Not found.' using errcode = '42501'; end if;
  return chpms_referral_json(r, true);
end $$;

-- ---------------------------------------------------------------- function grants
revoke all on function chpms_role(), chpms_require(boolean), chpms_my_name(), chpms_check_json(chpms_checks), chpms_directory(), chpms_extras(),
  chpms_history(text, text), chpms_check_log(jsonb), chpms_org_save(jsonb), chpms_program_save(jsonb), chpms_delete_local(text, text),
  chpms_ref_can(chpms_referrals), chpms_ref_event(uuid, text, text), chpms_referral_json(chpms_referrals, boolean), chpms_referral_save(jsonb),
  chpms_referral_step(uuid, text, jsonb), chpms_referrals_list(), chpms_referral_get(uuid) from public, anon;
grant execute on function chpms_directory(), chpms_extras(), chpms_history(text, text), chpms_check_log(jsonb), chpms_org_save(jsonb),
  chpms_program_save(jsonb), chpms_delete_local(text, text), chpms_referral_save(jsonb), chpms_referral_step(uuid, text, jsonb),
  chpms_referrals_list(), chpms_referral_get(uuid) to authenticated;
-- Helpers stay internal (called only from the functions above, which run as their owner).
revoke all on function chpms_role(), chpms_require(boolean), chpms_my_name(), chpms_check_json(chpms_checks), chpms_ref_can(chpms_referrals),
  chpms_ref_event(uuid, text, text), chpms_referral_json(chpms_referrals, boolean) from authenticated;
