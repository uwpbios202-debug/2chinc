-- eFile list: say WHY in plain words (Stephen, 11/11/2026: "Do not file means why? they paid or something?").
-- Each served-or-sent eviction notice gets one status, in this order:
--   paid        rent is paid: nothing to file
--   filed       case number recorded
--   submitted   sent to the court, waiting for accepted/rejected
--   not_served  the mailing (certified-mail stamp date) was never recorded
--   waiting     cure period not over yet
--   stop        a real problem with the notice or the papers (first STOP title shown)
--   ready       no STOP: go through the checklist
create or replace function efile_list()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_today date := (now() at time zone 'America/Chicago')::date;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(x.j || jsonb_build_object('status', x.status, 'reason', x.reason) order by x.sent_at desc) from (
    select n.sent_at,
      jsonb_build_object('id', n.id, 'template_name', n.template_name, 'label', coalesce(u.address, l.rental_label) || ' — ' || l.tenants_label,
        'served_on', n.served_on, 'cure_deadline', n.cure_deadline, 'efile_on', n.efile_on, 'case_number', n.case_number, 'court_at', n.court_at,
        'submitted_at', n.efile_submitted_at, 'stops', (c->>'stops')::int, 'rent_due', (c->'type'->>'rent_due')::numeric) j,
      case when n.case_number is not null then 'filed'
           when n.efile_submitted_at is not null then 'submitted'
           when coalesce((c->>'nonpay')::boolean, false) and coalesce((c->'type'->>'rent_due')::numeric, 0) <= 0 then 'paid'
           when n.served_on is null then 'not_served'
           when n.efile_on is not null and v_today < n.efile_on then 'waiting'
           when (c->>'stops')::int > 0 then 'stop'
           else 'ready' end status,
      case when n.case_number is not null then 'Case ' || n.case_number
           when n.efile_submitted_at is not null then 'Submitted ' || to_char(n.efile_submitted_at at time zone 'America/Chicago', 'FMMonth FMDD') || ', waiting for the court'
           when coalesce((c->>'nonpay')::boolean, false) and coalesce((c->'type'->>'rent_due')::numeric, 0) <= 0 then 'Rent is paid. Nothing to file.'
           when n.served_on is null then 'The mailing was never recorded. Enter the certified-mail stamp date on the Notices page (or, if it was never mailed, it cannot be filed on).'
           when n.efile_on is not null and v_today < n.efile_on then 'Cure period not over. First day to file: ' || to_char(n.efile_on, 'FMDay, FMMonth FMDD')
           when (c->>'stops')::int > 0 then (select string_agg(s->>'title', '; ') from jsonb_array_elements(c->'checks') s where s->>'level' = 'stop')
           else 'No problems found. Go through the checklist.' end reason
    from notices n join leases l on l.id = n.lease_id left join rental_units u on u.id = l.unit_id
    cross join lateral (select efile_core(n.id) c) k
   where n.status = 'sent' and not coalesce(n.voided, false) and notice_days(n.id) is not null
     and (n.case_number is null or n.court_at is null or n.court_at > now() - interval '60 days')
     and n.sent_at > now() - interval '180 days') x), '[]'::jsonb);
end;
$$;
revoke all on function efile_list() from public, anon;
grant execute on function efile_list() to authenticated;
