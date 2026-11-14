-- Housing Navigators run their OWN business on the platform (Stephen, 11/12/2026).
--   * A Navigator's people, landlords and units are her book of business: other Navigators NEVER see them. Office staff see
--     everything (full view). What is shared by everyone is the general knowledge base (the housing resource directory).
--   * Self-serve: after she signs the Housing Navigator Agreement and the Confidentiality Agreement once (office dates both on
--     the Navigators tab), she adds and manages her own people with no office acceptance, no placement approval and no cap on
--     open referrals. Before that she can set up her landlords and units only.
--   * 2nd Chance Housing does not pay Navigators per placement any more (what 2nd Chance gets in return is undecided):
--     nav_earn no longer records anything. Existing tables and rows are left as they are.
--   * Office-added landlords marked shared stay visible to Navigators; a landlord a Navigator adds is always private to her.

-- ---------------------------------------------------------------- landlords: private to the Navigator who added them
update nav_landlords set shared = false where added_by_navigator is not null and shared;

create or replace function nav_can_see_landlord(p_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select staff_session_staff() or (nav_me() is not null and exists (select 1 from nav_landlords l where l.id = p_id
    and (l.added_by_navigator = nav_me() or (l.added_by_navigator is null and l.shared))));
$$;

create or replace function nav_network() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_staff boolean := staff_session_staff(); v_me uuid := nav_me();
begin
  if not v_staff and v_me is null then raise exception 'Sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(
      (to_jsonb(l) - 'notes' - 'added_by_navigator') || jsonb_build_object(
        'mine', l.added_by_navigator is not null and l.added_by_navigator = v_me,
        'office', l.added_by_navigator is null,
        'added_by', case when v_staff then (select name from navigators where id = l.added_by_navigator) end,
        'notes', case when v_staff or l.added_by_navigator = v_me then l.notes end,
        'placements', (select count(*) from nav_referrals x join nav_units xu on xu.id = x.nav_unit_id where xu.landlord_id = l.id and x.moved_in_at is not null),
        'units', coalesce((select jsonb_agg(nav_unit_json(u) order by u.address, u.unit_label) from nav_units u where u.landlord_id = l.id), '[]'::jsonb))
      order by coalesce(l.business_name, l.name))
    from nav_landlords l
   where v_staff or l.added_by_navigator = v_me or (l.added_by_navigator is null and l.shared)), '[]'::jsonb);
end;
$$;

-- Same as 20261118800000, but a Navigator's landlord is always private (shared = false) and the office is not emailed
-- (staff see every landlord on https://2ndchinc.org/staff/navigators/#network).
create or replace function nav_landlord_save(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_role text := nav_actor_role(); v_id uuid := nullif(p->>'id', '')::uuid;
begin
  if v_role is null then raise exception 'Sign-in required' using errcode = '42501'; end if;
  if length(trim(coalesce(p->>'name', ''))) < 2 then raise exception 'Enter the landlord''s name.'; end if;
  if v_id is null then
    insert into nav_landlords (name, added_by_navigator, shared) values (trim(p->>'name'), case when v_role = 'navigator' then nav_me() end, v_role = 'staff')
      returning id into v_id;
    perform nav_log('landlord_added', trim(p->>'name'), null, null, v_id);
  elsif not nav_can_edit_landlord(v_id) then
    raise exception 'Only the office or the Navigator who added this landlord can change it.' using errcode = '42501';
  end if;
  update nav_landlords set
    name = trim(p->>'name'),
    business_name = nullif(trim(coalesce(p->>'business_name', '')), ''),
    email = nullif(lower(trim(coalesce(p->>'email', ''))), ''),
    phone = nullif(trim(coalesce(p->>'phone', '')), ''),
    mailing_address = nullif(trim(coalesce(p->>'mailing_address', '')), ''),
    accepts_vouchers = case when p->>'accepts_vouchers' in ('true', 'false') then (p->>'accepts_vouchers')::boolean end,
    accepts_assistance = case when p->>'accepts_assistance' in ('true', 'false') then (p->>'accepts_assistance')::boolean end,
    requirements = nullif(trim(coalesce(p->>'requirements', '')), ''),
    agreement_status = case when v_role = 'staff' then coalesce(nullif(p->>'agreement_status', ''), agreement_status) else agreement_status end,
    agreement_on = case when v_role = 'staff' then nullif(p->>'agreement_on', '')::date else agreement_on end,
    status = case when v_role = 'staff' then coalesce(nullif(p->>'status', ''), status) else status end,
    shared = case when added_by_navigator is not null then false when v_role = 'staff' then coalesce((p->>'shared')::boolean, shared) else shared end,
    notes = nullif(trim(coalesce(p->>'notes', '')), ''),
    updated_at = now()
  where id = v_id;
  return v_id;
end;
$$;

-- ---------------------------------------------------------------- no per-placement pay from 2nd Chance
create or replace function nav_earn(p_nav uuid, p_kind text, p_referral uuid, p_landlord uuid, p_note text) returns void
language plpgsql security definer set search_path = public as $$ begin return; end; $$;

-- ---------------------------------------------------------------- people: open once both agreements are signed
create or replace function nav_agreements_signed(p_nav uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from navigators where id = p_nav and chk_agreement is not null and chk_confidentiality is not null);
$$;

-- Same as 20261118890000, but: the gate is "both agreements signed" (not the status), no cap on open referrals, the Navigator
-- may record that income was verified, and she reopens her own closed referral herself (Reopen button).
create or replace function nav_referral_save(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_role text := nav_actor_role(); v_me uuid := nav_me(); v_id uuid := nullif(p->>'id', '')::uuid; r nav_referrals;
  t text;
begin
  if v_role is null then raise exception 'Sign-in required' using errcode = '42501'; end if;
  -- SAMPLE people (walkthrough data) can be worked on before the agreements are signed; real people cannot.
  if v_role = 'navigator' and not nav_agreements_signed(v_me)
     and (v_id is null or not exists (select 1 from nav_referrals where id = v_id and is_sample)) then
    raise exception 'Adding people opens once your Housing Navigator Agreement and Confidentiality Agreement are signed.' using errcode = '42501';
  end if;
  if length(trim(coalesce(p->>'first_name', ''))) < 1 then raise exception 'Enter the person''s first name.'; end if;
  if v_id is null then
    insert into nav_referrals (navigator_id, first_name) values (case when v_role = 'navigator' then v_me else nullif(p->>'navigator_id', '')::uuid end, trim(p->>'first_name'))
      returning id into v_id;
    perform nav_log('created', null, v_id);
  else
    if not nav_can_ref(v_id) then raise exception 'Not found.' using errcode = '42501'; end if;
    select * into r from nav_referrals where id = v_id;
    if r.status = 'closed' and v_role <> 'staff' then raise exception 'This file is closed. Tap Reopen first.'; end if;
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
    income_verified_on = case when p ? 'income_verified_on' then nullif(p->>'income_verified_on', '')::date else income_verified_on end,
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

-- Same as 20261118950000, but self-serve: the Navigator starts the search herself (draft -> searching, consent and a way to
-- reach the person required), confirms her own placements (same affordability-gap and income checks), closes and reopens
-- her own files. No office emails (staff see everything on the office page); the Navigator is emailed only when the office
-- acts on her file. No pay is recorded (nav_earn is a no-op).
create or replace function nav_referral_step(p_id uuid, p_to text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_role text := nav_actor_role(); r nav_referrals; u nav_units; rm nav_rooms; v_gap numeric; v_note text := nullif(trim(coalesce(p->>'note', '')), '');
  v_date date; v_ok boolean := false; v_label text; v_who text; v_tell boolean;
begin
  if v_role is null or not nav_can_ref(p_id) then raise exception 'Not found.' using errcode = '42501'; end if;
  perform set_config('nav.sample', coalesce((select case when is_sample then '1' else '0' end from nav_referrals where id = p_id), '0'), true);   -- sample records never send email
  select * into r from nav_referrals where id = p_id for update;
  if v_role = 'navigator' and not r.is_sample and not nav_agreements_signed(r.navigator_id) then
    raise exception 'Working with people opens once your Housing Navigator Agreement and Confidentiality Agreement are signed.' using errcode = '42501';
  end if;
  v_label := nav_ref_label(r);
  v_who := r.first_name || coalesce(' ' || left(r.last_name, 1) || '.', '');
  v_tell := v_role = 'staff' and r.navigator_id is not null;   -- email the Navigator only when the office acts on her file

  if p_to in ('submitted', 'reviewing', 'searching') and r.status in ('draft', 'submitted', 'reviewing', 'closed') then
    if r.status = 'closed' and r.moved_in_at is not null then raise exception 'This person was already housed through this file. Start a new file for a new housing search.'; end if;
    if r.consent_on is null or r.consent_name is null or r.consent_withdrawn_on is not null then raise exception 'The person must sign the consent (type their full name) first.'; end if;
    if r.phone is null and r.email is null and r.reach_note is null then raise exception 'Add a phone, an email or how to reach the person.'; end if;
    update nav_referrals set status = 'searching', submitted_at = coalesce(submitted_at, now()), accepted_at = coalesce(accepted_at, now()),
           close_reason = null, closed_at = null, updated_at = now() where id = p_id;
    p_to := 'searching';
    if v_tell then
      perform nav_email((select email from navigators where id = r.navigator_id), v_label || ': housing search started by the office',
        '<p>The office started the housing search for <b>' || v_label || '</b> (' || repair_esc(v_who) || ').' || coalesce('<br>Note: ' || repair_esc(v_note), '') || '</p><p>https://2ndchinc.org/navigator/</p>', 'nav_navigator');
    end if;
    v_ok := true;

  elsif p_to = 'matched' and r.status = 'searching' then
    if nullif(p->>'nav_room_id', '') is not null then
      select * into rm from nav_rooms where id = (p->>'nav_room_id')::uuid for update;
      if not found then raise exception 'Room not found.'; end if;
      select * into u from nav_units where id = rm.unit_id;
      if not nav_can_see_landlord(u.landlord_id) then raise exception 'Room not found.'; end if;
      if rm.status <> 'available' then raise exception 'That room is not available (it is %).', rm.status; end if;
      if rm.monthly_rate is null then raise exception 'Set the room''s monthly rate first (unit file, Rooms).'; end if;
      update nav_rooms set status = 'reserved', updated_at = now() where id = rm.id;
      update nav_referrals set status = 'matched', nav_unit_id = u.id, nav_room_id = rm.id, rental_unit_id = null, unit_rent = rm.monthly_rate, matched_at = now(), updated_at = now() where id = p_id;
      v_note := coalesce(v_note || ' · ', '') || u.address || coalesce(' ' || u.unit_label, '') || ', ' || rm.label;
    elsif nullif(p->>'nav_unit_id', '') is not null then
      select * into u from nav_units where id = (p->>'nav_unit_id')::uuid for update;
      if not found or not nav_can_see_landlord(u.landlord_id) then raise exception 'Unit not found.'; end if;
      if exists (select 1 from nav_rooms where unit_id = u.id) then raise exception 'This unit is rented by room. Pick a room.'; end if;
      if u.status not in ('available') then raise exception 'That unit is not available (it is %).', u.status; end if;
      update nav_units set status = 'reserved', updated_at = now() where id = u.id;
      update nav_referrals set status = 'matched', nav_unit_id = u.id, nav_room_id = null, rental_unit_id = null, unit_rent = u.rent, matched_at = now(), updated_at = now() where id = p_id;
      v_note := coalesce(v_note || ' · ', '') || u.address || coalesce(' ' || u.unit_label, '');
    elsif nullif(p->>'rental_unit_id', '') is not null and v_role = 'staff' then
      if nullif(p->>'rent', '') is null then raise exception 'Enter the monthly rent for this unit.'; end if;
      update nav_referrals set status = 'matched', rental_unit_id = (p->>'rental_unit_id')::uuid, nav_unit_id = null, nav_room_id = null, unit_rent = (p->>'rent')::numeric,
             matched_at = now(), updated_at = now() where id = p_id;
    else raise exception 'Pick a unit or room.';
    end if;
    v_ok := true;

  elsif p_to = 'searching' and r.status in ('matched', 'approved') then
    update nav_rooms set status = 'available', updated_at = now() where id = r.nav_room_id and status = 'reserved';
    update nav_units set status = 'available', updated_at = now() where id = r.nav_unit_id and r.nav_room_id is null and status = 'reserved';
    update nav_referrals set status = 'searching', nav_unit_id = null, nav_room_id = null, rental_unit_id = null, unit_rent = null, matched_at = null,
           approved_at = null, approved_by = null, updated_at = now() where id = p_id;
    v_note := coalesce(v_note, 'Unit released; back to searching');
    v_ok := true;

  elsif p_to = 'approved' and r.status = 'matched' then
    v_gap := nav_gap(r);
    if v_gap is null then raise exception 'No rent on the matched unit.'; end if;
    if v_gap > 0 and v_note is null then
      raise exception 'The person is short % a month (rent minus what they can pay minus confirmed assistance). Write how the gap is covered to confirm anyway.', to_char(v_gap, 'FM$999,990.00');
    end if;
    if r.income_verified_on is null and v_note is null then raise exception 'Income is not marked verified. Verify it (Edit details, Income verified on) or write why you confirm anyway.'; end if;
    update nav_referrals set status = 'approved', approved_at = now(), approved_by = lower(auth.email()), gap_override_note = case when v_gap > 0 then v_note end, updated_at = now() where id = p_id;
    if v_tell then
      perform nav_email((select email from navigators where id = r.navigator_id), v_label || ': placement confirmed by the office',
        '<p>The office confirmed the placement for <b>' || v_label || '</b> (' || repair_esc(v_who) || '). When the person moves in, record the move-in date on the portal.</p><p>https://2ndchinc.org/navigator/</p>', 'nav_navigator');
    end if;
    v_ok := true;

  elsif p_to = 'moved_in' and r.status = 'approved' then
    v_date := coalesce(nullif(p->>'move_in_on', '')::date, (now() at time zone 'America/Chicago')::date);
    if v_date > (now() at time zone 'America/Chicago')::date + 1 then raise exception 'Record the move-in on or after the day it happens.'; end if;
    update nav_referrals set status = 'moved_in', move_in_on = v_date, moved_in_at = now(), updated_at = now() where id = p_id;
    update nav_rooms set status = 'occupied', updated_at = now() where id = r.nav_room_id;
    update nav_units set status = 'occupied', updated_at = now() where id = r.nav_unit_id and r.nav_room_id is null;
    update nav_referrals set checkin_every = coalesce(nullif(p->>'checkin_every', ''), checkin_every, 'weekly'),
           checkin_note = coalesce(nullif(trim(coalesce(p->>'checkin_note', '')), ''), checkin_note) where id = p_id;
    insert into nav_followups (referral_id, mark, due_on) values (p_id, 'd90', v_date + 90), (p_id, 'm12', (v_date + interval '12 months')::date)
      on conflict do nothing;
    perform nav_checkin_schedule(p_id, nullif(p->>'first_checkin_on', '')::date, v_date);
    v_note := coalesce(v_note || ' · ', '') || 'Moved in ' || to_char(v_date, 'MM/DD/YYYY');
    v_ok := true;

  elsif p_to = 'closed' and r.status <> 'closed' then
    if nullif(p->>'close_reason', '') is null then raise exception 'Pick why it is closing.'; end if;
    update nav_rooms set status = 'available', updated_at = now() where id = r.nav_room_id and status in ('reserved', 'occupied');
    update nav_units set status = 'available', updated_at = now() where id = r.nav_unit_id and r.nav_room_id is null and status in ('reserved', 'occupied');
    update nav_referrals set status = 'closed', close_reason = p->>'close_reason', closed_at = now(), updated_at = now() where id = p_id;
    if v_tell then
      perform nav_email((select email from navigators where id = r.navigator_id), v_label || ': closed by the office',
        '<p>The office closed <b>' || v_label || '</b> (' || repair_esc(replace(p->>'close_reason', '_', ' ')) || ').' || coalesce('<br>Note: ' || repair_esc(v_note), '') || '</p>', 'nav_navigator');
    end if;
    v_ok := true;
  end if;

  if not v_ok then raise exception 'That step is not allowed now (the file is %).', replace(r.status, '_', ' '); end if;
  perform nav_log('status_' || p_to, v_note, p_id);
  return nav_referral_get(p_id);
end;
$$;

-- nav_home tells the page whether people are open yet.
create or replace function nav_home() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_me uuid := nav_me(); n navigators; v_today date := (now() at time zone 'America/Chicago')::date;
begin
  if v_me is null then raise exception 'Sign-in required' using errcode = '42501'; end if;
  select * into n from navigators where id = v_me;
  return jsonb_build_object(
    'me', jsonb_build_object('name', n.name, 'status', n.status, 'people_open', n.chk_agreement is not null and n.chk_confidentiality is not null,
            'agreement_signed', n.chk_agreement is not null, 'confidentiality_signed', n.chk_confidentiality is not null),
    'open_referrals', (select count(*) from nav_referrals where navigator_id = v_me and status not in ('closed')),
    'referrals', coalesce((select jsonb_agg(nav_referral_json(r, false) order by r.updated_at desc) from nav_referrals r where r.navigator_id = v_me), '[]'::jsonb),
    'followups_due', coalesce((select jsonb_agg(jsonb_build_object('id', f.id, 'referral_id', r.id, 'label', nav_ref_label(r), 'name', r.first_name || coalesce(' ' || r.last_name, ''),
                         'mark', f.mark, 'due_on', f.due_on, 'overdue', f.due_on < v_today) order by f.due_on)
                       from nav_followups f join nav_referrals r on r.id = f.referral_id
                      where r.navigator_id = v_me and f.done_on is null and f.due_on <= v_today + 7 and r.status = 'moved_in'), '[]'::jsonb),
    'consent_text', nav_consent_text()
  );
end;
$$;

revoke all on function nav_agreements_signed(uuid) from public, anon, authenticated;
grant execute on function nav_agreements_signed(uuid) to service_role;

-- Same as 20261118910000, but the Profile form no longer asks how she wants to be paid: keep what is on file unless sent.
create or replace function nav_profile_save(p jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare v_me uuid := nav_me();
begin
  if v_me is null then raise exception 'Sign-in required' using errcode = '42501'; end if;
  update navigators set
    phone = nullif(trim(coalesce(p->>'phone', '')), ''),
    mailing_address = nullif(trim(coalesce(p->>'mailing_address', '')), ''),
    business_name = nullif(trim(coalesce(p->>'business_name', '')), ''),
    pay_method = case when p ? 'pay_method' then nullif(trim(coalesce(p->>'pay_method', '')), '') else pay_method end,
    updated_at = now()
  where id = v_me;
  perform nav_log('profile_updated', null, null, v_me);
end;
$$;

-- Same as 20261118910000, but fields no longer on the office form (pilot dates, W-9 date, pay method) are kept when not sent.
create or replace function nav_staff_navigator_save(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid := nullif(p->>'id', '')::uuid; v_email text := lower(trim(coalesce(p->>'email', '')));
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if length(trim(coalesce(p->>'name', ''))) < 2 then raise exception 'Enter the Navigator''s name.'; end if;
  if v_email !~ '^[^\s@]+@[^\s@]+\.[^\s@]+$' then raise exception 'Enter a valid email address.'; end if;
  if coalesce(p->>'status', 'prospect') in ('pilot', 'active') and (nullif(p->>'chk_agreement', '') is null or nullif(p->>'chk_confidentiality', '') is null) then
    raise exception 'Before a pilot or active status, record the signed Housing Navigator Agreement and Confidentiality Agreement dates.';
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
    pilot_start = case when p ? 'pilot_start' then nullif(p->>'pilot_start', '')::date else pilot_start end,
    pilot_end = case when p ? 'pilot_end' then nullif(p->>'pilot_end', '')::date else pilot_end end,
    max_open_referrals = coalesce(nullif(p->>'max_open_referrals', '')::int, max_open_referrals),
    chk_meeting = nullif(p->>'chk_meeting', '')::date,
    chk_agreement = nullif(p->>'chk_agreement', '')::date,
    chk_w9 = case when p ? 'chk_w9' then nullif(p->>'chk_w9', '')::date else chk_w9 end,
    chk_insurance = nullif(p->>'chk_insurance', '')::date,
    chk_confidentiality = nullif(p->>'chk_confidentiality', '')::date,
    chk_business_good_standing = nullif(p->>'chk_business_good_standing', '')::date,
    pay_method = case when p ? 'pay_method' then nullif(trim(coalesce(p->>'pay_method', '')), '') else pay_method end,
    mailing_address = case when p ? 'mailing_address' then nullif(trim(coalesce(p->>'mailing_address', '')), '') else mailing_address end,
    notes = nullif(trim(coalesce(p->>'notes', '')), ''),
    updated_at = now()
  where id = v_id;
  perform nav_log('navigator_saved', trim(p->>'name') || ' · ' || coalesce(p->>'status', 'prospect'), null, v_id);
  return v_id;
end;
$$;
