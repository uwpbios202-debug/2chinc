-- Parking launch (Stephen, 11/8/2026: "time to send the parking emails and send me an email at 12:01 with the tracking").
--   * parking_launch_emails(): one email to every tenant on an active lease, and one per owner covering all their units (lives there /
--     no tenant / tenant / owner-managed Unit 6). 2nd Chance Housing itself (company_owner_id) is skipped. Runs once (setting
--     parking_launch_sent_at); it is called by hand, never by this migration.
--   * parking_launch_report(): every night at 12:01 a.m. Central until patrols start (11/20, last report 11/21), the admins get a table:
--     per stall, each person emailed, whether the email was delivered or opened, whether they signed in to the portal since the launch,
--     the vehicle registered or "no vehicle", and whether they signed the parking rules.
--   * outbox_flush_now(): sends queued email at once, using the cycle secret already stored in the repair-heat-escalate job (the secret is
--     read at run time and never written here).
-- No new table, so no new grants.

create or replace function outbox_flush_now()
returns void
language plpgsql volatile security definer set search_path = public as $$
declare v_secret text := substring((select command from cron.job where jobname = 'repair-heat-escalate') from 'x-cycle-secret'', ''([0-9a-f]+)''');
begin
  if v_secret is null then raise exception 'Cycle secret not found in the repair-heat-escalate job.'; end if;
  perform net.http_post(url := 'https://hvnsgwfcjpakvhhkfsuy.supabase.co/functions/v1/outbox-flush',
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-cycle-secret', v_secret), body := '{}'::jsonb);
end;
$$;
revoke all on function outbox_flush_now() from public, anon, authenticated;

create or replace function parking_launch_wrap(p_first text, p_body text)
returns text language sql immutable as $$
  select '<div style="font-family:Arial,sans-serif;max-width:640px;color:#1b2430;line-height:1.5"><p>Hi ' || repair_esc(coalesce(nullif(p_first, ''), 'there')) || ',</p>' || p_body
    || '<p>Questions: reply to this email or call (262) 236-5443.</p><p>2nd Chance Housing</p></div>';
$$;

create or replace function parking_launch_emails()
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  v_intro text := '<p>Starting <b>Friday, November 20, 2026</b>, Always Towing &amp; Recovery will patrol the parking lot at 6622 and 6626 N Bourbon St. '
    || 'Each numbered stall belongs to the unit with that number. A vehicle in a stall that is not registered to that unit will be towed at the vehicle owner''s expense ($400 to $500).</p>';
  v_steps text := '<ol style="padding-left:20px"><li><b>Register your vehicle</b>: make, model, color, plate, and a photo of the front and the back. No vehicle? Choose "I don''t have a vehicle".</li>'
    || '<li><b>Sign the parking rules</b>: initial each rule and fine, then record yourself reading one sentence.</li></ol><p>It takes about 3 minutes on your phone.</p>';
  v_guest_owner text := '<p>Guests may park only in your own stall. If someone is parked in your stall, use "Someone in my stall?" on the Parking tab.</p>';
  v_guest text := '<p>Guests park only in your stall, with a guest parking pass (Guests tab). If someone is parked in your stall, use "Someone in my stall?" on the Parking tab.</p>';
  r record; o record; v_body text; v_lives text[]; v_vacant text[]; v_tenanted text[]; v_direct text[]; nt int := 0; no int := 0;
begin
  if condo_setting('parking_launch_sent_at', '') <> '' then raise exception 'The parking emails were already sent (%).', condo_setting('parking_launch_sent_at', ''); end if;

  -- A. Tenants on an active lease.
  for r in select distinct on (lower(t.email)) lower(t.email) email, t.name, ru.unit_number from leases l join rental_units ru on ru.id = l.unit_id
             join lease_tenants lt on lt.lease_id = l.id join tenants t on t.id = lt.tenant_id where l.status = 'active' and t.email like '%@%' order by lower(t.email) loop
    insert into email_outbox (to_email, subject, html, kind) values (r.email, 'Parking: register your vehicle and sign the parking rules by Wednesday, November 18',
      parking_launch_wrap(split_part(r.name, ' ', 1), v_intro
        || '<p><b>By Wednesday, November 18</b>, please do two things on your Parking tab: <a href="https://2ndchinc.org/resident/#parking">https://2ndchinc.org/resident/#parking</a></p>'
        || v_steps || v_guest), 'parking_launch');
    nt := nt + 1;
  end loop;

  -- B-D. Owners (one email each), except 2nd Chance Housing itself.
  for o in select ow.id, lower(ow.email) email, ow.name from condo_owners ow
            where ow.email like '%@%' and ow.id::text is distinct from condo_setting('company_owner_id', '')
              and exists (select 1 from condo_ownerships s where s.is_current and s.owner_id = ow.id) loop
    select array_agg(cu.unit_number order by cu.unit_number::int) filter (where cu.unit_number = any (owner_direct_unit_list())),
           array_agg(cu.unit_number order by cu.unit_number::int) filter (where cu.unit_number <> all (owner_direct_unit_list()) and cu.occupancy = 'owner'),
           array_agg(cu.unit_number order by cu.unit_number::int) filter (where cu.unit_number <> all (owner_direct_unit_list()) and cu.occupancy <> 'owner'
             and exists (select 1 from leases l join rental_units ru on ru.id = l.unit_id where l.status = 'active' and ru.unit_number = cu.unit_number)),
           array_agg(cu.unit_number order by cu.unit_number::int) filter (where cu.unit_number <> all (owner_direct_unit_list()) and cu.occupancy <> 'owner'
             and not exists (select 1 from leases l join rental_units ru on ru.id = l.unit_id where l.status = 'active' and ru.unit_number = cu.unit_number))
      into v_direct, v_lives, v_tenanted, v_vacant
      from condo_ownerships s join condo_units cu on cu.id = s.unit_id where s.is_current and s.owner_id = o.id;
    v_body := v_intro;
    if v_lives is not null then
      v_body := v_body || '<p><b>You live in Unit ' || array_to_string(v_lives, ', ') || '.</b> By Wednesday, November 18, please do two things on the Parking tab of your owner portal: '
        || '<a href="https://2ndchinc.org/association-owners/roca1/#parking">https://2ndchinc.org/association-owners/roca1/#parking</a></p>' || v_steps || v_guest_owner;
    end if;
    if v_vacant is not null then
      v_body := v_body || '<p><b>Unit' || case when cardinality(v_vacant) > 1 then 's ' else ' ' end || array_to_string(v_vacant, ' and ') || ' ha' || case when cardinality(v_vacant) > 1 then 've' else 's' end || ' no tenant.</b> '
        || 'If anyone parks in stall ' || array_to_string(v_vacant, ' or ') || ', register that vehicle on the Parking tab of your owner portal, or choose "No vehicle", and sign the parking rules there: '
        || '<a href="https://2ndchinc.org/association-owners/roca1/#parking">https://2ndchinc.org/association-owners/roca1/#parking</a></p>';
    end if;
    if v_tenanted is not null then
      v_body := v_body || '<p><b>Unit ' || array_to_string(v_tenanted, ', ') || ':</b> your tenant has been emailed the same instructions. Please remind them to register their vehicle and sign the parking rules by Wednesday, November 18. '
        || 'From November 20, a vehicle not registered to the unit''s stall can be towed.</p>';
    end if;
    if v_direct is not null then
      v_body := v_body || '<p><b>Unit ' || array_to_string(v_direct, ', ') || ':</b> your tenant must register their vehicle and sign the parking rules too. On the <b>Tenant</b> tab of your owner portal '
        || '(<a href="https://2ndchinc.org/association-owners/roca1/#tenant">https://2ndchinc.org/association-owners/roca1/#tenant</a>), add them and click <b>Give access</b>. '
        || 'They sign in at <a href="https://2ndchinc.org/unit-access/">https://2ndchinc.org/unit-access/</a> and do both steps on their Parking tab by Wednesday, November 18.</p>';
    end if;
    insert into email_outbox (to_email, subject, html, kind) values (o.email,
      case when v_lives is not null then 'Parking: register your vehicle and sign the parking rules by Wednesday, November 18'
           else 'Parking at 6622-6626 N Bourbon St: vehicles must be registered by Wednesday, November 18' end,
      parking_launch_wrap(split_part(o.name, ' ', 1), v_body), 'parking_launch');
    no := no + 1;
  end loop;

  insert into portal_settings (key, value) values ('parking_launch_sent_at', now()::text) on conflict (key) do update set value = excluded.value;
  perform outbox_flush_now();
  return jsonb_build_object('tenants', nt, 'owners', no);
end;
$$;
revoke all on function parking_launch_emails() from public, anon, authenticated;

-- The nightly report.
create or replace function parking_launch_report()
returns int
language plpgsql volatile security definer set search_path = public as $$
declare
  v_today date := (now() at time zone 'America/Chicago')::date; v_launch timestamptz := nullif(condo_setting('parking_launch_sent_at', ''), '')::timestamptz;
  v_ver text := parking_terms_version(); v_rows text; v_sum text; v_to text; n int := 0;
begin
  if v_launch is null then return 0; end if;
  if v_today > date '2026-11-21' then perform cron.unschedule('parking-launch-report'); return 0; end if;
  with people as (
    select s.home_unit unit, p.email, p.name, p.kind from parking_stalls s cross join lateral (
        select lower(x.email) email, x.name, x.kind from parking_unit_people(s.home_unit) x where x.email like '%@%'
        union
        select lower(o.email), o.name, 'owner' from condo_units cu join condo_ownerships cs on cs.unit_id = cu.id and cs.is_current join condo_owners o on o.id = cs.owner_id
         where cu.unit_number = s.home_unit and o.email like '%@%' and o.id::text is distinct from condo_setting('company_owner_id', '')) p
     where s.kind = 'unit' and s.active),
  rows as (
    select pe.unit, case when pe.kind = 'occupant' then 'Unit ' || pe.unit || ' occupant' else coalesce(pe.name, pe.email) end who,
      case pe.kind when 'tenant' then 'tenant' when 'occupant' then 'Unit 6 person' else
        case when exists (select 1 from condo_units cu where cu.unit_number = pe.unit and cu.occupancy = 'owner') then 'owner (lives there)' else 'owner' end end role,
      (select case when l.bounced_at is not null then 'BOUNCED' when l.first_opened_at is not null then 'opened' when l.delivered_at is not null then 'delivered' when l.id is not null then 'sent' end
         from email_log l where lower(l.to_email) = pe.email and l.kind = 'parking_launch' order by l.id desc limit 1) mail,
      exists (select 1 from email_outbox e where lower(e.to_email) = pe.email and e.kind = 'parking_launch') emailed,
      (select u.last_sign_in_at from auth.users u where lower(u.email) = pe.email and u.last_sign_in_at > v_launch) signed_in,
      exists (select 1 from parking_acks a where lower(a.email) = pe.email and a.unit_number = pe.unit and a.terms_version = v_ver) rules,
      (select string_agg(concat_ws(' ', v.color, v.make, v.model, v.plate), '; ') from vehicles v where v.unit_number = pe.unit and v.status = 'active' and v.kind in ('own', 'loaner')) vehicle,
      exists (select 1 from parking_declarations d where d.unit_number = pe.unit and d.no_vehicle) no_vehicle
    from people pe)
  select string_agg('<tr><td style="padding:4px 8px;border-bottom:1px solid #dde2e8"><b>' || r.unit || '</b></td><td style="padding:4px 8px;border-bottom:1px solid #dde2e8">' || repair_esc(r.who) || '<br><span style="color:#5b6573;font-size:12px">' || r.role || '</span></td>'
      || '<td style="padding:4px 8px;border-bottom:1px solid #dde2e8">' || coalesce(r.mail, case when r.emailed then 'queued' else '<span style="color:#5b6573">not emailed</span>' end) || '</td>'
      || '<td style="padding:4px 8px;border-bottom:1px solid #dde2e8">' || coalesce(to_char(r.signed_in at time zone 'America/Chicago', 'FMMM/FMDD FMHH12:MI AM'), '<span style="color:#b3261e">no</span>') || '</td>'
      || '<td style="padding:4px 8px;border-bottom:1px solid #dde2e8">' || coalesce(repair_esc(r.vehicle), case when r.no_vehicle then 'no vehicle' else '<span style="color:#b3261e">not registered</span>' end) || '</td>'
      || '<td style="padding:4px 8px;border-bottom:1px solid #dde2e8">' || case when r.rules then '<span style="color:#2e7d1f">signed</span>' else '<span style="color:#b3261e">no</span>' end || '</td></tr>',
      '' order by nullif(regexp_replace(r.unit, '\D', '', 'g'), '')::int, r.role desc, r.who),
    count(*) filter (where r.emailed) || ' emailed · ' || count(*) filter (where r.signed_in is not null) || ' signed in since the email · '
      || count(*) filter (where r.rules) || ' signed the rules · ' || count(distinct r.unit) filter (where r.vehicle is not null or r.no_vehicle) || ' of ' || count(distinct r.unit) || ' stalls with people answered (vehicle or no vehicle)'
    into v_rows, v_sum from rows r;
  for v_to in select email from portal_admins loop
    insert into email_outbox (to_email, subject, html, kind) values (v_to, 'Parking tracking ' || to_char(v_today, 'FMMM/FMDD') || ': who signed in, registered and signed',
      '<div style="font-family:Arial,sans-serif;max-width:900px;color:#1b2430"><p><b>Parking tracking</b> as of 12:01 a.m. ' || to_char(v_today, 'FMMM/FMDD/YYYY')
      || '. Emails went out ' || to_char(v_launch at time zone 'America/Chicago', 'FMMM/FMDD FMHH12:MI AM') || '. Register-by date: Wednesday 11/18; patrols start Friday 11/20.</p><p>' || v_sum || '.</p>'
      || '<table style="border-collapse:collapse;font-size:13px"><tr style="text-align:left"><th style="padding:4px 8px">Stall</th><th style="padding:4px 8px">Person</th><th style="padding:4px 8px">Email</th>'
      || '<th style="padding:4px 8px">Signed in to the portal</th><th style="padding:4px 8px">Vehicle</th><th style="padding:4px 8px">Rules</th></tr>' || coalesce(v_rows, '') || '</table>'
      || '<p>Live view: <a href="https://2ndchinc.org/parking/">https://2ndchinc.org/parking/</a> (Stock-take).</p></div>', 'parking_report');
    n := n + 1;
  end loop;
  if n > 0 then perform outbox_flush_now(); end if;
  return n;
end;
$$;
revoke all on function parking_launch_report() from public, anon, authenticated;

select cron.unschedule('parking-launch-report') where exists (select 1 from cron.job where jobname = 'parking-launch-report');
select cron.schedule('parking-launch-report', '1 6 * * *', 'select parking_launch_report()');
