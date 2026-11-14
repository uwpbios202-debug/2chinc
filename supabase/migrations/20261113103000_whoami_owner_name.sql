-- Owners are greeted too ("Hi Pat"): when the signed-in person is an owner and not staff, first_name is the owner's first name,
-- or for an organization its whole name without the Inc/LLC ending. Otherwise unchanged from 20261113102000_whoami_first_name.sql.
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
  v_investor boolean := investor_is_me();
  v_phone text;
  v_name text;
begin
  if auth.uid() is null then
    return jsonb_build_object('role', 'none');
  end if;
  v_phone := condo_mfa_phone_for(auth.email());
  if not (v_staff or v_owner is not null or v_agent is not null or v_resident or v_field or v_contractor or v_investor) then
    return jsonb_build_object('role', 'none');
  end if;
  select case when o = 4 and n ~* '\m(inc|llc|ltd|corp|trust|association|company|housing)\M'
              then regexp_replace(trim(n), '[,.]?\s*(inc|llc|ltd|corp)\.?$', '', 'i')
              else split_part(trim(n), ' ', 1) end into v_name from (
    select name as n, 1 as o from condo_staff where lower(email) = lower(auth.email())
    union all select name, 2 from field_staff where active and lower(email) = lower(auth.email())
    union all select name, 3 from portal_admins where lower(email) = lower(auth.email())
    union all select name, 4 from condo_owners where id = v_owner
  ) s where coalesce(trim(n), '') <> '' order by o limit 1;
  return jsonb_build_object(
    'role', case when v_staff then 'staff' when v_owner is not null then 'owner' when v_agent is not null then 'agent' when v_resident then 'resident'
                 when v_field then 'field' when v_contractor then 'contractor' else 'investor' end,
    'is_owner', v_owner is not null,
    'is_agent', v_agent is not null,
    'is_resident', v_resident,
    'is_field', v_field,
    'is_contractor', v_contractor,
    'is_investor', v_investor,
    'first_name', v_name,
    'mfa_required', mfa_required(),
    'verified', condo_session_ok(),
    'phone_hint', condo_mask_phone(v_phone),
    'has_phone', v_phone is not null and length(regexp_replace(v_phone, '\D', '', 'g')) >= 10
  );
end;
$$;
