-- Unit 15 (Mark Postler): 3.5% fee on EVERY tenant payment, to cover Stripe and administrative costs (Stephen, 11/10/2026).
-- On a $950 payment: $950 - $215 dues - $33.25 fee = $701.75 check to the owner. Unit 15's rent goes into ROCA1's account (First Citizens):
-- new Unit 15 leases get that bank automatically (setting roca_routed_default_units, trigger below).
-- roca_pma_terms.card_fee_pct now means "% of tenant payments made through Stripe (bank or card)" for the per-payment split
-- (ROCA1-routed units). Before this, the split charged mgmt_fee_pct on every payment and nothing looked at card_fee_pct
-- (it filtered on method 'card', which Stripe payments never carry). No unit had a fee on file, so nothing charged before changes.

comment on column roca_pma_terms.card_fee_pct is '% of tenant payments made through Stripe (stripe_bank or stripe_card), Stripe + administrative fee (11/10/2026)';

insert into roca_pma_terms (unit_number, mgmt_fee_pct, card_fee_pct, operating_reserve, source_document, note, updated_by)
values ('15', 3.5, 0, 0, 'Unit 15 Property Management Agreement, Mark Postler (November 2026, paper)',
        '3.5% of every tenant payment, to cover Stripe and administrative fees.', 'info@2ndchinc.org')
on conflict (unit_number) do update set mgmt_fee_pct = excluded.mgmt_fee_pct, card_fee_pct = excluded.card_fee_pct, operating_reserve = excluded.operating_reserve,
  source_document = excluded.source_document, note = excluded.note, updated_by = excluded.updated_by, updated_at = now();

-- The split (latest version 20261118670000): fee = mgmt_fee_pct on every payment + card_fee_pct on Stripe payments.
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
  v_check boolean; v_mail text; v_method text := (select e.method from lease_ledger_entries e where e.id = p_entry);
  CAT jsonb := '{"fines_fees":"fines and fees","assessments":"special assessments","dues_current":"association dues","older_balance":"past-due dues"}';
begin
  if v_unit is null or p_amount <= 0 then return null; end if;
  if exists (select 1 from roca_rent_splits where lease_entry_id = p_entry) then return null; end if;
  select * into o from roca_unit_owner_on(v_unit, p_paid_on);
  if o.owner_id is null or o.name ~* '^2nd Chance' then return null; end if;   -- 2nd Chance's own unit: nothing to split
  v_check := roca_unit_paid_by_check(v_unit);
  v_mail := case when v_check then roca_owner_mail_to(o.owner_id) end;
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
          case when v_net > 0 then 'zelle_due' else 'nothing_to_send' end, case when v_check then 'check' else 'zelle' end, v_mail)
  returning id into v_split;
  if v_net > 0 and v_check then
    insert into email_outbox (to_email, subject, html, kind) values (v_office, 'Mail a check for $' || to_char(v_net, 'FM999,990.00') || ' to ' || o.name || ' (Unit ' || v_unit || ')',
      '<p>The tenant''s rent of ' || to_char(p_amount, 'FM$999,990.00') || ' for Unit ' || v_unit || ' cleared.</p><ul><li>Applied to ' || o.name || '''s association account: ' || to_char(v_ded_total, 'FM$999,990.00') || '</li>'
      || case when v_mgmt > 0 then '<li>Payment processing and administrative fee: ' || to_char(v_mgmt, 'FM$999,990.00') || '</li>' else '' end
      || '<li><b>To send to the owner by mailed paper check: ' || to_char(v_net, 'FM$999,990.00') || '</b></li></ul>'
      || '<p>This owner is paid by paper check only (no Zelle, nothing electronic). Make the check out to ' || repair_esc(o.name) || ' and mail it to: <b>'
      || repair_esc(coalesce(v_mail, '(no mailing address on file: add it to the owner record before mailing)')) || '</b>. Put a printed statement in the envelope: rent received, what was applied to ROCA1, and the check amount.</p>'
      || '<p>After you mail it, record the date and the check number: <a href="https://2ndchinc.org/association-owners/roca1/distributions/">Rent deductions</a>.</p>', 'roca_check_due');
  elsif v_net > 0 then
    insert into email_outbox (to_email, subject, html, kind) values (v_office, 'Zelle $' || to_char(v_net, 'FM999,990.00') || ' to ' || o.name || ' (Unit ' || v_unit || ')',
      '<p>The tenant''s rent of ' || to_char(p_amount, 'FM$999,990.00') || ' for Unit ' || v_unit || ' cleared.</p><ul><li>Applied to ' || o.name || '''s association account: ' || to_char(v_ded_total, 'FM$999,990.00') || '</li>'
      || case when v_mgmt > 0 then '<li>Payment processing and administrative fee: ' || to_char(v_mgmt, 'FM$999,990.00') || '</li>' else '' end
      || '<li><b>To send to the owner by Zelle: ' || to_char(v_net, 'FM$999,990.00') || '</b></li></ul>'
      || '<p>Zelle to ' || repair_esc(o.name) || ': phone ' || repair_esc(coalesce(v_phone, '(none on file)')) || ', email ' || repair_esc(coalesce(o.email, '(none on file)'))
      || '.</p><p>After you send it, record the date and reference: <a href="https://2ndchinc.org/association-owners/roca1/distributions/">Rent deductions</a>.</p>', 'roca_zelle_due');
  end if;
  if o.email is not null then
    insert into email_outbox (to_email, subject, html, kind) values (o.email, 'Unit ' || v_unit || ': your tenant''s rent payment was received',
      '<p>Dear ' || repair_esc(o.name) || ',</p><p>Your tenant''s rent payment of ' || to_char(p_amount, 'FM$999,990.00') || ' (' || to_char(p_paid_on, 'FMMM/FMDD/YYYY') || ') cleared.</p><ul>'
      || '<li>Paid to ROCA1 for your association account: ' || to_char(v_ded_total, 'FM$999,990.00') || '</li>'
      || case when v_mgmt > 0 then '<li>Payment processing and administrative fee: ' || to_char(v_mgmt, 'FM$999,990.00') || '</li>' else '' end
      || '<li><b>' || case when v_net > 0 and v_check then 'Being mailed to you by check: ' when v_net > 0 then 'Being sent to you by Zelle: ' else 'Left for you: ' end || to_char(v_net, 'FM$999,990.00') || '</b></li></ul>'
      || case when v_check then '<p>A printed statement comes in the envelope with your check.</p>' else '<p>See it in the owner portal: https://2ndchinc.org/association-owners/roca1/#statements</p>' end
      || '<p>2nd Chance Housing, for ROCA1</p>', 'roca_rent_split');
  end if;
  return v_split;
end;
$function$;

-- ---------------------------------------------------------------------------
-- New leases on a unit listed in roca_routed_default_units are paid into ROCA1's First Citizens account (Stephen, 11/10/2026: Unit 15).
-- Only fills an empty pay_to_account_id; staff can still change it at https://2ndchinc.org/accounting/bank/units/ .
insert into portal_settings (key, value) values ('roca_routed_default_units', '15,16') on conflict (key) do nothing;

create or replace function lease_default_pay_to()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.pay_to_account_id is null and exists (
       select 1 from rental_units u where u.id = new.unit_id
          and u.unit_number = any (string_to_array(replace(coalesce((select value from portal_settings where key = 'roca_routed_default_units'), ''), ' ', ''), ','))) then
    new.pay_to_account_id := bank_account_by_key('first_citizens_roca1');
  end if;
  return new;
end;
$$;
revoke all on function lease_default_pay_to() from public, anon, authenticated;
drop trigger if exists leases_default_pay_to on leases;
create trigger leases_default_pay_to before insert on leases for each row execute function lease_default_pay_to();
