-- Housing Navigator "Preview" status (Stephen, 11/11/2026): a Navigator can sign in (emailed code + authenticator app) and
-- look around the portal BEFORE the partner and confidentiality agreements are signed, but cannot add or change anything
-- (people, landlords, units, notes, check-ins) and does not see landlord contact details. Pilot or Active opens everything.

alter table navigators drop constraint if exists navigators_status_check;
alter table navigators add constraint navigators_status_check check (status in ('prospect', 'preview', 'pilot', 'active', 'paused', 'ended'));

-- Signed-in Navigator: preview, pilot or active.
create or replace function navigator_is_me() returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and exists (select 1 from navigators where status in ('preview', 'pilot', 'active') and lower(email) = lower(auth.email()));
$$;

create or replace function nav_me() returns uuid
language sql stable security definer set search_path = public as $$
  select n.id from navigators n where condo_session_ok() and n.status in ('preview', 'pilot', 'active') and lower(n.email) = lower(auth.email());
$$;

-- Every write goes through nav_actor_role() (nav_log, nav_referral_save, nav_referral_step, nav_landlord_save, nav_unit_save);
-- notes, check-ins and consent need an own referral, which a preview Navigator cannot create.
create or replace function nav_actor_role() returns text
language plpgsql stable security definer set search_path = public as $$
begin
  if staff_session_staff() then return 'staff'; end if;
  if nav_me() is null then return null; end if;
  if exists (select 1 from navigators where id = nav_me() and status = 'preview') then
    raise exception 'Preview only: you can look around now. Adding people, landlords and units opens once the partner and confidentiality agreements are signed.' using errcode = '42501';
  end if;
  return 'navigator';
end;
$$;

-- Same as 20261118800000, but a preview Navigator does not see landlord contact details or notes.
create or replace function nav_network() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_staff boolean := staff_session_staff(); v_me uuid := nav_me();
        v_preview boolean := exists (select 1 from navigators where id = nav_me() and status = 'preview');
begin
  if not v_staff and v_me is null then raise exception 'Two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(
      (to_jsonb(l) - 'notes' - 'added_by_navigator' - case when v_preview then 'phone' else '' end - case when v_preview then 'email' else '' end
                   - case when v_preview then 'mailing_address' else '' end) || jsonb_build_object(
        'mine', l.added_by_navigator is not null and l.added_by_navigator = v_me,
        'added_by', case when v_staff then (select name from navigators where id = l.added_by_navigator) end,
        'notes', case when v_staff or l.added_by_navigator = v_me then l.notes end,
        'placements', (select count(*) from nav_referrals x join nav_units xu on xu.id = x.nav_unit_id where xu.landlord_id = l.id and x.moved_in_at is not null),
        'units', coalesce((select jsonb_agg(nav_unit_json(u) order by u.address, u.unit_label) from nav_units u where u.landlord_id = l.id), '[]'::jsonb))
      order by coalesce(l.business_name, l.name))
    from nav_landlords l where v_staff or l.shared or l.added_by_navigator = v_me), '[]'::jsonb);
end;
$$;

create or replace function nav_staff_invite(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare n navigators;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into n from navigators where id = p_id;
  if not found then raise exception 'Navigator not found.'; end if;
  if n.status not in ('preview', 'pilot', 'active') then raise exception 'Set the Navigator to Preview, Pilot or Active first.'; end if;
  perform nav_email(n.email, 'Your Housing Navigator sign-in at 2nd Chance Housing',
    '<p>Hello ' || repair_esc(split_part(n.name, ' ', 1)) || ',</p>'
    || '<p>Welcome to the 2nd Chance Housing Community Housing Partnership. Your Navigator portal is ready.</p>'
    || '<ol><li>Open <a href="https://2ndchinc.org/navigator/">https://2ndchinc.org/navigator/</a> on your phone or computer.</li>'
    || '<li>Type this email address (' || repair_esc(n.email) || ') and tap <b>Email me a code</b>. Enter the 6-digit code we email you.</li>'
    || '<li>The first time, the page asks you to set up an <b>authenticator app</b> (Google Authenticator, Microsoft Authenticator or Authy) for a second code. It takes about a minute. '
    || 'This keeps the people you help safe.</li></ol>'
    || case when n.status = 'preview'
         then '<p>For now your portal is a <b>preview</b>: look around and see how it works. Adding people, landlords and units opens once the partner and confidentiality agreements are signed.</p>'
         else '<p>In the portal you add the people you are helping (with their signed consent), the landlords and units you work with, record move-ins and check-ins, and see your pay.</p>' end
    || '<p>Questions: reply to this email or write to info@2ndchinc.org.</p><p>2nd Chance Housing Inc</p>', 'nav_invite');
  update navigators set invited_at = now() where id = p_id;
  perform nav_log('navigator_invited', n.email, null, p_id);
end;
$$;

create or replace function public.condo_email_on_file(p_email text) returns boolean
language sql stable security definer set search_path = public as $function$
  select condo_owner_for_email(p_email) is not null
      or exists (select 1 from condo_staff where lower(email) = lower(p_email))
      or exists (select 1 from lease_agents where active and lower(email) = lower(p_email))
      or exists (select 1 from resident_tenant_ids(p_email))
      or exists (select 1 from field_staff where active and lower(email) = lower(p_email))
      or exists (select 1 from contractor_vendor_ids(p_email))
      or exists (select 1 from investors where active and lower(email) = lower(p_email))
      or exists (select 1 from land_contract_sellers where active and lower(email) = lower(p_email))
      or exists (select 1 from caseworkers where active and lower(email) = lower(p_email))
      or exists (select 1 from unit_occupants where active and lower(email) = lower(p_email))
      or exists (select 1 from navigators where status in ('preview', 'pilot', 'active') and lower(email) = lower(p_email));
$function$;

create or replace function public.mfa_required() returns boolean
language sql stable security definer set search_path = public as $function$
  with r as (select string_to_array(replace(coalesce((select value from portal_settings where key = 'mfa_required_roles'), ''), ' ', ''), ',') as roles)
  select auth.uid() is not null and exists (select 1 from r where
       ('staff' = any (r.roles) and exists (select 1 from condo_staff where lower(email) = lower(auth.email())))
    or ('field' = any (r.roles) and exists (select 1 from field_staff where active and lower(email) = lower(auth.email())))
    or ('agent' = any (r.roles) and exists (select 1 from lease_agents where active and lower(email) = lower(auth.email())))
    or ('owner' = any (r.roles) and condo_owner_for_email(auth.email()) is not null)
    or ('resident' = any (r.roles) and exists (select 1 from resident_tenant_ids(auth.email())))
    or ('contractor' = any (r.roles) and exists (select 1 from contractor_vendor_ids(auth.email())))
    or ('navigator' = any (r.roles) and exists (select 1 from navigators where status in ('preview', 'pilot', 'active') and lower(email) = lower(auth.email()))));
$function$;

create or replace function public.admin_role_for_email(p_email text) returns text
language sql stable security definer set search_path = public as $function$
  select case
    when exists (select 1 from condo_staff where lower(email) = lower(p_email)) then 'staff'
    when condo_owner_for_email(p_email) is not null then 'owner'
    when exists (select 1 from lease_agents where active and lower(email) = lower(p_email)) then 'agent'
    when exists (select 1 from resident_tenant_ids(p_email)) then 'resident'
    when exists (select 1 from field_staff where active and lower(email) = lower(p_email)) then 'field'
    when exists (select 1 from land_contract_sellers where active and lower(email) = lower(p_email)) then 'seller'
    when exists (select 1 from navigators where status in ('preview', 'pilot', 'active') and lower(email) = lower(p_email)) then 'navigator'
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
      from navigators where status in ('preview', 'pilot', 'active')), '[]'::jsonb),
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
