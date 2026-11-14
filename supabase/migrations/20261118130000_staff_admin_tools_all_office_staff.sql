-- Office staff (condo_staff) may do everything the admin can on the three admin tools of 11/3/2026 (Stephen, 11/3/2026):
-- change which units each staff login controls, change the bank account a unit's rent is paid into, and pay ROCA1 dues on every
-- unit 2nd Chance Housing Inc owns. Field staff keep paying dues only on the 2nd Chance-owned units assigned to them.
-- Only the role check changes (portal_is_admin() -> condo_is_staff()); the functions are otherwise as in 20261118120000.

create or replace function admin_staff_units_list()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'people', coalesce((
      with ppl as (
        select lower(email) email, name, 'field' as role, active from field_staff
        union all
        select lower(c.email), c.name, 'office', true from condo_staff c where not exists (select 1 from field_staff f where lower(f.email) = lower(c.email)))
      select jsonb_agg(jsonb_build_object('email', p.email, 'name', p.name, 'role', p.role, 'active', p.active,
        'units', coalesce((select jsonb_agg(jsonb_build_object('property_id', su.property_id, 'unit', su.unit) order by su.property_id, su.unit::int)
                           from staff_units su where lower(su.email) = p.email), '[]'::jsonb)) order by p.role, p.name)
      from ppl p), '[]'::jsonb),
    'company_units', coalesce((select jsonb_agg(u.unit_number order by u.unit_number::int)
      from condo_units u join condo_ownerships s on s.unit_id = u.id and s.is_current
      where s.owner_id::text = condo_setting('company_owner_id', '')), '[]'::jsonb),
    'log', coalesce((select jsonb_agg(jsonb_build_object('at', l.at, 'by', l.by_email, 'kind', l.kind, 'target', l.target, 'detail', l.detail) order by l.at desc)
      from (select * from admin_change_log order by at desc limit 30) l), '[]'::jsonb));
end $$;
revoke all on function admin_staff_units_list() from public, anon;
grant execute on function admin_staff_units_list() to authenticated, service_role;

create or replace function admin_staff_unit_set(p_email text, p_property text, p_unit text, p_on boolean)
returns void
language plpgsql volatile security definer set search_path = public
as $$
declare v_email text := lower(trim(p_email)); v_n int;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if not exists (select 1 from field_staff where lower(email) = v_email) and not exists (select 1 from condo_staff where lower(email) = v_email) then
    raise exception 'That email is not a staff login.';
  end if;
  if p_property not in ('6622-n-bourbon', '6626-n-bourbon') or p_unit !~ '^[0-9]{1,2}$' then raise exception 'Unknown unit.'; end if;
  if (p_property = '6626-n-bourbon' and p_unit::int not between 1 and 8) or (p_property = '6622-n-bourbon' and p_unit::int not between 11 and 18) then
    raise exception 'Unit % is not in that building.', p_unit;
  end if;
  if p_on then
    insert into staff_units (email, property_id, unit)
    select v_email, p_property, p_unit
    where not exists (select 1 from staff_units where lower(email) = v_email and property_id = p_property and unit = p_unit);
  else
    delete from staff_units where lower(email) = v_email and property_id = p_property and unit = p_unit;
  end if;
  get diagnostics v_n = row_count;
  if v_n > 0 then
    insert into admin_change_log (by_email, kind, target, detail)
    values (auth.email(), case when p_on then 'staff_unit_add' else 'staff_unit_remove' end, v_email, jsonb_build_object('property_id', p_property, 'unit', p_unit));
  end if;
end $$;
revoke all on function admin_staff_unit_set(text, text, text, boolean) from public, anon;
grant execute on function admin_staff_unit_set(text, text, text, boolean) to authenticated, service_role;

create or replace function staff_lease_banks()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'can_change', condo_is_staff(),
    'accounts', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'entity', a.entity, 'online', a.stripe_account is not null or a.bank_key = 'chase_2ch',
                          'default', a.bank_key = 'chase_2ch') order by a.bank_key = 'chase_2ch' desc, a.name)
                          from bank_accounts a where a.active), '[]'::jsonb),
    'leases', coalesce((select jsonb_agg(jsonb_build_object(
        'lease_id', l.id, 'unit', ru.unit_number, 'address', ru.address, 'status', l.status, 'tenants', l.tenants_label,
        'account_id', lease_receiving_account(l.id), 'account', (select name from bank_accounts where id = lease_receiving_account(l.id)),
        'routed_roca1', roca_routed_unit(l.id) is not null,
        'autopay_active', exists (select 1 from autopay_authorizations x where x.lease_id = l.id and x.status in ('pending', 'active', 'paused')),
        'in_flight', exists (select 1 from stripe_payments s where s.lease_id = l.id and s.status = 'processing'))
      order by ru.unit_number::int, l.start_date)
      from leases l join rental_units ru on ru.id = l.unit_id where l.status in ('active', 'future')), '[]'::jsonb));
end $$;
revoke all on function staff_lease_banks() from public, anon;
grant execute on function staff_lease_banks() to authenticated, service_role;

create or replace function admin_lease_bank_set(p_lease uuid, p_account uuid)
returns void
language plpgsql volatile security definer set search_path = public
as $$
declare l leases; a bank_accounts; v_old uuid;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into l from leases where id = p_lease for update;
  if l.id is null or l.status not in ('active', 'future') then raise exception 'Lease not found (only active and future leases can be changed).'; end if;
  select * into a from bank_accounts where id = p_account and active;
  if a.id is null then raise exception 'Choose an active bank account.'; end if;
  v_old := lease_receiving_account(l.id);
  if v_old = a.id then return; end if;
  -- Money already on its way to the old account, or an autopay set up there, would land in the wrong place.
  if exists (select 1 from stripe_payments s where s.lease_id = l.id and s.status = 'processing') then
    raise exception 'A bank payment for this lease is still clearing into the current account. Change it after it clears.';
  end if;
  if exists (select 1 from autopay_authorizations x where x.lease_id = l.id and x.status in ('pending', 'active', 'paused')) then
    raise exception 'This tenant has autopay set up into the current account. The tenant must cancel autopay first (and set it up again after the change).';
  end if;
  -- The default account (2nd Chance Chase) is stored as empty, which is how online payment and matching read it.
  update leases set pay_to_account_id = case when a.bank_key = 'chase_2ch' then null else a.id end where id = l.id;
  insert into admin_change_log (by_email, kind, target, detail)
  values (auth.email(), 'lease_bank_change', l.id::text, jsonb_build_object(
    'unit', (select unit_number from rental_units where id = l.unit_id),
    'from', (select name from bank_accounts where id = v_old), 'to', a.name));
end $$;
revoke all on function admin_lease_bank_set(uuid, uuid) from public, anon;
grant execute on function admin_lease_bank_set(uuid, uuid) to authenticated, service_role;

create or replace function admin_change_log_recent(p_kind text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('at', l.at, 'by', l.by_email, 'kind', l.kind, 'target', l.target, 'detail', l.detail) order by l.at desc)
    from (select * from admin_change_log where kind like p_kind || '%' order by at desc limit 30) l), '[]'::jsonb);
end $$;
revoke all on function admin_change_log_recent(text) from public, anon;
grant execute on function admin_change_log_recent(text) to authenticated, service_role;

create or replace function staff_dues_units()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v_admin boolean := condo_is_staff(); v_company text := condo_setting('company_owner_id', '');
begin
  if not (condo_session_ok() and (condo_is_staff() or field_is_staff())) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'enabled', condo_setting('owner_pay_stripe', 'off') = 'on' and condo_setting('stripe_enabled_roca1', 'off') = 'on',
    'units', coalesce((select jsonb_agg(jsonb_build_object(
        'unit', u.unit_number, 'address', u.address,
        'dues', coalesce(s.fee, condo_setting('dues_default', '215')::numeric),
        'max', 12 * coalesce(s.fee, condo_setting('dues_default', '215')::numeric),
        'balance', (select coalesce(sum(e.amount), 0) from condo_ledger_entries e join condo_ledger_accounts a on a.id = e.account_id
                    where a.ownership_id = s.id and not a.excluded),
        'recent', (select jsonb_agg(jsonb_build_object('at', p.created_at, 'amount', p.amount, 'status', p.status, 'by', p.started_by) order by p.created_at desc)
                   from (select * from stripe_payments p where p.owner_id = s.owner_id and p.condo_account_id in (select a2.id from condo_ledger_accounts a2 where a2.ownership_id = s.id)
                           and p.status <> 'created' order by p.created_at desc limit 5) p)
      ) order by u.unit_number::int)
      from condo_units u join condo_ownerships s on s.unit_id = u.id and s.is_current
      where s.owner_id::text = v_company
        and (v_admin or exists (select 1 from staff_units su where lower(su.email) = lower(auth.email()) and su.unit = u.unit_number))), '[]'::jsonb));
end $$;
revoke all on function staff_dues_units() from public, anon;
grant execute on function staff_dues_units() to authenticated, service_role;

create or replace function staff_dues_pay_target(p_unit text)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare v_company text := condo_setting('company_owner_id', ''); s condo_ownerships; v_unit uuid; v_dues numeric; v_bal numeric;
begin
  if not (condo_session_ok() and (condo_is_staff() or field_is_staff())) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if autopay_view_as_session() then raise exception 'Not available while viewing as someone else.'; end if;
  select s2.* into s from condo_ownerships s2 join condo_units u on u.id = s2.unit_id
   where u.unit_number = p_unit and s2.is_current and s2.owner_id::text = v_company;
  if s.id is null then raise exception 'Unit % is not owned by 2nd Chance Housing Inc.', p_unit; end if;
  if not (condo_is_staff() or exists (select 1 from staff_units su where lower(su.email) = lower(auth.email()) and su.unit = p_unit)) then
    raise exception 'Unit % is not assigned to you.', p_unit using errcode = '42501';
  end if;
  v_unit := s.unit_id;
  v_dues := coalesce(s.fee, condo_setting('dues_default', '215')::numeric);
  select coalesce(sum(e.amount), 0) into v_bal from condo_ledger_entries e join condo_ledger_accounts a on a.id = e.account_id
   where a.ownership_id = s.id and not a.excluded;
  return jsonb_build_object('owner_id', s.owner_id, 'name', (select name from condo_owners where id = s.owner_id),
    'email', (select email from condo_owners where id = s.owner_id), 'paid_by', auth.email(),
    'unit_number', p_unit, 'account_id', condo_billing_account(v_unit), 'balance', v_bal, 'dues', v_dues, 'max', 12 * v_dues);
end $$;
revoke all on function staff_dues_pay_target(text) from public, anon;
grant execute on function staff_dues_pay_target(text) to authenticated, service_role;

