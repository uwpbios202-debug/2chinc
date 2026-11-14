-- Unit 16 (and any unit whose rent is routed to ROCA1's First Citizens account): rent paid per payment, not per month (Stephen, 10/11/2026).
--
--   1. The tenant pays (Zelle, bank payment). While it is PENDING the owner sees it on her page, and her association account is paused:
--      no late fee or interest (the same hold as owner payments).
--   2. When the payment posts (the pending is lifted), the system takes EVERYTHING the unit owes ROCA1 out of it, in the existing order
--      (fines and fees, special assessments, current dues, older balance), as payments on the owner's association ledger. A partial
--      payment gets the same treatment on whatever arrives. Any management fee in roca_pma_terms (0% until entered) comes out next.
--   3. The balance is the owner's. It becomes a STAFF TASK: "Zelle $X to <owner>" with her phone and email. Staff send the Zelle themselves
--      and record the date and reference. The system never moves money to the owner.
--   4. A reversed payment (bounced, refunded, lost dispute) reverses the ledger credits and cancels the task; if the Zelle was already sent,
--      staff are told how much to recover.
-- The old monthly statement no longer covers these units (it would count the same rent twice).

insert into portal_settings (key, value) values ('roca_rent_split_from', '2026-10-12') on conflict (key) do nothing;   -- payments dated on/after this split

-- ---------------------------------------------------------------------------
create table if not exists roca_rent_splits (
  id uuid primary key default gen_random_uuid(),
  unit_number text not null,
  owner_id uuid references condo_owners(id),
  owner_name text, owner_email text, owner_phone text,         -- the Zelle details shown to staff (her phone and email)
  lease_id uuid not null,
  lease_entry_id bigint not null unique,                        -- the tenant's payment line on the lease ledger
  paid_on date not null,
  rent_amount numeric(12,2) not null,
  to_roca1 numeric(12,2) not null default 0,
  deductions jsonb not null default '[]'::jsonb,                -- [{category, gl_account, amount}]
  mgmt_fee numeric(12,2) not null default 0,
  net_to_owner numeric(12,2) not null default 0,
  condo_entry_ids bigint[] not null default '{}',
  status text not null default 'zelle_due' check (status in ('zelle_due', 'sent', 'nothing_to_send', 'reversed')),
  reversed_amount numeric(12,2) not null default 0,
  recovery_due numeric(12,2) not null default 0,                -- Zelle already sent for a payment that was then reversed
  sent_date date, sent_reference text, sent_by text,
  created_at timestamptz not null default now()
);
alter table roca_rent_splits enable row level security;   -- reached only through the functions below

-- Is this lease's rent paid into ROCA1's account? Returns the condo unit number.
create or replace function roca_routed_unit(p_lease uuid)
returns text language sql stable security definer set search_path = public as $$
  select cu.unit_number from leases l join rental_units ru on ru.id = l.unit_id join condo_units cu on cu.id = ru.condo_unit_id
  join bank_accounts b on b.id = l.pay_to_account_id
  where l.id = p_lease and b.bank_key = 'first_citizens_roca1';
$$;
revoke all on function roca_routed_unit(uuid) from public, anon, authenticated;

create or replace function roca_unit_routed(p_unit text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from leases l join rental_units ru on ru.id = l.unit_id join condo_units cu on cu.id = ru.condo_unit_id
    join bank_accounts b on b.id = l.pay_to_account_id
    where cu.unit_number = p_unit and l.status in ('active', 'future') and b.bank_key = 'first_citizens_roca1');
$$;
revoke all on function roca_unit_routed(text) from public, anon, authenticated;

-- Tenant rent for a routed unit that is pending: a bank payment in flight, or a fresh "I've paid" report.
create or replace function roca_unit_pending_rent(p_unit text, p_day date)
returns numeric language sql stable security definer set search_path = public as $$
  with ls as (select l.id from leases l join rental_units ru on ru.id = l.unit_id join condo_units cu on cu.id = ru.condo_unit_id
              join bank_accounts b on b.id = l.pay_to_account_id
              where cu.unit_number = p_unit and l.status in ('active', 'future') and b.bank_key = 'first_citizens_roca1')
  select coalesce((select sum(s.amount) from stripe_payments s where s.lease_id in (select id from ls) and s.status = 'processing'), 0)
       + coalesce((select sum(r.amount) from payment_reports r where r.lease_id in (select id from ls) and r.status = 'pending' and payment_report_fresh(r, p_day)), 0);
$$;
revoke all on function roca_unit_pending_rent(text, date) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- The split itself.
create or replace function roca_rent_split_apply(p_lease uuid, p_entry bigint, p_amount numeric, p_paid_on date)
returns uuid
language plpgsql volatile security definer set search_path = public as $$
declare
  v_unit text := roca_routed_unit(p_lease); o record; t roca_pma_terms; v_acct uuid; r record; take numeric; v_left numeric := p_amount;
  v_ded jsonb := '[]'::jsonb; v_ded_total numeric := 0; v_mgmt numeric := 0; v_ids bigint[] := '{}'; v_id bigint; v_net numeric; v_split uuid;
  v_phone text; v_office text := coalesce(nullif((select value from portal_settings where key = 'office_email'), ''), 'info@2ndchinc.org');
  CAT jsonb := '{"fines_fees":"fines and fees","assessments":"special assessments","dues_current":"association dues","older_balance":"past-due dues"}';
begin
  if v_unit is null or p_amount <= 0 then return null; end if;
  if exists (select 1 from roca_rent_splits where lease_entry_id = p_entry) then return null; end if;
  select * into o from roca_unit_owner_on(v_unit, p_paid_on);
  if o.owner_id is null or o.name ~* '^2nd Chance' then return null; end if;   -- 2nd Chance's own unit: nothing to split
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
  v_mgmt := least(greatest(v_left, 0), round(p_amount * coalesce(t.mgmt_fee_pct, 0) / 100, 2));
  v_net := greatest(v_left - v_mgmt, 0);
  select phone_mobile into v_phone from condo_owners where id = o.owner_id;
  insert into roca_rent_splits (unit_number, owner_id, owner_name, owner_email, owner_phone, lease_id, lease_entry_id, paid_on, rent_amount, to_roca1, deductions, mgmt_fee,
                                net_to_owner, condo_entry_ids, status)
  values (v_unit, o.owner_id, o.name, o.email, v_phone, p_lease, p_entry, p_paid_on, p_amount, v_ded_total, v_ded, v_mgmt, v_net, v_ids,
          case when v_net > 0 then 'zelle_due' else 'nothing_to_send' end)
  returning id into v_split;
  if v_net > 0 then
    insert into email_outbox (to_email, subject, html, kind) values (v_office, 'Zelle $' || to_char(v_net, 'FM999,990.00') || ' to ' || o.name || ' (Unit ' || v_unit || ')',
      '<p>The tenant''s rent of ' || to_char(p_amount, 'FM$999,990.00') || ' for Unit ' || v_unit || ' cleared.</p><ul><li>Applied to ' || o.name || '''s association account: ' || to_char(v_ded_total, 'FM$999,990.00') || '</li>'
      || case when v_mgmt > 0 then '<li>Management fee: ' || to_char(v_mgmt, 'FM$999,990.00') || '</li>' else '' end
      || '<li><b>To send to the owner by Zelle: ' || to_char(v_net, 'FM$999,990.00') || '</b></li></ul>'
      || '<p>Zelle to ' || repair_esc(o.name) || ': phone ' || repair_esc(coalesce(v_phone, '(none on file)')) || ', email ' || repair_esc(coalesce(o.email, '(none on file)'))
      || '.</p><p>After you send it, record the date and reference: <a href="https://2ndchinc.org/association-owners/roca1/distributions/">Rent deductions</a>.</p>', 'roca_zelle_due');
  end if;
  if o.email is not null then
    insert into email_outbox (to_email, subject, html, kind) values (o.email, 'Unit ' || v_unit || ': your tenant''s rent payment was received',
      '<p>Dear ' || repair_esc(o.name) || ',</p><p>Your tenant''s rent payment of ' || to_char(p_amount, 'FM$999,990.00') || ' (' || to_char(p_paid_on, 'FMMM/FMDD/YYYY') || ') cleared.</p><ul>'
      || '<li>Paid to ROCA1 for your association account: ' || to_char(v_ded_total, 'FM$999,990.00') || '</li>'
      || case when v_mgmt > 0 then '<li>Management fee: ' || to_char(v_mgmt, 'FM$999,990.00') || '</li>' else '' end
      || '<li><b>' || case when v_net > 0 then 'Being sent to you by Zelle: ' else 'Left for you: ' end || to_char(v_net, 'FM$999,990.00') || '</b></li></ul>'
      || '<p>See it in the owner portal: https://2ndchinc.org/association-owners/roca1/#statements</p><p>2nd Chance Housing, for ROCA1</p>', 'roca_rent_split');
  end if;
  return v_split;
end;
$$;
revoke all on function roca_rent_split_apply(uuid, bigint, numeric, date) from public, anon, authenticated;

-- A tenant's rent payment lands on the lease ledger: split it. Never blocks the payment itself; a failure only alerts staff.
create or replace function roca_rent_split_trg()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.kind = 'payment' and new.gl_account = 'Rent Income' and new.amount < 0
     and new.entry_date >= coalesce((select value from portal_settings where key = 'roca_rent_split_from')::date, '2026-10-12'::date)
     and roca_routed_unit(new.lease_id) is not null then
    begin
      perform roca_rent_split_apply(new.lease_id, new.id, -new.amount, new.entry_date);
    exception when others then
      insert into email_outbox (to_email, subject, html, kind) values (coalesce(nullif((select value from portal_settings where key = 'office_email'), ''), 'info@2ndchinc.org'),
        'Unit rent payment could not be split automatically',
        '<p>A tenant payment of ' || to_char(-new.amount, 'FM$999,990.00') || ' (lease ledger line ' || new.id || ') posted, but the automatic split to the owner''s association account failed: '
        || repair_esc(sqlerrm) || '. Please handle it by hand on the Rent deductions page.</p>', 'roca_split_error');
    end;
  end if;
  return new;
end;
$$;
drop trigger if exists roca_rent_split_after_insert on lease_ledger_entries;
create trigger roca_rent_split_after_insert after insert on lease_ledger_entries for each row execute function roca_rent_split_trg();

-- A reversed payment: undo its split (proportionally for a partial reversal).
create or replace function roca_rent_split_reverse(p_lease uuid, p_orig_entry bigint, p_amount numeric, p_reason text)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare s roca_rent_splits; ratio numeric; e record; v_amt numeric; v_net numeric; v_acct uuid;
  v_office text := coalesce(nullif((select value from portal_settings where key = 'office_email'), ''), 'info@2ndchinc.org');
begin
  select * into s from roca_rent_splits where lease_entry_id = p_orig_entry and status <> 'reversed' for update;
  if s.id is null then return; end if;
  ratio := least(p_amount / s.rent_amount, 1 - s.reversed_amount / s.rent_amount);
  if ratio <= 0 then return; end if;
  for e in select * from condo_ledger_entries where id = any (s.condo_entry_ids) loop
    v_amt := round(-e.amount * ratio, 2);
    continue when v_amt <= 0;
    insert into condo_ledger_entries (account_id, gl_account, entry_date, kind, raw_type, method, description, amount, origin, entered_by, correction_note, reverses_entry_id)
    values (e.account_id, e.gl_account, current_date, 'reversal', 'Payment reversed', 'rent_deduction',
            'Tenant rent payment reversed: ' || left(trim(coalesce(p_reason, '')), 80), v_amt, 'staff', 'automation',
            'Reverses the part of the ' || to_char(s.paid_on, 'FMMM/FMDD/YYYY') || ' tenant rent payment that was applied here; original line kept.', e.id);
  end loop;
  v_net := round(s.net_to_owner * ratio, 2);
  update roca_rent_splits set reversed_amount = reversed_amount + p_amount,
    net_to_owner = case when status = 'zelle_due' then greatest(net_to_owner - v_net, 0) else net_to_owner end,
    recovery_due = recovery_due + case when status = 'sent' then v_net else 0 end,
    status = case when reversed_amount + p_amount >= rent_amount then 'reversed'
                  when status = 'zelle_due' and net_to_owner - v_net <= 0 then 'nothing_to_send' else status end
  where id = s.id;
  insert into email_outbox (to_email, subject, html, kind) values (v_office, 'Unit ' || s.unit_number || ': tenant rent payment reversed',
    '<p>The ' || to_char(s.paid_on, 'FMMM/FMDD/YYYY') || ' rent payment for Unit ' || s.unit_number || ' was reversed (' || repair_esc(coalesce(p_reason, '')) || '). The part applied to '
    || repair_esc(s.owner_name) || '''s association account was reversed on her ledger.'
    || case when s.status = 'sent' then ' <b>The Zelle of ' || to_char(v_net, 'FM$999,990.00') || ' was already sent to her: please recover it.</b>'
            when s.status = 'zelle_due' then ' The Zelle to her was reduced to ' || to_char(greatest(s.net_to_owner - v_net, 0), 'FM$999,990.00') || '; do not send more than that.' else '' end
    || '</p>', 'roca_split_reversed');
end;
$$;
revoke all on function roca_rent_split_reverse(uuid, bigint, numeric, text) from public, anon, authenticated;

-- lease_payment_reverse (latest version, 20261106110000) now also reverses the split.
do $$
declare v text := pg_get_functiondef('lease_payment_reverse(uuid, numeric, text, text)'::regprocedure);
  v_old text := '  update payment_reports set reversed_amount = reversed_amount + v_amt, reversed_at = now(), reversed_reason = trim(p_reason), reversed_by = p_by,';
begin
  if position(v_old in v) = 0 then raise exception 'lease_payment_reverse changed: cannot patch'; end if;
  if position('roca_rent_split_reverse' in v) = 0 then
    v := replace(v, v_old, '  if r.lease_id is not null and r.ledger_entry_id is not null then perform roca_rent_split_reverse(r.lease_id, r.ledger_entry_id, v_amt, p_reason); end if;' || E'\n' || v_old);
    execute v;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Staff: the Zelle list.
create or replace function roca_rent_payouts_staff_list()
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  perform roca_staff_check();
  return jsonb_build_object(
    'due', coalesce((select jsonb_agg(to_jsonb(s) order by s.paid_on, s.created_at) from roca_rent_splits s where s.status = 'zelle_due'), '[]'::jsonb),
    'recovery', coalesce((select jsonb_agg(to_jsonb(s) order by s.created_at) from roca_rent_splits s where s.recovery_due > 0), '[]'::jsonb),
    'recent', coalesce((select jsonb_agg(to_jsonb(s) order by s.created_at desc) from (select * from roca_rent_splits where status in ('sent', 'nothing_to_send', 'reversed') order by created_at desc limit 25) s), '[]'::jsonb));
end;
$$;
revoke all on function roca_rent_payouts_staff_list() from public, anon;
grant execute on function roca_rent_payouts_staff_list() to authenticated;

create or replace function roca_rent_payout_sent(p_id uuid, p_date date, p_reference text)
returns void language plpgsql volatile security definer set search_path = public as $$
declare s roca_rent_splits;
begin
  perform roca_staff_check();
  if length(coalesce(trim(p_reference), '')) < 2 then raise exception 'Enter the Zelle confirmation or reference.'; end if;
  select * into s from roca_rent_splits where id = p_id for update;
  if s.id is null or s.status <> 'zelle_due' then raise exception 'That payout is not waiting to be sent.'; end if;
  update roca_rent_splits set status = 'sent', sent_date = coalesce(p_date, current_date), sent_reference = trim(p_reference), sent_by = lower(auth.email()) where id = p_id;
  if s.owner_email is not null then
    insert into email_outbox (to_email, subject, html, kind) values (s.owner_email, 'Unit ' || s.unit_number || ': your Zelle was sent',
      '<p>Dear ' || repair_esc(coalesce(s.owner_name, 'Owner')) || ',</p><p>We sent ' || to_char(s.net_to_owner, 'FM$999,990.00') || ' to you by Zelle on ' || to_char(coalesce(p_date, current_date), 'FMMM/FMDD/YYYY')
      || ' (reference ' || repair_esc(trim(p_reference)) || '), from your tenant''s rent payment of ' || to_char(s.paid_on, 'FMMM/FMDD/YYYY') || '.</p><p>2nd Chance Housing, for ROCA1</p>', 'roca_zelle_sent');
  end if;
end;
$$;
revoke all on function roca_rent_payout_sent(uuid, date, text) from public, anon;
grant execute on function roca_rent_payout_sent(uuid, date, text) to authenticated;

-- Owner: pending tenant rent and what happened to recent payments.
create or replace function roca_rent_pending_mine()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare v jsonb := '[]'::jsonb; u text;
begin
  if not condo_session_ok() then raise exception 'Sign-in required' using errcode = '42501'; end if;
  for u in select x from roca_my_unit_numbers() x loop
    continue when not roca_unit_routed(u);
    v := v || jsonb_build_object('unit_number', u,
      'pending', coalesce((
        select jsonb_agg(p order by p->>'date') from (
          select jsonb_build_object('amount', s.amount, 'date', s.created_at::date, 'how', 'Bank payment') p
            from stripe_payments s join leases l on l.id = s.lease_id join rental_units ru on ru.id = l.unit_id join condo_units cu on cu.id = ru.condo_unit_id
            where cu.unit_number = u and s.status = 'processing'
          union all
          select jsonb_build_object('amount', r.amount, 'date', r.paid_on, 'how', initcap(replace(r.method, '_', ' ')))
            from payment_reports r join leases l on l.id = r.lease_id join rental_units ru on ru.id = l.unit_id join condo_units cu on cu.id = ru.condo_unit_id
            where cu.unit_number = u and r.status = 'pending' and payment_report_fresh(r, current_date)) q), '[]'::jsonb),
      'recent', coalesce((select jsonb_agg(jsonb_build_object('paid_on', s.paid_on, 'rent_amount', s.rent_amount, 'to_roca1', s.to_roca1, 'deductions', s.deductions,
          'mgmt_fee', s.mgmt_fee, 'net_to_owner', s.net_to_owner, 'status', s.status, 'sent_date', s.sent_date) order by s.paid_on desc)
        from (select * from roca_rent_splits where unit_number = u order by paid_on desc, created_at desc limit 12) s), '[]'::jsonb));
  end loop;
  return v;
end;
$$;
revoke all on function roca_rent_pending_mine() from public, anon;
grant execute on function roca_rent_pending_mine() to authenticated;

-- ---------------------------------------------------------------------------
-- The monthly statement leaves routed units alone (this flow replaces it for them).
create or replace function roca_distribution_units(p_month date)
returns setof text language sql stable security definer set search_path = public as $$
  select distinct cu.unit_number from leases l join rental_units ru on ru.id = l.unit_id join condo_units cu on cu.id = ru.condo_unit_id
  where cu.unit_number ~ '^\d+$' and not roca_unit_routed(cu.unit_number)
    and ((coalesce(l.start_date, p_month) <= (date_trunc('month', p_month) + interval '1 month - 1 day')::date and (l.end_date is null or l.end_date >= date_trunc('month', p_month)::date))
      or exists (select 1 from lease_ledger_entries e where e.lease_id = l.id and e.kind = 'payment' and date_trunc('month', e.entry_date) = date_trunc('month', p_month)));
$$;
revoke all on function roca_distribution_units(date) from public, anon, authenticated;

-- Staff "Today" list: Zelle payouts waiting.
do $$
declare v text := pg_get_functiondef('staff_today()'::regprocedure);
  v_old text := '  return jsonb_build_object(''as_of'', now(), ''items'', v);';
begin
  if position(v_old in v) = 0 then raise exception 'staff_today changed: cannot patch'; end if;
  if position('zelle_owners' in v) = 0 then
    v := replace(v, v_old, '  select count(*) into n from roca_rent_splits where status = ''zelle_due'';' || E'\n'
      || '  v := v || jsonb_build_object(''key'', ''zelle_owners'', ''grp'', ''ROCA1'', ''label'', ''Zelle payments to send to owners'', ''n'', n, ''href'', ''/association-owners/roca1/distributions/'', ''urgent'', n > 0);' || E'\n' || v_old);
    execute v;
  end if;
end $$;

-- The owner's late fee is also held while the tenant's rent for a routed unit is pending.
create or replace function condo_post_late_fees(p_day date)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare
  d int := extract(day from p_day);
  flat_day int := condo_setting('dues_late_flat_day', '10')::int;
  pct_day int := condo_setting('dues_late_pct_day', '11')::int;
  flat numeric := condo_setting('dues_late_flat', '25')::numeric;
  pct numeric := condo_setting('dues_late_pct', '1.15')::numeric;
  pct_base text := condo_setting('dues_late_pct_base', 'balance');
  v_annual numeric := condo_setting('dues_interest_annual_pct', '4.5')::numeric;
  v_eff date := condo_setting('dues_interest_effective', '2026-10-08')::date;
  r record; v_hold boolean; v_held numeric; v_month date := date_trunc('month', p_day)::date; v_base numeric; v_fee numeric; v_credits numeric; n_flat int := 0; n_pct int := 0;
begin
  -- Catch-up: every day from the flat-fee day to month end, each fee at most once per account per month, so a fee held back
  -- while a payment was processing posts the day the payment fails.
  if d < flat_day then return jsonb_build_object('day', p_day, 'late_fees', 0); end if;
  -- Before the effective date: the earlier percentage rule, so history is never recomputed differently.
  if p_day < v_eff and pct_base = 'assessments_simple' then pct_base := 'balance'; end if;
  for r in select a.id, condo_account_balance(a.id, p_day) as bal from condo_ledger_accounts a where a.billing_account and not a.excluded
  loop
    -- A payment still processing (bank payment in flight, or a recent "I've paid" report) holds the fee back: the owner paid on time.
    v_held := coalesce((select sum(s.amount) from stripe_payments s where s.condo_account_id = r.id and s.status = 'processing'), 0)
            + coalesce((select sum(pr.amount) from payment_reports pr where pr.condo_account_id = r.id and pr.status = 'pending' and payment_report_fresh(pr, p_day)), 0);
    -- Unit whose tenant pays rent into ROCA1's account: that tenant's pending rent also holds the fee (the account is paused until it clears).
    v_held := v_held + coalesce((select roca_unit_pending_rent(u2.unit_number, p_day) from condo_ledger_accounts a2 join condo_units u2 on u2.id = a2.unit_id where a2.id = r.id), 0);
    v_hold := exists (select 1 from condo_late_holds where account_id = r.id and month = v_month);
    if r.bal <= 0 then
      if v_hold then delete from condo_late_holds where account_id = r.id and month = v_month; end if;   -- the pending payment cleared: nothing owed
      continue;
    end if;
    continue when not (d = flat_day or d = pct_day or v_hold);
    if r.bal - v_held <= 0 then   -- still pending: hold, and remember it so the fee follows if the payment fails
      insert into condo_late_holds (account_id, month) values (r.id, v_month) on conflict do nothing;
      continue;
    end if;
    if (d = flat_day or v_hold) and flat > 0 and not exists (select 1 from condo_ledger_entries where account_id = r.id and gl_account = 'Late Fee Income'
                                                  and entry_date >= v_month and entry_date <= p_day and origin = 'billing' and description = 'Late fee') then
      insert into condo_ledger_entries (account_id, gl_account, entry_date, kind, raw_type, description, amount, origin, entered_by)
      values (r.id, 'Late Fee Income', p_day, 'late_fee', 'Charge', 'Late fee', flat, 'billing', 'monthly billing');
      n_flat := n_flat + 1;
    end if;
    continue when not (d = pct_day or (v_hold and d >= pct_day));
    if pct_base = 'assessments_simple' then
      -- Simple interest on unpaid assessments that were due before today; all payments and credits applied to them first.
      continue when v_annual <= 0 or exists (select 1 from condo_ledger_entries where account_id = r.id and gl_account = 'Interest Income'
                                                and entry_date >= v_month and entry_date <= p_day and origin = 'billing');
      select coalesce(sum(amount) filter (where amount > 0 and gl_account in ('Association Fee Income', 'Association Dues', 'Special Assessment') and entry_date < p_day), 0),
             coalesce(-sum(amount) filter (where amount < 0), 0)
        into v_base, v_credits
        from condo_ledger_entries where account_id = r.id and entry_date <= p_day;
      v_base := greatest(v_base - v_credits, 0);
      v_fee := round(v_base * v_annual / 100 / 12, 2);
      if v_fee > 0 then
        insert into condo_ledger_entries (account_id, gl_account, entry_date, kind, raw_type, description, amount, origin, entered_by, correction_note)
        values (r.id, 'Interest Income', p_day, 'charge', 'Charge',
                'Interest ' || v_annual || '% a year on unpaid assessments of ' || to_char(v_base, 'FM$999,999,990.00') || ' (one month)', v_fee, 'billing', 'monthly billing',
                'By-Laws 2020 §1500(3) rate; Wis. Stat. § 703.165. Simple interest, not charged on late fees, fines or earlier interest.');
        n_pct := n_pct + 1;
      end if;
    elsif pct > 0 and not exists (select 1 from condo_ledger_entries where account_id = r.id and gl_account = 'Late Fee Income'
                                    and entry_date >= v_month and entry_date <= p_day and origin = 'billing' and description like 'Late fee %') then
      v_base := case when pct_base = 'charges'
                     then (select coalesce(sum(amount), 0) from condo_ledger_entries where account_id = r.id and entry_date <= p_day
                           and not (gl_account = 'Late Fee Income' and amount > 0))
                     else condo_account_balance(r.id, p_day) end;
      v_fee := round(v_base * pct / 100, 2);
      if v_fee > 0 then
        insert into condo_ledger_entries (account_id, gl_account, entry_date, kind, raw_type, description, amount, origin, entered_by)
        values (r.id, 'Late Fee Income', p_day, 'late_fee', 'Charge', 'Late fee ' || pct || '% of ' || to_char(v_base, 'FM$999,999,990.00'), v_fee, 'billing', 'monthly billing');
        n_pct := n_pct + 1;
      end if;
    end if;
  end loop;
  return jsonb_build_object('day', p_day, 'flat_fees', n_flat, 'percent_fees', n_pct, 'rule', pct_base);
end;
$$;
