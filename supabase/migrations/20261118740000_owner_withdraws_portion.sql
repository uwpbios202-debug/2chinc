-- Unit 15: the owner WITHDRAWS his portion at the bank instead of being mailed a check (Stephen, 11/11/2026).
-- Mark Postler has a ROCA1 deposit card and can withdraw from ROCA1's account; he goes to the bank regularly. So for the units in
-- portal setting `roca_withdraw_owner_units` (today 15): when the tenant's rent clears, what the unit owes ROCA1 comes out first, then the fee,
-- and the rest is his portion. The office gives him a printed statement (by hand or mail, Print statement on the Rent deductions page) and records
-- the date he withdrew it (button "Withdrawn"). When he owes more than the rent covers, he deposits it himself with his deposit card.
-- payout_method 'withdraw'; the status name 'zelle_due' still means "payout waiting". Unit 16 (Zelle) is unchanged.

insert into portal_settings (key, value) values ('roca_withdraw_owner_units', '15') on conflict (key) do nothing;
update portal_settings set value = '' where key = 'roca_check_owner_units' and replace(value, ' ', '') = '15';

alter table roca_rent_splits drop constraint if exists roca_rent_splits_payout_method_check;
alter table roca_rent_splits add constraint roca_rent_splits_payout_method_check check (payout_method in ('zelle', 'check', 'withdraw'));

create or replace function roca_unit_owner_withdraws(p_unit text)
returns boolean language sql stable security definer set search_path = public as $$
  select coalesce(p_unit = any (string_to_array(replace(coalesce((select value from portal_settings where key = 'roca_withdraw_owner_units'), ''), ' ', ''), ',')), false);
$$;
revoke all on function roca_unit_owner_withdraws(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- The split (latest 20261118680000) with the withdraw payout.
CREATE OR REPLACE FUNCTION public.roca_rent_split_apply(p_lease uuid, p_entry bigint, p_amount numeric, p_paid_on date)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_unit text := roca_split_unit(p_lease, (select e.payment_report_id from lease_ledger_entries e where e.id = p_entry)); o record; t roca_pma_terms; v_acct uuid; r record; take numeric; v_left numeric := p_amount;
  v_ded jsonb := '[]'::jsonb; v_ded_total numeric := 0; v_mgmt numeric := 0; v_ids bigint[] := '{}'; v_id bigint; v_net numeric; v_split uuid;
  v_phone text; v_office text := coalesce(nullif((select value from portal_settings where key = 'office_email'), ''), 'info@2ndchinc.org');
  v_check boolean; v_wd boolean; v_mail text; v_method text := (select e.method from lease_ledger_entries e where e.id = p_entry);
  CAT jsonb := '{"fines_fees":"fines and fees","assessments":"special assessments","dues_current":"association dues","older_balance":"past-due dues"}';
begin
  if v_unit is null or p_amount <= 0 then return null; end if;
  if exists (select 1 from roca_rent_splits where lease_entry_id = p_entry) then return null; end if;
  select * into o from roca_unit_owner_on(v_unit, p_paid_on);
  if o.owner_id is null or o.name ~* '^2nd Chance' then return null; end if;   -- 2nd Chance's own unit: nothing to split
  v_wd := roca_unit_owner_withdraws(v_unit);
  v_check := not v_wd and roca_unit_paid_by_check(v_unit);
  v_mail := case when v_check or v_wd then roca_owner_mail_to(o.owner_id) end;
  v_acct := roca_unit_account(v_unit);
  for r in select * from roca_unit_open_items(v_unit, date_trunc('month', p_paid_on)::date, greatest(p_paid_on, current_date)) loop
    exit when v_left <= 0;
    take := least(v_left, r.open);
    insert into condo_ledger_entries (account_id, gl_account, entry_date, kind, raw_type, method, description, amount, origin, entered_by, correction_note)
    values (v_acct, r.gl_account, p_paid_on, 'payment', 'Payment', 'rent_deduction',
      'Paid from your tenant''s rent (' || coalesce(CAT->>r.category, r.category) || ')', -take, 'staff', 'automation',
      'Tenant rent payment of ' || to_char(p_amount, 'FM$999,990.00') || ' on ' || to_char(p_paid_on, 'FMMM/FMDD/YYYY') || ' went to ROCA1''s account; this is the part applied to your association account.')
    returning id into v_id;
    v_ids := v_ids || v_id;
    v_ded := v_ded || jsonb_build_object('category', r.category, 'gl_account', r.gl_account, 'amount', take);
    v_ded_total := v_ded_total + take; v_left := v_left - take;
  end loop;
  select * into t from roca_pma_terms where unit_number = v_unit;
  v_mgmt := least(greatest(v_left, 0), round(p_amount * (coalesce(t.mgmt_fee_pct, 0)
            + case when v_method in ('stripe_bank', 'stripe_card') then coalesce(t.card_fee_pct, 0) else 0 end) / 100, 2));
  v_net := greatest(v_left - v_mgmt, 0);
  select phone_mobile into v_phone from condo_owners where id = o.owner_id;
  insert into roca_rent_splits (unit_number, owner_id, owner_name, owner_email, owner_phone, lease_id, lease_entry_id, paid_on, rent_amount, to_roca1, deductions, mgmt_fee,
                                net_to_owner, condo_entry_ids, status, payout_method, mail_to)
  values (v_unit, o.owner_id, o.name, o.email, v_phone, p_lease, p_entry, p_paid_on, p_amount, v_ded_total, v_ded, v_mgmt, v_net, v_ids,
          case when v_net > 0 then 'zelle_due' else 'nothing_to_send' end, case when v_wd then 'withdraw' when v_check then 'check' else 'zelle' end, v_mail)
  returning id into v_split;
  if v_net > 0 and v_wd then
    insert into email_outbox (to_email, subject, html, kind) values (v_office, 'Statement for ' || o.name || ' (Unit ' || v_unit || '): portion $' || to_char(v_net, 'FM999,990.00') || ' to withdraw',
      '<p>The tenant''s rent of ' || to_char(p_amount, 'FM$999,990.00') || ' for Unit ' || v_unit || ' cleared into ROCA1''s account.</p><ul><li>Applied to ' || o.name || '''s association account: ' || to_char(v_ded_total, 'FM$999,990.00') || '</li>'
      || case when v_mgmt > 0 then '<li>Payment processing and administrative fee: ' || to_char(v_mgmt, 'FM$999,990.00') || '</li>' else '' end
      || '<li><b>Owner''s portion, which the owner withdraws at the bank: ' || to_char(v_net, 'FM$999,990.00') || '</b></li></ul>'
      || '<p>Within 5 business days, give ' || repair_esc(o.name) || ' the printed statement (by hand, or mail it to: <b>'
      || repair_esc(coalesce(v_mail, '(no mailing address on file)')) || '</b>). Print it from <a href="https://2ndchinc.org/association-owners/roca1/distributions/">Rent deductions</a> (Print statement). '
      || 'When the withdrawal shows on ROCA1''s bank account, click Withdrawn there and enter the date. He may not withdraw more than this amount.</p>', 'roca_withdraw_due');
  elsif v_net > 0 and v_check then
    insert into email_outbox (to_email, subject, html, kind) values (v_office, 'Mail a check for $' || to_char(v_net, 'FM999,990.00') || ' to ' || o.name || ' (Unit ' || v_unit || ')',
      '<p>The tenant''s rent of ' || to_char(p_amount, 'FM$999,990.00') || ' for Unit ' || v_unit || ' cleared.</p><ul><li>Applied to ' || o.name || '''s association account: ' || to_char(v_ded_total, 'FM$999,990.00') || '</li>'
      || case when v_mgmt > 0 then '<li>Management fee: ' || to_char(v_mgmt, 'FM$999,990.00') || '</li>' else '' end
      || '<li><b>To send to the owner by mailed paper check: ' || to_char(v_net, 'FM$999,990.00') || '</b></li></ul>'
      || '<p>This owner is paid by paper check only (no Zelle, nothing electronic). Make the check out to ' || repair_esc(o.name) || ' and mail it to: <b>'
      || repair_esc(coalesce(v_mail, '(no mailing address on file: add it to the owner record before mailing)')) || '</b>. Put a printed statement in the envelope: rent received, what was applied to ROCA1, and the check amount.</p>'
      || '<p>After you mail it, record the date and the check number: <a href="https://2ndchinc.org/association-owners/roca1/distributions/">Rent deductions</a>.</p>', 'roca_check_due');
  elsif v_net > 0 then
    insert into email_outbox (to_email, subject, html, kind) values (v_office, 'Zelle $' || to_char(v_net, 'FM999,990.00') || ' to ' || o.name || ' (Unit ' || v_unit || ')',
      '<p>The tenant''s rent of ' || to_char(p_amount, 'FM$999,990.00') || ' for Unit ' || v_unit || ' cleared.</p><ul><li>Applied to ' || o.name || '''s association account: ' || to_char(v_ded_total, 'FM$999,990.00') || '</li>'
      || case when v_mgmt > 0 then '<li>Management fee: ' || to_char(v_mgmt, 'FM$999,990.00') || '</li>' else '' end
      || '<li><b>To send to the owner by Zelle: ' || to_char(v_net, 'FM$999,990.00') || '</b></li></ul>'
      || '<p>Zelle to ' || repair_esc(o.name) || ': phone ' || repair_esc(coalesce(v_phone, '(none on file)')) || ', email ' || repair_esc(coalesce(o.email, '(none on file)'))
      || '.</p><p>After you send it, record the date and reference: <a href="https://2ndchinc.org/association-owners/roca1/distributions/">Rent deductions</a>.</p>', 'roca_zelle_due');
  end if;
  if o.email is not null then
    insert into email_outbox (to_email, subject, html, kind) values (o.email, 'Unit ' || v_unit || ': your tenant''s rent payment was received',
      '<p>Dear ' || repair_esc(o.name) || ',</p><p>Your tenant''s rent payment of ' || to_char(p_amount, 'FM$999,990.00') || ' (' || to_char(p_paid_on, 'FMMM/FMDD/YYYY') || ') cleared.</p><ul>'
      || '<li>Paid to ROCA1 for your association account: ' || to_char(v_ded_total, 'FM$999,990.00') || '</li>'
      || case when v_mgmt > 0 then '<li>' || case when v_wd then 'Payment processing and administrative fee: ' else 'Management fee: ' end || to_char(v_mgmt, 'FM$999,990.00') || '</li>' else '' end
      || '<li><b>' || case when v_net > 0 and v_wd then 'Your portion, ready to withdraw at the bank: ' when v_net > 0 and v_check then 'Being mailed to you by check: ' when v_net > 0 then 'Being sent to you by Zelle: ' else 'Left for you: ' end || to_char(v_net, 'FM$999,990.00') || '</b></li></ul>'
      || case when v_wd then '<p>Please withdraw no more than this amount. You will also get a printed statement.</p>'
              when v_check then '<p>A printed statement comes in the envelope with your check.</p>' else '<p>See it in the owner portal: https://2ndchinc.org/association-owners/roca1/#statements</p>' end
      || '<p>2nd Chance Housing, for ROCA1</p>', 'roca_rent_split');
  end if;
  return v_split;
end;
$function$;

-- ---------------------------------------------------------------------------
-- Reversal (20261118670000) with withdraw wording.
CREATE OR REPLACE FUNCTION public.roca_rent_split_reverse(p_lease uuid, p_orig_entry bigint, p_amount numeric, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s roca_rent_splits; ratio numeric; e record; v_amt numeric; v_net numeric; v_acct uuid; v_what text;
  v_office text := coalesce(nullif((select value from portal_settings where key = 'office_email'), ''), 'info@2ndchinc.org');
begin
  select * into s from roca_rent_splits where lease_entry_id = p_orig_entry and status <> 'reversed' for update;
  if s.id is null then return; end if;
  v_what := case s.payout_method when 'check' then 'check' when 'withdraw' then 'owner''s withdrawal' else 'Zelle' end;
  ratio := least(p_amount / s.rent_amount, 1 - s.reversed_amount / s.rent_amount);
  if ratio <= 0 then return; end if;
  for e in select * from condo_ledger_entries where id = any (s.condo_entry_ids) loop
    v_amt := round(-e.amount * ratio, 2);
    continue when v_amt <= 0;
    insert into condo_ledger_entries (account_id, gl_account, entry_date, kind, raw_type, method, description, amount, origin, entered_by, correction_note, reverses_entry_id)
    values (e.account_id, e.gl_account, current_date, 'reversal', 'Payment reversed', 'rent_deduction',
            'Tenant rent payment reversed: ' || left(trim(coalesce(p_reason, '')), 80), v_amt, 'staff', 'automation',
            'Reverses the part of the ' || to_char(s.paid_on, 'FMMM/FMDD/YYYY') || ' tenant rent payment that was applied here; original line kept.', e.id);
  end loop;
  v_net := round(s.net_to_owner * ratio, 2);
  update roca_rent_splits set reversed_amount = reversed_amount + p_amount,
    net_to_owner = case when status = 'zelle_due' then greatest(net_to_owner - v_net, 0) else net_to_owner end,
    recovery_due = recovery_due + case when status = 'sent' then v_net else 0 end,
    status = case when reversed_amount + p_amount >= rent_amount then 'reversed'
                  when status = 'zelle_due' and net_to_owner - v_net <= 0 then 'nothing_to_send' else status end
  where id = s.id;
  insert into email_outbox (to_email, subject, html, kind) values (v_office, 'Unit ' || s.unit_number || ': tenant rent payment reversed',
    '<p>The ' || to_char(s.paid_on, 'FMMM/FMDD/YYYY') || ' rent payment for Unit ' || s.unit_number || ' was reversed (' || repair_esc(coalesce(p_reason, '')) || '). The part applied to '
    || repair_esc(s.owner_name) || '''s association account was reversed on the owner''s ledger.'
    || case when s.status = 'sent' and s.payout_method = 'withdraw' then ' <b>The owner already withdrew ' || to_char(v_net, 'FM$999,990.00') || ' of it: he deposits it back, or it comes out of his next portion.</b>'
            when s.status = 'sent' then ' <b>The ' || v_what || ' of ' || to_char(v_net, 'FM$999,990.00') || ' was already sent to the owner: please recover it'
                                        || case when s.payout_method = 'check' then ' (or stop the check if it has not been cashed)' else '' end || '.</b>'
            when s.status = 'zelle_due' and s.payout_method = 'withdraw' then ' The owner''s portion was reduced to ' || to_char(greatest(s.net_to_owner - v_net, 0), 'FM$999,990.00') || '; tell him not to withdraw more than that.'
            when s.status = 'zelle_due' then ' The ' || v_what || ' to the owner was reduced to ' || to_char(greatest(s.net_to_owner - v_net, 0), 'FM$999,990.00') || '; do not send more than that.' else '' end
    || '</p>', 'roca_split_reversed');
end;
$function$;

-- ---------------------------------------------------------------------------
-- Staff record the payout: Zelle reference, check number, or (withdraw) a note such as "seen on bank statement".
CREATE OR REPLACE FUNCTION public.roca_rent_payout_sent(p_id uuid, p_date date, p_reference text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s roca_rent_splits;
begin
  perform roca_staff_check();
  select * into s from roca_rent_splits where id = p_id for update;
  if s.id is null or s.status <> 'zelle_due' then raise exception 'That payout is not waiting to be sent.'; end if;
  if s.payout_method <> 'withdraw' and length(coalesce(trim(p_reference), '')) < 2 then
    raise exception '%', case when s.payout_method = 'check' then 'Enter the check number.' else 'Enter the Zelle confirmation or reference.' end;
  end if;
  update roca_rent_splits set status = 'sent', sent_date = coalesce(p_date, current_date),
    sent_reference = coalesce(nullif(trim(p_reference), ''), case when s.payout_method = 'withdraw' then 'withdrawn by owner' end), sent_by = lower(auth.email()) where id = p_id;
  if s.payout_method = 'withdraw' then
    null;   -- he withdrew it himself; no email
  elsif s.owner_email is not null and s.payout_method = 'check' then
    insert into email_outbox (to_email, subject, html, kind) values (s.owner_email, 'Unit ' || s.unit_number || ': your check was mailed',
      '<p>Dear ' || repair_esc(coalesce(s.owner_name, 'Owner')) || ',</p><p>We mailed you a check for ' || to_char(s.net_to_owner, 'FM$999,990.00') || ' on ' || to_char(coalesce(p_date, current_date), 'FMMM/FMDD/YYYY')
      || ' (check number ' || repair_esc(trim(p_reference)) || '), from your tenant''s rent payment of ' || to_char(s.paid_on, 'FMMM/FMDD/YYYY') || '. A printed statement is in the envelope.</p><p>2nd Chance Housing, for ROCA1</p>', 'roca_check_sent');
  elsif s.owner_email is not null then
    insert into email_outbox (to_email, subject, html, kind) values (s.owner_email, 'Unit ' || s.unit_number || ': your Zelle was sent',
      '<p>Dear ' || repair_esc(coalesce(s.owner_name, 'Owner')) || ',</p><p>We sent ' || to_char(s.net_to_owner, 'FM$999,990.00') || ' to you by Zelle on ' || to_char(coalesce(p_date, current_date), 'FMMM/FMDD/YYYY')
      || ' (reference ' || repair_esc(trim(p_reference)) || '), from your tenant''s rent payment of ' || to_char(s.paid_on, 'FMMM/FMDD/YYYY') || '.</p><p>2nd Chance Housing, for ROCA1</p>', 'roca_zelle_sent');
  end if;
end;
$function$;
revoke all on function roca_rent_payout_sent(uuid, date, text) from public, anon;
grant execute on function roca_rent_payout_sent(uuid, date, text) to authenticated;

do $$
declare v text := pg_get_functiondef('staff_today()'::regprocedure);
begin
  if position('Owner payouts to send (Zelle or mailed check)' in v) > 0 then
    execute replace(v, 'Owner payouts to send (Zelle or mailed check)', 'Owner payouts waiting (Zelle, or Unit 15 statement and withdrawal)');
  end if;
end $$;
