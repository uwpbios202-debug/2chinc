-- Parking, four more pieces (Stephen, 11/8/2026):
--   1. Photos on "Someone in my stall?" (ROCA1 Rules, Parking #18: front and rear with the plate, the VIN if visible, the stall). The reporter
--      adds up to 6 photos to their open alert (private bucket parking-alerts, folder = the alert id). Staff see them on the alerts list, and
--      Always Towing sees open tow requests with their photos on its private page.
--   2. Staff print a signed parking-rules copy (parking_ack_staff_get; Unit 6's person shown only as "Unit 6 occupant").
--   3. Always Towing marks a tow on its page (tow-view edge function -> tow_record): the tow is logged in parking_tows, a matching alert is
--      closed, the office is emailed. When the plate matches a vehicle registered to another unit, staff can start that unit's $35
--      "Parking in another unit's stall" violation with one button (roca_violation_create; the normal notice and 14-day hearing steps follow).
--   4. Stock-take for the office: per stall, who lives there, vehicle registered or "no vehicle", hangers, signatures (parking_stocktake_staff).
-- New table parking_tows: explicit grants (Supabase change of 10/30/2026).

-- ---------------------------------------------------------------------------
-- 1. Alert photos
alter table parking_alerts add column if not exists photos text[] not null default '{}';

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('parking-alerts', 'parking-alerts', false, 8388608, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;
drop policy if exists "parking alert photos upload reporter" on storage.objects;
create policy "parking alert photos upload reporter" on storage.objects for insert to authenticated
  with check (bucket_id = 'parking-alerts' and exists (select 1 from parking_alerts a where a.id::text = (storage.foldername(name))[1]
                and a.reporter_email = lower(auth.email()) and a.status in ('open', 'tow_requested')));
drop policy if exists "parking alert photos read reporter or staff" on storage.objects;
create policy "parking alert photos read reporter or staff" on storage.objects for select to authenticated
  using (bucket_id = 'parking-alerts' and (condo_is_staff() or exists (select 1 from parking_alerts a where a.id::text = (storage.foldername(name))[1]
                and a.reporter_email = lower(auth.email()))));

create or replace function parking_alert_add_photos(p_id uuid, p_paths text[])
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare a parking_alerts; p text;
begin
  if autopay_view_as_session() then raise exception 'Not available while viewing as someone else.'; end if;
  select * into a from parking_alerts where id = p_id for update;
  if a.id is null or a.reporter_email <> lower(auth.email()) then raise exception 'Alert not found.' using errcode = '42501'; end if;
  if a.status not in ('open', 'tow_requested') then raise exception 'This alert is closed.'; end if;
  foreach p in array coalesce(p_paths, '{}') loop
    if p !~ ('^' || a.id::text || '/[0-9a-f-]{36}\.jpg$') then raise exception 'Bad photo'; end if;
    if not exists (select 1 from storage.objects o where o.bucket_id = 'parking-alerts' and o.name = p) then raise exception 'A photo did not upload. Try again.'; end if;
  end loop;
  if cardinality(a.photos) + cardinality(coalesce(p_paths, '{}')) > 6 then raise exception 'Up to 6 photos per alert.'; end if;
  update parking_alerts set photos = photos || coalesce(p_paths, '{}') where id = a.id returning * into a;
  return parking_alert_row(a);
end;
$$;
revoke all on function parking_alert_add_photos(uuid, text[]) from public, anon;
grant execute on function parking_alert_add_photos(uuid, text[]) to authenticated;

-- The resident's alert card shows how many photos it has.
create or replace function parking_alert_row(a parking_alerts)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', a.id, 'stall', a.stall_label, 'unit', a.unit_number, 'vehicle', a.vehicle, 'plate', a.plate, 'plate_state', a.plate_state,
    'note', a.note, 'status', a.status, 'alerted_at', a.alerted_at, 'tow_unlock_at', a.tow_unlock_at, 'tow_requested_at', a.tow_requested_at,
    'resolved_at', a.resolved_at, 'recipients', a.recipients, 'now', now(), 'photo_count', cardinality(a.photos));
$$;
revoke all on function parking_alert_row(parking_alerts) from public, anon, authenticated;

-- Unit 6's parking-and-keys person is shown only as "Unit 6 occupant" (CLAUDE.md), never by email.
create or replace function parking_alerts_staff()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(parking_alert_row(a) || jsonb_build_object('reporter', case when exists (select 1 from unit_occupants o where lower(o.email) = a.reporter_email) then 'Unit ' || a.unit_number || ' occupant' else a.reporter_email end, 'matched_unit', a.matched_unit, 'resolved_note', a.resolved_note, 'photos', a.photos)
    order by a.alerted_at desc) from parking_alerts a where a.alerted_at > now() - interval '60 days'), '[]'::jsonb);
end;
$$;
revoke all on function parking_alerts_staff() from public, anon;
grant execute on function parking_alerts_staff() to authenticated;

-- The tow request email says where the photos are.
do $$ declare v text := pg_get_functiondef('parking_alert_tow(uuid)'::regprocedure); n text; begin
  n := replace(v, '|| ''<p>Property manager: 2nd Chance Housing',
    '|| case when cardinality(a.photos) > 0 then ''<p>Photos (''  || cardinality(a.photos) || ''): on your private vehicle page, under Tow requests.</p>'' else ''<p>Open tow requests are also on your private vehicle page.</p>'' end
    || ''<p>Property manager: 2nd Chance Housing');
  if n = v then raise exception 'parking_alert_tow changed; update this migration'; end if;
  execute n;
end $$;

-- ---------------------------------------------------------------------------
-- 3. Tows reported by Always Towing
create table if not exists parking_tows (
  id uuid primary key default gen_random_uuid(),
  alert_id uuid references parking_alerts(id),
  stall_label text not null,
  plate text,
  plate_state text,
  vehicle text,
  note text,
  matched_unit text,                 -- the plate is registered to this unit (it was in another unit's stall)
  stall_unit text,                   -- the unit using the stall that day
  towed_at timestamptz not null default now(),
  violation_id bigint,
  dismissed_at timestamptz,
  staff_note text
);
alter table parking_tows enable row level security;
revoke all on parking_tows from public, anon, authenticated;
grant all on parking_tows to service_role;

-- Called only by the tow-view edge function (service role) after it checks the private link.
create or replace function tow_record(p_alert uuid, p_stall text, p_plate text, p_state text, p_vehicle text, p_note text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare a parking_alerts; t parking_tows; v_plate text := upper(regexp_replace(coalesce(p_plate, ''), '[^A-Za-z0-9]', '', 'g'));
  v_stall text := trim(coalesce(p_stall, '')); s jsonb; v_match text;
begin
  if p_alert is not null then
    select * into a from parking_alerts where id = p_alert for update;
    if a.id is null then raise exception 'Tow request not found.'; end if;
    v_stall := a.stall_label;
    if v_plate = '' then v_plate := coalesce(a.plate, ''); end if;
  end if;
  select x into s from jsonb_array_elements(parking_lot_core((now() at time zone 'America/Chicago')::date, false) -> 'stalls') x where x ->> 'label' = v_stall limit 1;
  if s is null then raise exception 'Choose the stall.'; end if;
  if length(coalesce(p_vehicle, '')) > 80 or length(coalesce(p_note, '')) > 300 or length(v_plate) > 10 then raise exception 'Please shorten the description.'; end if;
  if v_plate <> '' then
    select unit_number into v_match from vehicles where status = 'active' and upper(regexp_replace(coalesce(plate, ''), '[^A-Za-z0-9]', '', 'g')) = v_plate limit 1;
  end if;
  insert into parking_tows (alert_id, stall_label, plate, plate_state, vehicle, note, matched_unit, stall_unit)
  values (a.id, v_stall, nullif(v_plate, ''), nullif(upper(trim(coalesce(p_state, a.plate_state, ''))), ''), coalesce(nullif(trim(p_vehicle), ''), a.vehicle),
          nullif(trim(p_note), ''), case when v_match is distinct from (s ->> 'used_by') then v_match end, s ->> 'used_by')
  returning * into t;
  if a.id is not null and a.status in ('open', 'tow_requested') then
    update parking_alerts set status = 'resolved', resolved_at = now(), resolved_note = 'towed by the tow company' where id = a.id;
  end if;
  insert into email_outbox (to_email, subject, html, kind) values ('info@2ndchinc.org', 'Towed: stall ' || v_stall || coalesce(' (plate ' || t.plate || ')', ''),
    '<div style="font-family:Arial,sans-serif;max-width:640px;color:#1b2430"><p><b>' || repair_esc(coalesce(nullif(condo_setting('tow_company', ''), ''), 'The tow company'))
    || ' reports a tow</b> from stall ' || repair_esc(v_stall) || ' at ' || to_char(t.towed_at at time zone 'America/Chicago', 'FMMM/FMDD/YYYY FMHH12:MI AM') || '.</p>'
    || '<p>Vehicle: ' || repair_esc(coalesce(nullif(concat_ws(', ', t.vehicle, case when t.plate is not null then 'plate ' || t.plate || coalesce(' ' || t.plate_state, '') end), ''), 'not described')) || '</p>'
    || case when t.matched_unit is not null then '<p><b>The plate is registered to Unit ' || repair_esc(t.matched_unit) || '</b> (it was in another unit''s stall). Start the fine on the staff Parking page.</p>' else '' end
    || coalesce('<p>Note: ' || repair_esc(t.note) || '</p>', '')
    || '<p>https://2ndchinc.org/parking/</p></div>', 'parking_tow');
  return to_jsonb(t);
end;
$$;
revoke all on function tow_record(uuid, text, text, text, text, text) from public, anon, authenticated;
grant execute on function tow_record(uuid, text, text, text, text, text) to service_role;

-- The tow company's page also lists open tow requests (last 24 hours) and today's tows.
do $$ declare v text := pg_get_functiondef('tow_lot_view()'::regprocedure); n text; begin
  n := replace(v, '''office_phone'', condo_setting(''org_phone'', ''''),',
    '''office_phone'', condo_setting(''org_phone'', ''''),
    ''tow_requests'', coalesce((select jsonb_agg(jsonb_build_object(''id'', a.id, ''stall'', a.stall_label, ''vehicle'', a.vehicle, ''plate'', a.plate, ''plate_state'', a.plate_state,
        ''note'', a.note, ''status'', a.status, ''alerted_at'', a.alerted_at, ''tow_requested_at'', a.tow_requested_at, ''photos'', a.photos) order by a.alerted_at desc)
      from parking_alerts a where a.status in (''open'', ''tow_requested'') and a.alerted_at > now() - interval ''24 hours''), ''[]''::jsonb),
    ''tows_today'', coalesce((select jsonb_agg(jsonb_build_object(''stall'', t.stall_label, ''plate'', t.plate, ''vehicle'', t.vehicle, ''towed_at'', t.towed_at) order by t.towed_at desc)
      from parking_tows t where t.towed_at > now() - interval ''24 hours''), ''[]''::jsonb),');
  if n = v then raise exception 'tow_lot_view changed; update this migration'; end if;
  execute n;
end $$;

create or replace function parking_tows_staff()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(to_jsonb(t) || jsonb_build_object('alert_photos', coalesce((select a.photos from parking_alerts a where a.id = t.alert_id), '{}'::text[]),
      'violation_status', (select v.status from condo_violations v where v.id = t.violation_id)) order by t.towed_at desc)
    from parking_tows t where t.towed_at > now() - interval '90 days'), '[]'::jsonb);
end;
$$;
revoke all on function parking_tows_staff() from public, anon;
grant execute on function parking_tows_staff() to authenticated;

-- Start the $35 "Parking in another unit's stall" violation for the unit the plate is registered to. The tenant is billed when that unit
-- has a 2nd Chance lease (Parking Agreement cost recovery). The violation then follows the normal notice / 14-day hearing steps.
create or replace function parking_tow_start_fine(p_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare t parking_tows; v jsonb; v_day date;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into t from parking_tows where id = p_id for update;
  if t.id is null then raise exception 'Tow not found.'; end if;
  if t.violation_id is not null then raise exception 'A violation was already started for this tow.'; end if;
  if t.matched_unit is null then raise exception 'The plate is not registered to a unit, so there is no unit to fine.'; end if;
  v_day := (t.towed_at at time zone 'America/Chicago')::date;
  v := roca_violation_create(t.matched_unit, 'unassigned_parking',
    'Vehicle registered to Unit ' || t.matched_unit || coalesce(' (' || concat_ws(', ', t.vehicle, 'plate ' || t.plate) || ')', '') || ' was parked in stall ' || t.stall_label
      || ' without permission and was towed by ' || coalesce(nullif(condo_setting('tow_company', ''), ''), 'the tow company') || ' on ' || to_char(v_day, 'FMMM/FMDD/YYYY') || '.',
    v_day, coalesce(nullif(condo_setting('tow_company', ''), ''), 'Tow company'), 'staff', null, false, roca_unit_lease_on(t.matched_unit, v_day) is not null);
  update parking_tows set violation_id = (v ->> 'id')::bigint where id = t.id;
  return v;
end;
$$;
revoke all on function parking_tow_start_fine(uuid) from public, anon;
grant execute on function parking_tow_start_fine(uuid) to authenticated;

create or replace function parking_tow_dismiss(p_id uuid, p_note text)
returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  update parking_tows set dismissed_at = now(), staff_note = nullif(trim(p_note), '') where id = p_id and violation_id is null;
  if not found then raise exception 'Tow not found, or a violation was already started.'; end if;
end;
$$;
revoke all on function parking_tow_dismiss(uuid, text) from public, anon;
grant execute on function parking_tow_dismiss(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Staff: one signed copy, to view or print
create or replace function parking_ack_staff_get(p_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare a parking_acks;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into a from parking_acks where id = p_id;
  if a.id is null then raise exception 'Not found.'; end if;
  if a.person_kind = 'occupant' then a.person_name := 'Unit ' || a.unit_number || ' occupant'; end if;
  return parking_ack_row(a) || jsonb_build_object('current', a.terms_version = parking_terms_version());
end;
$$;
revoke all on function parking_ack_staff_get(uuid) from public, anon;
grant execute on function parking_ack_staff_get(uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- 4. Stock-take: one row per unit stall. Counts only (no names), so the 11/15 review is one glance.
create or replace function parking_stocktake_staff()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_ver text := parking_terms_version(); v_blocked text[] := parking_blocked_units();
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object('as_of', now(), 'register_by', condo_setting('vehicle_register_by', ''), 'enforce_from', condo_setting('tow_enforce_from', ''),
    'stalls', coalesce((select jsonb_agg(jsonb_build_object(
        'stall', s.label, 'unit', s.home_unit,
        'occupied_by', case
          when s.home_unit = any (owner_direct_unit_list()) then 'owner-managed'
          when exists (select 1 from leases l join rental_units ru on ru.id = l.unit_id where l.status = 'active' and ru.unit_number = s.home_unit) then 'tenant'
          when (select occupancy from condo_units where unit_number = s.home_unit) = 'owner' then 'owner'
          else 'vacant' end,
        'people', (select count(*) from parking_unit_people(s.home_unit)),
        'vehicles', (select count(*) from vehicles v where v.unit_number = s.home_unit and v.status = 'active' and v.kind in ('own', 'loaner')),
        'visitors', (select count(*) from vehicles v where v.unit_number = s.home_unit and v.status = 'active' and v.kind = 'visitor'),
        'no_vehicle', exists (select 1 from parking_declarations d where d.unit_number = s.home_unit and d.no_vehicle),
        'hangers_missing', (select count(*) from vehicles v where v.unit_number = s.home_unit and v.status = 'active' and v.kind in ('own', 'loaner') and v.hanger_number is null),
        'signed', (select count(distinct lower(a.email)) from parking_acks a where a.unit_number = s.home_unit and a.terms_version = v_ver),
        'blocked', s.home_unit = any (v_blocked))
      order by nullif(regexp_replace(s.label, '\D', '', 'g'), '')::int nulls last) from parking_stalls s where s.kind = 'unit' and s.active), '[]'::jsonb));
end;
$$;
revoke all on function parking_stocktake_staff() from public, anon;
grant execute on function parking_stocktake_staff() to authenticated;
