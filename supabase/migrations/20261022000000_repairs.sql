-- Stage 5 (tenant-journey-spec): request a repair.
--  * Tenant: category, description, photos, permission to enter, pets; tracks
--    status, comments, and confirms when it's fixed (or says it isn't).
--  * Statuses: Received (new) -> Scheduled -> In progress -> Done (completed)
--    -> Closed. The tenant is emailed at each status change.
--  * Staff: assign a vendor and schedule the visit, with the 12-hour notice to
--    enter (Wis. Stat. 704.05(2), ATCP 134.09(2)) unless the tenant gave
--    permission to enter; bill the tenant if the tenant caused the damage.
--  * Emergencies (no heat in winter, flooding, gas, fire) are phoned in to the
--    emergency line; the form says so and does not wait on a ticket.

alter table maintenance_requests drop constraint if exists maintenance_requests_status_check;
alter table maintenance_requests add constraint maintenance_requests_status_check
  check (status in ('new', 'scheduled', 'in_progress', 'deferred', 'completed', 'closed'));
alter table maintenance_requests add column if not exists category text
  check (category in ('plumbing', 'heat', 'electric', 'pests', 'appliance', 'other'));
alter table maintenance_requests add column if not exists has_pets boolean;
alter table maintenance_requests add column if not exists pets_note text;
alter table maintenance_requests add column if not exists scheduled_start timestamptz;
alter table maintenance_requests add column if not exists scheduled_end timestamptz;
alter table maintenance_requests add column if not exists entry_purpose text;
alter table maintenance_requests add column if not exists entry_notice_id uuid references notices(id);
alter table maintenance_requests add column if not exists resident_confirmed_at timestamptz;
alter table maintenance_requests add column if not exists billed_amount numeric(10, 2);
alter table maintenance_requests add column if not exists billed_entry_id bigint;
alter table maintenance_requests add column if not exists closed_at timestamptz;
alter table maintenance_request_updates add column if not exists from_resident boolean not null default false;

-- Letters: render with extra fields ------------------------------------------

create or replace function letter_render_ctx(p_template text, p_lease uuid, p_extra jsonb)
returns text
language plpgsql stable security definer set search_path = public as $$
declare
  v_html text; ctx jsonb; k text; v text; l leases; s jsonb;
begin
  select html into v_html from letter_templates where legacy_id = p_template;
  if v_html is null then raise exception 'Letter % not found', p_template; end if;
  select * into l from leases where id = p_lease;
  select jsonb_object_agg(key, value) into s from portal_settings;
  ctx := notice_context_body(p_lease, s->>'office_email') || jsonb_build_object(
    'Tenant_First_Name', 'Resident',
    'Org_Phone', s->>'org_phone', 'Emergency_Phone', s->>'emergency_phone',
    'Portal_URL', s->>'resident_url', 'Documents_URL', regexp_replace(s->>'resident_url', 'resident/?$', 'documents/'),
    'Zelle_Name', s->>'pay_zelle_name', 'Late_Fee_Policy', s->>'late_fee_policy',
    'Move_In_Amount', to_char(greatest((select coalesce(sum(amount), 0) from lease_ledger_entries where lease_id = p_lease), 0), 'FM$999,990.00'),
    'Checklist_Due', to_char(coalesce(l.keys_released_at::date, l.start_date, current_date) + 7, 'FMMonth FMDD, YYYY'),
    'Move_Out_Notice', case when l.lease_type = 'fixed'
      then 'Your lease ends on ' || to_char(l.end_date, 'FMMM/FMDD/YYYY') || '. We will contact you before then about renewing. If you plan to leave, tell us in writing as early as you can.'
      else 'Give us written notice at least 28 days before the end of a month. A month-to-month tenancy can only end at the end of a calendar month.' end);
  ctx := ctx || jsonb_build_object('Unit_Address', replace(ctx->>'Unit_Address', ' - ', ', Unit #'));
  ctx := ctx || coalesce(p_extra, '{}'::jsonb) - '_keep_signature';
  for k, v in select key, value from jsonb_each_text(ctx) loop
    v_html := replace(v_html, '[[' || k || ']]', replace(replace(replace(coalesce(v, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'));
  end loop;
  -- Notices keep a signature marker for the PDF builder; emails sign off by name.
  return replace(v_html, '[[Sender_Signature]]', case when coalesce((p_extra->>'_keep_signature')::boolean, false) then '[[SIGNATURE]]' else '2nd Chance Housing' end);
end;
$$;
revoke all on function letter_render_ctx(text, uuid, jsonb) from public, anon, authenticated;

create or replace function letter_render(p_template text, p_lease uuid, p_first_name text)
returns text
language sql stable security definer set search_path = public as $$
  select letter_render_ctx(p_template, p_lease, jsonb_build_object('Tenant_First_Name', coalesce(nullif(p_first_name, ''), 'Resident')));
$$;
revoke all on function letter_render(text, uuid, text) from public, anon, authenticated;

insert into letter_templates (legacy_id, recipient, name, subject, description, html, fields) values
('2c-12-hour-repair', 'Tenant', '2nd Chance — 12 Hour Notice (Repairs)', 'Notice To Enter',
 'Made from the repair request when staff schedule a visit: the 12-hour notice to enter for the repair.',
 '<p style="text-align: center"><strong>12 HOUR NOTICE</strong></p>
<p style="text-align: center">Wisconsin Statute § 704.05(2) · ATCP 134.09(2)(a)1.</p>
<p>[[Unit_Address]]</p>
<p>To: [[Lease_All_Tenants]]</p>
<p>Date: [[Current_Date]]     Time: [[Notice_Time]]</p>
<p><strong>This is a 12-hour notice as required by law.</strong></p>
<p>We will be entering your rental unit at least 12 hours after the date and time above. Our entry will be at any time between [[Entry_Window]] on [[Entry_Date]]. The purpose of our entry is to perform: [[Entry_Purpose]] (repair request #[[Request_Number]]).</p>
<p><strong>NOTE:</strong></p>
<p>Tenants don''t have any rights to deny the landlord entry if the landlord has given proper notice.</p>
<p>Tenants cannot require that the tenant be there during the time that the landlord has chosen to enter. A tenant isn''t allowed to say, "I have to be here in order for you to come in." If the tenant happens to be there during the time that the landlord has chosen to enter, it''s perfectly allowable under these laws for the tenant to stay.</p>
<p>A landlord cannot require that a tenant NOT be there during the time that the landlord has chosen to enter. Similar to the above point, a landlord doesn''t have the right to tell the tenant that they may not be in their home during the landlord''s entry.</p>
<p>If you have any questions or concerns, or agree to us entering the unit at an earlier time, please contact us at [[Org_Phone]].</p>
<p>[[Sender_Signature]]</p>',
 array['Unit_Address', 'Lease_All_Tenants', 'Current_Date', 'Notice_Time', 'Entry_Window', 'Entry_Date', 'Entry_Purpose', 'Request_Number', 'Org_Phone', 'Sender_Signature'])
on conflict (legacy_id) do update set html = excluded.html, fields = excluded.fields, subject = excluded.subject, description = excluded.description, name = excluded.name;

-- Helpers ---------------------------------------------------------------------

create or replace function repair_status_label(p_status text)
returns text
language sql immutable as $$
  select case p_status when 'new' then 'Received' when 'scheduled' then 'Scheduled' when 'in_progress' then 'In progress'
    when 'completed' then 'Done' when 'closed' then 'Closed' when 'deferred' then 'On hold' else p_status end;
$$;

create or replace function repair_category_label(p_category text)
returns text
language sql immutable as $$
  select case p_category when 'plumbing' then 'Plumbing' when 'heat' then 'Heat' when 'electric' then 'Electric'
    when 'pests' then 'Pests' when 'appliance' then 'Appliance' when 'other' then 'Other' else 'Not set' end;
$$;

-- "6/12, 10:00 AM–1:00 PM" style window, Central time.
create or replace function repair_window_text(p_start timestamptz, p_end timestamptz)
returns text
language sql stable as $$
  select to_char(p_start at time zone 'America/Chicago', 'FMDay, FMMonth FMDD') || ', ' ||
         to_char(p_start at time zone 'America/Chicago', 'FMHH12:MI AM') || '–' || to_char(p_end at time zone 'America/Chicago', 'FMHH12:MI AM');
$$;

-- Queue an email to every tenant on the request's lease (or the requester).
create or replace function repair_email_tenants(p_request uuid, p_subject text, p_body text)
returns void
language plpgsql volatile security definer set search_path = public as $$
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
end;
$$;
revoke all on function repair_email_tenants(uuid, text, text) from public, anon, authenticated;

create or replace function repair_email_staff(p_request uuid, p_subject text, p_body text)
returns void
language sql volatile security definer set search_path = public as $$
  insert into email_outbox (to_email, subject, html, kind)
  select value, p_subject, p_body || '<p>Open the Maintenance page to respond.</p>', 'repair_staff' from portal_settings where key = 'office_email';
$$;
revoke all on function repair_email_staff(uuid, text, text) from public, anon, authenticated;

create or replace function repair_esc(p text)
returns text
language sql immutable as $$ select replace(replace(replace(coalesce(p, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'); $$;

-- Resident ----------------------------------------------------------------------

drop function if exists resident_create_request(text, text, text, text[]);
create or replace function resident_create_request(p_category text, p_subject text, p_description text, p_entry text,
                                                   p_has_pets boolean, p_pets_note text, p_photos text[])
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare v_ids uuid[] := array(select resident_me()); v_lease uuid; v_unit text; r maintenance_requests; v_tenant text;
begin
  if cardinality(v_ids) = 0 then raise exception 'Resident two-step sign-in required' using errcode = '42501'; end if;
  if p_category is null or p_category not in ('plumbing', 'heat', 'electric', 'pests', 'appliance', 'other') then raise exception 'Choose what kind of problem it is.'; end if;
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
  select name || coalesce(' · ' || phone, '') into v_tenant from tenants where id = v_ids[1];
  perform repair_email_staff(r.id, 'Repair request #' || r.number || ' — ' || repair_category_label(r.category) || ' — ' || coalesce(nullif(v_unit, ''), 'no unit'),
    '<p><b>' || repair_esc(r.subject) || '</b> (' || repair_category_label(r.category) || ')</p><p>' || repair_esc(r.description) || '</p>' ||
    '<p>Unit: ' || repair_esc(coalesce(nullif(v_unit, ''), '—')) || '<br>Tenant: ' || repair_esc(v_tenant) ||
    '<br>Permission to enter: ' || case p_entry when 'yes' then 'Yes, may enter' when 'no' then 'No, only when home' else 'Call first' end ||
    '<br>Animals: ' || case when p_has_pets then 'Yes — ' || repair_esc(r.pets_note) else 'None' end ||
    '<br>Photos: ' || coalesce(array_length(r.photos, 1), 0) || '</p>');
  return jsonb_build_object('id', r.id, 'number', r.number);
end;
$$;
revoke all on function resident_create_request(text, text, text, text, boolean, text, text[]) from public, anon;
grant execute on function resident_create_request(text, text, text, text, boolean, text, text[]) to authenticated;

-- Requests the resident can see: their own and any on their lease.
create or replace function resident_can_see_request(p_request uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from maintenance_requests r where r.id = p_request
    and (r.tenant_id in (select resident_me()) or (r.lease_id is not null and resident_lease_ok(r.lease_id))));
$$;
revoke all on function resident_can_see_request(uuid) from public, anon;
grant execute on function resident_can_see_request(uuid) to authenticated;

create or replace function resident_requests()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from resident_me()) then raise exception 'Resident two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'number', r.number, 'category', r.category, 'subject', r.subject, 'description', r.description,
      'status', r.status, 'status_label', repair_status_label(r.status), 'created_at', r.created_at, 'photos', r.photos, 'entry_permission', r.entry_permission,
      'has_pets', r.has_pets, 'pets_note', r.pets_note, 'vendor', (select v.name from vendors v where v.id = r.vendor_id),
      'scheduled_start', r.scheduled_start, 'scheduled_end', r.scheduled_end, 'resident_confirmed_at', r.resident_confirmed_at, 'billed_amount', r.billed_amount,
      'notice_pdf', (select n.pdf_path from notices n where n.id = r.entry_notice_id),
      'updates', (select jsonb_agg(jsonb_build_object('at', u.at, 'status', u.status, 'note', u.note, 'from_resident', u.from_resident) order by u.at)
                  from maintenance_request_updates u where u.request_id = r.id and u.visible_to_resident)) order by r.created_at desc)
    from maintenance_requests r where resident_can_see_request(r.id)), '[]'::jsonb);
end;
$$;
revoke all on function resident_requests() from public, anon;
grant execute on function resident_requests() to authenticated;

create or replace function resident_request_comment(p_id uuid, p_note text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r maintenance_requests;
begin
  if not resident_can_see_request(p_id) then raise exception 'Request not found.' using errcode = '42501'; end if;
  if length(trim(coalesce(p_note, ''))) < 2 then raise exception 'Write your comment first.'; end if;
  select * into r from maintenance_requests where id = p_id;
  if r.status = 'closed' then raise exception 'This request is closed. Send a new request if the problem is back.'; end if;
  insert into maintenance_request_updates (request_id, by_email, note, from_resident) values (p_id, auth.email(), left(trim(p_note), 2000), true);
  update maintenance_requests set updated_at = now() where id = p_id;
  perform repair_email_staff(p_id, 'Tenant comment on repair request #' || r.number,
    '<p>On <b>' || repair_esc(r.subject) || '</b> (' || repair_esc(coalesce(r.unit_label, '')) || '):</p><p><i>' || repair_esc(left(trim(p_note), 2000)) || '</i></p>');
  return jsonb_build_object('ok', true);
end;
$$;
revoke all on function resident_request_comment(uuid, text) from public, anon;
grant execute on function resident_request_comment(uuid, text) to authenticated;

-- After staff mark it Done, the tenant confirms it's fixed (closes it) or says
-- it isn't (back to In progress, staff told).
create or replace function resident_request_confirm(p_id uuid, p_fixed boolean, p_note text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r maintenance_requests;
begin
  if not resident_can_see_request(p_id) then raise exception 'Request not found.' using errcode = '42501'; end if;
  select * into r from maintenance_requests where id = p_id;
  if r.status <> 'completed' then raise exception 'You can confirm once we mark the repair as done.'; end if;
  if p_fixed then
    update maintenance_requests set status = 'closed', resident_confirmed_at = now(), closed_at = now(), updated_at = now() where id = p_id;
    insert into maintenance_request_updates (request_id, by_email, status, note, from_resident)
    values (p_id, auth.email(), 'closed', 'Tenant confirmed it''s fixed' || coalesce(': ' || nullif(left(trim(p_note), 2000), ''), '.'), true);
    perform repair_email_staff(p_id, 'Repair request #' || r.number || ' confirmed fixed', '<p>The tenant confirmed <b>' || repair_esc(r.subject) || '</b> is fixed. It is closed.</p>');
  else
    if length(trim(coalesce(p_note, ''))) < 2 then raise exception 'Tell us what is still wrong.'; end if;
    update maintenance_requests set status = 'in_progress', updated_at = now() where id = p_id;
    insert into maintenance_request_updates (request_id, by_email, status, note, from_resident)
    values (p_id, auth.email(), 'in_progress', 'Tenant says it''s not fixed: ' || left(trim(p_note), 2000), true);
    perform repair_email_staff(p_id, 'NOT fixed — repair request #' || r.number,
      '<p>The tenant says <b>' || repair_esc(r.subject) || '</b> (' || repair_esc(coalesce(r.unit_label, '')) || ') is not fixed:</p><p><i>' || repair_esc(left(trim(p_note), 2000)) || '</i></p><p>It is back to In progress.</p>');
  end if;
  return jsonb_build_object('ok', true);
end;
$$;
revoke all on function resident_request_confirm(uuid, boolean, text) from public, anon;
grant execute on function resident_request_confirm(uuid, boolean, text) to authenticated;

-- Photos: requests on a shared lease can be opened by every tenant on it.
-- (Storage policies must go through security-definer helpers: a subquery on an
-- RLS table inside a policy silently returns nothing.)
create or replace function resident_can_see_repair_photo(p_name text)
returns boolean
language sql stable security definer set search_path = public as $$
  select (storage.foldername(p_name))[1] in (select x::text from resident_me() x)
      or exists (select 1 from maintenance_requests r where p_name = any(r.photos) and resident_can_see_request(r.id));
$$;
revoke all on function resident_can_see_repair_photo(text) from public, anon;
grant execute on function resident_can_see_repair_photo(text) to authenticated;
drop policy if exists "maintenance read" on storage.objects;
create policy "maintenance read" on storage.objects for select to authenticated
  using (bucket_id = 'maintenance' and (resident_can_see_repair_photo(name) or (condo_session_ok() and condo_is_staff())));

-- Staff ---------------------------------------------------------------------------

create or replace function maintenance_staff_list()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(to_jsonb(r) || jsonb_build_object(
      'status_label', repair_status_label(r.status), 'category_label', repair_category_label(r.category),
      'tenant', (select jsonb_build_object('name', t.name, 'phone', t.phone, 'email', t.email) from tenants t where t.id = r.tenant_id),
      'vendor', (select v.name from vendors v where v.id = r.vendor_id),
      'notice', (select jsonb_build_object('id', n.id, 'pdf_path', n.pdf_path, 'sent_at', n.sent_at) from notices n where n.id = r.entry_notice_id),
      'updates', (select jsonb_agg(to_jsonb(u) order by u.at) from maintenance_request_updates u where u.request_id = r.id)) order by r.created_at desc)
    from maintenance_requests r), '[]'::jsonb);
end;
$$;

-- Status change and/or note. Tenants are emailed on every status change and on
-- every note marked visible.
create or replace function maintenance_staff_update(p_id uuid, p_status text, p_note text, p_visible boolean, p_vendor uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare r maintenance_requests; v_note text := nullif(trim(coalesce(p_note, '')), ''); v_changed boolean;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into r from maintenance_requests where id = p_id;
  if r.id is null then raise exception 'Request not found'; end if;
  if p_status is not null and p_status not in ('new', 'scheduled', 'in_progress', 'deferred', 'completed', 'closed') then raise exception 'Unknown status'; end if;
  if p_status = 'scheduled' and r.scheduled_start is null then raise exception 'Use "Schedule visit" to set the date and send the notice.'; end if;
  v_changed := p_status is not null and p_status <> r.status;
  if not v_changed and v_note is null and p_vendor is null then raise exception 'Nothing to save.'; end if;
  update maintenance_requests set status = coalesce(p_status, status), vendor_id = coalesce(p_vendor, vendor_id), updated_at = now(),
    closed_at = case when p_status = 'closed' then now() else closed_at end where id = p_id;
  insert into maintenance_request_updates (request_id, by_email, status, note, visible_to_resident)
  values (p_id, auth.email(), case when v_changed then p_status end, v_note, coalesce(p_visible, true));
  if v_changed or (v_note is not null and coalesce(p_visible, true)) then
    perform repair_email_tenants(p_id,
      'Repair request #' || r.number || case when v_changed then ': ' || repair_status_label(p_status) else ': an update' end,
      '<p>Your repair request <b>' || repair_esc(r.subject) || '</b>' ||
      case when v_changed then ' is now <b>' || repair_status_label(p_status) || '</b>.' else ' has an update.' end || '</p>' ||
      case when v_note is not null and coalesce(p_visible, true) then '<p><i>' || repair_esc(v_note) || '</i></p>' else '' end ||
      case when p_status = 'completed' then '<p>Please open the request in your resident portal and tell us whether it''s fixed.</p>' else '' end);
  end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- Schedule the visit. With p_notice the 12-hour notice to enter is rendered
-- for the notices function to turn into a PDF, file and email; the visit must
-- start at least 12 hours from now. Without it, the tenant must have given
-- permission to enter on the request.
create or replace function maintenance_staff_schedule(p_id uuid, p_vendor uuid, p_start timestamptz, p_end timestamptz, p_purpose text, p_notice boolean)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
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
    select id into v_tpl from letter_templates where legacy_id = '2c-12-hour-repair';
    v_html := letter_render_ctx('2c-12-hour-repair', r.lease_id, jsonb_build_object('_keep_signature', true,
      'Notice_Time', to_char(now() at time zone 'America/Chicago', 'FMHH12:MI AM'),
      'Current_Date', to_char(now() at time zone 'America/Chicago', 'FMMonth FMDD, YYYY'),
      'Entry_Date', to_char(p_start at time zone 'America/Chicago', 'FMDay, FMMonth FMDD, YYYY'),
      'Entry_Window', to_char(p_start at time zone 'America/Chicago', 'FMHH12:MI AM') || ' and ' || to_char(p_end at time zone 'America/Chicago', 'FMHH12:MI AM'),
      'Entry_Purpose', left(trim(p_purpose), 300), 'Request_Number', r.number::text));
  else
    perform repair_email_tenants(p_id, 'Repair request #' || r.number || ': Scheduled',
      '<p>Your repair request <b>' || repair_esc(r.subject) || '</b> is scheduled for <b>' || v_when || '</b>. You gave us permission to enter if you''re not home.</p>');
  end if;
  return jsonb_build_object('ok', true, 'lease_id', r.lease_id, 'template_id', v_tpl, 'subject', 'Notice To Enter — repair request #' || r.number, 'html', v_html);
end;
$$;

-- The notices function links the 12-hour notice it filed back to the request.
create or replace function maintenance_link_notice(p_id uuid, p_notice uuid)
returns void
language sql volatile security definer set search_path = public as $$
  update maintenance_requests set entry_notice_id = p_notice where id = p_id;
$$;
revoke all on function maintenance_link_notice(uuid, uuid) from public, anon, authenticated;
grant execute on function maintenance_link_notice(uuid, uuid) to service_role;

-- Bill the tenant for damage they caused (posts a charge to the lease ledger).
create or replace function maintenance_staff_bill(p_id uuid, p_amount numeric, p_reason text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r maintenance_requests; v_entry bigint;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into r from maintenance_requests where id = p_id;
  if r.id is null then raise exception 'Request not found'; end if;
  if r.lease_id is null then raise exception 'This request has no lease to bill.'; end if;
  if r.billed_entry_id is not null then raise exception 'This repair was already billed.'; end if;
  if p_amount is null or p_amount <= 0 or p_amount > 20000 then raise exception 'Enter the amount to bill.'; end if;
  if length(trim(coalesce(p_reason, ''))) < 5 then raise exception 'Say how the tenant caused the damage (the tenant sees this).'; end if;
  insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, description, amount, source, correction_note)
  values (r.lease_id, 'Repairs Income', current_date, 'charge', 'Charge', 'Repair — request #' || r.number || ': ' || left(trim(p_reason), 200), round(p_amount, 2), 'repair',
          'Tenant-caused damage, billed by ' || auth.email() || '.')
  returning id into v_entry;
  update maintenance_requests set billed_amount = round(p_amount, 2), billed_entry_id = v_entry, updated_at = now() where id = p_id;
  insert into maintenance_request_updates (request_id, by_email, note)
  values (p_id, auth.email(), 'Repair charge of ' || to_char(round(p_amount, 2), 'FM$999,990.00') || ' added to your account: ' || left(trim(p_reason), 200));
  perform repair_email_tenants(p_id, 'Repair charge — request #' || r.number,
    '<p>The repair for <b>' || repair_esc(r.subject) || '</b> was caused by damage in the unit, so a charge of <b>' || to_char(round(p_amount, 2), 'FM$999,990.00') ||
    '</b> was added to your account:</p><p><i>' || repair_esc(left(trim(p_reason), 200)) || '</i></p><p>Questions? Call ' || (select value from portal_settings where key = 'org_phone') || '.</p>');
  return jsonb_build_object('ok', true, 'entry_id', v_entry);
end;
$$;

revoke all on function maintenance_staff_list() from public, anon;
revoke all on function maintenance_staff_update(uuid, text, text, boolean, uuid) from public, anon;
revoke all on function maintenance_staff_schedule(uuid, uuid, timestamptz, timestamptz, text, boolean) from public, anon;
revoke all on function maintenance_staff_bill(uuid, numeric, text) from public, anon;
grant execute on function maintenance_staff_list() to authenticated;
grant execute on function maintenance_staff_update(uuid, text, text, boolean, uuid) to authenticated;
grant execute on function maintenance_staff_schedule(uuid, uuid, timestamptz, timestamptz, text, boolean) to authenticated;
grant execute on function maintenance_staff_bill(uuid, numeric, text) to authenticated;
