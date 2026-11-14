-- Reminders: a date that was already more than a week overdue when it was first entered (or when this job first saw it) gets one "overdue"
-- email instead of silence. Everything else about the job is unchanged.
create or replace function transfer_deadline_reminders() returns int
language plpgsql security definer set search_path = public as $$
declare cs record; it record; today date := (now() at time zone 'America/Chicago')::date; days int; bucket text; html text; n int := 0; r record;
begin
  for cs in select id, property_address from property_transfer_cases loop
    html := '';
    for it in select * from transfer_case_deadlines(cs.id) loop
      days := it.due - today;
      if days in (7, 3, 1, 0, -1, -7) or days < -7 then
        bucket := it.item_key || ':' || it.due::text || ':' || case when days < -7 then 'late' else days::text end;
        insert into property_transfer_reminders_sent (case_id, key) values (cs.id, bucket) on conflict do nothing;
        if found then
          html := html || '<li><b>' || to_char(it.due, 'FMMM/FMDD/YYYY') || '</b>: ' || replace(replace(it.label, '&', '&amp;'), '<', '&lt;') || ' <i>(' ||
                  case when days > 0 then 'in ' || days || ' day' || case when days = 1 then '' else 's' end when days = 0 then 'today' else (-days) || ' day' || case when days = -1 then '' else 's' end || ' overdue' end || ')</i></li>';
          n := n + 1;
        end if;
      end if;
    end loop;
    if html <> '' then
      for r in select email from property_transfer_access where case_id = cs.id loop
        insert into email_outbox (to_email, subject, html, kind) values (r.email, 'Property transfer case: deadline reminder',
          '<p>These dates on a property transfer case need attention' || case when coalesce(cs.property_address, '') <> '' then ' (' || replace(replace(cs.property_address, '&', '&amp;'), '<', '&lt;') || ')' else '' end || ':</p><ul>' || html ||
          '</ul><p>Open the case: <a href="https://2ndchinc.org/staff/deeds/transfer/">https://2ndchinc.org/staff/deeds/transfer/</a></p><p style="color:#666;font-size:12px">These dates are estimates worked out from the Probate Act and the dates entered on the case. They are not legal advice or court-set deadlines; confirm them with counsel or the court.</p>',
          'transfer_reminder');
      end loop;
    end if;
  end loop;
  return n;
end $$;
revoke all on function transfer_deadline_reminders() from public, anon, authenticated;
