-- Phone alerts (web push, free; no Twilio) (Stephen, 11/3/2026).
--   A tenant or owner taps "Turn on phone alerts" in the portal (Parking page). Their phone's push address is kept in push_subscriptions.
--   Parking alerts (email kind 'parking_alert') also go to every phone the recipient turned alerts on for: a trigger copies each such email
--   into push_outbox, and the outbox-flush function sends it (right after the alert, as it already does for the emails).
--   iPhone: works only from the portal added to the Home Screen (iOS 16.4 or newer). Android: works in Chrome.
-- The public half of the key pair is the setting vapid_public_key (data); the private half is a Supabase secret, never in this repo.
-- New tables: explicit grants (Supabase change of 10/30/2026).

create table if not exists push_subscriptions (
  id bigint generated always as identity primary key,
  email text not null,
  user_id uuid,
  endpoint text not null unique,
  p256dh text not null,
  auth text not null,
  device text,                                -- "iPhone", "Android", "Computer" (for the office's count only)
  created_at timestamptz not null default now(),
  last_ok_at timestamptz,
  last_error text
);
create index if not exists push_subscriptions_email on push_subscriptions (lower(email));
alter table push_subscriptions enable row level security;
revoke all on push_subscriptions from public, anon, authenticated;
grant all on push_subscriptions to service_role;

create table if not exists push_outbox (
  id bigint generated always as identity primary key,
  to_email text not null,
  title text not null,
  body text not null default '',
  url text not null default '/resident/',
  tag text,
  kind text not null,
  created_at timestamptz not null default now(),
  sent_at timestamptz,
  attempts int not null default 0,
  delivered int not null default 0,
  error text
);
create index if not exists push_outbox_unsent on push_outbox (id) where sent_at is null;
alter table push_outbox enable row level security;
revoke all on push_outbox from public, anon, authenticated;
grant all on push_outbox to service_role;

-- This phone: the public key to subscribe with, and whether this phone's address is on file for the signed-in person.
create or replace function push_config(p_endpoint text)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('public_key', condo_setting('vapid_public_key', ''),
    'on', exists (select 1 from push_subscriptions where endpoint = p_endpoint and lower(email) = lower(auth.email())),
    'devices', (select count(*) from push_subscriptions where lower(email) = lower(auth.email())),
    'view_as', autopay_view_as_session());
$$;
revoke all on function push_config(text) from public, anon;
grant execute on function push_config(text) to authenticated;

create or replace function push_subscribe(p_endpoint text, p_p256dh text, p_auth text, p_device text)
returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if not condo_session_ok() or auth.email() is null then raise exception 'Please sign in again.' using errcode = '42501'; end if;
  if autopay_view_as_session() then raise exception 'Not available while viewing as someone else (it would send their alerts to this device).'; end if;
  if p_endpoint !~ '^https://' or length(p_endpoint) > 1000 or length(coalesce(p_p256dh, '')) < 20 or length(coalesce(p_auth, '')) < 8 then raise exception 'This phone gave an address we cannot use.'; end if;
  insert into push_subscriptions (email, user_id, endpoint, p256dh, auth, device)
  values (lower(auth.email()), auth.uid(), p_endpoint, p_p256dh, p_auth, left(p_device, 20))
  on conflict (endpoint) do update set email = excluded.email, user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth,
    device = excluded.device, created_at = now(), last_error = null;
end;
$$;
revoke all on function push_subscribe(text, text, text, text) from public, anon;
grant execute on function push_subscribe(text, text, text, text) to authenticated;

create or replace function push_unsubscribe(p_endpoint text)
returns void
language sql volatile security definer set search_path = public as $$
  delete from push_subscriptions where endpoint = p_endpoint and lower(email) = lower(auth.email());
$$;
revoke all on function push_unsubscribe(text) from public, anon;
grant execute on function push_unsubscribe(text) to authenticated;

-- Every parking alert email also goes to the recipient's phones.
create or replace function push_from_email()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.kind = 'parking_alert' and exists (select 1 from push_subscriptions where lower(email) = lower(new.to_email)) then
    insert into push_outbox (to_email, title, body, url, tag, kind)
    values (lower(new.to_email), '🚨 ' || new.subject,
      'If it is yours or your guest''s, move it now. Tap to open the parking lot.',
      case when exists (select 1 from tenants where lower(email) = lower(new.to_email)) then '/resident/#parking' else '/association-owners/roca1/#parking' end,
      'parking', new.kind);
  end if;
  return new;
end;
$$;
revoke all on function push_from_email() from public, anon, authenticated;
drop trigger if exists email_outbox_push on email_outbox;
create trigger email_outbox_push after insert on email_outbox for each row execute function push_from_email();

-- Staff: who has phone alerts on, unit by unit (counts only).
create or replace function push_staff_summary()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('unit', p.unit_number, 'people', p.n, 'on', p.on_n) order by p.unit_number::int)
    from (select unit_number, count(*) n,
                 count(*) filter (where exists (select 1 from push_subscriptions s where lower(s.email) = x.email)) on_n
            from parking_alert_people() x group by unit_number) p), '[]'::jsonb);
end;
$$;
revoke all on function push_staff_summary() from public, anon;
grant execute on function push_staff_summary() to authenticated;
