-- The snow plow and the parking lot (Stephen, 11/8/2026).
--   * The snow vendor (a vendor with a snow agreement, signed in at https://2ndchinc.org/contractor/) sees the parking lot map and the
--     registered vehicles with their photos, like residents do.
--   * "Vehicle not moved": during a snow visit the plow marks a stall where a vehicle was left (plate and photos). BOTH happen at once
--     (Stephen: "both are activated immediately, towing and fine"):
--       - a tow request: Always Towing and the office are emailed, and it appears on Always Towing's page under Tow requests with the photos;
--       - a $105 ROCA1 violation "Vehicle not removed (snow)" is opened for the unit the plate is registered to, or, when the plate is not
--         registered, the unit whose stall it is. The office then sends the fine notice (ROCA1 Rules §10: notice and 14 days to ask for a
--         hearing). Fines stay on the unit owner's association account and are never billed to the tenant (Stephen, 10/7/2026).
--   * The snow notice now also reaches Unit 6's parking-and-keys person(s), and pops up on phones that turned on alerts.
--   * Always Towing's page shows a snow-removal banner while a snow window is on.
-- No new table, so no new grants.

create or replace function snow_vendor_ids()
returns setof uuid
language sql stable security definer set search_path = public as $$
  select v from contractor_vendor_ids(auth.email()) v where exists (select 1 from snow_agreements a where a.vendor_id = v);
$$;
revoke all on function snow_vendor_ids() from public, anon, authenticated;

create or replace function snow_is_vendor()
returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and exists (select 1 from snow_vendor_ids());
$$;
revoke all on function snow_is_vendor() from public, anon;
grant execute on function snow_is_vendor() to authenticated;

-- The plow may view the lot, the vehicles and their photos (storage policy "vehicles read" uses this too).
create or replace function vehicle_can_view()
returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and (
    exists (select 1 from vehicle_my_units())
    or exists (select 1 from occupant_my_units())
    or condo_owner_for_email(auth.email()) is not null
    or condo_is_staff()
    or snow_is_vendor());
$$;

-- Snow notice: Unit 6's parking-and-keys people too.
do $$ declare v text := pg_get_functiondef('snow_recipients()'::regprocedure); n text; begin
  n := replace(v, '    select unit_number, email, name from own
    where occupancy = ''owner'' or is_direct or not exists (select 1 from ten where ten.uid = own.uid)',
                  '    select unit_number, email, name from own
    where occupancy = ''owner'' or is_direct or not exists (select 1 from ten where ten.uid = own.uid)
    union all
    select o.unit_number, o.email, o.name from unit_occupants o where o.active and coalesce(o.email, '''') <> '''' and o.unit_number in (select u from dunits)');
  if n = v then raise exception 'snow_recipients changed; update this migration'; end if;
  execute n;
end $$;

-- Phone pop-ups for the snow notice as well as for parking alerts.
create or replace function push_from_email()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.kind in ('parking_alert', 'snow_move_notice') and exists (select 1 from push_subscriptions where lower(email) = lower(new.to_email)) then
    insert into push_outbox (to_email, title, body, url, tag, kind)
    values (lower(new.to_email), case when new.kind = 'snow_move_notice' then '❄ ' else '🚨 ' end || new.subject,
      case when new.kind = 'snow_move_notice' then 'Snow removal: move your vehicle out of the lot. Tap for the time.'
           else 'If it is yours or your guest''s, move it now. Tap to open the parking lot.' end,
      case when exists (select 1 from tenants where lower(email) = lower(new.to_email)) then '/resident/#parking'
           when exists (select 1 from unit_occupants where active and lower(email) = lower(new.to_email)) then '/unit-access/#parking'
           else '/association-owners/roca1/#parking' end,
      case when new.kind = 'snow_move_notice' then 'snow' else 'parking' end, new.kind);
  end if;
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- "Vehicle not moved"
alter table parking_alerts drop constraint if exists parking_alerts_reporter_kind_check;
alter table parking_alerts add constraint parking_alerts_reporter_kind_check check (reporter_kind in ('tenant', 'owner', 'vendor'));
alter table parking_alerts add column if not exists violation_id bigint;

create or replace function snow_not_moved(p_stall text, p_plate text, p_plate_state text, p_vehicle text, p_note text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  v_vendor uuid; v_vname text; s jsonb; a parking_alerts; v_plate text := upper(regexp_replace(coalesce(p_plate, ''), '[^A-Za-z0-9]', '', 'g'));
  v_match text; v_unit text; v_fine_unit text; f roca_fine_schedule; v_day date := (now() at time zone 'America/Chicago')::date; v_lease uuid; vi condo_violations;
  v_desc text; v_html text; v_to text := condo_setting('tow_email', '');
begin
  if not snow_is_vendor() then raise exception 'Snow vendor sign-in required' using errcode = '42501'; end if;
  if autopay_view_as_session() then raise exception 'Not available while viewing as someone else.'; end if;
  select v into v_vendor from snow_vendor_ids() v limit 1;
  select name into v_vname from vendors where id = v_vendor;
  if not exists (select 1 from snow_visits sv where sv.vendor_id = v_vendor and sv.kind = 'snow' and sv.created_at > now() - interval '24 hours'
                   and sv.status not in ('declined')) then
    raise exception 'Start today''s snow visit first (email the residents, or Log a push).';
  end if;
  select x into s from jsonb_array_elements(parking_lot_core(v_day, false) -> 'stalls') x where x ->> 'label' = trim(coalesce(p_stall, '')) limit 1;
  if s is null then raise exception 'Choose the stall.'; end if;
  if length(coalesce(p_vehicle, '')) > 80 or length(coalesce(p_note, '')) > 300 or length(v_plate) > 10 then raise exception 'Please shorten the description.'; end if;
  if exists (select 1 from parking_alerts x where x.stall_id = (s ->> 'id')::uuid and x.reporter_kind = 'vendor' and x.alerted_at > now() - interval '12 hours') then
    raise exception 'Stall % was already reported today.', s ->> 'label';
  end if;
  if v_plate <> '' then
    select unit_number into v_match from vehicles where status = 'active' and upper(regexp_replace(coalesce(plate, ''), '[^A-Za-z0-9]', '', 'g')) = v_plate limit 1;
  end if;
  v_unit := coalesce(s ->> 'used_by', s ->> 'home_unit');
  v_fine_unit := coalesce(v_match, v_unit);
  v_desc := concat_ws(', ', nullif(trim(p_vehicle), ''), case when v_plate <> '' then 'plate ' || v_plate || coalesce(' ' || nullif(upper(trim(p_plate_state)), ''), '') end);

  -- 1. The tow request (appears on Always Towing's page with the photos added next).
  insert into parking_alerts (stall_id, stall_label, address, unit_number, reporter_email, reporter_kind, vehicle, plate, plate_state, note, matched_unit,
                              status, tow_unlock_at, tow_requested_at)
  values ((s ->> 'id')::uuid, s ->> 'label', (select address from condo_units where unit_number = s ->> 'home_unit'), coalesce(v_unit, s ->> 'label'), lower(auth.email()), 'vendor',
          nullif(trim(p_vehicle), ''), nullif(v_plate, ''), nullif(upper(trim(p_plate_state)), ''), 'Snow removal: vehicle not moved.' || coalesce(' ' || nullif(trim(p_note), ''), ''),
          v_match, 'tow_requested', now(), now())
  returning * into a;
  v_html := '<div style="font-family:Arial,sans-serif;max-width:640px;color:#1b2430"><p>Hello ' || repair_esc(coalesce(nullif(condo_setting('tow_company', ''), ''), 'dispatch')) || ',</p>'
    || '<p><b>Snow removal tow request: a vehicle was not moved for the plow.</b></p>'
    || '<p>Location: <b>' || repair_esc(coalesce(a.address, '6622-6626 N Bourbon St')) || ', Milwaukee, WI</b>, parking lot, stall <b>' || repair_esc(a.stall_label) || '</b>.</p>'
    || '<p>Vehicle: ' || repair_esc(coalesce(nullif(v_desc, ''), 'see the photos')) || '</p>'
    || coalesce('<p>Note: ' || repair_esc(nullif(trim(p_note), '')) || '</p>', '')
    || '<p>Reported by the snow removal contractor (' || repair_esc(coalesce(v_vname, 'snow vendor')) || ') at ' || to_char(now() at time zone 'America/Chicago', 'FMHH12:MI AM')
    || '. All residents were asked to move their vehicles. Photos are on your private vehicle page under Tow requests.</p>'
    || '<p>Property manager: 2nd Chance Housing, info@2ndchinc.org, ' || repair_esc(condo_setting('org_phone', '')) || '.</p></div>';
  if v_to like '%@%' then
    insert into email_outbox (to_email, subject, html, kind) values (v_to, 'Snow removal tow request: stall ' || a.stall_label || ', ' || coalesce(a.address, 'N Bourbon St'), v_html, 'parking_tow');
  end if;

  -- 2. The $105 violation.
  select * into f from roca_fine_schedule where code = 'snow_non_removal' and active;
  if f.code is not null and exists (select 1 from condo_units where unit_number = v_fine_unit) then
    v_lease := roca_unit_lease_on(v_fine_unit, v_day);
    insert into condo_violations (unit_id, owner_id, category, description, observed_date, reported_by, entered_by, fine_code, fine_amount, complaint_source,
                                  continuing, bill_tenant, lease_id)
    values ((select id from condo_units where unit_number = v_fine_unit), (select owner_id from roca_unit_owner_on(v_fine_unit, v_day)), f.title,
            'Vehicle ' || coalesce(nullif(v_desc, '') || ' ', '') || 'was not moved from stall ' || a.stall_label || ' for snow removal on ' || to_char(v_day, 'FMMM/FMDD/YYYY')
              || case when v_match is not null then ' (plate registered to Unit ' || v_match || ')' else ' (plate not registered; charged to the unit whose stall it is)' end
              || '. Reported by the snow removal contractor with photos; a tow was requested.',
            v_day, coalesce(v_vname, 'Snow vendor'), lower(auth.email()), f.code, null, 'staff', false, false, v_lease)
    returning * into vi;
    update parking_alerts set violation_id = vi.id where id = a.id;
  end if;

  insert into email_outbox (to_email, subject, html, kind) values ('info@2ndchinc.org', 'Snow: vehicle not moved in stall ' || a.stall_label || ' (tow requested, $105 violation opened)',
    replace(v_html, '<p>Hello ' || repair_esc(coalesce(nullif(condo_setting('tow_company', ''), ''), 'dispatch')) || ',</p>', '')
    || case when vi.id is not null then '<p><b>Violation #' || vi.id || ' ($105, Vehicle not removed (snow)) was opened for Unit ' || repair_esc(v_fine_unit)
         || case when v_match is null then ' (the plate is not registered, so it is charged to the unit whose stall it is: check it)' else '' end
         || '.</b> Send the fine notice from the Violations page: https://2ndchinc.org/association-owners/roca1/violations/</p>' else '' end, 'parking_tow');
  return jsonb_build_object('alert_id', a.id, 'violation_id', vi.id, 'fine_unit', v_fine_unit, 'plate_unit', v_match);
end;
$$;
revoke all on function snow_not_moved(text, text, text, text, text) from public, anon;
grant execute on function snow_not_moved(text, text, text, text, text) to authenticated;

-- The plow's reports today (to add photos and see what was sent).
create or replace function snow_not_moved_today()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not snow_is_vendor() then raise exception 'Snow vendor sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'stall', a.stall_label, 'vehicle', a.vehicle, 'plate', a.plate, 'status', a.status,
      'at', a.alerted_at, 'photos', cardinality(a.photos)) order by a.alerted_at desc)
    from parking_alerts a where a.reporter_kind = 'vendor' and a.reporter_email = lower(auth.email()) and a.alerted_at > now() - interval '24 hours'), '[]'::jsonb);
end;
$$;
revoke all on function snow_not_moved_today() from public, anon;
grant execute on function snow_not_moved_today() to authenticated;

-- A tow of a snow report carries the violation already opened (so the staff Tows list offers no second fine).
do $$ declare v text := pg_get_functiondef('tow_record(uuid, text, text, text, text, text)'::regprocedure); n text; begin
  n := replace(v, '  if a.id is not null and a.status in (''open'', ''tow_requested'') then',
                  '  if a.violation_id is not null then update parking_tows set violation_id = a.violation_id where id = t.id; t.violation_id := a.violation_id; end if;
  if a.id is not null and a.status in (''open'', ''tow_requested'') then');
  if n = v then raise exception 'tow_record changed; update this migration'; end if;
  execute n;
end $$;

-- Always Towing's page: snow removal in progress.
do $$ declare v text := pg_get_functiondef('tow_lot_view()'::regprocedure); n text; begin
  n := replace(v, '''tow_requests'', coalesce(',
    '''snow'', (select jsonb_build_object(''from'', sv.window_start, ''until'', sv.window_end) from snow_visits sv
              where sv.kind = ''snow'' and sv.notice_sent_at is not null and now() < coalesce(sv.window_end, sv.notice_sent_at + interval ''24 hours'') and sv.status not in (''declined'')
              order by sv.notice_sent_at desc limit 1),
    ''tow_requests'', coalesce(');
  if n = v then raise exception 'tow_lot_view changed; update this migration'; end if;
  execute n;
end $$;

-- Fix (11/8): the staff "Start $35 fine" button for a tow keeps the fine on the owner's association account too (rule of 10/7/2026). It asked
-- to bill the tenant when the unit has a lease, which the roca_violation_no_tenant_billing trigger refuses.
do $$ declare v text := pg_get_functiondef('parking_tow_start_fine(uuid)'::regprocedure); n text; begin
  n := replace(v, '''staff'', null, false, roca_unit_lease_on(t.matched_unit, v_day) is not null);', '''staff'', null, false, false);');
  if n = v then raise exception 'parking_tow_start_fine changed; update this migration'; end if;
  execute n;
end $$;
