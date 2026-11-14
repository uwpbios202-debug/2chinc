-- Payments come in through the bank (Plaid), not from tenants reporting them (Stephen, 10/9/2026).
--  1. Every lease has an account number to put in the Zelle memo. Earlier leases keep
--     theirs (leases.legacy_lease_number, which is what the portal, staff pages and bank matching
--     already read); leases created on 2ndchinc.org get the next free 6-digit number from 800001 up.
--  2. Bank matching also looks at future leases, so the deposit and first month paid before the
--     start date match on their own.
--  3. A separate switch, bank_autopost, posts matched deposits without turning on the rest of the
--     automation (late fees, notices). It is turned on here.

create sequence if not exists lease_account_seq start 800001;

create or replace function lease_assign_account_number()
returns trigger
language plpgsql security definer set search_path = public as $$
declare v text;
begin
  if coalesce(trim(new.legacy_lease_number), '') = '' then
    loop
      v := nextval('lease_account_seq')::text;
      exit when not exists (select 1 from leases where legacy_lease_number = v);
    end loop;
    new.legacy_lease_number := v;
  end if;
  return new;
end;
$$;

drop trigger if exists leases_account_number on leases;
create trigger leases_account_number before insert on leases
  for each row execute function lease_assign_account_number();

-- Leases already created without one (the ones signed online so far).
do $$
declare r record; v text;
begin
  for r in select id from leases where coalesce(trim(legacy_lease_number), '') = '' order by start_date loop
    loop
      v := nextval('lease_account_seq')::text;
      exit when not exists (select 1 from leases where legacy_lease_number = v);
    end loop;
    update leases set legacy_lease_number = v where id = r.id;
  end loop;
end $$;

insert into portal_settings (key, value) values ('bank_autopost', 'on')
on conflict (key) do update set value = 'on';

-- Same as 20261105010000_payments_autopilot.sql, except future leases are matched too.
create or replace function bank_candidates(p_receipt uuid)
returns table (target_kind text, target_id uuid, label text, why text, rank int)
language plpgsql stable security definer set search_path = public
as $$
declare b bank_receipts; v_scope text; v_text text; v_tokens text[]; v_norm text;
begin
  select * into b from bank_receipts where id = p_receipt;
  if b.id is null then return; end if;
  v_scope := coalesce((select kind from bank_accounts where id = b.bank_account_id), 'tenant');
  v_text := coalesce(b.description, '') || ' ' || coalesce(b.reference, '') || ' ' || coalesce(b.payer_name, '');
  v_norm := payer_norm(coalesce(nullif(b.payer_name, ''), b.description));
  v_tokens := payer_tokens(coalesce(nullif(b.payer_name, ''), b.description));

  if v_scope = 'tenant' then
    return query
    with active as (
      select l.id, l.legacy_lease_number num, l.tenants_label, coalesce(ru.unit_number, '') unit, l.rent
      from leases l left join rental_units ru on ru.id = l.unit_id where l.status in ('active', 'future')),
    by_acct as (
      select a.id, 'lease'::text k, 1 r, 'account number ' || a.num || ' in the memo' w, a.tenants_label || ' (unit ' || a.unit || ')' lab
      from active a where a.num is not null and length(a.num) >= 5 and v_text ~ ('(^|[^0-9])0*' || ltrim(a.num, '0') || '([^0-9]|$)')),
    by_alias as (
      select al.lease_id id, 'lease'::text k, 2 r, 'known payer' w, a.tenants_label || ' (unit ' || a.unit || ')' lab
      from payer_aliases al join active a on a.id = al.lease_id where al.scope = 'tenant' and al.alias = v_norm and v_norm <> ''),
    by_name as (
      select a.id, 'lease'::text k, 3 r, 'payer name matches the tenant' w, a.tenants_label || ' (unit ' || a.unit || ')' lab
      from active a
      where cardinality(v_tokens) >= 2 and not exists (
        select 1 from unnest(v_tokens) t where not exists (select 1 from unnest(payer_tokens(a.tenants_label)) x where x = t))
      union
      select a.id, 'lease'::text, 3, 'payer name matches a tenant on the lease', a.tenants_label || ' (unit ' || a.unit || ')'
      from active a join lease_tenants lt on lt.lease_id = a.id join tenants t2 on t2.id = lt.tenant_id
      where cardinality(v_tokens) >= 2 and not exists (
        select 1 from unnest(v_tokens) t where not exists (select 1 from unnest(payer_tokens(t2.name)) x where x = t))),
    by_contract as (
      select c.id, 'land_contract'::text k, 3 r, 'payer name matches the buyer' w, c.buyers_label lab
      from land_contracts c where c.status = 'active' and cardinality(v_tokens) >= 2 and not exists (
        select 1 from unnest(v_tokens) t where not exists (select 1 from unnest(payer_tokens(c.buyers_label)) x where x = t))
      union
      select al.land_contract_id, 'land_contract', 2, 'known payer', c.buyers_label
      from payer_aliases al join land_contracts c on c.id = al.land_contract_id where al.scope = 'tenant' and al.alias = v_norm and v_norm <> '' and c.status = 'active')
    select d.k, d.id, d.lab, d.w, d.r from (
      select distinct on (x.k, x.id) x.k, x.id, x.lab, x.w, x.r from (
        select * from by_acct union all select * from by_alias union all select * from by_name union all select * from by_contract) x
      order by x.k, x.id, x.r) d
    order by d.r, d.lab;
  else
    return query
    with cur as (
      select a.id acct, u.unit_number, u.pin, o.name owner_name, o.id owner_id
      from condo_units u join condo_ownerships s on s.unit_id = u.id and s.is_current join condo_owners o on o.id = s.owner_id
      join condo_ledger_accounts a on a.unit_id = u.id and a.billing_account and not a.excluded),
    by_acct as (
      select c.acct id, 'condo'::text k, 1 r, case when c.pin is not null and v_text like '%' || c.pin || '%' then 'tax key ' || c.pin || ' in the memo' else 'unit ' || c.unit_number || ' in the memo' end w,
             'Unit ' || c.unit_number || ' (' || c.owner_name || ')' lab
      from cur c where (c.pin is not null and length(c.pin) >= 6 and v_text like '%' || c.pin || '%')
        or v_text ~* ('(unit|apt|#)\s*' || c.unit_number || '([^0-9]|$)')),
    by_alias as (
      select al.condo_account_id, 'condo'::text, 2, 'known payer', 'Unit ' || c.unit_number || ' (' || c.owner_name || ')'
      from payer_aliases al join cur c on c.acct = al.condo_account_id where al.scope = 'owner' and al.alias = v_norm and v_norm <> ''),
    by_name as (
      select c.acct, 'condo'::text, 3, 'payer name matches the owner', 'Unit ' || c.unit_number || ' (' || c.owner_name || ')'
      from cur c where cardinality(v_tokens) >= 2 and not exists (
        select 1 from unnest(v_tokens) t where not exists (select 1 from unnest(payer_tokens(c.owner_name)) x where x = t)))
    select d.k, d.id, d.lab, d.w, d.r from (
      select distinct on (x.k, x.id) x.k, x.id, x.lab, x.w, x.r from (
        select * from by_acct union all select * from by_alias union all select * from by_name) x
      order by x.k, x.id, x.r) d
    order by d.r, d.lab;
  end if;
end;
$$;
