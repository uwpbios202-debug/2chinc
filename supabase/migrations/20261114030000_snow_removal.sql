-- Snow removal vendor system (Stephen, 10/26/2026).
-- Vendor: Safe Investment Property Management LLC (Steven Hudson). Client: ROCA1 (Royal Orleans Condominium Association),
-- signed for by Albert Harris, President. Agreement "Option A, per service": $140 per completed push, 6622 & 6626 N Bourbon St.
--
-- What it does:
--   * The agreement is stored in the database, signed in the portal by the vendor and then by ROCA1's president (typed name,
--     time stamp), and a copy is emailed to both and to the office.
--   * The vendor presses ONE button on https://2ndchinc.org/contractor/ : an email goes to every household on the property
--     (the tenant of each rented unit, the owner of owner-occupied units and of Unit 6, which is owner-direct) asking them
--     to move their vehicle. The visit is logged. A second press within 4 hours is refused.
--   * The vendor finishes the visit with before and after photos; the office reviews at https://2ndchinc.org/staff/snow/ ,
--     approves ($140), and records the payment. ROCA1 pays the vendor by Zelle (Stephen, 10/26/2026), so this system tracks
--     what is owed and what was paid and does not move money.
--   * Junk removal: the vendor proposes it with photos, the office approves an amount, the vendor does it with after photos.
--
-- Nothing here reads owner_direct_tenants. Unit 6 gets its owner's email only.

-- ---------------------------------------------------------------------------
-- The vendor's account can be used by more than one login: the main email plus extra ones (for example the office
-- and other staff), so the office can run the button and upload photos until the vendor has a login of their own.
alter table vendors add column if not exists extra_emails text[] not null default '{}';
create or replace function contractor_vendor_ids(p_email text)
returns setof uuid
language sql stable security definer set search_path = public as $$
  select id from vendors where portal_access and p_email is not null
    and (lower(coalesce(email, '')) = lower(p_email) or lower(p_email) = any (select lower(x) from unnest(extra_emails) x));
$$;
revoke all on function contractor_vendor_ids(text) from public, anon, authenticated;
grant execute on function contractor_vendor_ids(text) to service_role;

-- Tables (all access goes through the security-definer functions below)

create table if not exists snow_agreements (
  id uuid primary key default gen_random_uuid(),
  vendor_id uuid not null references vendors(id) on delete restrict,
  season text not null default '2026-2027',
  version text not null default 'snow-2026-27-optA-v1',
  rate_per_push numeric(10,2) not null default 140 check (rate_per_push > 0),
  client_name text not null default 'Royal Orleans Condominium Association (ROCA1)',
  client_signer_name text not null default 'Albert Harris',
  client_signer_title text not null default 'President',
  client_signer_email text,
  terms jsonb not null,
  status text not null default 'awaiting_vendor' check (status in ('awaiting_vendor', 'awaiting_client', 'active', 'ended')),
  vendor_signed_name text,
  vendor_signed_at timestamptz,
  vendor_signed_by text,
  client_signed_name text,
  client_signed_at timestamptz,
  client_signed_by text,
  created_at timestamptz not null default now(),
  unique (vendor_id, season)
);
alter table snow_agreements enable row level security;

create table if not exists snow_visits (
  id uuid primary key default gen_random_uuid(),
  agreement_id uuid not null references snow_agreements(id) on delete restrict,
  vendor_id uuid not null references vendors(id) on delete restrict,
  kind text not null default 'snow' check (kind in ('snow', 'junk')),
  status text not null default 'notified' check (status in ('notified', 'proposed', 'junk_approved', 'declined', 'done', 'returned', 'approved', 'paid')),
  description text,                         -- junk: what and where
  notice_sent_at timestamptz,
  notice_count integer,                     -- how many households were emailed
  window_start timestamptz,                 -- stalls must be empty from here ...
  window_end timestamptz,                   -- ... to here
  notice_units text[],                      -- unit numbers only, never emails
  started_at timestamptz,
  completed_at timestamptz,
  vendor_note text,
  before_photos text[] not null default '{}',
  after_photos text[] not null default '{}',
  amount numeric(10,2),
  office_note text,
  reviewed_at timestamptz,
  reviewed_by text,
  paid_on date,
  paid_ref text,
  paid_method text,
  created_at timestamptz not null default now()
);
alter table snow_visits enable row level security;
create index if not exists snow_visits_vendor_idx on snow_visits (vendor_id, created_at desc);

grant all on snow_agreements, snow_visits to service_role;     -- no direct access for signed-in users or anon: functions only

-- ---------------------------------------------------------------------------
-- Photos bucket (private). Folder = the visit id.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('snow-photos', 'snow-photos', false, 10485760, array['image/jpeg', 'image/png', 'image/webp', 'image/heic'])
on conflict (id) do nothing;

-- Photos for a new junk proposal are uploaded before the row exists (the folder is a fresh id), so the upload
-- policy also accepts a folder that no visit uses yet, only for a signed-in vendor. Nothing is readable until a row owns it.
create or replace function snow_photo_vendor_ok(p_name text)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from contractor_me())
     and (exists (select 1 from snow_visits v where v.id::text = (storage.foldername(p_name))[1] and v.vendor_id in (select contractor_me()))
          or not exists (select 1 from snow_visits v where v.id::text = (storage.foldername(p_name))[1]));
$$;

revoke all on function snow_photo_vendor_ok(text) from public, anon;
grant execute on function snow_photo_vendor_ok(text) to authenticated;

drop policy if exists "snow-photos upload" on storage.objects;
create policy "snow-photos upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'snow-photos' and snow_photo_vendor_ok(name));
drop policy if exists "snow-photos read" on storage.objects;
create policy "snow-photos read" on storage.objects for select to authenticated
  using (bucket_id = 'snow-photos' and (snow_photo_vendor_ok(name) or staff_session_staff()));

-- ---------------------------------------------------------------------------
-- The agreement text (from the signed-off PDF, client changed to ROCA1)

create or replace function snow_terms()
returns jsonb
language sql immutable as $$
  select jsonb_build_array(
    jsonb_build_object('h', 'Service provider', 'p', 'Safe Investment Property Management LLC, Steven Hudson, 262-281-5071.'),
    jsonb_build_object('h', 'Client', 'p', 'Royal Orleans Condominium Association (ROCA1), represented by Albert Harris, President.'),
    jsonb_build_object('h', 'Property address', 'p', '6622 & 6626 N Bourbon St, Milwaukee, WI 53224. One combined property: shared parking lot, two entrance doors and two corresponding walkways.'),
    jsonb_build_object('h', 'Rate and included services', 'p', '$140 per completed push/service visit. Includes plowing the shared parking lot, clearing both entrance walkways, and salting/de-icing serviced areas as needed.'),
    jsonb_build_object('h', 'Priority service window', 'p', 'Target service time: 8:00 to 10:00 AM following snowfall. Timing may vary due to traffic, storm conditions or operational delays. Service will be completed within 24 hours after snowfall ends, subject to safe access and extraordinary weather conditions.'),
    jsonb_build_object('h', 'Site requirements', 'p', 'Pile snow on the north side of the parking lot and keep dumpster access clear. Client coordinates removal of remaining vehicles through its towing provider at approximately 7:59 AM. The provider sends the residents a move-your-vehicle email through the portal before each push.'),
    jsonb_build_object('h', 'Additional junk removal services', 'p', 'The provider also offers junk removal services. If the provider notices any debris around the property during snow removal, it will take photos and send them to the office for approval. Once approved, the provider will remove the items and provide before-and-after photos of the completed work.'),
    jsonb_build_object('h', 'Service documentation and terms', 'p', 'Before-and-after photos will be provided for snow services. Additional pushes are billed at $140 each. City/public sidewalks and work outside the stated scope require separate approval. Each completed visit is reviewed by the client and paid by Zelle after approval. This agreement takes effect when signed by both parties.')
  );
$$;

-- ---------------------------------------------------------------------------
-- Helpers

create or replace function snow_my_agreement()
returns snow_agreements
language sql stable security definer set search_path = public as $$
  select a.* from snow_agreements a where a.vendor_id in (select contractor_me()) order by a.created_at desc limit 1;
$$;
revoke all on function snow_my_agreement() from public, anon, authenticated;

create or replace function snow_require_staff()
returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
end;
$$;
revoke all on function snow_require_staff() from public, anon, authenticated;

create or replace function snow_require_vendor()
returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not exists (select 1 from contractor_me()) then raise exception 'Contractor sign-in required' using errcode = '42501'; end if;
end;
$$;
revoke all on function snow_require_vendor() from public, anon, authenticated;

create or replace function snow_office_mail(p_subject text, p_body text, p_kind text)
returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  insert into email_outbox (to_email, subject, html, kind)
  select value, p_subject, '<div style="font-family:Arial,sans-serif;max-width:640px;color:#1b2430">' || p_body || '</div>', p_kind
  from portal_settings where key = 'office_email' and coalesce(value, '') <> '';
end;
$$;
revoke all on function snow_office_mail(text, text, text) from public, anon, authenticated;

create or replace function snow_agreement_html(a snow_agreements)
returns text
language sql stable security definer set search_path = public as $$
  select '<h2>Snow Removal Service Agreement, Winter ' || repair_esc(a.season) || ' (Option A, per service)</h2>'
    || (select string_agg('<p><b>' || repair_esc(t->>'h') || '</b><br>' || repair_esc(t->>'p') || '</p>', '' order by ord)
        from jsonb_array_elements(a.terms) with ordinality as x(t, ord))
    || '<p><b>Signed (provider):</b> ' || coalesce(repair_esc(a.vendor_signed_name), '—') || ', '
    || coalesce(to_char(a.vendor_signed_at at time zone 'America/Chicago', 'FMMM/FMDD/YYYY FMHH12:MI AM') || ' Central', 'not yet') || '<br>'
    || '<b>Signed (client):</b> ' || coalesce(repair_esc(a.client_signed_name) || ', ' || repair_esc(a.client_signer_title) || ', '
    || to_char(a.client_signed_at at time zone 'America/Chicago', 'FMMM/FMDD/YYYY FMHH12:MI AM') || ' Central', 'not yet') || '</p>';
$$;
revoke all on function snow_agreement_html(snow_agreements) from public, anon, authenticated;

-- Who gets the move-your-vehicle email: one row per email address, with the unit numbers it covers.
create or replace function snow_recipients()
returns table (email text, first_name text, units text[])
language sql stable security definer set search_path = public as $$
  with dunits as (
    select trim(x) as u from portal_settings s, unnest(string_to_array(s.value, ',')) x where s.key = 'owner_direct_units'
  ), cu as (
    select id, unit_number, occupancy, (unit_number in (select u from dunits)) as is_direct from condo_units where occupancy <> 'vacant'
  ), ten as (
    select cu.id as uid, cu.unit_number, t.email, t.name
    from cu join rental_units ru on ru.condo_unit_id = cu.id
    join leases l on l.unit_id = ru.id and l.status = 'active'
    join lease_tenants lt on lt.lease_id = l.id join tenants t on t.id = lt.tenant_id
    where cu.occupancy = 'tenant' and not cu.is_direct and coalesce(t.email, '') <> ''
  ), own as (
    select cu.id as uid, cu.unit_number, cu.occupancy, cu.is_direct, o.email, o.name
    from cu join condo_ownerships os on os.unit_id = cu.id and os.is_current join condo_owners o on o.id = os.owner_id
    where coalesce(o.email, '') <> ''
  ), allr as (
    select unit_number, email, name from ten
    union all
    select unit_number, email, name from own
    where occupancy = 'owner' or is_direct or not exists (select 1 from ten where ten.uid = own.uid)
  )
  select lower(email), split_part(min(name), ' ', 1), array_agg(distinct unit_number)
  from allr group by lower(email);
$$;
revoke all on function snow_recipients() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Staff: vendor, agreement, client signature, review, payment

create or replace function snow_vendor_logins(v vendors)
returns setof text
language sql stable as $$
  select distinct lower(x) from unnest(array[v.email] || v.extra_emails) x where x is not null;
$$;
revoke all on function snow_vendor_logins(vendors) from public, anon, authenticated;

create or replace function snow_valid_emails(p text[])
returns text[]
language sql immutable as $$
  select coalesce(array_agg(distinct lower(trim(x))), '{}') from unnest(coalesce(p, '{}')) x where trim(x) ~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$';
$$;

-- Everyone on staff (office staff and admins) may use the vendor account, plus any extra addresses typed in.
create or replace function snow_staff_logins(p text[])
returns text[]
language sql stable security definer set search_path = public as $$
  select snow_valid_emails(coalesce(p, '{}') || coalesce((select array_agg(email) from condo_staff), '{}') || coalesce((select array_agg(email) from portal_admins), '{}'));
$$;
revoke all on function snow_staff_logins(text[]) from public, anon, authenticated;

create or replace function snow_staff_add_vendor(p_name text, p_contact text, p_email text, p_phone text, p_extra text[])
returns uuid
language plpgsql volatile security definer set search_path = public as $$
declare v uuid;
begin
  perform snow_require_staff();
  if coalesce(trim(p_name), '') = '' or cardinality(snow_valid_emails(array[p_email])) = 0 then raise exception 'Enter the company name and a valid email'; end if;
  select id into v from vendors where lower(email) = lower(trim(p_email)) limit 1;
  if v is null then
    insert into vendors (name, category, contact_name, email, mobile, portal_access, extra_emails)
    values (trim(p_name), 'Snow removal', nullif(trim(p_contact), ''), lower(trim(p_email)), nullif(trim(p_phone), ''), true, snow_staff_logins(p_extra)) returning id into v;
  else
    update vendors set portal_access = true, extra_emails = snow_staff_logins(p_extra) where id = v;
  end if;
  return v;
end;
$$;
revoke all on function snow_valid_emails(text[]) from public, anon, authenticated;
revoke all on function snow_staff_add_vendor(text, text, text, text, text[]) from public, anon;
grant execute on function snow_staff_add_vendor(text, text, text, text, text[]) to authenticated;

create or replace function snow_staff_create_agreement(p_vendor uuid, p_rate numeric)
returns uuid
language plpgsql volatile security definer set search_path = public as $$
declare a uuid; v vendors; signer text;
begin
  perform snow_require_staff();
  select * into v from vendors where id = p_vendor;
  if v.id is null then raise exception 'Choose a vendor'; end if;
  if exists (select 1 from snow_agreements where vendor_id = p_vendor and season = '2026-2027') then raise exception 'This vendor already has the 2026-2027 agreement'; end if;
  select email into signer from condo_staff where name = 'Albert Harris' limit 1;
  insert into snow_agreements (vendor_id, rate_per_push, client_signer_email, terms)
  values (p_vendor, coalesce(p_rate, 140), signer, snow_terms()) returning id into a;
  if v.email is not null then
    insert into email_outbox (to_email, subject, html, kind) values (v.email, 'Your snow removal agreement is ready to sign',
      tenant_email_wrap(split_part(coalesce(v.contact_name, v.name), ' ', 1),
        '<p>Your Winter 2026-2027 snow removal agreement with Royal Orleans Condominium Association is ready. Please sign in at <a href="https://2ndchinc.org/contractor/">https://2ndchinc.org/contractor/</a> with your email, read the agreement and sign it. It takes effect once the association''s president has also signed.</p>'),
      'snow_agreement_invite');
  end if;
  return a;
end;
$$;
revoke all on function snow_staff_create_agreement(uuid, numeric) from public, anon;
grant execute on function snow_staff_create_agreement(uuid, numeric) to authenticated;

create or replace function snow_finish_signing(p_id uuid)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare a snow_agreements; v vendors; html text;
begin
  select * into a from snow_agreements where id = p_id;
  if a.vendor_signed_at is not null and a.client_signed_at is not null and a.status <> 'active' then
    update snow_agreements set status = 'active' where id = p_id returning * into a;
    select * into v from vendors where id = a.vendor_id;
    html := snow_agreement_html(a);
    if v.email is not null then
      insert into email_outbox (to_email, subject, html, kind) select l, 'Snow removal agreement is signed by both parties',
        tenant_email_wrap(split_part(coalesce(v.contact_name, v.name), ' ', 1), '<p>Both signatures are in. A copy of the agreement is below. You can now use the "Send move-your-vehicle email" button at <a href="https://2ndchinc.org/contractor/">https://2ndchinc.org/contractor/</a>.</p>' || html), 'snow_agreement_active' from snow_vendor_logins(v) l;
    end if;
    perform snow_office_mail('Snow removal agreement is active: ' || v.name, '<p>Both parties have signed. Copy:</p>' || html, 'snow_agreement_active');
  elsif a.vendor_signed_at is not null and a.client_signed_at is null then
    update snow_agreements set status = 'awaiting_client' where id = p_id;
    perform snow_office_mail('Snow removal agreement waiting for the president''s signature', '<p>The vendor has signed. Albert Harris, President, signs at <a href="https://2ndchinc.org/staff/snow/">https://2ndchinc.org/staff/snow/</a>.</p>', 'snow_agreement_wait');
  end if;
end;
$$;
revoke all on function snow_finish_signing(uuid) from public, anon, authenticated;

create or replace function snow_staff_client_sign(p_id uuid, p_name text)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare a snow_agreements;
begin
  perform snow_require_staff();
  select * into a from snow_agreements where id = p_id for update;
  if a.id is null then raise exception 'Agreement not found'; end if;
  if a.client_signed_at is not null then raise exception 'Already signed for ROCA1'; end if;
  if a.client_signer_email is null or lower(a.client_signer_email) <> lower(auth.email()) then
    raise exception 'Only % (%) can sign for ROCA1', a.client_signer_name, a.client_signer_title;
  end if;
  if lower(trim(coalesce(p_name, ''))) <> lower(a.client_signer_name) then raise exception 'Type your full name exactly as shown: %', a.client_signer_name; end if;
  update snow_agreements set client_signed_name = a.client_signer_name, client_signed_at = now(), client_signed_by = lower(auth.email()) where id = p_id;
  perform snow_finish_signing(p_id);
end;
$$;
revoke all on function snow_staff_client_sign(uuid, text) from public, anon;
grant execute on function snow_staff_client_sign(uuid, text) to authenticated;

create or replace function snow_staff_overview()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  perform snow_require_staff();
  return jsonb_build_object(
    'vendors', coalesce((select jsonb_agg(jsonb_build_object('id', v.id, 'name', v.name) order by v.name) from vendors v where v.portal_access), '[]'::jsonb),
    'me', lower(auth.email()),
    'agreements', coalesce((select jsonb_agg(jsonb_build_object(
        'id', a.id, 'vendor', v.name, 'season', a.season, 'rate', a.rate_per_push, 'status', a.status, 'terms', a.terms,
        'vendor_signed_name', a.vendor_signed_name, 'vendor_signed_at', a.vendor_signed_at,
        'client_signer_name', a.client_signer_name, 'client_signer_title', a.client_signer_title,
        'client_signed_name', a.client_signed_name, 'client_signed_at', a.client_signed_at,
        'can_sign', a.client_signed_at is null and lower(coalesce(a.client_signer_email, '')) = lower(auth.email()))
        order by a.created_at desc) from snow_agreements a join vendors v on v.id = a.vendor_id), '[]'::jsonb),
    'visits', coalesce((select jsonb_agg(jsonb_build_object(
        'id', s.id, 'vendor', v.name, 'kind', s.kind, 'status', s.status, 'description', s.description, 'created_at', s.created_at,
        'notice_sent_at', s.notice_sent_at, 'notice_count', s.notice_count, 'window_start', s.window_start, 'window_end', s.window_end, 'completed_at', s.completed_at, 'vendor_note', s.vendor_note,
        'before_photos', s.before_photos, 'after_photos', s.after_photos, 'amount', s.amount, 'office_note', s.office_note,
        'paid_on', s.paid_on, 'paid_ref', s.paid_ref, 'rate', a.rate_per_push) order by s.created_at desc)
      from snow_visits s join vendors v on v.id = s.vendor_id join snow_agreements a on a.id = s.agreement_id), '[]'::jsonb),
    'owed', coalesce((select sum(amount) from snow_visits where status = 'approved'), 0),
    'paid_total', coalesce((select sum(amount) from snow_visits where status = 'paid'), 0));
end;
$$;
revoke all on function snow_staff_overview() from public, anon;
grant execute on function snow_staff_overview() to authenticated;

-- Office decision on a visit. p_action: approve | return (send back to the vendor) | junk_ok | junk_no
create or replace function snow_staff_review(p_id uuid, p_action text, p_amount numeric, p_note text)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare s snow_visits; a snow_agreements; v vendors; amt numeric; note text := nullif(trim(coalesce(p_note, '')), '');
begin
  perform snow_require_staff();
  select * into s from snow_visits where id = p_id for update;
  if s.id is null then raise exception 'Visit not found'; end if;
  select * into a from snow_agreements where id = s.agreement_id;
  select * into v from vendors where id = s.vendor_id;
  if p_action = 'approve' then
    if s.status <> 'done' then raise exception 'Only a finished visit can be approved'; end if;
    amt := coalesce(p_amount, s.amount, case when s.kind = 'snow' then a.rate_per_push end);
    if amt is null or amt <= 0 then raise exception 'Enter the amount'; end if;
    update snow_visits set status = 'approved', amount = amt, office_note = note, reviewed_at = now(), reviewed_by = lower(auth.email()) where id = p_id;
  elsif p_action = 'return' then
    if s.status <> 'done' then raise exception 'Only a finished visit can be sent back'; end if;
    if note is null then raise exception 'Say what is needed'; end if;
    update snow_visits set status = 'returned', office_note = note, reviewed_at = now(), reviewed_by = lower(auth.email()) where id = p_id;
    if v.email is not null then
      insert into email_outbox (to_email, subject, html, kind) select l, 'Snow visit sent back for more information',
        tenant_email_wrap(split_part(coalesce(v.contact_name, v.name), ' ', 1), '<p>The office needs more on your visit: ' || repair_esc(note) || '</p><p>Update it at <a href="https://2ndchinc.org/contractor/">https://2ndchinc.org/contractor/</a>.</p>'), 'snow_visit_returned' from snow_vendor_logins(v) l;
    end if;
  elsif p_action = 'junk_ok' then
    if s.kind <> 'junk' or s.status <> 'proposed' then raise exception 'That is not a junk proposal waiting for approval'; end if;
    if p_amount is null or p_amount <= 0 then raise exception 'Enter the approved price'; end if;
    update snow_visits set status = 'junk_approved', amount = p_amount, office_note = note, reviewed_at = now(), reviewed_by = lower(auth.email()) where id = p_id;
    if v.email is not null then
      insert into email_outbox (to_email, subject, html, kind) select l, 'Junk removal approved',
        tenant_email_wrap(split_part(coalesce(v.contact_name, v.name), ' ', 1), '<p>The office approved your junk removal at the approved price of $' || to_char(p_amount, 'FM999990.00') || '.' || coalesce(' Note: ' || repair_esc(note), '') || ' When it is done, finish it at <a href="https://2ndchinc.org/contractor/">https://2ndchinc.org/contractor/</a> with after photos.</p>'), 'snow_junk_approved' from snow_vendor_logins(v) l;
    end if;
  elsif p_action = 'junk_no' then
    if s.kind <> 'junk' or s.status <> 'proposed' then raise exception 'That is not a junk proposal waiting for approval'; end if;
    update snow_visits set status = 'declined', office_note = note, reviewed_at = now(), reviewed_by = lower(auth.email()) where id = p_id;
    if v.email is not null then
      insert into email_outbox (to_email, subject, html, kind) select l, 'Junk removal not approved',
        tenant_email_wrap(split_part(coalesce(v.contact_name, v.name), ' ', 1), '<p>The office did not approve that junk removal.' || coalesce(' Note: ' || repair_esc(note), '') || '</p>'), 'snow_junk_declined' from snow_vendor_logins(v) l;
    end if;
  else
    raise exception 'Unknown action';
  end if;
end;
$$;
revoke all on function snow_staff_review(uuid, text, numeric, text) from public, anon;
grant execute on function snow_staff_review(uuid, text, numeric, text) to authenticated;

-- ROCA1 pays by Zelle: record it here. Returns the total recorded.
create or replace function snow_staff_mark_paid(p_ids uuid[], p_paid_on date, p_ref text)
returns numeric
language plpgsql volatile security definer set search_path = public as $$
declare tot numeric; vid uuid; v vendors; n integer;
begin
  perform snow_require_staff();
  if p_ids is null or cardinality(p_ids) = 0 then raise exception 'Choose at least one approved visit'; end if;
  if p_paid_on is null or p_paid_on > (now() at time zone 'America/Chicago')::date then raise exception 'Enter the date the Zelle was sent'; end if;
  if (select count(distinct vendor_id) from snow_visits where id = any (p_ids)) <> 1 then raise exception 'Pay one vendor at a time'; end if;
  select count(*), coalesce(sum(amount), 0), min(vendor_id::text)::uuid into n, tot, vid from snow_visits where id = any (p_ids) and status = 'approved';
  if n <> cardinality(p_ids) then raise exception 'Only approved, unpaid visits can be marked paid'; end if;
  update snow_visits set status = 'paid', paid_on = p_paid_on, paid_ref = nullif(trim(coalesce(p_ref, '')), ''), paid_method = 'Zelle' where id = any (p_ids);
  select * into v from vendors where id = vid;
  if v.email is not null then
    insert into email_outbox (to_email, subject, html, kind) select l, 'Payment sent for snow removal',
      tenant_email_wrap(split_part(coalesce(v.contact_name, v.name), ' ', 1), '<p>ROCA1 sent $' || to_char(tot, 'FM999990.00') || ' by Zelle on ' || to_char(p_paid_on, 'FMMM/FMDD/YYYY') || ' for ' || n || ' visit' || case when n = 1 then '' else 's' end || '.' || coalesce(' Reference: ' || repair_esc(nullif(trim(p_ref), '')), '') || '</p>'), 'snow_paid' from snow_vendor_logins(v) l;
  end if;
  return tot;
end;
$$;
revoke all on function snow_staff_mark_paid(uuid[], date, text) from public, anon;
grant execute on function snow_staff_mark_paid(uuid[], date, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Vendor

create or replace function snow_vendor_overview()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare a snow_agreements;
begin
  perform snow_require_vendor();
  a := snow_my_agreement();
  if a.id is null then return jsonb_build_object('agreement', null); end if;
  return jsonb_build_object(
    'agreement', jsonb_build_object('id', a.id, 'season', a.season, 'rate', a.rate_per_push, 'status', a.status, 'terms', a.terms,
      'client_signer_name', a.client_signer_name, 'client_signer_title', a.client_signer_title,
      'vendor_signed_name', a.vendor_signed_name, 'vendor_signed_at', a.vendor_signed_at, 'client_signed_name', a.client_signed_name, 'client_signed_at', a.client_signed_at,
      'can_sign', a.vendor_signed_at is null and lower(coalesce((select email from vendors where id = a.vendor_id), '')) = lower(auth.email()),
      'signer_name', (select coalesce(contact_name, name) from vendors where id = a.vendor_id)),
    'visits', coalesce((select jsonb_agg(jsonb_build_object(
        'id', s.id, 'kind', s.kind, 'status', s.status, 'description', s.description, 'created_at', s.created_at, 'notice_sent_at', s.notice_sent_at,
        'notice_count', s.notice_count, 'window_start', s.window_start, 'window_end', s.window_end, 'completed_at', s.completed_at, 'vendor_note', s.vendor_note, 'before_photos', s.before_photos, 'after_photos', s.after_photos,
        'amount', s.amount, 'office_note', s.office_note, 'paid_on', s.paid_on) order by s.created_at desc)
      from (select * from snow_visits where vendor_id = a.vendor_id order by created_at desc limit 60) s), '[]'::jsonb),
    'owed', coalesce((select sum(amount) from snow_visits where vendor_id = a.vendor_id and status = 'approved'), 0),
    'pending', coalesce((select sum(coalesce(amount, a.rate_per_push)) from snow_visits where vendor_id = a.vendor_id and status = 'done'), 0),
    'paid_total', coalesce((select sum(amount) from snow_visits where vendor_id = a.vendor_id and status = 'paid'), 0));
end;
$$;
revoke all on function snow_vendor_overview() from public, anon;
grant execute on function snow_vendor_overview() to authenticated;

create or replace function snow_vendor_sign(p_name text)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare a snow_agreements; v vendors;
begin
  perform snow_require_vendor();
  a := snow_my_agreement();
  if a.id is null then raise exception 'No agreement has been prepared for you yet'; end if;
  if a.vendor_signed_at is not null then raise exception 'You already signed'; end if;
  select * into v from vendors where id = a.vendor_id;
  if lower(coalesce(v.email, '')) <> lower(auth.email()) then raise exception 'Only % can sign for the vendor. Office staff cannot sign for anyone.', coalesce(v.contact_name, v.name); end if;
  if v.contact_name is not null and lower(trim(p_name)) <> lower(trim(v.contact_name)) then raise exception 'Type your full name exactly as shown: %', v.contact_name; end if;
  if length(trim(coalesce(p_name, ''))) < 4 then raise exception 'Type your full name to sign'; end if;
  update snow_agreements set vendor_signed_name = trim(p_name), vendor_signed_at = now(), vendor_signed_by = lower(auth.email()) where id = a.id;
  perform snow_finish_signing(a.id);
end;
$$;
revoke all on function snow_vendor_sign(text) from public, anon;
grant execute on function snow_vendor_sign(text) to authenticated;

-- The button. p_notify = true emails the households whose stalls (stall number = unit number) are listed in p_units (null = all of
-- them) that the stall must be vacated between p_from and p_to; false just logs a push. The vendor's schedule is erratic, so the
-- window is typed each time. Two notices for the same window cannot go out within 30 minutes (double click) and no more than 6 a day.
create or replace function snow_vendor_new_visit(p_notify boolean, p_from timestamptz, p_to timestamptz, p_units text[])
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare a snow_agreements; vid uuid; r record; n integer := 0; allunits text[] := '{}'; win text; nowct timestamp := now() at time zone 'America/Chicago'; last_at timestamptz;
begin
  perform snow_require_vendor();
  a := snow_my_agreement();
  if a.id is null or a.status <> 'active' then raise exception 'The agreement must be signed by both parties first'; end if;
  if p_notify then
    if p_from is null or p_to is null or p_to <= p_from then raise exception 'Choose when the stalls must be empty: a start time and a later end time'; end if;
    if p_from < now() - interval '1 hour' then raise exception 'The start time is in the past'; end if;
    if p_from > now() + interval '7 days' or p_to - p_from > interval '24 hours' then raise exception 'The window must start within 7 days and last no more than 24 hours'; end if;
    select max(notice_sent_at) into last_at from snow_visits where vendor_id = a.vendor_id and notice_sent_at is not null;
    if last_at is not null and last_at > now() - interval '30 minutes' then
      raise exception 'A notice was just sent at %. Wait 30 minutes before sending another.', to_char(last_at at time zone 'America/Chicago', 'FMHH12:MI AM');
    end if;
    if (select count(*) from snow_visits where vendor_id = a.vendor_id and notice_sent_at > now() - interval '24 hours') >= 6 then
      raise exception 'Six notices have already gone out in the last 24 hours. Call the office if you need another.';
    end if;
  end if;
  insert into snow_visits (agreement_id, vendor_id, kind, status, started_at, window_start, window_end)
  values (a.id, a.vendor_id, 'snow', 'notified', now(), case when p_notify then p_from end, case when p_notify then p_to end) returning id into vid;
  if p_notify then
    win := case when (p_from at time zone 'America/Chicago')::date = (p_to at time zone 'America/Chicago')::date
                then to_char(p_from at time zone 'America/Chicago', 'FMHH12:MI AM') || ' and ' || to_char(p_to at time zone 'America/Chicago', 'FMHH12:MI AM') || ' on ' || to_char(p_from at time zone 'America/Chicago', 'FMDay, FMMonth FMDD')
                else to_char(p_from at time zone 'America/Chicago', 'FMDay FMMonth FMDD, FMHH12:MI AM') || ' and ' || to_char(p_to at time zone 'America/Chicago', 'FMDay FMMonth FMDD, FMHH12:MI AM') end;
    for r in select * from snow_recipients() sr where p_units is null or sr.units && p_units loop
      insert into email_outbox (to_email, subject, html, kind) values (r.email, 'Please keep your parking stall empty: snow removal ' || to_char(p_from at time zone 'America/Chicago', 'FMMon FMDD'),
        tenant_email_wrap(r.first_name,
          '<p>Snow removal is scheduled at 6622 and 6626 N Bourbon St. <b>Your parking stall (and any vehicle of yours in the lot) must be vacated between ' || win || '</b> so the plow can clear the whole lot.</p>'
          || '<p>Vehicles still in the lot during that time may be removed by the association''s towing provider at the vehicle owner''s expense. Please move yours to a legal place on the street, following the city''s winter parking rules, and bring it back once the lot is cleared.</p>'
          || '<p>The snow removal crew''s timing can change with the weather, so you may get another email if the schedule moves. Thank you for helping us keep the lot clear and safe.</p>'),
        'snow_move_notice');
      n := n + 1; allunits := allunits || r.units;
    end loop;
    if n = 0 then raise exception 'No households matched the stalls you chose'; end if;
    update snow_visits set notice_sent_at = now(), notice_count = n, notice_units = (select array_agg(distinct x order by x) from unnest(allunits) x) where id = vid;
    perform snow_office_mail('Snow removal notice sent to ' || n || ' households',
      '<p>' || (select name from vendors where id = a.vendor_id) || ' sent the move-your-vehicle email at ' || to_char(nowct, 'FMHH12:MI AM') || ' for ' || win || '. ' || n || ' households were emailed (tenants of rented units, owners of owner-occupied units and Unit 6). Review at <a href="https://2ndchinc.org/staff/snow/">https://2ndchinc.org/staff/snow/</a>.</p>', 'snow_notice_office');
  end if;
  return jsonb_build_object('visit', vid, 'emailed', n);
end;
$$;
revoke all on function snow_vendor_new_visit(boolean, timestamptz, timestamptz, text[]) from public, anon;
grant execute on function snow_vendor_new_visit(boolean, timestamptz, timestamptz, text[]) to authenticated;

-- Stall (unit) numbers the vendor can pick from: every occupied unit.
create or replace function snow_vendor_stalls()
returns text[]
language plpgsql stable security definer set search_path = public as $$
begin
  perform snow_require_vendor();
  return (select array_agg(unit_number order by length(unit_number), unit_number) from condo_units where occupancy <> 'vacant');
end;
$$;
revoke all on function snow_vendor_stalls() from public, anon;
grant execute on function snow_vendor_stalls() to authenticated;

create or replace function snow_vendor_junk_propose(p_id uuid, p_description text, p_photos text[])
returns uuid
language plpgsql volatile security definer set search_path = public as $$
declare a snow_agreements; vid uuid := p_id;
begin
  perform snow_require_vendor();
  a := snow_my_agreement();
  if a.id is null or a.status <> 'active' then raise exception 'The agreement must be signed by both parties first'; end if;
  if length(trim(coalesce(p_description, ''))) < 5 then raise exception 'Describe what you found and where'; end if;
  if coalesce(cardinality(p_photos), 0) = 0 then raise exception 'Add at least one photo'; end if;
  if exists (select 1 from unnest(p_photos) p where p not like vid::text || '/%') then raise exception 'Photo path is wrong'; end if;
  insert into snow_visits (id, agreement_id, vendor_id, kind, status, description, before_photos) values (vid, a.id, a.vendor_id, 'junk', 'proposed', trim(p_description), p_photos);
  perform snow_office_mail('Junk removal proposal waiting for your approval',
    '<p>' || repair_esc(trim(p_description)) || '</p><p>Photos and the decision: <a href="https://2ndchinc.org/staff/snow/">https://2ndchinc.org/staff/snow/</a></p>', 'snow_junk_proposed');
  return vid;
end;
$$;
revoke all on function snow_vendor_junk_propose(uuid, text, text[]) from public, anon;
grant execute on function snow_vendor_junk_propose(uuid, text, text[]) to authenticated;

-- Finish a visit (snow or approved junk) with photos. Before photos are required for snow; junk keeps its proposal photos.
create or replace function snow_vendor_finish(p_id uuid, p_note text, p_before text[], p_after text[])
returns void
language plpgsql volatile security definer set search_path = public as $$
declare s snow_visits; b text[]; v vendors;
begin
  perform snow_require_vendor();
  select * into s from snow_visits where id = p_id and vendor_id in (select contractor_me()) for update;
  if s.id is null then raise exception 'That visit is not yours'; end if;
  if s.status not in ('notified', 'junk_approved', 'returned') then raise exception 'This visit cannot be finished from its current state'; end if;
  b := case when s.kind = 'junk' then s.before_photos else coalesce(p_before, '{}') end;
  if coalesce(cardinality(b), 0) = 0 then raise exception 'Add at least one before photo'; end if;
  if coalesce(cardinality(p_after), 0) = 0 then raise exception 'Add at least one after photo'; end if;
  if exists (select 1 from unnest(coalesce(p_before, '{}') || p_after) p where p not like p_id::text || '/%') then raise exception 'Photo path is wrong'; end if;
  update snow_visits set status = 'done', completed_at = now(), before_photos = b, after_photos = p_after, vendor_note = nullif(trim(coalesce(p_note, '')), '') where id = p_id;
  select * into v from vendors where id = s.vendor_id;
  perform snow_office_mail('Snow removal visit finished: ready for review',
    '<p>' || repair_esc(v.name) || ' finished a ' || case s.kind when 'junk' then 'junk removal' else 'snow' end || ' visit. Photos and approval: <a href="https://2ndchinc.org/staff/snow/">https://2ndchinc.org/staff/snow/</a></p>', 'snow_visit_done');
end;
$$;
revoke all on function snow_vendor_finish(uuid, text, text[], text[]) from public, anon;
grant execute on function snow_vendor_finish(uuid, text, text[], text[]) to authenticated;
