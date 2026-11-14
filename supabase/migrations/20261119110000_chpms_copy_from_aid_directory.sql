-- Copy into the CHPMS housing resource directory everything the 11/11 rental assistance directory (aid_orgs / aid_programs,
-- https://2ndchinc.org/staff/aid/) has that the research workbook v2 does not (Stephen, 11/12/2026: "Yes please; before retiring
-- we will again do an audit of the information"). The old directory is NOT retired here and its tables are not changed.
--
-- Compared record by record on 11/12: 73 of the old 100 organizations are already in CHPMS. Copied here:
--   * 27 organizations that are only in the old directory, with their programs;
--   * 4 programs the old directory has at organizations CHPMS already lists (J-Help, DV Housing First, Reentry Housing Assistance,
--     Energy emergency grant);
--   * 4 old "organizations" that are really programs of CHPMS organizations (Housing Trust Fund, Landlord Training / Rent for Success,
--     Medicaid Housing Support Services, Refugee Resettlement);
--   * the office's notes (Legal Aid, Mediate Wisconsin, City rental assistance) and the "Do not refer" mark on SDC.
-- Every copied row is office-added (is_local) and its provenance says "Copied from the 11/11 rental assistance directory (code)",
-- so the audit can list exactly these (Find help > Show > Copied from the 11/11 directory). The facts are copied as they were;
-- nothing is re-researched or estimated. Office-added rows are never touched by a workbook import.

-- ---------- helpers for this copy (dropped at the end)
create or replace function pg_temp.ver(v text) returns text language sql immutable as $$
  select case v when 'verified_current' then 'Verified – Current' when 'verified_limited' then 'Verified – Limited'
    when 'needs_confirmation' then 'Needs Confirmation' when 'inactive' then 'Inactive/Expired' else 'Unverified Lead' end $$;
create or replace function pg_temp.status(v text) returns text language sql immutable as $$
  select case v when 'open' then 'Open (11/11 directory)' when 'limited' then 'Limited (11/11 directory)' when 'referral_only' then 'Referral only (11/11 directory)'
    when 'paused' then 'Paused (11/11 directory)' when 'inactive' then 'Inactive (11/11 directory)' else 'Unclear (11/11 directory)' end $$;
create or replace function pg_temp.pop(v text) returns text language sql immutable as $$
  select case v when 'veterans' then 'Veterans' when 'families' then 'Families with children' when 'seniors' then 'Seniors'
    when 'disability' then 'Disabilities' when 'reentry' then 'Returning citizens' end $$;
create or replace function pg_temp.help(v text) returns text language sql immutable as $$
  select case v when 'rent' then 'Emergency rental assistance' when 'arrears' then 'Eviction prevention' when 'deposit' then 'Security deposit assistance'
    when 'first_month' then 'First month''s rent' when 'utility' then 'Utility assistance' when 'voucher' then 'Housing vouchers'
    when 'rrh' then 'Rapid rehousing' when 'psh' then 'Supportive housing' when 'mediation' then 'Landlord mediation'
    when 'legal' then 'Other housing support' when 'landlord_risk' then 'Other housing support' when 'flexible' then 'Other housing support'
    when 'loan' then 'Other housing support' end $$;
-- The old directory's people tags that CHPMS has no group for are kept in words.
create or replace function pg_temp.pop_words(p text[]) returns text language sql immutable as $$
  select nullif(array_to_string(array(select case x when 'youth' then 'youth' when 'dv' then 'domestic violence survivors' when 'hiv' then 'people with HIV'
    when 'immigrant' then 'immigrants and refugees' when 'native' then 'Native American' when 'lgbtq' then 'LGBTQ+' end from unnest(p) x
    where x in ('youth', 'dv', 'hiv', 'immigrant', 'native', 'lgbtq')), ', '), '') $$;

-- ---------- 27 organizations only in the old directory
create temp table cp_orgs (code text primary key);
insert into cp_orgs values ('MKE-054'), ('MKE-055'), ('MKE-056'), ('MKE-058'), ('MKE-061'), ('MKE-062'), ('MKE-064'), ('MKE-065'), ('MKE-066'),
  ('MKE-068'), ('MKE-069'), ('MKE-074'), ('MKE-076'), ('MKE-077'), ('MKE-079'), ('MKE-080'), ('MKE-082'), ('MKE-084'), ('MKE-085'), ('MKE-087'),
  ('MKE-088'), ('MKE-090'), ('MKE-091'), ('WI-005'), ('WI-006'), ('WI-007'), ('WI-008');
do $$ begin
  if (select count(*) from aid_orgs where code in (select code from cp_orgs)) <> 27 then raise exception 'Expected 27 old organizations to copy'; end if;
end $$;

insert into chpms_orgs (org_id, legal_name, org_type, classifications, website, physical_address, main_phone, service_area,
  verification_status, verification_notes, primary_source_url, provenance, date_accessed, is_local, our_relationship, our_note, import_version)
select 'AID-' || a.code, a.name,
  null,
  'Kinds (11/11 directory): ' || coalesce(nullif(array_to_string(a.kinds, ', '), ''), 'not set') || coalesce('. Serves: ' || nullif(array_to_string(a.populations, ', '), ''), ''),
  a.website, a.address, a.phone,
  case a.region when 'wisconsin' then 'Wisconsin (statewide)' when 'milwaukee' then 'Milwaukee' else initcap(a.region) end,
  pg_temp.ver(a.verification), a.summary, a.source_url,
  'Copied from the 11/11 rental assistance directory (' || a.code || coalesce('; ' || a.source_note, '') || ')',
  a.created_at::date, true, a.relationship, a.staff_note, 'aid-11/11'
from aid_orgs a where a.code in (select code from cp_orgs)
on conflict (org_id) do nothing;

-- ---------- programs to copy: every program of those 27, plus 4 programs at organizations CHPMS already has
create temp table cp_progs (aid_id uuid primary key, org_id text not null, program_id text not null, extra_note text);
insert into cp_progs
select p.id, 'AID-' || o.code, 'AID-' || o.code || '-P' || row_number() over (partition by o.code order by p.name), null
from aid_programs p join aid_orgs o on o.id = p.org_id where o.code in (select code from cp_orgs);
insert into cp_progs
select p.id, v.target, 'AID-' || o.code || '-P' || row_number() over (partition by o.code order by p.name), v.note
from aid_programs p join aid_orgs o on o.id = p.org_id
join (values ('MKE-060', 'J-Help', 'ORG080', null),
             ('MKE-070', 'DV Housing First', 'ORG023', 'May be the same program the research lists here as "Asha flexible financial assistance with wraparound"; the audit should keep one.'),
             ('MKE-072', 'Reentry Housing Assistance', 'ORG051', 'May be the same program the research lists here as "My Way Out housing placement & wraparound"; the audit should keep one.'),
             ('WI-009', 'Energy emergency grant', 'ORG067', null)) v(code, name, target, note) on v.code = o.code and v.name = p.name;
do $$ begin
  if (select count(*) from cp_progs) <> 6 then raise exception 'Expected 6 old programs to copy, found %', (select count(*) from cp_progs); end if;
  if exists (select 1 from cp_progs c where not exists (select 1 from chpms_orgs o where o.org_id = c.org_id)) then raise exception 'A target organization is missing'; end if;
end $$;

insert into chpms_programs (program_id, org_id, program_name, payment_goes_to, max_assistance, current_status, eligibility_summary, how_to_apply,
  application_url, is_direct_financial, amount_publicly_disclosed, verification_status, notes, provenance, date_accessed, is_local, import_version)
select c.program_id, c.org_id, p.name, p.pays_to,
  case when p.max_amount_cents is not null then 'Up to ' || to_char(p.max_amount_cents / 100.0, 'FM$999,990') || ' (as published; 11/11 directory)' else 'Not publicly disclosed' end,
  pg_temp.status(p.status) || case when p.funds_today <> 'unknown' then '; money today: ' || p.funds_today else '' end,
  p.terms, p.how_to_apply, null,
  p.help_types && array['rent', 'arrears', 'deposit', 'first_month', 'utility', 'flexible', 'loan', 'landlord_risk', 'voucher', 'rrh'],
  case when p.max_amount_cents is not null then 'Yes' else 'No' end,
  pg_temp.ver(o.verification),
  nullif(concat_ws(' ', p.note, c.extra_note, case when p.source_url is not null then 'Source: ' || p.source_url end,
    case when pg_temp.pop_words(p.populations) is not null then 'For: ' || pg_temp.pop_words(p.populations) || '.' end), ''),
  'Copied from the 11/11 rental assistance directory (' || o.code || ')', p.created_at::date, true, 'aid-11/11'
from cp_progs c join aid_programs p on p.id = c.aid_id join aid_orgs o on o.id = p.org_id
on conflict (program_id) do nothing;

-- ---------- 4 old "organizations" that are programs of organizations CHPMS already has
insert into chpms_programs (program_id, org_id, program_name, current_status, eligibility_summary, max_assistance, is_direct_financial,
  amount_publicly_disclosed, verification_status, notes, provenance, date_accessed, is_local, import_version)
select 'AID-' || a.code || '-P1', v.target, v.name, 'Not stated (11/11 directory)', a.summary, 'Not publicly disclosed', false, 'No',
  pg_temp.ver(a.verification),
  nullif(concat_ws(' ', a.staff_note, case when a.phone is not null then 'Phone: ' || a.phone || '.' end, case when a.website is not null then 'Website: ' || a.website || '.' end,
    case when a.source_url is not null then 'Source: ' || a.source_url end), ''),
  'Copied from the 11/11 rental assistance directory (' || a.code || ', listed there as its own organization: ' || a.name || ')', a.created_at::date, true, 'aid-11/11'
from aid_orgs a
join (values ('MKE-051', 'ORG003', 'Housing Trust Fund'),
             ('MKE-052', 'ORG069', 'Landlord Training Program / Rent for Success'),
             ('WI-003', 'ORG113', 'Medicaid Housing Support Services'),
             ('MKE-063', 'ORG081', 'Refugee Resettlement (Milwaukee)')) v(code, target, name) on v.code = a.code
on conflict (program_id) do nothing;

-- ---------- kinds of help and who it serves for every copied program
insert into chpms_program_assist (program_id, category, provided)
select p.program_id, c, false from chpms_programs p cross join unnest(array['Emergency rental assistance', 'Monthly rental assistance', 'Security deposit assistance',
  'First month''s rent', 'Last month''s rent', 'Eviction prevention', 'Utility assistance', 'Moving expenses', 'Furniture and household items', 'Transitional housing',
  'Permanent housing', 'Housing vouchers', 'Rapid rehousing', 'Supportive housing', 'Case management', 'Housing navigation', 'Landlord mediation',
  'Financial counseling', 'Benefits enrollment', 'Other housing support']) c
where p.import_version = 'aid-11/11'
on conflict do nothing;
update chpms_program_assist a set provided = true
from cp_progs c join aid_programs p on p.id = c.aid_id
where a.program_id = c.program_id and a.category in (select pg_temp.help(x) from unnest(p.help_types) x);
insert into chpms_program_pops (program_id, population)
select c.program_id, pg_temp.pop(x) from cp_progs c join aid_programs p on p.id = c.aid_id cross join unnest(p.populations) x
where pg_temp.pop(x) is not null
on conflict do nothing;
-- Program-shaped old organizations: tag them from the old organization's own tags.
update chpms_program_assist a set provided = true
from aid_orgs o where a.program_id = 'AID-' || o.code || '-P1' and o.code in ('MKE-051', 'MKE-052', 'WI-003', 'MKE-063')
  and a.category = case o.code when 'MKE-052' then 'Other housing support' when 'WI-003' then 'Housing navigation' when 'MKE-063' then 'Case management' end;
insert into chpms_program_pops (program_id, population)
select 'AID-' || o.code || '-P1', pg_temp.pop(x) from aid_orgs o cross join unnest(o.populations) x
where o.code in ('MKE-051', 'MKE-052', 'WI-003', 'MKE-063') and pg_temp.pop(x) is not null
on conflict do nothing;

-- ---------- office notes and marks (office fields only: a workbook import never changes these)
update chpms_orgs set our_note = concat_ws(E'\n', our_note, 'From the 11/11 directory: ' || (select staff_note from aid_orgs where code = 'MKE-024')) where org_id = 'ORG041';
update chpms_orgs set our_note = concat_ws(E'\n', our_note, 'From the 11/11 directory: ' || (select staff_note from aid_orgs where code = 'MKE-026')) where org_id = 'ORG043';
update chpms_orgs set our_relationship = 'do_not_refer',
  our_note = concat_ws(E'\n', our_note, 'From the 11/11 directory: Do not refer (Community Action Agency designation ended 11/18/2025; UMOS replaced it).') where org_id = 'ORG040';
update chpms_programs set our_note = concat_ws(E'\n', our_note, 'From the 11/11 directory (written before the 11/10/2026 reopening was found): '
  || (select p.note from aid_programs p join aid_orgs o on o.id = p.org_id where o.code = 'MKE-005' and p.name = 'City of Milwaukee rental assistance'))
where program_id = 'PRG001';

-- ---------- history: one line per copied organization or program, so the audit trail shows where it came from
insert into chpms_checks (record_type, record_id, checked_on, status, method, notes, by_role, from_import)
select 'org', org_id, current_date, verification_status, 'Copied from the 11/11 directory', provenance, 'research', true from chpms_orgs where import_version = 'aid-11/11'
union all
select 'program', program_id, current_date, verification_status, 'Copied from the 11/11 directory', provenance, 'research', true from chpms_programs where import_version = 'aid-11/11';

do $$ begin
  if (select count(*) from chpms_orgs where import_version = 'aid-11/11') <> 27 then raise exception 'Copy check: organizations'; end if;
  if (select count(*) from chpms_programs where import_version = 'aid-11/11') <> 10 then raise exception 'Copy check: programs (expected 10)'; end if;
end $$;

drop table cp_progs;
drop table cp_orgs;
