-- Autopay: 10-day notice before every withdrawal (Stephen, 10/14/2026). Autopay is still OFF; nobody is enrolled.
-- A withdrawal whose amount can vary needs notice of the date and amount at least 10 days ahead (Regulation E, 12 CFR 1005.10(d)),
-- unless the consumer chooses to be told only when it falls outside an agreed range. So:
--   * reminders go out 10, 7, 3 and 1 day before each withdrawal (was 7, 3, 1), plus the "being withdrawn today" email;
--   * the first withdrawal is at least 11 days after signing (was 8), so the 10-day reminder always fits;
--   * the terms tell the tenant of the right to notice of every amount, and record their choice of the range "up to the approved amount".
-- New terms version autopay-2026-10-v2: a page still showing v1 is asked to reload.

-- The first withdrawal: at least 11 days after the tenant signed AND after the bank was verified, on the day they chose.
create or replace function autopay_first_draw(a autopay_authorizations)
returns date language sql stable as $$
  select autopay_next_draw(a.draw_day, greatest((a.created_at at time zone 'America/Chicago')::date,
                                                coalesce((a.activated_at at time zone 'America/Chicago')::date, (a.created_at at time zone 'America/Chicago')::date)) + 11);
$$;
revoke all on function autopay_first_draw(autopay_authorizations) from public, anon, authenticated;

create or replace function autopay_terms(p_name text, p_amount numeric, p_day int, p_label text, p_is_lease boolean, p_first date)
returns text language plpgsql stable security definer set search_path = public as $$
declare v_fee text := coalesce(nullif((select value from portal_settings where key = 'returned_payment_fee'), ''), '0');
begin
  return 'AUTOPAY AUTHORIZATION' || E'\n\n'
    || 'I, ' || p_name || ', authorize 2nd Chance Housing Inc. to withdraw money electronically (ACH) from the bank account I connect, to pay my '
       || case when p_is_lease then 'rent for ' else 'land contract payment for ' end || p_label || '.' || E'\n\n'
    || '• Amount: ' || to_char(p_amount, 'FM$999,990.00') || ' each month, or less if I owe less. It will never be more than this unless I approve a new amount myself.' || E'\n'
    || '• Date: on the ' || p_day || case p_day when 1 then 'st' when 2 then 'nd' when 3 then 'rd' else 'th' end || ' of each month. My first withdrawal is ' || to_char(p_first, 'FMMonth FMDD, YYYY') || '.' || E'\n'
    || '• Reminders: I will get an email 10 days, 7 days, 3 days and 1 day before each withdrawal, with its date and the most it can be, and an email on the day with the exact amount. If the 1-day reminder cannot be sent to me, no money is withdrawn that month.' || E'\n'
    || '• Varying amount: I have the right to be told the amount and date of every withdrawal at least 10 days before it. I agree that each withdrawal is what I owe that day and may be any amount up to the amount above, and I choose to be told the exact amount ahead of time only if it would be more than that amount (which autopay never does).' || E'\n'
    || '• Stopping it: I can cancel any time in my portal (Payments, Autopay, Cancel). To stop a withdrawal, I cancel before 11:59 PM the day before it.' || E'\n'
    || '• If my account does not have enough money: the withdrawal may be returned. Then my ' || case when p_is_lease then 'rent' else 'payment' end || ' is still due'
       || case when p_is_lease and v_fee::numeric > 0 then ', a returned payment fee of ' || to_char(v_fee::numeric, 'FM$999,990.00') || ' may be charged (as my lease provides)' else '' end
       || ', late fees and notices follow the normal schedule, my bank may also charge me, and autopay pauses until I turn it on again myself. There is no automatic second try.' || E'\n'
    || '• Only I can turn autopay on or change it. 2nd Chance staff cannot start or change it. Staff can pause it for safety, and I am emailed right away.' || E'\n'
    || '• If my ' || case when p_is_lease then 'rent' else 'payment' end || ' changes, autopay keeps withdrawing no more than the amount above until I approve a new amount.' || E'\n\n'
    || 'I set this up myself, from my own sign-in.';
end;
$$;
revoke all on function autopay_terms(text, numeric, int, text, boolean, date) from public, anon, authenticated;

create or replace function autopay_prepare(p_draw_day int default 1)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_t uuid := autopay_me(); s record; v_first date; v_day int := coalesce(p_draw_day, 1); v_email text;
begin
  if not exists (select 1 from resident_me()) then raise exception 'Resident sign-in required' using errcode = '42501'; end if;
  if autopay_view_as_session() then raise exception 'Autopay can only be set up by the tenant, from their own sign-in.'; end if;
  if condo_setting('autopay_enabled', 'off') <> 'on' then raise exception 'Autopay is not available yet.'; end if;
  if v_t is null then raise exception 'Autopay is for an active lease or land contract.'; end if;
  if v_day not between 1 and 5 then raise exception 'Choose a day from the 1st to the 5th.'; end if;
  select * into s from autopay_start_checks(v_t);
  select email into v_email from tenants where id = v_t;
  if coalesce(v_email, '') not like '%@%' then raise exception 'We need your email address on file first, because every withdrawal is announced by email. Update it under Profile.'; end if;
  v_first := autopay_next_draw(v_day, autopay_today() + 11);
  return jsonb_build_object('amount', s.amount, 'label', s.label, 'is_lease', s.is_lease, 'draw_day', v_day, 'first_draw', v_first,
    'version', 'autopay-2026-10-v2', 'terms', autopay_terms('[your full name]', s.amount, v_day, s.label, s.is_lease, v_first),
    'email_hint', left(v_email, 2) || '***' || substr(v_email, position('@' in v_email)));
end;
$$;
revoke all on function autopay_prepare(int) from public, anon;
grant execute on function autopay_prepare(int) to authenticated;

create or replace function autopay_start(p_code text, p_draw_day int, p_typed_name text, p_acks jsonb, p_version text, p_first date)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_t uuid := autopay_me(); s record; v_name text; v_email text; c autopay_codes; a autopay_authorizations; v_first date; v_terms text;
  v_hdr jsonb := coalesce(nullif(current_setting('request.headers', true), '')::jsonb, '{}'::jsonb); v_words text[]; v_typed text[];
begin
  if not exists (select 1 from resident_me()) then raise exception 'Resident sign-in required' using errcode = '42501'; end if;
  if autopay_view_as_session() then raise exception 'Autopay can only be set up by the tenant, from their own sign-in.'; end if;
  if condo_setting('autopay_enabled', 'off') <> 'on' then raise exception 'Autopay is not available yet.'; end if;
  if v_t is null then raise exception 'Autopay is for an active lease or land contract.'; end if;
  if p_version is distinct from 'autopay-2026-10-v2' then raise exception 'These terms changed. Reload the page and read them again.'; end if;
  if coalesce(p_draw_day, 0) not between 1 and 5 then raise exception 'Choose a day from the 1st to the 5th.'; end if;
  if not (coalesce(p_acks ->> 'set_up_myself', 'false') = 'true' and coalesce(p_acks ->> 'understand_return', 'false') = 'true'
          and coalesce(p_acks ->> 'keep_money', 'false') = 'true' and coalesce(p_acks ->> 'can_cancel', 'false') = 'true') then
    raise exception 'Check all four boxes to show you read and agree.';
  end if;
  select * into s from autopay_start_checks(v_t);
  select name, email into v_name, v_email from tenants where id = v_t;
  if coalesce(v_email, '') not like '%@%' then raise exception 'We need your email address on file first.'; end if;
  -- the typed name must contain the first and last name on file
  v_words := regexp_split_to_array(lower(regexp_replace(coalesce(v_name, ''), '[^A-Za-z ]', ' ', 'g')), '\s+');
  v_typed := regexp_split_to_array(lower(regexp_replace(coalesce(p_typed_name, ''), '[^A-Za-z ]', ' ', 'g')), '\s+');
  if array_length(v_words, 1) >= 2 and not (v_words[1] = any (v_typed) and v_words[array_length(v_words, 1)] = any (v_typed)) then
    raise exception 'Type your full name as it appears on your account.';
  end if;
  -- the code (a wrong code returns {error} rather than raising, so the attempt count is kept)
  select * into c from autopay_codes where tenant_id = v_t and used_at is null and expires_at > now() order by id desc limit 1 for update;
  if c.id is null then raise exception 'That code has expired. Ask for a new one.'; end if;
  if c.attempts >= 5 then raise exception 'Too many wrong tries. Ask for a new code.'; end if;
  if c.code_hash <> autopay_hash(v_t::text || ':' || trim(coalesce(p_code, ''))) then
    update autopay_codes set attempts = attempts + 1 where id = c.id;
    return jsonb_build_object('error', case when c.attempts + 1 >= 5 then 'That code is not right. Too many wrong tries: ask for a new code.' else 'That code is not right.' end);
  end if;
  update autopay_codes set used_at = now() where id = c.id;
  v_first := autopay_next_draw(p_draw_day, autopay_today() + 11);
  if p_first is distinct from v_first then raise exception 'The page is out of date. Reload it and try again.'; end if;
  v_terms := autopay_terms(trim(p_typed_name), s.amount, p_draw_day, s.label, s.is_lease, v_first);
  -- replace any unfinished setup
  perform autopay_set_actor('tenant');
  update autopay_authorizations set status = 'canceled', ended_at = now(), ended_by = 'tenant', ended_reason = 'replaced by a new setup' where tenant_id = v_t and status = 'pending';
  insert into autopay_authorizations (tenant_id, lease_id, land_contract_id, amount, draw_day, terms_version, terms_text, acks, typed_name, ip, user_agent, row_hash)
  values (v_t, s.lease_id, s.land_contract_id, s.amount, p_draw_day, p_version, v_terms, p_acks, left(trim(p_typed_name), 200),
          left(coalesce(v_hdr ->> 'cf-connecting-ip', v_hdr ->> 'x-forwarded-for', ''), 80), left(coalesce(v_hdr ->> 'user-agent', ''), 300), 'pending')
  returning * into a;
  perform autopay_event(a.id, 'created', jsonb_build_object('amount', a.amount, 'draw_day', a.draw_day, 'first_draw', v_first, 'terms_version', a.terms_version, 'ip', a.ip), 'tenant');
  return jsonb_build_object('authorization_id', a.id);
end;
$$;
revoke all on function autopay_start(text, int, text, jsonb, text, date) from public, anon;
grant execute on function autopay_start(text, int, text, jsonb, text, date) to authenticated;

-- Reminders 10, 7, 3 and 1 day before, only from the first date in the terms on, and only while the withdrawal can really happen.
create or replace function autopay_send_reminders(p_as_of date, p_keyed text[] default null)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
#variable_conflict use_column
declare a autopay_authorizations; s record; v_draw date; v_days int; v_kind text; v_name text; v_email text; v_amt numeric; v_oid bigint; v_subj text; n int := 0; v_stopped int := 0; v_wait int := 0;
begin
  if condo_setting('autopay_enabled', 'off') <> 'on' then return jsonb_build_object('skipped', 'autopay is off'); end if;
  for a in select * from autopay_authorizations where status = 'active' order by activated_at, id loop
    if not autopay_still_valid(a) then v_stopped := v_stopped + 1; continue; end if;
    select * into s from autopay_subject(a.tenant_id) x where (a.lease_id is not null and x.lease_id = a.lease_id) or (a.land_contract_id is not null and x.land_contract_id = a.land_contract_id) limit 1;
    v_draw := autopay_next_draw(a.draw_day, greatest(p_as_of, autopay_first_draw(a))); v_days := v_draw - p_as_of;
    continue when v_days not in (10, 7, 3, 1);
    v_kind := 'reminder_' || v_days;
    continue when exists (select 1 from autopay_events e where e.authorization_id = a.id and e.kind = v_kind and e.detail ->> 'cycle' = v_draw::text);
    continue when a.activated_at is not null and (a.activated_at at time zone 'America/Chicago')::date > p_as_of;
    -- No reminder while the withdrawal could not happen (online payments off): on the day the tenant is told nothing was withdrawn.
    if not autopay_account_ready(coalesce(a.stripe_account, 'main'), p_keyed) then v_wait := v_wait + 1; continue; end if;
    select name, email into v_name, v_email from tenants where id = a.tenant_id;
    continue when coalesce(v_email, '') not like '%@%';
    v_amt := least(a.amount, s.amount);
    v_subj := '[Autopay] Up to ' || to_char(v_amt, 'FM$999,990.00') || ' will be withdrawn ' || to_char(v_draw, 'FMMon FMDD') || ' (' || v_days || ' day' || case when v_days = 1 then '' else 's' end || ')';
    v_oid := autopay_email(v_email, v_subj,
      '<p>Hi ' || repair_esc(split_part(coalesce(v_name, ''), ' ', 1)) || ',</p><p>In <b>' || v_days || ' day' || case when v_days = 1 then '' else 's' end || '</b>, on <b>' || to_char(v_draw, 'FMDay, FMMonth FMDD') || '</b>,'
      || ' your autopay will withdraw what you owe that day, up to <b>' || to_char(v_amt, 'FM$999,990.00') || '</b>, from <b>' || repair_esc(coalesce(a.bank_label, 'your bank account')) || '</b> for ' || repair_esc(coalesce(s.label, '')) || '.</p>'
      || '<p><b>Please make sure the money is in the account.</b> If the withdrawal is returned, ' || case when a.lease_id is not null then 'your rent is still due, late fees and notices follow, a returned payment fee may apply, ' else 'your payment is still due, ' end
      || 'your bank may charge you, and autopay pauses.</p>'
      || case when s.amount > a.amount then '<p>Your ' || case when a.lease_id is not null then 'rent' else 'payment' end || ' is now ' || to_char(s.amount, 'FM$999,990.00') || '. Autopay will only withdraw ' || to_char(a.amount, 'FM$999,990.00')
           || ' until you approve a new amount yourself. Pay the rest in your portal.</p>' else '' end
      || '<p>To stop this withdrawal, sign in and cancel autopay <b>before 11:59 PM on ' || to_char(v_draw - 1, 'FMDay, FMMonth FMDD') || '</b>: <a href="https://2ndchinc.org/resident/#payments">your portal</a>, Payments, Autopay, Cancel.</p>'
      || '<p>Questions: (262) 236-5443.</p><p>2nd Chance Housing</p>', 'autopay_reminder');
    perform autopay_event(a.id, v_kind, jsonb_build_object('cycle', v_draw::text, 'outbox_id', v_oid, 'amount', v_amt), 'system');
    n := n + 1;
  end loop;
  return jsonb_build_object('reminders', n, 'stopped', v_stopped, 'waiting_for_online_payments', v_wait);
end;
$$;
revoke all on function autopay_send_reminders(date, text[]) from public, anon, authenticated;
grant execute on function autopay_send_reminders(date, text[]) to service_role;

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
      || '<p>We will email you 10 days, 7 days, 3 days and 1 day before every withdrawal, and on the day. <b>Please keep enough money in the account.</b> A returned withdrawal can cost you a fee and late rent, and autopay will pause.</p>'
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
