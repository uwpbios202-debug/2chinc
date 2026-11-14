-- A bank payment refunded while it is still processing (Unit 5 paid 3 times on 11/4; the two extras were refunded 11/8 at
-- Stephen's request) must never post as rent when it later clears. Stripe holds an ACH refund until the payment succeeds, so
-- payment_intent.succeeded still arrives: if the row was already fully refunded, nothing is posted. (Stephen, 11/8/2026.)
CREATE OR REPLACE FUNCTION public.stripe_payment_succeeded(p_intent text, p_method_type text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare s stripe_payments; v_report uuid;
begin
  select * into s from stripe_payments where payment_intent = p_intent for update;
  if s.id is null then return jsonb_build_object('error', 'unknown payment intent'); end if;
  if s.status = 'succeeded' then return jsonb_build_object('ok', true, 'already', true); end if;
  if coalesce(s.refunded_amount, 0) >= s.amount then
    update stripe_payments set status = 'canceled', updated_at = now() where id = s.id;
    return jsonb_build_object('ok', true, 'already', true, 'note', 'refunded before it cleared; nothing posted');
  end if;
  insert into payment_reports (tenant_id, owner_id, condo_account_id, lease_id, land_contract_id, method, amount, paid_on, confirmation_code, note, caseworker_id, received_account_id, payer_name)
  values (s.tenant_id, s.owner_id, s.condo_account_id, s.lease_id, s.land_contract_id,
          case when coalesce(p_method_type, s.method_type) = 'card' then 'stripe_card' else 'stripe_bank' end,
          s.amount, (s.created_at at time zone 'America/Chicago')::date, p_intent,
          case when s.owner_id is not null then 'Association dues paid online' when s.origin = 'autopay' then 'Autopay' when s.origin = 'caseworker' then 'Paid online by the agency' else 'Paid online' end,
          s.caseworker_id, case when s.caseworker_id is not null then bank_account_by_key('first_citizens_roca1') end,
          case when s.caseworker_id is not null then (select coalesce(nullif(c.agency, ''), 'Agency') || ' (' || c.name || ')' from caseworkers c where c.id = s.caseworker_id) end)
  returning id into v_report;
  perform payment_post(v_report, null, 'stripe', 'Stripe');
  update stripe_payments set status = 'succeeded', method_type = coalesce(p_method_type, method_type), payment_report_id = v_report, updated_at = now() where id = s.id;
  return jsonb_build_object('ok', true, 'report', v_report);
end;
$function$
;
revoke all on function stripe_payment_succeeded(text, text) from public, anon, authenticated;
grant execute on function stripe_payment_succeeded(text, text) to service_role;
