-- Autopay, rebuilt (Stephen, 10/13/2026). Tenants may not have the money on the day, so:
--   * ONLY the tenant can start or cancel autopay, from their own sign-in, with a one-time code emailed to THEM, after reading and
--     acknowledging the terms. Staff (and "view as") cannot start, change or restart it. Staff can only PAUSE it, and the tenant is emailed at once.
--   * Every authorization (the exact words shown, the acknowledgements, the typed name, time, IP, device) and every step is kept in an
--     append-only, hash-chained log. Rows cannot be edited or deleted through the application, and any tampering shows when the chain is checked.
--   * The tenant gets email reminders 7 days, 3 days and 1 day before each withdrawal, and on the day. If the 1-day reminder was not
--     sent or the address bounced, the withdrawal is HELD (nothing is taken) and the tenant and the office are told.
--   * One returned or failed withdrawal pauses autopay (no automatic retry). The tenant turns it back on themselves.
--   * The amount is fixed to what they approved: a withdrawal is never more than that, and never more than what is owed.
-- Autopay stays OFF for everyone until the setting autopay_enabled is switched to 'on'. Nobody was enrolled before this (0 Stripe customers).

insert into portal_settings (key, value) values ('autopay_enabled', 'off') on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- Records
create table if not exists autopay_authorizations (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  lease_id uuid references leases(id),
  land_contract_id uuid references land_contracts(id),
  amount numeric(12,2) not null check (amount >= 1 and amount <= 20000),
  draw_day int not null check (draw_day between 1 and 5),
  terms_version text not null,
  terms_text text not null,
  acks jsonb not null,
  typed_name text not null,
  ip text,
  user_agent text,
  status text not null default 'pending' check (status in ('pending', 'active', 'paused', 'canceled', 'expired')),
  stripe_account text,
  customer_id text,
  payment_method_id text,
  bank_label text,
  setup_intent text,
  mandate text,
  created_at timestamptz not null default now(),
  activated_at timestamptz,
  ended_at timestamptz,
  ended_by text,
  ended_reason text,
  row_hash text not null,
  check (num_nonnulls(lease_id, land_contract_id) = 1)
);
create index if not exists autopay_auth_tenant_idx on autopay_authorizations (tenant_id, status);
alter table autopay_authorizations enable row level security;

create table if not exists autopay_events (
  id bigint generated always as identity primary key,
  authorization_id uuid not null references autopay_authorizations(id),
  at timestamptz not null,
  kind text not null,
  detail jsonb not null default '{}'::jsonb,
  actor text not null,
  prev_hash text,
  row_hash text not null
);
create index if not exists autopay_events_auth_idx on autopay_events (authorization_id, id);
alter table autopay_events enable row level security;

create table if not exists autopay_codes (
  id bigint generated always as identity primary key,
  tenant_id uuid not null references tenants(id),
  code_hash text not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '10 minutes',
  attempts int not null default 0,
  used_at timestamptz
);
alter table autopay_codes enable row level security;

-- ---------------------------------------------------------------------------
-- Guards
create or replace function autopay_auth_guard()
returns trigger language plpgsql as $$
declare v_actor text := coalesce(current_setting('app.autopay_actor', true), ''); v_ok boolean := false;
begin
  if tg_op = 'DELETE' then raise exception 'Autopay records cannot be deleted.'; end if;
  if (new.id, new.tenant_id, new.lease_id, new.land_contract_id, new.amount, new.draw_day, new.terms_version, new.terms_text, new.acks, new.typed_name, new.ip, new.user_agent, new.created_at, new.row_hash)
     is distinct from (old.id, old.tenant_id, old.lease_id, old.land_contract_id, old.amount, old.draw_day, old.terms_version, old.terms_text, old.acks, old.typed_name, old.ip, old.user_agent, old.created_at, old.row_hash) then
    raise exception 'The terms of an autopay authorization cannot be changed.';
  end if;
  if (new.status, new.stripe_account, new.customer_id, new.payment_method_id, new.bank_label, new.setup_intent, new.mandate, new.activated_at, new.ended_at, new.ended_by, new.ended_reason)
     is distinct from (old.status, old.stripe_account, old.customer_id, old.payment_method_id, old.bank_label, old.setup_intent, old.mandate, old.activated_at, old.ended_at, old.ended_by, old.ended_reason) then
    if old.status <> 'pending' and (new.stripe_account, new.customer_id, new.payment_method_id, new.bank_label, new.setup_intent, new.mandate, new.activated_at)
         is distinct from (old.stripe_account, old.customer_id, old.payment_method_id, old.bank_label, old.setup_intent, old.mandate, old.activated_at) then
      raise exception 'The bank on an autopay authorization cannot be changed.';
    end if;
    v_ok := (old.status = 'pending' and new.status = 'active' and v_actor = 'webhook')
         or (old.status = 'pending' and new.status = 'canceled' and v_actor in ('tenant', 'system'))
         or (old.status = 'pending' and new.status = 'expired' and v_actor = 'system')
         or (old.status = 'active' and new.status = 'canceled' and v_actor in ('tenant', 'system'))
         or (old.status = 'active' and new.status = 'paused' and v_actor in ('staff_pause', 'system'))
         or (old.status = new.status and v_actor <> '');
    if not v_ok then raise exception 'Only the tenant can start or cancel autopay. Staff can only pause it.'; end if;
  end if;
  return new;
end;
$$;
drop trigger if exists autopay_auth_guard_t on autopay_authorizations;
create trigger autopay_auth_guard_t before update or delete on autopay_authorizations for each row execute function autopay_auth_guard();

create or replace function autopay_auth_hash_set()
returns trigger language plpgsql as $$
begin
  new.created_at := coalesce(new.created_at, now());
  new.row_hash := autopay_auth_hash(new);
  return new;
end;
$$;
drop trigger if exists autopay_auth_hash_set_t on autopay_authorizations;
create trigger autopay_auth_hash_set_t before insert on autopay_authorizations for each row execute function autopay_auth_hash_set();

create or replace function autopay_events_guard()
returns trigger language plpgsql as $$
begin raise exception 'The autopay log cannot be edited or deleted.'; end;
$$;
drop trigger if exists autopay_events_guard_t on autopay_events;
create trigger autopay_events_guard_t before update or delete on autopay_events for each row execute function autopay_events_guard();

-- The old autopay columns on stripe_customers can no longer be changed by anyone: the authorization table is the only truth.
create or replace function stripe_customers_autopay_guard()
returns trigger language plpgsql as $$
begin
  if (new.autopay_enabled, new.autopay_payment_method, new.autopay_bank_label, new.autopay_since)
     is distinct from (old.autopay_enabled, old.autopay_payment_method, old.autopay_bank_label, old.autopay_since) then
    raise exception 'Autopay is controlled only by the tenant through the authorization record.';
  end if;
  return new;
end;
$$;
drop trigger if exists stripe_customers_autopay_guard_t on stripe_customers;
create trigger stripe_customers_autopay_guard_t before update on stripe_customers for each row execute function stripe_customers_autopay_guard();

-- The old charge list returns nobody: only authorized, reminded withdrawals are made (autopay_due_v2).
create or replace function autopay_due(p_as_of date)
returns table (tenant_id uuid, customer_id text, payment_method text, lease_id uuid, amount numeric)
language sql stable security definer set search_path = public as $$
  select null::uuid, null::text, null::text, null::uuid, null::numeric where false;
$$;
revoke all on function autopay_due(date) from public, anon, authenticated;
grant execute on function autopay_due(date) to service_role;

-- ---------------------------------------------------------------------------
-- Helpers
create or replace function autopay_set_actor(p text) returns void language sql as $$ select set_config('app.autopay_actor', p, true); $$;
revoke all on function autopay_set_actor(text) from public, anon, authenticated;

create or replace function autopay_hash(p text) returns text language sql immutable as $$ select encode(extensions.digest(p, 'sha256'), 'hex'); $$;
revoke all on function autopay_hash(text) from public, anon, authenticated;

create or replace function autopay_today() returns date language sql stable as $$ select (now() at time zone 'America/Chicago')::date; $$;
revoke all on function autopay_today() from public, anon, authenticated;

create or replace function autopay_view_as_session()
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from view_as_grants g where g.session_id is not null and g.session_id::text = (auth.jwt() ->> 'session_id') and g.target_user_id = auth.uid());
$$;
revoke all on function autopay_view_as_session() from public, anon, authenticated;

create or replace function autopay_next_draw(p_day int, p_from date)
returns date language sql immutable as $$
  select case when make_date(extract(year from p_from)::int, extract(month from p_from)::int, p_day) >= p_from
              then make_date(extract(year from p_from)::int, extract(month from p_from)::int, p_day)
              else (date_trunc('month', p_from) + interval '1 month')::date + (p_day - 1) end;
$$;
revoke all on function autopay_next_draw(int, date) from public, anon, authenticated;

-- What a tenant pays: a lease (their portion of the rent) or a land contract (the monthly payment).
create or replace function autopay_subject(p_tenant uuid)
returns table (lease_id uuid, land_contract_id uuid, amount numeric, label text, is_lease boolean)
language sql stable security definer set search_path = public as $$
  select l.id, null::uuid, coalesce(lease_tenant_rent(l.id), l.rent), ru.address, true
    from lease_tenants lt join leases l on l.id = lt.lease_id and l.status = 'active' join rental_units ru on ru.id = l.unit_id
   where lt.tenant_id = p_tenant and coalesce(l.rent, 0) > 0
  union all
  select null::uuid, c.id, c.monthly_payment, p.street, false
    from land_contract_buyers b join land_contracts c on c.id = b.contract_id and c.status = 'active' join rental_properties p on p.id = c.property_id
   where b.tenant_id = p_tenant;
$$;
revoke all on function autopay_subject(uuid) from public, anon, authenticated;

create or replace function autopay_me()
returns uuid language sql stable security definer set search_path = public as $$
  select x.t from (select resident_me() as t) x where exists (select 1 from autopay_subject(x.t)) limit 1;
$$;
revoke all on function autopay_me() from public, anon, authenticated;

-- The log: one chain, so a row changed or removed later shows when the chain is checked.
create or replace function autopay_event(p_auth uuid, p_kind text, p_detail jsonb, p_actor text)
returns void language plpgsql security definer set search_path = public as $$
declare v_prev text; v_at timestamptz := clock_timestamp(); v_detail jsonb := coalesce(p_detail, '{}'::jsonb);
begin
  perform pg_advisory_xact_lock(7117001);
  select row_hash into v_prev from autopay_events order by id desc limit 1;
  insert into autopay_events (authorization_id, at, kind, detail, actor, prev_hash, row_hash)
  values (p_auth, v_at, p_kind, v_detail, p_actor, v_prev,
          autopay_hash(concat_ws('|', coalesce(v_prev, ''), p_auth::text, extract(epoch from v_at)::text, p_kind, v_detail::text, p_actor)));
end;
$$;
revoke all on function autopay_event(uuid, text, jsonb, text) from public, anon, authenticated;

create or replace function autopay_auth_hash(a autopay_authorizations)
returns text language sql immutable as $$
  select autopay_hash(concat_ws('|', a.id::text, a.tenant_id::text, coalesce(a.lease_id::text, ''), coalesce(a.land_contract_id::text, ''), a.amount::text, a.draw_day::text,
         a.terms_version, md5(a.terms_text), a.acks::text, a.typed_name, extract(epoch from a.created_at)::text));
$$;
revoke all on function autopay_auth_hash(autopay_authorizations) from public, anon, authenticated;

-- The exact words the tenant agrees to.
create or replace function autopay_terms(p_name text, p_amount numeric, p_day int, p_label text, p_is_lease boolean, p_first date)
returns text language plpgsql stable security definer set search_path = public as $$
declare v_fee text := coalesce(nullif((select value from portal_settings where key = 'returned_payment_fee'), ''), '0');
begin
  return 'AUTOPAY AUTHORIZATION' || E'\n\n'
    || 'I, ' || p_name || ', authorize 2nd Chance Housing Inc. to withdraw money electronically (ACH) from the bank account I connect, to pay my '
       || case when p_is_lease then 'rent for ' else 'land contract payment for ' end || p_label || '.' || E'\n\n'
    || '• Amount: ' || to_char(p_amount, 'FM$999,990.00') || ' each month, or less if I owe less. It will never be more than this unless I approve a new amount myself.' || E'\n'
    || '• Date: on the ' || p_day || case p_day when 1 then 'st' when 2 then 'nd' when 3 then 'rd' else 'th' end || ' of each month. My first withdrawal is ' || to_char(p_first, 'FMMonth FMDD, YYYY') || '.' || E'\n'
    || '• Reminders: I will get an email 7 days, 3 days and 1 day before each withdrawal, and on the day. If a reminder cannot be sent to me, no money is withdrawn that month.' || E'\n'
    || '• Stopping it: I can cancel any time in my portal (Payments, Autopay, Cancel). To stop a withdrawal, I cancel before 11:59 PM the day before it.' || E'\n'
    || '• If my account does not have enough money: the withdrawal may be returned. Then my ' || case when p_is_lease then 'rent' else 'payment' end || ' is still due'
       || case when p_is_lease and v_fee::numeric > 0 then ', a returned payment fee of ' || to_char(v_fee::numeric, 'FM$999,990.00') || ' may be charged (as my lease provides)' else '' end
       || ', late fees and notices follow the normal schedule, my bank may also charge me, and autopay pauses until I turn it on again myself. There is no automatic second try.' || E'\n'
    || '• Only I can turn autopay on or change it. 2nd Chance staff cannot start or change it. Staff can pause it for safety, and I am emailed right away.' || E'\n'
    || '• If my ' || case when p_is_lease then 'rent' else 'payment' end || ' changes, autopay keeps withdrawing no more than the amount above until I approve a new amount.' || E'\n\n'
    || 'I set this up myself, from my own sign-in.';
end;
$$;
revoke all on function autopay_terms(text, numeric, int, text, boolean, date) from public, anon, authenticated;

create or replace function autopay_email(p_to text, p_subject text, p_html text, p_kind text)
returns bigint language plpgsql security definer set search_path = public as $$
declare v_id bigint;
begin
  insert into email_outbox (to_email, subject, html, kind) values (p_to, p_subject, p_html, p_kind) returning id into v_id;
  return v_id;
end;
$$;
revoke all on function autopay_email(text, text, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Tenant: what is on, and the setup form
create or replace function autopay_status_mine()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_t uuid := autopay_me();
begin
  if not exists (select 1 from resident_me()) then raise exception 'Resident sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'enabled', condo_setting('autopay_enabled', 'off') = 'on',
    'authorizations', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'status', a.status, 'amount', a.amount, 'draw_day', a.draw_day, 'bank', a.bank_label,
          'is_lease', a.lease_id is not null, 'created_at', a.created_at, 'activated_at', a.activated_at, 'ended_by', a.ended_by,
          'next_draw', case when a.status = 'active' then autopay_next_draw(a.draw_day, autopay_today()) end,
          'label', coalesce((select ru.address from leases l join rental_units ru on ru.id = l.unit_id where l.id = a.lease_id),
                            (select p.street from land_contracts c join rental_properties p on p.id = c.property_id where c.id = a.land_contract_id)))
        order by a.created_at desc)
      from autopay_authorizations a where a.tenant_id in (select resident_me()) and (a.status in ('active', 'pending', 'paused') or a.ended_at > now() - interval '14 days')), '[]'::jsonb),
    'recent', coalesce((select jsonb_agg(jsonb_build_object('at', e.at, 'kind', e.kind) order by e.id desc)
      from (select e2.* from autopay_events e2 join autopay_authorizations a2 on a2.id = e2.authorization_id where a2.tenant_id in (select resident_me()) order by e2.id desc limit 8) e), '[]'::jsonb),
    'can_start', v_t is not null);
end;
$$;
revoke all on function autopay_status_mine() from public, anon;
grant execute on function autopay_status_mine() to authenticated;

create or replace function autopay_prepare(p_draw_day int default 1)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_t uuid := autopay_me(); s record; v_first date; v_day int := coalesce(p_draw_day, 1); v_email text;
begin
  if not exists (select 1 from resident_me()) then raise exception 'Resident sign-in required' using errcode = '42501'; end if;
  if autopay_view_as_session() then raise exception 'Autopay can only be set up by the tenant, from their own sign-in.'; end if;
  if condo_setting('autopay_enabled', 'off') <> 'on' then raise exception 'Autopay is not available yet.'; end if;
  if v_t is null then raise exception 'Autopay is for an active lease or land contract.'; end if;
  if v_day not between 1 and 5 then raise exception 'Choose a day from the 1st to the 5th.'; end if;
  select * into s from autopay_subject(v_t) limit 1;
  select email into v_email from tenants where id = v_t;
  if coalesce(v_email, '') not like '%@%' then raise exception 'We need your email address on file first, because every withdrawal is announced by email. Update it under Profile.'; end if;
  v_first := autopay_next_draw(v_day, autopay_today() + 8);
  return jsonb_build_object('amount', s.amount, 'label', s.label, 'is_lease', s.is_lease, 'draw_day', v_day, 'first_draw', v_first,
    'version', 'autopay-2026-10-v1', 'terms', autopay_terms('[your full name]', s.amount, v_day, s.label, s.is_lease, v_first),
    'email_hint', left(v_email, 2) || '***' || substr(v_email, position('@' in v_email)));
end;
$$;
revoke all on function autopay_prepare(int) from public, anon;
grant execute on function autopay_prepare(int) to authenticated;

-- A one-time code, emailed to the tenant, proves it is them at their own mailbox (staff and "view as" cannot read it).
create or replace function autopay_request_code()
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_t uuid := autopay_me(); v_email text; v_name text; v_code text;
begin
  if not exists (select 1 from resident_me()) then raise exception 'Resident sign-in required' using errcode = '42501'; end if;
  if autopay_view_as_session() then raise exception 'Autopay can only be set up by the tenant, from their own sign-in.'; end if;
  if condo_setting('autopay_enabled', 'off') <> 'on' then raise exception 'Autopay is not available yet.'; end if;
  if v_t is null then raise exception 'Autopay is for an active lease or land contract.'; end if;
  if (select count(*) from autopay_codes where tenant_id = v_t and created_at > now() - interval '1 hour') >= 5 then raise exception 'Too many codes. Try again in an hour.'; end if;
  select email, name into v_email, v_name from tenants where id = v_t;
  if coalesce(v_email, '') not like '%@%' then raise exception 'We need your email address on file first.'; end if;
  v_code := lpad(((('x' || encode(extensions.gen_random_bytes(4), 'hex'))::bit(32)::bigint) % 1000000)::text, 6, '0');
  insert into autopay_codes (tenant_id, code_hash) values (v_t, autopay_hash(v_t::text || ':' || v_code));
  perform autopay_email(v_email, 'Your autopay confirmation code: ' || v_code,
    '<p>Hi ' || repair_esc(split_part(v_name, ' ', 1)) || ',</p><p>Your code to set up autopay is <b style="font-size:1.4em;letter-spacing:.1em">' || v_code || '</b>. It works for 10 minutes.</p>'
    || '<p>Only enter it if <b>you</b> are setting up autopay in your own portal. If you did not ask for this, do not share the code, and call (262) 236-5443.</p><p>2nd Chance Housing</p>', 'autopay_code');
  return jsonb_build_object('sent', true, 'to', left(v_email, 2) || '***' || substr(v_email, position('@' in v_email)));
end;
$$;
revoke all on function autopay_request_code() from public, anon;
grant execute on function autopay_request_code() to authenticated;

create or replace function autopay_start(p_code text, p_draw_day int, p_typed_name text, p_acks jsonb, p_version text, p_first date)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_t uuid := autopay_me(); s record; v_name text; v_email text; c autopay_codes; a autopay_authorizations; v_first date; v_terms text;
  v_hdr jsonb := coalesce(nullif(current_setting('request.headers', true), '')::jsonb, '{}'::jsonb); v_words text[]; v_typed text[]; w text; ok boolean := true;
begin
  if not exists (select 1 from resident_me()) then raise exception 'Resident sign-in required' using errcode = '42501'; end if;
  if autopay_view_as_session() then raise exception 'Autopay can only be set up by the tenant, from their own sign-in.'; end if;
  if condo_setting('autopay_enabled', 'off') <> 'on' then raise exception 'Autopay is not available yet.'; end if;
  if v_t is null then raise exception 'Autopay is for an active lease or land contract.'; end if;
  if p_version is distinct from 'autopay-2026-10-v1' then raise exception 'These terms changed. Reload the page and read them again.'; end if;
  if coalesce(p_draw_day, 0) not between 1 and 5 then raise exception 'Choose a day from the 1st to the 5th.'; end if;
  if not (coalesce(p_acks ->> 'set_up_myself', 'false') = 'true' and coalesce(p_acks ->> 'understand_return', 'false') = 'true'
          and coalesce(p_acks ->> 'keep_money', 'false') = 'true' and coalesce(p_acks ->> 'can_cancel', 'false') = 'true') then
    raise exception 'Check all four boxes to show you read and agree.';
  end if;
  select name, email into v_name, v_email from tenants where id = v_t;
  if coalesce(v_email, '') not like '%@%' then raise exception 'We need your email address on file first.'; end if;
  -- the typed name must contain the first and last name on file
  v_words := regexp_split_to_array(lower(regexp_replace(coalesce(v_name, ''), '[^A-Za-z ]', ' ', 'g')), '\s+');
  v_typed := regexp_split_to_array(lower(regexp_replace(coalesce(p_typed_name, ''), '[^A-Za-z ]', ' ', 'g')), '\s+');
  if array_length(v_words, 1) >= 2 and not (v_words[1] = any (v_typed) and v_words[array_length(v_words, 1)] = any (v_typed)) then
    raise exception 'Type your full name as it appears on your account.';
  end if;
  -- the code
  select * into c from autopay_codes where tenant_id = v_t and used_at is null and expires_at > now() order by id desc limit 1 for update;
  if c.id is null then raise exception 'That code has expired. Ask for a new one.'; end if;
  if c.attempts >= 5 then raise exception 'Too many wrong tries. Ask for a new code.'; end if;
  if c.code_hash <> autopay_hash(v_t::text || ':' || trim(coalesce(p_code, ''))) then
    update autopay_codes set attempts = attempts + 1 where id = c.id;
    raise exception 'That code is not right.';
  end if;
  update autopay_codes set used_at = now() where id = c.id;
  select * into s from autopay_subject(v_t) limit 1;
  v_first := autopay_next_draw(p_draw_day, autopay_today() + 8);
  if p_first is distinct from v_first then raise exception 'The page is out of date. Reload it and try again.'; end if;
  v_terms := autopay_terms(trim(p_typed_name), s.amount, p_draw_day, s.label, s.is_lease, v_first);
  -- replace any unfinished setup
  perform autopay_set_actor('tenant');
  update autopay_authorizations set status = 'canceled', ended_at = now(), ended_by = 'tenant', ended_reason = 'replaced by a new setup' where tenant_id = v_t and status = 'pending';
  insert into autopay_authorizations (tenant_id, lease_id, land_contract_id, amount, draw_day, terms_version, terms_text, acks, typed_name, ip, user_agent, row_hash)
  values (v_t, s.lease_id, s.land_contract_id, s.amount, p_draw_day, p_version, v_terms, p_acks, trim(p_typed_name),
          left(coalesce(v_hdr ->> 'x-forwarded-for', v_hdr ->> 'cf-connecting-ip', ''), 80), left(coalesce(v_hdr ->> 'user-agent', ''), 300), 'pending')
  returning * into a;
  perform autopay_event(a.id, 'created', jsonb_build_object('amount', a.amount, 'draw_day', a.draw_day, 'first_draw', v_first, 'terms_version', a.terms_version, 'ip', a.ip), 'tenant');
  return jsonb_build_object('authorization_id', a.id);
end;
$$;
revoke all on function autopay_start(text, int, text, jsonb, text, date) from public, anon;
grant execute on function autopay_start(text, int, text, jsonb, text, date) to authenticated;
