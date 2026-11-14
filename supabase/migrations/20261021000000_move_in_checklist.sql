-- Stage 3 (tenant-journey-spec): move in.
--  * Move-in checklist, room by room with photos. The lease gives the tenant
--    7 days from the start of the tenancy to report pre-existing damage and to
--    ask for the list of damages charged to the previous tenant's deposit
--    (Wis. Admin. Code ATCP 134.06); the checklist does both. Staff review and
--    sign off; the approved checklist is kept for move-out.
--  * 2nd Chance versions of the Welcome, Move-In and Online Payments letters:
--    Welcome when the lease is signed, Move-In + Online Payments when the keys
--    are handed over.

insert into portal_settings (key, value) values
  ('resident_url', 'https://2ndchinc.org/resident/'),
  ('move_in_rooms', '[
    {"key": "entry", "name": "Entry & hallway", "items": ["Front door & lock", "Walls & ceiling", "Floor", "Lights & switches", "Closet", "Smoke detector"]},
    {"key": "living", "name": "Living room", "items": ["Walls & ceiling", "Floor / carpet", "Windows & screens", "Blinds", "Lights & outlets"]},
    {"key": "kitchen", "name": "Kitchen", "items": ["Refrigerator", "Stove & oven", "Sink & faucet", "Cabinets & counters", "Floor", "Walls & ceiling", "Lights & outlets"]},
    {"key": "bath", "name": "Bathroom", "items": ["Toilet", "Tub / shower", "Sink & faucet", "Mirror & cabinet", "Exhaust fan", "Floor", "Walls & ceiling"]},
    {"key": "bed1", "name": "Bedroom 1", "items": ["Door", "Walls & ceiling", "Floor / carpet", "Windows & screens", "Closet", "Lights & outlets"]},
    {"key": "bed2", "name": "Bedroom 2", "optional": true, "items": ["Door", "Walls & ceiling", "Floor / carpet", "Windows & screens", "Closet", "Lights & outlets"]},
    {"key": "bed3", "name": "Bedroom 3", "optional": true, "items": ["Door", "Walls & ceiling", "Floor / carpet", "Windows & screens", "Closet", "Lights & outlets"]},
    {"key": "systems", "name": "Heat, safety & keys", "items": ["Heat / thermostat", "Hot water", "Smoke detectors", "Carbon monoxide detector", "Keys received"]}
  ]')
on conflict (key) do nothing;

create table if not exists move_in_checklists (
  lease_id uuid primary key references leases(id) on delete cascade,
  data jsonb not null default '{}'::jsonb,
  status text not null default 'draft' check (status in ('draft', 'submitted', 'returned', 'approved')),
  submitted_at timestamptz,
  submitted_by text,
  prior_damage_list_requested boolean not null default false,
  staff_notes text,
  decided_at timestamptz,
  decided_by text,
  updated_at timestamptz not null default now()
);
alter table move_in_checklists enable row level security;

-- Private bucket: <lease id>/<room>/<file> checklist photos.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('move-in', 'move-in', false, 15728640, array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'image/heif'])
on conflict (id) do update set allowed_mime_types = excluded.allowed_mime_types;

create or replace function resident_lease_ok(p_lease uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from lease_tenants lt where lt.lease_id = p_lease and lt.tenant_id in (select resident_me()));
$$;
revoke all on function resident_lease_ok(uuid) from public, anon;
grant execute on function resident_lease_ok(uuid) to authenticated;

-- Folder names that aren't a uuid simply don't match (no cast error).
create or replace function move_in_folder_lease(p_name text)
returns uuid
language sql immutable as $$
  select case when (storage.foldername(p_name))[1] ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then (storage.foldername(p_name))[1]::uuid end;
$$;

drop policy if exists "move-in resident upload" on storage.objects;
create policy "move-in resident upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'move-in' and resident_lease_ok(move_in_folder_lease(name)));
drop policy if exists "move-in read" on storage.objects;
create policy "move-in read" on storage.objects for select to authenticated
  using (bucket_id = 'move-in' and (resident_lease_ok(move_in_folder_lease(name)) or (condo_session_ok() and condo_is_staff())));

-- Letters ------------------------------------------------------------------

insert into letter_templates (legacy_id, recipient, name, subject, description, html, fields) values
('2c-welcome', 'Tenant', '2nd Chance — Welcome Letter', 'Welcome to 2nd Chance Housing',
 'Sent automatically when a lease is fully signed: the resident portal and the move-in payment.',
 '<p>[[Current_Date]]</p>
<p>Dear [[Tenant_First_Name]],</p>
<p>Welcome to 2nd Chance Housing! Your lease for <b>[[Unit_Address]]</b> is signed, and your resident portal is ready. You can use it 24 hours a day from your phone or computer to:</p>
<ul><li>Pay rent and see your payment history</li><li>Turn on automatic monthly payments (autopay)</li><li>Send maintenance requests with photos</li><li>Open your lease and other documents</li></ul>
<p><b>Signing in:</b> go to <a href="[[Portal_URL]]">[[Portal_URL]]</a> and enter this email address. We email you a code, then text a second code to your phone. There is no password to remember.</p>
<p><b>Your next step:</b> pay your move-in amount of <b>[[Move_In_Amount]]</b> (security deposit and first month''s rent). As soon as it is paid, your keys are released, even before your lease starts on [[Lease_Start_Date]], with no extra charge for moving in early. There are no fees to you for paying online.</p>
<p>If you have any questions, call us at [[Org_Phone]].</p>
<p>Sincerely,</p><p>[[Sender_Signature]]</p>',
 array['Current_Date', 'Tenant_First_Name', 'Unit_Address', 'Portal_URL', 'Move_In_Amount', 'Lease_Start_Date', 'Org_Phone', 'Sender_Signature']),
('2c-move-in', 'Tenant', '2nd Chance — Move-In Letter', 'Welcome home — your move-in steps',
 'Sent automatically when the keys are handed over: checklist, autopay, repairs, entry, locks, moving out.',
 '<p>[[Current_Date]]</p>
<p>Dear [[Tenant_First_Name]],</p>
<p>Welcome to <b>[[Unit_Address]]</b>. Here is what to do in your first days, and what to know while you live here.</p>
<p><b>1. Your move-in checklist (by [[Checklist_Due]]).</b> In your resident portal (<a href="[[Portal_URL]]">[[Portal_URL]]</a>), go room by room, mark the condition of each item and add photos. Your lease gives you 7 days from the start of your tenancy to tell us about any damage or defects that were already there, and to ask for the list of damages charged to the previous tenant''s security deposit. The checklist does both. We review it and sign off, and we use it again when you move out, so you are never charged for something that was already there.</p>
<p><b>2. Autopay (optional).</b> Turn on autopay in the portal and your rent is paid automatically on the 1st. It is free to you.</p>
<p><b>Repairs.</b> For routine problems, send a request in the portal or call [[Org_Phone]]. For maintenance emergencies (flooding, no heat, no water, a lockout) call [[Emergency_Phone]] any time. For a fire or a gas smell, leave and call 911 first.</p>
<p><b>Entry.</b> We may enter with 12 hours'' advance notice to inspect, make repairs or show the unit, and without notice in a health or safety emergency.</p>
<p><b>Locks.</b> Neither of us adds or changes locks without giving the other a key. We must always be able to get in during an emergency.</p>
<p><b>Resident guides.</b> Pest-treatment preparation, lead and radon safety, and city rules: <a href="[[Documents_URL]]">[[Documents_URL]]</a>.</p>
<p><b>Moving out.</b> [[Move_Out_Notice]]</p>
<p>Thank you for choosing 2nd Chance Housing. We look forward to having you as a tenant for many years to come.</p>
<p>Sincerely,</p><p>[[Sender_Signature]]</p>',
 array['Current_Date', 'Tenant_First_Name', 'Unit_Address', 'Checklist_Due', 'Portal_URL', 'Org_Phone', 'Emergency_Phone', 'Documents_URL', 'Move_Out_Notice', 'Sender_Signature']),
('2c-online-payments', 'Tenant', '2nd Chance — Online Payments Letter', 'Paying rent online — free to you',
 'Sent automatically with the Move-In Letter: how to pay online, autopay and Zelle.',
 '<p>Dear [[Tenant_First_Name]],</p>
<p>Your rent of <b>[[Lease_Rent]]</b> is due on the 1st of each month. The easiest way to pay on time is online in your resident portal at <a href="[[Portal_URL]]">[[Portal_URL]]</a>:</p>
<ul><li><b>It is free to you.</b> 2nd Chance Housing pays all the fees.</li><li>Pay from your bank account or with a card, in seconds.</li><li>Turn on autopay and your rent is paid automatically on the 1st. Never forget rent again.</li><li>You can also pay by Zelle to <b>[[Zelle_Name]]</b>. Then tap "I''ve paid" in the portal so we can match your payment.</li></ul>
<p>[[Late_Fee_Policy]]</p>
<p>If you have any questions, or would like help, call us at [[Org_Phone]].</p>
<p>Sincerely,</p><p>[[Sender_Signature]]</p>',
 array['Tenant_First_Name', 'Lease_Rent', 'Portal_URL', 'Zelle_Name', 'Late_Fee_Policy', 'Org_Phone', 'Sender_Signature'])
on conflict (legacy_id) do update set html = excluded.html, fields = excluded.fields, subject = excluded.subject, description = excluded.description, name = excluded.name;

-- Fill a 2nd Chance letter for one tenant of a lease.
create or replace function letter_render(p_template text, p_lease uuid, p_first_name text)
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
    'Tenant_First_Name', coalesce(nullif(p_first_name, ''), 'Resident'),
    'Org_Phone', s->>'org_phone', 'Emergency_Phone', s->>'emergency_phone',
    'Portal_URL', s->>'resident_url', 'Documents_URL', regexp_replace(s->>'resident_url', 'resident/?$', 'documents/'),
    'Zelle_Name', s->>'pay_zelle_name', 'Late_Fee_Policy', s->>'late_fee_policy',
    'Move_In_Amount', to_char(greatest((select coalesce(sum(amount), 0) from lease_ledger_entries where lease_id = p_lease), 0), 'FM$999,990.00'),
    'Checklist_Due', to_char(coalesce(l.keys_released_at::date, l.start_date, current_date) + 7, 'FMMonth FMDD, YYYY'),
    'Move_Out_Notice', case when l.lease_type = 'fixed'
      then 'Your lease ends on ' || to_char(l.end_date, 'FMMM/FMDD/YYYY') || '. We will contact you before then about renewing. If you plan to leave, tell us in writing as early as you can.'
      else 'Give us written notice at least 28 days before the end of a month. A month-to-month tenancy can only end at the end of a calendar month.' end);
  ctx := ctx || jsonb_build_object('Unit_Address', replace(ctx->>'Unit_Address', ' - ', ', Unit #'));
  for k, v in select key, value from jsonb_each_text(ctx) loop
    v_html := replace(v_html, '[[' || k || ']]', replace(replace(replace(coalesce(v, ''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'));
  end loop;
  return replace(v_html, '[[Sender_Signature]]', '2nd Chance Housing');
end;
$$;
revoke all on function letter_render(text, uuid, text) from public, anon, authenticated;

create or replace function letter_queue_to_tenants(p_template text, p_lease uuid, p_kind text)
returns int
language plpgsql volatile security definer set search_path = public as $$
declare t record; n int := 0; v_subject text;
begin
  select subject into v_subject from letter_templates where legacy_id = p_template;
  for t in select x.name, x.email from lease_tenants lt join tenants x on x.id = lt.tenant_id where lt.lease_id = p_lease and x.email is not null loop
    insert into email_outbox (to_email, subject, html, kind) values (t.email, v_subject, letter_render(p_template, p_lease, split_part(t.name, ' ', 1)), p_kind);
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke all on function letter_queue_to_tenants(text, uuid, text) from public, anon, authenticated;

-- Resident: move-in ---------------------------------------------------------

-- The resident's move-in (the newest lease created from online signing).
create or replace function resident_move_in()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare l leases; c move_in_checklists;
begin
  if not exists (select 1 from resident_me()) then raise exception 'Resident two-step sign-in required' using errcode = '42501'; end if;
  select x.* into l from leases x where x.move_in_charges_posted and x.status in ('active', 'future') and resident_lease_ok(x.id) order by x.start_date desc limit 1;
  if l.id is null then return null; end if;
  select * into c from move_in_checklists where lease_id = l.id;
  return jsonb_build_object(
    'lease_id', l.id, 'start_date', l.start_date, 'keys_ready_at', l.keys_ready_at, 'keys_released_at', l.keys_released_at,
    'due_on', coalesce(l.keys_released_at::date, l.start_date) + 7,
    'address', (select address from rental_units where id = l.unit_id),
    'rooms', (select value::jsonb from portal_settings where key = 'move_in_rooms'),
    'checklist', case when c.lease_id is null then null else jsonb_build_object('data', c.data, 'status', c.status, 'submitted_at', c.submitted_at,
        'prior_damage_list_requested', c.prior_damage_list_requested, 'staff_notes', c.staff_notes, 'decided_at', c.decided_at) end);
end;
$$;

-- Check a checklist against the room template. Returns null when complete.
create or replace function move_in_checklist_problem(p_lease uuid, p_data jsonb)
returns text
language plpgsql stable security definer set search_path = public as $$
declare r jsonb; room jsonb; it text; c text; p text;
begin
  for r in select * from jsonb_array_elements((select value::jsonb from portal_settings where key = 'move_in_rooms')) loop
    room := p_data->'rooms'->(r->>'key');
    if coalesce((r->>'optional')::boolean, false) and coalesce((room->>'na')::boolean, false) then continue; end if;
    if room is null or jsonb_array_length(coalesce(room->'photos', '[]'::jsonb)) = 0 then
      return (r->>'name') || ': add at least one photo' || case when coalesce((r->>'optional')::boolean, false) then ', or mark it "Not in my unit"' else '' end || '.';
    end if;
    for it in select jsonb_array_elements_text(r->'items') loop
      c := room->'items'->it->>'c';
      if c is null or c not in ('good', 'fair', 'damaged') then return (r->>'name') || ': choose the condition of "' || it || '".'; end if;
      if c = 'damaged' and coalesce(trim(room->'items'->it->>'n'), '') = '' then return (r->>'name') || ': describe the damage to "' || it || '".'; end if;
    end loop;
  end loop;
  return null;
end;
$$;
revoke all on function move_in_checklist_problem(uuid, jsonb) from public, anon, authenticated;

create or replace function resident_move_in_save(p_lease uuid, p_data jsonb, p_prior_list boolean, p_submit boolean)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare l leases; v_status text; v_problem text; p text; v_addr text;
begin
  if not resident_lease_ok(p_lease) then raise exception 'Resident two-step sign-in required' using errcode = '42501'; end if;
  select * into l from leases where id = p_lease and move_in_charges_posted;
  if l.id is null then raise exception 'No move-in for this lease.'; end if;
  if l.keys_ready_at is null then raise exception 'The checklist opens once your move-in amount is paid and your keys are ready.'; end if;
  select status into v_status from move_in_checklists where lease_id = p_lease;
  if v_status in ('submitted', 'approved') then raise exception 'Your checklist was already sent. Call the office if something needs to change.'; end if;
  -- Photos must be this lease's own uploads.
  for p in select jsonb_array_elements_text(coalesce(r.value->'photos', '[]'::jsonb)) from jsonb_each(coalesce(p_data->'rooms', '{}'::jsonb)) r loop
    if left(p, 37) <> p_lease::text || '/' then raise exception 'Photo not recognised.'; end if;
  end loop;
  if p_submit then
    v_problem := move_in_checklist_problem(p_lease, p_data);
    if v_problem is not null then raise exception '%', v_problem; end if;
  end if;
  insert into move_in_checklists (lease_id, data, status, prior_damage_list_requested, submitted_at, submitted_by, updated_at)
  values (p_lease, p_data, case when p_submit then 'submitted' else 'draft' end, coalesce(p_prior_list, false),
          case when p_submit then now() end, case when p_submit then auth.email() end, now())
  on conflict (lease_id) do update set data = excluded.data, status = case when p_submit then 'submitted' else move_in_checklists.status end,
    prior_damage_list_requested = excluded.prior_damage_list_requested,
    submitted_at = coalesce(excluded.submitted_at, move_in_checklists.submitted_at), submitted_by = coalesce(excluded.submitted_by, move_in_checklists.submitted_by), updated_at = now();
  if p_submit then
    select address into v_addr from rental_units where id = l.unit_id;
    insert into email_outbox (to_email, subject, html, kind) values ((select value from portal_settings where key = 'office_email'),
      'Move-in checklist to review — ' || v_addr,
      '<p>' || l.tenants_label || ' sent the move-in checklist for <b>' || v_addr || '</b>' ||
      case when now()::date > coalesce(l.keys_released_at::date, l.start_date) + 7 then ' (after the 7-day window)' else '' end || '.</p>' ||
      case when coalesce(p_prior_list, false) then '<p><b>The tenant asked for the list of damages charged to the previous tenant''s security deposit.</b> Send it to them.</p>' else '' end ||
      '<p>Review and sign off on the Move-ins page.</p>', 'move_in_checklist');
  end if;
  return jsonb_build_object('ok', true, 'status', case when p_submit then 'submitted' else coalesce(v_status, 'draft') end);
end;
$$;

revoke all on function resident_move_in() from public, anon;
revoke all on function resident_move_in_save(uuid, jsonb, boolean, boolean) from public, anon;
grant execute on function resident_move_in() to authenticated;
grant execute on function resident_move_in_save(uuid, jsonb, boolean, boolean) to authenticated;

-- Staff: move-ins -----------------------------------------------------------

create or replace function move_in_staff_list()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('lease_id', l.id, 'address', u.address, 'tenants', l.tenants_label, 'start_date', l.start_date, 'status', l.status,
      'rent', l.rent, 'balance', (select coalesce(sum(amount), 0) from lease_ledger_entries where lease_id = l.id),
      'keys_ready_at', l.keys_ready_at, 'keys_released_at', l.keys_released_at, 'keys_released_by', l.keys_released_by,
      'due_on', coalesce(l.keys_released_at::date, l.start_date) + 7,
      'checklist_status', c.status, 'checklist_submitted_at', c.submitted_at, 'prior_damage_list_requested', coalesce(c.prior_damage_list_requested, false)) order by l.start_date)
    from leases l join rental_units u on u.id = l.unit_id left join move_in_checklists c on c.lease_id = l.id
    where l.move_in_charges_posted and (c.status is distinct from 'approved' or c.decided_at > now() - interval '30 days')), '[]'::jsonb);
end;
$$;

create or replace function move_in_staff_detail(p_lease uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare c move_in_checklists;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into c from move_in_checklists where lease_id = p_lease;
  return jsonb_build_object(
    'rooms', (select value::jsonb from portal_settings where key = 'move_in_rooms'),
    'checklist', case when c.lease_id is null then null else to_jsonb(c) end);
end;
$$;

create or replace function move_in_staff_decide(p_lease uuid, p_action text, p_notes text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_addr text; t record;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if p_action not in ('approve', 'return') then raise exception 'Unknown action'; end if;
  if p_action = 'return' and coalesce(trim(p_notes), '') = '' then raise exception 'Say what the tenant needs to fix.'; end if;
  update move_in_checklists set status = case when p_action = 'approve' then 'approved' else 'returned' end,
    staff_notes = nullif(trim(p_notes), ''), decided_at = now(), decided_by = auth.email()
  where lease_id = p_lease and status = 'submitted';
  if not found then raise exception 'There is no submitted checklist to review.'; end if;
  select u.address into v_addr from leases l join rental_units u on u.id = l.unit_id where l.id = p_lease;
  for t in select x.name, x.email from lease_tenants lt join tenants x on x.id = lt.tenant_id where lt.lease_id = p_lease and x.email is not null loop
    insert into email_outbox (to_email, subject, html, kind) values (t.email,
      case when p_action = 'approve' then 'Your move-in checklist is approved' else 'Your move-in checklist needs a change' end,
      '<p>Hi ' || split_part(t.name, ' ', 1) || ',</p>' || case when p_action = 'approve'
        then '<p>We reviewed and signed off on your move-in checklist for <b>' || v_addr || '</b>. It is saved in your resident portal and will be used when you move out.</p>'
        else '<p>We reviewed your move-in checklist for <b>' || v_addr || '</b> and need one more thing:</p><p><i>' ||
             replace(replace(trim(p_notes), '<', '&lt;'), '>', '&gt;') || '</i></p><p>Open the Move-in page in your resident portal to update it and send it again.</p>' end ||
      '<p>2nd Chance Housing</p>', 'move_in_checklist');
  end loop;
  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function move_in_staff_list() from public, anon;
revoke all on function move_in_staff_detail(uuid) from public, anon;
revoke all on function move_in_staff_decide(uuid, text, text) from public, anon;
grant execute on function move_in_staff_list() to authenticated;
grant execute on function move_in_staff_detail(uuid) to authenticated;
grant execute on function move_in_staff_decide(uuid, text, text) to authenticated;

-- Letters hooked into Stage 2 ---------------------------------------------

create or replace function lease_from_signing(p_doc uuid)
returns uuid
language plpgsql volatile security definer set search_path = public
as $$
declare
  d lease_signing_docs; v_lease uuid; v_unit uuid; v_unitnum text; v_rent numeric; v_dep numeric; v_start date; v_end date; v_type text;
  s record; v_tid uuid; v_names text;
begin
  select id into v_lease from leases where signing_doc_id = p_doc;
  if v_lease is not null then return v_lease; end if;
  select * into d from lease_signing_docs where id = p_doc and status = 'signed';
  if d.id is null then raise exception 'Lease is not fully signed'; end if;
  v_unitnum := substring(coalesce(d.lease_data->>'unitSelect', d.unit_label) from '#\s*(\d+)');
  select u.id into v_unit from rental_units u join rental_properties p on p.id = u.property_id where p.key = 'roca1' and u.unit_number = v_unitnum;
  if v_unit is null then raise exception 'Unit not recognised from "%"', d.unit_label; end if;
  v_rent := nullif(regexp_replace(coalesce(d.lease_data->>'rentAmount', ''), '[^0-9.]', '', 'g'), '')::numeric;
  v_dep := nullif(regexp_replace(coalesce(d.lease_data->>'securityDeposit', ''), '[^0-9.]', '', 'g'), '')::numeric;
  v_start := coalesce(nullif(d.lease_data->>'initialStartDate', '')::date, current_date);
  v_end := nullif(d.lease_data->>'expirationDate', '')::date;
  v_type := case when d.lease_data->>'leaseType' = 'annual' then 'fixed' else 'at_will' end;
  select string_agg(name, ', ' order by position) into v_names from lease_signing_signers where doc_id = d.id;
  insert into leases (unit_id, legacy_rental, tenants_label, start_date, end_date, lease_type, status, rent, rent_start, legacy_balance, deposit_held,
                      signing_doc_id, application_id, correction_note)
  values (v_unit, '2ndchinc.org lease', v_names, v_start, case when v_type = 'fixed' then v_end end, v_type,
          case when v_start > current_date then 'future' else 'active' end, v_rent, v_start, 0, 0, d.id, d.application_id,
          'Created from the lease signed online (document ' || upper(left(d.id::text, 8)) || ').')
  returning id into v_lease;
  for s in select * from lease_signing_signers where doc_id = d.id order by position loop
    select id into v_tid from tenants where lower(email) = lower(s.email) limit 1;
    if v_tid is null then
      insert into tenants (name, email, phone) values (s.name, lower(s.email), s.phone) returning id into v_tid;
    else
      update tenants set phone = coalesce(phone, s.phone) where id = v_tid;
    end if;
    insert into lease_tenants (lease_id, tenant_id) values (v_lease, v_tid) on conflict do nothing;
  end loop;
  if coalesce(v_dep, 0) > 0 then
    insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, description, amount, source)
    values (v_lease, 'Security Deposit Liability', current_date, 'charge', 'Charge', 'Security deposit', v_dep, 'move_in');
  end if;
  if coalesce(v_rent, 0) > 0 then
    insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, description, amount, source)
    values (v_lease, 'Rent Income', v_start, 'charge', 'Charge', 'Rent (first month)', v_rent, 'move_in');
  end if;
  update leases set move_in_charges_posted = true where id = v_lease;
  insert into lease_files (lease_id, kind, status, file_path, dated, note)
  values (v_lease, 'signed_lease', 'on_file', 'lease-signing:' || d.executed_pdf_path, current_date, 'Signed online; executed copy in the system.');
  update condo_units set occupancy = 'tenant' where id = (select condo_unit_id from rental_units where id = v_unit);
  perform letter_queue_to_tenants('2c-welcome', v_lease, 'welcome');
  return v_lease;
end;
$$;

create or replace function lease_keys_released(p_lease uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  update leases set keys_released_at = now(), keys_released_by = auth.email() where id = p_lease and keys_ready_at is not null and keys_released_at is null;
  if not found then raise exception 'Keys are not ready yet (move-in amount not fully paid) or already released.'; end if;
  perform letter_queue_to_tenants('2c-move-in', p_lease, 'move_in_letter');
  perform letter_queue_to_tenants('2c-online-payments', p_lease, 'online_payments_letter');
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function lease_keys_ready_check()
returns trigger
language plpgsql security definer set search_path = public
as $$
declare l leases; v_bal numeric; v_addr text; t record;
begin
  if new.amount >= 0 then return new; end if;
  select * into l from leases where id = new.lease_id;
  if l.id is null or not l.move_in_charges_posted or l.keys_ready_at is not null then return new; end if;
  select coalesce(sum(amount), 0) into v_bal from lease_ledger_entries where lease_id = l.id;
  if v_bal > 0 then return new; end if;
  update leases set keys_ready_at = now(),
    deposit_held = (select coalesce(sum(amount), 0) from lease_ledger_entries where lease_id = l.id and kind = 'charge' and gl_account = 'Security Deposit Liability' and source = 'move_in')
  where id = l.id;
  select address into v_addr from rental_units where id = l.unit_id;
  insert into email_outbox (to_email, subject, html, kind) values
    ((select value from portal_settings where key = 'office_email'), 'Keys can be released — ' || v_addr,
     '<p>The security deposit and first month''s rent for <b>' || v_addr || '</b> (' || l.tenants_label || ') are paid. The keys can be released now, even before the lease start date (' || to_char(l.start_date, 'FMMM/FMDD/YYYY') || ').</p><p>Record the hand-over on the Move-ins page.</p>', 'keys_ready');
  for t in select x.name, x.email from lease_tenants lt join tenants x on x.id = lt.tenant_id where lt.lease_id = l.id and x.email is not null loop
    insert into email_outbox (to_email, subject, html, kind) values (t.email, 'Your keys are ready',
      '<p>Hi ' || split_part(t.name, ' ', 1) || ',</p><p>Your security deposit and first month''s rent are paid. Your keys for <b>' || v_addr || '</b> are ready. You can move in early with no extra charge.</p><p>Call ' || coalesce((select value from portal_settings where key = 'org_phone'), '') || ' to arrange pick-up.</p><p>2nd Chance Housing</p>', 'keys_ready');
  end loop;
  return new;
end;
$$;
