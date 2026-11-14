-- Remembered devices expire (Stephen, 10/18/2026). A sign-in is remembered only for a limited time, per role:
--   idle days = days without use before the device must sign in again; max days = the longest any one sign-in lasts.
-- Defaults: residents and contractors and investors 45 idle / 180 max; owners 90 / 180; staff, field staff and agents 14 / 30.
-- Enforced in condo_session_ok(), the gate every portal data function already uses, so an expired device gets no data.
-- condo_whoami() reports role 'expired' so the sign-in screen can say "please sign in again" instead of showing an error.
insert into portal_settings (key, value) values
  ('session_idle_days_resident', '45'), ('session_max_days_resident', '180'),
  ('session_idle_days_owner', '90'), ('session_max_days_owner', '180'),
  ('session_idle_days_staff', '14'), ('session_max_days_staff', '30'),
  ('session_idle_days_field', '14'), ('session_max_days_field', '30'),
  ('session_idle_days_agent', '14'), ('session_max_days_agent', '30'),
  ('session_idle_days_contractor', '45'), ('session_max_days_contractor', '180'),
  ('session_idle_days_investor', '45'), ('session_max_days_investor', '180')
on conflict (key) do nothing;

-- The role used for the limits: the same order condo_whoami() uses.
create or replace function session_role()
returns text
language sql stable security definer set search_path = public as $$
  select case when condo_is_staff() then 'staff' when condo_owner_for_email(auth.email()) is not null then 'owner'
              when exists (select 1 from lease_agents where active and lower(email) = lower(auth.email())) then 'agent'
              when exists (select 1 from resident_tenant_ids(auth.email())) then 'resident'
              when field_is_staff() then 'field' when exists (select 1 from contractor_vendor_ids(auth.email())) then 'contractor'
              else 'investor' end;
$$;
revoke all on function session_role() from public, anon;
grant execute on function session_role() to authenticated;

-- True while this sign-in is within its role's idle and maximum days.
create or replace function session_fresh()
returns boolean
language plpgsql stable security definer set search_path = public as $$
declare
  v_sid uuid; v_created timestamptz; v_seen timestamptz; v_role text; v_idle numeric; v_max numeric;
begin
  if auth.uid() is null then return false; end if;
  begin v_sid := (auth.jwt() ->> 'session_id')::uuid; exception when others then v_sid := null; end;
  if v_sid is null then return true; end if;   -- no session id in the token (service calls): nothing to measure
  select s.created_at, coalesce(s.refreshed_at at time zone 'utc', s.updated_at at time zone 'utc', s.created_at) into v_created, v_seen
    from auth.sessions s where s.id = v_sid;
  if not found then return false; end if;      -- signed out everywhere: the old token no longer counts
  v_role := session_role();
  v_idle := coalesce(nullif(condo_setting('session_idle_days_' || v_role, ''), '')::numeric, 45);
  v_max  := coalesce(nullif(condo_setting('session_max_days_' || v_role, ''), '')::numeric, 180);
  return now() - v_created <= make_interval(days => v_max::int) and now() - v_seen <= make_interval(days => v_idle::int);
end;
$$;
revoke all on function session_fresh() from public, anon;
grant execute on function session_fresh() to authenticated;

create or replace function condo_session_ok()
returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and mfa_aal_ok() and session_fresh();
$$;

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
  if not session_fresh() then   -- this remembered device has expired: the page signs out and asks for a new code
    return jsonb_build_object('role', 'expired');
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
