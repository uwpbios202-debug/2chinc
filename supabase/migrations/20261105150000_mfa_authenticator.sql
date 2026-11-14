-- Authenticator-app second factor (TOTP) for sign-in (Stephen, 10/7/2026).
-- After the emailed code, people in the roles listed in portal_settings.mfa_required_roles must also enter the 6-digit code
-- from an authenticator app (Google Authenticator, Microsoft Authenticator, Authy, 1Password...). The check is enforced HERE, in the
-- database: a session that has not passed the app code (Supabase "aal2") is refused by every staff, field-staff and agent function,
-- whatever the web page does.
--
-- mfa_required_roles is a comma list of: staff, field, agent, owner, resident, contractor. It starts at 'staff,field,agent'.
-- Make it empty to switch the requirement off:  update portal_settings set value = '' where key = 'mfa_required_roles';

insert into portal_settings (key, value) values ('mfa_required_roles', 'staff,field,agent') on conflict (key) do nothing;

create or replace function mfa_required()
returns boolean
language sql stable security definer set search_path = public as $$
  with r as (select string_to_array(replace(coalesce((select value from portal_settings where key = 'mfa_required_roles'), ''), ' ', ''), ',') as roles)
  select auth.uid() is not null and exists (select 1 from r where
       ('staff' = any (r.roles) and exists (select 1 from condo_staff where lower(email) = lower(auth.email())))
    or ('field' = any (r.roles) and exists (select 1 from field_staff where active and lower(email) = lower(auth.email())))
    or ('agent' = any (r.roles) and exists (select 1 from lease_agents where active and lower(email) = lower(auth.email())))
    or ('owner' = any (r.roles) and condo_owner_for_email(auth.email()) is not null)
    or ('resident' = any (r.roles) and exists (select 1 from resident_tenant_ids(auth.email())))
    or ('contractor' = any (r.roles) and exists (select 1 from contractor_vendor_ids(auth.email()))));
$$;
revoke all on function mfa_required() from public, anon;
grant execute on function mfa_required() to authenticated;

-- True when this session has done everything its role requires.
create or replace function mfa_aal_ok()
returns boolean
language sql stable security definer set search_path = public as $$
  select not mfa_required() or coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2';
$$;
revoke all on function mfa_aal_ok() from public, anon;
grant execute on function mfa_aal_ok() to authenticated;

-- Every portal function gates on this one.
create or replace function condo_session_ok()
returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and mfa_aal_ok();
$$;

-- Field staff (units assigned to them): same requirement.
create or replace function field_can_access(p_property text, p_unit text)
returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and mfa_aal_ok() and (
    condo_is_staff()
    or (field_is_staff() and exists (
      select 1 from staff_units
      where lower(email) = lower(auth.email()) and property_id = p_property and unit = p_unit)));
$$;
create or replace function field_can_open_doc(p_bucket text, p_path text)
returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and mfa_aal_ok() and field_is_staff() and (
    (p_bucket = 'lease-signing' and exists (
       select 1 from lease_signing_docs d join leases l on l.id = d.lease_id join rental_units ru on ru.id = l.unit_id
         join staff_units su on lower(su.email) = lower(auth.email()) and su.unit = ru.unit_number
       where d.executed_pdf_path = p_path))
    or (p_bucket = 'notices' and exists (
       select 1 from notices n join leases l on l.id = n.lease_id join rental_units ru on ru.id = l.unit_id
         join staff_units su on lower(su.email) = lower(auth.email()) and su.unit = ru.unit_number
       where n.pdf_path = p_path))
    or (p_bucket = 'owner-docs' and exists (
       select 1 from condo_documents c where c.storage_path = p_path
         and (c.unit_number is null or c.unit_number in (select su.unit from staff_units su where lower(su.email) = lower(auth.email()))))));
$$;
create or replace function field_can_see_lease(p_lease uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and mfa_aal_ok() and field_is_staff() and exists (
    select 1 from leases l join rental_units ru on ru.id = l.unit_id
      join staff_units su on lower(su.email) = lower(auth.email()) and su.unit = ru.unit_number
    where l.id = p_lease);
$$;
create or replace function vehicle_can_view_unit(p_unit text)
returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and (
    exists (select 1 from vehicle_my_units())
    or condo_owner_for_email(auth.email()) is not null
    or (mfa_aal_ok() and condo_is_staff())
    or (mfa_aal_ok() and field_is_staff() and exists (select 1 from staff_units where lower(email) = lower(auth.email()) and unit = p_unit)));
$$;
create or replace function field_my_units()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'Sign-in required' using errcode = '42501'; end if;
  if not mfa_aal_ok() then raise exception 'Enter the code from your authenticator app to continue' using errcode = '42501'; end if;
  if condo_is_staff() then return jsonb_build_object('all', true, 'units', '[]'::jsonb); end if;
  if not field_is_staff() then raise exception 'Not field staff' using errcode = '42501'; end if;
  return jsonb_build_object('all', false, 'units', coalesce((
    select jsonb_agg(jsonb_build_object('property_id', property_id, 'unit', unit) order by property_id, unit)
    from staff_units where lower(email) = lower(auth.email())), '[]'::jsonb));
end;
$$;

-- Tell the page what is required so it can ask for the app code.
create or replace function condo_whoami()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_owner uuid := condo_owner_for_email(auth.email());
  v_staff boolean := condo_is_staff();
  v_agent uuid := (select id from lease_agents where active and lower(email) = lower(auth.email()));
  v_resident boolean := exists (select 1 from resident_tenant_ids(auth.email()));
  v_field boolean := field_is_staff();
  v_contractor boolean := exists (select 1 from contractor_vendor_ids(auth.email()));
  v_phone text;
begin
  if auth.uid() is null then
    return jsonb_build_object('role', 'none');
  end if;
  v_phone := condo_mfa_phone_for(auth.email());
  if not (v_staff or v_owner is not null or v_agent is not null or v_resident or v_field or v_contractor) then
    return jsonb_build_object('role', 'none');
  end if;
  return jsonb_build_object(
    'role', case when v_staff then 'staff' when v_owner is not null then 'owner' when v_agent is not null then 'agent' when v_resident then 'resident'
                 when v_field then 'field' else 'contractor' end,
    'is_owner', v_owner is not null,
    'is_agent', v_agent is not null,
    'is_resident', v_resident,
    'is_field', v_field,
    'is_contractor', v_contractor,
    'mfa_required', mfa_required(),
    'verified', condo_session_ok(),
    'phone_hint', condo_mask_phone(v_phone),
    'has_phone', v_phone is not null and length(regexp_replace(v_phone, '\D', '', 'g')) >= 10
  );
end;
$$;
