-- Check-ins follow each person's own plan (Stephen, 11/11/2026: "from daily to weekly to fortnightly ... depending on the client").
--   * nav_referrals.checkin_every: daily, every_3_days, weekly, every_2_weeks, monthly, every_2_months, quarterly, as_needed;
--     checkin_note (why), next_checkin_on.
--   * nav_followups mark 'checkin' (many per person): recording one schedules the next from the plan; the Navigator can change
--     the plan or move the next date any time (nav_checkin_plan_save).
--   * Two fixed stability reviews stay (90 days, 12 months): they measure staying housed and drive retention pay.
--     The fixed 30-day, 60-day and 6-month dates are no longer created (older rows stay as history).

alter table nav_referrals add column if not exists checkin_every text not null default 'weekly'
  check (checkin_every in ('daily', 'every_3_days', 'weekly', 'every_2_weeks', 'monthly', 'every_2_months', 'quarterly', 'as_needed'));
alter table nav_referrals add column if not exists checkin_note text;
alter table nav_referrals add column if not exists next_checkin_on date;

alter table nav_followups drop constraint if exists nav_followups_mark_check;
alter table nav_followups add constraint nav_followups_mark_check check (mark in ('d30', 'd60', 'd90', 'm6', 'm12', 'checkin'));
alter table nav_followups drop constraint if exists nav_followups_referral_id_mark_key;
create unique index if not exists nav_followups_review_once on nav_followups (referral_id, mark) where mark <> 'checkin';
create unique index if not exists nav_followups_one_open_checkin on nav_followups (referral_id) where mark = 'checkin' and done_on is null;

create or replace function nav_checkin_interval(p_every text) returns interval
language sql immutable as $$
  select case p_every when 'daily' then interval '1 day' when 'every_3_days' then interval '3 days' when 'weekly' then interval '7 days'
    when 'every_2_weeks' then interval '14 days' when 'monthly' then interval '1 month' when 'every_2_months' then interval '2 months'
    when 'quarterly' then interval '3 months' else null end;
$$;

-- Puts the person's next check-in on the calendar: p_next if given, else p_from + their interval. As needed: none.
create or replace function nav_checkin_schedule(p_referral uuid, p_next date, p_from date) returns void
language plpgsql security definer set search_path = public as $$
declare r nav_referrals; v_due date;
begin
  select * into r from nav_referrals where id = p_referral;
  if not found or r.status <> 'moved_in' then return; end if;
  v_due := coalesce(p_next, (p_from + nav_checkin_interval(r.checkin_every))::date);
  if v_due is null then
    delete from nav_followups where referral_id = p_referral and mark = 'checkin' and done_on is null;
  elsif exists (select 1 from nav_followups where referral_id = p_referral and mark = 'checkin' and done_on is null) then
    update nav_followups set due_on = v_due, reminded_at = null where referral_id = p_referral and mark = 'checkin' and done_on is null;
  else
    insert into nav_followups (referral_id, mark, due_on) values (p_referral, 'checkin', v_due);
  end if;
  update nav_referrals set next_checkin_on = v_due where id = p_referral;
end;
$$;

create or replace function nav_checkin_plan_save(p_id uuid, p_every text, p_next date, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare v_role text := nav_actor_role();
begin
  if v_role is null or not nav_can_ref(p_id) then raise exception 'Not found.' using errcode = '42501'; end if;
  if p_every not in ('daily', 'every_3_days', 'weekly', 'every_2_weeks', 'monthly', 'every_2_months', 'quarterly', 'as_needed') then raise exception 'Pick how often.'; end if;
  if p_next is not null and p_next < (now() at time zone 'America/Chicago')::date then raise exception 'The next check-in cannot be in the past.'; end if;
  update nav_referrals set checkin_every = p_every, checkin_note = nullif(trim(coalesce(p_note, '')), ''), updated_at = now() where id = p_id;
  perform nav_checkin_schedule(p_id, p_next, (now() at time zone 'America/Chicago')::date);
  perform nav_log('checkin_plan', replace(p_every, '_', ' ') || coalesce(' · next ' || to_char(p_next, 'MM/DD'), '') || coalesce(' · ' || trim(p_note), ''), p_id);
end;
$$;

revoke all on function nav_checkin_schedule(uuid, date, date) from public, anon, authenticated;
grant execute on function nav_checkin_schedule(uuid, date, date) to service_role;
revoke all on function nav_checkin_plan_save(uuid, text, date, text) from public, anon;
grant execute on function nav_checkin_plan_save(uuid, text, date, text) to authenticated, service_role;

create or replace function nav_referral_step(p_id uuid, p_to text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_role text := nav_actor_role(); r nav_referrals; u nav_units; rm nav_rooms; l nav_landlords; v_gap numeric; v_note text := nullif(trim(coalesce(p->>'note', '')), '');
  v_date date; v_ok boolean := false; v_label text; v_who text;
begin
  if v_role is null or not nav_can_ref(p_id) then raise exception 'Not found.' using errcode = '42501'; end if;
  perform set_config('nav.sample', coalesce((select case when is_sample then '1' else '0' end from nav_referrals where id = p_id), '0'), true);   -- sample records never send email
  select * into r from nav_referrals where id = p_id for update;
  v_label := nav_ref_label(r);
  v_who := r.first_name || coalesce(' ' || left(r.last_name, 1) || '.', '');

  if p_to = 'submitted' and r.status = 'draft' then
    if r.consent_on is null or r.consent_name is null then raise exception 'The person must sign the consent (type their full name) before you submit.'; end if;
    if r.phone is null and r.email is null and r.reach_note is null then raise exception 'Add a phone, an email or how to reach the person.'; end if;
    update nav_referrals set status = 'submitted', submitted_at = now(), updated_at = now() where id = p_id;
    perform nav_email('info@2ndchinc.org', 'Housing Navigator: new referral ' || v_label,
      '<p>' || repair_esc(coalesce((select name from navigators where id = r.navigator_id), 'A Navigator')) || ' submitted referral <b>' || v_label || '</b> ('
      || repair_esc(r.pathway) || '). Review it at https://2ndchinc.org/staff/navigators/</p>', 'nav_office');
    v_ok := true;

  elsif p_to in ('reviewing', 'searching') and v_role = 'staff' and r.status in ('submitted', 'reviewing', 'closed') then
    if r.status = 'closed' and r.moved_in_at is not null then raise exception 'This person was already housed through this referral. Start a new referral for a new housing search.'; end if;
    update nav_referrals set status = p_to, accepted_at = coalesce(accepted_at, case when p_to = 'searching' then now() end),
           close_reason = null, closed_at = null, updated_at = now() where id = p_id;
    if p_to = 'searching' and r.accepted_at is null then perform nav_earn(r.navigator_id, 'intake', p_id, null, v_label); end if;
    perform nav_email((select email from navigators where id = r.navigator_id), 'Referral ' || v_label || ': ' || case when p_to = 'searching' then 'accepted, start the housing search' else 'under review' end,
      '<p>Referral <b>' || v_label || '</b> (' || repair_esc(v_who) || ') is now <b>' || case when p_to = 'searching' then 'accepted: search for housing' else 'under review by your office' end || '</b>.'
      || coalesce('<br>Note from your office: ' || repair_esc(v_note), '') || '</p><p>https://2ndchinc.org/navigator/</p>', 'nav_navigator');
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
    select * into r from nav_referrals where id = p_id;
    perform nav_email('info@2ndchinc.org', 'Housing Navigator: ' || v_label || ' matched, needs placement approval',
      '<p>Referral <b>' || v_label || '</b> was matched. Rent ' || to_char(r.unit_rent, 'FM$999,990.00') || ', affordability gap '
      || coalesce(to_char(nav_gap(r), 'FM$999,990.00'), 'unknown') || '. Approve or send back at https://2ndchinc.org/staff/navigators/</p>', 'nav_office');
    v_ok := true;

  elsif p_to = 'searching' and r.status in ('matched', 'approved') then
    update nav_rooms set status = 'available', updated_at = now() where id = r.nav_room_id and status = 'reserved';
    update nav_units set status = 'available', updated_at = now() where id = r.nav_unit_id and r.nav_room_id is null and status = 'reserved';
    update nav_referrals set status = 'searching', nav_unit_id = null, nav_room_id = null, rental_unit_id = null, unit_rent = null, matched_at = null,
           approved_at = null, approved_by = null, updated_at = now() where id = p_id;
    v_note := coalesce(v_note, 'Unit released; back to searching');
    v_ok := true;

  elsif p_to = 'approved' and v_role = 'staff' and r.status = 'matched' then
    v_gap := nav_gap(r);
    if v_gap is null then raise exception 'No rent on the matched unit.'; end if;
    if v_gap > 0 and v_note is null then
      raise exception 'The person is short % a month (rent minus what they can pay minus confirmed assistance). Write how the gap is covered to approve anyway.', to_char(v_gap, 'FM$999,990.00');
    end if;
    if r.income_verified_on is null and v_note is null then raise exception 'Income is not marked verified. Verify it (Edit, Income verified on) or write why you approve anyway.'; end if;
    update nav_referrals set status = 'approved', approved_at = now(), approved_by = lower(auth.email()), gap_override_note = case when v_gap > 0 then v_note end, updated_at = now() where id = p_id;
    perform nav_email((select email from navigators where id = r.navigator_id), 'Referral ' || v_label || ': placement approved',
      '<p>Your office approved the placement for <b>' || v_label || '</b> (' || repair_esc(v_who) || '). When the person moves in, record the move-in date on the portal.</p><p>https://2ndchinc.org/navigator/</p>', 'nav_navigator');
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
    perform nav_earn(r.navigator_id, 'placement', p_id, null, v_label);
    if r.nav_unit_id is not null then
      select ll.* into l from nav_units uu join nav_landlords ll on ll.id = uu.landlord_id where uu.id = r.nav_unit_id;
      if l.added_by_navigator = r.navigator_id and not exists (select 1 from nav_referrals x join nav_units xu on xu.id = x.nav_unit_id
            where xu.landlord_id = l.id and x.id <> p_id and x.moved_in_at is not null) then
        perform nav_earn(r.navigator_id, 'landlord_first', null, l.id, coalesce(l.business_name, l.name));
      end if;
    end if;
    perform nav_email('info@2ndchinc.org', 'Housing Navigator: ' || v_label || ' moved in',
      '<p>Referral <b>' || v_label || '</b> moved in on ' || to_char(v_date, 'FMMonth FMDD, YYYY') || '. Follow-ups are scheduled; any pay earned waits for your approval at https://2ndchinc.org/staff/navigators/</p>', 'nav_office');
    v_note := coalesce(v_note || ' · ', '') || 'Moved in ' || to_char(v_date, 'MM/DD/YYYY');
    v_ok := true;

  elsif p_to = 'closed' and v_role = 'staff' and r.status <> 'closed' then
    if nullif(p->>'close_reason', '') is null then raise exception 'Pick why it is closing.'; end if;
    update nav_rooms set status = 'available', updated_at = now() where id = r.nav_room_id and status in ('reserved', 'occupied');
    update nav_units set status = 'available', updated_at = now() where id = r.nav_unit_id and r.nav_room_id is null and status = 'reserved';
    update nav_referrals set status = 'closed', close_reason = p->>'close_reason', closed_at = now(), updated_at = now() where id = p_id;
    perform nav_email((select email from navigators where id = r.navigator_id), 'Referral ' || v_label || ': closed',
      '<p>Your office closed referral <b>' || v_label || '</b> (' || repair_esc(replace(p->>'close_reason', '_', ' ')) || ').' || coalesce('<br>Note: ' || repair_esc(v_note), '') || '</p>', 'nav_navigator');
    v_ok := true;
  end if;

  if not v_ok then raise exception 'That step is not allowed now (the referral is %).', replace(r.status, '_', ' '); end if;
  perform nav_log('status_' || p_to, v_note, p_id);
  return nav_referral_get(p_id);
end;
$$;

create or replace function nav_followup_save(p_id uuid, p_outcome text, p_rent_current boolean, p_note text) returns void
language plpgsql security definer set search_path = public as $$
declare f nav_followups; r nav_referrals;
begin
  select * into f from nav_followups where id = p_id;
  if not found or not nav_can_ref(f.referral_id) then raise exception 'Not found.' using errcode = '42501'; end if;
  perform set_config('nav.sample', coalesce((select case when is_sample then '1' else '0' end from nav_referrals where id = f.referral_id), '0'), true);   -- sample records never send email
  if p_outcome not in ('stable', 'concern', 'at_risk', 'left', 'unreachable') then raise exception 'Pick how the person is doing.'; end if;
  if p_outcome in ('concern', 'at_risk', 'left', 'unreachable') and length(trim(coalesce(p_note, ''))) < 5 then raise exception 'Write a short note on what is happening.'; end if;
  update nav_followups set done_on = (now() at time zone 'America/Chicago')::date, outcome = p_outcome, rent_current = p_rent_current,
         note = nullif(trim(coalesce(p_note, '')), ''), done_by = lower(auth.email()) where id = p_id;
  select * into r from nav_referrals where id = f.referral_id;
  perform nav_log('followup_' || f.mark, p_outcome || coalesce(' · ' || trim(p_note), ''), r.id);
  -- Retention pay: every check-in up to the milestone is recorded and the milestone one says still housed (in any order;
  -- nav_earn never pays the same milestone twice).
  if r.status = 'moved_in' then
    if exists (select 1 from nav_followups where referral_id = r.id and mark = 'd90' and outcome in ('stable', 'concern')) then
      perform nav_earn(r.navigator_id, 'retention_90', r.id, null, nav_ref_label(r));
    end if;
    if exists (select 1 from nav_followups where referral_id = r.id and mark = 'm12' and outcome in ('stable', 'concern')) then
      perform nav_earn(r.navigator_id, 'retention_365', r.id, null, nav_ref_label(r));
    end if;
    if f.mark = 'checkin' and p_outcome <> 'left' then perform nav_checkin_schedule(r.id, null, (now() at time zone 'America/Chicago')::date); end if;
  end if;
  if p_outcome in ('at_risk', 'left', 'unreachable') then
    perform nav_email('info@2ndchinc.org', 'Housing Navigator: ' || nav_ref_label(r) || ' check-in needs attention',
      '<p>The ' || replace(replace(replace(replace(replace(replace(f.mark, 'd30', '30-day'), 'd60', '60-day'), 'd90', '90-day stability review'), 'm6', '6-month'), 'm12', '12-month stability review'), 'checkin', 'scheduled')
      || ' check-in for <b>' || nav_ref_label(r) || '</b> says: <b>' || replace(p_outcome, '_', ' ') || '</b>.<br>' || repair_esc(coalesce(p_note, ''))
      || '</p><p>https://2ndchinc.org/staff/navigators/</p>', 'nav_office');
  end if;
end;
$$;

create or replace function nav_followup_reminders() returns int
language plpgsql security definer set search_path = public as $$
declare v_today date := (now() at time zone 'America/Chicago')::date; x record; v_n int := 0; v_list text := '';
begin
  for x in
    select f.id, f.mark, f.due_on, r.id rid, nav_ref_label(r) label, n.email, n.name
      from nav_followups f join nav_referrals r on r.id = f.referral_id left join navigators n on n.id = r.navigator_id
     where f.done_on is null and f.reminded_at is null and f.due_on <= v_today and r.status = 'moved_in' and not r.is_sample
     order by f.due_on
  loop
    perform nav_email(x.email, 'Check-in due: ' || x.label,
      '<p>Hello ' || repair_esc(split_part(coalesce(x.name, ''), ' ', 1)) || ',</p><p>The ' || replace(replace(replace(replace(replace(replace(x.mark, 'd30', '30-day'), 'd60', '60-day'), 'd90', '90-day stability review'), 'm6', '6-month'), 'm12', '12-month stability review'), 'checkin', 'scheduled')
      || ' check-in for <b>' || x.label || '</b> was due ' || to_char(x.due_on, 'FMMonth FMDD') || '. Visit or call, then record it at https://2ndchinc.org/navigator/</p>', 'nav_followup');
    v_list := v_list || '<li>' || x.label || ': ' || x.mark || ' due ' || to_char(x.due_on, 'MM/DD') || coalesce(' (' || repair_esc(x.name) || ')', '') || '</li>';
    update nav_followups set reminded_at = now() where id = x.id;
    v_n := v_n + 1;
  end loop;
  if v_n > 0 then
    perform nav_email('info@2ndchinc.org', 'Housing Navigator: ' || v_n || ' check-in' || case when v_n = 1 then '' else 's' end || ' due',
      '<ul>' || v_list || '</ul><p>https://2ndchinc.org/staff/navigators/</p>', 'nav_office');
  end if;
  return v_n;
end;
$$;

create or replace function nav_sample_load(p_navigator uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_ll uuid; v_unit uuid; v_r1 uuid; v_r2 uuid; v_r3 uuid; v_p1 uuid; v_p2 uuid; v_p3 uuid; v_p4 uuid;
        v_today date := (now() at time zone 'America/Chicago')::date; v_m0 date; v_m1 date; v_in date;
begin
  if not (staff_session_staff() or session_user not in ('authenticator', 'anon', 'authenticated', 'service_role')) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;   -- a direct database login (this migration's own load below), never the website's API roles
  if not exists (select 1 from navigators where id = p_navigator) then raise exception 'Navigator not found.'; end if;
  if exists (select 1 from nav_units where is_sample and operated_by_navigator = p_navigator) then raise exception 'This Navigator already has sample data. Remove it first.'; end if;
  perform set_config('nav.sample', '1', true);
  v_m0 := date_trunc('month', v_today)::date;          -- this month
  v_m1 := (v_m0 - interval '1 month')::date;           -- last month
  v_in := v_m1 + 4;                                    -- sample move-in: the 5th of last month

  insert into nav_landlords (name, business_name, email, phone, mailing_address, accepts_vouchers, accepts_assistance, requirements, agreement_status, agreement_on, status, shared, added_by_navigator, notes, is_sample)
  values ('Pat Sample', 'SAMPLE Northside Rentals LLC', 'sample-landlord@example.com', '(414) 555-0100', 'PO Box 100, Milwaukee, WI 53209', true, true,
          'Proof of income; no smoking inside.', 'signed', v_m1 - 10, 'active', false, p_navigator, 'SAMPLE landlord for the walkthrough.', true)
  returning id into v_ll;

  insert into nav_units (landlord_id, address, unit_label, city, zip, bedrooms, bathrooms, rent, deposit, utilities_included, accessibility, ground_floor, accepts_vouchers, pets,
                         inspection_status, inspected_on, status, notes, added_by_navigator, operated_by_navigator, lease_start, lease_end, lease_rent, room_mode, is_sample)
  values (v_ll, '1234 W Sample St', 'Upper', 'Milwaukee', '53209', 3, 1, 1100, 1100, 'Water', 'Grab bar in the bathroom', false, true, 'No pets',
          'passed', v_m1 - 3, 'occupied', 'SAMPLE unit: leased by the Navigator, 3 furnished rooms.', p_navigator, p_navigator, v_m1, (v_m1 + interval '1 year' - interval '1 day')::date, 1100, true, true)
  returning id into v_unit;

  insert into nav_rooms (unit_id, label, monthly_rate, deposit, furnished, status, sort) values (v_unit, 'Room 1 (front)', 550, 550, true, 'occupied', 1) returning id into v_r1;
  insert into nav_rooms (unit_id, label, monthly_rate, deposit, furnished, status, sort) values (v_unit, 'Room 2 (middle)', 550, 550, true, 'reserved', 2) returning id into v_r2;
  insert into nav_rooms (unit_id, label, monthly_rate, deposit, furnished, status, sort) values (v_unit, 'Room 3 (back)', 525, 525, true, 'available', 3) returning id into v_r3;

  -- 1. Housed (Room 1): a veteran on VA benefits with HUD-VASH help; 30-day check-in done.
  insert into nav_referrals (navigator_id, first_name, last_name, phone, reach_note, pathway, housing_situation, veteran, household_size, bedrooms_needed,
      income_monthly, income_sources, income_verified_on, contribution_monthly, assistance_monthly, assistance_source, assistance_confirmed, areas, accessibility_needs,
      support_name, support_agency, consent_name, consent_on, consent_version, status, nav_unit_id, nav_room_id, unit_rent, move_in_on,
      submitted_at, accepted_at, matched_at, approved_at, approved_by, moved_in_at, is_sample)
  values (p_navigator, 'SAMPLE James', 'Veteran', '(414) 555-0111', 'Guest House shelter, front desk', 'veteran', 'shelter', true, 1, 1,
      1250, '{va}', v_m1 - 6, 450, 100, 'HUD-VASH', true, 'North side, near a bus line', 'No ladders; bad knee',
      'Sample Caseworker', 'VA Medical Center', 'SAMPLE James Veteran', v_m1 - 12, 'nav-consent-2026-11', 'moved_in', v_unit, v_r1, 550, v_in,
      (v_m1 - 12)::timestamptz, (v_m1 - 10)::timestamptz, (v_m1 - 8)::timestamptz, (v_m1 - 6)::timestamptz, 'office (sample)', v_in::timestamptz, true)
  returning id into v_p1;
  update nav_referrals set checkin_every = 'weekly', checkin_note = 'Daily the first week, now weekly while he settles in.' where id = v_p1;
  insert into nav_followups (referral_id, mark, due_on, done_on, outcome, rent_current, note, done_by) values
    (v_p1, 'checkin', v_in + 1, v_in + 1, 'stable', true, 'First night went well. Showed him the bus stop.', 'sample'),
    (v_p1, 'checkin', v_in + 7, v_in + 7, 'concern', true, 'Lonely; connected him with the VA peer group.', 'sample'),
    (v_p1, 'checkin', v_in + 14, v_in + 14, 'stable', true, 'Settled in; likes his room. Attending VA appointments.', 'sample'),
    (v_p1, 'checkin', v_today + 2, null, null, null, null, null),
    (v_p1, 'd90', v_in + 90, null, null, null, null, null), (v_p1, 'm12', (v_in + interval '12 months')::date, null, null, null, null, null);
  update nav_referrals set next_checkin_on = v_today + 2 where id = v_p1;

  -- 2. Matched to Room 2, waiting for the office to approve: an older adult on Social Security with county help.
  insert into nav_referrals (navigator_id, first_name, last_name, phone, reach_note, pathway, housing_situation, veteran, household_size, bedrooms_needed,
      income_monthly, income_sources, contribution_monthly, assistance_monthly, assistance_source, assistance_confirmed, move_in_by, accessibility_needs,
      consent_name, consent_on, consent_version, status, nav_unit_id, nav_room_id, unit_rent, submitted_at, accepted_at, matched_at, is_sample)
  values (p_navigator, 'SAMPLE Mary', 'Senior', '(414) 555-0122', 'Staying with her niece', 'senior', 'doubled_up', false, 1, 1,
      1050, '{ss}', 400, 150, 'Milwaukee County', true, v_today + 14, 'Needs a room near the bathroom',
      'SAMPLE Mary Senior', v_today - 9, 'nav-consent-2026-11', 'matched', v_unit, v_r2, 550, (v_today - 9)::timestamptz, (v_today - 7)::timestamptz, (v_today - 2)::timestamptz, true)
  returning id into v_p2;

  -- 3. Submitted, waiting for the office: a person on SSI, rent would be short (shows the gap check).
  insert into nav_referrals (navigator_id, first_name, last_name, phone, pathway, housing_situation, household_size, bedrooms_needed,
      income_monthly, income_sources, contribution_monthly, consent_name, consent_on, consent_version, status, submitted_at, is_sample)
  values (p_navigator, 'SAMPLE Robert', 'Example', '(414) 555-0133', 'benefits', 'street', 1, 1,
      967, '{ssi}', 325, 'SAMPLE Robert Example', v_today - 1, 'nav-consent-2026-11', 'submitted', (v_today - 1)::timestamptz, true)
  returning id into v_p3;

  -- 4. Draft: just started, no consent yet.
  insert into nav_referrals (navigator_id, first_name, last_name, reach_note, pathway, housing_situation, household_size, status, is_sample)
  values (p_navigator, 'SAMPLE Linda', 'Example', 'Met at the food pantry', 'family', 'at_risk', 3, 'draft', true)
  returning id into v_p4;

  insert into nav_events (referral_id, navigator_id, actor, actor_role, action, detail) values
    (v_p1, p_navigator, 'sample', 'navigator', 'note', 'Met James at the shelter; he wants a quiet room on a bus line.'),
    (v_p1, p_navigator, 'sample', 'staff', 'status_approved', 'Rent covered: pays $450 + $100 HUD-VASH = $550.'),
    (v_p2, p_navigator, 'sample', 'navigator', 'note', 'Mary saw Room 2 and liked it. Niece will help her move.'),
    (v_p3, p_navigator, 'sample', 'navigator', 'note', 'Robert can pay $325; looking for help with the rest.');

  -- Money: last month (start-up + first month) and this month.
  insert into nav_unit_money (unit_id, room_id, referral_id, kind, category, amount, entry_date, party, description, created_by) values
    (v_unit, null, null, 'expense', 'deposit_paid', 1100, v_m1 - 3, 'SAMPLE Northside Rentals', 'Security deposit to the landlord', 'sample'),
    (v_unit, null, null, 'expense', 'rent_to_landlord', 1100, v_m1, 'SAMPLE Northside Rentals', 'Rent, first month', 'sample'),
    (v_unit, null, null, 'expense', 'furniture', 1240, v_m1 + 1, 'Furniture store', '3 twin beds, mattresses, dressers', 'sample'),
    (v_unit, null, null, 'expense', 'appliances', 650, v_m1 + 2, 'Appliance store', 'Used washer and dryer', 'sample'),
    (v_unit, null, null, 'expense', 'household', 180, v_m1 + 2, 'Department store', 'Bedding, towels, kitchen basics', 'sample'),
    (v_unit, null, null, 'expense', 'utilities', 210, v_m1 + 20, 'We Energies', 'Gas and electric', 'sample'),
    (v_unit, null, null, 'expense', 'internet_phone', 70, v_m1 + 20, 'Internet provider', 'Wi-Fi', 'sample'),
    (v_unit, v_r1, v_p1, 'income', 'resident_rent', 450, v_in, 'SAMPLE James Veteran', 'Room 1 rent', 'sample'),
    (v_unit, v_r1, v_p1, 'income', 'va_payment', 100, v_in + 3, 'HUD-VASH', 'Room 1 rent share', 'sample'),
    (v_unit, null, null, 'expense', 'rent_to_landlord', 1100, v_m0, 'SAMPLE Northside Rentals', 'Rent', 'sample'),
    (v_unit, v_r1, v_p1, 'income', 'resident_rent', 450, v_m0, 'SAMPLE James Veteran', 'Room 1 rent', 'sample'),
    (v_unit, v_r1, v_p1, 'income', 'va_payment', 100, v_m0 + 2, 'HUD-VASH', 'Room 1 rent share', 'sample'),
    (v_unit, null, null, 'expense', 'repairs', 85, v_m0 + 3, 'Hardware store', 'Bathroom faucet cartridge', 'sample');

  insert into nav_unit_budget (unit_id, category, frequency, amount) values
    (v_unit, 'rent_to_landlord', 'monthly', 1100), (v_unit, 'utilities', 'monthly', 225), (v_unit, 'internet_phone', 'monthly', 70),
    (v_unit, 'repairs', 'monthly', 75), (v_unit, 'cleaning', 'monthly', 40), (v_unit, 'household', 'monthly', 30),
    (v_unit, 'resident_rent', 'monthly', 1625),
    (v_unit, 'furniture', 'one_time', 1500), (v_unit, 'appliances', 'one_time', 800), (v_unit, 'deposit_paid', 'one_time', 1100), (v_unit, 'household', 'one_time', 250);

  perform set_config('nav.sample', '0', true);
  return jsonb_build_object('landlord', v_ll, 'unit', v_unit, 'referrals', 4);
end;
$$;

-- The sample person already loaded: same plan as a fresh load.
do $$
declare v uuid; v_today date := (now() at time zone 'America/Chicago')::date;
begin
  for v in select id from nav_referrals where is_sample and status = 'moved_in' loop
    delete from nav_followups where referral_id = v and done_on is null and mark in ('d30', 'd60', 'm6');
    update nav_followups set mark = 'checkin' where referral_id = v and mark = 'd30';
    update nav_referrals set checkin_every = 'weekly', checkin_note = 'Daily the first week, now weekly while he settles in.' where id = v;
    perform nav_checkin_schedule(v, v_today + 2, v_today);
  end loop;
end;
$$;

-- Pay milestone wording follows the stability reviews.
update nav_pay_plan set description = 'The 90-day stability review is done and the person is still housed.' where key = 'retention_90';
update nav_pay_plan set description = 'The 12-month stability review is done and the person is still housed.' where key = 'retention_365';
