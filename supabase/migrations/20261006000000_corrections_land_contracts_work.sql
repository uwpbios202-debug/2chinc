-- Corrections log, land contracts, and work-in-lieu-of-rent.
--
-- Corrections: when an earlier record was wrong, we fix it in our records
-- and log what was there, what changed, who decided and why. The raw
-- original export stays untouched in incoming/ as the original evidence.
--
-- Land contracts: a buyer paying toward ownership (e.g. 3446 N. 12th St.) is
-- not a tenancy. It was recorded as a lease with "rent"; here it gets
-- its own contract terms and payment ledger (principal/interest split once
-- the contract terms are entered).
--
-- Work in lieu of rent: a tenant's agreed labor is credited to their lease
-- ledger as an in-kind payment, and each credit links back to a work log
-- entry describing the work.

create table if not exists ledger_corrections (
  id bigint generated always as identity primary key,
  decided_on date not null,
  decided_by text not null,
  subject text not null,              -- e.g. 'Andrew Cannon — Unit 12 lease entered in error'
  action text not null,               -- e.g. 'merge_lease', 'reclassify_in_kind', 'land_contract'
  reason text not null,
  legacy_detail jsonb not null default '{}'::jsonb,   -- what was there (lines removed/moved, labels)
  created_at timestamptz not null default now()
);

alter table leases add column if not exists correction_note text;
alter table lease_ledger_entries add column if not exists correction_note text;

-- ---------------------------------------------------------------------------
-- Land contracts
-- ---------------------------------------------------------------------------
create table if not exists land_contracts (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references rental_properties(id),
  buyers_label text not null,
  seller text,
  contract_date date,
  purchase_price numeric(12,2),
  down_payment numeric(12,2),
  interest_rate numeric(6,4),         -- annual, e.g. 0.0650
  term_months int,
  monthly_payment numeric(12,2),
  first_payment_date date,
  balloon_date date,
  terms_confirmed boolean not null default false,   -- false until entered from the signed contract
  status text not null default 'active' check (status in ('active', 'paid_off', 'forfeited', 'cancelled')),
  notes text,
  legacy_balance numeric(12,2)
);

create table if not exists land_contract_buyers (
  contract_id uuid not null references land_contracts(id) on delete cascade,
  tenant_id uuid not null references tenants(id),
  primary key (contract_id, tenant_id)
);

create table if not exists land_contract_ledger (
  id bigint generated always as identity primary key,
  contract_id uuid not null references land_contracts(id),
  entry_date date not null,
  kind text not null,                 -- installment_due | payment | late_fee | credit | deposit | other
  legacy_gl text,                   -- how it was recorded ("Rent Income", ...)
  raw_type text,
  description text,
  amount numeric(12,2) not null,
  principal numeric(12,2),            -- filled once terms_confirmed
  interest numeric(12,2),
  source text not null,
  source_row int,
  correction_note text
);
create index if not exists land_contract_ledger_idx on land_contract_ledger (contract_id, entry_date, id);

-- ---------------------------------------------------------------------------
-- Work in lieu of rent
-- ---------------------------------------------------------------------------
create table if not exists work_agreements (
  id uuid primary key default gen_random_uuid(),
  lease_id uuid not null references leases(id),
  title text not null,
  scope text not null,
  monthly_credit numeric(12,2),        -- fixed monthly in-kind credit, if any
  start_date date,
  end_date date,
  equipment_terms text,
  status text not null default 'draft' check (status in ('draft', 'active', 'ended')),
  signed_on date,
  notes text,
  created_at timestamptz not null default now()
);

create table if not exists work_logs (
  id bigint generated always as identity primary key,
  lease_id uuid not null references leases(id),
  agreement_id uuid references work_agreements(id),
  work_date date not null,
  description text not null,
  hours numeric(6,2),
  value numeric(12,2) not null,        -- dollars credited to rent
  verified_by text,
  ledger_entry_id bigint references lease_ledger_entries(id),
  created_at timestamptz not null default now()
);

alter table ledger_corrections enable row level security;
alter table land_contracts enable row level security;
alter table land_contract_buyers enable row level security;
alter table land_contract_ledger enable row level security;
alter table work_agreements enable row level security;
alter table work_logs enable row level security;

-- ---------------------------------------------------------------------------
-- Staff functions
-- ---------------------------------------------------------------------------
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
      'first_entry', (select min(entry_date) from land_contract_ledger where contract_id = c.id)))
    from land_contracts c join rental_properties p on p.id = c.property_id), '[]'::jsonb);
end;
$$;

create or replace function land_contracts_staff_ledger(p_contract_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('date', entry_date, 'kind', kind, 'gl', legacy_gl, 'type', raw_type,
      'description', description, 'amount', amount, 'principal', principal, 'interest', interest) order by entry_date, id)
    from land_contract_ledger where contract_id = p_contract_id), '[]'::jsonb);
end;
$$;

create or replace function rentals_staff_work(p_lease_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'agreements', coalesce((select jsonb_agg(to_jsonb(a) order by a.created_at) from work_agreements a where a.lease_id = p_lease_id), '[]'::jsonb),
    'logs', coalesce((select jsonb_agg(to_jsonb(w) order by w.work_date, w.id) from work_logs w where w.lease_id = p_lease_id), '[]'::jsonb));
end;
$$;

create or replace function staff_corrections()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(to_jsonb(c) order by c.decided_on desc, c.id desc) from ledger_corrections c), '[]'::jsonb);
end;
$$;

revoke all on function land_contracts_staff_overview() from public, anon;
revoke all on function land_contracts_staff_ledger(uuid) from public, anon;
revoke all on function rentals_staff_work(uuid) from public, anon;
revoke all on function staff_corrections() from public, anon;
grant execute on function land_contracts_staff_overview() to authenticated;
grant execute on function land_contracts_staff_ledger(uuid) to authenticated;
grant execute on function rentals_staff_work(uuid) to authenticated;
grant execute on function staff_corrections() to authenticated;

-- ---------------------------------------------------------------------------
-- Who manages each unit's rental. Owner-managed units (e.g. Unit 6) keep
-- their rental records outside this system; they show as such, not as
-- "missing a lease".
-- ---------------------------------------------------------------------------
alter table rental_units add column if not exists managed_by text not null default '2nd_chance'
  check (managed_by in ('2nd_chance', 'owner'));
alter table rental_units add column if not exists management_note text;

create or replace function rentals_staff_overview()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'units', coalesce((select jsonb_agg(jsonb_build_object(
        'id', u.id, 'property', p.name, 'property_key', p.key, 'unit_number', u.unit_number, 'address', u.address,
        'managed_by', u.managed_by, 'management_note', u.management_note,
        'condo_occupancy', cu.occupancy, 'bedrooms', cu.bedrooms, 'bathrooms', cu.bathrooms, 'size_sqft', cu.size_sqft,
        'leases', coalesce((select jsonb_agg(jsonb_build_object(
            'id', l.id, 'status', l.status, 'lease_type', l.lease_type, 'start_date', l.start_date, 'end_date', l.end_date,
            'rent', l.rent, 'tenants_label', l.tenants_label, 'balance', b.balance, 'legacy_balance', l.legacy_balance,
            'entries', b.entries, 'correction_note', l.correction_note,
            'work_agreements', (select count(*) from work_agreements w where w.lease_id = l.id),
            'tenants', (select jsonb_agg(jsonb_build_object('name', t.name, 'email', t.email, 'phone', t.phone) order by t.name)
                        from lease_tenants lt join tenants t on t.id = lt.tenant_id where lt.lease_id = l.id))
            order by l.start_date desc nulls last)
          from leases l join lease_balances b on b.lease_id = l.id where l.unit_id = u.id), '[]'::jsonb))
        order by p.key <> 'roca1', p.name, nullif(regexp_replace(coalesce(u.unit_number, ''), '\D', '', 'g'), '')::int nulls last)
      from rental_units u join rental_properties p on p.id = u.property_id
      left join condo_units cu on cu.id = u.condo_unit_id), '[]'::jsonb)
  );
end;
$$;

-- Ledger lines with their correction notes.
create or replace function rentals_staff_ledger(p_lease_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'date', e.entry_date, 'gl', e.gl_account, 'kind', e.kind, 'type', e.raw_type, 'description', e.description,
      'amount', e.amount, 'legacy_running', e.legacy_running_balance, 'note', e.correction_note)
      order by e.entry_date, e.id)
    from lease_ledger_entries e where e.lease_id = p_lease_id), '[]'::jsonb);
end;
$$;
