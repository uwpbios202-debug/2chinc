-- NO PARKING only with proof that no payment was attempted (Stephen, 11/8/2026: "we need NO PARKING only when we actually know that the
-- tenant has not attempted to pay... we do not want to get it incorrect").
--
-- parking_pay_evidence(unit) looks at every way money reaches us and lists anything that shows a payment attempt or that we cannot see yet.
-- The office cannot revoke while the list is not empty, and a revocation is SUSPENDED the moment anything appears (NO PARKING disappears from
-- every map, card and Always Towing's page at once); a job every 15 minutes then closes it ("restored by the system") and emails the office.
--
-- What is owed:
--   * Unit with an active lease: the tenant's unpaid RENT only (lease_rent_due: no late fees, no fines; the agency share of an assisted
--     tenancy is already credited when rent is charged, so a late agency never makes a tenant look unpaid). Owner dues never count here.
--   * Unit without a lease (owner-occupied 1, 7, 13; vacant; Unit 6): the owner's association dues of at least parking_revoke_min_dues
--     ($215, ROCA1 Rules §11.3).
-- Not yet late: unpaid rent can lead to NO PARKING only parking_revoke_wait_days (9) days after the oldest unpaid rent charge, so not
--   before the 10th for the 1st's rent (ROCA1 Rules #21, the later of the two dates in the rules). Change the setting to change it.
-- Signs of a payment attempt (any one blocks NO PARKING):
--   * a bank payment through the portal still clearing (Stripe processing), started in the last 24 hours, or paid in the last 3 days;
--   * a payment that failed, was returned or disputed in the last parking_attempt_hold_business_days (5) business days;
--   * an "I've paid" report (Zelle, check, money order, cash...) not yet verified or rejected, of ANY age; or one returned recently;
--   * any payment on the account since the oldest unpaid charge (a partial payment counts as an attempt) (owners: in the last 60 days,
--     as for the goodwill credit);
--   * autopay set up; an active work-in-lieu agreement;
--   * a bank deposit in the account that rent goes to, not yet matched to anyone (it may be theirs);
--   * that bank account's feed not synced in the last 30 hours, or showing an error (we cannot see the latest deposits).
-- The old setting parking_blocked_units no longer blocks anything (it had no such checks); it was empty.
-- No new table, so no new grants.

insert into portal_settings (key, value) values
  ('parking_revoke_wait_days', '9'),
  ('parking_attempt_hold_business_days', '5'),
  ('parking_revoke_min_dues', '215')
on conflict (key) do nothing;

create or replace function parking_pay_evidence(p_unit text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_today date := (now() at time zone 'America/Chicago')::date;
  v_hold int := coalesce(nullif(condo_setting('parking_attempt_hold_business_days', ''), '')::int, 5);
  v_wait int := coalesce(nullif(condo_setting('parking_revoke_wait_days', ''), '')::int, 9);
  v_min numeric := coalesce(nullif(condo_setting('parking_revoke_min_dues', ''), '')::numeric, 215);
  v_lease uuid; v_basis text; v_owed numeric := 0; v_oldest date; v_from date; v_acct uuid; v_cacct uuid; v_owner uuid;
  ev jsonb := '[]'::jsonb; x record;
begin
  select l.id into v_lease from leases l join rental_units ru on ru.id = l.unit_id where l.status = 'active' and ru.unit_number = p_unit order by l.start_date desc limit 1;

  if v_lease is not null then
    v_basis := 'rent';
    v_owed := coalesce(lease_rent_due(v_lease, v_today), 0);
    if v_owed > 0.004 then
      -- The oldest rent charge still unpaid (payments go to the oldest first).
      select d into v_oldest from (
        select e.entry_date d, sum(e.amount) over (order by e.entry_date desc, e.id desc) run
          from lease_ledger_entries e where e.lease_id = v_lease and e.gl_account in ('Rent Income', 'Rent Charge') and e.kind = 'charge' and e.amount > 0 and e.entry_date <= v_today) z
       where run >= v_owed order by d desc limit 1;
      v_oldest := coalesce(v_oldest, v_today);
      v_from := v_oldest + v_wait;
      if v_today < v_from then
        ev := ev || jsonb_build_array(jsonb_build_object('code', 'not_late', 'text', 'Rent charged ' || to_char(v_oldest, 'FMMM/FMDD') || ' is not late enough yet (NO PARKING possible from ' || to_char(v_from, 'FMMM/FMDD') || ').'));
      end if;
      for x in select status, amount, created_at, updated_at, method_type from stripe_payments where lease_id = v_lease
                and (status = 'processing' or (status = 'created' and created_at > now() - interval '24 hours') or (status = 'succeeded' and updated_at > now() - interval '3 days')
                     or (status in ('failed', 'reversed', 'disputed') and business_days_between((updated_at at time zone 'America/Chicago')::date, v_today) < v_hold)) loop
        ev := ev || jsonb_build_array(jsonb_build_object('code', 'portal_' || x.status, 'text', case x.status
          when 'processing' then 'A portal bank payment of ' || to_char(x.amount, 'FM$999,990.00') || ' (started ' || to_char(x.created_at at time zone 'America/Chicago', 'FMMM/FMDD') || ') is still clearing.'
          when 'created' then 'A portal payment was started in the last 24 hours.'
          when 'succeeded' then 'A portal payment of ' || to_char(x.amount, 'FM$999,990.00') || ' succeeded on ' || to_char(x.updated_at at time zone 'America/Chicago', 'FMMM/FMDD') || '; check that it posted.'
          else 'A portal payment of ' || to_char(x.amount, 'FM$999,990.00') || ' ' || x.status || ' on ' || to_char(x.updated_at at time zone 'America/Chicago', 'FMMM/FMDD') || ' (an attempt; wait ' || v_hold || ' business days).' end));
      end loop;
      for x in select method, amount, paid_on, status, created_at, reversed_at from payment_reports where lease_id = v_lease
                and (status = 'pending' or (status = 'reversed' and business_days_between(coalesce(reversed_at, created_at)::date, v_today) < v_hold)) loop
        ev := ev || jsonb_build_array(jsonb_build_object('code', 'report_' || x.status, 'text', case x.status
          when 'pending' then 'The tenant reported paying ' || to_char(x.amount, 'FM$999,990.00') || ' by ' || replace(x.method, '_', ' ') || ' on ' || to_char(x.paid_on, 'FMMM/FMDD') || ': verify or reject it first.'
          else 'A reported payment was returned on ' || to_char(coalesce(x.reversed_at, x.created_at), 'FMMM/FMDD') || ' (an attempt; wait ' || v_hold || ' business days).' end));
      end loop;
      for x in select entry_date, amount from lease_ledger_entries where lease_id = v_lease and kind in ('payment', 'in_kind') and amount < 0 and entry_date >= v_oldest order by entry_date loop
        ev := ev || jsonb_build_array(jsonb_build_object('code', 'partial', 'text', 'A payment of ' || to_char(-x.amount, 'FM$999,990.00') || ' was received on ' || to_char(x.entry_date, 'FMMM/FMDD') || ' (a partial payment counts as an attempt).'));
      end loop;
      if exists (select 1 from autopay_authorizations a where a.lease_id = v_lease and a.status = 'active') then
        ev := ev || jsonb_build_array(jsonb_build_object('code', 'autopay', 'text', 'The tenant has autopay set up.'));
      end if;
      if exists (select 1 from work_agreements w where w.lease_id = v_lease and w.status = 'active') then
        ev := ev || jsonb_build_array(jsonb_build_object('code', 'work', 'text', 'The tenant has an active work-in-lieu agreement.'));
      end if;
      v_acct := lease_receiving_account(v_lease);
    end if;
  else
    v_basis := 'dues';
    v_cacct := roca_unit_account(p_unit);
    v_owner := (select s.owner_id from condo_ownerships s join condo_units cu on cu.id = s.unit_id where s.is_current and cu.unit_number = p_unit limit 1);
    v_owed := coalesce(condo_account_balance(v_cacct, v_today), 0);
    if v_owed >= v_min then
      for x in select status, amount, created_at, updated_at from stripe_payments where (condo_account_id = v_cacct or (v_owner is not null and owner_id = v_owner and condo_account_id is null))
                and (status = 'processing' or (status = 'created' and created_at > now() - interval '24 hours') or (status = 'succeeded' and updated_at > now() - interval '3 days')
                     or (status in ('failed', 'reversed', 'disputed') and business_days_between((updated_at at time zone 'America/Chicago')::date, v_today) < v_hold)) loop
        ev := ev || jsonb_build_array(jsonb_build_object('code', 'portal_' || x.status, 'text', 'A portal dues payment of ' || to_char(x.amount, 'FM$999,990.00') || ' is ' || x.status || ' (' || to_char(coalesce(x.updated_at, x.created_at) at time zone 'America/Chicago', 'FMMM/FMDD') || ').'));
      end loop;
      for x in select method, amount, paid_on, status from payment_reports where (condo_account_id = v_cacct or (v_owner is not null and owner_id = v_owner and tenant_id is null))
                and (status = 'pending' or (status = 'reversed' and business_days_between(coalesce(reversed_at, created_at)::date, v_today) < v_hold)) loop
        ev := ev || jsonb_build_array(jsonb_build_object('code', 'report_' || x.status, 'text', 'The owner reported a dues payment of ' || to_char(x.amount, 'FM$999,990.00') || ' (' || x.status || '): resolve it first.'));
      end loop;
      for x in select entry_date, amount from condo_ledger_entries where account_id = v_cacct and kind = 'payment' and amount < 0 and entry_date >= v_today - 60 order by entry_date loop
        ev := ev || jsonb_build_array(jsonb_build_object('code', 'partial', 'text', 'A dues payment of ' || to_char(-x.amount, 'FM$999,990.00') || ' was received on ' || to_char(x.entry_date, 'FMMM/FMDD') || ' (paying in the last 60 days counts as an attempt).'));
      end loop;
      select id into v_acct from bank_accounts where active and kind = 'owner' order by created_at limit 1;
    end if;
  end if;

  -- Money we cannot see yet: unmatched deposits in that account, or a feed that is not current.
  if v_acct is not null then
    for x in select posted_on, amount from bank_receipts where bank_account_id = v_acct and status in ('new', 'needs_review') and not coalesce(ignored, false)
              and amount > 0 and posted_on >= coalesce(v_oldest, v_today - 60) - 3 loop
      ev := ev || jsonb_build_array(jsonb_build_object('code', 'deposit_waiting', 'text', 'A bank deposit of ' || to_char(x.amount, 'FM$999,990.00') || ' (' || to_char(x.posted_on, 'FMMM/FMDD') || ') is not matched to anyone yet; it may be theirs. Match it on the Bank page first.'));
    end loop;
    if exists (select 1 from bank_accounts b where b.id = v_acct and (b.last_synced_at is null or b.last_synced_at < now() - interval '30 hours' or b.last_error is not null)) then
      ev := ev || jsonb_build_array(jsonb_build_object('code', 'bank_stale', 'text', 'The bank feed for ' || (select name from bank_accounts where id = v_acct) || ' is not current, so a recent deposit may not show yet.'));
    end if;
  end if;

  return jsonb_build_object('unit', p_unit, 'basis', v_basis, 'owed', round(v_owed, 2), 'oldest_unpaid', v_oldest, 'revocable_from', v_from,
    'threshold', case when v_basis = 'dues' then v_min end, 'evidence', ev,
    'can_revoke', case when v_basis = 'rent' then v_owed > 0.004 else v_owed >= v_min end and jsonb_array_length(ev) = 0);
end;
$$;
revoke all on function parking_pay_evidence(text) from public, anon, authenticated;

-- NO PARKING applies only to an open revocation that is still proven right now.
create or replace function parking_blocked_list()
returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(r.unit_number), '{}') from parking_revocations r
   where r.restored_at is null and (parking_pay_evidence(r.unit_number) ->> 'can_revoke')::boolean;
$$;
revoke all on function parking_blocked_list() from public, anon, authenticated;

create or replace function parking_revoke(p_unit text, p_reason text, p_notify boolean)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r parking_revocations; n int := 0; e jsonb;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if autopay_view_as_session() then raise exception 'Not available while viewing as someone else.'; end if;
  if not exists (select 1 from parking_stalls where kind = 'unit' and active and home_unit = p_unit) then raise exception 'No stall for Unit %.', p_unit; end if;
  if length(coalesce(trim(p_reason), '')) < 5 then raise exception 'Enter the reason (for example: unpaid rent of $900 since 11/2).'; end if;
  if exists (select 1 from parking_revocations where unit_number = p_unit and restored_at is null) then raise exception 'Parking for Unit % is already revoked.', p_unit; end if;
  e := parking_pay_evidence(p_unit);
  if not (e ->> 'can_revoke')::boolean then
    raise exception 'Parking for Unit % cannot be revoked: %', p_unit,
      coalesce(nullif((select string_agg(x ->> 'text', ' ') from jsonb_array_elements(e -> 'evidence') x), ''),
               case when e ->> 'basis' = 'dues' then 'the dues balance is under $' || (e ->> 'threshold') || '.' else 'no rent is owed.' end);
  end if;
  insert into parking_revocations (unit_number, reason, revoked_by)
  values (p_unit, trim(p_reason) || ' [' || case when e ->> 'basis' = 'rent' then 'unpaid rent ' else 'dues balance ' end || to_char((e ->> 'owed')::numeric, 'FM$999,990.00')
          || coalesce(' since ' || to_char((e ->> 'oldest_unpaid')::date, 'FMMM/FMDD/YYYY'), '') || '; no payment attempt found]', lower(auth.email()))
  returning * into r;
  if coalesce(p_notify, false) then
    n := parking_revoke_notify(p_unit, 'Parking for Unit ' || p_unit || ' is revoked',
      '<p><b>Parking for Unit ' || repair_esc(p_unit) || ' is revoked</b> because of an unpaid balance on the account.</p>'
      || '<p><b>Do not park in stall ' || repair_esc(p_unit) || '.</b> A vehicle in it will be towed at the vehicle owner''s expense.</p>'
      || '<p>To restore parking, pay on your portal (Payments tab). Parking is restored as soon as a payment is under way; call or text the office with any question.</p>');
  end if;
  return jsonb_build_object('id', r.id, 'emailed', n);
end;
$$;
revoke all on function parking_revoke(text, text, boolean) from public, anon;
grant execute on function parking_revoke(text, text, boolean) to authenticated;

-- Every 15 minutes: close any revocation that is no longer proven (a payment attempt appeared, or the balance is paid) and tell the office.
create or replace function parking_revocations_autolift()
returns int
language plpgsql volatile security definer set search_path = public as $$
declare r parking_revocations; e jsonb; n int := 0; v_why text;
begin
  for r in select * from parking_revocations where restored_at is null loop
    e := parking_pay_evidence(r.unit_number);
    if (e ->> 'can_revoke')::boolean then continue; end if;
    v_why := coalesce(nullif((select string_agg(x ->> 'text', ' ') from jsonb_array_elements(e -> 'evidence') x), ''), 'The balance is paid.');
    update parking_revocations set restored_at = now(), restored_by = 'system', restore_note = left(v_why, 500) where id = r.id;
    insert into email_outbox (to_email, subject, html, kind) values ('info@2ndchinc.org', 'Parking restored for Unit ' || r.unit_number || ' (payment activity)',
      '<div style="font-family:Arial,sans-serif;max-width:640px;color:#1b2430"><p>NO PARKING for <b>Unit ' || repair_esc(r.unit_number) || '</b> was lifted automatically:</p><p>'
      || repair_esc(v_why) || '</p><p>Revoked ' || to_char(r.revoked_at at time zone 'America/Chicago', 'FMMM/FMDD FMHH12:MI AM') || ' for: ' || repair_esc(r.reason)
      || '</p><p>If the payment does not go through, you can revoke parking again once nothing shows an attempt. https://2ndchinc.org/parking/</p></div>', 'parking_revoke');
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke all on function parking_revocations_autolift() from public, anon, authenticated;

select cron.unschedule('parking-revoke-autolift') where exists (select 1 from cron.job where jobname = 'parking-revoke-autolift');
select cron.schedule('parking-revoke-autolift', '*/15 * * * *', 'select parking_revocations_autolift()');

-- Staff list: what is owed, on what basis, and every sign of a payment attempt (why Revoke is or is not allowed).
create or replace function parking_revocations_staff()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(parking_pay_evidence(s.home_unit) || jsonb_build_object(
      'revocation', (select jsonb_build_object('id', r.id, 'reason', r.reason, 'revoked_at', r.revoked_at, 'revoked_by', r.revoked_by)
                       from parking_revocations r where r.unit_number = s.home_unit and r.restored_at is null),
      'last_restore', (select jsonb_build_object('at', r.restored_at, 'by', r.restored_by, 'note', r.restore_note) from parking_revocations r
                        where r.unit_number = s.home_unit and r.restored_at is not null order by r.restored_at desc limit 1),
      'history', (select count(*) from parking_revocations r where r.unit_number = s.home_unit and r.restored_at is not null))
    order by nullif(regexp_replace(s.home_unit, '\D', '', 'g'), '')::int) from parking_stalls s where s.kind = 'unit' and s.active), '[]'::jsonb);
end;
$$;
revoke all on function parking_revocations_staff() from public, anon;
grant execute on function parking_revocations_staff() to authenticated;
