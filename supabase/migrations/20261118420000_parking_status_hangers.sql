-- Parking tab, tightened (Stephen, 11/8/2026).
--   * Rear-view mirror hangers are the parking permit (Parking Agreement section 14). The office records each hanger's number on the vehicle
--     (staff Parking page); residents see their own number; Always Towing's page shows it.
--   * parking_status_mine(): the "Your stall" card at the top of every Parking tab: today's stall, registered or not, hanger, parking allowed
--     or revoked (parking_blocked_units), the deadline / patrol dates, and an active snow-removal window (snow_visits).
-- No new table, so no new grants.

alter table vehicles add column if not exists hanger_number text;

create or replace function vehicles_staff_set_hanger(p_id uuid, p_number text)
returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if length(coalesce(p_number, '')) > 20 then raise exception 'Hanger number is too long.'; end if;
  update vehicles set hanger_number = nullif(upper(trim(p_number)), ''), updated_at = now() where id = p_id;
  if not found then raise exception 'Vehicle not found.'; end if;
end;
$$;
revoke all on function vehicles_staff_set_hanger(uuid, text) from public, anon;
grant execute on function vehicles_staff_set_hanger(uuid, text) to authenticated;

-- Always Towing's page shows the hanger number.
do $$ declare v text := pg_get_functiondef('tow_lot_view()'::regprocedure); n text; begin
  n := replace(v, '''vin'', v.vin,', '''vin'', v.vin, ''hanger'', v.hanger_number,');
  if n = v then raise exception 'tow_lot_view changed; update this migration'; end if;
  execute n;
end $$;

create or replace function parking_status_mine()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_blocked text[] := parking_blocked_units();
begin
  if not vehicle_can_view() then raise exception 'Resident or owner sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'register_by', condo_setting('vehicle_register_by', ''), 'enforce_from', condo_setting('tow_enforce_from', ''),
    'today', (now() at time zone 'America/Chicago')::date, 'office_phone', condo_setting('org_phone', ''),
    'snow', (select jsonb_build_object('from', s.window_start, 'until', s.window_end) from snow_visits s
              where s.kind = 'snow' and s.notice_sent_at is not null and now() < coalesce(s.window_end, s.notice_sent_at + interval '24 hours')
                and s.status not in ('declined') order by s.notice_sent_at desc limit 1),
    'units', coalesce((select jsonb_agg(jsonb_build_object('unit', r.unit_number, 'role', r.role,
        'stall', parking_alert_stall_for(r.unit_number) ->> 'label',
        'blocked', r.unit_number = any (v_blocked),
        'no_vehicle', exists (select 1 from parking_declarations d where d.unit_number = r.unit_number and d.no_vehicle),
        'vehicles', coalesce((select jsonb_agg(jsonb_build_object('kind', v.kind, 'desc', concat_ws(' ', v.color, v.year::text, v.make, v.model),
              'visitor', v.visitor_name, 'plate', v.plate, 'hanger', v.hanger_number, 'loaner_until', v.loaner_until) order by v.kind)
            from vehicles v where v.unit_number = r.unit_number and v.status = 'active'), '[]'::jsonb))
      order by nullif(regexp_replace(r.unit_number, '\D', '', 'g'), '')::int) from vehicle_reg_units() r), '[]'::jsonb));
end;
$$;
revoke all on function parking_status_mine() from public, anon;
grant execute on function parking_status_mine() to authenticated;
