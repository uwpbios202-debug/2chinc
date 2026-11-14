-- (1) lease_files: the signed lease documents on file for each lease, with a
--     status and note (e.g. "needs update", "coming soon").
-- (2) Lease signing: staff send a prepared lease (frozen snapshot), each
--     tenant opens a private link, confirms a code texted to their phone,
--     reviews the whole lease on the website, signs (drawn signature + typed
--     name + e-sign consent), and once every tenant has signed the system
--     builds the executed PDF and emails it to every signer and to staff.
--     Every step is recorded in lease_signing_events (the audit trail that
--     goes on the PDF's certificate page).

create table if not exists lease_files (
  id bigint generated always as identity primary key,
  lease_id uuid not null references leases(id),
  kind text not null check (kind in ('signed_lease', 'addendum', 'rent_increase', 'other')),
  status text not null default 'on_file' check (status in ('on_file', 'needs_update', 'coming_soon')),
  file_path text,                     -- path under lease/files/ (private), null when not on file yet
  dated date,
  note text,
  created_at timestamptz not null default now()
);
alter table lease_files enable row level security;

create table if not exists lease_signing_docs (
  id uuid primary key default gen_random_uuid(),
  application_id uuid references rental_applications(id),
  lease_id uuid references leases(id),
  unit_label text not null,
  title text not null default 'Residential Rental Agreement',
  status text not null default 'sent' check (status in ('sent', 'signed', 'void')),
  html text not null,                 -- frozen snapshot of the lease exactly as sent (images inlined)
  html_sha256 text not null,
  blocks jsonb not null,              -- the same lease as text blocks, for the executed PDF
  lease_data jsonb not null default '{}'::jsonb,
  created_by text not null,
  created_at timestamptz not null default now(),
  executed_at timestamptz,
  executed_pdf_path text,
  void_reason text
);

create table if not exists lease_signing_signers (
  id uuid primary key default gen_random_uuid(),
  doc_id uuid not null references lease_signing_docs(id) on delete cascade,
  position int not null,
  role text not null default 'tenant',
  name text not null,
  email text not null,
  phone text,                         -- E.164; the code that unlocks the lease is texted here
  token_hash text not null unique,
  sent_at timestamptz,
  viewed_at timestamptz,
  verified_at timestamptz,
  signed_at timestamptz,
  typed_name text,
  signature_path text,
  sign_ip text,
  sign_user_agent text
);

create table if not exists lease_signing_events (
  id bigint generated always as identity primary key,
  doc_id uuid not null references lease_signing_docs(id) on delete cascade,
  signer_id uuid references lease_signing_signers(id) on delete cascade,
  at timestamptz not null default now(),
  event text not null,                -- sent | opened | code_sent | verified | signed | executed | emailed | voided
  ip text,
  user_agent text,
  detail text
);
create index if not exists lease_signing_events_doc_idx on lease_signing_events (doc_id, at);

alter table lease_signing_docs enable row level security;
alter table lease_signing_signers enable row level security;
alter table lease_signing_events enable row level security;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('lease-signing', 'lease-signing', false, 20971520, array['application/pdf', 'image/png'])
on conflict (id) do update set public = false;

drop policy if exists "lease-signing staff read" on storage.objects;
create policy "lease-signing staff read" on storage.objects
  for select to authenticated
  using (bucket_id = 'lease-signing' and condo_session_ok() and condo_is_staff());

-- Staff check usable by edge functions with the caller's JWT.
create or replace function staff_session_ok()
returns boolean
language sql stable security definer set search_path = public
as $$ select condo_session_ok() and condo_is_staff(); $$;
revoke all on function staff_session_ok() from public, anon;
grant execute on function staff_session_ok() to authenticated;

-- One application, shaped for the lease builder (staff only).
create or replace function apply_staff_get(p_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare r rental_applications;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into r from rental_applications where id = p_id;
  if r.id is null then raise exception 'Application not found'; end if;
  insert into apply_access_log (staff_email, action, application_id, detail) values (auth.email(), 'list', p_id, 'opened in lease builder');
  return jsonb_build_object('id', r.id, 'status', r.status, 'applicant', r.applicant, 'household', r.household);
end;
$$;
revoke all on function apply_staff_get(uuid) from public, anon;
grant execute on function apply_staff_get(uuid) to authenticated;

create or replace function lease_signing_staff_list()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', d.id, 'unit_label', d.unit_label, 'title', d.title, 'status', d.status, 'created_at', d.created_at,
      'created_by', d.created_by, 'executed_at', d.executed_at, 'executed_pdf_path', d.executed_pdf_path,
      'application_id', d.application_id,
      'signers', (select jsonb_agg(jsonb_build_object('name', s.name, 'email', s.email, 'sent_at', s.sent_at, 'viewed_at', s.viewed_at,
                   'verified_at', s.verified_at, 'signed_at', s.signed_at) order by s.position) from lease_signing_signers s where s.doc_id = d.id))
      order by d.created_at desc) from lease_signing_docs d), '[]'::jsonb);
end;
$$;
revoke all on function lease_signing_staff_list() from public, anon;
grant execute on function lease_signing_staff_list() to authenticated;

-- Lease files on the rentals overview.
create or replace function rentals_staff_lease_files(p_lease_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(to_jsonb(f) order by f.dated nulls last, f.id) from lease_files f where f.lease_id = p_lease_id), '[]'::jsonb);
end;
$$;
revoke all on function rentals_staff_lease_files(uuid) from public, anon;
grant execute on function rentals_staff_lease_files(uuid) to authenticated;
