-- Applications verify an EMAILED code instead of a texted one (Stephen 10/6/2026).
-- Applicants have no portal login yet, so the rental-apply function keeps its own
-- short-lived codes. Only a hash is stored; anon and authenticated have no access.

create table if not exists apply_email_codes (
  id bigint generated always as identity primary key,
  email text not null,
  code_hash text not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '10 minutes',
  attempts int not null default 0,
  used_at timestamptz
);
create index if not exists apply_email_codes_email_idx on apply_email_codes (email, created_at desc);
alter table apply_email_codes enable row level security;

-- Sessions now prove an email, not a phone. Old rows keep their phone.
alter table apply_sessions add column if not exists email text;
alter table apply_sessions alter column phone drop not null;
