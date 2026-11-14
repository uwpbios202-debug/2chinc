-- Moving tenants onto this system (10/9/2026): two things every tenant needs.
--
-- 1. REGISTER. A tenant whose email on file is stale cannot get a sign-in code, so before signing in they can
--    prove who they are with the short code on the notice we hand them (plus their last name), confirm their
--    phone, and change their email (the new address must receive a code first). Codes are stored as hashes only;
--    staff can issue a fresh one (shown once). The edge function tenant-register does the checking.
-- 2. REPORT A PROBLEM. A button on every tenant-facing page sends what the person sees (page, device, message,
--    optional photo, who they are if signed in) into issue_reports. Staff see them on /staff/reports/ with
--    one-tap repairs: fix the tenant's email or phone, issue a new registration code, reply, mark resolved.
--
-- Nothing here is readable by anon or authenticated users directly: only the service role (the edge
-- functions) and the staff functions below.

create table if not exists tenant_reg_codes (
  tenant_id uuid primary key references tenants(id) on delete cascade,
  code_hash text not null,
  issued_at timestamptz not null default now(),
  issued_by text,
  used_at timestamptz,
  failed_tries int not null default 0
);
create unique index if not exists tenant_reg_codes_hash_idx on tenant_reg_codes (code_hash);

create table if not exists register_sessions (
  id uuid primary key default gen_random_uuid(),
  token_hash text not null unique,
  tenant_id uuid not null references tenants(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '30 minutes'
);

create table if not exists register_email_codes (
  id bigint generated always as identity primary key,
  tenant_id uuid not null references tenants(id) on delete cascade,
  new_email text not null,
  code_hash text not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '10 minutes',
  attempts int not null default 0,
  used_at timestamptz
);
create index if not exists register_email_codes_tenant_idx on register_email_codes (tenant_id, created_at desc);

-- Rate limiting for the public endpoints: one row per attempt (kind: 'code_try', 'email_code', 'report').
create table if not exists register_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  kind text not null,
  ip text,
  tenant_id uuid,
  ok boolean
);
create index if not exists register_log_idx on register_log (kind, at desc);

create table if not exists issue_reports (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  status text not null default 'new' check (status in ('new', 'fixing', 'resolved')),
  page_url text,
  page_title text,
  user_agent text,
  viewport text,
  message text not null,
  contact_name text,
  contact_email text,
  contact_phone text,
  tenant_id uuid references tenants(id) on delete set null,   -- set when the person was signed in, or matched by email
  signed_in_email text,
  errors jsonb not null default '[]'::jsonb,                  -- recent script errors on the page
  photo_path text,                                            -- private bucket issue-reports
  staff_note text,
  resolved_at timestamptz,
  resolved_by text
);
create index if not exists issue_reports_status_idx on issue_reports (status, created_at desc);

alter table tenant_reg_codes enable row level security;
alter table register_sessions enable row level security;
alter table register_email_codes enable row level security;
alter table register_log enable row level security;
alter table issue_reports enable row level security;
-- No policies: service role and the security-definer functions below only.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('issue-reports', 'issue-reports', false, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "issue-reports staff read" on storage.objects;
create policy "issue-reports staff read" on storage.objects
  for select to authenticated
  using (bucket_id = 'issue-reports' and condo_session_ok() and condo_is_staff());

-- ---------------------------------------------------------------------------
-- Registration codes
-- ---------------------------------------------------------------------------

-- 8 characters from an alphabet with no look-alikes (no 0/O, 1/I/L), from the database's strong random source.
create or replace function reg_code_make()
returns text language plpgsql volatile as $$
declare alpha constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789'; b bytea := decode(replace(gen_random_uuid()::text, '-', ''), 'hex'); s text := ''; i int;
begin
  for i in 0..7 loop s := s || substr(alpha, (get_byte(b, i) % 31) + 1, 1); end loop;
  return s;
end;
$$;
revoke all on function reg_code_make() from public, anon, authenticated;

-- Staff: a fresh code for one tenant, shown once. The old code stops working.
create or replace function tenant_staff_issue_code(p_tenant uuid)
returns text
language plpgsql volatile security definer set search_path = public
as $$
declare v text;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if not exists (select 1 from tenants where id = p_tenant) then raise exception 'Tenant not found'; end if;
  loop
    v := reg_code_make();
    exit when not exists (select 1 from tenant_reg_codes where code_hash = encode(sha256(convert_to(v, 'UTF8')), 'hex'));
  end loop;
  insert into tenant_reg_codes (tenant_id, code_hash, issued_by) values (p_tenant, encode(sha256(convert_to(v, 'UTF8')), 'hex'), lower(auth.email()))
  on conflict (tenant_id) do update set code_hash = excluded.code_hash, issued_at = now(), issued_by = excluded.issued_by, used_at = null, failed_tries = 0;
  insert into apply_access_log (staff_email, action, detail) values (auth.email(), 'status', 'registration code issued for tenant ' || p_tenant::text);
  return v;
end;
$$;
revoke all on function tenant_staff_issue_code(uuid) from public, anon;
grant execute on function tenant_staff_issue_code(uuid) to authenticated;

-- Service role only: codes for every tenant on an active or future lease who does not have one yet (the launch
-- notices). Returns the plaintext once, for printing. p_reissue = true replaces existing codes too.
create or replace function tenant_codes_issue_active(p_reissue boolean)
returns table (tenant_id uuid, tenant_name text, unit_number text, address text, account_number text, code text)
language plpgsql volatile security definer set search_path = public
as $$
declare r record; v text;
begin
  for r in
    select distinct on (t.id) t.id, t.name, u.unit_number, u.address, l.legacy_lease_number acct
      from leases l join lease_tenants lt on lt.lease_id = l.id join tenants t on t.id = lt.tenant_id join rental_units u on u.id = l.unit_id
     where l.status in ('active', 'future')
       and (p_reissue or not exists (select 1 from tenant_reg_codes c where c.tenant_id = t.id))
     order by t.id, l.start_date desc
  loop
    loop
      v := reg_code_make();
      exit when not exists (select 1 from tenant_reg_codes c2 where c2.code_hash = encode(sha256(convert_to(v, 'UTF8')), 'hex'));
    end loop;
    insert into tenant_reg_codes (tenant_id, code_hash, issued_by) values (r.id, encode(sha256(convert_to(v, 'UTF8')), 'hex'), 'launch notices')
    on conflict on constraint tenant_reg_codes_pkey do update set code_hash = excluded.code_hash, issued_at = now(), issued_by = excluded.issued_by, used_at = null, failed_tries = 0;
    tenant_id := r.id; tenant_name := r.name; unit_number := r.unit_number; address := r.address; account_number := r.acct; code := v;
    return next;
  end loop;
end;
$$;
revoke all on function tenant_codes_issue_active(boolean) from public, anon, authenticated;
grant execute on function tenant_codes_issue_active(boolean) to service_role;

-- ---------------------------------------------------------------------------
-- Staff: reports and one-tap repairs
-- ---------------------------------------------------------------------------

create or replace function reports_staff_list()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.created_at desc) from (
      select r.*, t.name as tenant_name, t.email as tenant_email, t.phone as tenant_phone,
             (select string_agg(distinct u.unit_number, ', ') from lease_tenants lt join leases l on l.id = lt.lease_id and l.status in ('active', 'future')
                join rental_units u on u.id = l.unit_id where lt.tenant_id = t.id) as unit,
             (select l.id from lease_tenants lt join leases l on l.id = lt.lease_id and l.status in ('active', 'future') where lt.tenant_id = t.id order by l.start_date desc limit 1) as lease_id,
             (select c.used_at from tenant_reg_codes c where c.tenant_id = t.id) as code_used_at,
             exists (select 1 from tenant_reg_codes c where c.tenant_id = t.id) as has_code
        from issue_reports r left join tenants t on t.id = r.tenant_id
       order by (r.status = 'resolved'), r.created_at desc limit 300) x), '[]'::jsonb);
end;
$$;
revoke all on function reports_staff_list() from public, anon;
grant execute on function reports_staff_list() to authenticated;

create or replace function report_staff_update(p_id uuid, p_status text, p_note text)
returns void
language plpgsql volatile security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if p_status not in ('new', 'fixing', 'resolved') then raise exception 'Unknown status'; end if;
  update issue_reports set status = p_status, staff_note = coalesce(nullif(trim(p_note), ''), staff_note),
         resolved_at = case when p_status = 'resolved' then now() else null end,
         resolved_by = case when p_status = 'resolved' then lower(auth.email()) else null end where id = p_id;
  if not found then raise exception 'Report not found'; end if;
end;
$$;
revoke all on function report_staff_update(uuid, text, text) from public, anon;
grant execute on function report_staff_update(uuid, text, text) to authenticated;

-- Link a report to a tenant (staff pick one when the person was not signed in).
create or replace function report_staff_link_tenant(p_id uuid, p_tenant uuid)
returns void
language plpgsql volatile security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  update issue_reports set tenant_id = p_tenant where id = p_id;
end;
$$;
revoke all on function report_staff_link_tenant(uuid, uuid) from public, anon;
grant execute on function report_staff_link_tenant(uuid, uuid) to authenticated;

create or replace function tenant_staff_search(p_q text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare q text := '%' || lower(trim(coalesce(p_q, ''))) || '%';
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if length(trim(coalesce(p_q, ''))) < 2 then return '[]'::jsonb; end if;
  return coalesce((select jsonb_agg(x) from (
    select t.id, t.name, t.email, t.phone,
           (select string_agg(distinct u.unit_number, ', ') from lease_tenants lt join leases l on l.id = lt.lease_id and l.status in ('active', 'future') join rental_units u on u.id = l.unit_id where lt.tenant_id = t.id) as unit
      from tenants t where lower(t.name) like q or lower(coalesce(t.email, '')) like q
     order by t.name limit 15) x), '[]'::jsonb);
end;
$$;
revoke all on function tenant_staff_search(text) from public, anon;
grant execute on function tenant_staff_search(text) to authenticated;

-- The immediate repair: set a tenant's email and/or phone. The change is logged in tenant_contact_changes.
create or replace function tenant_staff_set_contact(p_tenant uuid, p_email text, p_phone text)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare t tenants; v_email text := nullif(lower(trim(coalesce(p_email, ''))), ''); v_phone text := nullif(trim(coalesce(p_phone, '')), '');
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into t from tenants where id = p_tenant for update;
  if t.id is null then raise exception 'Tenant not found'; end if;
  if v_email is not null and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'That is not a full email address.'; end if;
  if v_email is not null and v_email is distinct from lower(t.email) then
    insert into tenant_contact_changes (requested_by, field, old_value, new_value, status, decided_by, decided_at, note)
    values (lower(auth.email()), 'email', t.email, v_email, 'applied', lower(auth.email()), now(), 'Changed by staff from a problem report');
    update tenants set email = v_email where id = t.id;
  end if;
  if v_phone is not null and v_phone is distinct from t.phone then
    insert into tenant_contact_changes (requested_by, field, old_value, new_value, status, decided_by, decided_at, note)
    values (lower(auth.email()), 'phone', t.phone, v_phone, 'applied', lower(auth.email()), now(), 'Changed by staff from a problem report');
    update tenants set phone = v_phone where id = t.id;
  end if;
  return (select jsonb_build_object('name', name, 'email', email, 'phone', phone) from tenants where id = t.id);
end;
$$;
revoke all on function tenant_staff_set_contact(uuid, text, text) from public, anon;
grant execute on function tenant_staff_set_contact(uuid, text, text) to authenticated;

-- Today: problem reports waiting for staff.
create or replace function staff_today()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v jsonb := '[]'::jsonb;
  n int;
  d int;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;

  -- Leasing
  select count(*) into n from rental_applications where status in ('new', 'reviewing');
  v := v || jsonb_build_object('key', 'applications', 'grp', 'Leasing', 'label', 'Applications to review', 'n', n, 'href', '/leasing/applications/', 'urgent', false);

  select count(*) into n from rental_applications a
   where a.status = 'approved'
     and a.existing_lease_id is null
     and not exists (select 1 from lease_signing_docs s where s.application_id = a.id and s.status <> 'void');
  v := v || jsonb_build_object('key', 'approved_no_lease', 'grp', 'Leasing', 'label', 'Approved, lease not sent yet', 'n', n, 'href', '/leasing/applications/', 'urgent', n > 0);

  select count(*) into n from lease_signing_docs where status = 'sent';
  v := v || jsonb_build_object('key', 'awaiting_tenant', 'grp', 'Leasing', 'label', 'Leases waiting for the tenant to sign', 'n', n, 'href', '/leasing/applications/', 'urgent', false);

  select count(*) into n from issue_reports where status = 'new';
  v := v || jsonb_build_object('key', 'problem_reports', 'grp', 'Residents', 'label', 'Problem reports to look at', 'n', n, 'href', '/staff/reports/', 'urgent', n > 0);

  select count(*) into n from lease_signing_docs where status = 'awaiting_agent';
  v := v || jsonb_build_object('key', 'countersign', 'grp', 'Leasing', 'label', 'Leases to countersign', 'n', n, 'href', '/leasing/countersign/', 'urgent', n > 0);

  select count(*), min(l.end_date - current_date) into n, d from leases l
   where l.status = 'active' and l.end_date between current_date and current_date + 60
     and not exists (select 1 from lease_renewals r where r.lease_id = l.id and r.status in ('offered', 'accepted', 'signed', 'declined', 'non_renewal'))
     and not exists (select 1 from move_outs m where m.lease_id = l.id and m.status <> 'closed');
  v := v || jsonb_build_object('key', 'renewals', 'grp', 'Leasing', 'label', 'Leases ending within 60 days, no renewal decision', 'n', n, 'href', '/leasing/renewals/',
                               'urgent', coalesce(d, 99) <= 30, 'note', case when n > 0 then 'first one ends in ' || d || ' day' || case when d = 1 then '' else 's' end end);

  -- Move-ins and move-outs
  select count(*) into n from move_in_checklists where status = 'submitted';
  v := v || jsonb_build_object('key', 'move_in_checklists', 'grp', 'Move-ins & move-outs', 'label', 'Move-in checklists to review', 'n', n, 'href', '/inspections/move-in/', 'urgent', false);

  select count(*) into n from leases where keys_ready_at is not null and keys_released_at is null;
  v := v || jsonb_build_object('key', 'keys', 'grp', 'Move-ins & move-outs', 'label', 'Paid in full, keys not handed over', 'n', n, 'href', '/inspections/move-in/', 'urgent', n > 0);

  select count(*) into n from move_out_checklists where status = 'submitted';
  v := v || jsonb_build_object('key', 'move_out_checklists', 'grp', 'Move-ins & move-outs', 'label', 'Move-out checklists to review', 'n', n, 'href', '/inspections/move-out/', 'urgent', false);

  -- Wis. Stat. 704.28: the deposit statement is due 21 days after the tenant leaves.
  select count(*), min(deposit_due_by - current_date) into n, d from move_outs
   where status in ('vacated', 'inspected') and deposit_due_by is not null and deposit_due_by - current_date <= 7;
  v := v || jsonb_build_object('key', 'deposit_deadline', 'grp', 'Move-ins & move-outs', 'label', 'Deposit statements due within 7 days', 'n', n, 'href', '/inspections/move-out/',
                               'urgent', n > 0, 'note', case when n > 0 then case when d < 0 then 'one is ' || -d || ' day' || case when d = -1 then '' else 's' end || ' late'
                                                                            when d = 0 then 'one is due today' else 'next due in ' || d || ' day' || case when d = 1 then '' else 's' end end end);

  -- Residents
  select count(*) into n from maintenance_requests where status = 'new';
  v := v || jsonb_build_object('key', 'repairs_new', 'grp', 'Residents', 'label', 'New repair requests', 'n', n, 'href', '/maintenance/', 'urgent', n > 0);

  select count(*) into n from maintenance_requests where status in ('scheduled', 'in_progress');
  v := v || jsonb_build_object('key', 'repairs_open', 'grp', 'Residents', 'label', 'Repairs scheduled or in progress', 'n', n, 'href', '/maintenance/', 'urgent', false);

  select count(distinct tenant_id) into n from tenant_messages where from_resident and read_at is null;
  v := v || jsonb_build_object('key', 'messages', 'grp', 'Residents', 'label', 'Residents with unread messages', 'n', n, 'href', '/resident/messages/', 'urgent', n > 0);

  select count(*) into n from tenant_contact_changes where status = 'pending';
  v := v || jsonb_build_object('key', 'contact_changes', 'grp', 'Residents', 'label', 'Contact changes to approve', 'n', n, 'href', '/resident/messages/', 'urgent', false);

  select count(*) into n from guest_requests where status = 'pending';
  v := v || jsonb_build_object('key', 'guests', 'grp', 'Residents', 'label', 'Guest requests to decide', 'n', n, 'href', '/parking/', 'urgent', false);

  -- Money
  select count(*) into n from payment_reports where status = 'pending';
  v := v || jsonb_build_object('key', 'payments', 'grp', 'Money', 'label', 'Reported payments to verify', 'n', n, 'href', '/accounting/tenant-side/payments/', 'urgent', n > 0);

  select count(*) into n from bank_receipts b
   where b.matched_report_id is null and b.assigned_lease_id is null and not b.ignored
     and b.status not in ('posted', 'stripe_payout', 'ignored') and b.posted_on > current_date - 120;
  v := v || jsonb_build_object('key', 'bank', 'grp', 'Money', 'label', 'Bank deposits to match', 'n', n, 'href', '/accounting/bank/', 'urgent', false);

  select count(*) into n from charge_disputes where status = 'open';
  v := v || jsonb_build_object('key', 'disputes', 'grp', 'Money', 'label', 'Charge questions to answer', 'n', n, 'href', '/accounting/disputes/', 'urgent', n > 0);

  -- ROCA1
  select count(*) into n from condo_violations where status in ('open', 'hearing_requested');
  v := v || jsonb_build_object('key', 'violations', 'grp', 'ROCA1', 'label', 'Violations needing a next step', 'n', n, 'href', '/association-owners/roca1/violations/', 'urgent', false);

  select count(*) into n from roca_resolutions where status = 'voting';
  v := v || jsonb_build_object('key', 'votes', 'grp', 'ROCA1', 'label', 'Board votes open', 'n', n, 'href', '/association-owners/roca1/board/', 'urgent', false);

  select count(*) into n from roca_distributions where status = 'calculated';
  v := v || jsonb_build_object('key', 'distributions', 'grp', 'ROCA1', 'label', 'Rent deductions to approve', 'n', n, 'href', '/association-owners/roca1/distributions/', 'urgent', false);

  return jsonb_build_object('as_of', now(), 'items', v);
end;
$$;

revoke all on function staff_today() from public, anon;
grant execute on function staff_today() to authenticated;

-- Staff: who has registered? One row per person on an active or future lease.
create or replace function register_staff_status()
returns jsonb
language plpgsql stable security definer set search_path = public, auth
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(x order by (x->>'unit')::int nulls last, x->>'name') from (
    select distinct on (t.id) jsonb_build_object(
      'tenant_id', t.id, 'name', t.name, 'email', t.email, 'phone', t.phone, 'unit', u.unit_number,
      'code_issued_at', c.issued_at, 'code_used_at', c.used_at, 'code_failed_tries', c.failed_tries,
      'last_sign_in', (select max(a.last_sign_in_at) from auth.users a where lower(a.email) = lower(t.email))) as x
      from leases l join lease_tenants lt on lt.lease_id = l.id join tenants t on t.id = lt.tenant_id join rental_units u on u.id = l.unit_id
      left join tenant_reg_codes c on c.tenant_id = t.id
     where l.status in ('active', 'future')
     order by t.id, l.start_date desc) s), '[]'::jsonb);
end;
$$;
revoke all on function register_staff_status() from public, anon;
grant execute on function register_staff_status() to authenticated;
