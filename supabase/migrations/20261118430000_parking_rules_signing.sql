-- Parking rules and fines: initial each one and record a spoken statement (Stephen, 11/8/2026).
--   * The rules and the fines live in parking_terms (one plain sentence each). Their text makes a version (md5); when the office changes a
--     rule or a fine, everyone is asked to sign again.
--   * Everyone who parks here signs for their stall: tenants on an active lease, owner-occupants, owners of a vacant unit, and Unit 6's
--     parking-and-keys person (vehicle_reg_units). Each person signs (two tenants = two signatures).
--   * Signing = click to initial every rule and every fine, then record yourself saying the statement (audio, 3 to 90 seconds, private
--     bucket parking-acks, folder = the person's auth id). parking_ack_submit() checks every item was initialed and the recording exists,
--     stores what they saw (item text and amount at that moment), and emails them a copy for their records.
--   * The signed copy stays on the portal ("View my signed copy", with the recording). Staff see who signed on https://2ndchinc.org/parking/
--     (Unit 6's person is shown only as "Unit 6 occupant", CLAUDE.md).
-- New tables: explicit grants (Supabase change of 10/30/2026).

create table if not exists parking_terms (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in ('rule', 'fine')),
  position int not null,
  text text not null,
  amount text,                       -- fines: "$35 each time, and towing"
  active boolean not null default true,
  updated_at timestamptz not null default now()
);
alter table parking_terms enable row level security;
revoke all on parking_terms from public, anon, authenticated;
grant all on parking_terms to service_role;

create table if not exists parking_acks (
  id uuid primary key default gen_random_uuid(),
  email text not null,
  person_kind text not null check (person_kind in ('tenant', 'owner', 'occupant')),
  person_name text,
  unit_number text not null,
  terms_version text not null,
  items jsonb not null,              -- [{kind, position, text, amount, initials, at}] exactly as shown and initialed
  initials text not null,
  statement text not null,
  audio_path text not null,
  audio_seconds numeric,
  user_agent text,
  signed_at timestamptz not null default now()
);
create index if not exists parking_acks_email on parking_acks (lower(email), unit_number, signed_at desc);
alter table parking_acks enable row level security;
revoke all on parking_acks from public, anon, authenticated;
grant all on parking_acks to service_role;

insert into parking_terms (kind, position, text, amount)
select * from (values
  ('rule', 1,  'Park only in the stall with your unit number.', null),
  ('rule', 2,  'Park in another unit''s stall only with a switch that unit accepted on the map.', null),
  ('rule', 3,  'Register every vehicle that parks in your stall.', null),
  ('rule', 4,  'Hang your parking hanger on the rear-view mirror (hangers coming soon).', null),
  ('rule', 5,  'Unregistered vehicles and vehicles in the wrong stall are towed at the vehicle owner''s expense.', null),
  ('rule', 6,  'Guests park only in your stall, with a guest parking pass or registered as a regular visitor.', null),
  ('rule', 7,  'Do not stop or stand in the fire lane for more than 3 minutes.', null),
  ('rule', 8,  'Do not block the dumpster.', null),
  ('rule', 9,  'After 2 inches of snow or more, move your vehicle out of the lot by 7:30 a.m. Return after plowing.', null),
  ('rule', 10, 'Move your vehicle at least once every 7 days.', null),
  ('rule', 11, 'Only working, licensed and registered cars, vans, motorcycles and light trucks may park. No trailers, boats or RVs.', null),
  ('rule', 12, 'Vehicles with expired registration, flat tires or leaks are towed.', null),
  ('rule', 13, 'Park inside the yellow lines. Do not block the sidewalk.', null),
  ('rule', 14, 'Put a board under a motorcycle kickstand.', null),
  ('rule', 15, 'No repairs, oil changes or car washing.', null),
  ('rule', 16, 'Keep your stall free of oil and trash.', null),
  ('rule', 17, 'No drinking, cooking, sleeping or hanging out in vehicles or in the lot.', null),
  ('rule', 18, 'Commercial vehicles may park only while working here.', null),
  ('rule', 19, 'Speed limit: 10 mph.', null),
  ('rule', 20, 'If your account has an unpaid balance, your parking is revoked and your vehicle is towed.', null),
  ('rule', 21, 'If a vehicle is in your stall, tap your stall on the map and press "Someone in my stall?".', null),
  ('fine', 1,  'Vehicle not registered', '$50 each time, and towing'),
  ('fine', 2,  'Parking in another unit''s stall', '$35 each time, and towing'),
  ('fine', 3,  'Parking in the fire lane', '$55 each time, and towing'),
  ('fine', 4,  'Vehicle not moved for snow removal', '$105 each time, and towing'),
  ('fine', 5,  'Snow not cleared from your stall after plowing', '$35 each time'),
  ('fine', 6,  'Vehicle not moved in 7 days', '$35 per week, and towing'),
  ('fine', 7,  'Guest without a pass, or in another unit''s stall', '$25 each time'),
  ('fine', 8,  'Repairs, oil changes or car washing', '$35 each time'),
  ('fine', 9,  'Trailer, boat, RV or other vehicle not allowed', '$5 per day, up to $100 per month'),
  ('fine', 10, 'Commercial vehicle', '$2.50 per day, up to $50 per month'),
  ('fine', 11, 'Vehicle over the yellow lines', '$5.50 each time'),
  ('fine', 12, 'Trash in your stall', '$5 each time'),
  ('fine', 13, 'Expired registration, flat tires or leaks', 'Towing'),
  ('fine', 14, 'Vehicle in the stall while parking is revoked for an unpaid balance', 'Towing')
) v(kind, position, text, amount)
where not exists (select 1 from parking_terms);

insert into portal_settings (key, value) values
  ('parking_ack_statement', 'I have read and understood each of the parking rules and each violation and fine amount, and I agree to comply.')
on conflict (key) do nothing;

-- Storage: the recording. Path = <auth uid>/<ack id>.<ext>. The person uploads and plays their own; staff play all.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('parking-acks', 'parking-acks', false, 5242880, array['audio/webm', 'audio/mp4', 'audio/ogg', 'audio/mpeg', 'audio/aac', 'audio/x-m4a', 'audio/wav', 'audio/x-wav', 'audio/3gpp'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;
drop policy if exists "parking acks upload own" on storage.objects;
create policy "parking acks upload own" on storage.objects for insert to authenticated
  with check (bucket_id = 'parking-acks' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists "parking acks read own or staff" on storage.objects;
create policy "parking acks read own or staff" on storage.objects for select to authenticated
  using (bucket_id = 'parking-acks' and ((storage.foldername(name))[1] = auth.uid()::text or condo_is_staff()));

-- ---------------------------------------------------------------------------
create or replace function parking_terms_version()
returns text
language sql stable security definer set search_path = public as $$
  select md5(coalesce(string_agg(kind || '|' || position || '|' || text || '|' || coalesce(amount, ''), '#' order by kind, position), ''))
    from parking_terms where active;
$$;
revoke all on function parking_terms_version() from public, anon, authenticated;

create or replace function parking_terms_list()
returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'kind', kind, 'position', position, 'text', text, 'amount', amount) order by kind desc, position), '[]'::jsonb)
    from parking_terms where active;
$$;
revoke all on function parking_terms_list() from public, anon, authenticated;

-- The signed-in person: kind and name (never shown to staff for an occupant).
create or replace function parking_ack_person()
returns table (kind text, name text)
language sql stable security definer set search_path = public as $$
  select x.kind, x.name from (
    select 'tenant' as kind, t.name, 1 as o from tenants t where t.id in (select resident_me())
    union all select 'owner', o.name, 2 from condo_owners o where o.id = condo_owner_for_email(auth.email())
    union all select 'occupant', u.name, 3 from unit_occupants u where u.active and lower(u.email) = lower(auth.email())) x
  order by x.o limit 1;
$$;
revoke all on function parking_ack_person() from public, anon, authenticated;

create or replace function parking_ack_row(a parking_acks)
returns jsonb
language sql stable as $$
  select jsonb_build_object('id', a.id, 'unit', a.unit_number, 'name', a.person_name, 'initials', a.initials, 'items', a.items, 'statement', a.statement,
    'audio_path', a.audio_path, 'audio_seconds', a.audio_seconds, 'signed_at', a.signed_at, 'version', a.terms_version);
$$;
revoke all on function parking_ack_row(parking_acks) from public, anon, authenticated;

-- What the Parking tab needs: the rules and fines, the statement, my name, and per unit my latest signature (current or out of date).
create or replace function parking_terms_mine()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_ver text := parking_terms_version(); p record;
begin
  if not vehicle_can_view() then raise exception 'Resident or owner sign-in required' using errcode = '42501'; end if;
  select * into p from parking_ack_person();
  return jsonb_build_object('version', v_ver, 'terms', parking_terms_list(), 'statement', condo_setting('parking_ack_statement', ''),
    'name', p.name, 'uid', auth.uid(),
    'units', coalesce((select jsonb_agg(jsonb_build_object('unit', r.unit_number,
        'ack', (select parking_ack_row(a) || jsonb_build_object('current', a.terms_version = v_ver) from parking_acks a
                 where lower(a.email) = lower(auth.email()) and a.unit_number = r.unit_number order by a.signed_at desc limit 1))
      order by nullif(regexp_replace(r.unit_number, '\D', '', 'g'), '')::int) from vehicle_reg_units() r), '[]'::jsonb));
end;
$$;
revoke all on function parking_terms_mine() from public, anon;
grant execute on function parking_terms_mine() to authenticated;

-- Sign: p_items = [{id, at}] for every active rule and fine. Emails a copy.
create or replace function parking_ack_submit(p_unit text, p_initials text, p_items jsonb, p_audio_path text, p_audio_seconds numeric, p_user_agent text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  v_ver text := parking_terms_version(); p record; v_id uuid := gen_random_uuid(); v_items jsonb; v_missing int; a parking_acks;
  v_ini text := upper(regexp_replace(coalesce(p_initials, ''), '[^A-Za-z.\- ]', '', 'g')); v_html text; v_link text; v_when text;
begin
  if autopay_view_as_session() then raise exception 'Not available while viewing as someone else.'; end if;
  if not exists (select 1 from vehicle_reg_units() where unit_number = p_unit) then
    raise exception 'You can sign only for your own unit''s stall.' using errcode = '42501'; end if;
  select * into p from parking_ack_person();
  if p.kind is null then raise exception 'Sign-in required' using errcode = '42501'; end if;
  if length(trim(v_ini)) < 2 or length(v_ini) > 6 then raise exception 'Enter your initials (2 to 6 letters).'; end if;
  select count(*) into v_missing from parking_terms t where t.active
    and not exists (select 1 from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) e where (e ->> 'id')::uuid = t.id);
  if v_missing > 0 then raise exception 'Initial every rule and every fine (% left).', v_missing; end if;
  if p_audio_path is null or p_audio_path !~ ('^' || auth.uid()::text || '/[0-9a-f-]{36}\.(webm|mp4|m4a|ogg|aac|mp3|wav|3gp)$') then raise exception 'Record your statement first.'; end if;
  if not exists (select 1 from storage.objects o where o.bucket_id = 'parking-acks' and o.name = p_audio_path) then
    raise exception 'Your recording did not upload. Record it again.'; end if;
  if coalesce(p_audio_seconds, 0) < 3 then raise exception 'The recording is too short. Read the whole statement out loud.'; end if;

  select jsonb_agg(jsonb_build_object('kind', t.kind, 'position', t.position, 'text', t.text, 'amount', t.amount, 'initials', v_ini,
           'at', coalesce((select e ->> 'at' from jsonb_array_elements(p_items) e where (e ->> 'id')::uuid = t.id limit 1), now()::text))
         order by t.kind desc, t.position) into v_items
    from parking_terms t where t.active;

  insert into parking_acks (id, email, person_kind, person_name, unit_number, terms_version, items, initials, statement, audio_path, audio_seconds, user_agent)
  values (v_id, lower(auth.email()), p.kind, p.name, p_unit, v_ver, v_items, v_ini, condo_setting('parking_ack_statement', ''), p_audio_path,
          round(least(p_audio_seconds, 600), 1), left(p_user_agent, 300))
  returning * into a;

  v_link := 'https://2ndchinc.org' || case p.kind when 'tenant' then '/resident/#parking' when 'occupant' then '/unit-access/#parking' else '/association-owners/roca1/#parking' end;
  v_when := to_char(a.signed_at at time zone 'America/Chicago', 'FMMM/FMDD/YYYY FMHH12:MI AM');
  v_html := '<div style="font-family:Arial,sans-serif;max-width:680px;color:#1b2430"><p>Hi ' || repair_esc(split_part(coalesce(p.name, ''), ' ', 1)) || ',</p>'
    || '<p>This is your copy of the parking rules and fines you signed for <b>stall ' || repair_esc(p_unit) || '</b> at 6622-6626 N Bourbon St on <b>' || v_when || '</b> (Central time).</p>'
    || '<h3 style="margin:18px 0 6px">Parking rules</h3><table style="border-collapse:collapse;width:100%">'
    || (select string_agg('<tr><td style="padding:4px 8px;border-bottom:1px solid #dde2e8;vertical-align:top">' || (e ->> 'position') || '.</td><td style="padding:4px 8px;border-bottom:1px solid #dde2e8">'
          || repair_esc(e ->> 'text') || '</td><td style="padding:4px 8px;border-bottom:1px solid #dde2e8;white-space:nowrap;font-weight:bold">' || repair_esc(e ->> 'initials') || '</td></tr>', '' order by (e ->> 'position')::int)
        from jsonb_array_elements(v_items) e where e ->> 'kind' = 'rule')
    || '</table><h3 style="margin:18px 0 6px">Violations and fines</h3><table style="border-collapse:collapse;width:100%">'
    || (select string_agg('<tr><td style="padding:4px 8px;border-bottom:1px solid #dde2e8">' || repair_esc(e ->> 'text') || '</td><td style="padding:4px 8px;border-bottom:1px solid #dde2e8">'
          || repair_esc(coalesce(e ->> 'amount', '')) || '</td><td style="padding:4px 8px;border-bottom:1px solid #dde2e8;white-space:nowrap;font-weight:bold">' || repair_esc(e ->> 'initials') || '</td></tr>', '' order by (e ->> 'position')::int)
        from jsonb_array_elements(v_items) e where e ->> 'kind' = 'fine')
    || '</table><p style="margin-top:16px">You recorded this statement out loud (' || coalesce(a.audio_seconds::text, '') || ' seconds):<br><i>"' || repair_esc(a.statement) || '"</i></p>'
    || '<p>Your signed copy and your recording stay on your portal: <a href="' || v_link || '">' || v_link || '</a> (Parking, "View my signed copy").</p>'
    || '<p>The full Parking Agreement: <a href="https://2ndchinc.org/documents/parking/">https://2ndchinc.org/documents/parking/</a></p>'
    || '<p style="color:#5b6573;font-size:13px">2nd Chance Housing, ' || repair_esc(condo_setting('org_phone', '')) || ', info@2ndchinc.org. Keep this email for your records.</p></div>';
  insert into email_outbox (to_email, subject, html, kind) values (lower(auth.email()), 'Your signed parking rules and fines (stall ' || p_unit || ')', v_html, 'parking_ack');
  return parking_ack_row(a) || jsonb_build_object('current', true);
end;
$$;
revoke all on function parking_ack_submit(text, text, jsonb, text, numeric, text) from public, anon;
grant execute on function parking_ack_submit(text, text, jsonb, text, numeric, text) to authenticated;

-- Staff: who signed, per stall (Unit 6's person only as "Unit 6 occupant").
create or replace function parking_acks_staff()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_ver text := parking_terms_version();
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object('version', v_ver,
    'acks', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'unit', a.unit_number, 'kind', a.person_kind,
        'name', case when a.person_kind = 'occupant' then 'Unit ' || a.unit_number || ' occupant' else a.person_name end,
        'signed_at', a.signed_at, 'current', a.terms_version = v_ver, 'audio_path', a.audio_path, 'audio_seconds', a.audio_seconds, 'initials', a.initials)
        order by nullif(regexp_replace(a.unit_number, '\D', '', 'g'), '')::int, a.signed_at desc)
      from (select distinct on (lower(email), unit_number) * from parking_acks order by lower(email), unit_number, signed_at desc) a), '[]'::jsonb),
    'stalls_unsigned', coalesce((select jsonb_agg(s.home_unit order by nullif(regexp_replace(s.home_unit, '\D', '', 'g'), '')::int) from parking_stalls s
        where s.kind = 'unit' and s.active and not exists (select 1 from parking_acks a where a.unit_number = s.home_unit and a.terms_version = v_ver)), '[]'::jsonb));
end;
$$;
revoke all on function parking_acks_staff() from public, anon;
grant execute on function parking_acks_staff() to authenticated;
