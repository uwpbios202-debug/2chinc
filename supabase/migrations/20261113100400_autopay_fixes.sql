-- Autopay fixes from the review of the rebuild (Stephen, 10/14/2026). Autopay is still OFF (autopay_enabled) and nobody is enrolled.
--   1. Never two withdrawals for one lease or land contract: one active autopay per lease/contract (unique index), setup refused
--      when one is already on, and the charge list returns at most one withdrawal per lease/contract per day.
--   2. Nothing is withdrawn (and no reminder sent) before the first withdrawal date written in the terms the tenant signed.
--   3. A tenant who was reminded is ALWAYS told when nothing is withdrawn (online payments off, a payment still processing,
--      a reported payment being checked, reminder unconfirmed, nothing owed). Reminders go out only while the withdrawal can happen.
--      An abandoned "Pay now" no longer blocks autopay forever. The "on the day" email is sent only when a withdrawal is really started.
--   4. Autopay pauses (and the tenant is told) when the lease's rent goes to a different account than the one autopay was set up with,
--      and it cannot be set up for a lease paid by Zelle/bank transfer to an account with no online payment.
--   7. The setup code is no longer in the email subject (staff can see subjects on the unit's messages).
-- (5 and 6 are in rent-cycle.)

-- ---------------------------------------------------------------------------
-- A paused autopay can be canceled (by the tenant, or by the system when replaced). Everything else is unchanged.
create or replace function autopay_auth_guard()
returns trigger language plpgsql as $$
declare v_actor text := coalesce(current_setting('app.autopay_actor', true), ''); v_ok boolean := false;
begin
  if tg_op = 'DELETE' then raise exception 'Autopay records cannot be deleted.'; end if;
  if (new.id, new.tenant_id, new.lease_id, new.land_contract_id, new.amount, new.draw_day, new.terms_version, new.terms_text, new.acks, new.typed_name, new.ip, new.user_agent, new.created_at, new.row_hash)
     is distinct from (old.id, old.tenant_id, old.lease_id, old.land_contract_id, old.amount, old.draw_day, old.terms_version, old.terms_text, old.acks, old.typed_name, old.ip, old.user_agent, old.created_at, old.row_hash) then
    raise exception 'The terms of an autopay authorization cannot be changed.';
  end if;
  if (new.status, new.stripe_account, new.customer_id, new.payment_method_id, new.bank_label, new.setup_intent, new.mandate, new.activated_at, new.ended_at, new.ended_by, new.ended_reason)
     is distinct from (old.status, old.stripe_account, old.customer_id, old.payment_method_id, old.bank_label, old.setup_intent, old.mandate, old.activated_at, old.ended_at, old.ended_by, old.ended_reason) then
    if old.status <> 'pending' and (new.stripe_account, new.customer_id, new.payment_method_id, new.bank_label, new.setup_intent, new.mandate, new.activated_at)
         is distinct from (old.stripe_account, old.customer_id, old.payment_method_id, old.bank_label, old.setup_intent, old.mandate, old.activated_at) then
      raise exception 'The bank on an autopay authorization cannot be changed.';
    end if;
    v_ok := (old.status = 'pending' and new.status = 'active' and v_actor = 'webhook')
         or (old.status = 'pending' and new.status = 'canceled' and v_actor in ('tenant', 'system'))
         or (old.status = 'pending' and new.status = 'expired' and v_actor = 'system')
         or (old.status = 'active' and new.status = 'canceled' and v_actor in ('tenant', 'system'))
         or (old.status = 'active' and new.status = 'paused' and v_actor in ('staff_pause', 'system'))
         or (old.status = 'paused' and new.status = 'canceled' and v_actor in ('tenant', 'system'))
         or (old.status = new.status and v_actor <> '');
    if not v_ok then raise exception 'Only the tenant can start or cancel autopay. Staff can only pause it.'; end if;
  end if;
  return new;
end;
$$;

-- 1. The database itself refuses a second active autopay on one lease or land contract.
create unique index if not exists autopay_one_active_per_subject on autopay_authorizations ((coalesce(lease_id, land_contract_id))) where status = 'active';

-- ---------------------------------------------------------------------------
-- Helpers
-- The first withdrawal date written in the terms the tenant signed (at least 8 days after they signed, so every reminder fits).
create or replace function autopay_first_draw(a autopay_authorizations)
returns date language sql stable as $$
  select autopay_next_draw(a.draw_day, (a.created_at at time zone 'America/Chicago')::date + 8);
$$;
revoke all on function autopay_first_draw(autopay_authorizations) from public, anon, authenticated;

-- The Stripe account a lease's rent goes to now ('main' = 2nd Chance). NULL = no online payment for it (Zelle/bank transfer only).
-- Land contracts are paid to 2nd Chance.
create or replace function autopay_expected_account(p_lease uuid, p_lc uuid)
returns text language sql stable security definer set search_path = public as $$
  select case when p_lease is null then 'main'
              else (select case when l.pay_to_account_id is null then 'main' else nullif(ba.stripe_account, '') end
                      from leases l left join bank_accounts ba on ba.id = l.pay_to_account_id where l.id = p_lease) end;
$$;
revoke all on function autopay_expected_account(uuid, uuid) from public, anon, authenticated;

-- Can money be taken through this account right now? p_keyed = accounts whose Stripe key is set (from rent-cycle; NULL = don't check).
create or replace function autopay_account_ready(p_acct text, p_keyed text[] default null)
returns boolean language sql stable security definer set search_path = public as $$
  select p_acct is not null and condo_setting('stripe_enabled', 'off') = 'on'
     and (p_acct = 'main' or condo_setting('stripe_enabled_' || p_acct, 'off') = 'on')
     and (p_keyed is null or p_acct = any (p_keyed));
$$;
revoke all on function autopay_account_ready(text, text[]) from public, anon, authenticated;

-- What a tenant pays, lease first (a tenant with both a lease and a land contract always gets the same one).
create or replace function autopay_subject(p_tenant uuid)
returns table (lease_id uuid, land_contract_id uuid, amount numeric, label text, is_lease boolean)
language sql stable security definer set search_path = public as $$
  select x.* from (
    select l.id as lease_id, null::uuid as land_contract_id, coalesce(lease_tenant_rent(l.id), l.rent) as amount, ru.address as label, true as is_lease
      from lease_tenants lt join leases l on l.id = lt.lease_id and l.status = 'active' join rental_units ru on ru.id = l.unit_id
     where lt.tenant_id = p_tenant and coalesce(l.rent, 0) > 0
    union all
    select null::uuid, c.id, c.monthly_payment, p.street, false
      from land_contract_buyers b join land_contracts c on c.id = b.contract_id and c.status = 'active' join rental_properties p on p.id = c.property_id
     where b.tenant_id = p_tenant) x
  order by x.is_lease desc, x.lease_id, x.land_contract_id;
$$;
revoke all on function autopay_subject(uuid) from public, anon, authenticated;

-- The checks before a tenant may set up autopay (used by prepare, request code, start and the bank connection step).
create or replace function autopay_start_checks(p_tenant uuid)
returns table (lease_id uuid, land_contract_id uuid, amount numeric, label text, is_lease boolean, account text)
language plpgsql stable security definer set search_path = public as $$
#variable_conflict use_column
declare s record; v_acct text; v_other uuid;
begin
  select * into s from autopay_subject(p_tenant) limit 1;
  if s.amount is null then raise exception 'Autopay is for an active lease or land contract.'; end if;
  if condo_setting('stripe_enabled', 'off') <> 'on' then raise exception 'Autopay is not available yet.'; end if;
  v_acct := autopay_expected_account(s.lease_id, s.land_contract_id);
  if v_acct is null or not autopay_account_ready(v_acct) then
    raise exception 'Your rent is paid by Zelle or bank transfer to a specific account, so autopay is not available for it. Open Payments to see where to send it, or call or text (262) 236-5443.';
  end if;
  select a.tenant_id into v_other from autopay_authorizations a
   where a.status = 'active' and coalesce(a.lease_id, a.land_contract_id) = coalesce(s.lease_id, s.land_contract_id) limit 1;
  if v_other = p_tenant then raise exception 'Your autopay is already on. To change the amount, day or bank, cancel it first, then set it up again.'; end if;
  if v_other is not null then raise exception 'Autopay is already set up for this lease by another person on it. Only one autopay per lease, so the rent is never taken twice.'; end if;
  lease_id := s.lease_id; land_contract_id := s.land_contract_id; amount := s.amount; label := s.label; is_lease := s.is_lease; account := v_acct;
  return next;
end;
$$;
revoke all on function autopay_start_checks(uuid) from public, anon, authenticated;

-- Tell the tenant and the office (once per authorization and cycle) that nothing was withdrawn, and why.
create or replace function autopay_hold(p_auth uuid, p_cycle date, p_kind text, p_reason text, p_alert boolean)
returns void language plpgsql volatile security definer set search_path = public as $$
declare a autopay_authorizations; v_name text; v_email text; v_what text;
begin
  if p_kind not in ('held', 'skipped') then raise exception 'Bad kind'; end if;
  select * into a from autopay_authorizations where id = p_auth;
  if a.id is null then return; end if;
  if exists (select 1 from autopay_events e where e.authorization_id = a.id and e.kind in ('held', 'skipped') and e.detail ->> 'cycle' = p_cycle::text) then return; end if;
  perform autopay_event(a.id, p_kind, jsonb_build_object('cycle', p_cycle::text, 'reason', left(p_reason, 300)), 'system');
  select name, email into v_name, v_email from tenants where id = a.tenant_id;
  v_what := case when a.lease_id is not null then 'rent' else 'payment' end;
  if coalesce(v_email, '') like '%@%' then
    if p_kind = 'skipped' then
      perform autopay_email(v_email, '[Autopay] Nothing was withdrawn today: ' || p_reason,
        '<p>Hi ' || repair_esc(split_part(v_name, ' ', 1)) || ',</p><p><b>Nothing was withdrawn today</b>: ' || repair_esc(p_reason) || '.</p>'
        || '<p>Autopay stays on for next month. Check your balance any time in your <a href="https://2ndchinc.org/resident/#payments">portal</a>.</p><p>2nd Chance Housing</p>', 'autopay_held');
    else
      perform autopay_email(v_email, '[Autopay] Your autopay withdrawal was NOT made this month',
        '<p>Hi ' || repair_esc(split_part(v_name, ' ', 1)) || ',</p><p><b>We did not withdraw anything today</b>, because ' || repair_esc(p_reason) || '.</p>'
        || '<p><b>Your ' || v_what || ' is still due.</b> Please pay in your <a href="https://2ndchinc.org/resident/#payments">portal</a>, or call (262) 236-5443. Autopay stays on for next month.</p><p>2nd Chance Housing</p>', 'autopay_held');
    end if;
  end if;
  if p_alert then
    perform office_alert('autopay_alert_email', 'autopay', 'Autopay held: ' || coalesce(v_name, ''),
      '<p>No autopay withdrawal was made for ' || repair_esc(coalesce(v_name, '')) || ' on ' || to_char(p_cycle, 'FMMonth FMDD, YYYY') || ' because ' || repair_esc(p_reason) || '. The tenant was emailed. Check whether they need help paying.</p>');
  end if;
end;
$$;
revoke all on function autopay_hold(uuid, date, text, text, boolean) from public, anon, authenticated;
grant execute on function autopay_hold(uuid, date, text, text, boolean) to service_role;

-- Pause or end one active autopay for a reason that is not a bank return, and tell the tenant and the office.
create or replace function autopay_stop_one(p_auth uuid, p_status text, p_reason text, p_tenant_reason text)
returns void language plpgsql volatile security definer set search_path = public as $$
declare a autopay_authorizations; v_name text; v_email text;
begin
  if p_status not in ('paused', 'canceled') then raise exception 'Bad status'; end if;
  select * into a from autopay_authorizations where id = p_auth for update;
  if a.id is null or a.status <> 'active' then return; end if;
  perform autopay_set_actor('system');
  update autopay_authorizations set status = p_status, ended_at = now(), ended_by = 'system', ended_reason = left(p_reason, 300) where id = a.id;
  perform autopay_event(a.id, case when p_status = 'paused' then 'paused' else 'canceled' end, jsonb_build_object('reason', left(p_reason, 300)), 'system');
  select name, email into v_name, v_email from tenants where id = a.tenant_id;
  if coalesce(v_email, '') like '%@%' then
    perform autopay_email(v_email, case when p_status = 'paused' then '[Autopay] Your autopay was paused: no withdrawals will be made' else '[Autopay] Your autopay has ended' end,
      '<p>Hi ' || repair_esc(split_part(v_name, ' ', 1)) || ',</p><p>' || case when p_status = 'paused' then '<b>Your autopay was paused</b>' else '<b>Your autopay has ended</b>' end
      || ' because ' || repair_esc(p_tenant_reason) || '. <b>No money will be withdrawn.</b></p>'
      || '<p>Anything you owe is still due: see your <a href="https://2ndchinc.org/resident/#payments">portal</a>, or call (262) 236-5443.</p><p>2nd Chance Housing</p>', 'autopay_pause');
  end if;
  perform office_alert('autopay_alert_email', 'autopay', 'Autopay ' || p_status || ': ' || coalesce(v_name, ''), '<p>' || repair_esc(coalesce(v_name, '')) || ': ' || repair_esc(p_reason) || '. The tenant was emailed.</p>');
end;
$$;
revoke all on function autopay_stop_one(uuid, text, text, text) from public, anon, authenticated;

-- Checks every active autopay is still for a current lease/contract and the right account; ends or pauses it otherwise. True = still fine.
create or replace function autopay_still_valid(a autopay_authorizations)
returns boolean language plpgsql volatile security definer set search_path = public as $$
declare s record;
begin
  select * into s from autopay_subject(a.tenant_id) x where (a.lease_id is not null and x.lease_id = a.lease_id) or (a.land_contract_id is not null and x.land_contract_id = a.land_contract_id) limit 1;
  if s.amount is null then
    perform autopay_stop_one(a.id, 'canceled', 'the lease or land contract ended', 'the lease or land contract it paid for has ended');
    return false;
  end if;
  if autopay_expected_account(a.lease_id, a.land_contract_id) is distinct from coalesce(a.stripe_account, 'main') then
    perform autopay_stop_one(a.id, 'paused', 'the rent now goes to a different account than autopay was set up with',
      'your rent is now paid to a different account. If online payment is available for it, you can set up autopay again yourself in your portal');
    return false;
  end if;
  return true;
end;
$$;
revoke all on function autopay_still_valid(autopay_authorizations) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Tenant: status (next withdrawal never before the first date in the terms; whether withdrawals can happen right now)
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
  v_first := autopay_next_draw(v_day, autopay_today() + 8);
  return jsonb_build_object('amount', s.amount, 'label', s.label, 'is_lease', s.is_lease, 'draw_day', v_day, 'first_draw', v_first,
    'version', 'autopay-2026-10-v1', 'terms', autopay_terms('[your full name]', s.amount, v_day, s.label, s.is_lease, v_first),
    'email_hint', left(v_email, 2) || '***' || substr(v_email, position('@' in v_email)));
end;
$$;
revoke all on function autopay_prepare(int) from public, anon;
grant execute on function autopay_prepare(int) to authenticated;

-- 7. The code is only in the email body (staff can see email subjects on the unit's messages, never bodies).
create or replace function autopay_request_code()
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_t uuid := autopay_me(); v_email text; v_name text; v_code text;
begin
  if not exists (select 1 from resident_me()) then raise exception 'Resident sign-in required' using errcode = '42501'; end if;
  if autopay_view_as_session() then raise exception 'Autopay can only be set up by the tenant, from their own sign-in.'; end if;
  if condo_setting('autopay_enabled', 'off') <> 'on' then raise exception 'Autopay is not available yet.'; end if;
  if v_t is null then raise exception 'Autopay is for an active lease or land contract.'; end if;
  perform autopay_start_checks(v_t);
  if (select count(*) from autopay_codes where tenant_id = v_t and created_at > now() - interval '1 hour') >= 5 then raise exception 'Too many codes. Try again in an hour.'; end if;
  select email, name into v_email, v_name from tenants where id = v_t;
  if coalesce(v_email, '') not like '%@%' then raise exception 'We need your email address on file first.'; end if;
  v_code := lpad(((('x' || encode(extensions.gen_random_bytes(4), 'hex'))::bit(32)::bigint) % 1000000)::text, 6, '0');
  insert into autopay_codes (tenant_id, code_hash) values (v_t, autopay_hash(v_t::text || ':' || v_code));
  perform autopay_email(v_email, 'Your autopay confirmation code',
    '<p>Hi ' || repair_esc(split_part(coalesce(v_name, ''), ' ', 1)) || ',</p><p>Your code to set up autopay is <b style="font-size:1.4em;letter-spacing:.1em">' || v_code || '</b>. It works for 10 minutes.</p>'
    || '<p>Only enter it if <b>you</b> are setting up autopay in your own portal. If you did not ask for this, do not share the code, and call (262) 236-5443.</p><p>2nd Chance Housing</p>', 'autopay_code');
  return jsonb_build_object('sent', true, 'to', left(v_email, 2) || '***' || substr(v_email, position('@' in v_email)));
end;
$$;
revoke all on function autopay_request_code() from public, anon;
grant execute on function autopay_request_code() to authenticated;

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
  if p_version is distinct from 'autopay-2026-10-v1' then raise exception 'These terms changed. Reload the page and read them again.'; end if;
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
  v_first := autopay_next_draw(p_draw_day, autopay_today() + 8);
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

-- The bank connection step: also returns the account the bank must be connected in (stripe-pay refuses any other).
create or replace function autopay_setup_ready(p_auth uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare a autopay_authorizations; s record;
begin
  if not exists (select 1 from resident_me()) then raise exception 'Resident sign-in required' using errcode = '42501'; end if;
  if autopay_view_as_session() then raise exception 'Autopay can only be set up by the tenant, from their own sign-in.'; end if;
  if condo_setting('autopay_enabled', 'off') <> 'on' then raise exception 'Autopay is not available yet.'; end if;
  select * into a from autopay_authorizations where id = p_auth;
  if a.id is null or a.status <> 'pending' or a.tenant_id not in (select resident_me()) or a.created_at < now() - interval '60 minutes' then
    raise exception 'Start again: read and agree to the terms, then connect your bank.';
  end if;
  select * into s from autopay_start_checks(a.tenant_id);
  if coalesce(s.lease_id, s.land_contract_id) is distinct from coalesce(a.lease_id, a.land_contract_id) then raise exception 'Start again: read and agree to the terms, then connect your bank.'; end if;
  return jsonb_build_object('ok', true, 'tenant_id', a.tenant_id, 'account', s.account);
end;
$$;
revoke all on function autopay_setup_ready(uuid) from public, anon;
grant execute on function autopay_setup_ready(uuid) to authenticated;

-- Activation: refuses a second active autopay for the lease/contract and the wrong account; replaces the tenant's own paused one.
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
  if a.created_at < now() - interval '2 hours' then
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

-- Cancel: also clears a paused autopay.
create or replace function autopay_cancel()
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare a autopay_authorizations; n int := 0; v_name text; v_email text;
begin
  if not exists (select 1 from resident_me()) then raise exception 'Resident sign-in required' using errcode = '42501'; end if;
  if autopay_view_as_session() then raise exception 'Autopay can only be changed by the tenant, from their own sign-in.'; end if;
  perform autopay_set_actor('tenant');
  for a in select * from autopay_authorizations where tenant_id in (select resident_me()) and status in ('pending', 'active', 'paused') for update loop
    update autopay_authorizations set status = 'canceled', ended_at = now(), ended_by = 'tenant', ended_reason = 'canceled by the tenant' where id = a.id;
    perform autopay_event(a.id, 'canceled', '{}'::jsonb, 'tenant');
    n := n + 1;
    if a.status = 'active' then
      select name, email into v_name, v_email from tenants where id = a.tenant_id;
      if coalesce(v_email, '') like '%@%' then
        perform autopay_email(v_email, '[Autopay] You canceled autopay',
          '<p>Hi ' || repair_esc(split_part(coalesce(v_name, ''), ' ', 1)) || ',</p><p><b>You canceled autopay.</b> No more automatic withdrawals will be made. Your ' || case when a.lease_id is not null then 'rent' else 'payment' end
          || ' is still due each month: pay in your <a href="https://2ndchinc.org/resident/#payments">portal</a>.</p><p>If you did not do this, call (262) 236-5443.</p><p>2nd Chance Housing</p>', 'autopay_cancel');
      end if;
    end if;
  end loop;
  return jsonb_build_object('canceled', n);
end;
$$;
revoke all on function autopay_cancel() from public, anon;
grant execute on function autopay_cancel() to authenticated;

-- 5/6: rent-cycle logs more outcomes.
create or replace function autopay_record(p_auth uuid, p_kind text, p_detail jsonb)
returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if p_kind not in ('debit_started', 'debit_succeeded', 'debit_failed', 'debit_returned', 'debit_unknown') then raise exception 'Bad event'; end if;
  perform autopay_event(p_auth, p_kind, coalesce(p_detail, '{}'::jsonb), 'system');
end;
$$;
revoke all on function autopay_record(uuid, text, jsonb) from public, anon, authenticated;
grant execute on function autopay_record(uuid, text, jsonb) to service_role;

-- The "on the day" email: sent only once the bank withdrawal has really been started, with the real amount.
create or replace function autopay_debit_submitted(p_auth uuid, p_stripe_payment uuid, p_amount numeric, p_intent text)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare a autopay_authorizations; v_name text; v_email text;
begin
  select * into a from autopay_authorizations where id = p_auth;
  if a.id is null then return; end if;
  perform autopay_event(a.id, 'debit_submitted', jsonb_build_object('stripe_payment_id', p_stripe_payment, 'amount', p_amount, 'payment_intent', p_intent), 'system');
  select name, email into v_name, v_email from tenants where id = a.tenant_id;
  if coalesce(v_email, '') like '%@%' then
    perform autopay_email(v_email, '[Autopay] ' || to_char(p_amount, 'FM$999,990.00') || ' is being withdrawn today',
      '<p>Hi ' || repair_esc(split_part(coalesce(v_name, ''), ' ', 1)) || ',</p><p>Today your autopay started a withdrawal of <b>' || to_char(p_amount, 'FM$999,990.00') || '</b> from <b>'
      || repair_esc(coalesce(a.bank_label, 'your bank account')) || '</b>. It can take a few business days to clear. You will see it in your portal under Payments.</p>'
      || '<p><b>Please keep the money in the account</b> until it clears. If it is returned, autopay pauses and the amount is due again.</p><p>Questions: (262) 236-5443.</p><p>2nd Chance Housing</p>', 'autopay_reminder');
  end if;
end;
$$;
revoke all on function autopay_debit_submitted(uuid, uuid, numeric, text) from public, anon, authenticated;
grant execute on function autopay_debit_submitted(uuid, uuid, numeric, text) to service_role;

-- ---------------------------------------------------------------------------
-- Reminders 7, 3 and 1 day before, only from the first date in the terms on, and only while the withdrawal can really happen.
drop function if exists autopay_send_reminders(date);
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
    continue when v_days not in (7, 3, 1);
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

-- ---------------------------------------------------------------------------
-- The only list the charge job may use. At most ONE withdrawal per lease/contract per day, never before the first date in the terms,
-- and every autopay due today that is not withdrawn gets a "held"/"skipped" email (once) saying why.
drop function if exists autopay_due_v2(date);
create or replace function autopay_due_v2(p_as_of date, p_keyed text[] default null)
returns table (authorization_id uuid, tenant_id uuid, lease_id uuid, land_contract_id uuid, customer_id text, payment_method text, stripe_account text, amount numeric)
language plpgsql volatile security definer set search_path = public as $$
#variable_conflict use_column
declare a autopay_authorizations; v_subj uuid; v_seen uuid[] := '{}'; v_due numeric; v_email text; v_why text;
begin
  if condo_setting('autopay_enabled', 'off') <> 'on' then return; end if;
  for a in select * from autopay_authorizations x where x.status = 'active' and x.draw_day = extract(day from p_as_of)::int order by x.activated_at, x.id loop
    v_subj := coalesce(a.lease_id, a.land_contract_id);
    -- one withdrawal per lease/contract per day, whoever set it up (also across re-runs)
    continue when v_subj = any (v_seen);
    v_seen := v_seen || v_subj;
    continue when exists (select 1 from autopay_events e join autopay_authorizations x on x.id = e.authorization_id
                          where coalesce(x.lease_id, x.land_contract_id) = v_subj and e.kind = 'debit_started' and e.detail ->> 'cycle' = p_as_of::text);
    -- never before the first withdrawal date in the signed terms
    continue when p_as_of < autopay_first_draw(a);
    continue when not autopay_still_valid(a);
    continue when a.payment_method_id is null or a.customer_id is null;
    if a.lease_id is not null then v_due := lease_rent_due(a.lease_id, p_as_of);
    else v_due := greatest((select coalesce(sum(l.amount), 0) from land_contract_ledger l where l.contract_id = a.land_contract_id), 0);
    end if;
    if coalesce(v_due, 0) <= 0 then
      perform autopay_hold(a.id, p_as_of, 'skipped', 'you do not owe anything right now', false);
      continue;
    end if;
    v_why := null;
    if not autopay_account_ready(coalesce(a.stripe_account, 'main'), p_keyed) then
      v_why := 'online payments are switched off right now';
    elsif exists (select 1 from stripe_payments sp where ((a.lease_id is not null and sp.lease_id = a.lease_id) or (a.land_contract_id is not null and sp.land_contract_id = a.land_contract_id))
                    and (sp.status = 'processing' or (sp.status = 'created' and (sp.origin = 'autopay' or sp.created_at > now() - interval '2 hours')))) then
      -- an abandoned "Pay now" (created, never paid) stops counting after 2 hours; an autopay withdrawal whose outcome is unknown always counts
      v_why := 'a payment is still being processed by the bank';
    elsif a.lease_id is not null and exists (select 1 from payment_reports r where r.lease_id = a.lease_id and r.status = 'pending' and payment_report_fresh(r, p_as_of)) then
      v_why := 'you reported a payment that we are still checking';
    else
      select email into v_email from tenants where id = a.tenant_id;
      if not (exists (select 1 from autopay_events e join email_outbox o on o.id = (e.detail ->> 'outbox_id')::bigint
                      where e.authorization_id = a.id and e.kind = 'reminder_1' and e.detail ->> 'cycle' = p_as_of::text and o.sent_at is not null)
              and not exists (select 1 from email_log l where lower(l.to_email) = lower(coalesce(v_email, '')) and l.status in ('bounced', 'complained', 'failed') and l.sent_at > now() - interval '10 days')) then
        v_why := 'we could not confirm that your reminder email reached you';
      end if;
    end if;
    if v_why is not null then
      perform autopay_hold(a.id, p_as_of, 'held', v_why, true);
      continue;
    end if;
    authorization_id := a.id; tenant_id := a.tenant_id; lease_id := a.lease_id; land_contract_id := a.land_contract_id;
    customer_id := a.customer_id; payment_method := a.payment_method_id; stripe_account := coalesce(a.stripe_account, 'main'); amount := least(v_due, a.amount);
    return next;
  end loop;
end;
$$;
revoke all on function autopay_due_v2(date, text[]) from public, anon, authenticated;
grant execute on function autopay_due_v2(date, text[]) to service_role;
