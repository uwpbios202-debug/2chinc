-- Inspection items now carry a label (for example "Walls: Holes"). The repair request made from a "Needs repair" item says which label was picked.
-- Only the request description changes; everything else in inspection_make_requests is as it was.
create or replace function inspection_make_requests(p_id uuid) returns integer
language plpgsql security definer set search_path = public as $$
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
            v_area || ' - ' || v_item || coalesce(' (' || nullif(it.value ->> 'l', '') || ')', '') || ': '
              || coalesce(nullif(trim(it.value ->> 'n'), ''), 'needs repair. Found during the unit inspection.'),
            case when v_occupied then 'call_first' else 'yes' end, 'new', inspection_category(v_area || ' ' || v_item),
            'Created from the ' || to_char(i.inspected_on, 'FMMM/FMDD/YYYY') || ' inspection by ' || i.inspector_email || '. Photos and the full report are on the inspection report.')
    returning id into v_req;
    insert into inspection_requests (inspection_id, item_key, request_id) values (p_id, it.key, v_req);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;
