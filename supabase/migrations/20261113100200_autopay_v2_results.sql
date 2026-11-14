-- Autopay, part 3: what happened to a withdrawal. A failed or returned withdrawal is logged and PAUSES autopay (no second try).
create or replace function autopay_debit_result(p_stripe_payment uuid, p_kind text, p_reason text)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare v_auth uuid; v_tenant uuid;
begin
  if p_kind not in ('debit_succeeded', 'debit_failed', 'debit_returned') then raise exception 'Bad kind'; end if;
  select ev.authorization_id, a.tenant_id into v_auth, v_tenant
    from autopay_events ev join autopay_authorizations a on a.id = ev.authorization_id
   where ev.kind = 'debit_started' and ev.detail ->> 'stripe_payment_id' = p_stripe_payment::text order by ev.id desc limit 1;
  if v_auth is null then return; end if;
  perform autopay_event(v_auth, p_kind, jsonb_build_object('stripe_payment_id', p_stripe_payment, 'reason', left(coalesce(p_reason, ''), 300)), 'system');
  if p_kind in ('debit_failed', 'debit_returned') then
    perform autopay_system_pause(v_tenant, coalesce(nullif(p_reason, ''), 'The bank did not accept the withdrawal.'));
  end if;
end;
$$;
revoke all on function autopay_debit_result(uuid, text, text) from public, anon, authenticated;
grant execute on function autopay_debit_result(uuid, text, text) to service_role;
