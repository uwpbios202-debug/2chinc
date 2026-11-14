-- Save and resume for the video application (Stephen 10/6/2026).
-- An applicant can leave (for example to replace a lost Social Security card, which
-- takes 2-3 weeks) and come back by verifying the same email. Their answers and the
-- list of files they already uploaded are kept in apply_drafts. The Social Security
-- number is NEVER saved in a draft; they type it again when they return.
-- Uploaded files stay in the same private session folder, so the draft just points at them.

create table if not exists apply_drafts (
  session_id uuid primary key references apply_sessions(id) on delete cascade,
  email text not null,
  step text,
  state jsonb not null,
  updated_at timestamptz not null default now()
);
create index if not exists apply_drafts_email_idx on apply_drafts (lower(email), updated_at desc);
alter table apply_drafts enable row level security;
-- No policies: only the rental-apply function (service role) reads or writes drafts.

-- Retention: an unsaved session still goes after 7 days; a saved draft is kept 45 days
-- after its last save, then the files and the draft are deleted.
create or replace function apply_purge_due()
returns table (session_id uuid, application_id uuid)
language sql stable security definer set search_path = public
as $$
  select s.id, null::uuid from apply_sessions s
   where s.submitted_at is null
     and case when exists (select 1 from apply_drafts d where d.session_id = s.id)
              then (select max(d.updated_at) from apply_drafts d where d.session_id = s.id) < now() - interval '45 days'
              else s.created_at < now() - interval '7 days' end
  union all
  select a.session_id, a.id from rental_applications a
   where a.status in ('declined', 'withdrawn') and coalesce(a.decided_at, a.created_at) < now() - interval '90 days';
$$;
revoke all on function apply_purge_due() from public, anon, authenticated;
grant execute on function apply_purge_due() to service_role;
