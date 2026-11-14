-- (1) Tenant move-out inspection (Stephen, 10/7/2026): when a move-out is under way the tenant walks the unit the same way they
--     did at move-in: room by room, condition, notes and photos. Staff see it next to the approved move-in checklist, on the unit page.
-- (2) Periodic staff inspections: how long since each unit was last inspected, and what is due.

insert into portal_settings (key, value) values ('inspection_interval_days', '180') on conflict (key) do nothing;

create table if not exists move_out_checklists (
  lease_id uuid primary key references leases(id) on delete cascade,
  move_out_id uuid references move_outs(id) on delete set null,
  data jsonb not null default '{}'::jsonb,
  status text not null default 'draft' check (status in ('draft', 'submitted', 'returned', 'approved')),
  submitted_at timestamptz,
  submitted_by text,
  staff_notes text,
  decided_at timestamptz,
  decided_by text,
  updated_at timestamptz not null default now()
);
alter table move_out_checklists enable row level security;

-- Tenant: the checklist for my lease, when a move-out exists.
create or replace function resident_move_out_check()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare l leases; m move_outs; c move_out_checklists; mi move_in_checklists;
begin
  if not exists (select 1 from resident_me()) then raise exception 'Resident two-step sign-in required' using errcode = '42501'; end if;
  select x.* into m from move_outs x join leases lz on lz.id = x.lease_id where resident_lease_ok(x.lease_id) and x.status <> 'closed' order by x.notice_received_at desc nulls last limit 1;
  if m.id is null then return null; end if;
  select * into l from leases where id = m.lease_id;
  select * into c from move_out_checklists where lease_id = l.id;
  select * into mi from move_in_checklists where lease_id = l.id and status = 'approved';
  return jsonb_build_object('lease_id', l.id, 'address', (select address from rental_units where id = l.unit_id), 'move_out_date', m.move_out_date,
    'rooms', (select value::jsonb from portal_settings where key = 'move_in_rooms'),
    'checklist', case when c.lease_id is null then null else jsonb_build_object('data', c.data, 'status', c.status, 'submitted_at', c.submitted_at, 'staff_notes', c.staff_notes) end,
    'move_in', case when mi.lease_id is null then null else mi.data end);
end;
$$;
revoke all on function resident_move_out_check() from public, anon;
grant execute on function resident_move_out_check() to authenticated;

create or replace function resident_move_out_check_save(p_data jsonb, p_submit boolean)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare m move_outs; c move_out_checklists; v_problem text; v_who text;
begin
  if not exists (select 1 from resident_me()) then raise exception 'Resident two-step sign-in required' using errcode = '42501'; end if;
  select x.* into m from move_outs x where resident_lease_ok(x.lease_id) and x.status <> 'closed' order by x.notice_received_at desc nulls last limit 1;
  if m.id is null then raise exception 'There is no move-out to inspect yet'; end if;
  select * into c from move_out_checklists where lease_id = m.lease_id;
  if c.lease_id is not null and c.status in ('submitted', 'approved') then raise exception 'You already sent your move-out checklist'; end if;
  if p_submit then
    v_problem := move_in_checklist_problem(m.lease_id, p_data);
    if v_problem is not null then raise exception '%', v_problem; end if;
  end if;
  insert into move_out_checklists (lease_id, move_out_id, data, status, submitted_at, submitted_by, updated_at)
  values (m.lease_id, m.id, coalesce(p_data, '{}'::jsonb), case when p_submit then 'submitted' else 'draft' end, case when p_submit then now() end, case when p_submit then lower(auth.email()) end, now())
  on conflict (lease_id) do update set data = excluded.data, status = excluded.status, submitted_at = excluded.submitted_at, submitted_by = excluded.submitted_by, updated_at = now(), move_out_id = excluded.move_out_id;
  if p_submit then
    select work_unit_label(m.lease_id) into v_who;
    perform work_alert('Move-out checklist sent - ' || v_who, '<p>' || replace(v_who, '<', '&lt;') || ' sent the room-by-room move-out checklist with photos. Compare it with the move-in checklist on the staff unit page (Inspections tab).</p>');
  end if;
end;
$$;
revoke all on function resident_move_out_check_save(jsonb, boolean) from public, anon;
grant execute on function resident_move_out_check_save(jsonb, boolean) to authenticated;

-- Staff on a unit can open the tenant's move-in and move-out photos (the folder name is the lease id).
create or replace function field_can_see_lease(p_lease uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select auth.uid() is not null and field_is_staff() and exists (
    select 1 from leases l join rental_units ru on ru.id = l.unit_id
      join staff_units su on lower(su.email) = lower(auth.email()) and su.unit = ru.unit_number
    where l.id = p_lease);
$$;
revoke all on function field_can_see_lease(uuid) from public, anon;
grant execute on function field_can_see_lease(uuid) to authenticated;
drop policy if exists "move-in field staff read" on storage.objects;
create policy "move-in field staff read" on storage.objects for select to authenticated
  using (bucket_id = 'move-in' and field_can_see_lease(move_in_folder_lease(name)));

-- Staff view of the move-in and move-out checklists for a unit.
create or replace function field_unit_checklists(p_property text, p_unit text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_ru uuid := inspection_rental_unit(p_property, p_unit); v_lease uuid;
begin
  if not field_can_access(p_property, p_unit) then raise exception 'Not your unit' using errcode = '42501'; end if;
  select l.id into v_lease from leases l where l.unit_id = v_ru order by (l.status = 'active') desc, l.start_date desc nulls last limit 1;
  return jsonb_build_object('lease_id', v_lease,
    'rooms', (select value::jsonb from portal_settings where key = 'move_in_rooms'),
    'move_in', (select jsonb_build_object('status', c.status, 'submitted_at', c.submitted_at, 'data', c.data, 'notes', c.staff_notes) from move_in_checklists c where c.lease_id = v_lease),
    'move_out', (select jsonb_build_object('status', c.status, 'submitted_at', c.submitted_at, 'data', c.data) from move_out_checklists c where c.lease_id = v_lease));
end;
$$;
revoke all on function field_unit_checklists(text, text) from public, anon;
grant execute on function field_unit_checklists(text, text) to authenticated;

-- Periodic inspections: what is due. Office staff see every unit; limited staff see their own.
create or replace function inspections_due()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_days int := coalesce(nullif((select value from portal_settings where key = 'inspection_interval_days'), '')::int, 180); v_all boolean;
begin
  if auth.uid() is null or not (condo_is_staff() or field_is_staff()) then raise exception 'Staff sign-in required' using errcode = '42501'; end if;
  v_all := condo_is_staff();
  return jsonb_build_object('interval_days', v_days, 'units', coalesce((select jsonb_agg(x order by (x ->> 'sort')::int, x ->> 'unit') from (
    select jsonb_build_object('property_id', pid, 'unit', ru.unit_number, 'address', ru.address,
        'occupied', exists (select 1 from leases l where l.unit_id = ru.id and l.status = 'active'),
        'last', last_done, 'due_on', case when last_done is null then null else last_done + v_days end,
        'state', case when last_done is null then 'never' when last_done + v_days < current_date then 'overdue' when last_done + v_days <= current_date + 30 then 'soon' else 'ok' end,
        'sort', case when last_done is null then 0 when last_done + v_days < current_date then 1 when last_done + v_days <= current_date + 30 then 2 else 3 end) x
    from (select ru.*, case when split_part(coalesce(ru.address, ''), ' ', 1) = '6626' then '6626-n-bourbon' when split_part(coalesce(ru.address, ''), ' ', 1) = '6622' then '6622-n-bourbon' else null end pid from rental_units ru where ru.unit_number is not null) ru
    left join lateral (select max(i.inspected_on) last_done from inspections i where i.property_id = ru.pid and i.unit = ru.unit_number and i.status = 'submitted') d on true
    where ru.pid is not null and (v_all or exists (select 1 from staff_units su where lower(su.email) = lower(auth.email()) and su.property_id = ru.pid and su.unit = ru.unit_number))) q), '[]'::jsonb));
end;
$$;
revoke all on function inspections_due() from public, anon;
grant execute on function inspections_due() to authenticated;
