-- Smoke alarms (Stephen, 11/5/2026):
--  1. A reminder to info@2ndchinc.org on the 1st of each month: the hall check is due by the 5th, plus any unit alarm that is due
--     (yearly, or a new tenant). Queued just before the daily rent-cycle run, which sends the outbox.
--  2. Units 8, 12 and 18 (managed by 2nd Chance, not owned) get the in-unit alarm too, like 2nd Chance's own units:
--     smoke/CO combo, sealed 10-year battery, ceiling outside the BR1 door; yearly and at each new tenant.

insert into alarm_points (building, name, location, kind, power, unit_number, sort)
select split_part(cu.address, ' ', 1), 'Unit ' || cu.unit_number || ': outside BR1 door',
       'Ceiling outside the BR1 door (covers both bedrooms; the doors are less than 6 feet apart)', 'smoke_co', 'ten_year', cu.unit_number,
       200 + nullif(regexp_replace(cu.unit_number, '\D', '', 'g'), '')::int
  from condo_units cu
 where cu.unit_number in ('8', '12', '18')
   and split_part(cu.address, ' ', 1) in ('6622', '6626')
   and not exists (select 1 from alarm_points a where a.unit_number = cu.unit_number);

create or replace function alarm_monthly_reminder()
returns int
language plpgsql volatile security definer set search_path = public as $$
declare
  v_today date := (now() at time zone 'America/Chicago')::date;
  v_mon text := trim(to_char(v_today, 'Month'));
  v_halls text; v_units text; v_replace text;
begin
  if extract(day from v_today) <> 1 then return 0; end if;   -- runs at 5 and 6 UTC; only the run that falls on the 1st in Central time sends
  if exists (select 1 from email_outbox where kind = 'alarm_reminder' and created_at >= date_trunc('month', now() at time zone 'America/Chicago') at time zone 'America/Chicago') then return 0; end if;

  select string_agg('<b>' || b || ' N Bourbon St:</b> ' || names, '<br>' order by b) into v_halls from (
    select building b, string_agg(name, ' → ' order by sort, name) names from alarm_points where active and unit_number is null group by building) s;
  select string_agg('<li>' || repair_esc(p.name) || ' (' || p.building || '): ' || repair_esc(alarm_unit_due(p.id)->>'reason') || '</li>', '' order by p.building, p.sort)
    into v_units from alarm_points p where p.active and p.unit_number is not null and alarm_unit_due(p.id) is not null;
  select string_agg('<li>' || p.building || ' · ' || repair_esc(p.name) || ': replace by ' || to_char(p.installed_on + interval '10 years', 'FMMM/YYYY') || '</li>', '' order by p.installed_on)
    into v_replace from alarm_points p where p.active and p.installed_on is not null and p.installed_on + interval '10 years' < v_today + interval '6 months';

  insert into email_outbox (to_email, subject, html, kind) values ('info@2ndchinc.org',
    'Smoke alarm check due by ' || v_mon || ' 5',
    '<p>The monthly smoke alarm walk-around is due between ' || v_mon || ' 1 and 5.</p>'
    || '<p>Press each alarm''s test button in this order. Stop only at one that does not work and tap <b>Problem</b>; at the end tap <b>✓ All the rest work</b>.</p>'
    || '<p>' || coalesce(v_halls, '') || '</p>'
    || coalesce('<p><b>Unit alarms due</b> (yearly or new tenant; give the tenant notice before going in):</p><ul>' || v_units || '</ul>', '')
    || coalesce('<p><b>Alarms to replace soon</b> (10 years from installation):</p><ul>' || v_replace || '</ul>', '')
    || '<p>Open the checklist: https://2ndchinc.org/staff/alarms/</p>',
    'alarm_reminder');
  return 1;
end;
$$;
revoke all on function alarm_monthly_reminder() from public, anon, authenticated;

-- 5:00 and 6:00 UTC on the 1st: one of them is just after midnight Central (summer or winter), a minute before the
-- rent-cycle run that sends the outbox.
select cron.unschedule('alarm-reminder-a') where exists (select 1 from cron.job where jobname = 'alarm-reminder-a');
select cron.unschedule('alarm-reminder-b') where exists (select 1 from cron.job where jobname = 'alarm-reminder-b');
select cron.schedule('alarm-reminder-a', '0 5 1 * *', 'select alarm_monthly_reminder()');
select cron.schedule('alarm-reminder-b', '0 6 1 * *', 'select alarm_monthly_reminder()');
