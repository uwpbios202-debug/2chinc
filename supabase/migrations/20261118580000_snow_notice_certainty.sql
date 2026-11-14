-- Snow: no doubt about the consequences (Stephen, 11/8/2026: "fix gaps to remove doubt and keep certainty").
--   1. The move-your-vehicle email states what WILL happen: a vehicle left in the lot is towed ($400 to $500, paid by the vehicle owner)
--      and a $105 fine is charged.
--   2. When the plow reports a vehicle not moved, the unit's people and the unit's owner are emailed at once (and phones alerted):
--      the stall, the vehicle, that a tow was requested and that the $105 fine was opened. The sooner they know, the sooner they can act.
-- No new table, so no new grants.

do $$ declare v text := pg_get_functiondef('snow_vendor_new_visit(boolean, timestamp with time zone, timestamp with time zone, text[])'::regprocedure); n text; begin
  n := replace(v, '''<p>Vehicles still in the lot during that time may be removed by the association''''s towing provider at the vehicle owner''''s expense. Please move yours to a legal place on the street, following the city''''s winter parking rules, and bring it back once the lot is cleared.</p>''',
    '''<p><b>A vehicle left in the lot during that time will be towed by Always Towing ($400 to $500, paid by the vehicle owner) and a $105 fine will be charged.</b> Please move yours to a legal place on the street, following the city''''s winter parking rules, and bring it back once the lot is cleared.</p>''');
  if n = v then raise exception 'snow_vendor_new_visit changed; update this migration'; end if;
  execute n;
end $$;

-- 2. Tell the unit at the moment of the report.
create or replace function snow_not_moved_notify(p_alert uuid)
returns int
language plpgsql volatile security definer set search_path = public as $$
declare a parking_alerts; vi condo_violations; v_unit text; r record; n int := 0; v_desc text; v_when text;
begin
  select * into a from parking_alerts where id = p_alert and reporter_kind = 'vendor';
  if a.id is null then return 0; end if;
  select * into vi from condo_violations where id = a.violation_id;
  v_unit := coalesce((select unit_number from condo_units where id = vi.unit_id), a.matched_unit, a.unit_number);
  v_desc := concat_ws(', ', a.vehicle, case when a.plate is not null then 'plate ' || a.plate || coalesce(' ' || a.plate_state, '') end);
  v_when := to_char(a.alerted_at at time zone 'America/Chicago', 'FMHH12:MI AM');
  for r in select distinct on (x.email) x.email, x.name from (
      select lower(p.email) email, p.name from parking_unit_people(v_unit) p where p.email like '%@%'
      union all
      select lower(o.email), o.name from condo_units cu join condo_ownerships s on s.unit_id = cu.id and s.is_current join condo_owners o on o.id = s.owner_id
       where cu.unit_number = v_unit and o.email like '%@%' and o.id::text is distinct from condo_setting('company_owner_id', '')) x order by x.email loop
    insert into email_outbox (to_email, subject, html, kind) values (r.email, 'Snow removal: a vehicle of Unit ' || v_unit || ' was not moved. A tow was requested',
      '<div style="font-family:Arial,sans-serif;max-width:640px;color:#1b2430;line-height:1.5"><p>Hi ' || repair_esc(coalesce(nullif(split_part(coalesce(r.name, ''), ' ', 1), ''), 'there')) || ',</p>'
      || '<p><b>A vehicle' || case when v_desc <> '' then ' (' || repair_esc(v_desc) || ')' else '' end || ' was not moved from stall ' || repair_esc(a.stall_label)
      || ' for snow removal.</b> The snow removal crew reported it with photos at ' || v_when || '.</p>'
      || '<ul><li><b>A tow was requested from Always Towing</b> ($400 to $500, paid by the vehicle owner to get the vehicle back).</li>'
      || case when vi.id is not null then '<li><b>A $105 fine was opened for Unit ' || repair_esc(v_unit) || '</b> (Vehicle not removed for snow). The office will send the written notice.</li>' else '' end
      || '</ul><p>If the vehicle is still there, move it right away. Questions: call or text (262) 236-5443.</p><p>2nd Chance Housing</p></div>', 'snow_not_moved');
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke all on function snow_not_moved_notify(uuid) from public, anon, authenticated;

do $$ declare v text := pg_get_functiondef('snow_not_moved(text, text, text, text, text)'::regprocedure); n text; begin
  n := replace(v, '  return jsonb_build_object(''alert_id'', a.id, ''violation_id'', vi.id, ''fine_unit'', v_fine_unit, ''plate_unit'', v_match);',
                  '  perform snow_not_moved_notify(a.id);
  return jsonb_build_object(''alert_id'', a.id, ''violation_id'', vi.id, ''fine_unit'', v_fine_unit, ''plate_unit'', v_match);');
  if n = v then raise exception 'snow_not_moved changed; update this migration'; end if;
  execute n;
end $$;

-- Phone pop-up for it too.
do $$ declare v text := pg_get_functiondef('push_from_email()'::regprocedure); n text; begin
  n := replace(v, 'if new.kind in (''parking_alert'', ''snow_move_notice'')', 'if new.kind in (''parking_alert'', ''snow_move_notice'', ''snow_not_moved'')');
  n := replace(n, 'case when new.kind = ''snow_move_notice'' then ''Snow removal: move your vehicle out of the lot. Tap for the time.''',
                  'case when new.kind = ''snow_move_notice'' then ''Snow removal: move your vehicle out of the lot. Tap for the time.''
           when new.kind = ''snow_not_moved'' then ''A tow was requested and a $105 fine was opened. Move it now if it is still there.''');
  if n = v or position('snow_not_moved' in n) = 0 then raise exception 'push_from_email changed; update this migration'; end if;
  execute n;
end $$;
