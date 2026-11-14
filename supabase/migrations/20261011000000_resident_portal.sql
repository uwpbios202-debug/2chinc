-- Resident portal (2ndchinc.org/resident/): tenants and land-contract buyers
-- sign in with the same two-step sign-in (email code + texted code) and see
-- their balance and payment history, lease details, documents (including
-- their e-signed leases), maintenance requests, contacts and announcements.

-- ---------------------------------------------------------------------------
-- Who is a resident: a tenant on an active lease, or a buyer on an active
-- land contract, matched by email.
-- ---------------------------------------------------------------------------
create or replace function resident_tenant_ids(p_email text)
returns setof uuid
language sql stable security definer set search_path = public
as $$
  select t.id from tenants t
  where lower(t.email) = lower(p_email)
    and (exists (select 1 from lease_tenants lt join leases l on l.id = lt.lease_id where lt.tenant_id = t.id and l.status = 'active')
      or exists (select 1 from land_contract_buyers b join land_contracts c on c.id = b.contract_id where b.tenant_id = t.id and c.status = 'active'));
$$;
revoke all on function resident_tenant_ids(text) from public, anon, authenticated;

-- The signed-in, two-step-verified resident's tenant ids.
create or replace function resident_me()
returns setof uuid
language sql stable security definer set search_path = public
as $$ select id from resident_tenant_ids(auth.email()) id where condo_session_ok(); $$;
revoke all on function resident_me() from public, anon;
grant execute on function resident_me() to authenticated;

create or replace function condo_email_on_file(p_email text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select condo_owner_for_email(p_email) is not null
      or exists (select 1 from condo_staff where lower(email) = lower(p_email))
      or exists (select 1 from lease_agents where active and lower(email) = lower(p_email))
      or exists (select 1 from resident_tenant_ids(p_email));
$$;

create or replace function condo_mfa_phone_for(p_email text)
returns text
language sql stable security definer set search_path = public
as $$
  select coalesce(
    (select phone_mobile from condo_staff where lower(email) = lower(p_email)),
    (select phone_mobile from condo_owners where id = condo_owner_for_email(p_email)),
    (select phone_mobile from lease_agents where active and lower(email) = lower(p_email)),
    (select t.phone from tenants t where t.id in (select resident_tenant_ids(p_email)) and t.phone is not null limit 1));
$$;

create or replace function condo_whoami()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_owner uuid := condo_owner_for_email(auth.email());
  v_staff boolean := condo_is_staff();
  v_agent uuid := (select id from lease_agents where active and lower(email) = lower(auth.email()));
  v_resident boolean := exists (select 1 from resident_tenant_ids(auth.email()));
  v_phone text;
begin
  if auth.uid() is null then
    return jsonb_build_object('role', 'none');
  end if;
  v_phone := condo_mfa_phone_for(auth.email());
  if not (v_staff or v_owner is not null or v_agent is not null or v_resident) then
    return jsonb_build_object('role', 'none');
  end if;
  return jsonb_build_object(
    'role', case when v_staff then 'staff' when v_owner is not null then 'owner' when v_agent is not null then 'agent' else 'resident' end,
    'is_owner', v_owner is not null,
    'is_agent', v_agent is not null,
    'is_resident', v_resident,
    'verified', condo_session_ok(),
    'phone_hint', condo_mask_phone(v_phone),
    'has_phone', v_phone is not null and length(regexp_replace(v_phone, '\D', '', 'g')) >= 10
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Office settings shown to residents
-- ---------------------------------------------------------------------------
create table if not exists portal_settings (key text primary key, value text not null);
alter table portal_settings enable row level security;
insert into portal_settings (key, value) values
  ('office_name', '2nd Chance Housing Inc.'),
  ('office_phone', '(414) 909-3279'),
  ('office_email', 'mkepropertymanager@gmail.com'),
  ('late_fee_policy', 'Payment is due on the 1st of the month. If payment isn''t received, a one-time fee of $75.00 will be charged on the 2nd of each month.'),
  ('pay_by_mail', 'ROCA1
6626 North Bourbon Street
Milwaukee, WI 53224')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- Vendors / contractors (the resident contact list is a subset)
-- ---------------------------------------------------------------------------
create table if not exists vendors (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  category text,
  contact_name text,
  email text,
  phone text,
  mobile text,
  address text,
  website text,
  eligible_1099 boolean not null default false,
  notes text,
  show_to_residents boolean not null default false,
  resident_category text,               -- label residents see, e.g. 'Pest Control', 'Maintenance'
  legacy_id text unique,
  created_at timestamptz not null default now()
);
alter table vendors enable row level security;

create table if not exists announcements (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  body text,
  status text not null default 'current' check (status in ('current', 'expired', 'draft')),
  created_on date not null default current_date,
  expires_on date,
  legacy_id text unique
);
alter table announcements enable row level security;

-- ---------------------------------------------------------------------------
-- Maintenance requests
-- ---------------------------------------------------------------------------
create sequence if not exists maintenance_request_number start 10000001;
create table if not exists maintenance_requests (
  id uuid primary key default gen_random_uuid(),
  number bigint not null unique default nextval('maintenance_request_number'),
  tenant_id uuid references tenants(id),
  lease_id uuid references leases(id),
  unit_label text,
  subject text not null,
  description text not null,
  entry_permission text not null default 'call_first' check (entry_permission in ('yes', 'no', 'call_first')),
  status text not null default 'new' check (status in ('new', 'in_progress', 'deferred', 'completed', 'closed')),
  photos text[] not null default '{}',
  vendor_id uuid references vendors(id),
  staff_notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  legacy_task_id text unique
);
create table if not exists maintenance_request_updates (
  id bigint generated always as identity primary key,
  request_id uuid not null references maintenance_requests(id) on delete cascade,
  at timestamptz not null default now(),
  by_email text,
  status text,
  note text,
  visible_to_resident boolean not null default true
);
alter table maintenance_requests enable row level security;
alter table maintenance_request_updates enable row level security;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('maintenance', 'maintenance', false, 15728640, array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif'])
on conflict (id) do update set public = false;

-- Residents upload/read photos only in their own folder (<tenant id>/...);
-- staff read all.
drop policy if exists "maintenance resident upload" on storage.objects;
create policy "maintenance resident upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'maintenance' and (storage.foldername(name))[1]::uuid in (select resident_me()));
drop policy if exists "maintenance read" on storage.objects;
create policy "maintenance read" on storage.objects for select to authenticated
  using (bucket_id = 'maintenance' and ((storage.foldername(name))[1]::uuid in (select resident_me()) or (condo_session_ok() and condo_is_staff())));

-- Residents can open the executed PDFs of leases they signed.
drop policy if exists "lease-signing resident read" on storage.objects;
create policy "lease-signing resident read" on storage.objects for select to authenticated
  using (bucket_id = 'lease-signing' and condo_session_ok() and exists (
    select 1 from lease_signing_docs d join lease_signing_signers s on s.doc_id = d.id
    where d.executed_pdf_path = storage.objects.name and lower(s.email) = lower(auth.email())));

-- ---------------------------------------------------------------------------
-- Resident functions
-- ---------------------------------------------------------------------------
create or replace function resident_home()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v_ids uuid[] := array(select resident_me());
begin
  if cardinality(v_ids) = 0 then raise exception 'Resident two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'name', (select name from tenants where id = v_ids[1]),
    'settings', (select jsonb_object_agg(key, value) from portal_settings),
    'leases', coalesce((select jsonb_agg(jsonb_build_object(
        'id', l.id, 'account_number', l.legacy_lease_number, 'address', coalesce(u.address, p.street), 'unit_number', u.unit_number,
        'start_date', l.start_date, 'end_date', l.end_date, 'lease_type', l.lease_type, 'rent', l.rent, 'deposit_held', l.deposit_held,
        'balance', (select coalesce(sum(amount), 0) from lease_ledger_entries where lease_id = l.id),
        'tenants', (select jsonb_agg(t.name order by t.name) from lease_tenants x join tenants t on t.id = x.tenant_id where x.lease_id = l.id),
        'history', (select jsonb_agg(jsonb_build_object('date', e.entry_date, 'kind', e.kind, 'type', e.raw_type, 'memo', e.description, 'account', e.gl_account, 'amount', e.amount) order by e.entry_date, e.id)
                    from lease_ledger_entries e where e.lease_id = l.id),
        'files', (select jsonb_agg(jsonb_build_object('kind', f.kind, 'status', f.status, 'dated', f.dated, 'note', f.note) order by f.dated) from lease_files f where f.lease_id = l.id)))
      from leases l join rental_units u on u.id = l.unit_id join rental_properties p on p.id = u.property_id
      where l.status = 'active' and exists (select 1 from lease_tenants x where x.lease_id = l.id and x.tenant_id = any(v_ids))), '[]'::jsonb),
    'land_contracts', coalesce((select jsonb_agg(jsonb_build_object(
        'id', c.id, 'property', p.name, 'street', p.street, 'monthly_payment', c.monthly_payment, 'contract_date', c.contract_date,
        'maturity_date', c.maturity_date, 'interest_rate', c.interest_rate, 'purchase_price', c.purchase_price,
        'principal_now', (select s.ending_balance from land_contract_schedule s where s.contract_id = c.id and s.due_date <= current_date order by s.n desc limit 1),
        'balance', (select coalesce(sum(amount), 0) from land_contract_ledger where contract_id = c.id),
        'history', (select jsonb_agg(jsonb_build_object('date', e.entry_date, 'kind', e.kind, 'type', e.raw_type, 'memo', e.description, 'amount', e.amount) order by e.entry_date, e.id)
                    from land_contract_ledger e where e.contract_id = c.id)))
      from land_contracts c join rental_properties p on p.id = c.property_id
      where c.status = 'active' and exists (select 1 from land_contract_buyers b where b.contract_id = c.id and b.tenant_id = any(v_ids))), '[]'::jsonb),
    'signing', coalesce((select jsonb_agg(jsonb_build_object('doc_id', d.id, 'title', d.title, 'unit_label', d.unit_label, 'status', d.status,
        'created_at', d.created_at, 'executed_at', d.executed_at, 'executed_pdf_path', d.executed_pdf_path, 'you_signed', s.signed_at is not null) order by d.created_at desc)
      from lease_signing_docs d join lease_signing_signers s on s.doc_id = d.id
      where lower(s.email) = lower(auth.email()) and d.status <> 'void'), '[]'::jsonb),
    'requests', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'number', r.number, 'subject', r.subject, 'description', r.description,
        'status', r.status, 'created_at', r.created_at, 'photos', r.photos, 'entry_permission', r.entry_permission,
        'updates', (select jsonb_agg(jsonb_build_object('at', u2.at, 'status', u2.status, 'note', u2.note) order by u2.at)
                    from maintenance_request_updates u2 where u2.request_id = r.id and u2.visible_to_resident)) order by r.created_at desc)
      from maintenance_requests r where r.tenant_id = any(v_ids)), '[]'::jsonb),
    'announcements', coalesce((select jsonb_agg(jsonb_build_object('title', a.title, 'body', a.body, 'created_on', a.created_on) order by a.created_on desc)
      from announcements a where a.status = 'current' and (a.expires_on is null or a.expires_on >= current_date)), '[]'::jsonb),
    'contacts', coalesce((select jsonb_agg(jsonb_build_object('name', v.name, 'category', coalesce(v.resident_category, v.category), 'email', v.email,
        'phone', coalesce(v.phone, v.mobile)) order by v.name) from vendors v where v.show_to_residents), '[]'::jsonb)
  );
end;
$$;
revoke all on function resident_home() from public, anon;
grant execute on function resident_home() to authenticated;

create or replace function resident_create_request(p_subject text, p_description text, p_entry text, p_photos text[])
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare v_ids uuid[] := array(select resident_me()); v_lease uuid; v_unit text; r maintenance_requests;
begin
  if cardinality(v_ids) = 0 then raise exception 'Resident two-step sign-in required' using errcode = '42501'; end if;
  if length(trim(coalesce(p_subject, ''))) < 2 or length(trim(coalesce(p_description, ''))) < 5 then raise exception 'Please describe the problem.'; end if;
  if exists (select 1 from unnest(coalesce(p_photos, '{}')) ph where split_part(ph, '/', 1)::uuid <> all(v_ids)) then raise exception 'Bad photo path'; end if;
  select l.id, coalesce(u.address, '') into v_lease, v_unit from leases l join rental_units u on u.id = l.unit_id
   where l.status = 'active' and exists (select 1 from lease_tenants x where x.lease_id = l.id and x.tenant_id = any(v_ids))
   order by l.start_date desc limit 1;
  insert into maintenance_requests (tenant_id, lease_id, unit_label, subject, description, entry_permission, photos)
  values (v_ids[1], v_lease, v_unit, left(trim(p_subject), 120), left(trim(p_description), 4000),
          case when p_entry in ('yes', 'no', 'call_first') then p_entry else 'call_first' end, coalesce(p_photos[1:6], '{}'))
  returning * into r;
  insert into maintenance_request_updates (request_id, by_email, status, note) values (r.id, auth.email(), 'new', 'Request submitted');
  return jsonb_build_object('id', r.id, 'number', r.number);
end;
$$;
revoke all on function resident_create_request(text, text, text, text[]) from public, anon;
grant execute on function resident_create_request(text, text, text, text[]) to authenticated;

-- Staff: maintenance queue
create or replace function maintenance_staff_list()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(to_jsonb(r) || jsonb_build_object(
      'tenant', (select jsonb_build_object('name', t.name, 'phone', t.phone, 'email', t.email) from tenants t where t.id = r.tenant_id),
      'vendor', (select v.name from vendors v where v.id = r.vendor_id),
      'updates', (select jsonb_agg(to_jsonb(u) order by u.at) from maintenance_request_updates u where u.request_id = r.id)) order by r.created_at desc)
    from maintenance_requests r), '[]'::jsonb);
end;
$$;

create or replace function maintenance_staff_update(p_id uuid, p_status text, p_note text, p_visible boolean, p_vendor uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  update maintenance_requests set status = coalesce(p_status, status), vendor_id = coalesce(p_vendor, vendor_id), updated_at = now() where id = p_id;
  if not found then raise exception 'Request not found'; end if;
  insert into maintenance_request_updates (request_id, by_email, status, note, visible_to_resident)
  values (p_id, auth.email(), p_status, nullif(trim(coalesce(p_note, '')), ''), coalesce(p_visible, true));
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function vendors_staff_list()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(to_jsonb(v) order by v.category nulls last, v.name) from vendors v), '[]'::jsonb);
end;
$$;

revoke all on function maintenance_staff_list() from public, anon;
revoke all on function maintenance_staff_update(uuid, text, text, boolean, uuid) from public, anon;
revoke all on function vendors_staff_list() from public, anon;
grant execute on function maintenance_staff_list() to authenticated;
grant execute on function maintenance_staff_update(uuid, text, text, boolean, uuid) to authenticated;
grant execute on function vendors_staff_list() to authenticated;
