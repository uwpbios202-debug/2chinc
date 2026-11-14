-- Autopay, part 2: activation, cancel, staff pause, returned-payment pause, reminders, the guarded charge list, and the log check.
-- (Part 1: 20261113100000_autopay_v2.sql.) Autopay stays off until the setting autopay_enabled is 'on'.

-- ---------------------------------------------------------------------------
-- Activation (only from Stripe's signed event, for a setup this tenant just authorized) and cancel (only the tenant)
create or replace function autopay_setup_ready(p_auth uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare a autopay_authorizations;
begin
  if not exists (select 1 from resident_me()) then raise exception 'Resident sign-in required' using errcode = '42501'; end if;
  if autopay_view_as_session() then raise exception 'Autopay can only be set up by the tenant, from their own sign-in.'; end if;
  if condo_setting('autopay_enabled', 'off') <> 'on' then raise exception 'Autopay is not available yet.'; end if;
  select * into a from autopay_authorizations where id = p_auth;
  if a.id is null or a.status <> 'pending' or a.tenant_id not in (select resident_me()) or a.created_at < now() - interval '60 minutes' then
    raise exception 'Start again: read and agree to the terms, then connect your bank.';
  end if;
  return jsonb_build_object('ok', true, 'tenant_id', a.tenant_id);
end;
$$;
revoke all on function autopay_setup_ready(uuid) from public, anon;
grant execute on function autopay_setup_ready(uuid) to authenticated;

create or replace function autopay_activate(p_auth uuid, p_customer text, p_account text, p_pm text, p_bank text, p_setup_intent text, p_mandate text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare a autopay_authorizations; v_name text; v_email text; v_first date; v_label text; o record;
begin
  select * into a from autopay_authorizations where id = p_auth for update;
  if a.id is null or a.status <> 'pending' then return jsonb_build_object('ok', false, 'reason', 'not pending'); end if;
  if a.created_at < now() - interval '2 hours' then
    perform autopay_set_actor('system');
    update autopay_authorizations set status = 'expired', ended_at = now(), ended_by = 'system', ended_reason = 'the bank was not connected in time' where id = a.id;
    perform autopay_event(a.id, 'expired', '{}'::jsonb, 'system');
    return jsonb_build_object('ok', false, 'reason', 'expired');
  end if;
  perform autopay_set_actor('webhook');
  update autopay_authorizations set status = 'active', stripe_account = coalesce(nullif(p_account, ''), 'main'), customer_id = p_customer, payment_method_id = p_pm,
         bank_label = p_bank, setup_intent = p_setup_intent, mandate = p_mandate, activated_at = now() where id = a.id;
  perform autopay_event(a.id, 'activated', jsonb_build_object('bank', p_bank, 'setup_intent', p_setup_intent, 'mandate', p_mandate), 'webhook');
  select name, email into v_name, v_email from tenants where id = a.tenant_id;
  v_first := autopay_next_draw(a.draw_day, (a.created_at at time zone 'America/Chicago')::date + 8);
  v_label := coalesce((select ru.address from leases l join rental_units ru on ru.id = l.unit_id where l.id = a.lease_id),
                      (select p.street from land_contracts c join rental_properties p on p.id = c.property_id where c.id = a.land_contract_id));
  if coalesce(v_email, '') like '%@%' then
    perform autopay_email(v_email, '[Autopay] You set up autopay: first withdrawal ' || to_char(v_first, 'FMMon FMDD'),
      '<p>Hi ' || repair_esc(split_part(v_name, ' ', 1)) || ',</p><p><b>You set up autopay.</b> This email is your record of what you agreed to.</p>'
      || '<ul><li>Amount: <b>' || to_char(a.amount, 'FM$999,990.00') || '</b> a month (or less if you owe less)</li><li>From: <b>' || repair_esc(coalesce(p_bank, 'your bank account')) || '</b></li>'
      || '<li>Date: the <b>' || a.draw_day || '</b> of each month. First withdrawal: <b>' || to_char(v_first, 'FMMonth FMDD, YYYY') || '</b></li>'
      || '<li>For: ' || repair_esc(coalesce(v_label, '')) || '</li></ul>'
      || '<p>We will email you 7 days, 3 days and 1 day before every withdrawal, and on the day. <b>Please keep enough money in the account.</b> A returned withdrawal can cost you a fee and late rent, and autopay will pause.</p>'
      || '<p>To cancel at any time: sign in to your <a href="https://2ndchinc.org/resident/#payments">portal</a>, Payments, Autopay, Cancel. Cancel before 11:59 PM the day before a withdrawal to stop it.</p>'
      || '<p>If you did not do this, cancel it now and call (262) 236-5443.</p><p>2nd Chance Housing</p>', 'autopay_setup');
  end if;
  -- the other people on a joint lease are told whose bank it is
  for o in select t.name, t.email from lease_tenants lt join tenants t on t.id = lt.tenant_id where lt.lease_id = a.lease_id and lt.tenant_id <> a.tenant_id and coalesce(t.email, '') like '%@%'
  loop
    perform autopay_email(o.email, '[Autopay] ' || split_part(v_name, ' ', 1) || ' set up autopay for your rent',
      '<p>Hi ' || repair_esc(split_part(o.name, ' ', 1)) || ',</p><p>' || repair_esc(v_name) || ' set up autopay for the rent at ' || repair_esc(coalesce(v_label, '')) || ', to be withdrawn from their own bank account on the '
      || a.draw_day || ' of each month. You do not need to do anything. If you also pay yourself, check your balance first so rent is not paid twice.</p><p>2nd Chance Housing</p>', 'autopay_setup');
  end loop;
  return jsonb_build_object('ok', true);
end;
$$;
revoke all on function autopay_activate(uuid, text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function autopay_activate(uuid, text, text, text, text, text, text) to service_role;

create or replace function autopay_cancel()
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare a autopay_authorizations; n int := 0; v_name text; v_email text;
begin
  if not exists (select 1 from resident_me()) then raise exception 'Resident sign-in required' using errcode = '42501'; end if;
  if autopay_view_as_session() then raise exception 'Autopay can only be changed by the tenant, from their own sign-in.'; end if;
  perform autopay_set_actor('tenant');
  for a in select * from autopay_authorizations where tenant_id in (select resident_me()) and status in ('pending', 'active') for update loop
    update autopay_authorizations set status = 'canceled', ended_at = now(), ended_by = 'tenant', ended_reason = 'canceled by the tenant' where id = a.id;
    perform autopay_event(a.id, 'canceled', '{}'::jsonb, 'tenant');
    n := n + 1;
    if a.status = 'active' then
      select name, email into v_name, v_email from tenants where id = a.tenant_id;
      if coalesce(v_email, '') like '%@%' then
        perform autopay_email(v_email, '[Autopay] You canceled autopay',
          '<p>Hi ' || repair_esc(split_part(v_name, ' ', 1)) || ',</p><p><b>You canceled autopay.</b> No more automatic withdrawals will be made. Your ' || case when a.lease_id is not null then 'rent' else 'payment' end
          || ' is still due each month: pay in your <a href="https://2ndchinc.org/resident/#payments">portal</a>.</p><p>If you did not do this, call (262) 236-5443.</p><p>2nd Chance Housing</p>', 'autopay_cancel');
      end if;
    end if;
  end loop;
  return jsonb_build_object('canceled', n);
end;
$$;
revoke all on function autopay_cancel() from public, anon;
grant execute on function autopay_cancel() to authenticated;

-- Staff can only STOP money moving, never start or change it, and the tenant is told at once. The tenant sets it up again themselves.
create or replace function autopay_staff_pause(p_auth uuid, p_reason text)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare a autopay_authorizations; v_name text; v_email text;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if autopay_view_as_session() then raise exception 'Not available while viewing as someone else.'; end if;
  if length(trim(coalesce(p_reason, ''))) < 5 then raise exception 'Give the reason (the tenant is told).'; end if;
  select * into a from autopay_authorizations where id = p_auth for update;
  if a.id is null or a.status <> 'active' then raise exception 'That autopay is not active.'; end if;
  perform autopay_set_actor('staff_pause');
  update autopay_authorizations set status = 'paused', ended_at = now(), ended_by = 'staff_pause', ended_reason = trim(p_reason) where id = a.id;
  perform autopay_event(a.id, 'paused', jsonb_build_object('reason', trim(p_reason), 'by', lower(auth.email())), 'staff_pause');
  select name, email into v_name, v_email from tenants where id = a.tenant_id;
  if coalesce(v_email, '') like '%@%' then
    perform autopay_email(v_email, '[Autopay] Your autopay was paused: no withdrawals will be made',
      '<p>Hi ' || repair_esc(split_part(v_name, ' ', 1)) || ',</p><p>2nd Chance Housing <b>paused your autopay</b>: ' || repair_esc(trim(p_reason)) || '.</p><p><b>No money will be withdrawn.</b> Your '
      || case when a.lease_id is not null then 'rent' else 'payment' end || ' is still due: pay in your <a href="https://2ndchinc.org/resident/#payments">portal</a>. You can set up autopay again yourself any time. Questions: (262) 236-5443.</p><p>2nd Chance Housing</p>', 'autopay_pause');
  end if;
end;
$$;
revoke all on function autopay_staff_pause(uuid, text) from public, anon;
grant execute on function autopay_staff_pause(uuid, text) to authenticated;

-- One returned or failed withdrawal pauses autopay. No automatic retry.
create or replace function autopay_system_pause(p_tenant uuid, p_reason text)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare a autopay_authorizations; v_name text; v_email text; v_fee numeric := coalesce(nullif((select value from portal_settings where key = 'returned_payment_fee'), ''), '0')::numeric;
begin
  perform autopay_set_actor('system');
  for a in select * from autopay_authorizations where tenant_id = p_tenant and status = 'active' for update loop
    update autopay_authorizations set status = 'paused', ended_at = now(), ended_by = 'system_return', ended_reason = left(p_reason, 300) where id = a.id;
    perform autopay_event(a.id, 'paused', jsonb_build_object('reason', left(p_reason, 300)), 'system');
    select name, email into v_name, v_email from tenants where id = a.tenant_id;
    if coalesce(v_email, '') like '%@%' then
      perform autopay_email(v_email, '[Autopay] Your autopay withdrawal did not go through: autopay is paused',
        '<p>Hi ' || repair_esc(split_part(v_name, ' ', 1)) || ',</p><p>Your autopay withdrawal <b>did not go through</b> (' || repair_esc(left(p_reason, 200)) || ').</p>'
        || '<p><b>What this means:</b> your ' || case when a.lease_id is not null then 'rent' else 'payment' end || ' is still due. Late fees and notices follow the normal schedule'
        || case when a.lease_id is not null and v_fee > 0 then ', and a returned payment fee of ' || to_char(v_fee, 'FM$999,990.00') || ' may apply' else '' end
        || '. <b>We will not try again automatically.</b> Autopay is paused until you set it up again yourself.</p>'
        || '<p>Pay now in your <a href="https://2ndchinc.org/resident/#payments">portal</a> or call (262) 236-5443 to talk about a plan.</p><p>2nd Chance Housing</p>', 'autopay_pause');
    end if;
    perform office_alert('autopay_alert_email', 'autopay', 'Autopay paused after a failed withdrawal: ' || coalesce(v_name, ''), '<p>' || repair_esc(coalesce(v_name, '')) || ': ' || repair_esc(left(p_reason, 300)) || '</p>');
  end loop;
end;
$$;
revoke all on function autopay_system_pause(uuid, text) from public, anon, authenticated;
grant execute on function autopay_system_pause(uuid, text) to service_role;

create or replace function autopay_record(p_auth uuid, p_kind text, p_detail jsonb)
returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if p_kind not in ('debit_started', 'debit_succeeded', 'debit_failed', 'debit_returned') then raise exception 'Bad event'; end if;
  perform autopay_event(p_auth, p_kind, coalesce(p_detail, '{}'::jsonb), 'system');
end;
$$;
revoke all on function autopay_record(uuid, text, jsonb) from public, anon, authenticated;
grant execute on function autopay_record(uuid, text, jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- Reminders: 7, 3, 1 days before and the day of. Run daily by the rent cycle.
create or replace function autopay_send_reminders(p_as_of date)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
#variable_conflict use_column
declare a autopay_authorizations; s record; v_draw date; v_days int; v_kind text; v_name text; v_email text; v_amt numeric; v_oid bigint; v_subj text; v_label text; n int := 0; v_ended int := 0;
begin
  if condo_setting('autopay_enabled', 'off') <> 'on' then return jsonb_build_object('skipped', 'autopay is off'); end if;
  for a in select * from autopay_authorizations where status = 'active' loop
    select name, email into v_name, v_email from tenants where id = a.tenant_id;
    select * into s from autopay_subject(a.tenant_id) x where (a.lease_id is not null and x.lease_id = a.lease_id) or (a.land_contract_id is not null and x.land_contract_id = a.land_contract_id) limit 1;
    if s.amount is null then   -- the lease or contract ended: autopay ends with it
      perform autopay_set_actor('system');
      update autopay_authorizations set status = 'canceled', ended_at = now(), ended_by = 'system', ended_reason = 'the lease or contract ended' where id = a.id;
      perform autopay_event(a.id, 'canceled', jsonb_build_object('reason', 'lease or contract ended'), 'system'); v_ended := v_ended + 1; continue;
    end if;
    v_draw := autopay_next_draw(a.draw_day, p_as_of); v_days := v_draw - p_as_of;
    continue when v_days not in (7, 3, 1, 0);
    v_kind := 'reminder_' || v_days;
    continue when exists (select 1 from autopay_events e where e.authorization_id = a.id and e.kind = v_kind and e.detail ->> 'cycle' = v_draw::text);
    continue when a.activated_at is not null and (a.activated_at at time zone 'America/Chicago')::date > p_as_of;
    continue when coalesce(v_email, '') not like '%@%';
    v_amt := least(a.amount, s.amount); v_label := s.label;
    v_subj := case when v_days = 0 then '[Autopay] Money leaves your bank TODAY: ' || to_char(v_amt, 'FM$999,990.00')
                   else '[Autopay] ' || to_char(v_amt, 'FM$999,990.00') || ' will be withdrawn ' || to_char(v_draw, 'FMMon FMDD') || ' (' || v_days || ' day' || case when v_days = 1 then '' else 's' end || ')' end;
    v_oid := autopay_email(v_email, v_subj,
      '<p>Hi ' || repair_esc(split_part(v_name, ' ', 1)) || ',</p><p>' || case when v_days = 0 then '<b>Today</b>' else 'In <b>' || v_days || ' day' || case when v_days = 1 then '' else 's' end || '</b>, on <b>' || to_char(v_draw, 'FMDay, FMMonth FMDD') || '</b>,' end
      || ' your autopay will withdraw <b>' || to_char(v_amt, 'FM$999,990.00') || '</b> from <b>' || repair_esc(coalesce(a.bank_label, 'your bank account')) || '</b> for ' || repair_esc(coalesce(v_label, '')) || '.</p>'
      || '<p><b>Please make sure the money is in the account.</b> If the withdrawal is returned, ' || case when a.lease_id is not null then 'your rent is still due, late fees and notices follow, a returned payment fee may apply, ' else 'your payment is still due, ' end
      || 'your bank may charge you, and autopay pauses.</p>'
      || case when s.amount > a.amount then '<p>Your ' || case when a.lease_id is not null then 'rent' else 'payment' end || ' is now ' || to_char(s.amount, 'FM$999,990.00') || '. Autopay will only withdraw ' || to_char(a.amount, 'FM$999,990.00')
           || ' until you approve a new amount yourself. Pay the rest in your portal.</p>' else '' end
      || case when v_days = 0 then '' else '<p>To stop this withdrawal, sign in and cancel autopay <b>before 11:59 PM on ' || to_char(v_draw - 1, 'FMDay, FMMonth FMDD') || '</b>: <a href="https://2ndchinc.org/resident/#payments">your portal</a>, Payments, Autopay, Cancel.</p>' end
      || '<p>Questions: (262) 236-5443.</p><p>2nd Chance Housing</p>', 'autopay_reminder');
    perform autopay_event(a.id, v_kind, jsonb_build_object('cycle', v_draw::text, 'outbox_id', v_oid, 'amount', v_amt), 'system');
    n := n + 1;
  end loop;
  return jsonb_build_object('reminders', n, 'ended', v_ended);
end;
$$;
revoke all on function autopay_send_reminders(date) from public, anon, authenticated;
grant execute on function autopay_send_reminders(date) to service_role;

-- ---------------------------------------------------------------------------
-- The only list the charge job may use: active, authorized, reminded, owing, nothing already in flight.
create or replace function autopay_due_v2(p_as_of date)
returns table (authorization_id uuid, tenant_id uuid, lease_id uuid, land_contract_id uuid, customer_id text, payment_method text, stripe_account text, amount numeric)
language plpgsql volatile security definer set search_path = public as $$
#variable_conflict use_column
declare a autopay_authorizations; s record; v_due numeric; v_amt numeric; v_email text; v_name text; v_ok boolean;
begin
  if condo_setting('autopay_enabled', 'off') <> 'on' then return; end if;
  for a in select * from autopay_authorizations x where x.status = 'active' and x.draw_day = extract(day from p_as_of)::int and x.payment_method_id is not null and x.customer_id is not null loop
    continue when exists (select 1 from autopay_events e where e.authorization_id = a.id and e.kind = 'debit_started' and e.detail ->> 'cycle' = p_as_of::text);
    select * into s from autopay_subject(a.tenant_id) x where (a.lease_id is not null and x.lease_id = a.lease_id) or (a.land_contract_id is not null and x.land_contract_id = a.land_contract_id) limit 1;
    continue when s.amount is null;
    if a.lease_id is not null then
      v_due := lease_rent_due(a.lease_id, p_as_of);
      continue when exists (select 1 from stripe_payments sp where sp.lease_id = a.lease_id and sp.status in ('created', 'processing'));
      continue when exists (select 1 from payment_reports r where r.lease_id = a.lease_id and r.status = 'pending' and payment_report_fresh(r, p_as_of));
    else
      v_due := greatest((select coalesce(sum(l.amount), 0) from land_contract_ledger l where l.contract_id = a.land_contract_id), 0);
      continue when exists (select 1 from stripe_payments sp where sp.land_contract_id = a.land_contract_id and sp.status in ('created', 'processing'));
    end if;
    continue when coalesce(v_due, 0) <= 0;
    -- No confirmed reminder, no withdrawal: the 1-day reminder must have been sent, and the address must not be bouncing.
    select email, name into v_email, v_name from tenants where id = a.tenant_id;
    v_ok := exists (select 1 from autopay_events e join email_outbox o on o.id = (e.detail ->> 'outbox_id')::bigint
                    where e.authorization_id = a.id and e.kind = 'reminder_1' and e.detail ->> 'cycle' = p_as_of::text and o.sent_at is not null and o.error is null)
        and not exists (select 1 from email_log l where lower(l.to_email) = lower(coalesce(v_email, '')) and l.status in ('bounced', 'complained', 'failed') and l.sent_at > now() - interval '10 days');
    if not v_ok then
      if not exists (select 1 from autopay_events e where e.authorization_id = a.id and e.kind = 'held' and e.detail ->> 'cycle' = p_as_of::text) then
        perform autopay_event(a.id, 'held', jsonb_build_object('cycle', p_as_of::text, 'reason', 'the reminder could not be confirmed'), 'system');
        if coalesce(v_email, '') like '%@%' then
          perform autopay_email(v_email, '[Autopay] Your autopay withdrawal was NOT made this month',
            '<p>Hi ' || repair_esc(split_part(v_name, ' ', 1)) || ',</p><p>We could not confirm that your reminder reached you, so <b>we did not withdraw anything</b>. Your '
            || case when a.lease_id is not null then 'rent' else 'payment' end || ' is still due: please pay in your <a href="https://2ndchinc.org/resident/#payments">portal</a>.</p><p>2nd Chance Housing</p>', 'autopay_held');
        end if;
        perform office_alert('autopay_alert_email', 'autopay', 'Autopay held: ' || coalesce(v_name, ''), '<p>A withdrawal for ' || repair_esc(coalesce(v_name, '')) || ' was held because the reminder could not be confirmed (not sent, or the address is bouncing). Check their email address and contact them.</p>');
      end if;
      continue;
    end if;
    v_amt := least(v_due, a.amount);
    authorization_id := a.id; tenant_id := a.tenant_id; lease_id := a.lease_id; land_contract_id := a.land_contract_id;
    customer_id := a.customer_id; payment_method := a.payment_method_id; stripe_account := coalesce(a.stripe_account, 'main'); amount := v_amt;
    return next;
  end loop;
end;
$$;
revoke all on function autopay_due_v2(date) from public, anon, authenticated;
grant execute on function autopay_due_v2(date) to service_role;

-- ---------------------------------------------------------------------------
-- Staff: see every authorization and check the log has not been altered.
create or replace function autopay_verify_log()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare e record; a autopay_authorizations; v_prev text := null; n int := 0; v_bad bigint; v_bad_a uuid; na int := 0;
begin
  if not (auth.role() = 'service_role' or (condo_session_ok() and condo_is_staff())) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  for e in select * from autopay_events order by id loop
    n := n + 1;
    if e.prev_hash is distinct from v_prev or e.row_hash <> autopay_hash(concat_ws('|', coalesce(v_prev, ''), e.authorization_id::text, extract(epoch from e.at)::text, e.kind, e.detail::text, e.actor)) then
      v_bad := e.id; exit;
    end if;
    v_prev := e.row_hash;
  end loop;
  for a in select * from autopay_authorizations loop
    na := na + 1;
    if a.row_hash <> autopay_auth_hash(a) then v_bad_a := a.id; exit; end if;
  end loop;
  return jsonb_build_object('ok', v_bad is null and v_bad_a is null, 'events_checked', n, 'authorizations_checked', na, 'first_bad_event', v_bad, 'first_bad_authorization', v_bad_a);
end;
$$;
revoke all on function autopay_verify_log() from public, anon;
grant execute on function autopay_verify_log() to authenticated, service_role;

create or replace function autopay_staff_list()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object('enabled', condo_setting('autopay_enabled', 'off') = 'on',
    'rows', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'tenant', t.name, 'status', a.status, 'amount', a.amount, 'draw_day', a.draw_day, 'bank', a.bank_label,
        'created_at', a.created_at, 'activated_at', a.activated_at, 'ended_by', a.ended_by, 'ended_reason', a.ended_reason, 'typed_name', a.typed_name, 'ip', a.ip, 'terms_version', a.terms_version,
        'label', coalesce((select ru.address from leases l join rental_units ru on ru.id = l.unit_id where l.id = a.lease_id), (select p.street from land_contracts c join rental_properties p on p.id = c.property_id where c.id = a.land_contract_id)),
        'events', coalesce((select jsonb_agg(jsonb_build_object('at', e.at, 'kind', e.kind, 'actor', e.actor) order by e.id desc) from (select * from autopay_events where authorization_id = a.id order by id desc limit 12) e), '[]'::jsonb))
      order by a.created_at desc) from autopay_authorizations a join tenants t on t.id = a.tenant_id), '[]'::jsonb));
end;
$$;
revoke all on function autopay_staff_list() from public, anon;
grant execute on function autopay_staff_list() to authenticated;

-- Daily: an autopay withdrawal with no matching log entry is raised at once.
create or replace function autopay_audit(p_as_of date)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare n int;
begin
  select count(*) into n from stripe_payments sp where sp.origin = 'autopay' and sp.created_at > now() - interval '3 days'
     and not exists (select 1 from autopay_events e where e.kind = 'debit_started' and e.detail ->> 'stripe_payment_id' = sp.id::text);
  if n > 0 then
    perform office_alert('autopay_alert_email', 'autopay', 'Autopay withdrawal with no authorization record', '<p>' || n || ' autopay withdrawal(s) in the last 3 days have no matching entry in the autopay log. Open Autopay in the staff menu and check the log.</p>');
  end if;
  return jsonb_build_object('unlogged', n, 'log', autopay_verify_log());
end;
$$;
revoke all on function autopay_audit(date) from public, anon, authenticated;
grant execute on function autopay_audit(date) to service_role;
