-- Navigator-facing emails say "your office", not "the office" (Stephen, 11/11/2026).

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
    insert into nav_followups (referral_id, mark, due_on) values
      (p_id, 'd30', v_date + 30), (p_id, 'd60', v_date + 60), (p_id, 'd90', v_date + 90), (p_id, 'm6', (v_date + interval '6 months')::date), (p_id, 'm12', (v_date + interval '12 months')::date)
      on conflict do nothing;
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
