-- Payments: one bank truth, two official bank accounts, and the review findings fixed (Stephen, 10/7–10/8/2026).
--
-- Stephen: "We are signing up for PLAID and we have Stripe and our official Bank account is CHASE for 2nd Chance and
-- First Citizens for ROCA1." and "Tenants pay 2nd Chance and Owners pay ROCA1."
--
--  A. Two official accounts: Chase (2nd Chance Housing Inc — every tenant payment, all units incl. Class C condo units,
--     land contracts and housing-agency payments) and First Citizens Bank (ROCA1 — every owner payment). Every
--     bank_receipts row now names its account (CSV import picks one; alert emails are routed by handle).
--  B. Plaid is the bank truth. Only a TRUTH record posts money: a Plaid transaction once the account is linked, or (until
--     then) a CSV/manual import for that account. Alert emails, and CSV rows for a Plaid-linked account, are
--     CONFIRMATIONS: they mark a tenant's/owner's "I've paid" as "bank alert seen" but never post. A cross-source
--     duplicate guard sends a would-be second posting (same account, amount and payer within ±3 days) to review.
--  C. A matched receipt is always marked posted; nothing posts a receipt that is already matched. Reports only pair
--     with receipts on their own side (tenant ↔ Chase, owner ↔ First Citizens).
--  D. Owners can't pay through 2nd Chance's Stripe or the shared PayPal button (settings, default off).
--  E. A pending "I've paid" holds back Pay-or-Vacate / 5-day notices only while it is under 5 business days old;
--     older ones are listed to staff daily.
--  F. Reversals: a bounced, refunded, disputed-and-lost or returned payment is reversed by an offsetting ledger line
--     (never deleted) — staff button, and the Stripe webhook for refunds/disputes/late failures.
--  G. A housing-agency deposit in Chase can be assigned to the agency's ledger (one or several tenants).
--  H. resident_home gives the tenant's own portion (housing assistance) for the suggested pay amount.
--  I. Stripe payouts are recorded; the matching Chase deposit is recognised as a payout, not a tenant payment.
--  J. stripe_enabled setting (default off): pay-now and autopay are hidden and refused until Stripe is live.
--  K. Definer functions that exposed lease money without a session check are no longer callable by anon/authenticated.

-- ---------------------------------------------------------------------------
-- A. Accounts
alter table bank_accounts add column if not exists bank_key text;
alter table bank_accounts add column if not exists truth_source text not null default 'csv';
alter table bank_accounts add column if not exists entity text;
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'bank_accounts_truth_source_check') then
    alter table bank_accounts add constraint bank_accounts_truth_source_check check (truth_source in ('plaid', 'csv'));
  end if;
end $$;
create unique index if not exists bank_accounts_bank_key_idx on bank_accounts (bank_key) where bank_key is not null;

-- Adopt an existing account of the right side if there is one (e.g. already linked on the live site), else create it.
do $$
declare v uuid;
begin
  if not exists (select 1 from bank_accounts where bank_key = 'chase_2ch') then
    select id into v from bank_accounts where kind = 'tenant' and bank_key is null order by (plaid_item_id is not null) desc, created_at limit 1;
    if v is not null then update bank_accounts set bank_key = 'chase_2ch' where id = v;
    else insert into bank_accounts (name, kind, institution, bank_key) values ('2nd Chance Housing Inc — Chase', 'tenant', 'Chase', 'chase_2ch'); end if;
  end if;
  if not exists (select 1 from bank_accounts where bank_key = 'first_citizens_roca1') then
    select id into v from bank_accounts where kind = 'owner' and bank_key is null order by (plaid_item_id is not null) desc, created_at limit 1;
    if v is not null then update bank_accounts set bank_key = 'first_citizens_roca1' where id = v;
    else insert into bank_accounts (name, kind, institution, bank_key) values ('ROCA1 — First Citizens Bank', 'owner', 'First Citizens Bank', 'first_citizens_roca1'); end if;
  end if;
end $$;
update bank_accounts set entity = '2nd Chance Housing Inc', institution = coalesce(institution, 'Chase') where bank_key = 'chase_2ch';
update bank_accounts set entity = 'ROCA1', institution = coalesce(institution, 'First Citizens Bank') where bank_key = 'first_citizens_roca1';
update bank_accounts set truth_source = 'plaid' where plaid_item_id is not null;

insert into portal_settings (key, value) values
  -- Payment-alert emails: which account each alert belongs to. Each line "text => bank_key"; the text is looked for
  -- (case-insensitive) in the alert's subject/body/recipient. Anything unmatched goes to Chase.
  ('bank_alert_routes', 'rocaone => first_citizens_roca1' || chr(10) || 'ROYAL ORLEANS => first_citizens_roca1' || chr(10) || 'ROCA1 => first_citizens_roca1'),
  ('owner_pay_stripe', 'off'),
  ('owner_pay_paypal', 'off'),
  ('stripe_enabled', 'off'),
  ('pending_hold_business_days', '5')
on conflict (key) do nothing;

-- "Tenants pay 2nd Chance": the tenant pay-by-mail payee (was ROCA1).
update portal_settings set value = '2nd Chance Housing Inc.' || chr(10) || '6626 North Bourbon Street' || chr(10) || 'Milwaukee, WI 53224'
 where key = 'pay_by_mail';

create or replace function bank_account_by_key(p_key text)
returns uuid language sql stable security definer set search_path = public as $$ select id from bank_accounts where bank_key = p_key; $$;
revoke all on function bank_account_by_key(text) from public, anon, authenticated;

-- Route an alert to an account by the settings table.
create or replace function bank_alert_account(p_text text)
returns uuid
language plpgsql stable security definer set search_path = public as $$
declare ln text; v_pat text; v_key text;
begin
  for ln in select regexp_split_to_table(coalesce((select value from portal_settings where key = 'bank_alert_routes'), ''), chr(10)) loop
    continue when position('=>' in ln) = 0;
    v_pat := trim(split_part(ln, '=>', 1)); v_key := trim(split_part(ln, '=>', 2));
    if v_pat <> '' and position(lower(v_pat) in lower(coalesce(p_text, ''))) > 0 and bank_account_by_key(v_key) is not null then
      return bank_account_by_key(v_key);
    end if;
  end loop;
  return bank_account_by_key('chase_2ch');
end;
$$;
revoke all on function bank_alert_account(text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- B. Truth vs confirmation
alter table bank_receipts add column if not exists role text;
alter table bank_receipts add column if not exists linked_receipt_id uuid references bank_receipts(id);
alter table bank_receipts add column if not exists confirms_report_id uuid references payment_reports(id);
alter table bank_receipts drop constraint if exists bank_receipts_status_check;
alter table bank_receipts add constraint bank_receipts_status_check
  check (status in ('new', 'posted', 'needs_review', 'ignored', 'confirmation', 'stripe_payout'));
alter table payment_reports add column if not exists bank_alert_seen_at timestamptz;

create or replace function bank_receipt_classify()
returns trigger
language plpgsql security definer set search_path = public as $$
declare v_truth text;
begin
  if new.bank_account_id is null then
    new.bank_account_id := case when new.source = 'email_alert'
      then bank_alert_account(concat_ws(' ', new.account, new.description, new.payer_name, new.raw::text))
      else bank_account_by_key('chase_2ch') end;
  end if;
  select truth_source into v_truth from bank_accounts where id = new.bank_account_id;
  if new.role is null then
    new.role := case
      when new.source = 'plaid' and v_truth = 'plaid' then 'truth'
      when new.source in ('chase_csv', 'manual') and coalesce(v_truth, 'csv') = 'csv' then 'truth'
      else 'confirmation' end;
  end if;
  if new.role = 'confirmation' and new.status = 'new' then new.status := 'confirmation'; end if;
  return new;
end;
$$;
drop trigger if exists bank_receipts_classify on bank_receipts;
create trigger bank_receipts_classify before insert on bank_receipts for each row execute function bank_receipt_classify();

-- Existing rows: give them an account and a role.
update bank_receipts set bank_account_id = case when source = 'email_alert'
    then bank_alert_account(concat_ws(' ', account, description, payer_name, raw::text)) else bank_account_by_key('chase_2ch') end
 where bank_account_id is null;
update bank_receipts b set role = case
    when b.source = 'plaid' and a.truth_source = 'plaid' then 'truth'
    when b.source in ('chase_csv', 'manual') and a.truth_source = 'csv' then 'truth'
    when b.status = 'posted' or b.matched_report_id is not null then 'truth'    -- already posted: history stays as it is
    else 'confirmation' end
  from bank_accounts a where a.id = b.bank_account_id and b.role is null;
update bank_receipts set status = 'confirmation' where role = 'confirmation' and status in ('new', 'needs_review') and matched_report_id is null;
update bank_receipts set status = 'posted' where matched_report_id is not null and status in ('new', 'needs_review');
alter table bank_receipts alter column bank_account_id set not null;
alter table bank_receipts alter column role set not null;

-- Which side a report belongs to: 'owner' (dues, First Citizens) or 'tenant' (rent / land contract, Chase).
create or replace function payment_report_side(r payment_reports)
returns text language sql immutable as $$ select case when r.condo_account_id is not null or (r.owner_id is not null and r.tenant_id is null) then 'owner' else 'tenant' end; $$;

create or replace function bank_receipt_side(p_receipt uuid)
returns text language sql stable security definer set search_path = public as $$
  select a.kind from bank_receipts b join bank_accounts a on a.id = b.bank_account_id where b.id = p_receipt;
$$;
revoke all on function bank_receipt_side(uuid) from public, anon, authenticated;

-- Cross-source duplicate guard: another receipt on the same account, already posted (or a payout), same amount,
-- within ±3 days, same payer (or no payer on either side).
create or replace function bank_receipt_duplicate_of(p_receipt uuid)
returns uuid
language sql stable security definer set search_path = public as $$
  select o.id from bank_receipts b join bank_receipts o on o.bank_account_id = b.bank_account_id and o.id <> b.id
  where b.id = p_receipt and o.status = 'posted' and o.amount = b.amount and abs(o.posted_on - b.posted_on) <= 3
    and o.id is distinct from b.linked_receipt_id
    and (nullif(payer_norm(o.payer_name), '') is null or nullif(payer_norm(b.payer_name), '') is null or payer_norm(o.payer_name) = payer_norm(b.payer_name))
  order by abs(o.posted_on - b.posted_on) limit 1;
$$;
revoke all on function bank_receipt_duplicate_of(uuid) from public, anon, authenticated;

-- When a truth receipt posts, link the confirmations that describe the same money.
create or replace function bank_link_confirmations(p_receipt uuid)
returns int
language plpgsql volatile security definer set search_path = public as $$
declare b bank_receipts; n int;
begin
  select * into b from bank_receipts where id = p_receipt;
  update bank_receipts c set linked_receipt_id = b.id
   where c.role = 'confirmation' and c.linked_receipt_id is null and c.bank_account_id = b.bank_account_id and c.amount = b.amount
     and abs(c.posted_on - b.posted_on) <= 3
     and (c.confirms_report_id = b.matched_report_id or nullif(payer_norm(c.payer_name), '') is null or nullif(payer_norm(b.payer_name), '') is null
          or payer_norm(c.payer_name) = payer_norm(b.payer_name));
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke all on function bank_link_confirmations(uuid) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- C. Posting guards
create or replace function payment_post(p_report uuid, p_receipt uuid, p_source text, p_by text)
returns void
language plpgsql security definer set search_path = public as $$
declare r payment_reports; b bank_receipts; v_entry bigint; v_label text;
begin
  select * into r from payment_reports where id = p_report for update;
  if r.id is null or r.status <> 'pending' then return; end if;
  if p_receipt is not null then
    select * into b from bank_receipts where id = p_receipt for update;
    if b.id is null then raise exception 'Deposit not found'; end if;
    if b.matched_report_id is not null and b.matched_report_id <> r.id then raise exception 'That deposit is already matched to another payment.'; end if;
    if b.status in ('posted', 'stripe_payout', 'ignored') then raise exception 'That deposit is already %.', replace(b.status, '_', ' '); end if;
    if bank_receipt_side(b.id) <> payment_report_side(r) then
      raise exception 'That deposit is in the % account; this payment belongs to the % side (tenants pay 2nd Chance at Chase, owners pay ROCA1 at First Citizens).',
        case bank_receipt_side(b.id) when 'owner' then 'ROCA1 (First Citizens)' else '2nd Chance (Chase)' end, payment_report_side(r);
    end if;
  end if;
  v_label := initcap(replace(r.method, '_', ' ')) || ' payment';
  if r.condo_account_id is not null then
    insert into condo_ledger_entries (account_id, gl_account, entry_date, kind, raw_type, method, check_number, description, amount, origin, entered_by, correction_note, payment_report_id)
    values (r.condo_account_id, 'Association Fee Income', r.paid_on, 'payment', v_label || ' (verified)', r.method, r.confirmation_code,
            'Payment by ' || coalesce(r.payer_name, (select name from condo_owners where id = r.owner_id)), -r.amount, 'staff', coalesce(p_by, 'system'),
            'Reported online; verified via ' || p_source || ' on ' || to_char(now(), 'YYYY-MM-DD'), r.id)
    returning id into v_entry;
  elsif r.lease_id is not null then
    insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, method, check_number, description, amount, source, correction_note)
    values (r.lease_id, 'Rent Income', r.paid_on, 'payment', v_label || ' (verified)', r.method, r.confirmation_code,
            'Payment by ' || coalesce(r.payer_name, (select name from tenants where id = r.tenant_id)), -r.amount, 'payment_report',
            'Verified via ' || p_source || coalesce(' by ' || p_by, '') || ' on ' || to_char(now(), 'YYYY-MM-DD'))
    returning id into v_entry;
  elsif r.land_contract_id is not null then
    insert into land_contract_ledger (contract_id, entry_date, kind, raw_type, description, amount, source, correction_note)
    values (r.land_contract_id, r.paid_on, 'payment', v_label || ' (verified)', 'Payment by ' || coalesce(r.payer_name, ''), -r.amount, 'payment_report',
            'Verified via ' || p_source)
    returning id into v_entry;
  end if;
  update payment_reports set status = 'verified', verified_at = now(), verified_by = p_by, verification_source = p_source,
         bank_receipt_id = p_receipt, ledger_entry_id = v_entry where id = r.id;
  if p_receipt is not null then
    -- A matched deposit is a posted deposit: it leaves the review queue and can never be posted again.
    update bank_receipts set matched_report_id = r.id, status = 'posted', posted_at = coalesce(posted_at, now()), review_reason = null where id = p_receipt;
    perform bank_link_confirmations(p_receipt);
  end if;
end;
$$;
revoke all on function payment_post(uuid, uuid, text, text) from public, anon, authenticated;

create or replace function bank_post_receipt(p_receipt uuid, p_kind text, p_target uuid, p_how text, p_by text)
returns uuid
language plpgsql security definer set search_path = public as $$
declare b bank_receipts; v_report uuid; v_tenant uuid; v_owner uuid; v_method text; v_lease uuid; v_contract uuid; v_acct uuid; v_side text;
begin
  select * into b from bank_receipts where id = p_receipt for update;
  if b.id is null then raise exception 'Deposit not found'; end if;
  if b.status in ('posted', 'stripe_payout') or b.matched_report_id is not null then raise exception 'That deposit is already posted.'; end if;
  v_side := bank_receipt_side(b.id);
  if (v_side = 'owner') <> (p_kind = 'condo') then
    raise exception 'That deposit is in the % account; it can only post to the % side.',
      case v_side when 'owner' then 'ROCA1 (First Citizens)' else '2nd Chance (Chase)' end, case v_side when 'owner' then 'owner dues' else 'tenant rent' end;
  end if;
  v_method := bank_receipt_method(coalesce(b.description, '') || ' ' || coalesce(b.payer_name, ''));
  if p_kind = 'lease' then
    v_lease := p_target;
    select lt.tenant_id into v_tenant from lease_tenants lt join tenants t on t.id = lt.tenant_id where lt.lease_id = v_lease
      order by (select count(*) from unnest(payer_tokens(b.payer_name)) w where lower(t.name) like '%' || w || '%') desc, t.created_at limit 1;
  elsif p_kind = 'land_contract' then
    v_contract := p_target;
    select bu.tenant_id into v_tenant from land_contract_buyers bu where bu.contract_id = v_contract order by bu.tenant_id limit 1;
  elsif p_kind = 'condo' then
    v_acct := p_target;
    select s.owner_id into v_owner from condo_ledger_accounts a join condo_ownerships s on s.unit_id = a.unit_id and s.is_current where a.id = v_acct limit 1;
  else raise exception 'Unknown target'; end if;
  if v_tenant is null and v_owner is null then raise exception 'No payer found for that target'; end if;
  insert into payment_reports (tenant_id, owner_id, lease_id, land_contract_id, condo_account_id, method, amount, paid_on, confirmation_code, payer_name, note, status)
  values (v_tenant, v_owner, v_lease, v_contract, v_acct, v_method, b.amount, b.posted_on, nullif(left(coalesce(b.reference, ''), 40), ''), nullif(b.payer_name, ''),
          'Posted automatically from the bank deposit (' || p_how || ')', 'pending')
  returning id into v_report;
  perform payment_post(v_report, p_receipt, 'bank_feed', p_by);
  update bank_receipts set status = 'posted', confidence = p_how, posted_at = now(), review_reason = null, matched_report_id = v_report where id = p_receipt;
  return v_report;
end;
$$;
revoke all on function bank_post_receipt(uuid, text, uuid, text, text) from public, anon, authenticated;

-- Pair "I've paid" reports with deposits. Truth receipts on the same side post the report; confirmations
-- (alert emails, non-truth CSV rows) only mark it "bank alert seen".
create or replace function payments_auto_match()
returns integer
language plpgsql security definer set search_path = public as $$
declare rec record; n int := 0; v_dup uuid;
begin
  for rec in
    with cand as (
      select b.id as receipt_id, r.id as report_id, b.source, b.role
      from bank_receipts b
      join bank_accounts ba on ba.id = b.bank_account_id
      join payment_reports r on r.status = 'pending' and r.amount = b.amount and abs(b.posted_on - r.paid_on) <= 4
      left join tenants t on t.id = r.tenant_id
      left join condo_owners o on o.id = r.owner_id
      left join leases l on l.id = r.lease_id
      left join condo_ledger_accounts ca on ca.id = r.condo_account_id
      left join condo_units cu on cu.id = ca.unit_id
      where b.matched_report_id is null and b.confirms_report_id is null and not b.ignored and b.amount > 0
        and b.status in ('new', 'needs_review', 'confirmation')
        and ba.kind = payment_report_side(r)
        and (
          exists (select 1 from regexp_split_to_table(lower(coalesce(t.name, o.name, '')), '\s+') w where length(w) >= 3 and lower(coalesce(b.payer_name, '') || ' ' || coalesce(b.description, '')) like '%' || w || '%')
          or (l.legacy_lease_number is not null and coalesce(b.description, '') || coalesce(b.reference, '') like '%' || l.legacy_lease_number || '%')
          or (cu.pin is not null and coalesce(b.description, '') || coalesce(b.reference, '') like '%' || cu.pin || '%')
          or (r.confirmation_code is not null and length(r.confirmation_code) >= 5 and coalesce(b.description, '') || coalesce(b.reference, '') ilike '%' || r.confirmation_code || '%')
          or (r.payer_name is not null and length(r.payer_name) >= 3 and lower(coalesce(b.payer_name, '') || ' ' || coalesce(b.description, '')) like '%' || lower(r.payer_name) || '%')
        )
    )
    select c.* from cand c
    where (select count(*) from cand x where x.receipt_id = c.receipt_id) = 1
      and (select count(*) from cand x where x.report_id = c.report_id and x.role = c.role) = 1
  loop
    if rec.role = 'confirmation' then
      update bank_receipts set confirms_report_id = rec.report_id where id = rec.receipt_id;
      update payment_reports set bank_alert_seen_at = coalesce(bank_alert_seen_at, now()) where id = rec.report_id;
      continue;
    end if;
    v_dup := bank_receipt_duplicate_of(rec.receipt_id);
    if v_dup is not null then
      update bank_receipts set status = 'needs_review', review_reason = 'Possible duplicate of a deposit already posted (' ||
        (select to_char(posted_on, 'FMMM/FMDD') || ' ' || coalesce(payer_name, '') from bank_receipts where id = v_dup) || ')' where id = rec.receipt_id;
      continue;
    end if;
    perform payment_post(rec.report_id, rec.receipt_id, case rec.source when 'chase_csv' then 'bank_csv' when 'plaid' then 'bank_feed' when 'manual' then 'staff' else 'staff' end, 'system');
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke all on function payments_auto_match() from public, anon, authenticated;

create or replace function payments_staff_decide(p_report uuid, p_action text, p_receipt uuid, p_reason text)
returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if p_action = 'verify' then
    perform payment_post(p_report, p_receipt, case when p_receipt is null then 'staff'
      else case (select source from bank_receipts where id = p_receipt) when 'plaid' then 'bank_feed' when 'email_alert' then 'email_alert' else 'bank_csv' end end, auth.email());
  elsif p_action = 'reject' then
    update payment_reports set status = 'rejected', reject_reason = nullif(trim(coalesce(p_reason, '')), ''), verified_by = auth.email(), verified_at = now()
     where id = p_report and status = 'pending';
  else raise exception 'Unknown action'; end if;
  return jsonb_build_object('ok', true);
end;
$$;
revoke all on function payments_staff_decide(uuid, text, uuid, text) from public, anon;
grant execute on function payments_staff_decide(uuid, text, uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- I. Stripe payouts
create table if not exists stripe_payouts (
  id text primary key,                     -- Stripe payout id
  amount numeric(12,2) not null,
  arrival_date date,
  status text not null,
  description text,
  bank_receipt_id uuid references bank_receipts(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
alter table stripe_payouts enable row level security;

create or replace function stripe_payout_record(p_id text, p_amount numeric, p_arrival date, p_status text, p_description text)
returns void
language sql volatile security definer set search_path = public as $$
  insert into stripe_payouts (id, amount, arrival_date, status, description) values (p_id, p_amount, p_arrival, p_status, p_description)
  on conflict (id) do update set amount = excluded.amount, arrival_date = excluded.arrival_date, status = excluded.status, updated_at = now();
$$;
revoke all on function stripe_payout_record(text, numeric, date, text, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- The autopilot: payouts recognised first, then pairing, then truth receipts by payer — with the duplicate guard.
create or replace function bank_autopilot()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record; c record; n_top int; v_posted int := 0; v_review int := 0; v_ignored int := 0; v_payouts int := 0; v_matched int; v_reason text;
  v_bal numeric; v_cap numeric; v_po text; v_dup uuid;
begin
  -- Stripe payouts landing in Chase: not a tenant payment (the payments already posted from Stripe's webhook).
  for r in select b.* from bank_receipts b join bank_accounts a on a.id = b.bank_account_id
           where b.status in ('new', 'needs_review') and b.matched_report_id is null and b.amount > 0 and a.kind = 'tenant'
             and coalesce(b.description, '') || ' ' || coalesce(b.payer_name, '') ~* 'stripe' loop
    select p.id into v_po from stripe_payouts p where p.status = 'paid' and p.bank_receipt_id is null and p.amount = r.amount
      and abs(p.arrival_date - r.posted_on) <= 3 order by abs(p.arrival_date - r.posted_on) limit 1;
    if v_po is not null then
      update stripe_payouts set bank_receipt_id = r.id, updated_at = now() where id = v_po;
      update bank_receipts set status = 'stripe_payout', review_reason = 'Stripe payout ' || v_po || ' (payments already posted from Stripe)', confidence = 'stripe payout' where id = r.id;
      v_payouts := v_payouts + 1;
    end if;
  end loop;
  v_matched := payments_auto_match();      -- tenant/owner-reported payments still pair first
  for r in select * from bank_receipts where status in ('new', 'needs_review') and role = 'truth' and matched_report_id is null and not ignored order by posted_on, created_at loop
    if r.amount <= 0 then
      if coalesce(r.description, '') ~* 'return|reversal|chargeback|dispute|nsf|unauthorized' then
        update bank_receipts set status = 'needs_review', review_reason = 'A returned or reversed payment: find the payment and press Reverse', confidence = null where id = r.id;
        v_review := v_review + 1;
      else
        update bank_receipts set status = 'ignored', review_reason = 'Money out' where id = r.id; v_ignored := v_ignored + 1;
      end if;
      continue;
    end if;
    v_dup := bank_receipt_duplicate_of(r.id);
    if v_dup is not null then
      update bank_receipts set status = 'needs_review', review_reason = 'Possible duplicate of a deposit already posted (' ||
        (select to_char(posted_on, 'FMMM/FMDD') || ' ' || coalesce(payer_name, '') from bank_receipts where id = v_dup) || ')', confidence = null where id = r.id;
      v_review := v_review + 1;
      continue;
    end if;
    select count(*) into n_top from bank_candidates(r.id) x where x.rank = (select min(y.rank) from bank_candidates(r.id) y);
    select * into c from bank_candidates(r.id) order by rank limit 1;
    v_reason := null;
    if c.target_id is null then
      v_reason := case when coalesce(r.description, '') || ' ' || coalesce(r.payer_name, '') ~* 'housing auth|hacm|cha\M|voucher|hap\M|county|section 8'
                       then 'Looks like a housing agency payment: assign it to the agency' else 'Nobody matches this payer yet' end;
    elsif n_top > 1 then
      v_reason := 'More than one possible match (' || n_top || ')';
    else
      if c.target_kind = 'lease' then
        v_bal := coalesce((select sum(amount) from lease_ledger_entries where lease_id = c.target_id), 0);
        v_cap := greatest(v_bal, 0) + 3 * coalesce((select rent from leases where id = c.target_id), 0);
      elsif c.target_kind = 'condo' then
        v_bal := coalesce((select sum(e.amount) from condo_ledger_entries e join condo_ledger_accounts a2 on a2.id = e.account_id
                           where a2.ownership_id = (select ownership_id from condo_ledger_accounts where id = c.target_id) and not a2.excluded), 0);
        v_cap := greatest(v_bal, 0) + 3 * coalesce(nullif(condo_setting('dues_default', '215'), '')::numeric, 215);
      else
        v_cap := 1e9;
      end if;
      if r.amount > v_cap then v_reason := 'Amount is more than the balance plus three months'; end if;
    end if;
    if v_reason is null then
      begin
        perform bank_post_receipt(r.id, c.target_kind, c.target_id,
          case c.rank when 1 then 'account number in memo' when 2 then 'known payer' else 'payer name' end, 'autopilot');
        perform bank_link_confirmations(r.id);
        v_posted := v_posted + 1;
      exception when others then
        update bank_receipts set status = 'needs_review', review_reason = left('Could not post: ' || sqlerrm, 200) where id = r.id; v_review := v_review + 1;
      end;
    else
      update bank_receipts set status = 'needs_review', review_reason = v_reason, confidence = null where id = r.id;
      v_review := v_review + 1;
    end if;
  end loop;
  return jsonb_build_object('paired_with_reports', v_matched, 'posted', v_posted, 'needs_review', v_review, 'ignored', v_ignored, 'stripe_payouts', v_payouts);
end;
$$;
revoke all on function bank_autopilot() from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- G. Agency deposits
alter table assistance_ledger add column if not exists bank_receipt_id uuid references bank_receipts(id);

create or replace function bank_staff_assign_agency(p_receipt uuid, p_items jsonb, p_note text)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare b bank_receipts; it jsonb; a housing_assistance; v_amt numeric; v_total numeric := 0; v_n int := 0;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into b from bank_receipts where id = p_receipt for update;
  if b.id is null then raise exception 'Deposit not found'; end if;
  if b.status in ('posted', 'stripe_payout') or b.matched_report_id is not null then raise exception 'That deposit is already posted.'; end if;
  if bank_receipt_side(b.id) <> 'tenant' then raise exception 'Housing agency payments go to 2nd Chance''s Chase account; this deposit is in ROCA1''s account.'; end if;
  for it in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    v_amt := round(nullif(it->>'amount', '')::numeric, 2);
    continue when v_amt is null or v_amt = 0;
    if v_amt < 0 then raise exception 'Amounts must be positive.'; end if;
    select * into a from housing_assistance where id = (it->>'assistance_id')::uuid;
    if a.id is null then raise exception 'Assistance record not found'; end if;
    insert into assistance_ledger (assistance_id, lease_id, entry_date, kind, amount, method, reference, description, created_by, bank_receipt_id)
    values (a.id, a.lease_id, b.posted_on, 'payment', -v_amt, 'eft', nullif(left(coalesce(b.reference, ''), 60), ''),
            'Payment from ' || a.agency_name || ' (bank deposit ' || to_char(b.posted_on, 'FMMM/FMDD/YYYY') || ')' || coalesce(' — ' || nullif(trim(coalesce(p_note, '')), ''), ''),
            lower(auth.email()), b.id);
    v_total := v_total + v_amt; v_n := v_n + 1;
  end loop;
  if v_n = 0 then raise exception 'Enter at least one amount.'; end if;
  if v_total <> b.amount then raise exception 'The amounts add up to %, but the deposit is %.', to_char(v_total, 'FM$999,990.00'), to_char(b.amount, 'FM$999,990.00'); end if;
  update bank_receipts set status = 'posted', posted_at = now(), confidence = 'housing agency (assigned by staff)', review_reason = null where id = b.id;
  perform bank_link_confirmations(b.id);
  return jsonb_build_object('lines', v_n, 'total', v_total);
end;
$$;
revoke all on function bank_staff_assign_agency(uuid, jsonb, text) from public, anon;
grant execute on function bank_staff_assign_agency(uuid, jsonb, text) to authenticated;

create or replace function bank_staff_assign(p_receipt uuid, p_kind text, p_target uuid, p_remember boolean)
returns void
language plpgsql security definer set search_path = public as $$
declare b bank_receipts; v_scope text; v_norm text;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into b from bank_receipts where id = p_receipt;
  if b.id is null then raise exception 'Deposit not found'; end if;
  if p_kind = 'agency' then
    perform bank_staff_assign_agency(p_receipt, jsonb_build_array(jsonb_build_object('assistance_id', p_target, 'amount', b.amount)), null);
    return;
  end if;
  v_scope := bank_receipt_side(b.id);
  if (v_scope = 'owner') <> (p_kind = 'condo') then raise exception 'That deposit is in the % bank account; it can only post to the % side', v_scope, case v_scope when 'owner' then 'owner dues' else 'tenant rent' end; end if;
  perform bank_post_receipt(p_receipt, p_kind, p_target, 'assigned by staff', auth.email());
  perform bank_link_confirmations(p_receipt);
  v_norm := payer_norm(coalesce(nullif(b.payer_name, ''), b.description));
  if p_remember and v_norm <> '' then
    insert into payer_aliases (scope, alias, lease_id, land_contract_id, condo_account_id, created_by)
    values (v_scope, v_norm, case when p_kind = 'lease' then p_target end, case when p_kind = 'land_contract' then p_target end, case when p_kind = 'condo' then p_target end, auth.email())
    on conflict (scope, alias) do update set lease_id = excluded.lease_id, land_contract_id = excluded.land_contract_id, condo_account_id = excluded.condo_account_id, created_by = excluded.created_by;
  end if;
  perform bank_autopilot();
end;
$$;
revoke all on function bank_staff_assign(uuid, text, uuid, boolean) from public, anon;
grant execute on function bank_staff_assign(uuid, text, uuid, boolean) to authenticated;

create or replace function bank_staff_overview()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'accounts', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'kind', a.kind, 'institution', a.institution, 'mask', a.mask, 'bank_key', a.bank_key,
        'entity', a.entity, 'truth_source', a.truth_source,
        'connected', a.plaid_item_id is not null, 'last_synced_at', a.last_synced_at, 'last_error', a.last_error, 'active', a.active) order by a.kind desc, a.name) from bank_accounts a), '[]'::jsonb),
    'queue', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'posted_on', b.posted_on, 'amount', b.amount, 'payer', b.payer_name, 'description', b.description,
        'reason', b.review_reason, 'kind', bank_receipt_side(b.id), 'source', b.source,
        'candidates', coalesce((select jsonb_agg(jsonb_build_object('kind', c.target_kind, 'id', c.target_id, 'label', c.label, 'why', c.why) order by c.rank, c.label)
                                from (select * from bank_candidates(b.id) order by rank limit 5) c), '[]'::jsonb)) order by b.posted_on desc)
      from bank_receipts b where b.status = 'needs_review'), '[]'::jsonb),
    'agencies', coalesce((select jsonb_agg(jsonb_build_object('id', h.id, 'agency', h.agency_name, 'unit', ru.unit_number, 'tenants', l.tenants_label,
        'portion', h.agency_portion, 'owes', (select coalesce(sum(amount), 0) from assistance_ledger x where x.assistance_id = h.id)) order by h.agency_name, ru.unit_number)
      from housing_assistance h join leases l on l.id = h.lease_id left join rental_units ru on ru.id = l.unit_id where h.status = 'active'), '[]'::jsonb),
    'confirmations', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'posted_on', b.posted_on, 'amount', b.amount, 'payer', b.payer_name, 'source', b.source,
        'kind', bank_receipt_side(b.id), 'linked', b.linked_receipt_id is not null, 'report', b.confirms_report_id) order by b.posted_on desc)
      from (select * from bank_receipts where role = 'confirmation' and posted_on > current_date - 45 order by posted_on desc limit 40) b), '[]'::jsonb),
    'recent', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'posted_on', b.posted_on, 'amount', b.amount, 'payer', b.payer_name, 'how', b.confidence, 'posted_at', b.posted_at,
        'source', b.source, 'status', b.status, 'kind', bank_receipt_side(b.id)) order by b.posted_at desc nulls last)
      from (select * from bank_receipts where status in ('posted', 'stripe_payout') order by posted_at desc nulls last limit 30) b), '[]'::jsonb));
end;
$$;
revoke all on function bank_staff_overview() from public, anon;
grant execute on function bank_staff_overview() to authenticated;

-- CSV/manual import: rows carry the account (default Chase); a CSV for a Plaid-linked account only confirms.
create or replace function payments_staff_import(p_source text, p_rows jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare x jsonb; v_new int := 0; v_res jsonb; v_acct uuid;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if p_source not in ('chase_csv', 'manual') then raise exception 'Unknown source'; end if;
  for x in select * from jsonb_array_elements(p_rows) loop
    v_acct := coalesce(nullif(x->>'bank_account_id', '')::uuid, bank_account_by_key('chase_2ch'));
    insert into bank_receipts (source, account, posted_on, amount, description, payer_name, reference, fingerprint, raw, bank_account_id)
    values (p_source, x->>'account', (x->>'posted_on')::date, (x->>'amount')::numeric, x->>'description', x->>'payer_name', x->>'reference',
            p_source || '|' || v_acct || '|' || (x->>'posted_on') || '|' || (x->>'amount') || '|' || coalesce(x->>'description', '') || '|' || coalesce(x->>'reference', ''), x,
            v_acct)
    on conflict (fingerprint) do nothing;
    if found then v_new := v_new + 1; end if;
  end loop;
  v_res := bank_autopilot();
  return jsonb_build_object('new_receipts', v_new, 'matched', (v_res->>'paired_with_reports')::int + (v_res->>'posted')::int) || v_res;
end;
$$;
revoke all on function payments_staff_import(text, jsonb) from public, anon;
grant execute on function payments_staff_import(text, jsonb) to authenticated;

create or replace function payments_staff_queue()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'reports', coalesce((select jsonb_agg(to_jsonb(r) || jsonb_build_object(
        'tenant', coalesce(t.name, o.name || ' (owner)'),
        'account_number', coalesce(l.legacy_lease_number, cu.pin),
        'unit', coalesce(u.unit_number, case when cu.unit_number is not null then 'ROCA ' || cu.unit_number || ' dues' end),
        'side', payment_report_side(r),
        'receipt', (select to_jsonb(b) - 'raw' from bank_receipts b where b.id = r.bank_receipt_id)) order by r.created_at desc)
      from payment_reports r left join tenants t on t.id = r.tenant_id left join condo_owners o on o.id = r.owner_id
      left join leases l on l.id = r.lease_id left join rental_units u on u.id = l.unit_id
      left join condo_ledger_accounts ca on ca.id = r.condo_account_id left join condo_units cu on cu.id = ca.unit_id
      where r.created_at > now() - interval '120 days'), '[]'::jsonb),
    'accounts', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'kind', a.kind, 'bank_key', a.bank_key, 'truth_source', a.truth_source) order by a.kind desc) from bank_accounts a where a.active), '[]'::jsonb),
    'unmatched_receipts', coalesce((select jsonb_agg(to_jsonb(b) - 'raw' || jsonb_build_object('side', bank_receipt_side(b.id)) order by b.posted_on desc)
      from bank_receipts b where b.matched_report_id is null and b.assigned_lease_id is null and not b.ignored
        and b.status not in ('posted', 'stripe_payout', 'ignored') and b.posted_on > current_date - 120), '[]'::jsonb));
end;
$$;
revoke all on function payments_staff_queue() from public, anon;
grant execute on function payments_staff_queue() to authenticated;

-- ---------------------------------------------------------------------------
-- E. Pending reports hold notices only while fresh
create or replace function business_days_between(p_from date, p_to date)
returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from generate_series(p_from + 1, p_to, interval '1 day') d
  where extract(isodow from d) < 6 and not exists (select 1 from court_holidays h where h.day = d::date);
$$;
revoke all on function business_days_between(date, date) from public, anon, authenticated;

create or replace function payment_report_fresh(r payment_reports, p_as_of date)
returns boolean
language sql stable security definer set search_path = public as $$
  select business_days_between(r.created_at::date, p_as_of) < coalesce((select value from portal_settings where key = 'pending_hold_business_days'), '5')::int;
$$;
revoke all on function payment_report_fresh(payment_reports, date) from public, anon, authenticated;

create or replace function rent_unpaid(p_as_of date)
returns table(lease_id uuid, unit_label text, address text, rent_due numeric, pending_reported numeric, tenants jsonb, account_number text, property_key text)
language sql stable security definer set search_path = public as $$
  select l.id, coalesce(u.unit_number, ''), u.address, lease_rent_due(l.id, p_as_of),
         coalesce((select sum(r.amount) from payment_reports r where r.lease_id = l.id and r.status = 'pending' and payment_report_fresh(r, p_as_of)), 0)
           + coalesce((select sum(s.amount) from stripe_payments s where s.lease_id = l.id and s.status = 'processing'), 0),
         (select jsonb_agg(jsonb_build_object('name', t.name, 'email', t.email)) from lease_tenants x join tenants t on t.id = x.tenant_id where x.lease_id = l.id),
         l.legacy_lease_number, p.key
  from leases l join rental_units u on u.id = l.unit_id join rental_properties p on p.id = u.property_id
  where l.status = 'active' and lease_rent_due(l.id, p_as_of) > 0;
$$;
revoke all on function rent_unpaid(date) from public, anon, authenticated;

-- Daily: stale "I've paid" reports (no longer holding notices) go to staff.
create or replace function payments_stale_pending(p_as_of date)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v jsonb;
begin
  select coalesce(jsonb_agg(jsonb_build_object('id', r.id, 'who', coalesce(t.name, o.name), 'amount', r.amount, 'paid_on', r.paid_on, 'reported', r.created_at::date,
      'side', payment_report_side(r), 'alert_seen', r.bank_alert_seen_at is not null) order by r.created_at), '[]'::jsonb) into v
    from payment_reports r left join tenants t on t.id = r.tenant_id left join condo_owners o on o.id = r.owner_id
   where r.status = 'pending' and not payment_report_fresh(r, p_as_of);
  if jsonb_array_length(v) > 0 then
    insert into email_outbox (to_email, subject, html, kind)
    select coalesce(nullif((select value from portal_settings where key = 'office_email'), ''), 'info@2ndchinc.org'),
      'Payments reported but not found in the bank (' || jsonb_array_length(v) || ')',
      '<p>These "I''ve paid" reports are more than ' || coalesce((select value from portal_settings where key = 'pending_hold_business_days'), '5')
      || ' business days old and haven''t matched a bank deposit. They no longer hold back rent notices. Verify or reject each one on the Payments page.</p><ul>'
      || (select string_agg('<li>' || repair_esc(x->>'who') || ' — ' || to_char((x->>'amount')::numeric, 'FM$999,990.00') || ' paid ' || (x->>'paid_on')
            || ', reported ' || (x->>'reported') || case when (x->>'alert_seen')::boolean then ' (a bank alert was seen)' else '' end || '</li>', '') from jsonb_array_elements(v) x)
      || '</ul>', 'payments_stale'
    where not exists (select 1 from email_outbox where kind = 'payments_stale' and created_at::date = p_as_of);
  end if;
  return jsonb_build_object('stale', jsonb_array_length(v));
end;
$$;
revoke all on function payments_stale_pending(date) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- F. Reversals (never delete: an offsetting line)
alter table payment_reports drop constraint if exists payment_reports_status_check;
alter table payment_reports add constraint payment_reports_status_check check (status in ('pending', 'verified', 'rejected', 'reversed'));
alter table payment_reports add column if not exists reversed_amount numeric(12,2) not null default 0;
alter table payment_reports add column if not exists reversed_at timestamptz;
alter table payment_reports add column if not exists reversed_reason text;
alter table payment_reports add column if not exists reversed_by text;
alter table stripe_payments drop constraint if exists stripe_payments_status_check;
alter table stripe_payments add constraint stripe_payments_status_check check (status in ('created', 'processing', 'succeeded', 'failed', 'canceled', 'reversed', 'disputed'));
alter table stripe_payments add column if not exists refunded_amount numeric(12,2) not null default 0;

create or replace function lease_payment_reverse(p_report uuid, p_amount numeric, p_reason text, p_by text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r payment_reports; v_amt numeric; v_entry bigint; v_orig bigint;
begin
  select * into r from payment_reports where id = p_report for update;
  if r.id is null then raise exception 'Payment not found'; end if;
  if r.status not in ('verified', 'reversed') then raise exception 'Only a posted payment can be reversed.'; end if;
  if length(coalesce(trim(p_reason), '')) < 3 then raise exception 'Say why the payment is reversed (bounced, refunded, disputed…).'; end if;
  v_amt := round(coalesce(p_amount, r.amount - r.reversed_amount), 2);
  if v_amt <= 0 or v_amt > r.amount - r.reversed_amount then raise exception 'Up to % can still be reversed.', to_char(r.amount - r.reversed_amount, 'FM$999,990.00'); end if;
  if r.condo_account_id is not null then
    select id into v_orig from condo_ledger_entries where payment_report_id = r.id and kind = 'payment' order by id limit 1;
    insert into condo_ledger_entries (account_id, gl_account, entry_date, kind, raw_type, method, description, amount, origin, entered_by, correction_note, reverses_entry_id, payment_report_id)
    values (r.condo_account_id, 'Association Fee Income', current_date, 'reversal', 'Payment reversed', r.method,
            'Payment reversed: ' || trim(p_reason), v_amt, 'staff', p_by, 'Reverses the ' || to_char(r.paid_on, 'FMMM/FMDD/YYYY') || ' payment; original line kept.', v_orig, r.id)
    returning id into v_entry;
  elsif r.lease_id is not null then
    insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, method, description, amount, source, correction_note)
    values (r.lease_id, 'Rent Income', current_date, 'reversal', 'Payment reversed', r.method, 'Payment reversed: ' || trim(p_reason), v_amt, 'payment_reversal',
            'Reverses the ' || to_char(r.paid_on, 'FMMM/FMDD/YYYY') || ' payment (ledger line ' || coalesce(r.ledger_entry_id::text, '?') || '); original line kept. By ' || coalesce(p_by, 'system') || '.')
    returning id into v_entry;
  elsif r.land_contract_id is not null then
    insert into land_contract_ledger (contract_id, entry_date, kind, raw_type, description, amount, source, correction_note)
    values (r.land_contract_id, current_date, 'reversal', 'Payment reversed', 'Payment reversed: ' || trim(p_reason), v_amt, 'payment_reversal',
            'Reverses the ' || to_char(r.paid_on, 'FMMM/FMDD/YYYY') || ' payment; original line kept.')
    returning id into v_entry;
  end if;
  update payment_reports set reversed_amount = reversed_amount + v_amt, reversed_at = now(), reversed_reason = trim(p_reason), reversed_by = p_by,
         status = case when reversed_amount + v_amt >= amount then 'reversed' else status end
   where id = r.id;
  return jsonb_build_object('reversed', v_amt, 'entry', v_entry);
end;
$$;
revoke all on function lease_payment_reverse(uuid, numeric, text, text) from public, anon, authenticated;

create or replace function payments_staff_reverse(p_report uuid, p_amount numeric, p_reason text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v jsonb; r payment_reports; v_to text; v_name text;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  v := lease_payment_reverse(p_report, p_amount, p_reason, lower(auth.email()));
  select * into r from payment_reports where id = p_report;
  select coalesce(t.email, o.email), coalesce(t.name, o.name) into v_to, v_name
    from payment_reports x left join tenants t on t.id = x.tenant_id left join condo_owners o on o.id = x.owner_id where x.id = p_report;
  if v_to is not null then
    insert into email_outbox (to_email, subject, html, kind) values (v_to, 'A payment was reversed',
      '<p>Hi ' || repair_esc(split_part(coalesce(v_name, ''), ' ', 1)) || ',</p><p>Your payment of ' || to_char(r.amount, 'FM$999,990.00') || ' made '
      || to_char(r.paid_on, 'FMMM/FMDD/YYYY') || ' was reversed (' || repair_esc(p_reason) || '), so ' || to_char((v->>'reversed')::numeric, 'FM$999,990.00')
      || ' is back on your account. Please pay again or call the office' || coalesce(' at ' || (select value from portal_settings where key = 'org_phone'), '') || '.</p>', 'payment_reversed');
  end if;
  return v;
end;
$$;
revoke all on function payments_staff_reverse(uuid, numeric, text) from public, anon;
grant execute on function payments_staff_reverse(uuid, numeric, text) to authenticated;

-- Stripe: refunds, lost disputes and failures after success reverse the posted payment.
create or replace function stripe_payment_reverse(p_intent text, p_amount numeric, p_reason text)
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
  update stripe_payments set status = 'reversed', failure_message = p_reason, updated_at = now() where id = s.id;
  return v;
end;
$$;
revoke all on function stripe_payment_reverse(text, numeric, text) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- D. Owner pay options: no 2nd Chance Stripe / shared PayPal for owners unless switched on.
create or replace function condo_owner_pay_options()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not condo_session_ok() then raise exception 'Sign-in required' using errcode = '42501'; end if;
  v := coalesce((select jsonb_object_agg(key, value) from portal_settings where key like 'owner_pay_%' and value <> ''), '{}'::jsonb);
  if coalesce(v->>'owner_pay_paypal', 'off') <> 'on' then v := v - 'owner_pay_paypal_client_id' - 'owner_pay_paypal_hosted_id' - 'owner_pay_paypal_link'; end if;
  return v || jsonb_build_object('stripe_enabled', coalesce((select value from portal_settings where key = 'stripe_enabled'), 'off'));
end;
$$;
revoke all on function condo_owner_pay_options() from public, anon;
grant execute on function condo_owner_pay_options() to authenticated;

-- ---------------------------------------------------------------------------
-- H. resident_home: the tenant's own monthly portion.
do $$
declare v text := pg_get_functiondef('resident_home()'::regprocedure); v_old text := '''rent'', l.rent,';
begin
  if position('tenant_rent' in v) = 0 then
    if position(v_old in v) = 0 then raise exception 'resident_home changed shape; update this patch'; end if;
    v := replace(v, v_old, v_old || ' ''tenant_rent'', lease_tenant_rent(l.id),');
    execute v;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- K. Money-revealing definer functions: server-side only.
revoke all on function lease_rent_due(uuid, date) from public, anon, authenticated;
revoke all on function notice_prior_within_year(uuid, text, date) from public, anon, authenticated;
revoke all on function lease_keys_ready_check() from public, anon, authenticated;
revoke all on function inspection_rental_unit(text, text) from public, anon;
