-- Virtual parking lot (Stephen, 10/7/2026). 16 units, 16 stalls, every stall clearly marked with its unit number
-- (1–8 at 6626 N Bourbon, 11–18 at 6622 N Bourbon), plus extra labeled GUEST and CONTRACTOR stalls that the office
-- adds and labels on the staff Parking page (none seeded: their number isn't on file). There are never parking
-- disputes, so there is no violations log. The map exists because occupants sometimes switch stalls for a while:
--   * Temporary switch: the occupant of one unit asks the occupant of another unit to trade stalls for some dates. The
--     other side accepts or declines in their portal; staff can also record a switch both sides agreed to in person.
--     Either side, or staff, can end it early. Both sides and the office are emailed at every step.
--   * Holds: a guest or contractor stall held for a date range, for an approved guest parking request (the decal
--     hand-over stays on the guest request) or for a contractor.
-- Occupants (tenants on an active lease; owners of an owner-occupied unit) can switch. Every tenant and owner can see
-- the map with unit numbers and vehicle descriptions only, as on "Vehicles in the building"; names, emails and plates
-- are for staff.

create table if not exists parking_stalls (
  id uuid primary key default gen_random_uuid(),
  label text not null unique,                 -- what is painted on the stall: '8', 'G1', 'C1'
  kind text not null check (kind in ('unit', 'guest', 'contractor')),
  home_unit text unique,                      -- unit stalls: the unit number the stall belongs to
  map_row int not null default 1,
  map_pos int not null default 1,
  note text,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check ((kind = 'unit') = (home_unit is not null))
);
alter table parking_stalls enable row level security;

insert into parking_stalls (label, kind, home_unit, map_row, map_pos)
select u, 'unit', u, case when u::int <= 8 then 1 else 2 end, case when u::int <= 8 then u::int else u::int - 10 end
from unnest(array['1', '2', '3', '4', '5', '6', '7', '8', '11', '12', '13', '14', '15', '16', '17', '18']) u
on conflict (label) do nothing;

create table if not exists parking_swaps (
  id uuid primary key default gen_random_uuid(),
  unit_a text not null,                       -- asked for the switch
  unit_b text not null,                       -- was asked
  start_date date not null,
  end_date date not null,                     -- last day of the switch (shortened when ended early)
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined', 'cancelled', 'ended')),
  requested_kind text not null check (requested_kind in ('tenant', 'owner', 'staff')),
  requested_by text, requested_name text,
  note text,
  decided_by text, decided_at timestamptz, decision_note text,
  ended_by text, ended_at timestamptz, end_note text,
  created_at timestamptz not null default now(),
  check (unit_a <> unit_b),
  check (end_date >= start_date)
);
create index if not exists parking_swaps_units_idx on parking_swaps (unit_a, unit_b, start_date);
alter table parking_swaps enable row level security;

create table if not exists parking_holds (
  id uuid primary key default gen_random_uuid(),
  stall_id uuid not null references parking_stalls(id),
  holder_kind text not null check (holder_kind in ('guest', 'contractor', 'other')),
  guest_request_id uuid references guest_requests(id),
  holder_name text,                           -- guest's or contractor's name
  company text,
  for_unit text,                              -- the unit the guest is visiting or the contractor is working in
  vehicle text, plate text, plate_state text,
  start_date date not null,
  end_date date not null,
  status text not null default 'active' check (status in ('active', 'ended', 'cancelled')),
  note text,
  created_by text, created_at timestamptz not null default now(),
  ended_by text, ended_at timestamptz,
  check (end_date >= start_date)
);
create index if not exists parking_holds_stall_idx on parking_holds (stall_id, start_date);
alter table parking_holds enable row level security;
-- No policies on any of the three: everything goes through the functions below.

-- ---------------------------------------------------------------------------
-- Who is who

-- Units the signed-in person occupies (and so can switch): active-lease tenants, and owners of owner-occupied units.
create or replace function parking_my_units()
returns table (unit_number text, kind text)
language sql stable security definer set search_path = public as $$
  select u, 'tenant' from vehicle_my_units() u where exists (select 1 from parking_stalls s where s.home_unit = u and s.active)
  union
  select cu.unit_number, 'owner' from condo_ownerships s join condo_units cu on cu.id = s.unit_id
   where s.is_current and cu.occupancy = 'owner' and s.owner_id = condo_owner_for_email(auth.email()) and condo_session_ok()
     and exists (select 1 from parking_stalls st where st.home_unit = cu.unit_number and st.active);
$$;
revoke all on function parking_my_units() from public, anon;
grant execute on function parking_my_units() to authenticated;

-- The people living in a unit: tenants on the active lease, or the owner when the unit is owner-occupied.
create or replace function parking_unit_people(p_unit text)
returns table (name text, email text, kind text)
language sql stable security definer set search_path = public as $$
  select t.name, lower(t.email), 'tenant' from leases l join rental_units ru on ru.id = l.unit_id
    join lease_tenants lt on lt.lease_id = l.id join tenants t on t.id = lt.tenant_id
   where l.status = 'active' and ru.unit_number = p_unit
  union
  select o.name, lower(o.email), 'owner' from condo_units cu join condo_ownerships s on s.unit_id = cu.id and s.is_current
    join condo_owners o on o.id = s.owner_id
   where cu.unit_number = p_unit and cu.occupancy = 'owner';
$$;
revoke all on function parking_unit_people(text) from public, anon, authenticated;

create or replace function parking_email_unit(p_unit text, p_subject text, p_body text)
returns int
language plpgsql volatile security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in select distinct on (email) name, email from parking_unit_people(p_unit) where email is not null and email like '%@%' loop
    insert into email_outbox (to_email, subject, html, kind) values (r.email, p_subject,
      '<p>Hi ' || repair_esc(split_part(coalesce(r.name, ''), ' ', 1)) || ',</p>' || p_body || '<p>2nd Chance Housing</p>', 'parking');
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke all on function parking_email_unit(text, text, text) from public, anon, authenticated;

create or replace function parking_d(p date) returns text language sql immutable as $$ select to_char(p, 'FMMM/FMDD/YYYY'); $$;

-- True when either unit already has a pending or accepted switch overlapping these dates.
create or replace function parking_swap_conflict(p_a text, p_b text, p_start date, p_end date, p_exclude uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from parking_swaps w
    where w.id is distinct from p_exclude and w.status in ('pending', 'accepted', 'ended')
      and (w.unit_a in (p_a, p_b) or w.unit_b in (p_a, p_b))
      and w.start_date <= p_end and w.end_date >= p_start
      and not (w.status = 'ended' and w.end_date < w.start_date));
$$;
revoke all on function parking_swap_conflict(text, text, date, date, uuid) from public, anon, authenticated;

create or replace function parking_swap_validate(p_a text, p_b text, p_start date, p_end date)
returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if p_a = p_b then raise exception 'Choose a different unit to switch with.'; end if;
  if not exists (select 1 from parking_stalls where home_unit = p_a and active) then raise exception 'Unit % has no stall on the map.', p_a; end if;
  if not exists (select 1 from parking_stalls where home_unit = p_b and active) then raise exception 'Unit % has no stall on the map.', p_b; end if;
  if p_start is null or p_end is null or p_end < p_start then raise exception 'Enter the first and last day of the switch.'; end if;
  if p_end - p_start > 180 then raise exception 'A switch can last up to 180 days. Ask again when it ends.'; end if;
end;
$$;
revoke all on function parking_swap_validate(text, text, date, date) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- The lot on a given day. p_staff adds names, emails, plates and notes.
create or replace function parking_lot_core(p_date date, p_staff boolean)
returns jsonb
language sql stable security definer set search_path = public as $$
  with sw as (
    select w.*, s.home_unit from parking_stalls s join parking_swaps w
      on (w.unit_a = s.home_unit or w.unit_b = s.home_unit)
     where s.kind = 'unit' and w.status in ('accepted', 'ended') and p_date between w.start_date and w.end_date
  ), st as (
    select s.*, coalesce((select case when w.unit_a = s.home_unit then w.unit_b else w.unit_a end from sw w where w.home_unit = s.home_unit limit 1), s.home_unit) as used_by,
      (select w.id from sw w where w.home_unit = s.home_unit limit 1) as swap_id
    from parking_stalls s where s.active
  )
  select jsonb_build_object('date', p_date, 'stalls', coalesce(jsonb_agg(jsonb_build_object(
      'id', st.id, 'label', st.label, 'kind', st.kind, 'home_unit', st.home_unit, 'row', st.map_row, 'pos', st.map_pos,
      'used_by', case when st.kind = 'unit' then st.used_by end,
      'occupancy', (select occupancy from condo_units where unit_number = st.home_unit),
      'swap', (select jsonb_build_object('id', w.id, 'unit_a', w.unit_a, 'unit_b', w.unit_b, 'start_date', w.start_date, 'end_date', w.end_date)
                 || case when p_staff then jsonb_build_object('requested_name', w.requested_name, 'requested_kind', w.requested_kind, 'note', w.note) else '{}'::jsonb end
               from parking_swaps w where w.id = st.swap_id),
      'vehicles', case when st.kind = 'unit' then coalesce((select jsonb_agg(
          case when p_staff then jsonb_build_object('id', v.id, 'kind', v.kind, 'summary', vehicle_summary(v), 'tenant', (select name from tenants where id = v.tenant_id))
          else jsonb_build_object('kind', v.kind, 'make', v.make, 'model', v.model, 'color', v.color, 'year', v.year,
                                  'visitor_frequency', case when v.kind = 'visitor' then v.visitor_frequency end) end order by v.kind)
        from vehicles v where v.unit_number = st.used_by and v.status = 'active'), '[]'::jsonb) else '[]'::jsonb end,
      'people', case when p_staff and st.kind = 'unit' then (select coalesce(jsonb_agg(jsonb_build_object('name', p.name, 'email', p.email, 'kind', p.kind)), '[]'::jsonb) from parking_unit_people(st.used_by) p) end,
      'hold', (select case when p_staff then to_jsonb(h) || jsonb_build_object('guest', (select jsonb_build_object('guest_name', g.guest_name, 'unit', g.unit_number,
                     'decal_number', g.decal_number, 'requester_name', g.requester_name) from guest_requests g where g.id = h.guest_request_id))
                else jsonb_build_object('holder_kind', h.holder_kind, 'for_unit', h.for_unit, 'vehicle', h.vehicle, 'start_date', h.start_date, 'end_date', h.end_date) end
               from parking_holds h where h.stall_id = st.id and h.status in ('active', 'ended') and p_date between h.start_date and h.end_date
               order by h.created_at desc limit 1),
      'note', case when p_staff then st.note end)
    order by st.map_row, st.map_pos, st.label), '[]'::jsonb))
  from st;
$$;
revoke all on function parking_lot_core(date, boolean) from public, anon, authenticated;

create or replace function parking_swap_row(w parking_swaps, p_staff boolean)
returns jsonb
language sql stable security definer set search_path = public as $$
  select case when p_staff then to_jsonb(w) else to_jsonb(w) - 'requested_by' - 'decided_by' - 'ended_by' - 'requested_name' end;
$$;
revoke all on function parking_swap_row(parking_swaps, boolean) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Tenants and owners
create or replace function parking_lot_mine(p_date date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not vehicle_can_view() then raise exception 'Resident or owner sign-in required' using errcode = '42501'; end if;
  return parking_lot_core(coalesce(p_date, current_date), false) || jsonb_build_object(
    'my_units', coalesce((select jsonb_agg(jsonb_build_object('unit', unit_number, 'kind', kind) order by unit_number) from parking_my_units()), '[]'::jsonb),
    'office_phone', (select value from portal_settings where key = 'org_phone'),
    'unit_stalls', coalesce((select jsonb_agg(home_unit order by map_row, map_pos) from parking_stalls where kind = 'unit' and active), '[]'::jsonb),
    'swaps', coalesce((select jsonb_agg(parking_swap_row(w, false) order by w.start_date desc) from parking_swaps w
      where (w.unit_a in (select unit_number from parking_my_units()) or w.unit_b in (select unit_number from parking_my_units()))
        and (w.status = 'pending' or (w.status in ('accepted', 'ended') and w.end_date >= current_date - 30))), '[]'::jsonb));
end;
$$;
revoke all on function parking_lot_mine(date) from public, anon;
grant execute on function parking_lot_mine(date) to authenticated;

create or replace function parking_swap_request(p_my_unit text, p_other_unit text, p_start date, p_end date, p_note text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_kind text; v_name text; w parking_swaps; v_n int;
begin
  select kind into v_kind from parking_my_units() where unit_number = p_my_unit order by kind = 'tenant' desc limit 1;
  if v_kind is null then raise exception 'You can only switch the stall of the unit you live in.' using errcode = '42501'; end if;
  p_other_unit := trim(p_other_unit);
  perform parking_swap_validate(p_my_unit, p_other_unit, p_start, p_end);
  if p_start < current_date then raise exception 'The first day can''t be in the past.'; end if;
  if not exists (select 1 from parking_unit_people(p_other_unit) where email like '%@%') then
    raise exception 'Nobody at Unit % can answer online. Call the office to arrange it.', p_other_unit; end if;
  if parking_swap_conflict(p_my_unit, p_other_unit, p_start, p_end, null) then
    raise exception 'One of the two units already has a switch on some of those days.'; end if;
  select name into v_name from parking_unit_people(p_my_unit) where email = lower(auth.email()) limit 1;
  insert into parking_swaps (unit_a, unit_b, start_date, end_date, requested_kind, requested_by, requested_name, note)
  values (p_my_unit, p_other_unit, p_start, p_end, v_kind, lower(auth.email()), v_name, left(nullif(trim(coalesce(p_note, '')), ''), 500))
  returning * into w;
  v_n := parking_email_unit(w.unit_b, 'Unit ' || w.unit_a || ' asks to switch parking stalls',
    '<p>The resident of <b>Unit ' || repair_esc(w.unit_a) || '</b> asks to switch parking stalls with your unit from <b>' || parking_d(w.start_date) || '</b> to <b>'
    || parking_d(w.end_date) || '</b>: you would park in stall ' || repair_esc(w.unit_a) || ' and they would park in stall ' || repair_esc(w.unit_b) || '.</p>'
    || case when w.note is not null then '<p>Their note: ' || repair_esc(w.note) || '</p>' else '' end
    || '<p>Accept or decline it on the Parking page of your portal. Nothing changes unless you accept.</p>');
  perform vehicle_alert('Stall switch asked — Units ' || w.unit_a || ' and ' || w.unit_b,
    '<p>Unit ' || repair_esc(w.unit_a) || ' (' || repair_esc(coalesce(v_name, auth.email())) || ') asks Unit ' || repair_esc(w.unit_b) || ' to switch stalls, '
    || parking_d(w.start_date) || ' to ' || parking_d(w.end_date) || '. Waiting for Unit ' || repair_esc(w.unit_b) || ' to answer.</p>');
  return parking_swap_row(w, false);
end;
$$;
revoke all on function parking_swap_request(text, text, date, date, text) from public, anon;
grant execute on function parking_swap_request(text, text, date, date, text) to authenticated;

create or replace function parking_swap_respond(p_id uuid, p_accept boolean, p_note text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare w parking_swaps; v_word text;
begin
  select * into w from parking_swaps where id = p_id for update;
  if w.id is null or w.unit_b not in (select unit_number from parking_my_units()) then raise exception 'That switch request isn''t for your unit.' using errcode = '42501'; end if;
  if w.status <> 'pending' then raise exception 'This request was already %.', w.status; end if;
  if p_accept and w.end_date < current_date then raise exception 'These dates have passed.'; end if;
  if p_accept and parking_swap_conflict(w.unit_a, w.unit_b, w.start_date, w.end_date, w.id) then
    raise exception 'One of the two units already has a switch on some of those days.'; end if;
  update parking_swaps set status = case when p_accept then 'accepted' else 'declined' end, decided_by = lower(auth.email()), decided_at = now(),
    decision_note = left(nullif(trim(coalesce(p_note, '')), ''), 500)
   where id = p_id returning * into w;
  v_word := case when p_accept then 'accepted' else 'declined' end;
  perform parking_email_unit(w.unit_a, 'Stall switch ' || v_word || ' by Unit ' || w.unit_b,
    '<p>Unit ' || repair_esc(w.unit_b) || ' <b>' || v_word || '</b> your request to switch parking stalls, ' || parking_d(w.start_date) || ' to ' || parking_d(w.end_date) || '.</p>'
    || case when p_accept then '<p>On those days you park in <b>stall ' || repair_esc(w.unit_b) || '</b>, and Unit ' || repair_esc(w.unit_b) || ' parks in stall ' || repair_esc(w.unit_a) || '. Your own stall is yours again the day after.</p>' else '' end
    || case when w.decision_note is not null then '<p>Their note: ' || repair_esc(w.decision_note) || '</p>' else '' end);
  if p_accept then
    perform parking_email_unit(w.unit_b, 'Stall switch confirmed with Unit ' || w.unit_a,
      '<p>You accepted the switch: from ' || parking_d(w.start_date) || ' to ' || parking_d(w.end_date) || ' you park in <b>stall ' || repair_esc(w.unit_a) || '</b>, and Unit '
      || repair_esc(w.unit_a) || ' parks in stall ' || repair_esc(w.unit_b) || '.</p>');
  end if;
  perform vehicle_alert('Stall switch ' || v_word || ' — Units ' || w.unit_a || ' and ' || w.unit_b,
    '<p>Unit ' || repair_esc(w.unit_b) || ' ' || v_word || ' switching stalls with Unit ' || repair_esc(w.unit_a) || ', ' || parking_d(w.start_date) || ' to ' || parking_d(w.end_date) || '.</p>'
    || '<p>The parking map shows it: https://2ndchinc.org/parking/</p>');
  return parking_swap_row(w, false);
end;
$$;
revoke all on function parking_swap_respond(uuid, boolean, text) from public, anon;
grant execute on function parking_swap_respond(uuid, boolean, text) to authenticated;

-- Either unit (or staff) ends a switch. A pending request or one that hasn't started yet is cancelled; one in progress
-- ends today (today still counts as switched), so each unit is back in its own stall tomorrow.
create or replace function parking_swap_end(p_id uuid, p_note text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare w parking_swaps; v_staff boolean := staff_session_staff(); v_msg text;
begin
  select * into w from parking_swaps where id = p_id for update;
  if w.id is null then raise exception 'Switch not found'; end if;
  if not v_staff and not exists (select 1 from parking_my_units() where unit_number in (w.unit_a, w.unit_b)) then
    raise exception 'That switch isn''t for your unit.' using errcode = '42501'; end if;
  if w.status = 'pending' then
    if not v_staff and w.unit_a not in (select unit_number from parking_my_units()) then raise exception 'Decline it instead.'; end if;
  elsif w.status <> 'accepted' or w.end_date < current_date then raise exception 'This switch is already over.';
  end if;
  if w.status = 'pending' or w.start_date > current_date then
    update parking_swaps set status = 'cancelled', ended_by = lower(auth.email()), ended_at = now(), end_note = nullif(trim(coalesce(p_note, '')), '') where id = p_id returning * into w;
    v_msg := '<p>The stall switch between Units ' || repair_esc(w.unit_a) || ' and ' || repair_esc(w.unit_b) || ' (' || parking_d(w.start_date) || ' to ' || parking_d(w.end_date) || ') was <b>cancelled</b>. Each unit keeps its own stall.</p>';
  else
    update parking_swaps set status = 'ended', end_date = current_date, ended_by = lower(auth.email()), ended_at = now(), end_note = nullif(trim(coalesce(p_note, '')), '') where id = p_id returning * into w;
    v_msg := '<p>The stall switch between Units ' || repair_esc(w.unit_a) || ' and ' || repair_esc(w.unit_b) || ' <b>ends today</b>, ' || parking_d(current_date) || '. From tomorrow each unit parks in its own stall again.</p>';
  end if;
  v_msg := v_msg || case when w.end_note is not null then '<p>Note: ' || repair_esc(w.end_note) || '</p>' else '' end;
  perform parking_email_unit(w.unit_a, 'Stall switch ' || w.status || ' — Units ' || w.unit_a || ' and ' || w.unit_b, v_msg);
  if w.decided_at is not null or w.requested_kind = 'staff' then
    perform parking_email_unit(w.unit_b, 'Stall switch ' || w.status || ' — Units ' || w.unit_a || ' and ' || w.unit_b, v_msg);
  end if;
  perform vehicle_alert('Stall switch ' || w.status || ' — Units ' || w.unit_a || ' and ' || w.unit_b, v_msg || '<p>By ' || repair_esc(auth.email()) || '.</p>');
  return parking_swap_row(w, v_staff);
end;
$$;
revoke all on function parking_swap_end(uuid, text) from public, anon;
grant execute on function parking_swap_end(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Staff
create or replace function parking_lot_staff(p_date date)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return parking_lot_core(coalesce(p_date, current_date), true) || jsonb_build_object(
    'all_stalls', coalesce((select jsonb_agg(to_jsonb(s) order by s.active desc, s.map_row, s.map_pos, s.label) from parking_stalls s), '[]'::jsonb),
    'swaps', coalesce((select jsonb_agg(parking_swap_row(w, true) order by w.status <> 'pending', w.start_date desc) from parking_swaps w
      where w.status = 'pending' or (w.status in ('accepted', 'ended') and w.end_date >= current_date - 30)), '[]'::jsonb),
    'holds', coalesce((select jsonb_agg(to_jsonb(h) || jsonb_build_object('stall', s.label, 'stall_kind', s.kind) order by h.start_date) from parking_holds h join parking_stalls s on s.id = h.stall_id
      where h.status = 'active' and h.end_date >= current_date), '[]'::jsonb),
    'guest_requests', coalesce((select jsonb_agg(jsonb_build_object('id', g.id, 'unit', g.unit_number, 'guest_name', g.guest_name, 'start_date', g.start_date, 'end_date', g.end_date,
        'vehicle', concat_ws(' ', g.vehicle_color, g.vehicle_make, g.vehicle_model), 'plate', g.plate, 'plate_state', g.plate_state, 'decal_number', g.decal_number) order by g.start_date)
      from guest_requests g where g.status = 'approved' and g.parking and g.end_date >= current_date
        and not exists (select 1 from parking_holds h where h.guest_request_id = g.id and h.status = 'active')), '[]'::jsonb));
end;
$$;
revoke all on function parking_lot_staff(date) from public, anon;
grant execute on function parking_lot_staff(date) to authenticated;

-- A switch both sides agreed to (in person or by phone). Takes effect at once; both units are emailed.
create or replace function parking_swap_staff_record(p_a text, p_b text, p_start date, p_end date, p_note text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare w parking_swaps; v_msg text;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  p_a := trim(p_a); p_b := trim(p_b);
  perform parking_swap_validate(p_a, p_b, p_start, p_end);
  if p_end < current_date then raise exception 'Those dates have passed.'; end if;
  if parking_swap_conflict(p_a, p_b, p_start, p_end, null) then raise exception 'One of the two units already has a switch on some of those days.'; end if;
  insert into parking_swaps (unit_a, unit_b, start_date, end_date, status, requested_kind, requested_by, requested_name, note, decided_by, decided_at)
  values (p_a, p_b, p_start, p_end, 'accepted', 'staff', lower(auth.email()), 'Office', left(nullif(trim(coalesce(p_note, '')), ''), 500), lower(auth.email()), now())
  returning * into w;
  v_msg := '<p>The office recorded the parking stall switch you agreed to: from <b>' || parking_d(w.start_date) || '</b> to <b>' || parking_d(w.end_date) || '</b>, Unit '
    || repair_esc(w.unit_a) || ' parks in stall ' || repair_esc(w.unit_b) || ' and Unit ' || repair_esc(w.unit_b) || ' parks in stall ' || repair_esc(w.unit_a)
    || '. Either of you can end it early on the Parking page of your portal.</p>';
  perform parking_email_unit(w.unit_a, 'Stall switch recorded — Units ' || w.unit_a || ' and ' || w.unit_b, v_msg);
  perform parking_email_unit(w.unit_b, 'Stall switch recorded — Units ' || w.unit_a || ' and ' || w.unit_b, v_msg);
  return parking_swap_row(w, true);
end;
$$;
revoke all on function parking_swap_staff_record(text, text, date, date, text) from public, anon;
grant execute on function parking_swap_staff_record(text, text, date, date, text) to authenticated;

-- Hold a guest or contractor stall. For a guest, pass the approved guest parking request; its dates and vehicle are used.
create or replace function parking_hold_create(p_stall uuid, p_kind text, p_guest_request uuid, p_name text, p_company text, p_for_unit text,
  p_vehicle text, p_plate text, p_plate_state text, p_start date, p_end date, p_note text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare s parking_stalls; g guest_requests; h parking_holds;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into s from parking_stalls where id = p_stall and active;
  if s.id is null then raise exception 'Choose a stall.'; end if;
  if s.kind = 'unit' then raise exception 'Stall % belongs to Unit %. Hold a guest or contractor stall.', s.label, s.home_unit; end if;
  if p_kind not in ('guest', 'contractor', 'other') then raise exception 'Choose who the stall is held for.'; end if;
  if p_guest_request is not null then
    select * into g from guest_requests where id = p_guest_request;
    if g.id is null or g.status <> 'approved' or not g.parking then raise exception 'Only an approved guest parking request can hold a stall.'; end if;
    p_kind := 'guest'; p_name := coalesce(nullif(trim(coalesce(p_name, '')), ''), g.guest_name); p_for_unit := coalesce(nullif(trim(coalesce(p_for_unit, '')), ''), g.unit_number);
    p_vehicle := coalesce(nullif(trim(coalesce(p_vehicle, '')), ''), nullif(concat_ws(' ', g.vehicle_color, g.vehicle_make, g.vehicle_model), ''));
    p_plate := coalesce(nullif(trim(coalesce(p_plate, '')), ''), g.plate); p_plate_state := coalesce(nullif(trim(coalesce(p_plate_state, '')), ''), g.plate_state);
    p_start := coalesce(p_start, g.start_date); p_end := coalesce(p_end, g.end_date);
  end if;
  if length(coalesce(trim(p_name), '')) < 2 and length(coalesce(trim(p_company), '')) < 2 then raise exception 'Enter the name (or the contractor''s company).'; end if;
  if p_start is null or p_end is null or p_end < p_start then raise exception 'Enter the first and last day.'; end if;
  if p_end < current_date then raise exception 'Those dates have passed.'; end if;
  if p_end - p_start > 120 then raise exception 'A hold can last up to 120 days.'; end if;
  if exists (select 1 from parking_holds x where x.stall_id = s.id and x.status in ('active', 'ended') and x.start_date <= p_end and x.end_date >= p_start
             and not (x.status = 'ended' and x.end_date < x.start_date)) then
    raise exception 'Stall % is already held on some of those days.', s.label; end if;
  insert into parking_holds (stall_id, holder_kind, guest_request_id, holder_name, company, for_unit, vehicle, plate, plate_state, start_date, end_date, note, created_by)
  values (s.id, p_kind, p_guest_request, nullif(trim(coalesce(p_name, '')), ''), nullif(trim(coalesce(p_company, '')), ''), nullif(trim(coalesce(p_for_unit, '')), ''),
    nullif(trim(coalesce(p_vehicle, '')), ''), upper(nullif(trim(coalesce(p_plate, '')), '')), upper(nullif(trim(coalesce(p_plate_state, '')), '')),
    p_start, p_end, left(nullif(trim(coalesce(p_note, '')), ''), 500), lower(auth.email()))
  returning * into h;
  if g.id is not null and g.requester_email is not null then
    insert into email_outbox (to_email, subject, html, kind) values (g.requester_email, 'Guest parking stall ' || s.label || ' — ' || g.guest_name,
      '<p>Hi ' || repair_esc(split_part(coalesce(g.requester_name, ''), ' ', 1)) || ',</p><p>Your guest <b>' || repair_esc(g.guest_name) || '</b> parks in <b>guest stall '
      || repair_esc(s.label) || '</b> from ' || parking_d(h.start_date) || ' to ' || parking_d(h.end_date) || ', with the guest decal displayed.</p><p>2nd Chance Housing</p>', 'parking');
  end if;
  return to_jsonb(h) || jsonb_build_object('stall', s.label);
end;
$$;
revoke all on function parking_hold_create(uuid, text, uuid, text, text, text, text, text, text, date, date, text) from public, anon;
grant execute on function parking_hold_create(uuid, text, uuid, text, text, text, text, text, text, date, date, text) to authenticated;

-- End a hold: one that hasn't started is cancelled; one in progress ends today.
create or replace function parking_hold_end(p_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare h parking_holds;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  update parking_holds set status = case when start_date > current_date then 'cancelled' else 'ended' end,
    end_date = case when start_date > current_date then end_date else least(end_date, current_date) end,
    ended_by = lower(auth.email()), ended_at = now()
   where id = p_id and status = 'active' returning * into h;
  if h.id is null then raise exception 'That hold is already over.'; end if;
  return to_jsonb(h);
end;
$$;
revoke all on function parking_hold_end(uuid) from public, anon;
grant execute on function parking_hold_end(uuid) to authenticated;

-- Add or change a stall. Unit stalls keep their label and unit; only their place on the map and note change.
-- Guest and contractor stalls can be added, relabeled, moved and taken off the map (never deleted: holds point at them).
create or replace function parking_stall_save(p_id uuid, p_label text, p_kind text, p_row int, p_pos int, p_note text, p_active boolean)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare s parking_stalls;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if coalesce(p_row, 0) < 1 or p_row > 20 or coalesce(p_pos, 0) < 1 or p_pos > 60 then raise exception 'Row is 1–20 and position 1–60.'; end if;
  if p_id is null then
    if p_kind not in ('guest', 'contractor') then raise exception 'New stalls are guest or contractor stalls.'; end if;
    if length(coalesce(trim(p_label), '')) < 1 then raise exception 'Enter the label painted on the stall.'; end if;
    if exists (select 1 from parking_stalls where lower(label) = lower(trim(p_label))) then raise exception 'There is already a stall labeled %.', trim(p_label); end if;
    insert into parking_stalls (label, kind, map_row, map_pos, note, active)
    values (trim(p_label), p_kind, p_row, p_pos, nullif(trim(coalesce(p_note, '')), ''), coalesce(p_active, true)) returning * into s;
  else
    select * into s from parking_stalls where id = p_id for update;
    if s.id is null then raise exception 'Stall not found'; end if;
    if s.kind = 'unit' then
      if coalesce(p_active, true) = false then raise exception 'Unit stalls stay on the map.'; end if;
      update parking_stalls set map_row = p_row, map_pos = p_pos, note = nullif(trim(coalesce(p_note, '')), ''), updated_at = now() where id = p_id returning * into s;
    else
      if p_kind not in ('guest', 'contractor') then raise exception 'Guest or contractor stall.'; end if;
      if length(coalesce(trim(p_label), '')) < 1 then raise exception 'Enter the label painted on the stall.'; end if;
      if exists (select 1 from parking_stalls where lower(label) = lower(trim(p_label)) and id <> p_id) then raise exception 'There is already a stall labeled %.', trim(p_label); end if;
      update parking_stalls set label = trim(p_label), kind = p_kind, map_row = p_row, map_pos = p_pos, note = nullif(trim(coalesce(p_note, '')), ''),
        active = coalesce(p_active, true), updated_at = now() where id = p_id returning * into s;
    end if;
  end if;
  return to_jsonb(s);
end;
$$;
revoke all on function parking_stall_save(uuid, text, text, int, int, text, boolean) from public, anon;
grant execute on function parking_stall_save(uuid, text, text, int, int, text, boolean) to authenticated;
