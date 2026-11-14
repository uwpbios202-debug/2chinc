-- The tenant gets a read-only copy of the staff pre-move-in inspection of their unit (Stephen, 11/5/2026).
-- Resident Documents tab lists it; https://2ndchinc.org/resident/#inspection shows the report with its photos.
-- Only a SUBMITTED pre_move_in inspection of the unit on the tenant's active/future lease, done from 120 days before
-- the lease start to 30 days after it (so a later tenant never sees an older tenant's report, and drafts never show).
-- The inspector's email and the photo metadata (who took it, file hash) are left out. No new table, so no grants needed
-- beyond the functions below.

create or replace function resident_inspection_ids()
returns table (inspection_id uuid, lease_id uuid, address text, unit_number text)
language sql stable security definer set search_path = public as $$
  select i.id, q.lease_id, q.address, q.unit_number
    from (select l.id lease_id, l.start_date, u.unit_number, u.address,
                 case when split_part(coalesce(u.address, ''), ' ', 1) = '6626' then '6626-n-bourbon'
                      when split_part(coalesce(u.address, ''), ' ', 1) = '6622' then '6622-n-bourbon' end pid
            from leases l join rental_units u on u.id = l.unit_id
           where l.status in ('active', 'future') and resident_lease_ok(l.id)) q
    join lateral (select x.id from inspections x
                   where x.property_id = q.pid and x.unit = q.unit_number and x.purpose = 'pre_move_in' and x.status = 'submitted'
                     and x.inspected_on between q.start_date - 120 and q.start_date + 30
                   order by x.inspected_on desc, x.submitted_at desc limit 1) i on true
   where q.pid is not null;
$$;
revoke all on function resident_inspection_ids() from public, anon;
grant execute on function resident_inspection_ids() to authenticated;

-- List for the Documents tab.
create or replace function resident_inspections()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from resident_me()) then raise exception 'Resident two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', i.id, 'inspected_on', i.inspected_on, 'address', r.address, 'unit', r.unit_number)
                                    order by i.inspected_on desc)
                     from resident_inspection_ids() r join inspections i on i.id = r.inspection_id), '[]'::jsonb);
end;
$$;
revoke all on function resident_inspections() from public, anon;
grant execute on function resident_inspections() to authenticated;

-- One report.
create or replace function resident_get_inspection(p_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r inspections; v_addr text;
begin
  if not exists (select 1 from resident_me()) then raise exception 'Resident two-step sign-in required' using errcode = '42501'; end if;
  select x.address into v_addr from resident_inspection_ids() x where x.inspection_id = p_id;
  if not found then return null; end if;
  select * into r from inspections where id = p_id;
  return jsonb_build_object('id', r.id, 'property_id', r.property_id, 'unit', r.unit, 'address', v_addr,
    'inspected_on', r.inspected_on, 'submitted_at', r.submitted_at, 'purpose', r.purpose,
    'items', coalesce((select jsonb_object_agg(e.key, e.value - 'photoMeta') from jsonb_each(r.data -> 'items') e
                        where jsonb_typeof(e.value) = 'object'), '{}'::jsonb));
end;
$$;
revoke all on function resident_get_inspection(uuid) from public, anon;
grant execute on function resident_get_inspection(uuid) to authenticated;

-- Photos: a tenant may READ (never add or delete) the photos of that one inspection. Path: <property>/<unit>/<inspection id>/<file>.
create or replace function resident_inspection_photo_ok(p_name text)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from resident_me())
     and exists (select 1 from resident_inspection_ids() x where x.inspection_id::text = split_part(p_name, '/', 3));
$$;
revoke all on function resident_inspection_photo_ok(text) from public, anon;
grant execute on function resident_inspection_photo_ok(text) to authenticated;

drop policy if exists "inspections read tenant move-in copy" on storage.objects;
create policy "inspections read tenant move-in copy" on storage.objects for select to authenticated
  using (bucket_id = 'inspections' and resident_inspection_photo_ok(name));
