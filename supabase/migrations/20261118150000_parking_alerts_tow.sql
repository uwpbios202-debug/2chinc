-- Parking alerts and tow requests (Stephen, 11/3/2026).
--   An occupant comes home to a vehicle in their stall. In the portal they press "Someone is parked in my stall" for their stall (the stall
--   their unit uses today, switches included). Everyone who lives here (tenants on active leases, owner-occupants) and the owner of an
--   owner-direct unit (Unit 6: John starts alerts for stall 6 and receives them, since Unit 6's tenant has no portal) is emailed at once.
--   After parking_tow_wait_seconds (60) the reporter may press "Request a tow": Always Towing and the office are emailed the details and the
--   reporter's phone calls dispatch. One open alert per stall. Every step is logged in parking_alerts.
-- The tow company's name, phone and email are portal settings (tow_*), entered as data, not here.
-- No Twilio: email now; free web push notifications come next (Stephen, 11/3/2026).

create table if not exists parking_alerts (
  id uuid primary key default gen_random_uuid(),
  stall_id uuid not null references parking_stalls(id),
  stall_label text not null,
  address text,
  unit_number text not null,                  -- the reporter's unit (whose stall it is today)
  reporter_email text not null,
  reporter_kind text not null check (reporter_kind in ('tenant', 'owner')),
  vehicle text,                               -- color / make / model, as the reporter saw it
  plate text,
  plate_state text,
  note text,
  matched_unit text,                          -- the plate matches a vehicle registered to this unit
  status text not null default 'open' check (status in ('open', 'tow_requested', 'resolved', 'cancelled')),
  alerted_at timestamptz not null default now(),
  tow_unlock_at timestamptz not null,
  recipients int not null default 0,
  tow_requested_at timestamptz,
  resolved_at timestamptz,
  resolved_note text
);
create index if not exists parking_alerts_open on parking_alerts (stall_id) where status = 'open';
alter table parking_alerts enable row level security;   -- read and written through the functions below only
revoke all on parking_alerts from public, anon, authenticated;
grant all on parking_alerts to service_role;

insert into portal_settings (key, value) values ('parking_tow_wait_seconds', '60') on conflict (key) do nothing;

-- Units the signed-in person may raise an alert for: their own stall (tenant, owner-occupant) and owner-direct units they own (Unit 6).
create or replace function parking_alert_my_units()
returns table (unit_number text, kind text)
language sql stable security definer set search_path = public as $$
  select unit_number, kind from parking_my_units()
  union
  select cu.unit_number, 'owner' from condo_ownerships s join condo_units cu on cu.id = s.unit_id
   where s.is_current and s.owner_id = condo_owner_for_email(auth.email()) and condo_session_ok()
     and cu.unit_number = any (string_to_array(replace(condo_setting('owner_direct_units', ''), ' ', ''), ','))
     and exists (select 1 from parking_stalls st where st.home_unit = cu.unit_number and st.active);
$$;
revoke all on function parking_alert_my_units() from public, anon, authenticated;

-- Everyone who gets an alert: the people of every unit (tenants on active leases, owner-occupants) and the owners of owner-direct units.
create or replace function parking_alert_people()
returns table (unit_number text, name text, email text)
language sql stable security definer set search_path = public as $$
  select distinct on (x.email) x.unit_number, x.name, x.email from (
    select st.home_unit as unit_number, p.name, lower(p.email) as email
      from parking_stalls st cross join lateral parking_unit_people(st.home_unit) p
     where st.kind = 'unit' and st.active and p.email like '%@%'
    union all
    select cu.unit_number, o.name, lower(o.email)
      from condo_units cu join condo_ownerships s on s.unit_id = cu.id and s.is_current join condo_owners o on o.id = s.owner_id
     where cu.unit_number = any (string_to_array(replace(condo_setting('owner_direct_units', ''), ' ', ''), ',')) and o.email like '%@%') x
  order by x.email, x.unit_number;
$$;
revoke all on function parking_alert_people() from public, anon, authenticated;

-- The stall a unit uses today (a switch moves it).
create or replace function parking_alert_stall_for(p_unit text)
returns jsonb
language sql stable security definer set search_path = public as $$
  select s from jsonb_array_elements(parking_lot_core(current_date, false) -> 'stalls') s
   where s ->> 'kind' = 'unit' and s ->> 'used_by' = p_unit limit 1;
$$;
revoke all on function parking_alert_stall_for(text) from public, anon, authenticated;

create or replace function parking_alert_row(a parking_alerts)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object('id', a.id, 'stall', a.stall_label, 'unit', a.unit_number, 'vehicle', a.vehicle, 'plate', a.plate, 'plate_state', a.plate_state,
    'note', a.note, 'status', a.status, 'alerted_at', a.alerted_at, 'tow_unlock_at', a.tow_unlock_at, 'tow_requested_at', a.tow_requested_at,
    'resolved_at', a.resolved_at, 'recipients', a.recipients, 'now', now());
$$;
revoke all on function parking_alert_row(parking_alerts) from public, anon, authenticated;

-- What the portal shows: my stalls today, any open alert on them, the tow company's phone.
create or replace function parking_alert_mine()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_units text[];
begin
  select coalesce(array_agg(unit_number), '{}') into v_units from parking_alert_my_units();
  return jsonb_build_object(
    'stalls', coalesce((select jsonb_agg(jsonb_build_object('unit', u, 'stall', parking_alert_stall_for(u) ->> 'label',
                 'blocked', u = any (parking_blocked_units())) order by u::int) from unnest(v_units) u), '[]'::jsonb),
    'alerts', coalesce((select jsonb_agg(parking_alert_row(a) order by a.alerted_at desc) from parking_alerts a
                 where a.unit_number = any (v_units) and (a.status in ('open', 'tow_requested') and a.alerted_at > now() - interval '24 hours'
                   or a.alerted_at > now() - interval '3 days')), '[]'::jsonb),
    'tow', jsonb_build_object('company', condo_setting('tow_company', ''), 'phone', condo_setting('tow_dispatch_phone', ''),
                 'option', condo_setting('tow_dispatch_option', ''), 'wait', condo_setting('parking_tow_wait_seconds', '60')::int),
    'office_phone', condo_setting('org_phone', ''));
end;
$$;
revoke all on function parking_alert_mine() from public, anon;
grant execute on function parking_alert_mine() to authenticated;

-- Raise an alert: emails everyone who lives here (and the office).
create or replace function parking_alert_create(p_unit text, p_vehicle text, p_plate text, p_plate_state text, p_note text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  v_kind text; s jsonb; a parking_alerts; v_plate text := upper(regexp_replace(coalesce(p_plate, ''), '[^A-Za-z0-9]', '', 'g'));
  v_match text; r record; n int := 0; v_body text; v_when text := to_char(now() at time zone 'America/Chicago', 'FMHH12:MI AM');
  v_wait int := greatest(condo_setting('parking_tow_wait_seconds', '60')::int, 0); v_desc text;
begin
  if autopay_view_as_session() then raise exception 'Not available while viewing as someone else.'; end if;
  select kind into v_kind from parking_alert_my_units() where unit_number = p_unit limit 1;
  if v_kind is null then raise exception 'You can raise an alert only for your own stall.' using errcode = '42501'; end if;
  if p_unit = any (parking_blocked_units()) then raise exception 'Unit % is not allowed to park right now (association dues). Please call the office.', p_unit; end if;
  s := parking_alert_stall_for(p_unit);
  if s is null then raise exception 'No stall found for Unit % today.', p_unit; end if;
  if exists (select 1 from parking_alerts where stall_id = (s ->> 'id')::uuid and status = 'open' and alerted_at > now() - interval '24 hours') then
    raise exception 'An alert for stall % is already open. Use it below.', s ->> 'label';
  end if;
  if (select count(*) from parking_alerts where unit_number = p_unit and alerted_at > now() - interval '24 hours') >= 5 then
    raise exception 'Too many alerts today for this stall. Please call the office.';
  end if;
  if length(coalesce(p_vehicle, '')) > 80 or length(coalesce(p_note, '')) > 300 or length(v_plate) > 10 then raise exception 'Please shorten the description.'; end if;
  if v_plate <> '' then
    select unit_number into v_match from vehicles where status = 'active' and upper(regexp_replace(coalesce(plate, ''), '[^A-Za-z0-9]', '', 'g')) = v_plate limit 1;
  end if;
  insert into parking_alerts (stall_id, stall_label, address, unit_number, reporter_email, reporter_kind, vehicle, plate, plate_state, note, matched_unit, tow_unlock_at)
  values ((s ->> 'id')::uuid, s ->> 'label', (select address from condo_units where unit_number = (s ->> 'home_unit')), p_unit, lower(auth.email()), v_kind,
          nullif(trim(p_vehicle), ''), nullif(v_plate, ''), nullif(upper(trim(p_plate_state)), ''), nullif(trim(p_note), ''), v_match, now() + make_interval(secs => v_wait))
  returning * into a;

  v_desc := concat_ws(', ', a.vehicle, case when a.plate is not null then 'plate ' || a.plate || coalesce(' ' || a.plate_state, '') end);
  v_body := '<p><b>A vehicle is parked in stall ' || repair_esc(a.stall_label) || ' without permission</b> (reported at ' || v_when || ' by Unit ' || repair_esc(a.unit_number) || ').</p>'
    || case when v_desc <> '' then '<p>Vehicle: <b>' || repair_esc(v_desc) || '</b></p>' else '' end
    || '<p><b>If it is yours, or your guest''s, move it right now.</b> The stall''s resident may have it towed at the owner''s expense in a few minutes.</p>';
  for r in select * from parking_alert_people() where email <> lower(auth.email()) loop
    insert into email_outbox (to_email, subject, html, kind) values (r.email,
      case when r.unit_number = v_match then 'URGENT: your vehicle is in stall ' || a.stall_label || '. Move it now'
           else 'Parking alert: a vehicle is in stall ' || a.stall_label || ' without permission' end,
      '<div style="font-family:Arial,sans-serif;max-width:640px;color:#1b2430"><p>Hi ' || repair_esc(split_part(coalesce(r.name, ''), ' ', 1)) || ',</p>'
      || case when r.unit_number = v_match then '<p style="color:#b3261e"><b>The plate matches a vehicle registered to your unit.</b></p>' else '' end
      || v_body || '<p style="color:#5b6573;font-size:13px">2nd Chance Housing. You get this because you live at 6622 or 6626 N Bourbon St.</p></div>', 'parking_alert');
    n := n + 1;
  end loop;
  insert into email_outbox (to_email, subject, html, kind) values ('info@2ndchinc.org',
    'Parking alert: stall ' || a.stall_label || ' (Unit ' || a.unit_number || ')',
    '<div style="font-family:Arial,sans-serif;max-width:640px;color:#1b2430">' || v_body
    || case when v_match is not null then '<p>The plate matches a vehicle registered to <b>Unit ' || repair_esc(v_match) || '</b>.</p>' else '' end
    || coalesce('<p>Note: ' || repair_esc(a.note) || '</p>', '') || '<p>' || n || ' residents were emailed. Reported by ' || repair_esc(a.reporter_email) || '.</p></div>', 'parking_alert');
  update parking_alerts set recipients = n where id = a.id returning * into a;
  return parking_alert_row(a);
end;
$$;
revoke all on function parking_alert_create(text, text, text, text, text) from public, anon;
grant execute on function parking_alert_create(text, text, text, text, text) to authenticated;

-- Request the tow (only the reporter, only after the wait): emails the tow company and the office; the portal then calls dispatch.
create or replace function parking_alert_tow(p_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare a parking_alerts; v_name text; v_phone text; v_to text := condo_setting('tow_email', ''); v_html text;
begin
  if autopay_view_as_session() then raise exception 'Not available while viewing as someone else.'; end if;
  select * into a from parking_alerts where id = p_id for update;
  if a.id is null or a.reporter_email <> lower(auth.email()) then raise exception 'Alert not found.' using errcode = '42501'; end if;
  if a.status = 'tow_requested' then return parking_alert_row(a); end if;
  if a.status <> 'open' then raise exception 'This alert is closed.'; end if;
  if now() < a.tow_unlock_at then raise exception 'Please wait % more seconds.', ceil(extract(epoch from a.tow_unlock_at - now()))::int; end if;
  select name, phone into v_name, v_phone from tenants where lower(email) = a.reporter_email limit 1;
  if v_name is null then select name, coalesce(phone_mobile, phone_home) into v_name, v_phone from condo_owners where lower(email) = a.reporter_email limit 1; end if;
  update parking_alerts set status = 'tow_requested', tow_requested_at = now() where id = a.id returning * into a;
  v_html := '<div style="font-family:Arial,sans-serif;max-width:640px;color:#1b2430"><p>Hello ' || repair_esc(coalesce(nullif(condo_setting('tow_company', ''), ''), 'dispatch')) || ',</p>'
    || '<p><b>Tow request: unauthorized vehicle in a reserved resident stall.</b></p>'
    || '<p>Location: <b>' || repair_esc(coalesce(a.address, '6622-6626 N Bourbon St')) || ', Milwaukee, WI</b>, parking lot, stall <b>' || repair_esc(a.stall_label) || '</b> (marked with the unit number).</p>'
    || '<p>Vehicle: ' || repair_esc(coalesce(nullif(concat_ws(', ', a.vehicle, case when a.plate is not null then 'plate ' || a.plate || coalesce(' ' || a.plate_state, '') end), ''), 'see stall ' || a.stall_label)) || '</p>'
    || '<p>Requested by the resident of Unit ' || repair_esc(a.unit_number) || ': ' || repair_esc(coalesce(v_name, '')) || coalesce(', phone ' || repair_esc(v_phone), '') || '.</p>'
    || '<p>All residents were notified at ' || to_char(a.alerted_at at time zone 'America/Chicago', 'FMHH12:MI AM') || ' and the vehicle was not moved. The resident is calling dispatch now.</p>'
    || coalesce('<p>Note: ' || repair_esc(a.note) || '</p>', '')
    || '<p>Property manager: 2nd Chance Housing, info@2ndchinc.org, ' || repair_esc(condo_setting('org_phone', '')) || '.</p></div>';
  if v_to like '%@%' then
    insert into email_outbox (to_email, subject, html, kind) values (v_to, 'Tow request: stall ' || a.stall_label || ', ' || coalesce(a.address, 'N Bourbon St'), v_html, 'parking_tow');
  end if;
  insert into email_outbox (to_email, subject, html, kind) values ('info@2ndchinc.org', 'Tow requested: stall ' || a.stall_label || ' (Unit ' || a.unit_number || ')', v_html, 'parking_tow');
  return parking_alert_row(a);
end;
$$;
revoke all on function parking_alert_tow(uuid) from public, anon;
grant execute on function parking_alert_tow(uuid) to authenticated;

-- The reporter closes the alert (the vehicle moved, or it was a mistake). Office is told; residents are not emailed again.
create or replace function parking_alert_close(p_id uuid, p_moved boolean)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare a parking_alerts;
begin
  select * into a from parking_alerts where id = p_id for update;
  if a.id is null or a.reporter_email <> lower(auth.email()) then raise exception 'Alert not found.' using errcode = '42501'; end if;
  if a.status not in ('open', 'tow_requested') then return parking_alert_row(a); end if;
  update parking_alerts set status = case when p_moved then 'resolved' else 'cancelled' end, resolved_at = now(),
    resolved_note = case when p_moved then 'vehicle moved / towed' else 'cancelled by the reporter' end where id = a.id returning * into a;
  return parking_alert_row(a);
end;
$$;
revoke all on function parking_alert_close(uuid, boolean) from public, anon;
grant execute on function parking_alert_close(uuid, boolean) to authenticated;

-- Staff: the last 60 days of alerts.
create or replace function parking_alerts_staff()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(parking_alert_row(a) || jsonb_build_object('reporter', a.reporter_email, 'matched_unit', a.matched_unit, 'resolved_note', a.resolved_note)
    order by a.alerted_at desc) from parking_alerts a where a.alerted_at > now() - interval '60 days'), '[]'::jsonb);
end;
$$;
revoke all on function parking_alerts_staff() from public, anon;
grant execute on function parking_alerts_staff() to authenticated;
