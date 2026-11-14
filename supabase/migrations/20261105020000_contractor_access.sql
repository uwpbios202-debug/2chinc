-- Contractor sign-in (Stephen, 10/6/2026). A contractor signs in with an emailed code, like everyone else,
-- and sees ONLY the work orders assigned to their vendor record: the address and unit, the problem, when
-- they are scheduled, whether the tenant allows entry and whether there are pets. No tenant phone or
-- email, no ledgers, no other units. They can mark a job started or done and leave a note.
--
-- A vendor can sign in only when staff switch portal_access on for that vendor (and the vendor has an email).
-- To add one (SQL editor):
--   insert into vendors (name, category, email, portal_access) values ('Yawdcore', 'Maintenance', 'yawdcour@gmail.com', true);

alter table vendors add column if not exists portal_access boolean not null default false;
alter table maintenance_requests add column if not exists contractor_notes text;
alter table maintenance_requests add column if not exists contractor_updated_at timestamptz;

create or replace function contractor_vendor_ids(p_email text)
returns setof uuid
language sql stable security definer set search_path = public as $$
  select id from vendors where portal_access and email is not null and lower(email) = lower(p_email);
$$;
revoke all on function contractor_vendor_ids(text) from public, anon, authenticated;
grant execute on function contractor_vendor_ids(text) to service_role;

create or replace function contractor_me()
returns setof uuid
language sql stable security definer set search_path = public as $$
  select * from contractor_vendor_ids(auth.email());
$$;
revoke all on function contractor_me() from public, anon;
grant execute on function contractor_me() to authenticated;

-- The sign-in email goes only to people on file; contractors are now on file.
create or replace function condo_email_on_file(p_email text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select condo_owner_for_email(p_email) is not null
      or exists (select 1 from condo_staff where lower(email) = lower(p_email))
      or exists (select 1 from lease_agents where active and lower(email) = lower(p_email))
      or exists (select 1 from resident_tenant_ids(p_email))
      or exists (select 1 from field_staff where active and lower(email) = lower(p_email))
      or exists (select 1 from contractor_vendor_ids(p_email));
$$;
revoke all on function condo_email_on_file(text) from public, anon, authenticated;
grant execute on function condo_email_on_file(text) to service_role;

create or replace function condo_whoami()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare
  v_owner uuid := condo_owner_for_email(auth.email());
  v_staff boolean := condo_is_staff();
  v_agent uuid := (select id from lease_agents where active and lower(email) = lower(auth.email()));
  v_resident boolean := exists (select 1 from resident_tenant_ids(auth.email()));
  v_field boolean := field_is_staff();
  v_contractor boolean := exists (select 1 from contractor_vendor_ids(auth.email()));
  v_phone text;
begin
  if auth.uid() is null then
    return jsonb_build_object('role', 'none');
  end if;
  v_phone := condo_mfa_phone_for(auth.email());
  if not (v_staff or v_owner is not null or v_agent is not null or v_resident or v_field or v_contractor) then
    return jsonb_build_object('role', 'none');
  end if;
  return jsonb_build_object(
    'role', case when v_staff then 'staff' when v_owner is not null then 'owner' when v_agent is not null then 'agent' when v_resident then 'resident'
                 when v_field then 'field' else 'contractor' end,
    'is_owner', v_owner is not null,
    'is_agent', v_agent is not null,
    'is_resident', v_resident,
    'is_field', v_field,
    'is_contractor', v_contractor,
    'verified', condo_session_ok(),
    'phone_hint', condo_mask_phone(v_phone),
    'has_phone', v_phone is not null and length(regexp_replace(v_phone, '\D', '', 'g')) >= 10
  );
end;
$$;

-- My jobs: open ones, plus anything finished in the last 30 days.
create or replace function contractor_tasks()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not exists (select 1 from contractor_me()) then raise exception 'Contractor sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'id', r.id, 'number', r.number, 'subject', r.subject, 'description', r.description, 'category', r.category, 'status', r.status,
      'unit', coalesce(ru.unit_number, r.unit_label), 'address', coalesce(ru.address, p.street, r.unit_label),
      'scheduled_start', r.scheduled_start, 'scheduled_end', r.scheduled_end, 'entry_permission', r.entry_permission, 'entry_purpose', r.entry_purpose,
      'has_pets', r.has_pets, 'pets_note', r.pets_note, 'photo_count', cardinality(r.photos), 'notes', r.contractor_notes, 'created_at', r.created_at)
      order by (r.status in ('completed', 'closed')), r.scheduled_start nulls last, r.created_at)
    from maintenance_requests r
    left join leases l on l.id = r.lease_id left join rental_units ru on ru.id = l.unit_id left join rental_properties p on p.id = ru.property_id
    where r.vendor_id in (select contractor_me())
      and (r.status not in ('completed', 'closed') or coalesce(r.closed_at, r.contractor_updated_at, r.updated_at) > now() - interval '30 days')), '[]'::jsonb);
end;
$$;
revoke all on function contractor_tasks() from public, anon;
grant execute on function contractor_tasks() to authenticated;

create or replace function contractor_update(p_id uuid, p_status text, p_note text)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare v_note text;
begin
  if auth.uid() is null or not exists (select 1 from contractor_me()) then raise exception 'Contractor sign-in required' using errcode = '42501'; end if;
  if p_status not in ('in_progress', 'completed') then raise exception 'Choose started or done'; end if;
  if not exists (select 1 from maintenance_requests where id = p_id and vendor_id in (select contractor_me())) then raise exception 'That job is not assigned to you'; end if;
  if p_status = 'completed' and coalesce(trim(p_note), '') = '' then raise exception 'Write a short note about what you did'; end if;
  v_note := nullif(trim(p_note), '');
  update maintenance_requests set status = p_status, updated_at = now(), contractor_updated_at = now(),
    contractor_notes = case when v_note is null then contractor_notes
                            else coalesce(contractor_notes || E'\n', '') || to_char(now() at time zone 'America/Chicago', 'FMMM/FMDD FMHH12:MI AM') || ' - ' || v_note end
  where id = p_id and vendor_id in (select contractor_me());
end;
$$;
revoke all on function contractor_update(uuid, text, text) from public, anon;
grant execute on function contractor_update(uuid, text, text) to authenticated;
