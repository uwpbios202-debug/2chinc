-- Stripe payouts by bank account (Stephen, 10/16/2026). There are three Stripe accounts, each paying out to one bank:
--   main (2nd Chance Housing Inc) -> 2nd Chance Chase ****7620   (units 2, 3, 8, 11, 12)
--   yawdcour                      -> Yawdcour Chase ****3802     (units 4, 5, 14)
--   roca1                         -> ROCA1 First Citizens ****9032 (association dues; unit 16's rent)
-- Until now a payout was recognised only in a tenant-kind account, so a ROCA1 payout landing at First Citizens fell through
-- to the payer matcher (the money was already posted from Stripe's webhook, so posting it again would count it twice).
-- Now each payout records which Stripe account sent it and is matched only against deposits in that account's bank, in
-- any account kind. A Stripe deposit with no payout record yet waits for review instead of being matched to a payer.
alter table stripe_payouts add column if not exists stripe_account text;

-- The Stripe account that pays out into a bank account (2nd Chance Chase is the main account's bank).
create or replace function bank_account_stripe(p_bank uuid)
returns text language sql stable security definer set search_path = public as $$
  select coalesce(stripe_account, case when bank_key = 'chase_2ch' then 'main' end) from bank_accounts where id = p_bank;
$$;
revoke all on function bank_account_stripe(uuid) from public, anon, authenticated;

create or replace function stripe_payout_record(p_id text, p_amount numeric, p_arrival date, p_status text, p_description text, p_account text)
returns void
language sql volatile security definer set search_path = public as $$
  insert into stripe_payouts (id, amount, arrival_date, status, description, stripe_account) values (p_id, p_amount, p_arrival, p_status, p_description, nullif(p_account, ''))
  on conflict (id) do update set amount = excluded.amount, arrival_date = excluded.arrival_date, status = excluded.status,
    stripe_account = coalesce(excluded.stripe_account, stripe_payouts.stripe_account), updated_at = now();
$$;
revoke all on function stripe_payout_record(text, numeric, date, text, text, text) from public, anon, authenticated;
grant execute on function stripe_payout_record(text, numeric, date, text, text, text) to service_role;
-- The old five-argument call (the webhook before this change) still works; the account stays unknown.
create or replace function stripe_payout_record(p_id text, p_amount numeric, p_arrival date, p_status text, p_description text)
returns void language sql volatile security definer set search_path = public as $$
  select stripe_payout_record(p_id, p_amount, p_arrival, p_status, p_description, null);
$$;
revoke all on function stripe_payout_record(text, numeric, date, text, text) from public, anon, authenticated;
grant execute on function stripe_payout_record(text, numeric, date, text, text) to service_role;

create or replace function bank_autopilot()
returns jsonb
language plpgsql security definer set search_path = public as $$
declare r record; c record; n_top int; v_posted int := 0; v_review int := 0; v_ignored int := 0; v_payouts int := 0; v_matched int; v_reason text;
  v_bal numeric; v_cap numeric; v_po text; v_dup uuid;
begin
  -- Stripe payouts landing in any of the three banks: not a payment (the payments already posted from Stripe's webhook).
  -- A payout matches only in the bank its Stripe account pays out to (an older payout with no account recorded matches any).
  for r in select b.* from bank_receipts b
           where b.status in ('new', 'needs_review') and b.matched_report_id is null and b.amount > 0
             and coalesce(b.description, '') || ' ' || coalesce(b.payer_name, '') ~* 'stripe' loop
    select p.id into v_po from stripe_payouts p where p.status = 'paid' and p.bank_receipt_id is null and p.amount = r.amount
      and abs(p.arrival_date - r.posted_on) <= 3 and (p.stripe_account is null or p.stripe_account = bank_account_stripe(r.bank_account_id))
      order by abs(p.arrival_date - r.posted_on), (p.stripe_account is null) limit 1;
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
    -- A Stripe deposit is a payout, never a resident's payment: it waits for Stripe's payout record instead of a payer match.
    if coalesce(r.description, '') || ' ' || coalesce(r.payer_name, '') ~* 'stripe' then
      update bank_receipts set status = 'needs_review', review_reason = 'Stripe payout: waiting for Stripe''s payout record (do not post it to a resident)', confidence = null where id = r.id;
      v_review := v_review + 1;
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
