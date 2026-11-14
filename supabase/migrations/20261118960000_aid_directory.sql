-- Rental assistance directory (Stephen, 11/11/2026): every organization that has anything to do with rental assistance,
-- Milwaukee first, then Chicago. Staff page https://2ndchinc.org/staff/aid/ (read + edit); Housing Navigators may read it.
-- Rule from the research baseline: "the program exists" and "money is available to this household today" are separate fields,
-- and an amount that is not published stays NULL (never estimated).
-- Seeded from the research report pasted 11/11/2026 ("CHPMS Baseline v2.0"); last_checked stays NULL until staff confirm a row.

create table if not exists aid_orgs (
  id uuid primary key default gen_random_uuid(),
  code text unique,                                         -- e.g. MKE-001
  region text not null default 'milwaukee' check (region in ('milwaukee', 'chicago', 'wisconsin', 'illinois', 'national')),
  name text not null,
  kinds text[] not null default '{}',                       -- money, navigation, services, subsidy, access, housing, funder, legal, landlord
  populations text[] not null default '{}',                 -- general, veterans, families, youth, seniors, disability, dv, reentry, hiv, immigrant, native, lgbtq
  summary text,
  verification text not null default 'unverified_lead'
    check (verification in ('verified_current', 'verified_limited', 'needs_confirmation', 'inactive', 'unverified_lead')),
  relationship text not null default 'none' check (relationship in ('none', 'contacted', 'talking', 'partner', 'do_not_refer')),
  website text, phone text, address text,
  source_url text, source_note text,
  last_checked date,                                        -- when someone at 2nd Chance last confirmed it
  staff_note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table aid_orgs enable row level security;
grant select, insert, update, delete on aid_orgs to service_role;

create table if not exists aid_programs (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references aid_orgs(id) on delete cascade,
  name text not null,
  help_types text[] not null default '{}',                  -- rent, arrears, deposit, first_month, utility, voucher, rrh, psh, landlord_risk, flexible, loan, legal, mediation
  populations text[] not null default '{}',
  terms text,                                               -- published limits and rules, as written by the source
  max_amount_cents int,                                     -- NULL when not published; never estimated
  pays_to text,                                             -- landlord, utility, tenant, varies
  status text not null default 'unclear' check (status in ('open', 'limited', 'referral_only', 'paused', 'inactive', 'unclear')),
  funds_today text not null default 'unknown' check (funds_today in ('unknown', 'available', 'low', 'none')),
  how_to_apply text,
  source_url text,
  last_checked date,
  note text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists aid_programs_org on aid_programs (org_id);
alter table aid_programs enable row level security;
grant select, insert, update, delete on aid_programs to service_role;

-- Read: staff (two-step) or a signed-in Housing Navigator.
create or replace function aid_directory() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not ((condo_session_ok() and condo_is_staff()) or nav_me() is not null) then
    raise exception 'Staff or Navigator sign-in required' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'can_edit', condo_session_ok() and condo_is_staff(),
    'orgs', coalesce((select jsonb_agg(to_jsonb(o) || jsonb_build_object('programs',
        coalesce((select jsonb_agg(to_jsonb(p) order by p.name) from aid_programs p where p.org_id = o.id), '[]'::jsonb)) order by o.region, o.code nulls last, o.name)
      from aid_orgs o), '[]'::jsonb));
end $$;
revoke all on function aid_directory() from public, anon;
grant execute on function aid_directory() to authenticated;

-- Save an organization (insert when id is missing). Staff only.
create or replace function aid_org_save(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid := nullif(p->>'id', '')::uuid;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if coalesce(trim(p->>'name'), '') = '' then raise exception 'Name is required'; end if;
  if v_id is null then
    insert into aid_orgs (code, region, name) values (nullif(trim(p->>'code'), ''), coalesce(nullif(p->>'region', ''), 'milwaukee'), trim(p->>'name')) returning id into v_id;
  end if;
  update aid_orgs set
    code = nullif(trim(p->>'code'), ''), region = coalesce(nullif(p->>'region', ''), region), name = trim(p->>'name'),
    kinds = coalesce((select array_agg(x) from jsonb_array_elements_text(p->'kinds') x), kinds),
    populations = coalesce((select array_agg(x) from jsonb_array_elements_text(p->'populations') x), populations),
    summary = nullif(trim(p->>'summary'), ''), verification = coalesce(nullif(p->>'verification', ''), verification),
    relationship = coalesce(nullif(p->>'relationship', ''), relationship),
    website = nullif(trim(p->>'website'), ''), phone = nullif(trim(p->>'phone'), ''), address = nullif(trim(p->>'address'), ''),
    source_url = nullif(trim(p->>'source_url'), ''), source_note = nullif(trim(p->>'source_note'), ''),
    last_checked = nullif(p->>'last_checked', '')::date, staff_note = nullif(trim(p->>'staff_note'), ''), updated_at = now()
  where id = v_id;
  return v_id;
end $$;
revoke all on function aid_org_save(jsonb) from public, anon;
grant execute on function aid_org_save(jsonb) to authenticated;

create or replace function aid_program_save(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid := nullif(p->>'id', '')::uuid;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if coalesce(trim(p->>'name'), '') = '' then raise exception 'Program name is required'; end if;
  if v_id is null then
    insert into aid_programs (org_id, name) values ((p->>'org_id')::uuid, trim(p->>'name')) returning id into v_id;
  end if;
  update aid_programs set
    name = trim(p->>'name'),
    help_types = coalesce((select array_agg(x) from jsonb_array_elements_text(p->'help_types') x), help_types),
    populations = coalesce((select array_agg(x) from jsonb_array_elements_text(p->'populations') x), populations),
    terms = nullif(trim(p->>'terms'), ''), max_amount_cents = nullif(p->>'max_amount_cents', '')::int,
    pays_to = nullif(trim(p->>'pays_to'), ''), status = coalesce(nullif(p->>'status', ''), status),
    funds_today = coalesce(nullif(p->>'funds_today', ''), funds_today), how_to_apply = nullif(trim(p->>'how_to_apply'), ''),
    source_url = nullif(trim(p->>'source_url'), ''), last_checked = nullif(p->>'last_checked', '')::date,
    note = nullif(trim(p->>'note'), ''), updated_at = now()
  where id = v_id;
  return v_id;
end $$;
revoke all on function aid_program_save(jsonb) from public, anon;
grant execute on function aid_program_save(jsonb) to authenticated;

create or replace function aid_delete(p_kind text, p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if p_kind = 'org' then delete from aid_orgs where id = p_id;
  elsif p_kind = 'program' then delete from aid_programs where id = p_id;
  else raise exception 'Unknown kind'; end if;
end $$;
revoke all on function aid_delete(text, uuid) from public, anon;
grant execute on function aid_delete(text, uuid) to authenticated;

-- ---------- Seed: Milwaukee organizations from the 11/11/2026 research report ----------
insert into aid_orgs (code, name, kinds, populations, summary, verification, website, phone, address, source_note) values
('MKE-001','Milwaukee County DHHS – Housing Services','{money,subsidy,access,landlord}','{general,families}','Coordinated Entry lead since 12/30/2025 (operating from January 2026). My Home PSH, TBRA (capped 2026), street outreach, LIFT landlord program, family diversion funding (2026-2027).','verified_current',null,null,null,'Report 11/2026'),
('MKE-002','Housing Authority of the City of Milwaukee (HACM)','{subsidy,housing}','{general,veterans,seniors}','HCV/Section 8 (tenant-based waitlist closed), public housing, project-based vouchers, HUD-VASH (258 vouchers), RAD. Pays landlords directly.','verified_current','https://www.hacm.org','414-286-5824',null,'Report 11/2026'),
('MKE-003','Milwaukee County Housing Authority','{subsidy}','{general}','Section 8 for suburban Milwaukee County; not accepting applications.','verified_current',null,null,null,'Report 11/2026'),
('MKE-004','WHEDA','{subsidy}','{general}','Statewide HCV administrator for areas outside city/county PHAs; project-based rental assistance contracts for HUD; pays landlords directly.','verified_current','https://www.wheda.com','414-227-4039',null,'Report 11/2026'),
('MKE-005','Community Advocates','{money,navigation,services,housing}','{general,dv}','Runs the Rental Housing Resource Center. Direct rent applications PAUSED since 1/7/2026 (exceptions: placard, fire, domestic violence). Rent Bridge, Security Deposit Guarantee, WHEAP intake, DV shelter, PSH (Autumn West).','verified_current','https://communityadvocates.net','414-449-4777',null,'Report 11/2026'),
('MKE-006','UMOS','{money}','{general}','Community Pathways: up to $1,800 per household (rent, deposit, eviction). WHEAP administrator, DCF Emergency Assistance intake. Milwaukee County''s Community Action Agency (replaced SDC).','verified_current','https://www.umos.org','414-389-6600','2701 S. Chase Ave., Milwaukee','Report 11/2026'),
('MKE-007','IMPACT 211','{access}','{general}','24/7 access point for Coordinated Entry and shelter referrals (no longer the CE lead).','verified_current',null,'211',null,'Report 11/2026'),
('MKE-008','Milwaukee Coalition on Housing & Homelessness / CoC WI-501','{subsidy,access}','{general}','Continuum of Care governance, coordinated entry oversight, HMIS. United Way is lead agency.','verified_current',null,null,null,'Report 11/2026'),
('MKE-009','Center for Veterans Issues (CVI)','{money,navigation,services,housing,landlord}','{veterans}','SSVF grantee: rent, deposits, utilities, move-in for veterans; transitional housing; PSH; landlord engagement.','verified_current',null,'414-345-4254',null,'Report 11/2026'),
('MKE-010','VA – Clement J. Zablocki Medical Center','{money,subsidy}','{veterans}','HUD-VASH case management, HCHV outreach. VA Homeless Line 877-424-3838.','verified_current',null,'877-424-3838',null,'Report 11/2026'),
('MKE-011','Milwaukee Soldiers Home','{housing}','{veterans}','101 supportive housing units for veterans; HUD-VASH on site.','verified_current',null,null,null,'Report 11/2026'),
('MKE-012','Veterans Community Project – Milwaukee','{housing}','{veterans}','40 tiny homes (transitional village), not yet open; walk-in outreach, no discharge-status restriction.','verified_limited',null,null,null,'Report 11/2026'),
('MKE-013','Hope House of Milwaukee','{money,navigation,services,housing}','{families}','Family shelter; Family Bonds rapid re-housing (up to 2 years, Coordinated Entry referral only); PSH for families.','verified_current','https://hopehousemke.org',null,null,'Report 11/2026'),
('MKE-014','Guest House of Milwaukee','{money,navigation,services,housing}','{general,reentry}','Men''s shelter, rapid re-housing, PSH (269 units cited); serves returning citizens.','verified_current',null,null,null,'Report 11/2026'),
('MKE-015','Cathedral Center','{services,housing}','{families}','Women''s and family shelter (via 211); case management; Coordinated Entry partner.','verified_current',null,null,null,'Report 11/2026'),
('MKE-016','Salvation Army of Milwaukee County','{money,services,housing}','{general}','Emergency Lodge shelter (via 211); limited case-by-case emergency rent/utility help; medical respite; Roots PSH.','verified_current',null,null,null,'Report 11/2026'),
('MKE-017','Sojourner Family Peace Center','{services,housing}','{dv}','DV shelter (53-54 beds), 24-hour hotline, housing advocacy.','verified_current',null,null,null,'Report 11/2026'),
('MKE-018','Milwaukee Women''s Center (Community Advocates)','{services,housing}','{dv}','DV shelter, housing counseling, rental help for DV survivors (an exception category in the paused city program).','verified_current',null,null,null,'Report 11/2026'),
('MKE-019','Pathfinders','{navigation,services,housing}','{youth}','Youth shelter (11-25), supported housing, street outreach, housing navigation; youth rental assistance up to $1,000 via Coordinated Entry.','verified_current',null,null,null,'Report 11/2026'),
('MKE-020','Walker''s Point Youth & Family Center (Insights Housing)','{housing}','{youth}','Youth housing (18-24) up to 24 months; Coordinated Entry referral only.','verified_current',null,null,null,'Report 11/2026'),
('MKE-021','Courage MKE','{housing}','{youth,lgbtq}','LGBTQ+ youth group home; C2 Apartments transitional living (18-24).','verified_current',null,null,null,'Report 11/2026'),
('MKE-022','La Causa Crisis Nursery','{housing}','{families}','Crisis shelter for children 0-12 during family homelessness.','verified_current',null,null,null,'Report 11/2026'),
('MKE-023','Milwaukee County ADRC','{services,access}','{seniors,disability}','Aging and disability resource center: benefits specialists, options counseling. Not a rent fund.','verified_current',null,'414-289-6874',null,'Report 11/2026'),
('MKE-024','Legal Aid Society of Milwaukee','{legal}','{general}','Eviction Free MKE (right to counsel), eviction record sealing clinics; at the Resource Center.','verified_current',null,null,null,'Report 11/2026'),
('MKE-025','Legal Action of Wisconsin','{legal}','{general,disability}','Eviction defense, SSI/SSDI appeals, public benefits.','verified_current',null,null,null,'Report 11/2026'),
('MKE-026','Mediate Wisconsin / Milwaukee Justice Center','{legal}','{general}','Free landlord-tenant mediation, Eviction Diversion Initiative, stipulated dismissals.','verified_current',null,'414-939-8800',null,'Report 11/2026'),
('MKE-027','Rental Housing Resource Center (RHRC)','{services,access}','{general}','Walk-in hub: triage, with Community Advocates, Legal Aid, Mediate Wisconsin and a landlord liaison on site.','verified_current',null,'414-895-7368','728 N. James Lovell St., Milwaukee','Report 11/2026'),
('MKE-028','Wisconsin Community Services (WCS)','{housing}','{reentry}','Reentry housing (Joshua Glover RRC); Thurgood Marshall Apartments PSH (24 units).','verified_current',null,null,null,'Report 11/2026'),
('MKE-029','Project RETURN','{services,housing}','{reentry}','Bridge Housing (12 rooms, up to 6 months) for people released from prison; 7 rooms County-funded.','verified_current',null,null,null,'Report 11/2026'),
('MKE-030','Mercy Housing Lakefront','{housing}','{general,disability}','PSH operator: Johnston Center (91 units), St. Catherine Residence.','verified_current',null,null,null,'Report 11/2026'),
('MKE-031','Vivent Health','{money,services}','{hiv}','HIV housing services: monthly rent, utilities, security deposits; case management.','verified_current',null,null,null,'Report 11/2026'),
('MKE-032','Outreach Community Health Centers (OCHC)','{navigation,services}','{general}','Street outreach, rapid re-housing, SOAR SSI/SSDI, medical respite partner.','verified_current',null,null,null,'Report 11/2026'),
('MKE-033','Sixteenth Street Community Health Centers','{services}','{general,immigrant}','Housing-focused social services for patients (housing insecurity, eviction, navigation).','verified_current',null,null,null,'Report 11/2026'),
('MKE-034','Milwaukee Health Care Partnership (MHCP)','{services,funder}','{general}','Housing is Health: hospital navigators and gap fund; medical respite beds.','verified_current',null,null,null,'Report 11/2026'),
('MKE-035','Repairers of the Breach','{services,housing}','{general}','Daytime shelter (Mon-Sat), medical clinic, showers, employment help.','verified_current',null,null,null,'Report 11/2026'),
('MKE-036','Street Angels','{services}','{general}','Mobile street outreach (Tue/Thu nights), supplies, connections.','verified_current',null,null,null,'Report 11/2026'),
('MKE-037','United Way of Greater Milwaukee & Waukesha County','{access,funder}','{general,families}','CoC lead agency; Safe & Stable Homes; Community Case Management flexible funds (deposits, first month, moving) through case managers; Family Flex Fund.','verified_current',null,null,null,'Report 11/2026'),
('MKE-038','Greater Milwaukee Foundation','{funder}','{general}','Housing grantmaking; co-funds the CCM flexible funds.','verified_current',null,null,null,'Report 11/2026'),
('MKE-039','Key to Change','{funder}','{general}','Funds Housing First outreach: rental applications and security deposits.','verified_current',null,null,null,'Report 11/2026'),
('MKE-040','Milwaukee Jewish Free Loan Association','{money}','{general}','0% interest loans for rent, moving, storage (loans, not grants; all faiths).','verified_current',null,null,null,'Report 11/2026'),
('MKE-041','St. Vincent de Paul Society of Milwaukee','{money,access}','{general}','Parish-conference rent/utility help (amounts vary), furniture, online request form.','verified_limited',null,null,null,'Report 11/2026'),
('MKE-042','Catholic Charities of the Archdiocese of Milwaukee','{access}','{general}','Housing referral only; case management, benefits enrollment. Not a direct money source.','verified_current',null,null,null,'Report 11/2026'),
('MKE-043','Milwaukee Rescue Mission','{services,housing}','{general,families}','Safe Harbor (men) and Joy House (women/children) shelters; recovery programs.','verified_current',null,null,null,'Report 11/2026'),
('MKE-044','Capuchin Community Services / St. Benedict the Moor','{housing}','{general}','Overnight shelter (up to 80 single adults), CoC partner.','verified_current',null,null,null,'Report 11/2026'),
('MKE-045','Berrada Properties','{navigation,services}','{general}','Private landlord with an eviction diversion program at the Resource Center (payment plans, short-term help, move-out agreements). A model, not a referral source.','verified_current',null,null,null,'Report 11/2026'),
('MKE-046','Milwaukee Habitat for Humanity','{navigation}','{general}','Affordable homeownership program.','verified_limited',null,null,null,'Report 11/2026'),
('MKE-047','West Allis Office of Housing','{subsidy,housing}','{seniors,general}','Beloit Road Senior Housing (~30% of income, waitlist), rehab grants (up to $20,000), HCV program.','verified_current',null,null,null,'Report 11/2026'),
('MKE-048','Social Development Commission (SDC)','{}','{general}','INACTIVE. Community Action Agency designation ended 11/18/2025 (UMOS replaced it). Do not refer.','inactive',null,null,null,'Report 11/2026'),
('MKE-049','DCF Emergency Assistance (W-2 agencies: Maximus, America Works, UMOS, Ross)','{money}','{families}','State emergency assistance for families with children: deposit, first month, utility, repairs. Apply in person with ID; payment about 5 business days.','verified_current',null,null,null,'Report 11/2026')
on conflict (code) do nothing;
update aid_orgs set relationship = 'do_not_refer' where code = 'MKE-048';

-- Programs (amounts only where the source published one).
insert into aid_programs (org_id, name, help_types, populations, terms, max_amount_cents, pays_to, status, how_to_apply)
select o.id, v.name, v.help_types::text[], v.pops::text[], v.terms, v.amt, v.pays_to, v.status, v.how
from (values
 ('MKE-006','Community Pathways','{rent,deposit,arrears}','{general}','One-time; up to $1,800 per household; income at or below 125% of poverty.',180000,'landlord','open','UMOS'),
 ('MKE-009','SSVF Temporary Financial Assistance','{rent,deposit,utility,first_month}','{veterans}','VA limits; amount not published.',null,'landlord','open','CVI SSVF team 414-345-4254'),
 ('MKE-006','WHEAP / Home Energy Plus','{utility}','{general}','Heating season 10/1/2026-5/15/2027; benefit matrix.',null,'utility','open','UMOS or Community Advocates'),
 ('MKE-013','Family Bonds rapid re-housing','{rrh,rent}','{families}','Up to 2 years of rent with case management.',null,'landlord','referral_only','Coordinated Entry (211)'),
 ('MKE-019','Youth rental assistance','{rent,deposit,arrears}','{youth}','$1,000 maximum (youth collaborative standard).',100000,'landlord','referral_only','Coordinated Entry'),
 ('MKE-031','HIV housing services','{rent,utility,deposit}','{hiv}','Income-based; amount not published.',null,'landlord','open','Vivent Health'),
 ('MKE-049','DCF Emergency Assistance','{deposit,first_month,utility}','{families}','Families with children only; in person with ID; about 5 business days.',null,'landlord','open','W-2 agency for your area'),
 ('MKE-005','City of Milwaukee rental assistance','{rent,arrears}','{general,dv}','PAUSED since 1/7/2026. Exceptions: placard, fire, domestic violence.',null,'landlord','paused','Resource Center'),
 ('MKE-005','Rent Bridge','{arrears}','{general}','Arrears up to $400 on a 6-month plan; tenancy 1+ year; income required; landlord must agree.',40000,'landlord','open','Community Advocates 414-449-4777'),
 ('MKE-005','Security Deposit Guarantee','{deposit}','{general}','Deposit paid in installments over up to 6 months; tenant must have income; landlord must agree.',null,'landlord','open','Community Advocates 414-449-4777'),
 ('MKE-001','LIFT (Landlord Incentives to Foster Tenancy)','{landlord_risk}','{general,reentry}','Up to 3x contract rent for verified damage; up to 1x rent for vacancy loss; admin support; tenant wraparound. $356,355 county pilot; 96 landlords by 1/2026.',null,'landlord','open','https://www.liftmke.com'),
 ('MKE-001','Family diversion funding','{flexible}','{families}','$203,750 United Way grant through June 2027; families referred to Coordinated Entry.',null,'varies','referral_only','Coordinated Entry (211)'),
 ('MKE-001','Tenant-Based Rental Assistance (TBRA)','{rent}','{general}','Capped in 2026.',null,'landlord','limited','County Housing Services'),
 ('MKE-037','Community Case Management flexible funds','{deposit,first_month,flexible}','{general}','Through case managers only, not walk-in.',null,'varies','referral_only','A case manager'),
 ('MKE-034','Housing is Health gap fund','{flexible}','{general}','Hospital referral for homeless patients.',null,'varies','referral_only','Hospital navigator'),
 ('MKE-016','Emergency financial assistance','{rent,utility}','{general}','Limited, case by case.',null,'landlord','limited','Salvation Army'),
 ('MKE-041','Emergency aid','{rent,utility}','{general}','Depends on the parish conference.',null,'landlord','limited','Online request form'),
 ('MKE-040','0% housing loans','{loan,rent}','{general}','Loans, not grants.',null,'tenant','open','Milwaukee Jewish Free Loan'),
 ('MKE-048','MERA','{rent,utility}','{general}','Inactive. Do not refer.',null,null,'inactive',null)
) as v(code, name, help_types, pops, terms, amt, pays_to, status, how)
join aid_orgs o on o.code = v.code
where not exists (select 1 from aid_programs p where p.org_id = o.id and p.name = v.name);
