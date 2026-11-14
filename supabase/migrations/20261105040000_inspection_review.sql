-- Inspections, part 2 (Stephen, 10/6/2026):
--   * Submitting an inspection turns every "Needs repair" item into a maintenance request (one per item,
--     created once). The request is linked to the tenant on the active lease, or to the vacant unit.
--   * Office staff get a list of every inspection and a full report for each (photos, notes, and the
--     maintenance request each repair created), printable, and an email summary.

create table if not exists inspection_requests (
  inspection_id uuid not null references inspections(id) on delete cascade,
  item_key text not null,
  request_id uuid not null references maintenance_requests(id),
  created_at timestamptz not null default now(),
  primary key (inspection_id, item_key)
);
alter table inspection_requests enable row level security;

create or replace function inspection_category(p_text text)
returns text language sql immutable as $$
  select case
    when p_text ~* 'faucet|sink|drain|toilet|tub|shower|plumb|leak|water' then 'plumbing'
    when p_text ~* 'outlet|light|switch|electric|smoke|detector|fixture lamp' then 'electric'
    when p_text ~* 'window|screen|blind' then 'windows'
    when p_text ~* 'door|lock|hinge' then 'doors'
    when p_text ~* 'heat|radiator|thermostat|furnace' then 'heat'
    when p_text ~* 'roach|pest|mouse|mice|bug' then 'pests'
    when p_text ~* 'cabinet|counter|vanity|appliance|base|floor|wall|ceiling' then 'fixtures'
    else 'other' end;
$$;

-- The rental unit an inspection is for: property id like '6626-n-bourbon' (street number first) + unit.
create or replace function inspection_rental_unit(p_property text, p_unit text)
returns uuid language sql stable security definer set search_path = public as $$
  select ru.id from rental_units ru
  where coalesce(ru.address, '') ilike split_part(p_property, '-', 1) || ' %'
    and (ru.unit_number = p_unit or (p_unit = '_' and ru.unit_number is null))
  order by ru.unit_number limit 1;
$$;

create or replace function inspection_make_requests(p_id uuid)
returns int
language plpgsql volatile security definer set search_path = public as $$
declare i inspections; it record; v_ru uuid; v_lease uuid; v_tenant uuid; v_label text; v_req uuid; v_n int := 0; v_area text; v_item text; v_occupied boolean;
begin
  select * into i from inspections where id = p_id;
  if i.id is null then return 0; end if;
  v_ru := inspection_rental_unit(i.property_id, i.unit);
  select l.id into v_lease from leases l where l.unit_id = v_ru and l.status = 'active' order by l.start_date desc nulls last limit 1;
  v_occupied := v_lease is not null;
  select lt.tenant_id into v_tenant from lease_tenants lt where lt.lease_id = v_lease limit 1;
  select coalesce(ru.address, i.property_id || ' unit ' || i.unit) into v_label from rental_units ru where ru.id = v_ru;
  v_label := coalesce(v_label, i.property_id || ' unit ' || i.unit);
  for it in select e.key, e.value from jsonb_each(coalesce(i.data -> 'items', '{}'::jsonb)) e where e.value ->> 's' = 'Needs repair'
            and not exists (select 1 from inspection_requests r where r.inspection_id = p_id and r.item_key = e.key) loop
    v_area := initcap(replace(split_part(it.key, '|', 1), '-', ' '));
    v_item := split_part(it.key, '|', 2);
    insert into maintenance_requests (tenant_id, lease_id, unit_label, subject, description, entry_permission, status, category, staff_notes)
    values (v_tenant, v_lease, v_label, left('Inspection: ' || v_area || ' - ' || v_item, 120),
            coalesce(nullif(trim(it.value ->> 'n'), ''), v_area || ' - ' || v_item || ' needs repair. Found during the unit inspection.'),
            case when v_occupied then 'call_first' else 'yes' end, 'new', inspection_category(v_area || ' ' || v_item),
            'Created from the ' || to_char(i.inspected_on, 'FMMM/FMDD/YYYY') || ' inspection by ' || i.inspector_email || '. Photos and the full report are on the inspection report.')
    returning id into v_req;
    insert into inspection_requests (inspection_id, item_key, request_id) values (p_id, it.key, v_req);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;
revoke all on function inspection_make_requests(uuid) from public, anon, authenticated;
grant execute on function inspection_make_requests(uuid) to service_role;

-- Same save as before, plus the repair requests when it is submitted.
create or replace function field_save_inspection(p_id uuid, p_property text, p_unit text, p_date date, p_data jsonb, p_submit boolean default false)
returns jsonb
language plpgsql security definer set search_path = public
as $$
declare r inspections; v_req int := 0;
begin
  if not field_can_access(p_property, p_unit) then raise exception 'Not your unit' using errcode = '42501'; end if;
  select * into r from inspections where id = p_id;
  if found and (r.property_id <> p_property or r.unit <> p_unit) then raise exception 'Wrong unit' using errcode = '42501'; end if;
  if found and r.status = 'submitted' then raise exception 'This inspection was already submitted' using errcode = '42501'; end if;
  insert into inspections (id, property_id, unit, inspector_email, inspected_on, data, status, submitted_at)
  values (p_id, p_property, p_unit, lower(auth.email()), coalesce(p_date, current_date), coalesce(p_data, '{}'::jsonb),
          case when p_submit then 'submitted' else 'draft' end, case when p_submit then now() end)
  on conflict (id) do update set
    inspected_on = coalesce(p_date, inspections.inspected_on),
    data = coalesce(p_data, inspections.data),
    status = case when p_submit then 'submitted' else 'draft' end,
    submitted_at = case when p_submit then now() else null end,
    updated_at = now();
  if p_submit then v_req := inspection_make_requests(p_id); end if;
  return jsonb_build_object('id', p_id, 'status', case when p_submit then 'submitted' else 'draft' end, 'requests_created', v_req);
end;
$$;
revoke all on function field_save_inspection(uuid, text, text, date, jsonb, boolean) from public, anon;
grant execute on function field_save_inspection(uuid, text, text, date, jsonb, boolean) to authenticated;

-- ---------------------------------------------------------------------------
-- Office staff: every inspection, newest first.
create or replace function inspections_staff_list(p_limit int default 300)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(q.x order by q.inspected_on desc, q.created_at desc) from (
    select jsonb_build_object('id', i.id, 'property_id', i.property_id, 'unit', i.unit, 'inspector', i.inspector_email, 'inspected_on', i.inspected_on, 'status', i.status,
             'submitted_at', i.submitted_at,
             'needs_repair', (select count(*) from jsonb_each(i.data -> 'items') e where e.value ->> 's' = 'Needs repair'),
             'checked', (select count(*) from jsonb_each(i.data -> 'items') e where coalesce(e.value ->> 's', '') <> ''),
             'requests', (select count(*) from inspection_requests r where r.inspection_id = i.id)) x, i.inspected_on, i.created_at
    from inspections i order by i.inspected_on desc, i.created_at desc limit greatest(least(coalesce(p_limit, 300), 1000), 1)) q), '[]'::jsonb);
end;
$$;
revoke all on function inspections_staff_list(int) from public, anon;
grant execute on function inspections_staff_list(int) to authenticated;

-- One inspection with the maintenance request each repair created.
create or replace function inspections_staff_get(p_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r inspections;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into r from inspections where id = p_id;
  if r.id is null then return null; end if;
  return jsonb_build_object('id', r.id, 'property_id', r.property_id, 'unit', r.unit, 'inspector', r.inspector_email, 'inspected_on', r.inspected_on,
    'status', r.status, 'submitted_at', r.submitted_at, 'data', r.data,
    'requests', coalesce((select jsonb_object_agg(q.item_key, jsonb_build_object('id', m.id, 'number', m.number, 'status', m.status))
                          from inspection_requests q join maintenance_requests m on m.id = q.request_id where q.inspection_id = r.id), '{}'::jsonb));
end;
$$;
revoke all on function inspections_staff_get(uuid) from public, anon;
grant execute on function inspections_staff_get(uuid) to authenticated;

-- Email a summary of one inspection (the repairs it found) to a person; the staff page then sends the queue.
create or replace function inspections_staff_email(p_id uuid, p_to text, p_label text)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare r inspections; v_rows text := ''; it record; v_n int := 0;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if coalesce(p_to, '') !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'Enter a full email address'; end if;
  select * into r from inspections where id = p_id;
  if r.id is null then raise exception 'Inspection not found'; end if;
  for it in select e.key, e.value, (select m.number from inspection_requests q join maintenance_requests m on m.id = q.request_id where q.inspection_id = r.id and q.item_key = e.key) num
            from jsonb_each(r.data -> 'items') e where e.value ->> 's' = 'Needs repair' order by e.key loop
    v_n := v_n + 1;
    v_rows := v_rows || '<tr><td style="padding:6px 10px;border-bottom:1px solid #ddd">' || initcap(replace(split_part(it.key, '|', 1), '-', ' ')) || ' - ' || split_part(it.key, '|', 2) ||
      '</td><td style="padding:6px 10px;border-bottom:1px solid #ddd">' || replace(replace(coalesce(it.value ->> 'n', ''), '<', '&lt;'), '>', '&gt;') ||
      '</td><td style="padding:6px 10px;border-bottom:1px solid #ddd">' || coalesce('#' || it.num, '') || '</td></tr>';
  end loop;
  insert into email_outbox (to_email, subject, html, kind) values (lower(trim(p_to)),
    'Unit inspection ' || coalesce(nullif(trim(p_label), ''), r.property_id || ' unit ' || r.unit) || ' - ' || to_char(r.inspected_on, 'FMMM/FMDD/YYYY'),
    '<p>Unit inspection for <b>' || coalesce(nullif(trim(p_label), ''), r.property_id || ' unit ' || r.unit) || '</b> on ' || to_char(r.inspected_on, 'FMMM/FMDD/YYYY') ||
    ' by ' || r.inspector_email || '. Status: ' || r.status || '.</p>' ||
    case when v_n = 0 then '<p>No items need repair.</p>' else '<p><b>' || v_n || ' item(s) need repair:</b></p><table style="border-collapse:collapse;font-size:14px"><tr><th align="left" style="padding:6px 10px">Item</th><th align="left" style="padding:6px 10px">Note</th><th align="left" style="padding:6px 10px">Request</th></tr>' || v_rows || '</table>' end ||
    '<p>The full report with photos is on the inspection page when you are signed in.</p><p>2nd Chance Housing</p>', 'inspection');
end;
$$;
revoke all on function inspections_staff_email(uuid, text, text) from public, anon;
grant execute on function inspections_staff_email(uuid, text, text) to authenticated;
