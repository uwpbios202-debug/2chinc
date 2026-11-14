-- Land contract terms from the signed contract, and the amortization
-- schedule (Exhibit A) the interest statements are produced from.

alter table land_contracts add column if not exists vendor_payment_address text;
alter table land_contracts add column if not exists recorded_document text;
alter table land_contracts add column if not exists recorded_on date;
alter table land_contracts add column if not exists parcel_pin text;
alter table land_contracts add column if not exists possession_date date;
alter table land_contracts add column if not exists maturity_date date;
alter table land_contracts add column if not exists grace_days int;
alter table land_contracts add column if not exists default_interest_rate numeric(6,4);
alter table land_contracts add column if not exists prepayment_terms text;
alter table land_contracts add column if not exists taxes_insurance text;
alter table land_contracts add column if not exists source_documents text;

create table if not exists land_contract_schedule (
  contract_id uuid not null references land_contracts(id) on delete cascade,
  n int not null,
  due_date date not null,
  beginning_balance numeric(12,2) not null,
  scheduled_payment numeric(12,2) not null,
  extra_payment numeric(12,2) not null default 0,
  principal numeric(12,2) not null,
  interest numeric(12,2) not null,
  ending_balance numeric(12,2) not null,
  primary key (contract_id, n)
);
alter table land_contract_schedule enable row level security;

create or replace function land_contracts_staff_overview()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(to_jsonb(c) || jsonb_build_object(
      'property', p.name, 'street', p.street,
      'buyers', (select jsonb_agg(jsonb_build_object('name', t.name, 'email', t.email, 'phone', t.phone) order by t.name)
                 from land_contract_buyers b join tenants t on t.id = b.tenant_id where b.contract_id = c.id),
      'paid_total', (select -coalesce(sum(amount), 0) from land_contract_ledger where contract_id = c.id and kind = 'payment'),
      'balance', (select coalesce(sum(amount), 0) from land_contract_ledger where contract_id = c.id),
      'entries', (select count(*) from land_contract_ledger where contract_id = c.id),
      'first_entry', (select min(entry_date) from land_contract_ledger where contract_id = c.id),
      'schedule_count', (select count(*) from land_contract_schedule s where s.contract_id = c.id),
      'principal_now', (select s.ending_balance from land_contract_schedule s where s.contract_id = c.id and s.due_date <= current_date order by s.n desc limit 1),
      'installments_due', (select count(*) from land_contract_schedule s where s.contract_id = c.id and s.due_date <= current_date),
      'interest_by_year', (select jsonb_object_agg(y, i) from (select extract(year from due_date)::int y, sum(interest) i
                           from land_contract_schedule s where s.contract_id = c.id and s.due_date <= current_date group by 1) z)))
    from land_contracts c join rental_properties p on p.id = c.property_id), '[]'::jsonb);
end;
$$;

create or replace function land_contracts_staff_schedule(p_contract_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(to_jsonb(s) - 'contract_id' order by s.n) from land_contract_schedule s where s.contract_id = p_contract_id), '[]'::jsonb);
end;
$$;
revoke all on function land_contracts_staff_schedule(uuid) from public, anon;
grant execute on function land_contracts_staff_schedule(uuid) to authenticated;
