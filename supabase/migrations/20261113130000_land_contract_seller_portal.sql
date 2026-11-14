-- Land contract SELLER portal (Stephen, 10/18/2026). The seller of a land contract (for 3446 N 12th St: MH Star LLC) signs in with an
-- emailed code and sees a READ-ONLY page: the contract's terms, balance, next payment, the schedule, the payments received and the
-- contract documents. Nothing on it moves money. Who may sign in lives in land_contract_sellers; the people are added in a
-- separate local-only migration (real emails are never committed).
-- Buyers' payments still land in 2nd Chance's account (Stephen's choice); this page shows what has been collected.

create table if not exists land_contract_sellers (
  id uuid primary key default gen_random_uuid(),
  contract_id uuid not null references land_contracts(id) on delete cascade,
  name text,                 -- the contact person
  entity text,               -- the selling company
  email text not null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create unique index if not exists land_contract_sellers_email_idx on land_contract_sellers (contract_id, lower(email));
alter table land_contract_sellers enable row level security;   -- no policies: only the security-definer functions below read it
revoke all on land_contract_sellers from anon, authenticated;

insert into portal_settings (key, value) values ('session_idle_days_seller', '45'), ('session_max_days_seller', '180') on conflict (key) do nothing;

create or replace function seller_is_me() returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and exists (select 1 from land_contract_sellers where active and lower(email) = lower(auth.email()));
$$;
revoke all on function seller_is_me() from public, anon;
grant execute on function seller_is_me() to authenticated;

-- Who may receive a sign-in code: add the sellers.
create or replace function condo_email_on_file(p_email text) returns boolean
language sql stable security definer set search_path = public as $$
  select condo_owner_for_email(p_email) is not null
      or exists (select 1 from condo_staff where lower(email) = lower(p_email))
      or exists (select 1 from lease_agents where active and lower(email) = lower(p_email))
      or exists (select 1 from resident_tenant_ids(p_email))
      or exists (select 1 from field_staff where active and lower(email) = lower(p_email))
      or exists (select 1 from contractor_vendor_ids(p_email))
      or exists (select 1 from investors where active and lower(email) = lower(p_email))
      or exists (select 1 from land_contract_sellers where active and lower(email) = lower(p_email));
$$;

-- The role used for the session limits.
create or replace function session_role() returns text
language sql stable security definer set search_path = public as $$
  select case when condo_is_staff() then 'staff' when condo_owner_for_email(auth.email()) is not null then 'owner'
              when exists (select 1 from lease_agents where active and lower(email) = lower(auth.email())) then 'agent'
              when exists (select 1 from resident_tenant_ids(auth.email())) then 'resident'
              when field_is_staff() then 'field' when exists (select 1 from contractor_vendor_ids(auth.email())) then 'contractor'
              when seller_is_me() then 'seller'
              else 'investor' end;
$$;

-- Who am I: report the seller role (no authenticator code is asked of sellers, like owners and residents).
create or replace function condo_whoami() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_owner uuid := condo_owner_for_email(auth.email());
  v_staff boolean := condo_is_staff();
  v_agent uuid := (select id from lease_agents where active and lower(email) = lower(auth.email()));
  v_resident boolean := exists (select 1 from resident_tenant_ids(auth.email()));
  v_field boolean := field_is_staff();
  v_contractor boolean := exists (select 1 from contractor_vendor_ids(auth.email()));
  v_investor boolean := investor_is_me();
  v_seller boolean := seller_is_me();
  v_phone text;
  v_name text;
begin
  if auth.uid() is null then
    return jsonb_build_object('role', 'none');
  end if;
  if not session_fresh() then   -- this remembered device has expired: the page signs out and asks for a new code
    return jsonb_build_object('role', 'expired');
  end if;
  v_phone := condo_mfa_phone_for(auth.email());
  if not (v_staff or v_owner is not null or v_agent is not null or v_resident or v_field or v_contractor or v_investor or v_seller) then
    return jsonb_build_object('role', 'none');
  end if;
  select case when o = 4 and n ~* '\m(inc|llc|ltd|corp|trust|association|company|housing)\M'
              then regexp_replace(trim(n), '[,.]?\s*(inc|llc|ltd|corp)\.?$', '', 'i')
              else split_part(trim(n), ' ', 1) end into v_name from (
    select name as n, 1 as o from condo_staff where lower(email) = lower(auth.email())
    union all select name, 2 from field_staff where active and lower(email) = lower(auth.email())
    union all select name, 3 from portal_admins where lower(email) = lower(auth.email())
    union all select name, 4 from condo_owners where id = v_owner
    union all select name, 5 from land_contract_sellers where active and lower(email) = lower(auth.email())
  ) s where coalesce(trim(n), '') <> '' order by o limit 1;
  return jsonb_build_object(
    'role', case when v_staff then 'staff' when v_owner is not null then 'owner' when v_agent is not null then 'agent' when v_resident then 'resident'
                 when v_field then 'field' when v_contractor then 'contractor' when v_seller then 'seller' else 'investor' end,
    'is_owner', v_owner is not null,
    'is_agent', v_agent is not null,
    'is_resident', v_resident,
    'is_field', v_field,
    'is_contractor', v_contractor,
    'is_investor', v_investor,
    'is_seller', v_seller,
    'first_name', v_name,
    'mfa_required', mfa_required(),
    'verified', condo_session_ok(),
    'phone_hint', condo_mask_phone(v_phone),
    'has_phone', v_phone is not null and length(regexp_replace(v_phone, '\D', '', 'g')) >= 10
  );
end;
$$;

-- The seller's read-only view of the contract.
create or replace function seller_land_contracts() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not condo_session_ok() then raise exception 'Sign-in required' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', c.id, 'street', p.street, 'buyers', c.buyers_label, 'seller', c.seller,
      'contract_date', c.contract_date, 'purchase_price', c.purchase_price, 'down_payment', c.down_payment,
      'interest_rate', c.interest_rate, 'term_months', c.term_months, 'monthly_payment', c.monthly_payment,
      'first_payment_date', c.first_payment_date, 'maturity_date', c.maturity_date, 'grace_days', c.grace_days,
      'balance', (select coalesce(sum(e.amount), 0) from land_contract_ledger e where e.contract_id = c.id),
      'principal_now', (land_contract_interest(c.id) ->> 'principal_balance')::numeric,
      'accrued_interest', (land_contract_interest(c.id) ->> 'accrued_interest')::numeric,
      'next_due', (select jsonb_build_object('due', s.due_date, 'payment', s.scheduled_payment) from land_contract_schedule s
                    where s.contract_id = c.id and s.due_date >= current_date order by s.n limit 1),
      'schedule', coalesce((select jsonb_agg(jsonb_build_object('n', s.n, 'due', s.due_date, 'payment', s.scheduled_payment,
          'principal', s.principal, 'interest', s.interest, 'end', s.ending_balance) order by s.n)
        from land_contract_schedule s where s.contract_id = c.id), '[]'::jsonb),
      'payments', coalesce((select jsonb_agg(jsonb_build_object('date', x.entry_date, 'amount', -x.amount, 'what', x.gl_account, 'note', x.description) order by x.entry_date desc, x.id desc)
        from (select e.* from land_contract_ledger e where e.contract_id = c.id and e.kind = 'payment' and e.gl_account <> 'Security Deposit Liability'
              order by e.entry_date desc, e.id desc limit 36) x), '[]'::jsonb),
      'documents', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'kind', d.kind, 'title', d.title, 'tax_year', d.tax_year,
          'dated', d.dated, 'path', d.storage_path) order by d.kind, d.tax_year desc nulls last, d.dated desc nulls last)
        from land_contract_documents d where d.contract_id = c.id), '[]'::jsonb)))
    from land_contracts c join rental_properties p on p.id = c.property_id
    where c.status = 'active' and exists (select 1 from land_contract_sellers s where s.contract_id = c.id and s.active and lower(s.email) = lower(auth.email()))), '[]'::jsonb);
end;
$$;
revoke all on function seller_land_contracts() from public, anon;
grant execute on function seller_land_contracts() to authenticated;

-- The seller opens the contract documents (a signed link from the page).
drop policy if exists "land contract docs read seller" on storage.objects;
create policy "land contract docs read seller" on storage.objects for select to authenticated
  using (bucket_id = 'land-contract-docs' and condo_session_ok() and exists (
    select 1 from land_contract_documents d join land_contract_sellers s on s.contract_id = d.contract_id
    where d.storage_path = objects.name and s.active and lower(s.email) = lower(auth.email())));

-- "View as" (staff): the seller appears in the tenants list as a land-contract seller and lands on the seller page.
create or replace function admin_role_for_email(p_email text) returns text
language sql stable security definer set search_path = public as $$
  select case
    when exists (select 1 from condo_staff where lower(email) = lower(p_email)) then 'staff'
    when condo_owner_for_email(p_email) is not null then 'owner'
    when exists (select 1 from lease_agents where active and lower(email) = lower(p_email)) then 'agent'
    when exists (select 1 from resident_tenant_ids(p_email)) then 'resident'
    when exists (select 1 from field_staff where active and lower(email) = lower(p_email)) then 'field'
    when exists (select 1 from land_contract_sellers where active and lower(email) = lower(p_email)) then 'seller'
    else 'none' end;
$$;

create or replace function admin_login_directory() returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not portal_is_admin() then raise exception 'Admin only' using errcode = '42501'; end if;
  return jsonb_build_object(
    'staff', coalesce((select jsonb_agg(jsonb_build_object('name', name, 'email', email, 'kind', 'Office staff (all units)') order by name) from condo_staff), '[]'::jsonb),
    'field', coalesce((select jsonb_agg(jsonb_build_object('name', f.name, 'email', f.email, 'kind', 'Field staff',
        'units', (select string_agg(su.unit, ', ' order by su.unit::int) from staff_units su where lower(su.email) = lower(f.email))) order by f.name)
      from field_staff f where f.active), '[]'::jsonb),
    'agents', coalesce((select jsonb_agg(jsonb_build_object('name', name, 'email', email, 'kind', 'Lease agent') order by name) from lease_agents where active), '[]'::jsonb),
    'owners', coalesce((select jsonb_agg(jsonb_build_object('name', o.name, 'email', o.email, 'kind', 'Owner',
        'units', condo_unit_label(o.id)) order by o.name)
      from condo_owners o where condo_owner_for_email(o.email) is not null), '[]'::jsonb),
    'tenants', coalesce((select jsonb_agg(x order by nullif(regexp_replace(coalesce(x ->> 'unit', ''), '\D', '', 'g'), '')::int nulls last, x ->> 'name') from (
        select jsonb_build_object('name', t.name, 'email', t.email, 'kind', 'Tenant', 'unit', ru.unit_number) x
        from tenants t
        join lease_tenants lt on lt.tenant_id = t.id
        join leases l on l.id = lt.lease_id and l.status in ('active', 'future')
        join rental_units ru on ru.id = l.unit_id
        where exists (select 1 from resident_tenant_ids(t.email))
        union
        select jsonb_build_object('name', t.name, 'email', t.email, 'kind', 'Land-contract buyer', 'unit', null::text)
        from land_contract_buyers b join tenants t on t.id = b.tenant_id join land_contracts c on c.id = b.contract_id and c.status = 'active'
        union
        select jsonb_build_object('name', coalesce(s.entity, s.name), 'email', s.email, 'kind', 'Land-contract seller', 'unit', null::text)
        from land_contract_sellers s where s.active) s), '[]'::jsonb)
  );
end;
$$;
