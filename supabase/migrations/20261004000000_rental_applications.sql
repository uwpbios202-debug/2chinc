-- "Say Yes" rental applications (2ndchinc.org/apply).
--
-- What we care about, in order: (1) the applicant's STATED commitment to pay
-- rent on time, recorded on video; (2) that they can say, in their own words,
-- what happens when a lease section is violated ("lease scenes", also video).
--
-- Flow (all writes go through the rental-apply edge function with the
-- service role; anon/authenticated have NO table access at all):
--   1. start   -> applicant's mobile gets a Twilio Verify code (rate limited)
--   2. verify  -> code checked; a random session token is issued (only its
--                 SHA-256 is stored here) — proves a real, reachable phone
--   3. upload  -> per clip/photo, a one-time signed upload URL into the
--                 private `applications` bucket under <session_id>/
--   4. submit  -> application row written, staff emailed
-- Staff review at /owners/applications.html: two-step staff sign-in, then
-- apply_staff_list() and short-lived signed URLs for the media.

create table if not exists apply_sms_requests (
  id bigint generated always as identity primary key,
  phone text not null,
  created_at timestamptz not null default now()
);
create index if not exists apply_sms_requests_phone_idx on apply_sms_requests (phone, created_at);

create table if not exists apply_sessions (
  id uuid primary key default gen_random_uuid(),
  token_hash text not null unique,
  phone text not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '12 hours',
  submitted_at timestamptz
);

create table if not exists rental_applications (
  id uuid primary key default gen_random_uuid(),
  session_id uuid not null references apply_sessions(id),
  created_at timestamptz not null default now(),
  status text not null default 'new'
    check (status in ('new', 'reviewing', 'approved', 'declined', 'withdrawn')),
  applicant jsonb not null,          -- name, email, phone (verified), units wanted, move-in, how heard
  household jsonb not null default '[]'::jsonb,  -- [{name, relation, dob, minor}]
  answers jsonb not null default '{}'::jsonb,    -- typed notes per scene (optional, alongside video)
  media jsonb not null default '[]'::jsonb,      -- [{kind, scene, path, mime, bytes, seconds}]
  scene_version text,                -- which version of the lease scenes they answered
  staff_notes text,
  decided_at timestamptz,
  decided_by text
);
create index if not exists rental_applications_created_idx on rental_applications (created_at desc);

alter table apply_sms_requests enable row level security;
alter table apply_sessions enable row level security;
alter table rental_applications enable row level security;
-- No policies: only the service role (edge function) and the staff RPCs below.

-- ---------------------------------------------------------------------------
-- Private media bucket. 100 MB per file; video, audio and photos only.
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('applications', 'applications', false, 104857600,
        array['video/webm', 'video/mp4', 'video/quicktime', 'video/x-matroska',
              'audio/webm', 'audio/mp4', 'audio/mpeg', 'audio/ogg',
              'image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- Staff (after the text-code step) may read media to create signed URLs.
-- Uploads only happen through signed upload URLs issued by the edge function.
drop policy if exists "applications staff read" on storage.objects;
create policy "applications staff read" on storage.objects
  for select to authenticated
  using (bucket_id = 'applications' and condo_session_ok() and condo_is_staff());

-- Every staff look at, or decision on, an application is logged.
create table if not exists apply_access_log (
  id bigint generated always as identity primary key,
  at timestamptz not null default now(),
  staff_email text not null,
  action text not null,              -- 'list' | 'media' | 'status'
  application_id uuid,
  detail text
);
alter table apply_access_log enable row level security;

-- ---------------------------------------------------------------------------
-- Staff functions
-- ---------------------------------------------------------------------------
create or replace function apply_staff_list()
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  insert into apply_access_log (staff_email, action) values (auth.email(), 'list');
  return coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at desc) from rental_applications a), '[]'::jsonb);
end;
$$;

-- Called by the review page before it requests a signed URL for a clip, so
-- each media view is on record.
create or replace function apply_staff_log_media(p_id uuid, p_path text)
returns void
language plpgsql volatile security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  insert into apply_access_log (staff_email, action, application_id, detail) values (auth.email(), 'media', p_id, p_path);
end;
$$;

-- Retention: what the purge job may delete. Sessions that never submitted
-- after 7 days; declined/withdrawn applications 90 days after the decision.
-- (Files are deleted through the Storage API by the rental-apply function's
-- "purge" action, then the rows.)
create or replace function apply_purge_due()
returns table (session_id uuid, application_id uuid)
language sql stable security definer set search_path = public
as $$
  select s.id, null::uuid from apply_sessions s
   where s.submitted_at is null and s.created_at < now() - interval '7 days'
  union all
  select a.session_id, a.id from rental_applications a
   where a.status in ('declined', 'withdrawn') and coalesce(a.decided_at, a.created_at) < now() - interval '90 days';
$$;
revoke all on function apply_purge_due() from public, anon, authenticated;
grant execute on function apply_purge_due() to service_role;
revoke all on function apply_staff_log_media(uuid, text) from public, anon;
grant execute on function apply_staff_log_media(uuid, text) to authenticated;

create or replace function apply_staff_set_status(p_id uuid, p_status text, p_notes text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare r rental_applications;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if p_status not in ('new', 'reviewing', 'approved', 'declined', 'withdrawn') then raise exception 'Unknown status %', p_status; end if;
  update rental_applications
     set status = p_status,
         staff_notes = coalesce(p_notes, staff_notes),
         decided_at = case when p_status in ('approved', 'declined') then now() else decided_at end,
         decided_by = case when p_status in ('approved', 'declined') then auth.email() else decided_by end
   where id = p_id
  returning * into r;
  if r.id is null then raise exception 'Application not found'; end if;
  insert into apply_access_log (staff_email, action, application_id, detail) values (auth.email(), 'status', p_id, p_status);
  return to_jsonb(r);
end;
$$;

revoke all on function apply_staff_list() from public, anon;
revoke all on function apply_staff_set_status(uuid, text, text) from public, anon;
grant execute on function apply_staff_list() to authenticated;
grant execute on function apply_staff_set_status(uuid, text, text) to authenticated;
