-- 3446 N 12th St land contract (Stephen, 11/5/2026): whenever the buyers pay, email info@2ndchinc.org the amount paid,
-- 2nd Chance's service fee (portal setting land_contract_service_fee_pct, 4%) and the balance, which the office sends to the
-- seller by Zelle. Fires on any new payment line in the land contract ledger (Stripe, bank match, or entered by staff);
-- a reversal (a payment line that adds back) sends a "do not send / recover" email instead. Imported history is ignored.

insert into portal_settings (key, value) values ('land_contract_service_fee_pct', '4') on conflict (key) do nothing;

create or replace function land_contract_payment_split_email()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_pct numeric := coalesce(nullif(condo_setting('land_contract_service_fee_pct', ''), '')::numeric, 4);
  v_paid numeric; v_fee numeric; v_rest numeric; v_street text; v_seller text; v_date text;
begin
  if new.kind <> 'payment' or coalesce(new.source, '') = 'opening records' or coalesce(new.amount, 0) = 0 then return new; end if;
  select rp.street into v_street from land_contracts lc left join rental_properties rp on rp.id = lc.property_id where lc.id = new.contract_id;
  select string_agg(distinct coalesce(nullif(entity, ''), name), ', ') into v_seller from land_contract_sellers where contract_id = new.contract_id and active;
  v_paid := abs(new.amount);
  v_fee := round(v_paid * v_pct / 100, 2);
  v_rest := v_paid - v_fee;
  v_date := to_char(new.entry_date, 'FMMM/FMDD/YYYY');

  if new.amount < 0 then
    insert into email_outbox (to_email, subject, html, kind) values ('info@2ndchinc.org',
      'Land contract payment: Zelle $' || to_char(v_rest, 'FM999,990.00') || ' to ' || coalesce(v_seller, 'the seller'),
      '<p>The buyers of <b>' || repair_esc(coalesce(v_street, 'the land contract property')) || '</b> made a payment.</p>'
      || '<table style="border-collapse:collapse;font-size:15px">'
      || '<tr><td style="padding:4px 12px 4px 0">Paid on</td><td style="text-align:right">' || v_date || '</td></tr>'
      || '<tr><td style="padding:4px 12px 4px 0">Amount paid</td><td style="text-align:right">$' || to_char(v_paid, 'FM999,990.00') || '</td></tr>'
      || '<tr><td style="padding:4px 12px 4px 0">2nd Chance service fee (' || trim(to_char(v_pct, 'FM990.##')) || '%)</td><td style="text-align:right">$' || to_char(v_fee, 'FM999,990.00') || '</td></tr>'
      || '<tr><td style="padding:4px 12px 4px 0;border-top:1px solid #999"><b>Balance to Zelle to ' || repair_esc(coalesce(v_seller, 'the seller')) || '</b></td><td style="text-align:right;border-top:1px solid #999"><b>$' || to_char(v_rest, 'FM999,990.00') || '</b></td></tr></table>'
      || '<p style="color:#555">Recorded as: ' || repair_esc(coalesce(new.raw_type, new.description, 'payment')) || '. A bank payment can still be returned in the first few days; a card payment can be disputed.</p>',
      'land_contract_split');
  else
    insert into email_outbox (to_email, subject, html, kind) values ('info@2ndchinc.org',
      'Land contract payment REVERSED: do not send $' || to_char(v_rest, 'FM999,990.00') || ' to ' || coalesce(v_seller, 'the seller'),
      '<p>A payment of <b>$' || to_char(v_paid, 'FM999,990.00') || '</b> on the <b>' || repair_esc(coalesce(v_street, 'land contract')) || '</b> land contract was reversed (' || v_date || ').</p>'
      || '<p>If the $' || to_char(v_rest, 'FM999,990.00') || ' balance was not sent yet, do not send it. If it was sent, it needs to be recovered from the seller or netted against the next payment. '
      || 'The ' || trim(to_char(v_pct, 'FM990.##')) || '% fee ($' || to_char(v_fee, 'FM999,990.00') || ') is not earned on a reversed payment.</p>',
      'land_contract_split');
  end if;
  return new;
end;
$$;
revoke all on function land_contract_payment_split_email() from public, anon, authenticated;

drop trigger if exists land_contract_payment_split_email on land_contract_ledger;
create trigger land_contract_payment_split_email after insert on land_contract_ledger
  for each row execute function land_contract_payment_split_email();
