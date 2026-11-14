-- Housing Navigator unit files (Stephen, 11/11/2026). The first Navigator LEASES whole units from landlords, furnishes them
-- and rents ROOMS to residents (shared living). Each unit she runs gets a unit file:
--   * nav_units: operated_by_navigator (she leases and runs it), master-lease dates and rent, room_mode.
--   * nav_rooms: the rooms (or beds) she rents, with monthly rate and status. Referrals are matched to a room.
--   * nav_unit_money: every dollar in and out of the unit (rent to the landlord, utilities, furniture, appliances, repairs,
--     supplies ... and resident rent, agency or VA payments), each with optional receipt photos (private bucket nav-receipts).
--   * nav_unit_budget: the planned amounts per category, monthly or one-time (start-up), for budget vs actual.
--   * Inspections: the office's room-by-room inspection page works for these units (property_id 'nav', unit = nav_units.id),
--     with a new purpose 'pre_lease' (before taking the unit). Navigator inspections never create office repair requests.
-- Who may see and change a unit file: office staff, and the Navigator who runs the unit or added it or its landlord.
-- A Navigator on Preview sees nothing to manage and can change nothing (nav_actor_role refuses).

-- ---------------------------------------------------------------- tables
alter table nav_units add column if not exists operated_by_navigator uuid references navigators(id) on delete set null;
alter table nav_units add column if not exists lease_start date;
alter table nav_units add column if not exists lease_end date;
alter table nav_units add column if not exists lease_rent numeric(10,2);
alter table nav_units add column if not exists room_mode boolean not null default false;

create table if not exists nav_rooms (
  id uuid primary key default gen_random_uuid(),
  unit_id uuid not null references nav_units(id) on delete cascade,
  label text not null,
  monthly_rate numeric(10,2),
  deposit numeric(10,2),
  furnished boolean not null default true,
  status text not null default 'available' check (status in ('available', 'reserved', 'occupied', 'offline')),
  notes text,
  sort int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists nav_rooms_unit_idx on nav_rooms (unit_id);
alter table nav_rooms enable row level security;

alter table nav_referrals add column if not exists nav_room_id uuid references nav_rooms(id) on delete set null;

create table if not exists nav_unit_money (
  id uuid primary key default gen_random_uuid(),
  unit_id uuid not null references nav_units(id) on delete cascade,
  room_id uuid references nav_rooms(id) on delete set null,
  referral_id uuid references nav_referrals(id) on delete set null,
  kind text not null check (kind in ('expense', 'income')),
  category text not null check (category in (
    'rent_to_landlord', 'utilities', 'internet_phone', 'furniture', 'appliances', 'repairs', 'cleaning', 'household',
    'insurance', 'deposit_paid', 'fees', 'other_expense',
    'resident_rent', 'agency_payment', 'va_payment', 'resident_deposit', 'other_income')),
  amount numeric(10,2) not null check (amount > 0),
  entry_date date not null,
  party text,                       -- paid to (vendor) or received from
  description text,
  receipts text[] not null default '{}',
  voided boolean not null default false,
  void_reason text,
  created_by text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists nav_unit_money_unit_idx on nav_unit_money (unit_id, entry_date);
alter table nav_unit_money enable row level security;

create table if not exists nav_unit_budget (
  unit_id uuid not null references nav_units(id) on delete cascade,
  category text not null,
  frequency text not null check (frequency in ('monthly', 'one_time')),
  amount numeric(10,2) not null check (amount >= 0),
  note text,
  updated_at timestamptz not null default now(),
  primary key (unit_id, category, frequency)
);
alter table nav_unit_budget enable row level security;

revoke all on nav_rooms, nav_unit_money, nav_unit_budget from anon, authenticated;
grant all on nav_rooms, nav_unit_money, nav_unit_budget to service_role;

-- ---------------------------------------------------------------- access
create or replace function nav_can_manage_unit(p_unit text) returns boolean
language sql stable security definer set search_path = public as $$
  select staff_session_staff() or (nav_me() is not null and exists (
    select 1 from nav_units u left join nav_landlords l on l.id = u.landlord_id
     where u.id::text = p_unit
       and (u.operated_by_navigator = nav_me() or u.added_by_navigator = nav_me() or l.added_by_navigator = nav_me())));
$$;

-- Receipts live at nav-receipts/<unit id>/<file>.
create or replace function nav_receipt_ok(p_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select nav_can_manage_unit(split_part(coalesce(p_name, ''), '/', 1));
$$;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('nav-receipts', 'nav-receipts', false, 10485760, array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif', 'application/pdf'])
on conflict (id) do nothing;

drop policy if exists "nav receipts read" on storage.objects;
drop policy if exists "nav receipts upload" on storage.objects;
drop policy if exists "nav receipts delete" on storage.objects;
create policy "nav receipts read" on storage.objects for select to authenticated
  using (bucket_id = 'nav-receipts' and nav_receipt_ok(name));
create policy "nav receipts upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'nav-receipts' and nav_receipt_ok(name));
create policy "nav receipts delete" on storage.objects for delete to authenticated
  using (bucket_id = 'nav-receipts' and nav_receipt_ok(name));

-- Inspections: the same page, functions and photo bucket; a nav unit is property 'nav', unit = its id.
create or replace function public.inspection_can_access(p_property text, p_unit text) returns boolean
language sql stable security definer set search_path = public as $function$
  select case when p_property = 'nav' then nav_can_manage_unit(p_unit)
  else field_can_access(p_property, p_unit)
      or (auth.uid() is not null and mfa_aal_ok() and exists (
            select 1 from condo_ownerships s join condo_units u on u.id = s.unit_id
             where s.is_current and s.owner_id = condo_owner_for_email(auth.email())
               and u.unit_number = p_unit and u.address like split_part(p_property, '-', 1) || '%')) end;
$function$;

alter table inspections drop constraint if exists inspections_purpose_chk;
alter table inspections drop constraint if exists inspections_purpose_check;
alter table inspections add constraint inspections_purpose_chk
  check (purpose = any (array['routine', 'annual', 'pre_move_in', 'pre_move_out', 'follow_up', 'complaint', 'other', 'pre_lease']));

create or replace function public.field_save_inspection(p_id uuid, p_property text, p_unit text, p_date date, p_data jsonb, p_submit boolean default false, p_purpose text default null, p_appointment uuid default null)
returns jsonb language plpgsql security definer set search_path = public as $function$
declare r inspections; v_req int := 0; v_purpose text; v_appt uuid; v_staffside boolean; v_bad int;
begin
  if not inspection_can_access(p_property, p_unit) then raise exception 'Not your unit' using errcode = '42501'; end if;
  if p_property = 'nav' then perform nav_actor_role(); end if;   -- a Preview Navigator cannot save
  v_staffside := p_property <> 'nav' and field_can_access(p_property, p_unit);
  if p_purpose is not null and p_purpose not in ('routine', 'annual', 'pre_move_in', 'pre_move_out', 'follow_up', 'complaint', 'other', 'pre_lease') then raise exception 'Unknown inspection purpose'; end if;
  select * into r from inspections where id = p_id;
  if found and (r.property_id <> p_property or r.unit <> p_unit) then raise exception 'Wrong unit' using errcode = '42501'; end if;
  if found and r.status = 'submitted' then raise exception 'This inspection was already submitted' using errcode = '42501'; end if;
  if p_appointment is not null and not exists (select 1 from inspection_appointments a where a.id = p_appointment and a.property_id = p_property and a.unit = p_unit) then
    raise exception 'That appointment is for another unit'; end if;
  v_appt := coalesce(p_appointment, r.appointment_id);
  v_purpose := coalesce(p_purpose, r.purpose, (select a.purpose from inspection_appointments a where a.id = v_appt), 'routine');
  insert into inspections (id, property_id, unit, inspector_email, inspected_on, data, status, submitted_at, purpose, appointment_id)
  values (p_id, p_property, p_unit, lower(auth.email()), coalesce(p_date, current_date), coalesce(p_data, '{}'::jsonb),
          case when p_submit then 'submitted' else 'draft' end, case when p_submit then now() end, v_purpose, v_appt)
  on conflict (id) do update set
    inspected_on = coalesce(p_date, inspections.inspected_on),
    data = coalesce(p_data, inspections.data),
    status = case when p_submit then 'submitted' else 'draft' end,
    submitted_at = case when p_submit then now() else null end,
    purpose = v_purpose, appointment_id = v_appt,
    updated_at = now();
  if p_submit and p_property = 'nav' then
    select count(*) into v_bad from inspections i, jsonb_each(coalesce(i.data -> 'items', '{}'::jsonb)) x where i.id = p_id and x.value ->> 's' = 'Needs repair';
    update nav_units set inspection_status = case when v_bad > 0 then 'failed' else 'passed' end,
           inspected_on = coalesce(p_date, current_date), updated_at = now() where id::text = p_unit;
    perform nav_log('inspection_' || v_purpose, case when v_bad > 0 then v_bad || ' item(s) need repair' else 'All OK' end, null, null, null, p_unit::uuid);
  end if;
  if p_submit and v_staffside then
    v_req := inspection_make_requests(p_id);
    select * into r from inspections where id = p_id;
    if v_appt is null then
      select a.id into v_appt from inspection_appointments a where a.property_id = p_property and a.unit = p_unit and a.status = 'scheduled'
        and abs((a.starts_at at time zone 'America/Chicago')::date - r.inspected_on) <= 7
      order by abs((a.starts_at at time zone 'America/Chicago')::date - r.inspected_on) limit 1;
      if v_appt is not null then update inspections set appointment_id = v_appt where id = p_id; end if;
    end if;
    if v_appt is not null then
      update inspection_appointments set status = 'done', inspection_id = p_id where id = v_appt and status = 'scheduled';
    end if;
    if r.purpose in ('routine', 'annual') then
      update inspection_schedules set next_due = (r.inspected_on + make_interval(months => frequency_months))::date, updated_at = now(), updated_by = 'inspection ' || to_char(r.inspected_on, 'FMMM/FMDD')
       where property_id = p_property and unit = p_unit and (next_due is null or next_due <= (r.inspected_on + make_interval(months => frequency_months))::date);
    end if;
  end if;
  return jsonb_build_object('id', p_id, 'status', case when p_submit then 'submitted' else 'draft' end, 'requests_created', v_req, 'purpose', v_purpose, 'appointment_id', v_appt);
end;
$function$;

-- The inspection page's heading for a nav unit.
create or replace function nav_unit_label(p_unit text) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if not nav_can_manage_unit(p_unit) then raise exception 'Not your unit' using errcode = '42501'; end if;
  select jsonb_build_object('name', coalesce(l.business_name, l.name) || ': ' || u.address || coalesce(' ' || u.unit_label, ''),
                            'address', u.address || coalesce(' ' || u.unit_label, '') || ', ' || u.city || coalesce(' ' || u.zip, ''))
    into v from nav_units u join nav_landlords l on l.id = u.landlord_id where u.id::text = p_unit;
  return v;
end;
$$;

-- ---------------------------------------------------------------- shapes
create or replace function nav_unit_json(u nav_units) returns jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(u) - 'added_by_navigator' - 'operated_by_navigator' || jsonb_build_object(
    'mine', u.added_by_navigator is not null and u.added_by_navigator = nav_me(),
    'manage', nav_can_manage_unit(u.id::text),
    'operator', (select name from navigators where id = u.operated_by_navigator),
    'operated_by_me', u.operated_by_navigator is not null and u.operated_by_navigator = nav_me(),
    'rooms', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'label', r.label, 'monthly_rate', r.monthly_rate, 'status', r.status, 'furnished', r.furnished) order by r.sort, r.label)
                       from nav_rooms r where r.unit_id = u.id), '[]'::jsonb));
$$;

create or replace function nav_referral_json(r nav_referrals, p_full boolean) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_staff boolean := staff_session_staff(); v jsonb; v_unit jsonb;
begin
  v := to_jsonb(r) - 'staff_notes' || jsonb_build_object('label', nav_ref_label(r), 'gap', nav_gap(r),
        'navigator', (select name from navigators where id = r.navigator_id));
  if v_staff then v := v || jsonb_build_object('staff_notes', r.staff_notes); end if;
  if r.nav_unit_id is not null then
    select jsonb_build_object('kind', 'network', 'id', u.id, 'address', u.address, 'unit_label', u.unit_label, 'rent', u.rent, 'deposit', coalesce(rm.deposit, u.deposit),
             'room', rm.label, 'room_id', rm.id,
             'landlord', coalesce(l.business_name, l.name), 'landlord_phone', l.phone, 'landlord_email', l.email)
      into v_unit from nav_units u join nav_landlords l on l.id = u.landlord_id left join nav_rooms rm on rm.id = r.nav_room_id where u.id = r.nav_unit_id;
  elsif r.rental_unit_id is not null then
    select jsonb_build_object('kind', '2nd Chance', 'id', ru.id, 'address', ru.address, 'unit_label', ru.unit_number, 'rent', r.unit_rent,
             'landlord', '2nd Chance Housing')
      into v_unit from rental_units ru where ru.id = r.rental_unit_id;
  end if;
  v := v || jsonb_build_object('unit', v_unit);
  if p_full then
    v := v || jsonb_build_object(
      'events', coalesce((select jsonb_agg(jsonb_build_object('at', e.created_at, 'who', e.actor_role, 'action', e.action, 'detail', e.detail, 'private', e.private) order by e.created_at desc)
                 from nav_events e where e.referral_id = r.id and (v_staff or not e.private)), '[]'::jsonb),
      'followups', coalesce((select jsonb_agg(to_jsonb(f) order by f.due_on) from nav_followups f where f.referral_id = r.id), '[]'::jsonb));
  end if;
  return v;
end;
$$;

-- ---------------------------------------------------------------- units: who runs it, master lease, rooms
create or replace function nav_unit_save(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_role text := nav_actor_role(); v_me uuid := nav_me(); v_id uuid := nullif(p->>'id', '')::uuid; v_ll uuid := nullif(p->>'landlord_id', '')::uuid; v_old nav_units;
begin
  if v_role is null then raise exception 'Sign-in required' using errcode = '42501'; end if;
  if v_id is not null then select * into v_old from nav_units where id = v_id; v_ll := v_old.landlord_id; end if;
  if v_ll is null or not (nav_can_edit_landlord(v_ll) or (v_id is not null and nav_can_manage_unit(v_id::text))) then
    raise exception 'Only the office or the Navigator who added or runs this unit can change it.' using errcode = '42501';
  end if;
  if length(trim(coalesce(p->>'address', ''))) < 4 then raise exception 'Enter the street address.'; end if;
  if v_id is null then
    insert into nav_units (landlord_id, address, added_by_navigator) values (v_ll, trim(p->>'address'), case when v_role = 'navigator' then v_me end) returning id into v_id;
    perform nav_log('unit_added', trim(p->>'address'), null, null, v_ll, v_id);
  end if;
  if v_role <> 'staff' and v_old.status in ('reserved', 'occupied') and coalesce(p->>'status', v_old.status) <> v_old.status then
    raise exception 'This unit is % through a referral; it changes when that referral moves on.', v_old.status;
  end if;
  update nav_units set
    address = trim(p->>'address'),
    unit_label = nullif(trim(coalesce(p->>'unit_label', '')), ''),
    city = coalesce(nullif(trim(coalesce(p->>'city', '')), ''), 'Milwaukee'),
    zip = nullif(trim(coalesce(p->>'zip', '')), ''),
    bedrooms = nullif(p->>'bedrooms', '')::numeric,
    bathrooms = nullif(p->>'bathrooms', '')::numeric,
    rent = nullif(p->>'rent', '')::numeric,
    deposit = nullif(p->>'deposit', '')::numeric,
    application_fee = nullif(p->>'application_fee', '')::numeric,
    utilities_included = nullif(trim(coalesce(p->>'utilities_included', '')), ''),
    accessibility = nullif(trim(coalesce(p->>'accessibility', '')), ''),
    ground_floor = case when p->>'ground_floor' in ('true', 'false') then (p->>'ground_floor')::boolean end,
    accepts_vouchers = case when p->>'accepts_vouchers' in ('true', 'false') then (p->>'accepts_vouchers')::boolean end,
    pets = nullif(trim(coalesce(p->>'pets', '')), ''),
    inspection_status = case when v_role = 'staff' then coalesce(nullif(p->>'inspection_status', ''), inspection_status) else inspection_status end,
    inspected_on = case when v_role = 'staff' then nullif(p->>'inspected_on', '')::date else inspected_on end,
    status = case when v_role = 'staff' or coalesce(p->>'status', status) in ('available', 'maintenance', 'off_market') then coalesce(nullif(p->>'status', ''), status) else status end,
    available_on = nullif(p->>'available_on', '')::date,
    notes = nullif(trim(coalesce(p->>'notes', '')), ''),
    room_mode = coalesce((p->>'room_mode')::boolean, room_mode),
    lease_start = case when p ? 'lease_start' then nullif(p->>'lease_start', '')::date else lease_start end,
    lease_end = case when p ? 'lease_end' then nullif(p->>'lease_end', '')::date else lease_end end,
    lease_rent = case when p ? 'lease_rent' then nullif(p->>'lease_rent', '')::numeric else lease_rent end,
    operated_by_navigator = case
      when v_role = 'staff' and p ? 'operated_by_navigator' then nullif(p->>'operated_by_navigator', '')::uuid
      when v_role = 'navigator' and p ? 'operated' and (operated_by_navigator is null or operated_by_navigator = v_me)
        then case when (p->>'operated')::boolean then v_me else null end
      else operated_by_navigator end,
    updated_at = now()
  where id = v_id;
  return v_id;
end;
$$;

create or replace function nav_room_save(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_role text := nav_actor_role(); v_id uuid := nullif(p->>'id', '')::uuid; v_unit uuid := nullif(p->>'unit_id', '')::uuid; v_old nav_rooms;
begin
  if v_id is not null then select * into v_old from nav_rooms where id = v_id; v_unit := v_old.unit_id; end if;
  if v_role is null or v_unit is null or not nav_can_manage_unit(v_unit::text) then raise exception 'Not your unit' using errcode = '42501'; end if;
  if length(trim(coalesce(p->>'label', ''))) < 1 then raise exception 'Name the room (e.g. Room 1, Front bedroom).'; end if;
  if v_old.status in ('reserved', 'occupied') and coalesce(nullif(p->>'status', ''), v_old.status) <> v_old.status and v_role <> 'staff' then
    raise exception 'This room is % through a referral; it changes when that referral moves on.', v_old.status;
  end if;
  if v_id is null then
    insert into nav_rooms (unit_id, label) values (v_unit, trim(p->>'label')) returning id into v_id;
    update nav_units set room_mode = true, updated_at = now() where id = v_unit;
    perform nav_log('room_added', trim(p->>'label'), null, null, null, v_unit);
  end if;
  update nav_rooms set label = trim(p->>'label'), monthly_rate = nullif(p->>'monthly_rate', '')::numeric, deposit = nullif(p->>'deposit', '')::numeric,
         furnished = coalesce((p->>'furnished')::boolean, furnished),
         status = case when coalesce(nullif(p->>'status', ''), status) in ('available', 'offline') or v_role = 'staff' then coalesce(nullif(p->>'status', ''), status) else status end,
         notes = nullif(trim(coalesce(p->>'notes', '')), ''), sort = coalesce(nullif(p->>'sort', '')::int, sort), updated_at = now()
   where id = v_id;
  return v_id;
end;
$$;

create or replace function nav_room_delete(p_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_role text := nav_actor_role(); rm nav_rooms;
begin
  select * into rm from nav_rooms where id = p_id;
  if not found or v_role is null or not nav_can_manage_unit(rm.unit_id::text) then raise exception 'Not found.' using errcode = '42501'; end if;
  if exists (select 1 from nav_referrals where nav_room_id = p_id) then raise exception 'A referral is matched to this room. Set it Offline instead.'; end if;
  delete from nav_rooms where id = p_id;
  perform nav_log('room_removed', rm.label, null, null, null, rm.unit_id);
end;
$$;

-- ---------------------------------------------------------------- money and budget
create or replace function nav_money_save(p jsonb) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_role text := nav_actor_role(); v_id uuid := nullif(p->>'id', '')::uuid; v_unit uuid := nullif(p->>'unit_id', '')::uuid; v_old nav_unit_money;
        v_kind text; v_cat text := p->>'category'; v_receipts text[];
begin
  if v_id is not null then select * into v_old from nav_unit_money where id = v_id; v_unit := v_old.unit_id; end if;
  if v_role is null or v_unit is null or not nav_can_manage_unit(v_unit::text) then raise exception 'Not your unit' using errcode = '42501'; end if;
  v_kind := case when v_cat in ('resident_rent', 'agency_payment', 'va_payment', 'resident_deposit', 'other_income') then 'income' else 'expense' end;
  if nullif(p->>'amount', '') is null or (p->>'amount')::numeric <= 0 then raise exception 'Enter the amount.'; end if;
  if nullif(p->>'entry_date', '') is null then raise exception 'Enter the date.'; end if;
  if (p->>'entry_date')::date > (now() at time zone 'America/Chicago')::date + 31 then raise exception 'That date is too far ahead.'; end if;
  select coalesce(array_agg(x), '{}') into v_receipts from jsonb_array_elements_text(coalesce(p->'receipts', '[]'::jsonb)) x where split_part(x, '/', 1) = v_unit::text;
  if v_id is null then
    insert into nav_unit_money (unit_id, kind, category, amount, entry_date, created_by)
    values (v_unit, v_kind, v_cat, (p->>'amount')::numeric, (p->>'entry_date')::date, lower(auth.email())) returning id into v_id;
  elsif v_old.voided then raise exception 'This entry was voided.';
  end if;
  update nav_unit_money set kind = v_kind, category = v_cat, amount = round((p->>'amount')::numeric, 2), entry_date = (p->>'entry_date')::date,
         room_id = (select id from nav_rooms where id = nullif(p->>'room_id', '')::uuid and unit_id = v_unit),
         referral_id = (select id from nav_referrals where id = nullif(p->>'referral_id', '')::uuid and nav_unit_id = v_unit),
         party = nullif(trim(coalesce(p->>'party', '')), ''), description = nullif(trim(coalesce(p->>'description', '')), ''),
         receipts = v_receipts, updated_at = now()
   where id = v_id;
  perform nav_log('money_' || case when v_old.id is null then 'added' else 'changed' end,
    v_kind || ' ' || v_cat || ' ' || to_char((p->>'amount')::numeric, 'FM$999,990.00'), null, null, null, v_unit);
  return v_id;
end;
$$;

create or replace function nav_money_void(p_id uuid, p_reason text) returns void
language plpgsql security definer set search_path = public as $$
declare v_role text := nav_actor_role(); m nav_unit_money;
begin
  select * into m from nav_unit_money where id = p_id;
  if not found or v_role is null or not nav_can_manage_unit(m.unit_id::text) then raise exception 'Not found.' using errcode = '42501'; end if;
  if length(trim(coalesce(p_reason, ''))) < 3 then raise exception 'Say why it is removed.'; end if;
  update nav_unit_money set voided = true, void_reason = trim(p_reason), updated_at = now() where id = p_id;
  perform nav_log('money_voided', m.category || ' ' || to_char(m.amount, 'FM$999,990.00') || ': ' || trim(p_reason), null, null, null, m.unit_id);
end;
$$;

-- p_lines: [{category, frequency, amount, note}] replaces the unit's budget.
create or replace function nav_budget_save(p_unit uuid, p_lines jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare v_role text := nav_actor_role();
begin
  if v_role is null or not nav_can_manage_unit(p_unit::text) then raise exception 'Not your unit' using errcode = '42501'; end if;
  delete from nav_unit_budget where unit_id = p_unit;
  insert into nav_unit_budget (unit_id, category, frequency, amount, note)
  select p_unit, x->>'category', x->>'frequency', round((x->>'amount')::numeric, 2), nullif(trim(coalesce(x->>'note', '')), '')
    from jsonb_array_elements(coalesce(p_lines, '[]'::jsonb)) x
   where coalesce(x->>'amount', '') ~ '^[0-9]+(\.[0-9]+)?$' and (x->>'amount')::numeric > 0 and x->>'frequency' in ('monthly', 'one_time')
  on conflict do nothing;
  perform nav_log('budget_saved', null, null, null, null, p_unit);
end;
$$;

-- ---------------------------------------------------------------- the unit file
create or replace function nav_unit_file(p_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare u nav_units; v_today date := (now() at time zone 'America/Chicago')::date; v_month date := date_trunc('month', (now() at time zone 'America/Chicago'))::date;
        v_write boolean;
begin
  if not nav_can_manage_unit(p_id::text) then raise exception 'Not your unit' using errcode = '42501'; end if;
  select * into u from nav_units where id = p_id;
  v_write := staff_session_staff() or exists (select 1 from navigators where id = nav_me() and status in ('pilot', 'active'));
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

-- Units the signed-in Navigator runs, with this month's money (Navigator home).
create or replace function nav_my_units() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_me uuid := nav_me(); v_month date := date_trunc('month', (now() at time zone 'America/Chicago'))::date;
begin
  if v_me is null then raise exception 'Sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', u.id, 'address', u.address, 'unit_label', u.unit_label,
      'landlord', (select coalesce(business_name, name) from nav_landlords where id = u.landlord_id),
      'rooms', (select count(*) from nav_rooms where unit_id = u.id and status <> 'offline'),
      'rooms_occupied', (select count(*) from nav_rooms where unit_id = u.id and status = 'occupied'),
      'income_month', (select coalesce(sum(amount), 0) from nav_unit_money where unit_id = u.id and not voided and kind = 'income' and entry_date >= v_month),
      'expense_month', (select coalesce(sum(amount), 0) from nav_unit_money where unit_id = u.id and not voided and kind = 'expense' and entry_date >= v_month),
      'inspection_status', u.inspection_status, 'inspected_on', u.inspected_on) order by u.address, u.unit_label)
    from nav_units u where nav_can_manage_unit(u.id::text)), '[]'::jsonb);
end;
$$;

-- ---------------------------------------------------------------- referral steps with rooms
-- Same as 20261118800000, plus: a unit with rooms is matched by ROOM (nav_room_id); the room is reserved, then occupied at
-- move-in, and freed when the referral is released or closed. The unit's own status follows only when it has no rooms.
create or replace function nav_referral_step(p_id uuid, p_to text, p jsonb default '{}'::jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_role text := nav_actor_role(); r nav_referrals; u nav_units; rm nav_rooms; l nav_landlords; v_gap numeric; v_note text := nullif(trim(coalesce(p->>'note', '')), '');
  v_date date; v_ok boolean := false; v_label text; v_who text;
begin
  if v_role is null or not nav_can_ref(p_id) then raise exception 'Not found.' using errcode = '42501'; end if;
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
      '<p>Referral <b>' || v_label || '</b> (' || repair_esc(v_who) || ') is now <b>' || case when p_to = 'searching' then 'accepted: search for housing' else 'under review by the office' end || '</b>.'
      || coalesce('<br>Note from the office: ' || repair_esc(v_note), '') || '</p><p>https://2ndchinc.org/navigator/</p>', 'nav_navigator');
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
      '<p>The office approved the placement for <b>' || v_label || '</b> (' || repair_esc(v_who) || '). When the person moves in, record the move-in date on the portal.</p><p>https://2ndchinc.org/navigator/</p>', 'nav_navigator');
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
      '<p>The office closed referral <b>' || v_label || '</b> (' || repair_esc(replace(p->>'close_reason', '_', ' ')) || ').' || coalesce('<br>Note: ' || repair_esc(v_note), '') || '</p>', 'nav_navigator');
    v_ok := true;
  end if;

  if not v_ok then raise exception 'That step is not allowed now (the referral is %).', replace(r.status, '_', ' '); end if;
  perform nav_log('status_' || p_to, v_note, p_id);
  return nav_referral_get(p_id);
end;
$$;

-- ---------------------------------------------------------------- grants
do $g$
declare f text;
begin
  foreach f in array array['nav_can_manage_unit(text)', 'nav_receipt_ok(text)', 'nav_unit_label(text)', 'nav_room_save(jsonb)', 'nav_room_delete(uuid)',
                           'nav_money_save(jsonb)', 'nav_money_void(uuid,text)', 'nav_budget_save(uuid,jsonb)', 'nav_unit_file(uuid)', 'nav_my_units()'] loop
    execute format('revoke all on function %s from public, anon', f);
    execute format('grant execute on function %s to authenticated, service_role', f);
  end loop;
  revoke all on function nav_unit_json(nav_units) from public, anon, authenticated;
  grant execute on function nav_unit_json(nav_units) to service_role;
  revoke all on function nav_referral_json(nav_referrals, boolean) from public, anon, authenticated;
  grant execute on function nav_referral_json(nav_referrals, boolean) to service_role;
end;
$g$;
