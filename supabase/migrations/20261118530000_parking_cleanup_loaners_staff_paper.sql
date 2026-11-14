-- Parking, the rest of the list (Stephen, 11/8/2026):
--   A. The stall is cleared when a unit is SOLD (the old owner's vehicles and "no vehicle" answer end when the ownership stops being current)
--      and when John REMOVES Unit 6's parking-and-keys person (only that person's vehicles end). The office gets "Stall X cleared" with the
--      hanger numbers to collect. Unit 6's person is never named: their registrations are marked occupant:<id> (no email, no name).
--   B. Loaners: the day before the "return by" date the person who registered it is emailed (extend it or remove it). Anyone who may register
--      for the stall can extend a loaner (vehicle_loaner_extend). After the date it is no longer allowed on Always Towing's page (as before).
--   C. Staff help for residents who cannot do it themselves: staff add a vehicle for a unit (vehicles_staff_add, photos optional), and record a
--      rules signature made ON PAPER (parking_ack_staff_paper: a photo or PDF of the signed printout instead of the voice recording).
--   E. Always Towing's charge is a fine line everyone initials: "Towing by Always Towing: $400 to $500".
-- Nobody has signed the rules yet, so adding the towing line asks no one to sign again.
-- No new table, so no new grants.

-- ---------------------------------------------------------------------------
-- A. Clearing helper and the office email
create or replace function parking_clear_vehicles(p_unit text, p_where text, p_why text)
returns int
language plpgsql volatile security definer set search_path = public as $$
declare v_list text; v_hangers text; n int;
begin
  execute format('select string_agg(vehicle_summary(v), ''; ''), string_agg(v.hanger_number, '', '') filter (where v.hanger_number is not null)
                    from vehicles v where v.unit_number = %L and v.status = ''active'' and (%s)', p_unit, p_where) into v_list, v_hangers;
  execute format('update vehicles v set status = ''ended'', ended_at = now(), updated_at = now(), notes = concat_ws('' '', nullif(v.notes, ''''), %L)
                   where v.unit_number = %L and v.status = ''active'' and (%s)', '[Ended: ' || p_why || ' ' || to_char(current_date, 'FMMM/FMDD/YYYY') || '.]', p_unit, p_where);
  get diagnostics n = row_count;
  if n > 0 then
    insert into email_outbox (to_email, subject, html, kind) values ('info@2ndchinc.org', 'Stall ' || p_unit || ' cleared: ' || p_why,
      '<div style="font-family:Arial,sans-serif;max-width:640px;color:#1b2430"><p><b>Stall ' || repair_esc(p_unit) || '</b>: ' || repair_esc(p_why) || '.</p>'
      || '<p>Removed from the registered vehicles (no longer allowed on Always Towing''s page): ' || repair_esc(v_list) || '.</p>'
      || case when v_hangers is not null then '<p><b>Collect parking hanger #' || repair_esc(v_hangers) || '.</b></p>' else '' end
      || '<p>https://2ndchinc.org/parking/</p></div>', 'parking_moveout');
  end if;
  return n;
end;
$$;
revoke all on function parking_clear_vehicles(text, text, text) from public, anon, authenticated;

-- Sale: the ownership stops being current (or is deleted).
create or replace function parking_on_ownership_end()
returns trigger
language plpgsql security definer set search_path = public as $$
declare v_unit text; v_email text;
begin
  if tg_op = 'UPDATE' and not (old.is_current and not new.is_current) then return new; end if;
  if tg_op = 'DELETE' and not old.is_current then return old; end if;
  select unit_number into v_unit from condo_units where id = old.unit_id;
  select lower(email) into v_email from condo_owners where id = old.owner_id;
  if v_unit is not null and v_email like '%@%' then
    perform parking_clear_vehicles(v_unit, format('v.tenant_id is null and v.registered_by = %L', v_email), 'the owner''s ownership ended');
    delete from parking_declarations where unit_number = v_unit and declared_by = v_email;
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$$;
revoke all on function parking_on_ownership_end() from public, anon, authenticated;
drop trigger if exists condo_ownerships_parking_clear on condo_ownerships;
create trigger condo_ownerships_parking_clear after update of is_current or delete on condo_ownerships
  for each row execute function parking_on_ownership_end();

-- Unit 6: registrations by the parking-and-keys person carry their occupant id, so removing one person ends only their vehicles.
do $$ declare f text; v text; n text; begin
  foreach f in array array['vehicle_reg_save(text, uuid, text, text, text, text, integer, text, text, text, text, date, date, text, text, text, text, text, text)',
                           'vehicle_reg_declare(text, boolean, boolean, text)'] loop
    v := pg_get_functiondef(f::regprocedure);
    n := replace(v, 'case when v_role = ''occupant'' then ''unit occupant'' else lower(auth.email()) end',
      'case when v_role = ''occupant'' then ''occupant:'' || coalesce((select o.id::text from unit_occupants o where o.active and lower(o.email) = lower(auth.email()) and o.unit_number = p_unit limit 1), '''') else lower(auth.email()) end');
    if n = v then raise exception '% changed; update this migration', f; end if;
    execute n;
  end loop;
end $$;

create or replace function parking_on_occupant_removed()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.active and not new.active then
    perform parking_clear_vehicles(new.unit_number, format('v.registered_by = %L', 'occupant:' || new.id::text)
      || case when not exists (select 1 from unit_occupants o where o.active and o.unit_number = new.unit_number and o.id <> new.id) then ' or v.registered_by = ''unit occupant''' else '' end,
      'the owner removed the unit''s parking-and-keys person');
    delete from parking_declarations where unit_number = new.unit_number and declared_by in ('occupant:' || new.id::text, 'unit occupant');
  end if;
  return new;
end;
$$;
revoke all on function parking_on_occupant_removed() from public, anon, authenticated;
drop trigger if exists unit_occupants_parking_clear on unit_occupants;
create trigger unit_occupants_parking_clear after update of active on unit_occupants for each row execute function parking_on_occupant_removed();

-- Staff screens: Unit 6's person shows as "Unit 6 occupant", staff additions as "office".
create or replace function parking_who_label(p_unit text, p_by text)
returns text language sql immutable as $$
  select case when p_by like 'occupant:%' or p_by = 'unit occupant' then 'Unit ' || p_unit || ' occupant'
              when p_by like 'staff:%' then 'office (' || substr(p_by, 7) || ')' else p_by end;
$$;

create or replace function vehicles_staff_list()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'vehicles', coalesce((select jsonb_agg((to_jsonb(v) - 'registered_by') || jsonb_build_object('registered_by', parking_who_label(v.unit_number, v.registered_by),
        'tenant', (select name from tenants where id = v.tenant_id), 'summary', vehicle_summary(v))
        order by v.status, nullif(regexp_replace(v.unit_number, '\D', '', 'g'), '')::int nulls last, v.created_at desc) from vehicles v), '[]'::jsonb),
    'declarations', coalesce((select jsonb_agg((to_jsonb(d) - 'declared_by') || jsonb_build_object('declared_by', parking_who_label(d.unit_number, d.declared_by),
        'tenant', (select name from tenants where id = d.tenant_id)) order by d.unit_number) from parking_declarations d), '[]'::jsonb),
    'units_without', coalesce((select jsonb_agg(s.home_unit order by nullif(regexp_replace(s.home_unit, '\D', '', 'g'), '')::int nulls last) from parking_stalls s
        where s.kind = 'unit' and s.active
          and not exists (select 1 from vehicles v where v.unit_number = s.home_unit and v.status = 'active')
          and not exists (select 1 from parking_declarations d where d.unit_number = s.home_unit and d.no_vehicle)), '[]'::jsonb),
    'register_by', condo_setting('vehicle_register_by', ''), 'enforce_from', condo_setting('tow_enforce_from', ''),
    'tow_link_set', coalesce(condo_setting('tow_link_hash', ''), '') <> '',
    'tow_views', coalesce((select jsonb_agg(jsonb_build_object('at', t.viewed_at) order by t.viewed_at desc) from (select viewed_at from tow_link_views order by viewed_at desc limit 10) t), '[]'::jsonb));
end;
$$;
revoke all on function vehicles_staff_list() from public, anon;
grant execute on function vehicles_staff_list() to authenticated;

-- ---------------------------------------------------------------------------
-- B. Loaners
alter table vehicles add column if not exists loaner_reminded_at timestamptz;

create or replace function vehicle_loaner_extend(p_id uuid, p_until date)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare v vehicles;
begin
  if autopay_view_as_session() then raise exception 'Not available while viewing as someone else.'; end if;
  select * into v from vehicles where id = p_id and status = 'active' and kind = 'loaner';
  if v.id is null or not (v.unit_number in (select unit_number from vehicle_reg_units()) or (condo_session_ok() and condo_is_staff())) then
    raise exception 'Loaner not found.' using errcode = '42501'; end if;
  if p_until is null or p_until < (now() at time zone 'America/Chicago')::date then raise exception 'Choose the new return date (today or later).'; end if;
  if p_until > (now() at time zone 'America/Chicago')::date + 90 then raise exception 'A loaner can be registered for up to 90 days at a time.'; end if;
  update vehicles set loaner_until = p_until, loaner_reminded_at = null, updated_at = now() where id = v.id returning * into v;
  perform vehicle_alert('Loaner extended - Unit ' || v.unit_number, '<p>Unit ' || v.unit_number || ': ' || repair_esc(vehicle_summary(v)) || '</p>');
end;
$$;
revoke all on function vehicle_loaner_extend(uuid, date) from public, anon;
grant execute on function vehicle_loaner_extend(uuid, date) to authenticated;

-- Daily (8 a.m. Central): loaners due back tomorrow -> email whoever registered it.
create or replace function parking_loaner_reminders()
returns int
language plpgsql volatile security definer set search_path = public as $$
declare v vehicles; v_to text; v_link text; n int := 0; v_tomorrow date := (now() at time zone 'America/Chicago')::date + 1;
begin
  for v in select * from vehicles where status = 'active' and kind = 'loaner' and loaner_until = v_tomorrow and loaner_reminded_at is null loop
    v_to := case when v.registered_by like '%@%' then v.registered_by
                 when v.registered_by like 'occupant:%' then (select lower(o.email) from unit_occupants o where o.id::text = substr(v.registered_by, 10) and o.active)
                 else (select lower(t.email) from tenants t where t.id = v.tenant_id) end;
    if coalesce(v_to, '') not like '%@%' then continue; end if;
    v_link := 'https://2ndchinc.org' || case when exists (select 1 from tenants t where lower(t.email) = v_to) then '/resident/#parking'
                                             when exists (select 1 from unit_occupants o where o.active and lower(o.email) = v_to) then '/unit-access/#parking'
                                             else '/association-owners/roca1/#parking' end;
    insert into email_outbox (to_email, subject, html, kind) values (v_to, 'Your loaner registration ends tomorrow (stall ' || v.unit_number || ')',
      '<div style="font-family:Arial,sans-serif;max-width:640px;color:#1b2430"><p>Your loaner, <b>' || repair_esc(vehicle_summary(v)) || '</b>, is registered for stall '
      || repair_esc(v.unit_number) || ' until <b>' || to_char(v.loaner_until, 'FMMM/FMDD/YYYY') || '</b>.</p>'
      || '<p>After that day it is not allowed in the lot and can be towed ($400 to $500). If you still have it, press <b>Extend</b> on your Parking tab: '
      || '<a href="' || v_link || '">' || v_link || '</a>. If you returned it, press Remove.</p>'
      || '<p style="color:#5b6573;font-size:13px">2nd Chance Housing, ' || repair_esc(condo_setting('org_phone', '')) || '</p></div>', 'parking_loaner');
    update vehicles set loaner_reminded_at = now() where id = v.id;
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke all on function parking_loaner_reminders() from public, anon, authenticated;
select cron.unschedule('parking-loaner-remind') where exists (select 1 from cron.job where jobname = 'parking-loaner-remind');
select cron.schedule('parking-loaner-remind', '0 14 * * *', 'select parking_loaner_reminders()');

-- The "Your stall" card gets each vehicle's id (for Extend).
do $$ declare v text := pg_get_functiondef('parking_status_mine()'::regprocedure); n text; begin
  n := replace(v, 'jsonb_build_object(''kind'', v.kind, ''desc'',', 'jsonb_build_object(''id'', v.id, ''kind'', v.kind, ''desc'',');
  if n = v then raise exception 'parking_status_mine changed; update this migration'; end if;
  execute n;
end $$;

-- ---------------------------------------------------------------------------
-- C. Staff add a vehicle for a unit (photos optional), and paper signatures.
create or replace function vehicles_staff_add(p_unit text, p_kind text, p_make text, p_model text, p_color text, p_year int, p_plate text, p_plate_state text, p_vin text,
  p_loaner_until date, p_visitor_name text, p_visitor_frequency text, p_notes text, p_front text, p_back text, p_hanger text)
returns uuid
language plpgsql volatile security definer set search_path = public as $$
declare v_id uuid := gen_random_uuid(); v_lease uuid; v_tenant uuid; v_vin text := upper(regexp_replace(coalesce(p_vin, ''), '[^A-Za-z0-9]', '', 'g')); v_row vehicles;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if autopay_view_as_session() then raise exception 'Not available while viewing as someone else.'; end if;
  if not exists (select 1 from parking_stalls where kind = 'unit' and active and home_unit = p_unit) then raise exception 'No stall for Unit %.', p_unit; end if;
  if p_kind not in ('own', 'loaner', 'visitor') then raise exception 'Choose the kind.'; end if;
  if p_kind in ('own', 'loaner') and (coalesce(trim(p_make), '') = '' or coalesce(trim(p_model), '') = '' or coalesce(trim(p_color), '') = '' or coalesce(trim(p_plate), '') = '') then
    raise exception 'Enter the make, model, color and plate.'; end if;
  if p_kind = 'loaner' and p_loaner_until is null then raise exception 'Enter the loaner''s return date.'; end if;
  if p_kind = 'visitor' and coalesce(trim(p_visitor_name), '') = '' then raise exception 'Enter the visitor''s name.'; end if;
  if v_vin <> '' and v_vin !~ '^[A-HJ-NPR-Z0-9]{17}$' then raise exception 'A VIN has 17 letters and numbers (never I, O or Q).'; end if;
  if p_kind = 'own' and exists (select 1 from vehicles where unit_number = p_unit and kind = 'own' and status = 'active') then
    raise exception 'Unit % already has a vehicle registered. Mark it removed first, or add a loaner.', p_unit; end if;
  if (p_front is not null and p_front not like p_unit || '/%') or (p_back is not null and p_back not like p_unit || '/%') then raise exception 'Bad photo'; end if;
  select l.id, (select lt.tenant_id from lease_tenants lt where lt.lease_id = l.id limit 1) into v_lease, v_tenant
    from leases l join rental_units ru on ru.id = l.unit_id where l.status = 'active' and ru.unit_number = p_unit limit 1;
  insert into vehicles (id, unit_number, lease_id, tenant_id, kind, make, model, color, year, plate, plate_state, vin, loaner_until, loaner_reason,
                        visitor_name, visitor_frequency, notes, front_path, back_path, hanger_number, registered_by)
  values (v_id, p_unit, v_lease, v_tenant, p_kind, nullif(trim(p_make), ''), nullif(trim(p_model), ''), nullif(trim(p_color), ''), p_year, upper(nullif(trim(p_plate), '')),
          upper(nullif(trim(p_plate_state), '')), nullif(v_vin, ''), p_loaner_until, case when p_kind = 'loaner' then 'Entered by the office' end,
          nullif(trim(p_visitor_name), ''), nullif(trim(p_visitor_frequency), ''), nullif(trim(p_notes), ''), p_front, p_back, nullif(upper(trim(p_hanger)), ''),
          'staff:' || lower(auth.email()))
  returning * into v_row;
  perform vehicle_alert('Vehicle added by the office - Unit ' || p_unit, '<p>' || repair_esc(vehicle_summary(v_row)) || ' (entered by ' || repair_esc(lower(auth.email())) || ').</p>');
  return v_id;
end;
$$;
revoke all on function vehicles_staff_add(text, text, text, text, text, int, text, text, text, date, text, text, text, text, text, text) from public, anon;
grant execute on function vehicles_staff_add(text, text, text, text, text, int, text, text, text, date, text, text, text, text, text, text) to authenticated;

-- Paper signatures: a scan instead of the recording.
alter table parking_acks add column if not exists method text not null default 'voice';
alter table parking_acks add column if not exists scan_path text;
alter table parking_acks add column if not exists entered_by text;
alter table parking_acks alter column audio_path drop not null;
alter table parking_acks drop constraint if exists parking_acks_method_check;
alter table parking_acks add constraint parking_acks_method_check check (method in ('voice', 'paper') and (audio_path is not null or scan_path is not null));

update storage.buckets set allowed_mime_types = array['audio/webm', 'audio/mp4', 'audio/ogg', 'audio/mpeg', 'audio/aac', 'audio/x-m4a', 'audio/wav', 'audio/x-wav', 'audio/3gpp',
  'image/jpeg', 'image/png', 'image/webp', 'application/pdf'], file_size_limit = 10485760 where id = 'parking-acks';
drop policy if exists "parking acks paper upload staff" on storage.objects;
create policy "parking acks paper upload staff" on storage.objects for insert to authenticated
  with check (bucket_id = 'parking-acks' and (storage.foldername(name))[1] = 'paper' and condo_is_staff());
drop policy if exists "parking acks paper read signer" on storage.objects;
create policy "parking acks paper read signer" on storage.objects for select to authenticated
  using (bucket_id = 'parking-acks' and (storage.foldername(name))[1] = 'paper'
         and exists (select 1 from parking_acks a where a.scan_path = name and lower(a.email) = lower(auth.email())));

-- The people who may sign for a stall, for the staff paper form (Unit 6's person only as "Unit 6 occupant").
create or replace function parking_paper_people(p_unit text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('key', x.key, 'label', x.label)) from (
      select 't:' || t.id key, t.name || ' (tenant)' label from leases l join rental_units ru on ru.id = l.unit_id join lease_tenants lt on lt.lease_id = l.id join tenants t on t.id = lt.tenant_id
       where l.status = 'active' and ru.unit_number = p_unit and t.email like '%@%'
      union all
      select 'o:' || o.id, o.name || ' (owner)' from condo_units cu join condo_ownerships s on s.unit_id = cu.id and s.is_current join condo_owners o on o.id = s.owner_id
       where cu.unit_number = p_unit and o.email like '%@%' and (cu.occupancy = 'owner' or not exists (select 1 from leases l join rental_units ru on ru.id = l.unit_id where l.status = 'active' and ru.unit_number = p_unit))
         and p_unit <> all (owner_direct_unit_list())
      union all
      select 'u:' || u.id, 'Unit ' || p_unit || ' occupant' || case when count(*) over () > 1 then ' #' || row_number() over (order by u.created_at) else '' end
        from unit_occupants u where u.active and u.unit_number = p_unit) x), '[]'::jsonb);
end;
$$;
revoke all on function parking_paper_people(text) from public, anon;
grant execute on function parking_paper_people(text) to authenticated;

create or replace function parking_ack_staff_paper(p_unit text, p_key text, p_initials text, p_signed_on date, p_scan_path text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_email text; v_name text; v_kind text; v_items jsonb; a parking_acks; v_ini text := upper(regexp_replace(coalesce(p_initials, ''), '[^A-Za-z.\- ]', '', 'g'));
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if autopay_view_as_session() then raise exception 'Not available while viewing as someone else.'; end if;
  if p_key like 't:%' then select lower(email), name, 'tenant' into v_email, v_name, v_kind from tenants where id::text = substr(p_key, 3);
  elsif p_key like 'o:%' then select lower(email), name, 'owner' into v_email, v_name, v_kind from condo_owners where id::text = substr(p_key, 3);
  elsif p_key like 'u:%' then select lower(email), name, 'occupant' into v_email, v_name, v_kind from unit_occupants where id::text = substr(p_key, 3) and active and unit_number = p_unit;
  end if;
  if v_email is null then raise exception 'Choose who signed.'; end if;
  if not exists (select 1 from jsonb_array_elements(parking_paper_people(p_unit)) x where x ->> 'key' = p_key) then raise exception 'That person does not park in stall %.', p_unit; end if;
  if length(trim(v_ini)) < 2 then raise exception 'Enter the initials written on the paper.'; end if;
  if p_signed_on is null or p_signed_on > current_date then raise exception 'Enter the date written on the paper.'; end if;
  if p_scan_path is null or p_scan_path !~ '^paper/[0-9a-f-]{36}\.(jpg|jpeg|png|webp|pdf)$' or not exists (select 1 from storage.objects o where o.bucket_id = 'parking-acks' and o.name = p_scan_path) then
    raise exception 'Upload the photo or PDF of the signed paper first.'; end if;
  select jsonb_agg(jsonb_build_object('kind', t.kind, 'position', t.position, 'text', t.text, 'amount', t.amount, 'initials', v_ini, 'at', p_signed_on::text) order by t.kind desc, t.position)
    into v_items from parking_terms t where t.active;
  insert into parking_acks (email, person_kind, person_name, unit_number, terms_version, items, initials, statement, audio_path, audio_seconds, user_agent, signed_at, method, scan_path, entered_by)
  values (v_email, v_kind, v_name, p_unit, parking_terms_version(), v_items, v_ini, condo_setting('parking_ack_statement', ''), null, null, 'paper (entered by the office)',
          (p_signed_on::timestamp + time '12:00') at time zone 'America/Chicago', 'paper', p_scan_path, lower(auth.email()))
  returning * into a;
  return jsonb_build_object('id', a.id);
end;
$$;
revoke all on function parking_ack_staff_paper(text, text, text, date, text) from public, anon;
grant execute on function parking_ack_staff_paper(text, text, text, date, text) to authenticated;

-- The signed copy shows how it was signed.
create or replace function parking_ack_row(a parking_acks)
returns jsonb
language sql stable as $$
  select jsonb_build_object('id', a.id, 'unit', a.unit_number, 'name', a.person_name, 'initials', a.initials, 'items', a.items, 'statement', a.statement,
    'audio_path', a.audio_path, 'audio_seconds', a.audio_seconds, 'signed_at', a.signed_at, 'version', a.terms_version, 'method', a.method, 'scan_path', a.scan_path);
$$;
revoke all on function parking_ack_row(parking_acks) from public, anon, authenticated;

do $$ declare v text := pg_get_functiondef('parking_acks_staff()'::regprocedure); n text; begin
  n := replace(v, '''audio_path'', a.audio_path,', '''audio_path'', a.audio_path, ''method'', a.method, ''scan_path'', a.scan_path,');
  if n = v then raise exception 'parking_acks_staff changed; update this migration'; end if;
  execute n;
end $$;

-- ---------------------------------------------------------------------------
-- E. The tow company's charge, initialed with the other fines.
insert into parking_terms (kind, position, text, amount)
select 'fine', 15, 'Towing by Always Towing (paid by the vehicle owner to get the vehicle back)', '$400 to $500'
where not exists (select 1 from parking_terms where kind = 'fine' and text like 'Towing by Always Towing%');
