-- Land contract buyers (e.g. 3446 N 12th St) can open their own contract, the full
-- amortization schedule, interest by calendar year, and their documents, from the
-- resident portal. Buyers are the tenants linked in land_contract_buyers, so the
-- same emailed-code sign-in applies. Nobody else can read these rows.

-- Account numbers the buyers need on the city's payment sites (they paste them in; the
-- city sites have no direct link to an account). Tax key is from the 2025 tax bill.
alter table land_contracts add column if not exists tax_key text;
alter table land_contracts add column if not exists water_account text;
update land_contracts set tax_key = '2830207000' where id = '65c45d34-6fa4-5fb0-8beb-a76a2b45cb54' and tax_key is null;

create table if not exists land_contract_documents (
  id uuid primary key default gen_random_uuid(),
  contract_id uuid not null references land_contracts(id) on delete cascade,
  kind text not null check (kind in ('contract', 'amortization', 'interest_statement', 'tax_bill', 'other')),
  title text not null,
  tax_year int,
  dated date,
  storage_path text not null unique,
  created_at timestamptz not null default now()
);
create index if not exists land_contract_documents_idx on land_contract_documents (contract_id, kind, tax_year);
alter table land_contract_documents enable row level security;   -- no policies: read through resident_land_contracts()

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('land-contract-docs', 'land-contract-docs', false, 26214400,
        array['application/pdf', 'image/jpeg', 'image/png', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- Read: office staff, or a buyer on the contract the document belongs to.
-- Uploads happen only with the service key (tools/upload_land_contract_docs.py).
drop policy if exists "land contract docs read" on storage.objects;
create policy "land contract docs read" on storage.objects
  for select to authenticated
  using (bucket_id = 'land-contract-docs' and (
    condo_is_staff()
    or exists (
      select 1 from land_contract_documents d
      join land_contract_buyers b on b.contract_id = d.contract_id
      where d.storage_path = name and b.tenant_id in (select resident_me()))));

-- Interest exactly as the land contract states it (State Bar Form 11-2003, signed 3/2/2020):
-- "together with interest from the date hereof on the balance outstanding from time to
-- time at the rate of 10.25% per annum ... Payments shall be applied first to interest on
-- the unpaid balance at the rate specified and then to principal." So: start from the
-- balance after the down payment on the contract date, accrue interest daily (days/365)
-- on what is actually owed, and apply each real payment to accrued interest first.
-- "Interest paid" for a year is the interest part of payments received that year.
-- Payments are the 'Rent Income' payments in land_contract_ledger (late-fee payments are not loan payments).
create or replace function land_contract_interest(p_contract uuid, p_as_of date default current_date)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  c land_contracts;
  bal numeric; unpaid numeric := 0; last date;
  r record; i numeric; amt numeric;
  ints jsonb := '{}'::jsonb; prins jsonb := '{}'::jsonb; y text;
  y0 int; y1 int; yrs jsonb;
begin
  select * into c from land_contracts where id = p_contract;
  if not found or c.contract_date is null or c.interest_rate is null then return null; end if;
  bal := coalesce(c.purchase_price, 0) - coalesce(c.down_payment, 0);
  last := c.contract_date;
  for r in select entry_date, -amount as amt from land_contract_ledger
           where contract_id = p_contract and kind = 'payment' and legacy_gl = 'Rent Income'
             and entry_date >= c.contract_date and entry_date <= p_as_of
           order by entry_date, id loop
    amt := r.amt;
    if amt <= 0 then continue; end if;
    unpaid := unpaid + bal * c.interest_rate * (r.entry_date - last) / 365;
    last := r.entry_date;
    i := least(unpaid, amt);
    unpaid := unpaid - i;
    bal := bal - (amt - i);
    y := extract(year from r.entry_date)::int::text;
    ints := jsonb_set(ints, array[y], to_jsonb(coalesce((ints ->> y)::numeric, 0) + i));
    prins := jsonb_set(prins, array[y], to_jsonb(coalesce((prins ->> y)::numeric, 0) + (amt - i)));
  end loop;
  unpaid := unpaid + bal * c.interest_rate * (p_as_of - last) / 365;
  y0 := extract(year from c.contract_date)::int; y1 := extract(year from p_as_of)::int;
  select coalesce(jsonb_agg(jsonb_build_object('year', g, 'interest', round(coalesce((ints ->> g::text)::numeric, 0), 2),
      'principal', round(coalesce((prins ->> g::text)::numeric, 0), 2),
      'paid', round(coalesce((ints ->> g::text)::numeric, 0) + coalesce((prins ->> g::text)::numeric, 0), 2),
      'complete', g < y1) order by g), '[]'::jsonb)
    into yrs from generate_series(y0, y1) g;
  return jsonb_build_object('years', yrs, 'principal_balance', round(bal, 2), 'accrued_interest', round(unpaid, 2), 'as_of', p_as_of);
end;
$$;
revoke all on function land_contract_interest(uuid, date) from public, anon, authenticated;

create or replace function resident_land_contracts()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if auth.uid() is null then raise exception 'Sign-in required' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', c.id, 'street', p.street, 'buyers', c.buyers_label, 'seller', c.seller,
      'contract_date', c.contract_date, 'purchase_price', c.purchase_price, 'down_payment', c.down_payment,
      'interest_rate', c.interest_rate, 'term_months', c.term_months, 'monthly_payment', c.monthly_payment,
      'maturity_date', c.maturity_date, 'tax_key', c.tax_key, 'water_account', c.water_account,
      'principal_now', (land_contract_interest(c.id) ->> 'principal_balance')::numeric,
      'accrued_interest', (land_contract_interest(c.id) ->> 'accrued_interest')::numeric,
      'scheduled_principal_now', (select s.ending_balance from land_contract_schedule s where s.contract_id = c.id and s.due_date <= current_date order by s.n desc limit 1),
      'schedule', coalesce((select jsonb_agg(jsonb_build_object('n', s.n, 'due', s.due_date, 'begin', s.beginning_balance,
          'payment', s.scheduled_payment, 'extra', s.extra_payment, 'principal', s.principal, 'interest', s.interest, 'end', s.ending_balance) order by s.n)
        from land_contract_schedule s where s.contract_id = c.id), '[]'::jsonb),
      'years', coalesce(land_contract_interest(c.id) -> 'years', '[]'::jsonb),
      'documents', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind, 'title', d.title, 'tax_year', d.tax_year,
          'dated', d.dated, 'path', d.storage_path) order by d.kind, d.tax_year desc nulls last, d.dated desc nulls last)
        from land_contract_documents d where d.contract_id = c.id), '[]'::jsonb)))
    from land_contracts c join rental_properties p on p.id = c.property_id
    where c.status = 'active' and exists (select 1 from land_contract_buyers b where b.contract_id = c.id and b.tenant_id in (select resident_me()))), '[]'::jsonb);
end;
$$;
revoke all on function resident_land_contracts() from public, anon;
grant execute on function resident_land_contracts() to authenticated;
