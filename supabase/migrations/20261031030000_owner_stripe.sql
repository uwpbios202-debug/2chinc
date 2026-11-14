-- Owners can pay association dues by Stripe (bank account or card), the same
-- way tenants pay rent. We never see bank or card numbers; Stripe Checkout
-- collects them and the signed stripe-webhook posts the payment to the
-- association ledger once Stripe confirms it. Dues are ROCA1's money: each
-- Stripe payment is tagged association = ROCA1 in Stripe's metadata.

create table if not exists stripe_owner_customers (
  owner_id uuid primary key references condo_owners(id),
  customer_id text not null unique,
  updated_at timestamptz not null default now()
);
alter table stripe_owner_customers enable row level security;

alter table stripe_payments add column if not exists owner_id uuid references condo_owners(id);
alter table stripe_payments add column if not exists condo_account_id uuid references condo_ledger_accounts(id);

-- What stripe-pay needs about the signed-in owner and one of their units.
create or replace function condo_pay_target(p_unit text)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare v_owner uuid := condo_owner_for_email(auth.email()); v_unit uuid; v_bal numeric; v_dues numeric;
begin
  if not condo_session_ok() or v_owner is null then raise exception 'Sign in as an owner first.' using errcode = '42501'; end if;
  select s.unit_id, coalesce(s.fee, condo_setting('dues_default', '215')::numeric) into v_unit, v_dues
    from condo_ownerships s join condo_units u on u.id = s.unit_id
   where s.owner_id = v_owner and s.is_current and u.unit_number = p_unit;
  if v_unit is null then raise exception 'Choose one of your units.'; end if;
  select coalesce(sum(e.amount), 0) into v_bal from condo_ledger_entries e join condo_ledger_accounts a on a.id = e.account_id
   join condo_ownerships s on s.id = a.ownership_id where s.unit_id = v_unit and s.owner_id = v_owner and s.is_current and not a.excluded;
  return jsonb_build_object('owner_id', v_owner, 'name', (select name from condo_owners where id = v_owner), 'email', auth.email(),
    'unit_number', p_unit, 'account_id', condo_billing_account(v_unit), 'balance', v_bal, 'dues', v_dues);
end;
$$;
revoke all on function condo_pay_target(text) from public, anon;
grant execute on function condo_pay_target(text) to authenticated;

-- Stripe confirmed a payment: post it once, to the tenant's or the owner's ledger.
create or replace function stripe_payment_succeeded(p_intent text, p_method_type text)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare s stripe_payments; v_report uuid;
begin
  select * into s from stripe_payments where payment_intent = p_intent for update;
  if s.id is null then return jsonb_build_object('error', 'unknown payment intent'); end if;
  if s.status = 'succeeded' then return jsonb_build_object('ok', true, 'already', true); end if;
  insert into payment_reports (tenant_id, owner_id, condo_account_id, lease_id, land_contract_id, method, amount, paid_on, confirmation_code, note)
  values (s.tenant_id, s.owner_id, s.condo_account_id, s.lease_id, s.land_contract_id,
          case when coalesce(p_method_type, s.method_type) = 'card' then 'stripe_card' else 'stripe_bank' end,
          s.amount, current_date, p_intent, case when s.owner_id is not null then 'Association dues paid online' when s.origin = 'autopay' then 'Autopay' else 'Paid online' end)
  returning id into v_report;
  perform payment_post(v_report, null, 'stripe', 'Stripe');
  update stripe_payments set status = 'succeeded', method_type = coalesce(p_method_type, method_type), payment_report_id = v_report, updated_at = now() where id = s.id;
  return jsonb_build_object('ok', true, 'report', v_report);
end;
$$;
revoke all on function stripe_payment_succeeded(text, text) from public, anon, authenticated;
grant execute on function stripe_payment_succeeded(text, text) to service_role;

-- Recent online payments for the owner's page.
create or replace function condo_my_stripe_payments()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v_owner uuid := condo_owner_for_email(auth.email());
begin
  if not condo_session_ok() or v_owner is null then raise exception 'Sign in as an owner first.' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('amount', p.amount, 'status', p.status, 'method', p.method_type, 'created_at', p.created_at, 'failure', p.failure_message,
      'unit_number', (select u.unit_number from condo_ledger_accounts a join condo_units u on u.id = a.unit_id where a.id = p.condo_account_id)) order by p.created_at desc)
    from (select * from stripe_payments where owner_id = v_owner order by created_at desc limit 10) p), '[]'::jsonb);
end;
$$;
revoke all on function condo_my_stripe_payments() from public, anon;
grant execute on function condo_my_stripe_payments() to authenticated;

-- Optional "Bank transfer" instructions shown to owners and tenants when set.
insert into portal_settings (key, value) values ('owner_pay_bank_transfer', ''), ('pay_bank_transfer', '') on conflict (key) do nothing;
