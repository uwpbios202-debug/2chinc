-- Stephen (10/8/2026): "Remove credit card and add the return fee."
--  * Cards are gone from Stripe checkout (bank account only) — see supabase/functions/stripe-pay; PayPal's own card
--    option is turned off in site/assets/portal/paypal.js.
--  * Returned-payment fee: the lease's nonstandard rental provision "RETURNED CHECK/STOP PAYMENT FEE: If any payment by
--    Tenant is returned unpaid due to insufficient funds or for any other reason, Tenant will be charged a fee of $30"
--    (templates/lease-agreement). It posts when a payment comes back UNPAID — a bank return (NSF, closed account, stop
--    payment), an ACH failure after the payment had cleared, or a lost dispute. Never for a refund 2nd Chance gives.
--    Automatic only on leases signed through this system (leases.signing_doc_id), whose lease carries that clause;
--    for an older lease staff are told to add it by hand only if that signed lease allows it.
--    Owners (ROCA1 dues) get no return fee: nothing in the Rules or By-Laws provides one.

insert into portal_settings (key, value) values ('returned_payment_fee', '30') on conflict (key) do nothing;

alter table payment_reports add column if not exists return_fee_entry_id bigint;

create or replace function lease_return_fee(p_report uuid, p_by text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r payment_reports; l leases; v_fee numeric := coalesce(nullif((select value from portal_settings where key = 'returned_payment_fee'), ''), '0')::numeric; v_e bigint;
begin
  select * into r from payment_reports where id = p_report for update;
  if r.id is null or r.lease_id is null then return jsonb_build_object('fee', 0, 'note', 'Not a rent payment: no return fee.'); end if;
  if r.return_fee_entry_id is not null then return jsonb_build_object('fee', 0, 'note', 'The return fee was already charged for this payment.'); end if;
  select * into l from leases where id = r.lease_id;
  if v_fee <= 0 then return jsonb_build_object('fee', 0, 'note', 'Return fee is set to $0.'); end if;
  if l.signing_doc_id is null then
    return jsonb_build_object('fee', 0, 'note', 'No return fee charged automatically: this lease was not signed through the system. Add it by hand only if that signed lease provides for it.');
  end if;
  insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, description, amount, source, correction_note)
  values (r.lease_id, 'Returned Payment Fee', current_date, 'charge', 'Returned payment fee',
          'Returned payment fee (payment of ' || to_char(r.amount, 'FM$999,990.00') || ' made ' || to_char(r.paid_on, 'FMMM/FMDD/YYYY') || ')', v_fee, 'payment_reversal',
          'Lease: RETURNED CHECK/STOP PAYMENT FEE ($' || v_fee || '). By ' || coalesce(p_by, 'system') || '.')
  returning id into v_e;
  update payment_reports set return_fee_entry_id = v_e where id = r.id;
  return jsonb_build_object('fee', v_fee, 'entry', v_e);
end;
$$;
revoke all on function lease_return_fee(uuid, text) from public, anon, authenticated;

-- Staff reversal: now says whether the payment came back unpaid (then the fee posts). Old 3-argument calls still work.
drop function if exists payments_staff_reverse(uuid, numeric, text);
create or replace function payments_staff_reverse(p_report uuid, p_amount numeric, p_reason text, p_returned boolean default false)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v jsonb; f jsonb := '{}'::jsonb; r payment_reports; v_to text; v_name text;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  v := lease_payment_reverse(p_report, p_amount, p_reason, lower(auth.email()));
  if coalesce(p_returned, false) then f := lease_return_fee(p_report, lower(auth.email())); end if;
  select * into r from payment_reports where id = p_report;
  select coalesce(t.email, o.email), coalesce(t.name, o.name) into v_to, v_name
    from payment_reports x left join tenants t on t.id = x.tenant_id left join condo_owners o on o.id = x.owner_id where x.id = p_report;
  if v_to is not null then
    insert into email_outbox (to_email, subject, html, kind) values (v_to, 'A payment was ' || case when p_returned then 'returned unpaid' else 'reversed' end,
      '<p>Hi ' || repair_esc(split_part(coalesce(v_name, ''), ' ', 1)) || ',</p><p>Your payment of ' || to_char(r.amount, 'FM$999,990.00') || ' made '
      || to_char(r.paid_on, 'FMMM/FMDD/YYYY') || ' was ' || case when p_returned then 'returned unpaid' else 'reversed' end || ' (' || repair_esc(p_reason) || '), so '
      || to_char((v->>'reversed')::numeric, 'FM$999,990.00') || ' is back on your account.'
      || case when (f->>'fee')::numeric > 0 then ' Under your lease, a returned-payment fee of ' || to_char((f->>'fee')::numeric, 'FM$999,990.00') || ' was added.' else '' end
      || ' Please pay again or call the office' || coalesce(' at ' || (select value from portal_settings where key = 'org_phone'), '') || '.</p>', 'payment_reversed');
  end if;
  return v || jsonb_build_object('return_fee', f);
end;
$$;
revoke all on function payments_staff_reverse(uuid, numeric, text, boolean) from public, anon;
grant execute on function payments_staff_reverse(uuid, numeric, text, boolean) to authenticated;

-- Stripe: a bank return or a lost dispute is a payment returned unpaid; a refund is not.
drop function if exists stripe_payment_reverse(text, numeric, text);
create or replace function stripe_payment_reverse(p_intent text, p_amount numeric, p_reason text, p_returned boolean default false)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare s stripe_payments; v jsonb;
begin
  select * into s from stripe_payments where payment_intent = p_intent for update;
  if s.id is null then return jsonb_build_object('error', 'unknown payment intent'); end if;
  if s.payment_report_id is null or s.status not in ('succeeded', 'disputed', 'reversed') then
    update stripe_payments set status = case when s.status in ('created', 'processing') then 'failed' else s.status end, failure_message = p_reason, updated_at = now() where id = s.id;
    return jsonb_build_object('ok', true, 'note', 'nothing was posted');
  end if;
  if (select amount - reversed_amount from payment_reports where id = s.payment_report_id) <= 0 then return jsonb_build_object('ok', true, 'already', true); end if;
  v := lease_payment_reverse(s.payment_report_id, least(coalesce(p_amount, s.amount), (select amount - reversed_amount from payment_reports where id = s.payment_report_id)), p_reason, 'Stripe');
  if coalesce(p_returned, false) then v := v || jsonb_build_object('return_fee', lease_return_fee(s.payment_report_id, 'Stripe')); end if;
  update stripe_payments set status = 'reversed', failure_message = p_reason, updated_at = now() where id = s.id;
  return v;
end;
$$;
revoke all on function stripe_payment_reverse(text, numeric, text, boolean) from public, anon, authenticated;
