-- Messages from the public Contact page. Kept for the record and to rate-limit spam.
create table if not exists contact_messages (
  id bigint generated always as identity primary key,
  email text not null,
  message text not null,
  created_at timestamptz not null default now()
);
create index if not exists contact_messages_email_idx on contact_messages (lower(email), created_at desc);
alter table contact_messages enable row level security;
-- No policies: only the contact-form function (service role) writes here.
