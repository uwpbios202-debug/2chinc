-- Smoke alarms (Stephen, 11/5/2026):
--  * Every alarm is a smoke + CO combo with a sealed 10-year battery (the 11/5 photo reading of "smoke only" was wrong).
--  * Each alarm gets its installation date (Stephen reports them the week of 11/9); replace by = installed + 10 years.
--  * Unit alarms (unit_number set) are NOT on the monthly walk-around. They are checked once a year and at each new tenant:
--    due when never checked, last check over a year ago, or a lease on that unit started (or will start) after the last check.

alter table alarm_points add column if not exists installed_on date;

update alarm_points set kind = 'smoke_co', power = 'ten_year' where kind <> 'smoke_co' or power <> 'ten_year';

-- When a unit alarm is due, and why (null = not due). Units: rental_units.address ends with ' - <unit>'.
create or replace function alarm_unit_due(p_alarm uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_unit text; v_last timestamptz; v_move date;
begin
  select unit_number into v_unit from alarm_points where id = p_alarm;
  if v_unit is null then return null; end if;
  select max(checked_at) into v_last from alarm_checks where alarm_id = p_alarm;
  if v_last is null then return jsonb_build_object('reason', 'no check on record'); end if;
  select max(l.start_date) into v_move from leases l join rental_units ru on ru.id = l.unit_id
   where ru.address like '% - ' || v_unit and l.status in ('active', 'future', 'ended', 'expired')
     and (v_last is null or l.start_date > (v_last at time zone 'America/Chicago')::date);
  if v_move is not null then
    return jsonb_build_object('reason', case when v_move > current_date then 'new tenant moves in ' else 'new tenant moved in ' end || to_char(v_move, 'FMMM/FMDD/YYYY'), 'since', v_move);
  end if;
  if v_last is null then return jsonb_build_object('reason', 'no check on record'); end if;
  if v_last < now() - interval '1 year' then return jsonb_build_object('reason', 'yearly check (last ' || to_char(v_last at time zone 'America/Chicago', 'FMMM/FMDD/YYYY') || ')'); end if;
  return null;
end;
$$;
revoke all on function alarm_unit_due(uuid) from public, anon;

create or replace function alarm_staff_list()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_month date := date_trunc('month', now() at time zone 'America/Chicago')::date;
begin
  if not alarm_can_check() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'office', condo_is_staff(),
    'month', v_month,
    'today', (now() at time zone 'America/Chicago')::date,
    'points', coalesce((select jsonb_agg(jsonb_build_object('id', p.id, 'building', p.building, 'name', p.name, 'location', p.location,
        'kind', p.kind, 'power', p.power, 'unit', p.unit_number, 'standard', alarm_meets_standard(p.kind, p.power),
        'installed_on', p.installed_on, 'replace_by', (p.installed_on + interval '10 years')::date,
        'photo_path', p.photo_path, 'sort', p.sort, 'active', p.active,
        'due', case when p.unit_number is not null and p.active then alarm_unit_due(p.id) end,
        'this_month', (select jsonb_build_object('id', c.id, 'at', c.checked_at, 'status', c.status, 'findings', c.findings, 'notes', c.notes, 'by', c.checked_by, 'photo_path', c.photo_path)
                        from alarm_checks c where c.alarm_id = p.id and c.check_month = v_month order by c.checked_at desc limit 1),
        'last', (select jsonb_build_object('at', c.checked_at, 'status', c.status, 'findings', c.findings, 'notes', c.notes) from alarm_checks c where c.alarm_id = p.id order by c.checked_at desc limit 1))
        order by p.building, p.sort, p.name) from alarm_points p), '[]'::jsonb),
    'recent', coalesce((select jsonb_agg(x) from (
        select c.id, c.checked_at as at, c.status, c.findings, c.notes, c.checked_by as by, c.photo_path, p.building, p.name, p.location
          from alarm_checks c join alarm_points p on p.id = c.alarm_id order by c.checked_at desc limit 60) x), '[]'::jsonb),
    'reports', case when condo_is_staff() then coalesce((select jsonb_agg(x) from (
        select r.id, r.recipient_name, r.recipient_email, r.organization, r.period_from, r.period_to, r.checks_count, r.sent_by, r.sent_at
          from alarm_reports r order by r.sent_at desc limit 30) x), '[]'::jsonb) else '[]'::jsonb end);
end;
$$;
revoke all on function alarm_staff_list() from public, anon;
grant execute on function alarm_staff_list() to authenticated;

drop function if exists alarm_point_save(uuid, text, text, text, text, text, text, boolean, text);
create or replace function alarm_point_save(p_id uuid, p_building text, p_name text, p_location text, p_kind text, p_power text,
                                            p_unit text, p_active boolean, p_photo text, p_installed date)
returns uuid
language plpgsql volatile security definer set search_path = public as $$
declare v_id uuid;
begin
  if not alarm_can_check() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if length(coalesce(trim(p_name), '')) < 1 then raise exception 'Give the alarm a name, like "Second floor front".'; end if;
  if p_unit is not null and trim(p_unit) <> '' and not exists (select 1 from condo_units where unit_number = trim(p_unit)) then raise exception 'No such unit.'; end if;
  if p_installed is not null and (p_installed > current_date or p_installed < date '1990-01-01') then raise exception 'Check the installation date.'; end if;
  if p_id is null then
    if p_building not in ('6622', '6626') then raise exception 'Choose the building.'; end if;
    insert into alarm_points (building, name, location, kind, power, unit_number, photo_path, installed_on, sort)
    values (p_building, trim(p_name), nullif(trim(p_location), ''), coalesce(nullif(p_kind, ''), 'smoke_co'), coalesce(nullif(p_power, ''), 'ten_year'),
            nullif(trim(p_unit), ''), nullif(trim(p_photo), ''), p_installed, coalesce((select max(sort) + 10 from alarm_points where building = p_building and unit_number is null), 10))
    returning id into v_id;
  else
    update alarm_points set name = trim(p_name), location = nullif(trim(p_location), ''), kind = coalesce(nullif(p_kind, ''), kind),
           power = coalesce(nullif(p_power, ''), power), unit_number = nullif(trim(p_unit), ''), installed_on = p_installed,
           active = coalesce(p_active, active), photo_path = coalesce(nullif(trim(p_photo), ''), photo_path)
     where id = p_id returning id into v_id;
    if v_id is null then raise exception 'Alarm not found.'; end if;
  end if;
  return v_id;
end;
$$;
revoke all on function alarm_point_save(uuid, text, text, text, text, text, text, boolean, text, date) from public, anon;
grant execute on function alarm_point_save(uuid, text, text, text, text, text, text, boolean, text, date) to authenticated;

-- "All the rest work" covers the monthly (common-area) alarms only; unit alarms are checked one by one.
create or replace function alarm_check_all_ok(p_building text)
returns int
language plpgsql volatile security definer set search_path = public as $$
declare v_n int; v_month date := date_trunc('month', now() at time zone 'America/Chicago')::date;
begin
  if not alarm_can_check() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if p_building is not null and p_building not in ('6622', '6626') then raise exception 'Choose the building.'; end if;
  insert into alarm_checks (alarm_id, check_month, findings, status, checked_by)
  select p.id, v_month, array['sounded'], 'ok', auth.email()
    from alarm_points p
   where p.active and p.unit_number is null and (p_building is null or p.building = p_building)
     and not exists (select 1 from alarm_checks c where c.alarm_id = p.id and c.check_month = v_month);
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;
revoke all on function alarm_check_all_ok(text) from public, anon;
grant execute on function alarm_check_all_ok(text) to authenticated;

-- Report: the monthly grid shows the common-area alarms; unit alarms get their own table (yearly and at each new tenant).
create or replace function alarm_report_html(p_from timestamptz, p_to timestamptz, p_name text, p_org text)
returns text
language plpgsql stable security definer set search_path = public as $$
declare
  v_html text; v_months date[]; v_b text; v_rows text; v_n int; v_att int; v_fixed int; v_ok int; v_missed int;
  fmt constant text := 'FMMM/FMDD/YYYY';
  tz constant text := 'America/Chicago';
  td constant text := '<td style="padding:5px 8px;border-bottom:1px solid #ddd';
  th constant text := '<th style="text-align:left;padding:5px 8px;border-bottom:2px solid #999">';
begin
  select coalesce(array_agg(m order by m), '{}') into v_months from (
    select distinct m from (
      select g::date m from generate_series(date_trunc('month', p_from at time zone tz), date_trunc('month', p_to at time zone tz), interval '1 month') g
       where (g::timestamp + interval '5 days') at time zone tz > p_from and g::timestamp at time zone tz <= p_to
      union
      select c.check_month from alarm_checks c join alarm_points p on p.id = c.alarm_id
       where p.unit_number is null and c.checked_at > p_from and c.checked_at <= p_to) s) t;

  select count(*), count(*) filter (where status = 'attention'), count(*) filter (where status = 'fixed'), count(*) filter (where status = 'ok')
    into v_n, v_att, v_fixed, v_ok from alarm_checks where checked_at > p_from and checked_at <= p_to;

  select count(*) into v_missed from alarm_points p cross join unnest(v_months) m
   where p.unit_number is null
     and (p.active or exists (select 1 from alarm_checks c where c.alarm_id = p.id and c.checked_at > p_from and c.checked_at <= p_to))
     and p.created_at <= (m::timestamp + interval '1 month') at time zone tz
     and not exists (select 1 from alarm_checks c where c.alarm_id = p.id and c.check_month = m and c.checked_at > p_from and c.checked_at <= p_to);

  v_html := '<div style="font:15px/1.45 Arial,Helvetica,sans-serif;color:#1d2433;max-width:900px">'
    || '<h2 style="margin:0 0 4px">Smoke and carbon monoxide alarm check report</h2>'
    || '<div style="color:#555">6622 and 6626 N Bourbon St, Milwaukee, WI 53224 · 2nd Chance Housing Inc.</div>'
    || '<p style="margin:12px 0"><b>Period:</b> ' || to_char(p_from at time zone tz, fmt) || ' to ' || to_char(p_to at time zone tz, fmt)
    || coalesce('<br><b>Prepared for:</b> ' || repair_esc(nullif(trim(p_name), '')) || coalesce(', ' || repair_esc(nullif(trim(p_org), '')), ''), '')
    || '<br><b>Alarms:</b> combination smoke and carbon monoxide alarms with sealed 10-year batteries.'
    || '<br><b>How we check:</b> between the 1st and the 5th of every month, a staff member presses the test button on each alarm in the halls, stairs and basements and records what they found. '
    || 'The alarm inside each unit 2nd Chance Housing owns is tested once a year and whenever a new tenant moves in.</p>';

  if v_n = 0 then
    v_html := v_html || '<p><b>No checks were recorded in this period.</b></p>';
  else
    v_html := v_html || '<p><b>Summary:</b> ' || v_n || ' check' || case when v_n = 1 then '' else 's' end || '. '
      || v_ok || ' worked with nothing wrong; ' || v_fixed || ' had a problem fixed on the spot; ' || v_att || ' needed more work'
      || case when v_missed > 0 then '; ' || v_missed || ' monthly hall check' || case when v_missed = 1 then '' else 's' end || ' not done' else '' end || '.</p>';

    if cardinality(v_months) > 0 then
      foreach v_b in array array['6622', '6626'] loop
        select string_agg(
            '<tr>' || td || '"><b>' || repair_esc(p.name) || '</b>'
            || case when p.installed_on is not null then '<br><span style="color:#666;font-size:12px">Installed ' || to_char(p.installed_on, 'FMMM/YYYY') || ', replace by ' || to_char(p.installed_on + interval '10 years', 'FMMM/YYYY') || '</span>' else '' end || '</td>'
            || (select string_agg(
                  coalesce((select td || ';text-align:center;white-space:nowrap;'
                      || case c.status when 'ok' then 'color:#1a7f37">✓ OK' when 'fixed' then 'color:#0b5cad">✓ Fixed' else 'color:#b42318;font-weight:bold">⚠ Needs work' end
                      || '<br><span style="color:#666;font-size:12px">' || to_char(c.checked_at at time zone tz, 'FMMM/FMDD') || '</span></td>'
                    from alarm_checks c where c.alarm_id = p.id and c.check_month = m and c.checked_at > p_from and c.checked_at <= p_to
                    order by c.checked_at desc limit 1),
                  case when p.created_at > (m::timestamp + interval '1 month') at time zone tz then td || ';text-align:center;color:#999">n/a</td>'
                    else td || ';text-align:center;color:#b42318">not checked</td>' end), '' order by m)
                from unnest(v_months) m)
            || '</tr>', '' order by p.sort, p.name)
          into v_rows
          from alarm_points p
         where p.building = v_b and p.unit_number is null
           and (p.active or exists (select 1 from alarm_checks c where c.alarm_id = p.id and c.checked_at > p_from and c.checked_at <= p_to));
        if v_rows is not null then
          v_html := v_html || '<h3 style="margin:18px 0 6px">' || v_b || ' N Bourbon St: halls, stairs and basement (monthly)</h3>'
            || '<table style="border-collapse:collapse;font-size:14px;width:100%"><tr>' || th || 'Alarm</th>'
            || (select string_agg('<th style="padding:5px 8px;border-bottom:2px solid #999">' || to_char(m, 'Mon YYYY') || '</th>', '' order by m) from unnest(v_months) m)
            || '</tr>' || v_rows || '</table>';
        end if;
      end loop;
    end if;

    -- Unit alarms: every check in the period, or the last one before it.
    select string_agg('<tr>' || td || '"><b>' || repair_esc(p.name) || '</b>'
        || case when p.installed_on is not null then '<br><span style="color:#666;font-size:12px">Installed ' || to_char(p.installed_on, 'FMMM/YYYY') || ', replace by ' || to_char(p.installed_on + interval '10 years', 'FMMM/YYYY') || '</span>' else '' end || '</td>'
        || td || '">' || coalesce((select string_agg(to_char(c.checked_at at time zone tz, fmt) || ': '
              || case c.status when 'ok' then '<span style="color:#1a7f37">✓ OK</span>' when 'fixed' then '<span style="color:#0b5cad">✓ Fixed</span>' else '<b style="color:#b42318">⚠ Needs work</b>' end, '<br>' order by c.checked_at)
            from alarm_checks c where c.alarm_id = p.id and c.checked_at > p_from and c.checked_at <= p_to),
          coalesce('<span style="color:#666">No check in this period. Last check ' || (select to_char(max(c.checked_at) at time zone tz, fmt) from alarm_checks c where c.alarm_id = p.id) || '.</span>',
                   '<span style="color:#666">No check on record yet.</span>')) || '</td></tr>', '' order by p.building, p.sort)
      into v_rows
      from alarm_points p where p.unit_number is not null and p.active;
    if v_rows is not null then
      v_html := v_html || '<h3 style="margin:18px 0 6px">Alarms inside the units (yearly and at each new tenant)</h3>'
        || '<table style="border-collapse:collapse;font-size:14px;width:100%"><tr>' || th || 'Unit</th>' || th || 'Checks</th></tr>' || v_rows || '</table>';
    end if;

    select string_agg('<tr>' || td || ';white-space:nowrap">' || to_char(c.checked_at at time zone tz, fmt) || '</td>'
        || td || '">' || p.building || ' · ' || repair_esc(p.name) || '</td>'
        || td || '">' || repair_esc((select string_agg(alarm_finding_label(f), ', ') from unnest(c.findings) f))
        || coalesce('<br><i>' || repair_esc(c.notes) || '</i>', '') || '</td>'
        || td || ';white-space:nowrap">' || case c.status when 'fixed' then 'Fixed' else '<b style="color:#b42318">Needs work</b>' end || '</td></tr>',
        '' order by c.checked_at)
      into v_rows
      from alarm_checks c join alarm_points p on p.id = c.alarm_id
     where c.checked_at > p_from and c.checked_at <= p_to and c.status <> 'ok';
    if v_rows is not null then
      v_html := v_html || '<h3 style="margin:18px 0 6px">Problems found and what was done</h3>'
        || '<table style="border-collapse:collapse;font-size:14px;width:100%"><tr>' || th || 'Date</th>' || th || 'Alarm</th>' || th || 'Found / done</th>' || th || 'Result</th></tr>'
        || v_rows || '</table>';
    end if;
  end if;

  return v_html || '<p style="color:#555;margin-top:18px">Questions: reply to this email, or write to info@2ndchinc.org.<br>2nd Chance Housing Inc., 6626 N Bourbon St, Milwaukee, WI 53224</p></div>';
end;
$$;
revoke all on function alarm_report_html(timestamptz, timestamptz, text, text) from public, anon;
