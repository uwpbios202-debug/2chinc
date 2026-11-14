-- Autopay: start only once the bank account is VERIFIED (Stephen, 10/14/2026). Autopay is still off; nobody is enrolled.
-- Some banks are verified at once; others need Stripe's small test deposits (up to a few days). Until Stripe says the bank is verified
-- (setup_intent.succeeded), the authorization stays pending: nothing can be withdrawn. If verification fails, the setup is canceled
-- and the tenant is told. A late verification can only move the first withdrawal later (never earlier), and every reminder still fits.

-- The first withdrawal: at least 8 days after the tenant signed AND after the bank was verified, on the day they chose.
create or replace function autopay_first_draw(a autopay_authorizations)
returns date language sql stable as $$
  select autopay_next_draw(a.draw_day, greatest((a.created_at at time zone 'America/Chicago')::date,
                                                coalesce((a.activated_at at time zone 'America/Chicago')::date, (a.created_at at time zone 'America/Chicago')::date)) + 8);
$$;
revoke all on function autopay_first_draw(autopay_authorizations) from public, anon, authenticated;

-- The bank was connected but Stripe is still verifying it: log it (once) and tell the tenant nothing is withdrawn until it is verified.
create or replace function autopay_bank_verifying(p_auth uuid, p_setup_intent text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare a autopay_authorizations; v_name text; v_email text;
begin
  select * into a from autopay_authorizations where id = p_auth for update;
  if a.id is null or a.status <> 'pending' then return jsonb_build_object('ok', false, 'reason', 'not pending'); end if;
  if exists (select 1 from autopay_events e where e.authorization_id = a.id and e.kind = 'bank_verifying') then return jsonb_build_object('ok', true, 'already', true); end if;
  perform autopay_event(a.id, 'bank_verifying', jsonb_build_object('setup_intent', p_setup_intent), 'webhook');
  select name, email into v_name, v_email from tenants where id = a.tenant_id;
  if coalesce(v_email, '') like '%@%' then
    perform autopay_email(v_email, '[Autopay] Your bank needs to be verified before autopay starts',
      '<p>Hi ' || repair_esc(split_part(coalesce(v_name, ''), ' ', 1)) || ',</p><p>You connected your bank account for autopay. <b>Your bank still has to be verified</b>, '
      || 'usually with one or two small test deposits. Watch for an email from Stripe and follow its steps.</p>'
      || '<p><b>Autopay is not on yet and nothing will be withdrawn</b> until the bank is verified. We will email you when it is on, with the date of your first withdrawal. '
      || 'Until then, please pay as usual in your <a href="https://2ndchinc.org/resident/#payments">portal</a>.</p><p>Questions: (262) 236-5443.</p><p>2nd Chance Housing</p>', 'autopay_setup');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;
revoke all on function autopay_bank_verifying(uuid, text) from public, anon, authenticated;
grant execute on function autopay_bank_verifying(uuid, text) to service_role;

-- The bank could not be verified (or the setup failed): the setup is canceled and the tenant is told. Nothing was or will be withdrawn.
create or replace function autopay_setup_failed(p_auth uuid, p_reason text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare a autopay_authorizations; v_name text; v_email text;
begin
  select * into a from autopay_authorizations where id = p_auth for update;
  if a.id is null or a.status <> 'pending' then return jsonb_build_object('ok', false, 'reason', 'not pending'); end if;
  perform autopay_set_actor('system');
  update autopay_authorizations set status = 'canceled', ended_at = now(), ended_by = 'system', ended_reason = left('the bank could not be verified: ' || coalesce(p_reason, ''), 300) where id = a.id;
  perform autopay_event(a.id, 'canceled', jsonb_build_object('reason', 'bank not verified', 'detail', left(coalesce(p_reason, ''), 300)), 'webhook');
  select name, email into v_name, v_email from tenants where id = a.tenant_id;
  if coalesce(v_email, '') like '%@%' then
    perform autopay_email(v_email, '[Autopay] Autopay was NOT set up: your bank could not be verified',
      '<p>Hi ' || repair_esc(split_part(coalesce(v_name, ''), ' ', 1)) || ',</p><p>Your bank account <b>could not be verified</b>, so autopay was <b>not</b> set up. <b>Nothing will be withdrawn.</b></p>'
      || '<p>Please pay in your <a href="https://2ndchinc.org/resident/#payments">portal</a>. You can try setting up autopay again any time. Questions: (262) 236-5443.</p><p>2nd Chance Housing</p>', 'autopay_setup');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;
revoke all on function autopay_setup_failed(uuid, text) from public, anon, authenticated;
grant execute on function autopay_setup_failed(uuid, text) to service_role;

create or replace function autopay_status_mine()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_t uuid := autopay_me();
begin
  if not exists (select 1 from resident_me()) then raise exception 'Resident sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'enabled', condo_setting('autopay_enabled', 'off') = 'on',
    'authorizations', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'status', a.status, 'amount', a.amount, 'draw_day', a.draw_day, 'bank', a.bank_label,
          'is_lease', a.lease_id is not null, 'created_at', a.created_at, 'activated_at', a.activated_at, 'ended_by', a.ended_by, 'ended_reason', a.ended_reason,
          'verifying', a.status = 'pending' and exists (select 1 from autopay_events e where e.authorization_id = a.id and e.kind = 'bank_verifying'),
          'next_draw', case when a.status = 'active' then autopay_next_draw(a.draw_day, greatest(autopay_today(), autopay_first_draw(a))) end,
          'ready', a.status = 'active' and condo_setting('autopay_enabled', 'off') = 'on' and autopay_account_ready(coalesce(a.stripe_account, 'main')),
          'label', coalesce((select ru.address from leases l join rental_units ru on ru.id = l.unit_id where l.id = a.lease_id),
                            (select p.street from land_contracts c join rental_properties p on p.id = c.property_id where c.id = a.land_contract_id)))
        order by a.created_at desc)
      from autopay_authorizations a where a.tenant_id in (select resident_me()) and (a.status in ('active', 'pending', 'paused') or a.ended_at > now() - interval '14 days')), '[]'::jsonb),
    'recent', coalesce((select jsonb_agg(jsonb_build_object('at', e.at, 'kind', e.kind) order by e.id desc)
      from (select e2.* from autopay_events e2 join autopay_authorizations a2 on a2.id = e2.authorization_id where a2.tenant_id in (select resident_me()) order by e2.id desc limit 8) e), '[]'::jsonb),
    'can_start', v_t is not null);
end;
$$;
revoke all on function autopay_status_mine() from public, anon;
grant execute on function autopay_status_mine() to authenticated;

create or replace function autopay_activate(p_auth uuid, p_customer text, p_account text, p_pm text, p_bank text, p_setup_intent text, p_mandate text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare a autopay_authorizations; v_name text; v_email text; v_first date; v_label text; o record; v_why text; v_old uuid;
begin
  select * into a from autopay_authorizations where id = p_auth;
  if a.id is null then return jsonb_build_object('ok', false, 'reason', 'not found'); end if;
  perform pg_advisory_xact_lock(7117002, hashtext(coalesce(a.lease_id, a.land_contract_id)::text));   -- one activation per lease/contract at a time
  select * into a from autopay_authorizations where id = p_auth for update;
  if a.status <> 'pending' then return jsonb_build_object('ok', false, 'reason', 'not pending'); end if;
  select name, email into v_name, v_email from tenants where id = a.tenant_id;
  if a.created_at < now() - interval '2 hours'
     and not (a.created_at > now() - interval '14 days' and exists (select 1 from autopay_events e where e.authorization_id = a.id and e.kind = 'bank_verifying')) then
    v_why := 'the bank was not connected in time';
  elsif exists (select 1 from autopay_authorizations x where x.status = 'active' and coalesce(x.lease_id, x.land_contract_id) = coalesce(a.lease_id, a.land_contract_id)) then
    v_why := 'autopay is already on for this lease';
  elsif autopay_expected_account(a.lease_id, a.land_contract_id) is distinct from coalesce(nullif(p_account, ''), 'main') then
    v_why := 'the bank was connected for a different account than this lease is paid to';
  end if;
  if v_why is not null then
    perform autopay_set_actor('system');
    update autopay_authorizations set status = case when v_why like '%in time' then 'expired' else 'canceled' end, ended_at = now(), ended_by = 'system', ended_reason = v_why where id = a.id;
    perform autopay_event(a.id, case when v_why like '%in time' then 'expired' else 'canceled' end, jsonb_build_object('reason', v_why), 'system');
    if coalesce(v_email, '') like '%@%' then
      perform autopay_email(v_email, '[Autopay] Autopay was NOT set up',
        '<p>Hi ' || repair_esc(split_part(coalesce(v_name, ''), ' ', 1)) || ',</p><p>Your autopay setup was <b>not</b> completed because ' || repair_esc(v_why)
        || '. <b>No money will be withdrawn.</b> Please pay in your <a href="https://2ndchinc.org/resident/#payments">portal</a>, or call (262) 236-5443.</p><p>2nd Chance Housing</p>', 'autopay_setup');
    end if;
    return jsonb_build_object('ok', false, 'reason', v_why);
  end if;
  perform autopay_set_actor('webhook');
  update autopay_authorizations set status = 'active', stripe_account = coalesce(nullif(p_account, ''), 'main'), customer_id = p_customer, payment_method_id = p_pm,
         bank_label = p_bank, setup_intent = p_setup_intent, mandate = p_mandate, activated_at = now() where id = a.id;
  perform autopay_event(a.id, 'activated', jsonb_build_object('bank', p_bank, 'setup_intent', p_setup_intent, 'mandate', p_mandate), 'webhook');
  -- the tenant's own older paused autopay for the same lease/contract is replaced by this one
  perform autopay_set_actor('system');
  for v_old in select x.id from autopay_authorizations x where x.tenant_id = a.tenant_id and x.status = 'paused' and coalesce(x.lease_id, x.land_contract_id) = coalesce(a.lease_id, a.land_contract_id) loop
    update autopay_authorizations set status = 'canceled', ended_by = 'system', ended_reason = 'replaced by a new setup' where id = v_old;
    perform autopay_event(v_old, 'canceled', jsonb_build_object('reason', 'replaced by a new setup'), 'system');
  end loop;
  select * into a from autopay_authorizations where id = a.id;
  v_first := autopay_first_draw(a);
  v_label := coalesce((select ru.address from leases l join rental_units ru on ru.id = l.unit_id where l.id = a.lease_id),
                      (select p.street from land_contracts c join rental_properties p on p.id = c.property_id where c.id = a.land_contract_id));
  if coalesce(v_email, '') like '%@%' then
    perform autopay_email(v_email, '[Autopay] You set up autopay: first withdrawal ' || to_char(v_first, 'FMMon FMDD'),
      '<p>Hi ' || repair_esc(split_part(coalesce(v_name, ''), ' ', 1)) || ',</p><p><b>You set up autopay.</b> This email is your record of what you agreed to.</p>'
      || '<ul><li>Amount: up to <b>' || to_char(a.amount, 'FM$999,990.00') || '</b> a month (less if you owe less)</li><li>From: <b>' || repair_esc(coalesce(p_bank, 'your bank account')) || '</b></li>'
      || '<li>Date: the <b>' || a.draw_day || '</b> of each month. First withdrawal: <b>' || to_char(v_first, 'FMMonth FMDD, YYYY') || '</b></li>'
      || '<li>For: ' || repair_esc(coalesce(v_label, '')) || '</li></ul>'
      || '<p>We will email you 7 days, 3 days and 1 day before every withdrawal, and on the day. <b>Please keep enough money in the account.</b> A returned withdrawal can cost you a fee and late rent, and autopay will pause.</p>'
      || '<p>To cancel at any time: sign in to your <a href="https://2ndchinc.org/resident/#payments">portal</a>, Payments, Autopay, Cancel. Cancel before 11:59 PM the day before a withdrawal to stop it.</p>'
      || '<p>If you did not do this, cancel it now and call (262) 236-5443.</p><p>2nd Chance Housing</p>', 'autopay_setup');
  end if;
  -- the other people on a joint lease are told whose bank it is
  for o in select t.name, t.email from lease_tenants lt join tenants t on t.id = lt.tenant_id where lt.lease_id = a.lease_id and lt.tenant_id <> a.tenant_id and coalesce(t.email, '') like '%@%'
  loop
    perform autopay_email(o.email, '[Autopay] ' || split_part(coalesce(v_name, ''), ' ', 1) || ' set up autopay for your rent',
      '<p>Hi ' || repair_esc(split_part(coalesce(o.name, ''), ' ', 1)) || ',</p><p>' || repair_esc(coalesce(v_name, '')) || ' set up autopay for the rent at ' || repair_esc(coalesce(v_label, '')) || ', to be withdrawn from their own bank account on the '
      || a.draw_day || ' of each month. You do not need to do anything. If you also pay yourself, check your balance first so rent is not paid twice.</p><p>2nd Chance Housing</p>', 'autopay_setup');
  end loop;
  return jsonb_build_object('ok', true);
end;
$$;
revoke all on function autopay_activate(uuid, text, text, text, text, text, text) from public, anon, authenticated;
grant execute on function autopay_activate(uuid, text, text, text, text, text, text) to service_role;
