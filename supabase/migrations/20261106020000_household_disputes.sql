-- Household members and charge disputes (Stephen, 10/7/2026: "we drop nothing but strengthen").
--
-- HOUSEHOLD MEMBERS
--   Everyone living in a unit who doesn't sign the lease. The signers stay in lease_tenants; these are the other
--   people (children, a partner, a relative). A tenant adds someone in the resident portal and the office approves it;
--   a tenant reports when someone moves out (no approval needed). Staff can add people directly, or copy them from
--   the rental application with one click. Guests are counted separately (guest_requests; 13-night rule).
--
--   Occupancy limit per unit: Milwaukee Code ch. 275 bedroom sizes. Stephen, 10/7/2026 (listing): BR1 12'x13' =
--   156 sq ft = 3 people, BR2 12'x10' = 120 sq ft = 2 people, so up to 5 people in a 2-bedroom. Every unit on file
--   is a 2-bedroom, so each starts at 5; staff can change a unit's number on the Household page. Approving past the
--   limit needs an explicit confirmation from staff.
--
-- CHARGE DISPUTES
--   A tenant can question a charge on their rent ledger, and an owner a charge on their association ledger. The
--   office answers (question stays open for a reply), denies with an explanation, or adjusts: an adjustment posts a
--   credit on the same ledger with a correction note citing the dispute. The original line is never changed or
--   deleted (history is everything). A dispute does not pause late fees, notices or anything else by itself.

-- ---------------------------------------------------------------------------
-- Office alert email (setting 'household_alert_email' / 'disputes_alert_email', else info@2ndchinc.org)
create or replace function office_alert(p_setting text, p_kind text, p_subject text, p_html text)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare v_to text := coalesce(nullif((select value from portal_settings where key = p_setting), ''), 'info@2ndchinc.org');
begin
  insert into email_outbox (to_email, subject, html, kind) values (v_to, p_subject, p_html, p_kind);
end;
$$;
revoke all on function office_alert(text, text, text, text) from public, anon, authenticated;

-- Email every tenant (with an email) on a lease.
create or replace function lease_email_tenants(p_lease uuid, p_subject text, p_body_html text, p_kind text)
returns int
language plpgsql volatile security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in select distinct lower(t.email) email, t.name from lease_tenants lt join tenants t on t.id = lt.tenant_id
           where lt.lease_id = p_lease and coalesce(t.email, '') like '%@%'
  loop
    insert into email_outbox (to_email, subject, html, kind) values (r.email, p_subject,
      '<p>Hi ' || repair_esc(split_part(coalesce(r.name, ''), ' ', 1)) || ',</p>' || p_body_html || '<p>2nd Chance Housing</p>', p_kind);
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke all on function lease_email_tenants(uuid, text, text, text) from public, anon, authenticated;

-- ===========================================================================
-- HOUSEHOLD MEMBERS
-- ===========================================================================
create table if not exists unit_occupancy_limits (
  unit_number text primary key,
  max_people int not null check (max_people between 1 and 20),
  basis text,
  set_by text,
  set_at timestamptz not null default now()
);
alter table unit_occupancy_limits enable row level security;

insert into unit_occupancy_limits (unit_number, max_people, basis, set_by)
select unit_number, 5, 'Milwaukee Code ch. 275 bedroom sizes: BR1 12''x13'' = 156 sq ft (3 people), BR2 12''x10'' = 120 sq ft (2 people). Stephen, 10/7/2026.', 'migration'
from condo_units where bedrooms ilike '2%'
on conflict (unit_number) do nothing;

create table if not exists household_members (
  id uuid primary key default gen_random_uuid(),
  lease_id uuid not null references leases(id),
  name text not null,
  relationship text,
  birth_date date,
  moved_in date,
  moved_out date,
  status text not null default 'pending' check (status in ('pending', 'approved', 'declined', 'removed')),
  added_by_kind text not null check (added_by_kind in ('tenant', 'staff', 'application')),
  added_by text,
  note text,
  staff_note text,
  over_limit_ok boolean not null default false,     -- staff approved knowing it went past the unit's limit
  decided_by text, decided_at timestamptz,
  removed_by text, removed_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists household_members_lease_idx on household_members (lease_id, status);
alter table household_members enable row level security;
-- No policies: everything goes through the functions below.

create or replace function household_unit_of(p_lease uuid)
returns text language sql stable security definer set search_path = public as $$
  select ru.unit_number from leases l join rental_units ru on ru.id = l.unit_id where l.id = p_lease;
$$;
revoke all on function household_unit_of(uuid) from public, anon, authenticated;

-- People living in the unit under this lease: signers + approved members who haven't moved out.
create or replace function household_people_count(p_lease uuid)
returns int language sql stable security definer set search_path = public as $$
  select ((select count(*) from lease_tenants where lease_id = p_lease)
        + (select count(*) from household_members m where m.lease_id = p_lease and m.status = 'approved'
             and (m.moved_out is null or m.moved_out > current_date)))::int;
$$;
revoke all on function household_people_count(uuid) from public, anon, authenticated;

create or replace function household_row(m household_members)
returns jsonb language sql stable security definer set search_path = public as $$
  select to_jsonb(m) || jsonb_build_object(
    'age', case when m.birth_date is not null then extract(year from age(current_date, m.birth_date))::int end,
    'minor', case when m.birth_date is not null then age(current_date, m.birth_date) < interval '18 years' end,
    'living', m.status = 'approved' and (m.moved_out is null or m.moved_out > current_date));
$$;
revoke all on function household_row(household_members) from public, anon, authenticated;

create or replace function household_lease_json(p_lease uuid, p_staff boolean)
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'lease_id', l.id, 'unit', ru.unit_number, 'address', ru.address, 'lease_status', l.status, 'start_date', l.start_date,
    'signers', (select coalesce(jsonb_agg(t.name order by t.name), '[]'::jsonb) from lease_tenants lt join tenants t on t.id = lt.tenant_id where lt.lease_id = l.id),
    'people', household_people_count(l.id),
    'limit', (select max_people from unit_occupancy_limits where unit_number = ru.unit_number),
    'limit_basis', (select basis from unit_occupancy_limits where unit_number = ru.unit_number),
    'application_id', case when p_staff then l.application_id end,
    'application_household', case when p_staff then (select a.household from rental_applications a where a.id = l.application_id) end,
    'members', (select coalesce(jsonb_agg(
        case when p_staff then household_row(m) else household_row(m) - 'staff_note' - 'decided_by' - 'removed_by' - 'added_by' end
        order by m.status = 'removed', m.created_at), '[]'::jsonb)
      from household_members m where m.lease_id = l.id and (p_staff or m.status <> 'declined' or m.decided_at > now() - interval '60 days')))
  from leases l join rental_units ru on ru.id = l.unit_id where l.id = p_lease;
$$;
revoke all on function household_lease_json(uuid, boolean) from public, anon, authenticated;

create or replace function household_validate(p_name text, p_birth date, p_moved_in date)
returns void language plpgsql immutable as $$
begin
  if length(coalesce(trim(p_name), '')) < 2 then raise exception 'Enter the person''s full name.'; end if;
  if p_birth is not null and (p_birth > current_date or p_birth < date '1900-01-01') then raise exception 'Check the date of birth.'; end if;
  if p_moved_in is not null and p_moved_in > current_date + 120 then raise exception 'The move-in date is too far ahead.'; end if;
end;
$$;

-- ---- Tenants -------------------------------------------------------------
create or replace function household_my_leases()
returns setof uuid language sql stable security definer set search_path = public as $$
  select distinct l.id from lease_tenants lt join leases l on l.id = lt.lease_id and l.status in ('active', 'future')
  where lt.tenant_id in (select resident_me());
$$;
revoke all on function household_my_leases() from public, anon;

create or replace function household_mine()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from household_my_leases()) then raise exception 'Sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'office_phone', (select value from portal_settings where key = 'org_phone'),
    'leases', (select coalesce(jsonb_agg(household_lease_json(id, false)), '[]'::jsonb) from household_my_leases() id));
end;
$$;
revoke all on function household_mine() from public, anon;
grant execute on function household_mine() to authenticated;

create or replace function household_add(p_lease uuid, p_name text, p_relationship text, p_birth date, p_moved_in date, p_note text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare m household_members; v_who text; v_unit text; v_people int; v_limit int;
begin
  if p_lease is null or p_lease not in (select household_my_leases()) then raise exception 'That lease isn''t yours.' using errcode = '42501'; end if;
  perform household_validate(p_name, p_birth, p_moved_in);
  if exists (select 1 from household_members where lease_id = p_lease and status in ('pending', 'approved') and (moved_out is null or moved_out > current_date)
             and lower(regexp_replace(name, '\s+', ' ', 'g')) = lower(regexp_replace(trim(p_name), '\s+', ' ', 'g'))) then
    raise exception '% is already on your household list.', trim(p_name); end if;
  select name into v_who from tenants where id in (select resident_me()) limit 1;
  insert into household_members (lease_id, name, relationship, birth_date, moved_in, status, added_by_kind, added_by, note)
  values (p_lease, trim(p_name), nullif(trim(coalesce(p_relationship, '')), ''), p_birth, p_moved_in, 'pending', 'tenant', lower(auth.email()),
          left(nullif(trim(coalesce(p_note, '')), ''), 500))
  returning * into m;
  v_unit := household_unit_of(p_lease); v_people := household_people_count(p_lease);
  select max_people into v_limit from unit_occupancy_limits where unit_number = v_unit;
  perform office_alert('household_alert_email', 'household', 'Household member to approve — Unit ' || coalesce(v_unit, '?') || ' (' || m.name || ')',
    '<p><b>' || repair_esc(coalesce(v_who, auth.email())) || '</b> (Unit ' || repair_esc(coalesce(v_unit, '?')) || ') asks to add <b>' || repair_esc(m.name) || '</b>'
    || coalesce(' (' || repair_esc(m.relationship) || ')', '') || coalesce(', born ' || to_char(m.birth_date, 'FMMM/FMDD/YYYY'), '')
    || coalesce(', moving in ' || to_char(m.moved_in, 'FMMM/FMDD/YYYY'), '') || ' to the household.</p>'
    || '<p>People living there now: ' || v_people || coalesce(' of ' || v_limit || ' allowed', '') || '; with this person: ' || (v_people + 1)
    || case when v_limit is not null and v_people + 1 > v_limit then ' <b>(over the limit)</b>' else '' end || '.</p>'
    || case when m.note is not null then '<p>Note: ' || repair_esc(m.note) || '</p>' else '' end
    || '<p>Approve or decline it on the Household page: https://2ndchinc.org/leasing/household/</p>');
  return household_row(m);
end;
$$;
revoke all on function household_add(uuid, text, text, date, date, text) from public, anon;
grant execute on function household_add(uuid, text, text, date, date, text) to authenticated;

-- Tenant cancels a pending request, or reports that someone moved out.
create or replace function household_remove(p_id uuid, p_moved_out date)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare m household_members; v_unit text;
begin
  select * into m from household_members where id = p_id and lease_id in (select household_my_leases()) for update;
  if m.id is null then raise exception 'Not found.' using errcode = '42501'; end if;
  if m.status = 'pending' then
    update household_members set status = 'removed', removed_by = lower(auth.email()), removed_at = now() where id = p_id returning * into m;
  elsif m.status = 'approved' then
    if p_moved_out is null or p_moved_out > current_date + 60 then raise exception 'Enter the day they moved (or will move) out.'; end if;
    update household_members set status = 'removed', moved_out = p_moved_out, removed_by = lower(auth.email()), removed_at = now() where id = p_id returning * into m;
    v_unit := household_unit_of(m.lease_id);
    perform office_alert('household_alert_email', 'household', 'Household member moved out — Unit ' || coalesce(v_unit, '?') || ' (' || m.name || ')',
      '<p>The tenant at Unit ' || repair_esc(coalesce(v_unit, '?')) || ' reports that <b>' || repair_esc(m.name) || '</b> moved out on '
      || to_char(p_moved_out, 'FMMM/FMDD/YYYY') || '. Nothing to approve; it''s on the Household page.</p>');
  else
    raise exception 'This person is already off the list.';
  end if;
  return household_row(m);
end;
$$;
revoke all on function household_remove(uuid, date) from public, anon;
grant execute on function household_remove(uuid, date) to authenticated;

-- ---- Staff ---------------------------------------------------------------
create or replace function household_staff_list(p_all boolean)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'pending', (select coalesce(jsonb_agg(household_row(m) || jsonb_build_object('unit', household_unit_of(m.lease_id),
                  'people', household_people_count(m.lease_id),
                  'limit', (select max_people from unit_occupancy_limits where unit_number = household_unit_of(m.lease_id))) order by m.created_at), '[]'::jsonb)
                from household_members m where m.status = 'pending'),
    'leases', (select coalesce(jsonb_agg(household_lease_json(l.id, true) order by nullif(regexp_replace(ru.unit_number, '\D', '', 'g'), '')::int, l.start_date), '[]'::jsonb)
               from leases l join rental_units ru on ru.id = l.unit_id
               where l.status in ('active', 'future') or (coalesce(p_all, false) and exists (select 1 from household_members m where m.lease_id = l.id))),
    'limits', (select coalesce(jsonb_agg(to_jsonb(x) order by nullif(regexp_replace(x.unit_number, '\D', '', 'g'), '')::int), '[]'::jsonb) from unit_occupancy_limits x));
end;
$$;
revoke all on function household_staff_list(boolean) from public, anon;
grant execute on function household_staff_list(boolean) to authenticated;

-- Approve or decline. Approving past the unit's limit raises unless p_over_limit_ok is true.
create or replace function household_staff_decide(p_id uuid, p_approve boolean, p_note text, p_over_limit_ok boolean default false)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare m household_members; v_unit text; v_people int; v_limit int; v_over boolean := false;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into m from household_members where id = p_id for update;
  if m.id is null then raise exception 'Not found'; end if;
  if m.status <> 'pending' then raise exception 'This was already %.', m.status; end if;
  if not p_approve and length(coalesce(trim(p_note), '')) < 3 then raise exception 'Say why it''s declined (the tenant sees it).'; end if;
  v_unit := household_unit_of(m.lease_id); v_people := household_people_count(m.lease_id);
  select max_people into v_limit from unit_occupancy_limits where unit_number = v_unit;
  if p_approve and v_limit is not null and v_people + 1 > v_limit then
    if not coalesce(p_over_limit_ok, false) then
      raise exception 'OVER_LIMIT: approving makes % people in Unit % (limit %).', v_people + 1, v_unit, v_limit;
    end if;
    v_over := true;
  end if;
  update household_members set status = case when p_approve then 'approved' else 'declined' end, staff_note = nullif(trim(coalesce(p_note, '')), ''),
    decided_by = lower(auth.email()), decided_at = now(), over_limit_ok = v_over,
    moved_in = case when p_approve then coalesce(moved_in, current_date) else moved_in end
  where id = p_id returning * into m;
  perform lease_email_tenants(m.lease_id, 'Household member ' || case when p_approve then 'approved' else 'declined' end || ' — ' || m.name,
    '<p>Your request to add <b>' || repair_esc(m.name) || '</b> to the household at Unit ' || repair_esc(coalesce(v_unit, '')) || ' is <b>'
    || case when p_approve then 'approved' else 'declined' end || '</b>.</p>'
    || case when m.staff_note is not null then '<p>Note from the office: ' || repair_esc(m.staff_note) || '</p>' else '' end, 'household');
  return household_row(m);
end;
$$;
revoke all on function household_staff_decide(uuid, boolean, text, boolean) from public, anon;
grant execute on function household_staff_decide(uuid, boolean, text, boolean) to authenticated;

-- Staff add someone directly (approved). Same over-limit rule.
create or replace function household_staff_add(p_lease uuid, p_name text, p_relationship text, p_birth date, p_moved_in date, p_note text, p_over_limit_ok boolean default false)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare m household_members; v_unit text; v_people int; v_limit int;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if not exists (select 1 from leases where id = p_lease) then raise exception 'Lease not found'; end if;
  perform household_validate(p_name, p_birth, p_moved_in);
  v_unit := household_unit_of(p_lease); v_people := household_people_count(p_lease);
  select max_people into v_limit from unit_occupancy_limits where unit_number = v_unit;
  if v_limit is not null and v_people + 1 > v_limit and not coalesce(p_over_limit_ok, false) then
    raise exception 'OVER_LIMIT: adding makes % people in Unit % (limit %).', v_people + 1, v_unit, v_limit; end if;
  insert into household_members (lease_id, name, relationship, birth_date, moved_in, status, added_by_kind, added_by, note, decided_by, decided_at, over_limit_ok)
  values (p_lease, trim(p_name), nullif(trim(coalesce(p_relationship, '')), ''), p_birth, coalesce(p_moved_in, current_date), 'approved', 'staff', lower(auth.email()),
          left(nullif(trim(coalesce(p_note, '')), ''), 500), lower(auth.email()), now(), v_limit is not null and v_people + 1 > v_limit)
  returning * into m;
  return household_row(m);
end;
$$;
revoke all on function household_staff_add(uuid, text, text, date, date, text, boolean) from public, anon;
grant execute on function household_staff_add(uuid, text, text, date, date, text, boolean) to authenticated;

-- One click: copy the household from the lease's rental application (skips signers and people already listed).
-- Returns how many were added. Added as approved (the office approved the application); counts are not blocked by the limit
-- here, the page shows the result against the limit.
create or replace function household_staff_from_application(p_lease uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare v_app uuid; p jsonb; v_name text; n int := 0; skipped jsonb := '[]'::jsonb; v_dob date;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select application_id into v_app from leases where id = p_lease;
  if v_app is null then raise exception 'This lease has no rental application linked.'; end if;
  for p in select * from jsonb_array_elements(coalesce((select household from rental_applications where id = v_app), '[]'::jsonb)) loop
    v_name := trim(coalesce(p ->> 'name', ''));
    if length(v_name) < 2 then continue; end if;
    if exists (select 1 from lease_tenants lt join tenants t on t.id = lt.tenant_id where lt.lease_id = p_lease
               and lower(regexp_replace(t.name, '\s+', ' ', 'g')) = lower(regexp_replace(v_name, '\s+', ' ', 'g')))
       or exists (select 1 from household_members m where m.lease_id = p_lease and m.status in ('pending', 'approved')
               and lower(regexp_replace(m.name, '\s+', ' ', 'g')) = lower(regexp_replace(v_name, '\s+', ' ', 'g'))) then
      skipped := skipped || to_jsonb(v_name); continue;
    end if;
    begin v_dob := nullif(p ->> 'dob', '')::date; exception when others then v_dob := null; end;
    insert into household_members (lease_id, name, relationship, birth_date, moved_in, status, added_by_kind, added_by, decided_by, decided_at, note)
    select p_lease, v_name, nullif(p ->> 'relation', ''), v_dob, l.start_date, 'approved', 'application', lower(auth.email()), lower(auth.email()), now(),
           'From the rental application'
    from leases l where l.id = p_lease;
    n := n + 1;
  end loop;
  return jsonb_build_object('added', n, 'skipped', skipped, 'household', household_lease_json(p_lease, true));
end;
$$;
revoke all on function household_staff_from_application(uuid) from public, anon;
grant execute on function household_staff_from_application(uuid) to authenticated;

create or replace function household_staff_remove(p_id uuid, p_moved_out date, p_note text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare m household_members;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  update household_members set status = 'removed', moved_out = case when status = 'approved' then coalesce(p_moved_out, current_date) else moved_out end,
    removed_by = lower(auth.email()), removed_at = now(),
    staff_note = coalesce(nullif(trim(coalesce(p_note, '')), ''), staff_note)
  where id = p_id and status in ('pending', 'approved') returning * into m;
  if m.id is null then raise exception 'Only someone on the list can be taken off.'; end if;
  return household_row(m);
end;
$$;
revoke all on function household_staff_remove(uuid, date, text) from public, anon;
grant execute on function household_staff_remove(uuid, date, text) to authenticated;

create or replace function household_staff_set_limit(p_unit text, p_max int, p_basis text)
returns void language plpgsql volatile security definer set search_path = public as $$
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if not exists (select 1 from condo_units where unit_number = trim(p_unit)) and not exists (select 1 from rental_units where unit_number = trim(p_unit)) then
    raise exception 'Unit % isn''t on file.', p_unit; end if;
  if p_max is null or p_max < 1 or p_max > 20 then raise exception 'Enter a number of people from 1 to 20.'; end if;
  insert into unit_occupancy_limits (unit_number, max_people, basis, set_by, set_at) values (trim(p_unit), p_max, nullif(trim(coalesce(p_basis, '')), ''), lower(auth.email()), now())
  on conflict (unit_number) do update set max_people = excluded.max_people, basis = coalesce(excluded.basis, unit_occupancy_limits.basis), set_by = excluded.set_by, set_at = now();
end;
$$;
revoke all on function household_staff_set_limit(text, int, text) from public, anon;
grant execute on function household_staff_set_limit(text, int, text) to authenticated;

-- Read-only household for the field/office unit page (site/staff/unit): names, relationship and minor/adult only.
create or replace function household_for_unit(p_property text, p_unit text)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_ru uuid;
begin
  if not field_can_access(p_property, p_unit) then raise exception 'Not one of your units' using errcode = '42501'; end if;
  v_ru := inspection_rental_unit(p_property, p_unit);
  return (select coalesce(jsonb_agg(jsonb_build_object('unit', ru.unit_number,
      'signers', (select coalesce(jsonb_agg(t.name order by t.name), '[]'::jsonb) from lease_tenants lt join tenants t on t.id = lt.tenant_id where lt.lease_id = l.id),
      'members', (select coalesce(jsonb_agg(jsonb_build_object('name', m.name, 'relationship', m.relationship,
                     'minor', case when m.birth_date is not null then age(current_date, m.birth_date) < interval '18 years' end) order by m.name), '[]'::jsonb)
                  from household_members m where m.lease_id = l.id and m.status = 'approved' and (m.moved_out is null or m.moved_out > current_date)),
      'people', household_people_count(l.id),
      'limit', (select max_people from unit_occupancy_limits where unit_number = ru.unit_number))), '[]'::jsonb)
    from leases l join rental_units ru on ru.id = l.unit_id where ru.id = v_ru and l.status = 'active');
end;
$$;
revoke all on function household_for_unit(text, text) from public, anon;
grant execute on function household_for_unit(text, text) to authenticated;

-- ===========================================================================
-- CHARGE DISPUTES
-- ===========================================================================
create table if not exists charge_disputes (
  id uuid primary key default gen_random_uuid(),
  side text not null check (side in ('tenant', 'owner')),
  lease_id uuid references leases(id),
  lease_entry_id bigint references lease_ledger_entries(id),
  condo_account_id uuid references condo_ledger_accounts(id),
  condo_entry_id bigint references condo_ledger_entries(id),
  unit_number text,
  entry_date date not null,               -- copy of the questioned line, as it was when questioned
  entry_description text,
  entry_amount numeric(12,2) not null,
  amount_disputed numeric(12,2) not null check (amount_disputed > 0),
  reason text not null,
  status text not null default 'open' check (status in ('open', 'answered', 'adjusted', 'denied', 'withdrawn')),
  thread jsonb not null default '[]'::jsonb,   -- [{at, by: 'tenant'|'owner'|'staff', name, text}]
  staff_response text,                         -- the final explanation (denied / adjusted)
  adjustment_entry_id bigint,                  -- the credit posted (lease_ledger_entries or condo_ledger_entries id, by side)
  adjustment_amount numeric(12,2),
  raised_by_email text not null,
  raised_by_name text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  closed_by text, closed_at timestamptz,
  check ((side = 'tenant' and lease_entry_id is not null and lease_id is not null) or (side = 'owner' and condo_entry_id is not null and condo_account_id is not null))
);
create unique index if not exists charge_disputes_open_lease_entry on charge_disputes (lease_entry_id) where status in ('open', 'answered') and lease_entry_id is not null;
create unique index if not exists charge_disputes_open_condo_entry on charge_disputes (condo_entry_id) where status in ('open', 'answered') and condo_entry_id is not null;
create index if not exists charge_disputes_status_idx on charge_disputes (status, created_at);
alter table charge_disputes enable row level security;

-- The signed-in owner's ledger accounts (current ownerships, not excluded).
create or replace function dispute_owner_accounts()
returns table (account_id uuid, unit_number text)
language sql stable security definer set search_path = public as $$
  select a.id, u.unit_number from condo_ledger_accounts a
    join condo_ownerships s on s.id = a.ownership_id and s.is_current
    join condo_units u on u.id = a.unit_id
  where not a.excluded and condo_session_ok() and s.owner_id = condo_owner_for_email(auth.email());
$$;
revoke all on function dispute_owner_accounts() from public, anon, authenticated;

create or replace function dispute_tenant_leases()
returns setof uuid language sql stable security definer set search_path = public as $$
  select distinct lt.lease_id from lease_tenants lt join leases l on l.id = lt.lease_id and l.status in ('active', 'future')
  where lt.tenant_id in (select resident_me());
$$;
revoke all on function dispute_tenant_leases() from public, anon, authenticated;

create or replace function dispute_row(d charge_disputes, p_staff boolean)
returns jsonb language sql stable security definer set search_path = public as $$
  select case when p_staff then to_jsonb(d) else to_jsonb(d) - 'closed_by' - 'raised_by_email' end
    || jsonb_build_object('tenants', case when p_staff and d.side = 'tenant' then
         (select string_agg(t.name, ', ' order by t.name) from lease_tenants lt join tenants t on t.id = lt.tenant_id where lt.lease_id = d.lease_id) end,
       'owner', case when p_staff and d.side = 'owner' then
         (select o.name from condo_ledger_accounts a join condo_ownerships s on s.id = a.ownership_id join condo_owners o on o.id = s.owner_id where a.id = d.condo_account_id) end);
$$;
revoke all on function dispute_row(charge_disputes, boolean) from public, anon, authenticated;

-- Charges the signed-in tenant/owner can question (last 24 months), plus their disputes.
create or replace function disputes_mine()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v_t boolean := exists (select 1 from dispute_tenant_leases()); v_o boolean := exists (select 1 from dispute_owner_accounts());
begin
  if not (v_t or v_o) then raise exception 'Sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'office_phone', (select value from portal_settings where key = 'org_phone'),
    'tenant_lines', case when v_t then (select coalesce(jsonb_agg(jsonb_build_object('side', 'tenant', 'id', e.id, 'date', e.entry_date, 'description', coalesce(e.description, e.raw_type),
          'type', e.raw_type, 'amount', e.amount, 'unit', ru.unit_number) order by e.entry_date desc, e.id desc), '[]'::jsonb)
        from lease_ledger_entries e join leases l on l.id = e.lease_id join rental_units ru on ru.id = l.unit_id
        where e.lease_id in (select dispute_tenant_leases()) and e.amount > 0 and e.kind in ('charge', 'other', 'refund') and e.entry_date > current_date - 730) else '[]'::jsonb end,
    'owner_lines', case when v_o then (select coalesce(jsonb_agg(jsonb_build_object('side', 'owner', 'id', e.id, 'date', e.entry_date, 'description', coalesce(e.description, e.raw_type),
          'type', e.raw_type, 'amount', e.amount, 'unit', oa.unit_number) order by e.entry_date desc, e.id desc), '[]'::jsonb)
        from condo_ledger_entries e join dispute_owner_accounts() oa on oa.account_id = e.account_id
        where e.amount > 0 and e.entry_date > current_date - 730) else '[]'::jsonb end,
    'disputes', (select coalesce(jsonb_agg(dispute_row(d, false) order by d.created_at desc), '[]'::jsonb) from charge_disputes d
                 where (d.side = 'tenant' and d.lease_id in (select dispute_tenant_leases()))
                    or (d.side = 'owner' and d.condo_account_id in (select account_id from dispute_owner_accounts()))));
end;
$$;
revoke all on function disputes_mine() from public, anon;
grant execute on function disputes_mine() to authenticated;

create or replace function dispute_create(p_side text, p_entry bigint, p_amount numeric, p_reason text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare d charge_disputes; v_lease uuid; v_acct uuid; v_unit text; v_date date; v_desc text; v_amt numeric; v_name text;
begin
  if length(coalesce(trim(p_reason), '')) < 10 then raise exception 'Tell us what''s wrong with this charge (a sentence or two).'; end if;
  if p_side = 'tenant' then
    select e.lease_id, ru.unit_number, e.entry_date, coalesce(e.description, e.raw_type), e.amount into v_lease, v_unit, v_date, v_desc, v_amt
      from lease_ledger_entries e join leases l on l.id = e.lease_id join rental_units ru on ru.id = l.unit_id
     where e.id = p_entry and e.lease_id in (select dispute_tenant_leases());
    if v_lease is null then raise exception 'That charge isn''t on your ledger.' using errcode = '42501'; end if;
    select name into v_name from tenants where id in (select resident_me()) limit 1;
  elsif p_side = 'owner' then
    select e.account_id, oa.unit_number, e.entry_date, coalesce(e.description, e.raw_type), e.amount into v_acct, v_unit, v_date, v_desc, v_amt
      from condo_ledger_entries e join dispute_owner_accounts() oa on oa.account_id = e.account_id where e.id = p_entry;
    if v_acct is null then raise exception 'That charge isn''t on your account.' using errcode = '42501'; end if;
    select name into v_name from condo_owners where id = condo_owner_for_email(auth.email());
  else
    raise exception 'Unknown side';
  end if;
  if v_amt <= 0 then raise exception 'Only a charge can be questioned. For a payment that is missing or wrong, message the office.'; end if;
  if coalesce(p_amount, v_amt) <= 0 or coalesce(p_amount, v_amt) > v_amt then raise exception 'The amount you question can be up to the charge, %.', to_char(v_amt, 'FM$999,990.00'); end if;
  if exists (select 1 from charge_disputes where status in ('open', 'answered')
             and ((p_side = 'tenant' and lease_entry_id = p_entry) or (p_side = 'owner' and condo_entry_id = p_entry))) then
    raise exception 'You already have an open question about this charge.'; end if;
  insert into charge_disputes (side, lease_id, lease_entry_id, condo_account_id, condo_entry_id, unit_number, entry_date, entry_description, entry_amount,
    amount_disputed, reason, raised_by_email, raised_by_name, thread)
  values (p_side, v_lease, case when p_side = 'tenant' then p_entry end, v_acct, case when p_side = 'owner' then p_entry end, v_unit, v_date, v_desc, v_amt,
    coalesce(p_amount, v_amt), left(trim(p_reason), 2000), lower(auth.email()), v_name,
    jsonb_build_array(jsonb_build_object('at', now(), 'by', p_side, 'name', v_name, 'text', left(trim(p_reason), 2000))))
  returning * into d;
  perform office_alert('disputes_alert_email', 'dispute', 'Charge questioned — Unit ' || coalesce(v_unit, '?') || ' (' || to_char(d.amount_disputed, 'FM$999,990.00') || ')',
    '<p><b>' || repair_esc(coalesce(v_name, auth.email())) || '</b> (' || p_side || ', Unit ' || repair_esc(coalesce(v_unit, '?')) || ') questions the charge of '
    || to_char(v_amt, 'FM$999,990.00') || ' on ' || to_char(v_date, 'FMMM/FMDD/YYYY') || ': <i>' || repair_esc(coalesce(v_desc, '')) || '</i>'
    || case when d.amount_disputed < v_amt then ' (questioning ' || to_char(d.amount_disputed, 'FM$999,990.00') || ' of it)' else '' end || '.</p>'
    || '<p>“' || repair_esc(d.reason) || '”</p><p>Answer, deny or adjust it on the Disputes page: https://2ndchinc.org/accounting/disputes/</p>');
  return dispute_row(d, false);
end;
$$;
revoke all on function dispute_create(text, bigint, numeric, text) from public, anon;
grant execute on function dispute_create(text, bigint, numeric, text) to authenticated;

create or replace function dispute_mine_ok(d charge_disputes)
returns boolean language sql stable security definer set search_path = public as $$
  select (d.side = 'tenant' and d.lease_id in (select dispute_tenant_leases()))
      or (d.side = 'owner' and d.condo_account_id in (select account_id from dispute_owner_accounts()));
$$;
revoke all on function dispute_mine_ok(charge_disputes) from public, anon, authenticated;

-- Tenant/owner replies to the office's answer (re-opens it) or withdraws.
create or replace function dispute_reply(p_id uuid, p_text text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare d charge_disputes;
begin
  select * into d from charge_disputes where id = p_id for update;
  if d.id is null or not dispute_mine_ok(d) then raise exception 'Not found.' using errcode = '42501'; end if;
  if d.status not in ('open', 'answered') then raise exception 'This question is closed. If something is still wrong, question the charge again or call the office.'; end if;
  if length(coalesce(trim(p_text), '')) < 2 then raise exception 'Write your reply.'; end if;
  update charge_disputes set status = 'open', updated_at = now(),
    thread = thread || jsonb_build_array(jsonb_build_object('at', now(), 'by', d.side, 'name', d.raised_by_name, 'text', left(trim(p_text), 2000)))
  where id = p_id returning * into d;
  perform office_alert('disputes_alert_email', 'dispute', 'Reply on a questioned charge — Unit ' || coalesce(d.unit_number, '?'),
    '<p><b>' || repair_esc(coalesce(d.raised_by_name, '')) || '</b> replied about the ' || to_char(d.entry_amount, 'FM$999,990.00') || ' charge of '
    || to_char(d.entry_date, 'FMMM/FMDD/YYYY') || ':</p><p>“' || repair_esc(trim(p_text)) || '”</p><p>https://2ndchinc.org/accounting/disputes/</p>');
  return dispute_row(d, false);
end;
$$;
revoke all on function dispute_reply(uuid, text) from public, anon;
grant execute on function dispute_reply(uuid, text) to authenticated;

create or replace function dispute_withdraw(p_id uuid)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare d charge_disputes;
begin
  select * into d from charge_disputes where id = p_id for update;
  if d.id is null or not dispute_mine_ok(d) then raise exception 'Not found.' using errcode = '42501'; end if;
  if d.status not in ('open', 'answered') then raise exception 'This question is already closed.'; end if;
  update charge_disputes set status = 'withdrawn', closed_at = now(), closed_by = lower(auth.email()), updated_at = now(),
    thread = thread || jsonb_build_array(jsonb_build_object('at', now(), 'by', d.side, 'name', d.raised_by_name, 'text', 'Withdrew the question.'))
  where id = p_id returning * into d;
  return dispute_row(d, false);
end;
$$;
revoke all on function dispute_withdraw(uuid) from public, anon;
grant execute on function dispute_withdraw(uuid) to authenticated;

-- ---- Staff ---------------------------------------------------------------
create or replace function disputes_staff_list(p_all boolean)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return (select coalesce(jsonb_agg(dispute_row(d, true) order by d.status not in ('open', 'answered'), d.status <> 'open', d.updated_at desc), '[]'::jsonb)
          from charge_disputes d where coalesce(p_all, false) or d.status in ('open', 'answered') or d.closed_at > now() - interval '30 days');
end;
$$;
revoke all on function disputes_staff_list(boolean) from public, anon;
grant execute on function disputes_staff_list(boolean) to authenticated;

-- Email the person who raised it (and, for tenants, every tenant on the lease).
create or replace function dispute_notify(d charge_disputes, p_subject text, p_html text)
returns void language plpgsql volatile security definer set search_path = public as $$
begin
  if d.side = 'tenant' then
    perform lease_email_tenants(d.lease_id, p_subject, p_html, 'dispute');
  else
    insert into email_outbox (to_email, subject, html, kind) values (d.raised_by_email, p_subject,
      '<p>Hi ' || repair_esc(split_part(coalesce(d.raised_by_name, ''), ' ', 1)) || ',</p>' || p_html || '<p>2nd Chance Housing</p>', 'dispute');
  end if;
end;
$$;
revoke all on function dispute_notify(charge_disputes, text, text) from public, anon, authenticated;

create or replace function dispute_line_html(d charge_disputes)
returns text language sql immutable as $$
  select 'the ' || to_char(d.entry_amount, 'FM$999,990.00') || ' charge of ' || to_char(d.entry_date, 'FMMM/FMDD/YYYY')
    || coalesce(' (' || repair_esc(d.entry_description) || ')', '') || coalesce(' for Unit ' || repair_esc(d.unit_number), '');
$$;

-- Answer: explain, leave it open for a reply.
create or replace function dispute_staff_answer(p_id uuid, p_text text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare d charge_disputes;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if length(coalesce(trim(p_text), '')) < 3 then raise exception 'Write the answer.'; end if;
  select * into d from charge_disputes where id = p_id for update;
  if d.id is null then raise exception 'Not found'; end if;
  if d.status not in ('open', 'answered') then raise exception 'This dispute is closed (%).', d.status; end if;
  update charge_disputes set status = 'answered', updated_at = now(),
    thread = thread || jsonb_build_array(jsonb_build_object('at', now(), 'by', 'staff', 'name', 'Office', 'text', left(trim(p_text), 2000)))
  where id = p_id returning * into d;
  perform dispute_notify(d, 'About the charge you questioned',
    '<p>About ' || dispute_line_html(d) || ':</p><p>' || repair_esc(trim(p_text)) || '</p><p>You can reply in your portal.</p>');
  return dispute_row(d, true);
end;
$$;
revoke all on function dispute_staff_answer(uuid, text) from public, anon;
grant execute on function dispute_staff_answer(uuid, text) to authenticated;

create or replace function dispute_staff_deny(p_id uuid, p_text text)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare d charge_disputes;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if length(coalesce(trim(p_text), '')) < 10 then raise exception 'Explain why the charge stands (the tenant or owner sees it).'; end if;
  select * into d from charge_disputes where id = p_id for update;
  if d.id is null then raise exception 'Not found'; end if;
  if d.status not in ('open', 'answered') then raise exception 'This dispute is closed (%).', d.status; end if;
  update charge_disputes set status = 'denied', staff_response = left(trim(p_text), 2000), closed_by = lower(auth.email()), closed_at = now(), updated_at = now(),
    thread = thread || jsonb_build_array(jsonb_build_object('at', now(), 'by', 'staff', 'name', 'Office', 'text', left(trim(p_text), 2000)))
  where id = p_id returning * into d;
  perform dispute_notify(d, 'The charge you questioned stands',
    '<p>We reviewed ' || dispute_line_html(d) || '. The charge stands.</p><p>' || repair_esc(d.staff_response) || '</p>');
  return dispute_row(d, true);
end;
$$;
revoke all on function dispute_staff_deny(uuid, text) from public, anon;
grant execute on function dispute_staff_deny(uuid, text) to authenticated;

-- Adjust: post a credit on the same ledger (same GL account), never touching the original line.
create or replace function dispute_staff_adjust(p_id uuid, p_amount numeric, p_text text, p_date date default null)
returns jsonb language plpgsql volatile security definer set search_path = public as $$
declare d charge_disputes; v_gl text; v_id bigint; v_note text; v_date date := coalesce(p_date, current_date);
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if length(coalesce(trim(p_text), '')) < 5 then raise exception 'Say what was wrong and what you credited (the tenant or owner sees it).'; end if;
  select * into d from charge_disputes where id = p_id for update;
  if d.id is null then raise exception 'Not found'; end if;
  if d.status not in ('open', 'answered') then raise exception 'This dispute is closed (%).', d.status; end if;
  if p_amount is null or p_amount <= 0 or p_amount > d.entry_amount then
    raise exception 'The credit must be more than $0 and no more than the charge, %.', to_char(d.entry_amount, 'FM$999,990.00'); end if;
  if v_date > current_date + 31 then raise exception 'The credit date can''t be more than a month ahead.'; end if;
  v_note := 'Charge dispute ' || left(d.id::text, 8) || ': ' || left(trim(p_text), 400) || ' (questioned by ' || coalesce(d.raised_by_name, d.raised_by_email)
            || ' ' || to_char(d.created_at, 'FMMM/FMDD/YYYY') || '; credited by ' || lower(auth.email()) || ')';
  if d.side = 'tenant' then
    select gl_account into v_gl from lease_ledger_entries where id = d.lease_entry_id;
    insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, description, amount, source, correction_note)
    values (d.lease_id, v_gl, v_date, 'credit', 'Credit', 'Adjustment: ' || coalesce(d.entry_description, 'charge') || ' of ' || to_char(d.entry_date, 'FMMM/FMDD/YYYY'),
            -p_amount, 'dispute', v_note)
    returning id into v_id;
  else
    select gl_account into v_gl from condo_ledger_entries where id = d.condo_entry_id;
    insert into condo_ledger_entries (account_id, gl_account, entry_date, kind, raw_type, description, amount, origin, entered_by, correction_note)
    values (d.condo_account_id, v_gl, v_date, 'credit', 'Credit', 'Adjustment: ' || coalesce(d.entry_description, 'charge') || ' of ' || to_char(d.entry_date, 'FMMM/FMDD/YYYY'),
            -p_amount, 'staff', lower(auth.email()), v_note)
    returning id into v_id;
  end if;
  update charge_disputes set status = 'adjusted', staff_response = left(trim(p_text), 2000), adjustment_entry_id = v_id, adjustment_amount = p_amount,
    closed_by = lower(auth.email()), closed_at = now(), updated_at = now(),
    thread = thread || jsonb_build_array(jsonb_build_object('at', now(), 'by', 'staff', 'name', 'Office',
      'text', 'Credited ' || to_char(p_amount, 'FM$999,990.00') || '. ' || left(trim(p_text), 2000)))
  where id = p_id returning * into d;
  perform dispute_notify(d, 'We credited your account',
    '<p>We reviewed ' || dispute_line_html(d) || ' and credited <b>' || to_char(p_amount, 'FM$999,990.00') || '</b> to your account on '
    || to_char(v_date, 'FMMM/FMDD/YYYY') || '.</p><p>' || repair_esc(d.staff_response) || '</p><p>The original charge stays on the ledger with the credit right after it.</p>');
  return dispute_row(d, true);
end;
$$;
revoke all on function dispute_staff_adjust(uuid, numeric, text, date) from public, anon;
grant execute on function dispute_staff_adjust(uuid, numeric, text, date) to authenticated;
