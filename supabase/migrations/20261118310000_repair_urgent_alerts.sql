-- Urgent repair alerts for every unit (Stephen, 11/5/2026).
--   A repair is "waiting" while it is open and nobody but the tenant has posted on it (no office or owner update yet).
--   Heat repairs from October through April are URGENT.
--   Who must respond: the owner for units in repair_owner_handles_units (today 16), otherwise 2nd Chance.
--   * Owner portal Alerts: a red alert while a repair the owner handles is waiting (built in the page from owner_repairs_mine()).
--   * Staff Maintenance page: a red banner for every waiting repair, any unit (repair_alerts_staff()).
--   * Every 15 minutes: an URGENT heat repair still waiting after 4 hours emails the office once ("No response"), so someone calls.
--     The job then calls outbox-flush (x-cycle-secret, copied from the existing bank-sync job so the secret is never in git).

alter table maintenance_requests add column if not exists escalated_at timestamptz;

insert into portal_settings (key, value) values ('repair_escalate_hours', '4') on conflict (key) do nothing;

create or replace function repair_heat_season() returns boolean
language sql stable as $$ select extract(month from now() at time zone 'America/Chicago') in (10, 11, 12, 1, 2, 3, 4); $$;

create or replace function repair_waiting(p_request uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select r.status not in ('completed', 'closed', 'deferred')
     and not exists (select 1 from maintenance_request_updates u where u.request_id = r.id and not coalesce(u.from_resident, false))
    from maintenance_requests r where r.id = p_request;
$$;

create or replace function repair_alerts_staff() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'number', r.number, 'unit', repair_unit_number(r.id), 'subject', r.subject,
      'category', repair_category_label(r.category), 'urgent', r.category = 'heat' and repair_heat_season(),
      'owner_handles', repair_owner_handles(r.id), 'since', r.created_at, 'escalated_at', r.escalated_at)
      order by (r.category = 'heat') desc, r.created_at)
    from maintenance_requests r where r.status not in ('completed', 'closed', 'deferred') and repair_waiting(r.id)), '[]'::jsonb);
end;
$$;

-- Returns how many office emails it queued.
create or replace function repair_heat_escalate() returns int
language plpgsql security definer set search_path = public as $$
declare r maintenance_requests; v_n int := 0; v_unit text; v_owner boolean; v_hours numeric := coalesce(nullif(condo_setting('repair_escalate_hours', '4'), '')::numeric, 4);
begin
  if not repair_heat_season() then return 0; end if;
  for r in select * from maintenance_requests m where m.category = 'heat' and m.escalated_at is null and m.status not in ('completed', 'closed', 'deferred')
             and m.created_at < now() - make_interval(secs => (v_hours * 3600)::int) and repair_waiting(m.id) loop
    v_unit := repair_unit_number(r.id); v_owner := repair_owner_handles(r.id);
    insert into email_outbox (to_email, subject, html, kind)
    select value, 'URGENT: no response on no-heat repair #' || r.number || ' — Unit ' || coalesce(v_unit, '?') || case when v_owner then ' (owner handles)' else '' end,
      '<p><b>Nobody has responded to this heat repair for ' || floor(extract(epoch from now() - r.created_at) / 3600) || ' hours.</b></p>' ||
      '<p><b>' || repair_esc(r.subject) || '</b>, Unit ' || repair_esc(coalesce(v_unit, '?')) || ', sent ' ||
      to_char(r.created_at at time zone 'America/Chicago', 'FMMM/FMDD FMHH12:MI AM') || '.</p><p>' || repair_esc(r.description) || '</p>' ||
      case when v_owner then '<p>The <b>owner</b> is responsible for repairs in this unit and has not posted an update. Please call the owner.</p>'
           else '<p>2nd Chance is responsible for this unit. Text the HVAC technician from the Maintenance page and post an update.</p>' end ||
      '<p>Open the Maintenance page: https://2ndchinc.org/maintenance/</p>', 'repair_escalation'
      from portal_settings where key = 'office_email';
    update maintenance_requests set escalated_at = now() where id = r.id;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

revoke all on function repair_waiting(uuid), repair_heat_escalate() from public, anon, authenticated;
grant execute on function repair_waiting(uuid), repair_heat_escalate() to service_role;
revoke all on function repair_alerts_staff() from public, anon;
grant execute on function repair_alerts_staff() to authenticated, service_role;

-- The job: escalate, and when something was queued, send it right away through outbox-flush.
do $do$
declare v_secret text;
begin
  select substring(command from $r$'x-cycle-secret', '([^']+)'$r$) into v_secret from cron.job where jobname = 'bank-sync';
  if v_secret is null then raise exception 'Could not find the cycle secret on the bank-sync job'; end if;
  perform cron.unschedule('repair-heat-escalate') where exists (select 1 from cron.job where jobname = 'repair-heat-escalate');
  perform cron.schedule('repair-heat-escalate', '*/15 * * * *', format($c$
    select case when repair_heat_escalate() > 0 then net.http_post(url := 'https://hvnsgwfcjpakvhhkfsuy.supabase.co/functions/v1/outbox-flush',
      headers := jsonb_build_object('Content-Type', 'application/json', 'x-cycle-secret', %L), body := '{}'::jsonb) end;
  $c$, v_secret));
end;
$do$;
