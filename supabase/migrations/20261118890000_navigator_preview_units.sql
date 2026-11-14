-- Preview Navigators may manage their OWN landlords, units, rooms, money, budget and inspections (their business
-- information); adding PEOPLE (referrals, resident information) still waits for Pilot (Stephen, 11/11/2026).
-- A Preview Navigator sees contact details of the landlords she added, not of other Navigators' shared landlords.

create or replace function nav_actor_role() returns text
language plpgsql stable security definer set search_path = public as $$
begin
  if staff_session_staff() then return 'staff'; end if;
  if nav_me() is null then return null; end if;
  return 'navigator';
end;
$$;

create or replace function nav_referral_save(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_role text := nav_actor_role(); v_me uuid := nav_me(); v_id uuid := nullif(p->>'id', '')::uuid; r nav_referrals; n navigators;
  t text;
begin
  if v_role is null then raise exception 'Sign-in required' using errcode = '42501'; end if;
  if v_role = 'navigator' and exists (select 1 from navigators where id = v_me and status = 'preview') then
    raise exception 'Preview: adding people opens once the partner and confidentiality agreements are signed.' using errcode = '42501';
  end if;
  if length(trim(coalesce(p->>'first_name', ''))) < 1 then raise exception 'Enter the person''s first name.'; end if;
  if v_id is null then
    if v_role = 'navigator' then
      select * into n from navigators where id = v_me;
      if (select count(*) from nav_referrals where navigator_id = v_me and status <> 'closed') >= n.max_open_referrals then
        raise exception 'You have % open referrals, the most allowed right now. Close one or ask the office to raise the limit.', n.max_open_referrals;
      end if;
    end if;
    insert into nav_referrals (navigator_id, first_name) values (case when v_role = 'navigator' then v_me else nullif(p->>'navigator_id', '')::uuid end, trim(p->>'first_name'))
      returning id into v_id;
    perform nav_log('created', null, v_id);
  else
    if not nav_can_ref(v_id) then raise exception 'Not found.' using errcode = '42501'; end if;
    select * into r from nav_referrals where id = v_id;
    if r.status = 'closed' and v_role <> 'staff' then raise exception 'This referral is closed. Ask the office to reopen it.'; end if;
  end if;

  update nav_referrals set
    first_name = trim(p->>'first_name'),
    last_name = nullif(trim(coalesce(p->>'last_name', '')), ''),
    phone = nullif(trim(coalesce(p->>'phone', '')), ''),
    email = nullif(lower(trim(coalesce(p->>'email', ''))), ''),
    reach_note = nullif(trim(coalesce(p->>'reach_note', '')), ''),
    pathway = coalesce(nullif(p->>'pathway', ''), 'other'),
    housing_situation = nullif(p->>'housing_situation', ''),
    veteran = case when p ? 'veteran' and p->>'veteran' in ('true', 'false') then (p->>'veteran')::boolean else null end,
    household_size = nullif(p->>'household_size', '')::int,
    bedrooms_needed = nullif(p->>'bedrooms_needed', '')::numeric,
    income_monthly = nullif(p->>'income_monthly', '')::numeric,
    income_sources = coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p->'income_sources', '[]'::jsonb)) x
                                 where x in ('ss', 'ssi', 'ssdi', 'va', 'pension', 'employment', 'child_support', 'other')), '{}'),
    income_verified_on = case when v_role = 'staff' then nullif(p->>'income_verified_on', '')::date else income_verified_on end,
    contribution_monthly = nullif(p->>'contribution_monthly', '')::numeric,
    assistance_monthly = nullif(p->>'assistance_monthly', '')::numeric,
    assistance_source = nullif(trim(coalesce(p->>'assistance_source', '')), ''),
    assistance_confirmed = coalesce((p->>'assistance_confirmed')::boolean, false),
    move_in_by = nullif(p->>'move_in_by', '')::date,
    areas = nullif(trim(coalesce(p->>'areas', '')), ''),
    accessibility_needs = nullif(trim(coalesce(p->>'accessibility_needs', '')), ''),
    accommodation_request = nullif(trim(coalesce(p->>'accommodation_request', '')), ''),
    support_name = nullif(trim(coalesce(p->>'support_name', '')), ''),
    support_agency = nullif(trim(coalesce(p->>'support_agency', '')), ''),
    support_phone = nullif(trim(coalesce(p->>'support_phone', '')), ''),
    support_email = nullif(lower(trim(coalesce(p->>'support_email', ''))), ''),
    staff_notes = case when v_role = 'staff' and p ? 'staff_notes' then nullif(trim(coalesce(p->>'staff_notes', '')), '') else staff_notes end,
    navigator_id = case when v_role = 'staff' and p ? 'navigator_id' then nullif(p->>'navigator_id', '')::uuid else navigator_id end,
    updated_at = now()
  where id = v_id;

  -- Consent: the person types their own full name on the Navigator's screen. Recorded once with the date and text version.
  t := trim(coalesce(p->>'consent_name', ''));
  if t <> '' then
    update nav_referrals set consent_name = t, consent_on = (now() at time zone 'America/Chicago')::date, consent_version = 'nav-consent-2026-11', consent_withdrawn_on = null
     where id = v_id and (consent_name is distinct from t or consent_on is null);
    if found then perform nav_log('consent_signed', 'Consent signed by ' || t, v_id); end if;
  end if;
  if v_id = nullif(p->>'id', '')::uuid then perform nav_log('updated', null, v_id); end if;
  return v_id;
end;
$$;

create or replace function nav_network() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_staff boolean := staff_session_staff(); v_me uuid := nav_me();
        v_preview boolean := exists (select 1 from navigators where id = nav_me() and status = 'preview');
begin
  if not v_staff and v_me is null then raise exception 'Two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(
      (to_jsonb(l) - 'notes' - 'added_by_navigator' - case when v_preview and l.added_by_navigator is distinct from v_me then 'phone' else '' end
                   - case when v_preview and l.added_by_navigator is distinct from v_me then 'email' else '' end
                   - case when v_preview and l.added_by_navigator is distinct from v_me then 'mailing_address' else '' end) || jsonb_build_object(
        'mine', l.added_by_navigator is not null and l.added_by_navigator = v_me,
        'added_by', case when v_staff then (select name from navigators where id = l.added_by_navigator) end,
        'notes', case when v_staff or l.added_by_navigator = v_me then l.notes end,
        'placements', (select count(*) from nav_referrals x join nav_units xu on xu.id = x.nav_unit_id where xu.landlord_id = l.id and x.moved_in_at is not null),
        'units', coalesce((select jsonb_agg(nav_unit_json(u) order by u.address, u.unit_label) from nav_units u where u.landlord_id = l.id), '[]'::jsonb))
      order by coalesce(l.business_name, l.name))
    from nav_landlords l where v_staff or l.shared or l.added_by_navigator = v_me), '[]'::jsonb);
end;
$$;

create or replace function nav_unit_file(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare u nav_units; v_today date := (now() at time zone 'America/Chicago')::date; v_month date := date_trunc('month', (now() at time zone 'America/Chicago'))::date;
        v_write boolean;
begin
  if not nav_can_manage_unit(p_id::text) then raise exception 'Not your unit' using errcode = '42501'; end if;
  select * into u from nav_units where id = p_id;
  v_write := staff_session_staff() or exists (select 1 from navigators where id = nav_me() and status in ('preview', 'pilot', 'active'));
  return jsonb_build_object(
    'can_write', v_write,
    'role', case when staff_session_staff() then 'staff' else 'navigator' end,
    'unit', nav_unit_json(u),
    'landlord', (select jsonb_build_object('id', l.id, 'name', l.name, 'business_name', l.business_name, 'phone', l.phone, 'email', l.email) from nav_landlords l where l.id = u.landlord_id),
    'navigators', case when staff_session_staff() then coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name) order by name) from navigators), '[]'::jsonb) end,
    'operated_by_navigator', case when staff_session_staff() then u.operated_by_navigator end,
    'rooms', coalesce((select jsonb_agg(to_jsonb(r) || jsonb_build_object('occupant', (
        select jsonb_build_object('referral_id', x.id, 'label', nav_ref_label(x), 'name', x.first_name || coalesce(' ' || left(x.last_name, 1) || '.', ''), 'status', x.status, 'move_in_on', x.move_in_on)
          from nav_referrals x where x.nav_room_id = r.id and x.status in ('matched', 'approved', 'moved_in') order by x.updated_at desc limit 1)) order by r.sort, r.label)
      from nav_rooms r where r.unit_id = p_id), '[]'::jsonb),
    'budget', coalesce((select jsonb_agg(to_jsonb(b) order by b.frequency, b.category) from nav_unit_budget b where b.unit_id = p_id), '[]'::jsonb),
    'money', coalesce((select jsonb_agg(to_jsonb(m) || jsonb_build_object('room', (select label from nav_rooms where id = m.room_id),
        'referral', (select nav_ref_label(x) from nav_referrals x where x.id = m.referral_id)) order by m.entry_date desc, m.created_at desc)
      from nav_unit_money m where m.unit_id = p_id), '[]'::jsonb),
    'months', coalesce((select jsonb_agg(jsonb_build_object('month', to_char(mo, 'YYYY-MM'),
        'income', (select coalesce(sum(amount), 0) from nav_unit_money where unit_id = p_id and not voided and kind = 'income' and date_trunc('month', entry_date) = mo),
        'expense', (select coalesce(sum(amount), 0) from nav_unit_money where unit_id = p_id and not voided and kind = 'expense' and date_trunc('month', entry_date) = mo)) order by mo desc)
      from generate_series(v_month - interval '11 months', v_month, interval '1 month') mo), '[]'::jsonb),
    'totals', jsonb_build_object(
      'income', (select coalesce(sum(amount), 0) from nav_unit_money where unit_id = p_id and not voided and kind = 'income'),
      'expense', (select coalesce(sum(amount), 0) from nav_unit_money where unit_id = p_id and not voided and kind = 'expense'),
      'startup', (select coalesce(sum(amount), 0) from nav_unit_money where unit_id = p_id and not voided and category in ('furniture', 'appliances', 'deposit_paid')),
      'potential_rent', case when u.room_mode then (select coalesce(sum(monthly_rate), 0) from nav_rooms where unit_id = p_id and status <> 'offline') else u.rent end,
      'occupied_rent', case when u.room_mode then (select coalesce(sum(monthly_rate), 0) from nav_rooms where unit_id = p_id and status = 'occupied') end,
      'rooms', (select count(*) from nav_rooms where unit_id = p_id and status <> 'offline'),
      'rooms_occupied', (select count(*) from nav_rooms where unit_id = p_id and status = 'occupied')),
    'inspections', coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'inspected_on', i.inspected_on, 'purpose', i.purpose, 'status', i.status,
        'needs_repair', (select count(*) from jsonb_each(coalesce(i.data -> 'items', '{}'::jsonb)) x where x.value ->> 's' = 'Needs repair')) order by i.inspected_on desc, i.created_at desc)
      from inspections i where i.property_id = 'nav' and i.unit = p_id::text), '[]'::jsonb),
    'residents', coalesce((select jsonb_agg(jsonb_build_object('id', x.id, 'label', nav_ref_label(x), 'name', x.first_name || coalesce(' ' || left(x.last_name, 1) || '.', ''),
        'status', x.status, 'room', (select label from nav_rooms where id = x.nav_room_id), 'move_in_on', x.move_in_on, 'unit_rent', x.unit_rent) order by x.updated_at desc)
      from nav_referrals x where x.nav_unit_id = p_id and (staff_session_staff() or x.navigator_id = nav_me())), '[]'::jsonb)
  );
end;
$$;
