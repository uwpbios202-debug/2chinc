-- Navigator profile (Stephen, 11/11/2026): the Navigator sees everything on file about her (never the office's notes) on a
-- Profile tab, and may update her own phone, mailing address, business name and how she wants to be paid. Her sign-in email
-- is changed only by the office.

alter table navigators add column if not exists mailing_address text;

create or replace function nav_profile() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare n navigators;
begin
  select * into n from navigators where id = nav_me();
  if not found then raise exception 'Sign-in required' using errcode = '42501'; end if;
  return to_jsonb(n) - 'notes' - 'id' || jsonb_build_object(
    'referrals_total', (select count(*) from nav_referrals where navigator_id = n.id and not is_sample),
    'housed_total', (select count(*) from nav_referrals where navigator_id = n.id and moved_in_at is not null and not is_sample),
    'units_run', (select count(*) from nav_units where operated_by_navigator = n.id),
    'landlords_added', (select count(*) from nav_landlords where added_by_navigator = n.id),
    'has_sample', exists (select 1 from nav_referrals where navigator_id = n.id and is_sample));
end;
$$;

create or replace function nav_profile_save(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare v_me uuid := nav_me();
begin
  if v_me is null then raise exception 'Sign-in required' using errcode = '42501'; end if;
  update navigators set
    phone = nullif(trim(coalesce(p->>'phone', '')), ''),
    mailing_address = nullif(trim(coalesce(p->>'mailing_address', '')), ''),
    business_name = nullif(trim(coalesce(p->>'business_name', '')), ''),
    pay_method = nullif(trim(coalesce(p->>'pay_method', '')), ''),
    updated_at = now()
  where id = v_me;
  perform nav_log('profile_updated', null, null, v_me);
end;
$$;

create or replace function nav_staff_navigator_save(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_email text := lower(trim(coalesce(p->>'email', '')));
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if length(trim(coalesce(p->>'name', ''))) < 2 then raise exception 'Enter the Navigator''s name.'; end if;
  if v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then raise exception 'Enter a valid email address.'; end if;
  if coalesce(p->>'status', 'prospect') in ('pilot', 'active') and (nullif(p->>'chk_agreement', '') is null or nullif(p->>'chk_confidentiality', '') is null) then
    raise exception 'Before a pilot or active status (which lets the Navigator sign in), record the signed partner agreement and the confidentiality agreement dates.';
  end if;
  if v_id is null then
    insert into navigators (name, email) values (trim(p->>'name'), v_email) returning id into v_id;
  end if;
  update navigators set
    name = trim(p->>'name'), email = v_email,
    phone = nullif(trim(coalesce(p->>'phone', '')), ''),
    business_name = nullif(trim(coalesce(p->>'business_name', '')), ''),
    dfi_entity_id = nullif(trim(coalesce(p->>'dfi_entity_id', '')), ''),
    dfi_status = nullif(trim(coalesce(p->>'dfi_status', '')), ''),
    dfi_checked_on = nullif(p->>'dfi_checked_on', '')::date,
    status = coalesce(nullif(p->>'status', ''), status),
    pilot_start = nullif(p->>'pilot_start', '')::date,
    pilot_end = nullif(p->>'pilot_end', '')::date,
    max_open_referrals = coalesce(nullif(p->>'max_open_referrals', '')::int, max_open_referrals),
    chk_meeting = nullif(p->>'chk_meeting', '')::date,
    chk_agreement = nullif(p->>'chk_agreement', '')::date,
    chk_w9 = nullif(p->>'chk_w9', '')::date,
    chk_insurance = nullif(p->>'chk_insurance', '')::date,
    chk_confidentiality = nullif(p->>'chk_confidentiality', '')::date,
    chk_business_good_standing = nullif(p->>'chk_business_good_standing', '')::date,
    pay_method = nullif(trim(coalesce(p->>'pay_method', '')), ''),
    mailing_address = case when p ? 'mailing_address' then nullif(trim(coalesce(p->>'mailing_address', '')), '') else mailing_address end,
    notes = nullif(trim(coalesce(p->>'notes', '')), ''),
    updated_at = now()
  where id = v_id;
  perform nav_log('navigator_saved', trim(p->>'name') || ' · ' || coalesce(p->>'status', 'prospect'), null, v_id);
  return v_id;
end;
$$;

revoke all on function nav_profile(), nav_profile_save(jsonb) from public, anon;
grant execute on function nav_profile(), nav_profile_save(jsonb) to authenticated, service_role;
