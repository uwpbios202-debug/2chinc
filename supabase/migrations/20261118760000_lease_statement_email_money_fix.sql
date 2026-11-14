-- Fix: money format in lease_statement_email (the ";" negative section is not a Postgres format). Shows $825.00 and -$825.00.
create or replace function lease_money(p numeric) returns text language sql immutable set search_path = public as $m$ select case when p < 0 then '-$' || to_char(abs(p), 'FM999,990.00') else '$' || to_char(coalesce(p, 0), 'FM999,990.00') end $m$;
revoke all on function lease_money(numeric) from public, anon, authenticated;

create or replace function lease_statement_email(p_lease uuid, p_to text, p_message text)
returns void language plpgsql volatile security definer set search_path = public as $$
declare v_by text := lower(auth.email()); v_to text := lower(trim(coalesce(p_to, ''))); l record; v_rows text; v_bal numeric;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select le.id, le.account_number, le.tenants_label, ru.address into l from leases le join rental_units ru on ru.id = le.unit_id where le.id = p_lease;
  if l.id is null then raise exception 'That lease isn''t on file.'; end if;
  if v_to !~ '^[^@\s<>,;]+@[^@\s<>,;]+\.[a-z]{2,}$' then raise exception 'Enter one email address.'; end if;
  if (select count(*) from lease_statement_emails where sent_by = v_by and created_at > now() - interval '1 day') >= 20 then
    raise exception 'That''s 20 statements today; please try again tomorrow.'; end if;
  select string_agg('<tr><td>' || to_char(x.entry_date, 'FMMM/FMDD/YYYY') || '</td><td>' || repair_esc(case when x.kind = 'in_kind' then 'Work in lieu of rent' else coalesce(x.raw_type, '') end)
      || '<br><span style="color:#666">' || repair_esc(coalesce(x.description, '')) || '</span></td><td align="right">' || lease_money(x.amount)
      || '</td><td align="right">' || lease_money(x.run) || '</td></tr>', '' order by x.entry_date, x.id),
    (array_agg(x.run order by x.entry_date desc, x.id desc))[1]
    into v_rows, v_bal
    from (select e.*, sum(e.amount) over (order by e.entry_date, e.id) run from lease_ledger_entries e where e.lease_id = p_lease) x;
  insert into email_outbox (to_email, subject, html, kind) values (v_to, 'Account statement — ' || l.address,
    case when length(trim(coalesce(p_message, ''))) > 0 then '<p style="white-space:pre-wrap;border-left:3px solid #ccc;padding-left:10px">' || repair_esc(left(trim(p_message), 1500)) || '</p>' else '' end
    || '<p>Account ' || repair_esc(coalesce(l.account_number, '')) || ' · ' || repair_esc(l.address) || ' · ' || repair_esc(coalesce(l.tenants_label, '')) || '</p>'
    || '<table cellpadding="6" style="border-collapse:collapse;font:14px Arial" border="1" bordercolor="#ddd"><tr><th align="left">Date</th><th align="left">Memo</th><th align="right">Amount</th><th align="right">Balance</th></tr>'
    || coalesce(v_rows, '<tr><td colspan="4">No ledger lines yet.</td></tr>') || '</table>'
    || '<p><b>Current balance: ' || lease_money(v_bal) || '</b></p><p>2nd Chance Housing</p>',
    'lease_statement');
  insert into lease_statement_emails (lease_id, sent_by, to_email) values (p_lease, v_by, v_to);
end;
$$;
revoke all on function lease_statement_email(uuid, text, text) from public, anon;
grant execute on function lease_statement_email(uuid, text, text) to authenticated;
