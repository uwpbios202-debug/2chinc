-- Admin "View as" lists Housing Navigators (pilot or active) and opens their portal at /navigator/ (Stephen, 11/11/2026).
-- Same bodies as live, plus the navigator group / role.

create or replace function public.admin_role_for_email(p_email text) returns text
language sql stable security definer set search_path = public as $function$
  select case
    when exists (select 1 from condo_staff where lower(email) = lower(p_email)) then 'staff'
    when condo_owner_for_email(p_email) is not null then 'owner'
    when exists (select 1 from lease_agents where active and lower(email) = lower(p_email)) then 'agent'
    when exists (select 1 from resident_tenant_ids(p_email)) then 'resident'
    when exists (select 1 from field_staff where active and lower(email) = lower(p_email)) then 'field'
    when exists (select 1 from land_contract_sellers where active and lower(email) = lower(p_email)) then 'seller'
    when exists (select 1 from navigators where status in ('pilot', 'active') and lower(email) = lower(p_email)) then 'navigator'
    else 'none' end;
$function$;

create or replace function public.admin_login_directory() returns jsonb
language plpgsql stable security definer set search_path = public as $function$
begin
  if not portal_is_admin() then raise exception 'Admin only' using errcode = '42501'; end if;
  return jsonb_build_object(
    'staff', coalesce((select jsonb_agg(jsonb_build_object('name', name, 'email', email, 'kind', 'Office staff (all units)') order by name) from condo_staff), '[]'::jsonb),
    'field', coalesce((select jsonb_agg(jsonb_build_object('name', f.name, 'email', f.email, 'kind', 'Field staff',
        'units', (select string_agg(su.unit, ', ' order by su.unit::int) from staff_units su where lower(su.email) = lower(f.email))) order by f.name)
      from field_staff f where f.active), '[]'::jsonb),
    'agents', coalesce((select jsonb_agg(jsonb_build_object('name', name, 'email', email, 'kind', 'Lease agent') order by name) from lease_agents where active), '[]'::jsonb),
    'navigators', coalesce((select jsonb_agg(jsonb_build_object('name', name, 'email', email, 'kind', 'Housing Navigator (' || status || ')') order by name)
      from navigators where status in ('pilot', 'active')), '[]'::jsonb),
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
$function$;
