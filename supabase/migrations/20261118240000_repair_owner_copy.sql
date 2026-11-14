-- Repair requests: the unit's owner is copied on the whole maintenance thread (Stephen, 11/5/2026).
--   repair_owner_cc_units      units whose current owner gets a copy of every message on a repair request (start: 13, 15, 16, 17).
--   repair_owner_handles_units units where the OWNER is responsible for the repair (start: 16). That owner also gets a Repairs tab in
--                              the owner portal where they post updates and mark it in progress or done; the tenant and the office are emailed.
-- Owner copies never include the tenant's phone or email (the owner portal does not share tenant contact details).
-- Owners whose email is a 2nd Chance address (2nd Chance Housing Inc) are skipped: the office already gets the staff copy.

insert into portal_settings (key, value) values
  ('repair_owner_cc_units', '13,15,16,17'),
  ('repair_owner_handles_units', '16'),
  ('owner_portal_url', 'https://2ndchinc.org/association-owners/roca1/')
on conflict (key) do nothing;

create or replace function repair_setting_units(p_key text) returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(trim(x)), '{}') from unnest(string_to_array(condo_setting(p_key, ''), ',')) x where trim(x) <> '';
$$;

-- The rental unit number of a repair request (from its lease, else from the address it was filed under).
create or replace function repair_unit_number(p_request uuid) returns text
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select u.unit_number from maintenance_requests r join leases l on l.id = r.lease_id join rental_units u on u.id = l.unit_id where r.id = p_request),
    (select u.unit_number from maintenance_requests r join rental_units u on u.address = r.unit_label where r.id = p_request and coalesce(r.unit_label, '') <> '' limit 1));
$$;

create or replace function repair_owner_handles(p_request uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(repair_unit_number(p_request) = any (repair_setting_units('repair_owner_handles_units')), false);
$$;

-- Current owners of a unit who are copied on its repairs (only units in repair_owner_cc_units; never a 2nd Chance address).
create or replace function repair_unit_owners(p_unit text)
returns table (owner_id uuid, name text, email text)
language sql stable security definer set search_path = public as $$
  select distinct o.id, o.name, o.email
    from condo_units cu join condo_ownerships s on s.unit_id = cu.id and s.is_current join condo_owners o on o.id = s.owner_id
   where cu.unit_number = p_unit and p_unit = any (repair_setting_units('repair_owner_cc_units'))
     and o.email is not null and o.email not ilike '%@2ndchinc.org'
     and lower(o.email) <> lower(condo_setting('office_email', ''));
$$;

-- Copy one message of a repair thread to the unit's owner(s). p_skip: the owner who wrote it (no echo).
create or replace function repair_email_owners(p_request uuid, p_subject text, p_body text, p_skip uuid default null) returns void
language plpgsql security definer set search_path = public as $$
declare r maintenance_requests; v_unit text := repair_unit_number(p_request); v_handles boolean := repair_owner_handles(p_request); o record;
begin
  if v_unit is null then return; end if;
  select * into r from maintenance_requests where id = p_request;
  for o in select * from repair_unit_owners(v_unit) where owner_id is distinct from p_skip loop
    insert into email_outbox (to_email, subject, html, kind) values (o.email, 'Unit ' || v_unit || ' — ' || p_subject,
      '<p>Hi ' || repair_esc(split_part(o.name, ' ', 1)) || ',</p>' ||
      '<p>You are copied on this repair request for your Unit ' || repair_esc(v_unit) || coalesce(' (' || repair_esc(nullif(r.unit_label, '')) || ')', '') || '.</p>' ||
      p_body ||
      case when v_handles then
        '<p><b>You are responsible for this repair.</b> Please arrange it and post each update (and mark it done) on the Repairs tab of your owner portal: ' ||
        '<a href="' || condo_setting('owner_portal_url', 'https://2ndchinc.org/association-owners/roca1/') || '#repairs">Repairs</a>. Your tenant and our office get every update by email.</p>'
      else
        '<p>2nd Chance is handling this repair; you don''t need to do anything. You can follow it on the Repairs tab of your owner portal: ' ||
        '<a href="' || condo_setting('owner_portal_url', 'https://2ndchinc.org/association-owners/roca1/') || '#repairs">Repairs</a>.</p>'
      end ||
      '<p>Questions? Call ' || condo_setting('org_phone', '') || '.</p><p>2nd Chance Housing</p>', 'repair_owner');
  end loop;
end;
$$;

-- Tenant emails now also copy the owner (prefaced as a copy). p_copy_owners false when the owner wrote the update.
drop function if exists repair_email_tenants(uuid, text, text);
create or replace function repair_email_tenants(p_request uuid, p_subject text, p_body text, p_copy_owners boolean default true) returns void
language plpgsql security definer set search_path = public as $$
declare r maintenance_requests; t record;
begin
  select * into r from maintenance_requests where id = p_request;
  for t in select distinct x.name, x.email from tenants x
           where x.email is not null and (x.id = r.tenant_id or x.id in (select tenant_id from lease_tenants where lease_id = r.lease_id)) loop
    insert into email_outbox (to_email, subject, html, kind) values (t.email, p_subject,
      '<p>Hi ' || replace(replace(split_part(t.name, ' ', 1), '<', ''), '>', '') || ',</p>' || p_body ||
      '<p>See your request in the resident portal: <a href="' || (select value from portal_settings where key = 'resident_url') || '#requests">Requests</a>.</p>' ||
      '<p>For an emergency, call ' || (select value from portal_settings where key = 'emergency_phone') || '.</p><p>2nd Chance Housing</p>', 'repair');
  end loop;
  if p_copy_owners then
    perform repair_email_owners(p_request, p_subject, '<p><i>Copy of the message sent to your tenant:</i></p><blockquote>' || p_body || '</blockquote>');
  end if;
end;
$$;

create or replace function resident_create_request(p_category text, p_subject text, p_description text, p_entry text, p_has_pets boolean, p_pets_note text, p_photos text[])
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_ids uuid[] := array(select resident_me()); v_lease uuid; v_unit text; r maintenance_requests; v_tenant text; v_tname text; v_handles boolean; v_facts text;
begin
  perform resident_require_current();
  if cardinality(v_ids) = 0 then raise exception 'Resident two-step sign-in required' using errcode = '42501'; end if;
  if p_category is null or p_category not in ('plumbing', 'fixtures', 'keys', 'doors', 'windows', 'heat', 'electric', 'pests', 'other') then raise exception 'Choose what kind of problem it is.'; end if;
  if length(trim(coalesce(p_subject, ''))) < 2 or length(trim(coalesce(p_description, ''))) < 5 then raise exception 'Please describe the problem.'; end if;
  if p_entry is null or p_entry not in ('yes', 'no', 'call_first') then raise exception 'Tell us whether we may enter if you''re not home.'; end if;
  if p_has_pets is null then raise exception 'Tell us whether there are animals in the unit.'; end if;
  if p_has_pets and length(trim(coalesce(p_pets_note, ''))) < 2 then raise exception 'Tell us about the animal (kind, and whether it will be put away).'; end if;
  if exists (select 1 from unnest(coalesce(p_photos, '{}')) ph where split_part(ph, '/', 1) !~ '^[0-9a-f-]{36}$' or split_part(ph, '/', 1)::uuid <> all(v_ids)) then raise exception 'Bad photo path'; end if;
  select l.id, coalesce(u.address, '') into v_lease, v_unit from leases l join rental_units u on u.id = l.unit_id
   where l.status in ('active', 'future') and exists (select 1 from lease_tenants x where x.lease_id = l.id and x.tenant_id = any(v_ids))
   order by l.start_date desc limit 1;
  insert into maintenance_requests (tenant_id, lease_id, unit_label, category, subject, description, entry_permission, has_pets, pets_note, photos)
  values (v_ids[1], v_lease, v_unit, p_category, left(trim(p_subject), 120), left(trim(p_description), 4000), p_entry,
          p_has_pets, case when p_has_pets then left(trim(p_pets_note), 300) end, coalesce(p_photos[1:6], '{}'))
  returning * into r;
  insert into maintenance_request_updates (request_id, by_email, status, note, from_resident) values (r.id, auth.email(), 'new', 'Request submitted', true);
  select name || coalesce(' · ' || phone, ''), name into v_tenant, v_tname from tenants where id = v_ids[1];
  v_handles := repair_owner_handles(r.id);
  v_facts := '<br>Permission to enter: ' || case p_entry when 'yes' then 'Yes, may enter' when 'no' then 'No, only when home' else 'Call first' end ||
    '<br>Animals: ' || case when p_has_pets then 'Yes — ' || repair_esc(r.pets_note) else 'None' end ||
    '<br>Photos: ' || coalesce(array_length(r.photos, 1), 0) || '</p>';
  perform repair_email_staff(r.id, 'Repair request #' || r.number || ' — ' || repair_category_label(r.category) || ' — ' || coalesce(nullif(v_unit, ''), 'no unit') ||
      case when v_handles then ' (owner handles)' else '' end,
    '<p><b>' || repair_esc(r.subject) || '</b> (' || repair_category_label(r.category) || ')</p><p>' || repair_esc(r.description) || '</p>' ||
    '<p>Unit: ' || repair_esc(coalesce(nullif(v_unit, ''), '—')) || '<br>Tenant: ' || repair_esc(v_tenant) || v_facts ||
    case when v_handles then '<p><b>The owner is responsible for repairs in this unit</b> and was emailed a copy. They post updates from the owner portal.</p>' else '' end);
  perform repair_email_owners(r.id, 'New repair request #' || r.number || ': ' || r.subject,
    '<p>Your tenant' || coalesce(' (' || repair_esc(v_tname) || ')', '') || ' submitted a repair request:</p>' ||
    '<p><b>' || repair_esc(r.subject) || '</b> (' || repair_category_label(r.category) || ')</p><p>' || repair_esc(r.description) || '</p><p>' || substr(v_facts, 5));
  return jsonb_build_object('id', r.id, 'number', r.number);
end;
$$;

create or replace function resident_request_comment(p_id uuid, p_note text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r maintenance_requests;
begin
  perform resident_require_current();
  if not resident_can_see_request(p_id) then raise exception 'Request not found.' using errcode = '42501'; end if;
  if length(trim(coalesce(p_note, ''))) < 2 then raise exception 'Write your comment first.'; end if;
  select * into r from maintenance_requests where id = p_id;
  if r.status = 'closed' then raise exception 'This request is closed. Send a new request if the problem is back.'; end if;
  insert into maintenance_request_updates (request_id, by_email, note, from_resident) values (p_id, auth.email(), left(trim(p_note), 2000), true);
  update maintenance_requests set updated_at = now() where id = p_id;
  perform repair_email_staff(p_id, 'Tenant comment on repair request #' || r.number,
    '<p>On <b>' || repair_esc(r.subject) || '</b> (' || repair_esc(coalesce(r.unit_label, '')) || '):</p><p><i>' || repair_esc(left(trim(p_note), 2000)) || '</i></p>');
  perform repair_email_owners(p_id, 'Tenant comment on repair request #' || r.number,
    '<p>Your tenant commented on <b>' || repair_esc(r.subject) || '</b>:</p><p><i>' || repair_esc(left(trim(p_note), 2000)) || '</i></p>');
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function resident_request_confirm(p_id uuid, p_fixed boolean, p_note text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare r maintenance_requests;
begin
  perform resident_require_current();
  if not resident_can_see_request(p_id) then raise exception 'Request not found.' using errcode = '42501'; end if;
  select * into r from maintenance_requests where id = p_id;
  if r.status <> 'completed' then raise exception 'You can confirm once we mark the repair as done.'; end if;
  if p_fixed then
    update maintenance_requests set status = 'closed', resident_confirmed_at = now(), closed_at = now(), updated_at = now() where id = p_id;
    insert into maintenance_request_updates (request_id, by_email, status, note, from_resident)
    values (p_id, auth.email(), 'closed', 'Tenant confirmed it''s fixed' || coalesce(': ' || nullif(left(trim(p_note), 2000), ''), '.'), true);
    perform repair_email_staff(p_id, 'Repair request #' || r.number || ' confirmed fixed', '<p>The tenant confirmed <b>' || repair_esc(r.subject) || '</b> is fixed. It is closed.</p>');
    perform repair_email_owners(p_id, 'Repair request #' || r.number || ' confirmed fixed', '<p>Your tenant confirmed <b>' || repair_esc(r.subject) || '</b> is fixed. The request is closed.</p>');
  else
    if length(trim(coalesce(p_note, ''))) < 2 then raise exception 'Tell us what is still wrong.'; end if;
    update maintenance_requests set status = 'in_progress', updated_at = now() where id = p_id;
    insert into maintenance_request_updates (request_id, by_email, status, note, from_resident)
    values (p_id, auth.email(), 'in_progress', 'Tenant says it''s not fixed: ' || left(trim(p_note), 2000), true);
    perform repair_email_staff(p_id, 'NOT fixed — repair request #' || r.number,
      '<p>The tenant says <b>' || repair_esc(r.subject) || '</b> (' || repair_esc(coalesce(r.unit_label, '')) || ') is not fixed:</p><p><i>' || repair_esc(left(trim(p_note), 2000)) || '</i></p><p>It is back to In progress.</p>');
    perform repair_email_owners(p_id, 'NOT fixed — repair request #' || r.number,
      '<p>Your tenant says <b>' || repair_esc(r.subject) || '</b> is not fixed:</p><p><i>' || repair_esc(left(trim(p_note), 2000)) || '</i></p><p>It is back to In progress.</p>');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- Schedule: the 12-hour-notice path does not email through repair_email_tenants, so copy the owner here.
create or replace function maintenance_staff_schedule(p_id uuid, p_vendor uuid, p_start timestamp with time zone, p_end timestamp with time zone, p_purpose text, p_notice boolean)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r maintenance_requests; v_when text; v_html text; v_tpl uuid;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into r from maintenance_requests where id = p_id;
  if r.id is null then raise exception 'Request not found'; end if;
  if r.status in ('completed', 'closed') then raise exception 'This request is already done.'; end if;
  if p_start is null or p_end is null or p_end <= p_start then raise exception 'Enter the visit date and a time window (end after start).'; end if;
  if length(trim(coalesce(p_purpose, ''))) < 3 then raise exception 'Say what the visit is for (it goes on the notice).'; end if;
  if p_notice then
    if r.lease_id is null then raise exception 'This request has no lease, so a notice can''t be made. Contact the tenant directly.'; end if;
    if p_start < now() + interval '12 hours' then raise exception 'With a 12-hour notice the visit must start at least 12 hours from now (after %).',
      to_char((now() + interval '12 hours') at time zone 'America/Chicago', 'FMMM/FMDD FMHH12:MI AM'); end if;
  elsif r.entry_permission <> 'yes' then
    raise exception 'The tenant did not give permission to enter, so send the 12-hour notice.';
  end if;
  v_when := repair_window_text(p_start, p_end);
  update maintenance_requests set status = 'scheduled', vendor_id = coalesce(p_vendor, vendor_id), scheduled_start = p_start, scheduled_end = p_end,
    entry_purpose = left(trim(p_purpose), 300), updated_at = now() where id = p_id;
  insert into maintenance_request_updates (request_id, by_email, status, note)
  values (p_id, auth.email(), 'scheduled', 'Visit scheduled: ' || v_when || coalesce(' (' || (select name from vendors where id = coalesce(p_vendor, r.vendor_id)) || ')', '') ||
          case when p_notice then '. 12-hour notice to enter sent.' else '. You gave permission to enter.' end);
  if p_notice then
    select id into v_tpl from letter_templates where template_key = '2c-12-hour-repair';
    v_html := letter_render_ctx('2c-12-hour-repair', r.lease_id, jsonb_build_object('_keep_signature', true,
      'Notice_Time', to_char(now() at time zone 'America/Chicago', 'FMHH12:MI AM'),
      'Current_Date', to_char(now() at time zone 'America/Chicago', 'FMMonth FMDD, YYYY'),
      'Entry_Date', to_char(p_start at time zone 'America/Chicago', 'FMDay, FMMonth FMDD, YYYY'),
      'Entry_Window', to_char(p_start at time zone 'America/Chicago', 'FMHH12:MI AM') || ' and ' || to_char(p_end at time zone 'America/Chicago', 'FMHH12:MI AM'),
      'Entry_Purpose', left(trim(p_purpose), 300), 'Request_Number', r.number::text));
    perform repair_email_owners(p_id, 'Repair request #' || r.number || ': Scheduled',
      '<p>The repair <b>' || repair_esc(r.subject) || '</b> is scheduled for <b>' || v_when || '</b>. Your tenant is being given a 12-hour notice to enter.</p>');
  else
    perform repair_email_tenants(p_id, 'Repair request #' || r.number || ': Scheduled',
      '<p>Your repair request <b>' || repair_esc(r.subject) || '</b> is scheduled for <b>' || v_when || '</b>. You gave us permission to enter if you''re not home.</p>');
  end if;
  return jsonb_build_object('ok', true, 'lease_id', r.lease_id, 'template_id', v_tpl, 'subject', 'Notice To Enter — repair request #' || r.number, 'html', v_html);
end;
$$;

-- Owner portal, Repairs tab: requests in the owner's copied units, with the thread the tenant sees (no tenant contact details, no staff-only notes).
create or replace function owner_repairs_mine() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_owner uuid := condo_owner_for_email(auth.email()); v_units text[];
begin
  if v_owner is null or not condo_session_ok() then raise exception 'Owner sign-in required' using errcode = '42501'; end if;
  select coalesce(array_agg(distinct cu.unit_number), '{}') into v_units from condo_ownerships s join condo_units cu on cu.id = s.unit_id
   where s.is_current and s.owner_id = v_owner and cu.unit_number = any (repair_setting_units('repair_owner_cc_units'));
  return jsonb_build_object(
    'units', (select coalesce(jsonb_agg(jsonb_build_object('unit', u, 'handles', u = any (repair_setting_units('repair_owner_handles_units'))) order by u::int), '[]'::jsonb) from unnest(v_units) u),
    'requests', coalesce((select jsonb_agg(x order by x->>'created_at' desc) from (
      select jsonb_build_object('id', r.id, 'number', r.number, 'unit', q.unit, 'handles', q.unit = any (repair_setting_units('repair_owner_handles_units')),
        'subject', r.subject, 'description', r.description, 'category', repair_category_label(r.category), 'status', r.status, 'status_label', repair_status_label(r.status),
        'created_at', r.created_at, 'entry', r.entry_permission, 'has_pets', r.has_pets, 'pets_note', r.pets_note, 'photos', coalesce(array_length(r.photos, 1), 0),
        'scheduled_start', r.scheduled_start, 'scheduled_end', r.scheduled_end,
        'updates', (select coalesce(jsonb_agg(jsonb_build_object('at', u.at, 'status_label', case when u.status is not null then repair_status_label(u.status) end, 'note', u.note,
                      'by', case when u.from_resident then 'Tenant' when lower(u.by_email) = lower(auth.email()) then 'You'
                                 when exists (select 1 from condo_owners o where lower(o.email) = lower(u.by_email)) then 'Owner' else 'Office' end) order by u.at), '[]'::jsonb)
                    from maintenance_request_updates u where u.request_id = r.id and (u.visible_to_resident or u.from_resident))) x
      from maintenance_requests r cross join lateral (select repair_unit_number(r.id) unit) q
      where q.unit = any (v_units)) t), '[]'::jsonb));
end;
$$;

-- Owner posts an update on a repair in a unit where the owner is responsible. Emails the tenant(s) and the office.
create or replace function owner_repair_update(p_id uuid, p_status text, p_note text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_owner uuid := condo_owner_for_email(auth.email()); r maintenance_requests; v_unit text; v_note text := nullif(left(trim(coalesce(p_note, '')), 2000), ''); v_changed boolean;
begin
  if v_owner is null or not condo_session_ok() then raise exception 'Owner sign-in required' using errcode = '42501'; end if;
  select * into r from maintenance_requests where id = p_id;
  v_unit := repair_unit_number(p_id);
  if r.id is null or v_unit is null or not exists (select 1 from condo_ownerships s join condo_units cu on cu.id = s.unit_id
       where s.is_current and s.owner_id = v_owner and cu.unit_number = v_unit) then raise exception 'Request not found.' using errcode = '42501'; end if;
  if not repair_owner_handles(p_id) then raise exception '2nd Chance handles repairs in this unit. Call the office to add something.'; end if;
  if r.status = 'closed' then raise exception 'This request is closed.'; end if;
  if p_status is not null and p_status not in ('in_progress', 'completed') then raise exception 'Unknown status'; end if;
  v_changed := p_status is not null and p_status <> r.status;
  if not v_changed and v_note is null then raise exception 'Write an update or choose a new status.'; end if;
  update maintenance_requests set status = coalesce(p_status, status), updated_at = now() where id = p_id;
  insert into maintenance_request_updates (request_id, by_email, status, note, visible_to_resident)
  values (p_id, auth.email(), case when v_changed then p_status end, v_note, true);
  perform repair_email_tenants(p_id,
    'Repair request #' || r.number || case when v_changed then ': ' || repair_status_label(p_status) else ': an update' end,
    '<p>Your repair request <b>' || repair_esc(r.subject) || '</b>' ||
    case when v_changed then ' is now <b>' || repair_status_label(p_status) || '</b>.' else ' has an update from the owner.' end || '</p>' ||
    case when v_note is not null then '<p><i>' || repair_esc(v_note) || '</i></p>' else '' end ||
    case when p_status = 'completed' then '<p>Please open the request in your resident portal and tell us whether it''s fixed.</p>' else '' end, false);
  perform repair_email_staff(p_id, 'Owner update on repair request #' || r.number || ' (Unit ' || v_unit || ')',
    '<p>The owner updated <b>' || repair_esc(r.subject) || '</b>' || case when v_changed then ': now <b>' || repair_status_label(p_status) || '</b>' else '' end || '.</p>' ||
    case when v_note is not null then '<p><i>' || repair_esc(v_note) || '</i></p>' else '' end);
  perform repair_email_owners(p_id, 'Update on repair request #' || r.number,
    '<p>Another owner of the unit updated <b>' || repair_esc(r.subject) || '</b>' || case when v_changed then ': now <b>' || repair_status_label(p_status) || '</b>' else '' end || '.</p>' ||
    case when v_note is not null then '<p><i>' || repair_esc(v_note) || '</i></p>' else '' end, v_owner);
  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function repair_setting_units(text), repair_unit_number(uuid), repair_owner_handles(uuid), repair_unit_owners(text),
  repair_email_owners(uuid, text, text, uuid), repair_email_tenants(uuid, text, text, boolean) from public, anon, authenticated;
grant execute on function repair_setting_units(text), repair_unit_number(uuid), repair_owner_handles(uuid), repair_unit_owners(text),
  repair_email_owners(uuid, text, text, uuid), repair_email_tenants(uuid, text, text, boolean) to service_role;
revoke all on function owner_repairs_mine(), owner_repair_update(uuid, text, text) from public, anon;
grant execute on function owner_repairs_mine(), owner_repair_update(uuid, text, text) to authenticated, service_role;
