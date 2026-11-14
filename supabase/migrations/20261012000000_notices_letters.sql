-- Notices & letters, from the earlier mailing templates ([[Field]] merge fields).
-- Staff compose a notice for a lease; the system fills what it knows (tenants,
-- unit, owner, rent, unpaid rent, deposit, dates), staff fill the rest, and the
-- notices function builds the PDF, emails every tenant on the lease, files it in
-- their resident portal (Documents -> Notices) and records it. Legal service
-- (personal delivery / mail / posting under Wis. Stat. 704.21) is recorded
-- separately: an emailed copy is not legal service by itself.

create table if not exists letter_templates (
  id uuid primary key default gen_random_uuid(),
  legacy_id text unique,
  recipient text not null,             -- Tenant | Rental-owner | Applicant | Association-owner
  name text not null,
  subject text,
  description text,
  html text not null,
  fields text[] not null default '{}',
  active boolean not null default true
);
alter table letter_templates enable row level security;

create table if not exists notices (
  id uuid primary key default gen_random_uuid(),
  lease_id uuid references leases(id),
  template_id uuid references letter_templates(id),
  template_name text not null,
  subject text not null,
  html text not null,
  html_sha256 text not null,
  pdf_path text,
  sent_by text not null,
  sent_at timestamptz not null default now(),
  signed_by_agent boolean not null default false,
  emailed_to text[] not null default '{}',
  service_method text check (service_method in ('personal', 'mail', 'certified_mail', 'posted', 'email_only')),
  served_on date,
  service_note text,
  voided boolean not null default false
);
create index if not exists notices_lease_idx on notices (lease_id, sent_at desc);
alter table notices enable row level security;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('notices', 'notices', false, 10485760, array['application/pdf'])
on conflict (id) do update set public = false;

drop policy if exists "notices read" on storage.objects;
create policy "notices read" on storage.objects for select to authenticated
  using (bucket_id = 'notices' and condo_session_ok() and (condo_is_staff() or exists (
    select 1 from notices n join lease_tenants lt on lt.lease_id = n.lease_id
    where n.pdf_path = storage.objects.name and not n.voided and lt.tenant_id in (select resident_me()))));

-- ---------------------------------------------------------------------------
-- Staff functions
-- ---------------------------------------------------------------------------
create or replace function letter_templates_list()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'recipient', recipient, 'name', name, 'subject', subject,
      'description', description, 'html', html, 'fields', fields) order by recipient, name) from letter_templates where active), '[]'::jsonb);
end;
$$;

-- Everything the system knows for one lease, keyed by the original field name.
create or replace function notice_context(p_lease_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  l leases; u rental_units; p rental_properties; cu condo_units;
  v_owner text; v_tenants text; v_first text; v_last text; v_emails text;
  v_rent_balance numeric; v_balance numeric; v_agent lease_agents; v_sender text; v_sender_phone text; v_sender_email text;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into l from leases where id = p_lease_id;
  if l.id is null then raise exception 'Lease not found'; end if;
  select * into u from rental_units where id = l.unit_id;
  select * into p from rental_properties where id = u.property_id;
  select * into cu from condo_units where id = u.condo_unit_id;
  select o.name into v_owner from condo_ownerships s join condo_owners o on o.id = s.owner_id where s.unit_id = u.condo_unit_id and s.is_current order by s.start_date desc limit 1;
  select string_agg(t.name, ', ' order by t.name), string_agg(t.email, ', ' order by t.name) into v_tenants, v_emails
    from lease_tenants lt join tenants t on t.id = lt.tenant_id where lt.lease_id = l.id;
  select split_part(t.name, ' ', 1), regexp_replace(t.name, '^\S+\s*', '') into v_first, v_last
    from lease_tenants lt join tenants t on t.id = lt.tenant_id where lt.lease_id = l.id order by t.name limit 1;
  select coalesce(sum(amount), 0) into v_balance from lease_ledger_entries where lease_id = l.id;
  -- Unpaid RENT only (the 5-day notice's amount to avoid eviction excludes late fees).
  select greatest(coalesce(sum(amount), 0), 0) into v_rent_balance from lease_ledger_entries where lease_id = l.id and gl_account in ('Rent Income', 'Rent Charge');
  select * into v_agent from lease_agents where active order by created_at limit 1;
  select coalesce(a.name, s.name), coalesce(a.phone_mobile, s.phone_mobile), lower(auth.email()) into v_sender, v_sender_phone, v_sender_email
    from condo_staff s left join lease_agents a on lower(a.email) = lower(s.email) where lower(s.email) = lower(auth.email());
  return jsonb_build_object(
    'Current_Date', to_char(current_date, 'FMMonth FMDD, YYYY'), 'Current_Month', to_char(current_date, 'FMMonth'), 'Current_Year', to_char(current_date, 'YYYY'),
    'Unit_Address_Line_1', coalesce(regexp_replace(u.address, '\s*-\s*\d+$', ''), p.street), 'Unit_Number', coalesce(u.unit_number, ''),
    'Unit_Address', coalesce(u.address, p.street) || ', ' || coalesce(p.city, 'Milwaukee') || ', ' || coalesce(p.state, 'WI') || ' ' || coalesce(p.zip, ''),
    'Unit_City_Address', coalesce(p.city, 'Milwaukee'), 'Unit_City', coalesce(p.city, 'Milwaukee'),
    'Unit_State_Address', coalesce(p.state, 'WI'), 'Unit_State', coalesce(p.state, 'WI'),
    'Unit_PostalCode_Address', coalesce(p.zip, ''), 'Unit_Postal_Code', coalesce(p.zip, ''),
    'Property_Address_Line_1', coalesce(p.street, ''), 'Property_Name', p.name,
    'Rental_Owner_Full_Name', coalesce(v_owner, '2nd Chance Housing Inc.'), 'Rental_Owners_Full_Name', coalesce(v_owner, '2nd Chance Housing Inc.'),
    'Tenant_First_Name', coalesce(v_first, ''), 'Tenant_Last_Name', coalesce(v_last, ''), 'Tenants_Full_Name', coalesce(v_tenants, ''),
    'Lease_All_Tenants', coalesce(v_tenants, ''), 'Tenants_Email', coalesce(v_emails, ''), 'Tenant_Address_1', coalesce(u.address, p.street),
    'Lease_Rent', to_char(coalesce(l.rent, 0), 'FM$999,990.00'), 'Lease_Rent_Due_Day', '1st',
    'Rent_Balance', to_char(v_rent_balance, 'FM$999,990.00'), 'Account_Balance', to_char(v_balance, 'FM$999,990.00'),
    'Lease_Start_Date', to_char(l.start_date, 'FMMM/FMDD/YYYY'), 'Lease_End_Date', coalesce(to_char(l.end_date, 'FMMM/FMDD/YYYY'), 'month-to-month'),
    'Lease_Security_Deposit', to_char(coalesce(l.deposit_held, 0), 'FM$999,990.00'),
    'Sender_Name', coalesce(v_sender, ''), 'Sender_Phone', coalesce(v_sender_phone, (select value from portal_settings where key = 'office_phone')),
    'Sender_Email', coalesce(v_sender_email, ''), 'Sender_URL', '2ndchinc.org',
    '_lease_label', coalesce(u.address, p.street) || ' — ' || coalesce(v_tenants, ''),
    '_sender_is_agent', exists (select 1 from lease_agents a where a.active and lower(a.email) = lower(auth.email()) and a.signature_path is not null)
  );
end;
$$;

create or replace function notices_staff_list()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'template_name', n.template_name, 'subject', n.subject, 'sent_at', n.sent_at,
      'sent_by', n.sent_by, 'signed_by_agent', n.signed_by_agent, 'emailed_to', n.emailed_to, 'pdf_path', n.pdf_path, 'service_method', n.service_method,
      'served_on', n.served_on, 'service_note', n.service_note, 'voided', n.voided, 'lease_label', u.address || ' — ' || l.tenants_label) order by n.sent_at desc)
    from notices n left join leases l on l.id = n.lease_id left join rental_units u on u.id = l.unit_id), '[]'::jsonb);
end;
$$;

create or replace function notice_record_service(p_id uuid, p_method text, p_served_on date, p_note text)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  update notices set service_method = p_method, served_on = p_served_on, service_note = nullif(trim(coalesce(p_note, '')), '') where id = p_id;
  if not found then raise exception 'Notice not found'; end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- Active leases to address a notice to.
create or replace function notice_leases()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'label', coalesce(u.unit_number, '') || ' — ' || l.tenants_label, 'address', u.address)
      order by nullif(regexp_replace(coalesce(u.unit_number, ''), '\D', '', 'g'), '')::int nulls last)
    from leases l join rental_units u on u.id = l.unit_id where l.status = 'active'), '[]'::jsonb);
end;
$$;

revoke all on function letter_templates_list() from public, anon;
revoke all on function notice_context(uuid) from public, anon;
revoke all on function notices_staff_list() from public, anon;
revoke all on function notice_record_service(uuid, text, date, text) from public, anon;
revoke all on function notice_leases() from public, anon;
grant execute on function letter_templates_list() to authenticated;
grant execute on function notice_context(uuid) to authenticated;
grant execute on function notices_staff_list() to authenticated;
grant execute on function notice_record_service(uuid, text, date, text) to authenticated;
grant execute on function notice_leases() to authenticated;

-- Residents: their notices (for the portal's Documents -> Notices).
create or replace function resident_notices()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not exists (select resident_me()) then raise exception 'Resident two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'subject', n.subject, 'name', n.template_name, 'sent_at', n.sent_at, 'pdf_path', n.pdf_path) order by n.sent_at desc)
    from notices n where not n.voided and exists (select 1 from lease_tenants lt where lt.lease_id = n.lease_id and lt.tenant_id in (select resident_me()))), '[]'::jsonb);
end;
$$;
revoke all on function resident_notices() from public, anon;
grant execute on function resident_notices() to authenticated;

-- Storage policies can't see rows in RLS-locked tables, so the "may this
-- resident open this file?" checks run in security-definer functions.
create or replace function resident_can_read_notice(p_path text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select condo_session_ok() and exists (
    select 1 from notices n join lease_tenants lt on lt.lease_id = n.lease_id
    where n.pdf_path = p_path and not n.voided and lt.tenant_id in (select resident_me()));
$$;
create or replace function resident_can_read_signed_lease(p_path text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select condo_session_ok() and exists (
    select 1 from lease_signing_docs d join lease_signing_signers s on s.doc_id = d.id
    where d.executed_pdf_path = p_path and lower(s.email) = lower(auth.email()));
$$;
revoke all on function resident_can_read_notice(text) from public, anon;
revoke all on function resident_can_read_signed_lease(text) from public, anon;
grant execute on function resident_can_read_notice(text) to authenticated;
grant execute on function resident_can_read_signed_lease(text) to authenticated;

drop policy if exists "notices read" on storage.objects;
create policy "notices read" on storage.objects for select to authenticated
  using (bucket_id = 'notices' and ((condo_session_ok() and condo_is_staff()) or resident_can_read_notice(name)));
drop policy if exists "lease-signing resident read" on storage.objects;
create policy "lease-signing resident read" on storage.objects for select to authenticated
  using (bucket_id = 'lease-signing' and name not like 'agents/%' and resident_can_read_signed_lease(name));
