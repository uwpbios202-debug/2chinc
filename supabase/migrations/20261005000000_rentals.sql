-- Rentals: properties, units, tenants, leases and the full lease ledger.
--
-- Rules carried over from the association side:
--   * A unit is a permanent record; leases attach to it with dates.
--   * History is everything: every earlier lease-ledger line is imported
--     (the lease ledger importer proves each section and lease total
--     matches the original before rentals_sql.py writes the load file).
--   * The original labels are kept next to our interpretation, so any mapping
--     (e.g. "# Fourteen" -> unit 14) can be audited.
-- Access: RLS on, no anon/authenticated policies; staff read through
-- rentals_staff_* functions after the two-step sign-in.

create table if not exists rental_properties (
  id uuid primary key default gen_random_uuid(),
  key text not null unique,                 -- 'roca1', '3446-n-12th'
  name text not null,
  street text,
  city text,
  state text,
  zip text,
  notes text
);

create table if not exists rental_units (
  id uuid primary key default gen_random_uuid(),
  property_id uuid not null references rental_properties(id),
  unit_number text,                         -- null for a single-family home
  condo_unit_id uuid references condo_units(id),
  address text,
  unique (property_id, unit_number)
);

create table if not exists tenants (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  email text,
  phone text,
  notes text,
  created_at timestamptz not null default now()
);
create unique index if not exists tenants_name_email_idx on tenants (lower(name), coalesce(lower(email), ''));

create table if not exists leases (
  id uuid primary key default gen_random_uuid(),
  unit_id uuid not null references rental_units(id),
  legacy_rental text not null,            -- the rental name, as printed
  tenants_label text not null,              -- the tenant list, as printed
  start_date date,
  end_date date,                            -- null = at-will with no end (the original shows 1/1/2060)
  lease_type text check (lease_type in ('fixed', 'at_will')),
  status text check (status in ('active', 'past', 'future')),
  rent numeric(12,2),
  rent_start date,
  legacy_balance numeric(12,2),
  imported_at timestamptz not null default now()
);
create index if not exists leases_unit_idx on leases (unit_id, start_date);

create table if not exists lease_tenants (
  lease_id uuid not null references leases(id) on delete cascade,
  tenant_id uuid not null references tenants(id),
  primary key (lease_id, tenant_id)
);

create table if not exists lease_ledger_entries (
  id bigint generated always as identity primary key,
  lease_id uuid not null references leases(id),
  gl_account text not null,
  entry_date date not null,
  kind text not null,                       -- charge | payment | credit | refund | reversal | other
  raw_type text not null,
  method text,
  check_number text,
  description text,
  amount numeric(12,2) not null,
  legacy_running_balance numeric(12,2),
  source text not null,                     -- export file it came from
  source_row int
);
create index if not exists lease_ledger_lease_idx on lease_ledger_entries (lease_id, entry_date, id);

create or replace view lease_balances with (security_invoker = true) as
  select l.id as lease_id, coalesce(sum(e.amount), 0)::numeric(12,2) as balance,
         l.legacy_balance, count(e.id) as entries, min(e.entry_date) as first_entry, max(e.entry_date) as last_entry
  from leases l left join lease_ledger_entries e on e.lease_id = l.id
  group by l.id;

alter table rental_properties enable row level security;
alter table rental_units enable row level security;
alter table tenants enable row level security;
alter table leases enable row level security;
alter table lease_tenants enable row level security;
alter table lease_ledger_entries enable row level security;
revoke all on lease_balances from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Staff functions (two-step staff sign-in required)
-- ---------------------------------------------------------------------------
create or replace function rentals_staff_overview()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'units', coalesce((select jsonb_agg(jsonb_build_object(
        'id', u.id, 'property', p.name, 'property_key', p.key, 'unit_number', u.unit_number, 'address', u.address,
        'condo_occupancy', cu.occupancy, 'bedrooms', cu.bedrooms, 'bathrooms', cu.bathrooms, 'size_sqft', cu.size_sqft,
        'leases', coalesce((select jsonb_agg(jsonb_build_object(
            'id', l.id, 'status', l.status, 'lease_type', l.lease_type, 'start_date', l.start_date, 'end_date', l.end_date,
            'rent', l.rent, 'tenants_label', l.tenants_label, 'balance', b.balance, 'legacy_balance', l.legacy_balance,
            'entries', b.entries,
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

create or replace function rentals_staff_ledger(p_lease_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'date', e.entry_date, 'gl', e.gl_account, 'kind', e.kind, 'type', e.raw_type, 'description', e.description,
      'amount', e.amount, 'legacy_running', e.legacy_running_balance)
      order by e.entry_date, e.id)
    from lease_ledger_entries e where e.lease_id = p_lease_id), '[]'::jsonb);
end;
$$;

revoke all on function rentals_staff_overview() from public, anon;
revoke all on function rentals_staff_ledger(uuid) from public, anon;
grant execute on function rentals_staff_overview() to authenticated;
grant execute on function rentals_staff_ledger(uuid) to authenticated;
