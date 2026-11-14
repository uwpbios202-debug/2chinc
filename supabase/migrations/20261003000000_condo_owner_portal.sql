-- ===========================================================================
-- 2nd Chance Housing — condo owner portal (Royal Orleans Condominium -
-- Addition One, 6622/6626 N. Bourbon St., Milwaukee)
-- ===========================================================================
-- Owners sign in at /owners/ (https://2ndchinc.org/owners/ once live) to
-- review and update their contact details. This runs on 2nd Chance
-- Housing's own Supabase project; nothing here depends on SelassieFest.
--
-- Data model: the UNIT is the permanent record. Owners attach to a unit
-- through condo_ownerships (start/end dates); an owner coming or going never
-- rewrites the unit. One owner can hold several units (one ownership row each).
--
-- Sign-in is two steps:
--   1. A 6-digit code emailed to the owner's address on file (Supabase Auth
--      signInWithOtp; the auth-send-email hook only sends it to addresses on
--      file in condo_owners/condo_staff, so the page can't be used to probe
--      which emails are owners).
--   2. A 6-digit code texted to the mobile number ON FILE (never one typed in
--      at sign-in), sent and checked by the condo-owner-sms edge function via
--      Twilio Verify. A passed check is recorded in condo_mfa_sessions against
--      the Supabase session id in the JWT; every data RPC below requires that
--      row (condo_session_ok), so an email-only session sees nothing.
--
-- Every table has RLS on and NO policies: nothing is readable or writable
-- through the REST API directly. All access goes through the security-definer
-- functions at the bottom, each of which checks who is calling.
--
-- Reminders: the condo-owner-reminders edge function (daily pg_cron) emails
-- any current owner whose details haven't been confirmed in 6 months, with
-- a one-click "Nothing changed" link (single-use token, reveals nothing) and
-- a "Review my information" link to the portal. One follow-up after 14 days.
-- Owner data is NOT in this file — it is loaded from data/ (gitignored),
-- see data/condo-owner-portal-seed.sql.
-- ===========================================================================

create table if not exists condo_units (
  id uuid primary key default gen_random_uuid(),
  unit_number text not null unique,
  address text,
  pin text,                       -- property tax key; shown as the Account #
  size_sqft integer,
  bedrooms text,
  bathrooms text,
  fee_allocation_pct numeric,
  occupancy text check (occupancy in ('owner', 'tenant', 'vacant')),
  notes text,                     -- staff-only
  updated_at timestamptz not null default now()
);

create table if not exists condo_owners (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  email text,                     -- sign-in email; only staff can change it
  alt_email text,
  phone_mobile text,              -- also the 2-step sign-in phone
  phone_home text,
  phone_work text,
  communications_preference text not null default 'Mailing' check (communications_preference in ('Mailing', 'Email')),
  mailing_line1 text,
  mailing_line2 text,
  mailing_city text,
  mailing_state text,
  mailing_zip text,
  alt_line1 text,
  alt_line2 text,
  alt_city text,
  alt_state text,
  alt_zip text,
  emergency_name text,
  emergency_phone text,
  eligible_1099 boolean not null default false,
  staff_notes text,               -- never shown to the owner
  legacy_ids text[] not null default '{}',
  last_confirmed_at timestamptz,
  last_confirmed_how text check (last_confirmed_how in ('updated', 'nothing_changed')),
  reminders_sent_in_cycle integer not null default 0,
  last_reminded_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
-- Not unique: a former owner (e.g. an LLC) can share an address with a
-- current one. Sign-in resolves to the owner holding a CURRENT unit.
create index if not exists condo_owners_email_idx on condo_owners (lower(email));

create table if not exists condo_ownerships (
  id uuid primary key default gen_random_uuid(),
  unit_id uuid not null references condo_units(id) on delete cascade,
  owner_id uuid not null references condo_owners(id) on delete restrict,
  start_date date,
  end_date date,
  is_current boolean not null default false,
  fee numeric,
  fee_frequency text not null default 'Monthly',
  board_position text,            -- a board seat sits on the unit's current ownership
  legacy_account text,          -- legacy account number
  delinquency text,
  updated_at timestamptz not null default now()
);
create index if not exists condo_ownerships_owner_idx on condo_ownerships (owner_id);
create index if not exists condo_ownerships_unit_idx on condo_ownerships (unit_id);

-- People who can see the staff view. They also pass the text-code step,
-- against phone_mobile here.
create table if not exists condo_staff (
  email text primary key,
  name text,
  phone_mobile text
);

-- One row per Supabase session that has passed the text-code step.
create table if not exists condo_mfa_sessions (
  session_id uuid primary key,
  user_id uuid not null,
  verified_at timestamptz not null default now()
);

-- Text-code sends, for rate limiting (5 per user per hour).
create table if not exists condo_sms_requests (
  id bigint generated always as identity primary key,
  user_id uuid not null,
  created_at timestamptz not null default now()
);
create index if not exists condo_sms_requests_user_idx on condo_sms_requests (user_id, created_at);

-- Single-use "Nothing changed" links from reminder emails (only the
-- sha-256 hash is stored; the token itself exists only in the email).
create table if not exists condo_reminder_tokens (
  token_hash text primary key,
  owner_id uuid not null references condo_owners(id) on delete cascade,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '30 days',
  used_at timestamptz
);

-- One row per owner save / confirmation / staff edit. The condo-notify-update
-- edge function emails the property manager each new row (old -> new) and
-- stamps notified_at. The page pings that function right after a save, and
-- the daily reminder run sweeps up anything a dropped ping missed.
create table if not exists condo_profile_updates (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references condo_owners(id) on delete cascade,
  owner_name text,
  owner_email text,
  unit_label text,
  kind text not null check (kind in ('updated', 'nothing_changed', 'staff_edit')),
  via text not null check (via in ('portal', 'email_link', 'staff')),
  changes jsonb not null default '[]'::jsonb,   -- [{field, label, old, new}]
  created_at timestamptz not null default now(),
  notified_at timestamptz
);
create index if not exists condo_profile_updates_pending_idx on condo_profile_updates (created_at) where notified_at is null;

alter table condo_units enable row level security;
alter table condo_owners enable row level security;
alter table condo_ownerships enable row level security;
alter table condo_staff enable row level security;
alter table condo_mfa_sessions enable row level security;
alter table condo_sms_requests enable row level security;
alter table condo_reminder_tokens enable row level security;
alter table condo_profile_updates enable row level security;

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- True when this request's Supabase session has passed the text-code step
-- within the last 12 hours.
create or replace function condo_session_ok()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (
    select 1 from condo_mfa_sessions
    where session_id = nullif(auth.jwt() ->> 'session_id', '')::uuid
      and user_id = auth.uid()
      and verified_at > now() - interval '12 hours'
  );
$$;

create or replace function condo_is_staff()
returns boolean
language sql stable security definer set search_path = public
as $$
  select exists (select 1 from condo_staff where lower(email) = lower(auth.email()));
$$;

-- The owner record for the signed-in email: the one holding a current unit.
create or replace function condo_owner_for_email(p_email text)
returns uuid
language sql stable security definer set search_path = public
as $$
  select o.id from condo_owners o
  where lower(o.email) = lower(p_email)
    and exists (select 1 from condo_ownerships s where s.owner_id = o.id and s.is_current)
  order by o.created_at
  limit 1;
$$;

create or replace function condo_unit_label(p_owner_id uuid)
returns text
language sql stable security definer set search_path = public
as $$
  select coalesce(string_agg('Unit #' || u.unit_number, ', ' order by nullif(regexp_replace(u.unit_number, '\D', '', 'g'), '')::int), '')
  from condo_ownerships s join condo_units u on u.id = s.unit_id
  where s.owner_id = p_owner_id and s.is_current;
$$;

-- Masks a phone number to its last 4 digits for display.
create or replace function condo_mask_phone(p text)
returns text
language sql immutable
as $$
  select case when length(regexp_replace(coalesce(p, ''), '\D', '', 'g')) >= 4
    then '(•••) •••-' || right(regexp_replace(p, '\D', '', 'g'), 4) else null end;
$$;

-- ---------------------------------------------------------------------------
-- Called by the page right after the email-code step (before the text step):
-- what kind of account this is and where the text code will go.
-- ---------------------------------------------------------------------------
create or replace function condo_whoami()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_owner uuid := condo_owner_for_email(auth.email());
  v_staff boolean := condo_is_staff();
  v_phone text;
begin
  if auth.uid() is null then
    return jsonb_build_object('role', 'none');
  end if;
  if v_staff then
    select phone_mobile into v_phone from condo_staff where lower(email) = lower(auth.email());
  elsif v_owner is not null then
    select phone_mobile into v_phone from condo_owners where id = v_owner;
  else
    return jsonb_build_object('role', 'none');
  end if;
  return jsonb_build_object(
    'role', case when v_staff then 'staff' else 'owner' end,
    'is_owner', v_owner is not null,
    'verified', condo_session_ok(),
    'phone_hint', condo_mask_phone(v_phone),
    'has_phone', v_phone is not null and length(regexp_replace(v_phone, '\D', '', 'g')) >= 10
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- Owner functions (require the text-code step)
-- ---------------------------------------------------------------------------

create or replace function condo_my_profile()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_owner uuid := condo_owner_for_email(auth.email());
  v jsonb;
begin
  if not condo_session_ok() then raise exception 'Two-step sign-in required' using errcode = '42501'; end if;
  if v_owner is null then raise exception 'No current ownership on file for this email' using errcode = '42501'; end if;
  select jsonb_build_object(
    'name', o.name, 'email', o.email, 'alt_email', o.alt_email,
    'phone_mobile', o.phone_mobile, 'phone_home', o.phone_home, 'phone_work', o.phone_work,
    'communications_preference', o.communications_preference,
    'mailing_line1', o.mailing_line1, 'mailing_line2', o.mailing_line2, 'mailing_city', o.mailing_city,
    'mailing_state', o.mailing_state, 'mailing_zip', o.mailing_zip,
    'alt_line1', o.alt_line1, 'alt_line2', o.alt_line2, 'alt_city', o.alt_city, 'alt_state', o.alt_state, 'alt_zip', o.alt_zip,
    'emergency_name', o.emergency_name, 'emergency_phone', o.emergency_phone,
    'last_confirmed_at', o.last_confirmed_at,
    'units', coalesce((
      select jsonb_agg(jsonb_build_object(
        'unit_number', u.unit_number, 'address', u.address, 'pin', u.pin,
        'owner_since', s.start_date, 'board_position', s.board_position,
        'fee', s.fee, 'fee_frequency', s.fee_frequency)
        order by nullif(regexp_replace(u.unit_number, '\D', '', 'g'), '')::int)
      from condo_ownerships s join condo_units u on u.id = s.unit_id
      where s.owner_id = o.id and s.is_current), '[]'::jsonb)
  ) into v from condo_owners o where o.id = v_owner;
  return v;
end;
$$;

-- Fields an owner may change, with labels for the staff email. Sign-in email
-- is deliberately absent: changing it would lock the owner out mid-session;
-- the page tells them to contact the office instead.
create or replace function condo_owner_editable_fields()
returns jsonb
language sql immutable
as $$
  select '{
    "alt_email": "Alternate email", "phone_mobile": "Mobile phone (sign-in texts)", "phone_home": "Home phone",
    "phone_work": "Work phone", "communications_preference": "Prefers",
    "mailing_line1": "Mailing street", "mailing_line2": "Mailing line 2", "mailing_city": "Mailing city",
    "mailing_state": "Mailing state", "mailing_zip": "Mailing ZIP",
    "alt_line1": "Alternate street", "alt_line2": "Alternate line 2", "alt_city": "Alternate city",
    "alt_state": "Alternate state", "alt_zip": "Alternate ZIP",
    "emergency_name": "Emergency contact", "emergency_phone": "Emergency contact phone"
  }'::jsonb;
$$;

-- Applies whitelisted fields from p_changes to an owner and logs old -> new.
-- Shared by the owner save and the staff edit.
create or replace function condo_apply_owner_changes(p_owner uuid, p_changes jsonb, p_fields jsonb)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_old jsonb;
  v_diff jsonb := '[]'::jsonb;
  k text;
  v_new text;
  v_prev text;
begin
  select to_jsonb(o) into v_old from condo_owners o where o.id = p_owner;
  for k in select jsonb_object_keys(p_changes) loop
    if not (p_fields ? k) then continue; end if;
    v_new := nullif(btrim(p_changes ->> k), '');
    v_prev := v_old ->> k;
    if k = 'communications_preference' and v_new not in ('Mailing', 'Email') then
      raise exception 'Invalid communications preference' using errcode = '22023';
    end if;
    if k = 'name' and v_new is null then
      raise exception 'Name is required' using errcode = '22023';
    end if;
    if length(coalesce(v_new, '')) > 300 then
      raise exception '% is too long', p_fields ->> k using errcode = '22023';
    end if;
    if v_new is distinct from v_prev then
      v_diff := v_diff || jsonb_build_object('field', k, 'label', p_fields ->> k, 'old', v_prev, 'new', v_new);
      execute format('update condo_owners set %I = $1, updated_at = now() where id = $2', k) using v_new, p_owner;
    end if;
  end loop;
  return v_diff;
end;
$$;
revoke all on function condo_apply_owner_changes(uuid, jsonb, jsonb) from public, anon, authenticated;

-- Saves the owner's edits. Saving always counts as confirming the record,
-- even when nothing differs.
create or replace function condo_update_my_profile(p_changes jsonb)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_owner uuid := condo_owner_for_email(auth.email());
  v_diff jsonb;
  v_name text;
  v_email text;
  v_update uuid;
begin
  if not condo_session_ok() then raise exception 'Two-step sign-in required' using errcode = '42501'; end if;
  if v_owner is null then raise exception 'No current ownership on file for this email' using errcode = '42501'; end if;
  if jsonb_typeof(p_changes) <> 'object' then raise exception 'Expected an object' using errcode = '22023'; end if;
  if nullif(btrim(p_changes ->> 'phone_mobile'), '') is not null
     and length(regexp_replace(p_changes ->> 'phone_mobile', '\D', '', 'g')) < 10 then
    raise exception 'Mobile phone needs all 10 digits — it is where your sign-in codes are texted' using errcode = '22023';
  end if;
  v_diff := condo_apply_owner_changes(v_owner, p_changes, condo_owner_editable_fields());
  update condo_owners
    set last_confirmed_at = now(),
        last_confirmed_how = case when jsonb_array_length(v_diff) > 0 then 'updated' else 'nothing_changed' end,
        reminders_sent_in_cycle = 0
    where id = v_owner
    returning name, email into v_name, v_email;
  insert into condo_profile_updates (owner_id, owner_name, owner_email, unit_label, kind, via, changes)
    values (v_owner, v_name, v_email, condo_unit_label(v_owner),
            case when jsonb_array_length(v_diff) > 0 then 'updated' else 'nothing_changed' end, 'portal', v_diff)
    returning id into v_update;
  return jsonb_build_object('changed', jsonb_array_length(v_diff), 'confirmed_at', now(), 'update_id', v_update);
end;
$$;

create or replace function condo_confirm_nothing_changed()
returns jsonb
language plpgsql security definer set search_path = public
as $$
begin
  return condo_update_my_profile('{}'::jsonb);
end;
$$;

-- One-click "Nothing changed" from a reminder email. Callable without
-- signing in; it only confirms, and returns nothing about the owner.
create or replace function condo_confirm_by_token(p_token text)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_owner uuid;
  v_name text;
  v_email text;
begin
  update condo_reminder_tokens
    set used_at = now()
    where token_hash = encode(extensions.digest(coalesce(p_token, ''), 'sha256'), 'hex')
      and used_at is null and expires_at > now()
    returning owner_id into v_owner;
  if v_owner is null then
    return jsonb_build_object('ok', false);
  end if;
  update condo_owners
    set last_confirmed_at = now(), last_confirmed_how = 'nothing_changed', reminders_sent_in_cycle = 0
    where id = v_owner
    returning name, email into v_name, v_email;
  -- Any other outstanding links for this owner are no longer needed.
  update condo_reminder_tokens set used_at = now() where owner_id = v_owner and used_at is null;
  insert into condo_profile_updates (owner_id, owner_name, owner_email, unit_label, kind, via)
    values (v_owner, v_name, v_email, condo_unit_label(v_owner), 'nothing_changed', 'email_link');
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------------------------------------------------------------------------
-- Staff functions (require staff + the text-code step)
-- ---------------------------------------------------------------------------

create or replace function condo_staff_overview()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'units', coalesce((select jsonb_agg(jsonb_build_object(
        'id', u.id, 'unit_number', u.unit_number, 'address', u.address, 'pin', u.pin, 'occupancy', u.occupancy,
        'current', (select jsonb_agg(jsonb_build_object('owner_id', s.owner_id, 'owner_name', o.name, 'since', s.start_date,
                      'board_position', s.board_position, 'fee', s.fee, 'fee_frequency', s.fee_frequency))
                    from condo_ownerships s join condo_owners o on o.id = s.owner_id
                    where s.unit_id = u.id and s.is_current))
        order by nullif(regexp_replace(u.unit_number, '\D', '', 'g'), '')::int) from condo_units u), '[]'::jsonb),
    'owners', coalesce((select jsonb_agg(to_jsonb(o) - 'legacy_ids' || jsonb_build_object(
        'units', condo_unit_label(o.id),
        'is_current', exists (select 1 from condo_ownerships s where s.owner_id = o.id and s.is_current))
        order by o.name) from condo_owners o), '[]'::jsonb),
    'updates', coalesce((select jsonb_agg(to_jsonb(p) order by p.created_at desc)
        from (select * from condo_profile_updates order by created_at desc limit 50) p), '[]'::jsonb)
  );
end;
$$;

create or replace function condo_staff_update_owner(p_owner_id uuid, p_changes jsonb)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare
  v_diff jsonb;
  v_name text;
  v_email text;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  v_diff := condo_apply_owner_changes(p_owner_id, p_changes,
    condo_owner_editable_fields() || '{"name": "Name", "email": "Sign-in email", "staff_notes": "Staff notes"}'::jsonb);
  if jsonb_array_length(v_diff) > 0 then
    select name, email into v_name, v_email from condo_owners where id = p_owner_id;
    insert into condo_profile_updates (owner_id, owner_name, owner_email, unit_label, kind, via, changes)
      values (p_owner_id, v_name, v_email, condo_unit_label(p_owner_id), 'staff_edit', 'staff', v_diff);
  end if;
  return jsonb_build_object('changed', jsonb_array_length(v_diff));
end;
$$;

-- ---------------------------------------------------------------------------
-- Service-role-only functions used by the edge functions
-- ---------------------------------------------------------------------------

-- The phone the text code goes to for this signed-in email (staff record
-- first, then the owner's current record). Never a client-supplied number.
create or replace function condo_mfa_phone_for(p_email text)
returns text
language sql stable security definer set search_path = public
as $$
  select coalesce(
    (select phone_mobile from condo_staff where lower(email) = lower(p_email)),
    (select phone_mobile from condo_owners where id = condo_owner_for_email(p_email)));
$$;

-- Owners due a reminder: current owners with an email whose details are
-- unconfirmed for 6 months — first reminder, then one follow-up 14 days on.
create or replace function condo_reminders_due()
returns table (owner_id uuid, name text, email text, unit_label text, is_followup boolean)
language sql stable security definer set search_path = public
as $$
  select o.id, o.name, o.email, condo_unit_label(o.id), o.reminders_sent_in_cycle = 1
  from condo_owners o
  where coalesce(o.email, '') <> ''
    and exists (select 1 from condo_ownerships s where s.owner_id = o.id and s.is_current)
    and (o.last_confirmed_at is null or o.last_confirmed_at < now() - interval '6 months')
    and (o.reminders_sent_in_cycle = 0
         or (o.reminders_sent_in_cycle = 1 and o.last_reminded_at < now() - interval '14 days'));
$$;

create or replace function condo_record_reminder_sent(p_owner_id uuid, p_token_hash text)
returns void
language sql security definer set search_path = public
as $$
  insert into condo_reminder_tokens (token_hash, owner_id) values (p_token_hash, p_owner_id);
  update condo_owners
    set reminders_sent_in_cycle = reminders_sent_in_cycle + 1, last_reminded_at = now()
    where id = p_owner_id;
$$;

-- True when the email belongs to an owner with a current unit or to staff.
-- The auth-send-email hook uses it so sign-in codes only go to people on file.
create or replace function condo_email_on_file(p_email text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select condo_owner_for_email(p_email) is not null
      or exists (select 1 from condo_staff where lower(email) = lower(p_email));
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
revoke all on function condo_session_ok() from public, anon;
revoke all on function condo_is_staff() from public, anon;
revoke all on function condo_owner_for_email(text) from public, anon, authenticated;
revoke all on function condo_unit_label(uuid) from public, anon, authenticated;
revoke all on function condo_whoami() from public, anon;
revoke all on function condo_my_profile() from public, anon;
revoke all on function condo_update_my_profile(jsonb) from public, anon;
revoke all on function condo_confirm_nothing_changed() from public, anon;
revoke all on function condo_staff_overview() from public, anon;
revoke all on function condo_staff_update_owner(uuid, jsonb) from public, anon;
revoke all on function condo_mfa_phone_for(text) from public, anon, authenticated;
revoke all on function condo_reminders_due() from public, anon, authenticated;
revoke all on function condo_record_reminder_sent(uuid, text) from public, anon, authenticated;
revoke all on function condo_email_on_file(text) from public, anon, authenticated;

grant execute on function condo_whoami() to authenticated;
grant execute on function condo_my_profile() to authenticated;
grant execute on function condo_update_my_profile(jsonb) to authenticated;
grant execute on function condo_confirm_nothing_changed() to authenticated;
grant execute on function condo_staff_overview() to authenticated;
grant execute on function condo_staff_update_owner(uuid, jsonb) to authenticated;
grant execute on function condo_confirm_by_token(text) to anon, authenticated;
grant execute on function condo_mfa_phone_for(text) to service_role;
grant execute on function condo_reminders_due() to service_role;
grant execute on function condo_record_reminder_sent(uuid, text) to service_role;
grant execute on function condo_email_on_file(text) to service_role;

-- ---------------------------------------------------------------------------
-- Daily reminder job — applied by hand AFTER owner data is loaded and the
-- launch is approved (the first run emails every owner never confirmed).
-- Replace <PROJECT_REF> and <SECRET> (the CONDO_REMINDER_SECRET edge-function
-- secret). Locally, run the function by hand instead (see ROADMAP.md).
-- ---------------------------------------------------------------------------
-- select cron.schedule('condo-owner-reminders', '0 14 * * *', $$
--   select net.http_post(
--     url := 'https://<PROJECT_REF>.supabase.co/functions/v1/condo-owner-reminders',
--     headers := jsonb_build_object('Content-Type', 'application/json', 'x-webhook-secret', '<SECRET>'),
--     body := '{}'::jsonb);
-- $$);
