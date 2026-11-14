-- Leasing gap list repairs (docs/leasing-gap-analysis.md items 8, 9, 12, 14). No table is created here, so no grants are needed.

-- 12. Common phone recordings (iPhone voice memos, Android 3GP/AAC) are accepted in the applications bucket.
update storage.buckets set allowed_mime_types = (
  select array(select distinct unnest(allowed_mime_types || array['audio/x-m4a', 'audio/aac', 'audio/3gpp', 'video/3gpp'])))
 where id = 'applications';

-- 8. Field staff see a unit's signed leases: the signed lease is linked from leases.signing_doc_id (lease_from_signing never set lease_signing_docs.lease_id).
create or replace function field_unit_documents(p_property text, p_unit text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_ru uuid := inspection_rental_unit(p_property, p_unit);
begin
  if not field_can_access(p_property, p_unit) then raise exception 'Not your unit' using errcode = '42501'; end if;
  return jsonb_build_object(
    'signed_leases', coalesce((select jsonb_agg(jsonb_build_object('title', d.title, 'date', d.executed_at, 'bucket', 'lease-signing', 'path', d.executed_pdf_path, 'who', l.tenants_label) order by d.executed_at desc)
        from lease_signing_docs d join leases l on (l.signing_doc_id = d.id or d.lease_id = l.id) where l.unit_id = v_ru and d.executed_pdf_path is not null), '[]'::jsonb),
    'notices', coalesce((select jsonb_agg(jsonb_build_object('title', n.subject, 'date', n.sent_at, 'bucket', 'notices', 'path', n.pdf_path, 'status', case when n.voided then 'voided' else n.status end) order by n.sent_at desc)
        from notices n join leases l on l.id = n.lease_id where l.unit_id = v_ru and n.pdf_path is not null), '[]'::jsonb),
    'on_file', coalesce((select jsonb_agg(jsonb_build_object('kind', f.kind, 'status', f.status, 'dated', f.dated, 'note', f.note) order by f.dated nulls last, f.id)
        from lease_files f join leases l on l.id = f.lease_id where l.unit_id = v_ru), '[]'::jsonb),
    'owner_docs', coalesce((select jsonb_agg(jsonb_build_object('title', c.title, 'category', c.category, 'date', c.uploaded_at, 'bucket', 'owner-docs', 'path', c.storage_path, 'for_unit', c.unit_number is not null) order by c.category, c.title)
        from condo_documents c where c.unit_number is null or c.unit_number = p_unit), '[]'::jsonb));
end;
$$;
revoke all on function field_unit_documents(text, text) from public, anon;
grant execute on function field_unit_documents(text, text) to authenticated;

-- 14. Emails built in SQL: names and addresses are escaped, a missing value cannot blank the body, and a missing
-- address skips that one email instead of failing (and rolling back the payment or approval that triggered it).
create or replace function lease_keys_ready_check()
returns trigger language plpgsql security definer set search_path = public as $$
declare l leases; v_bal numeric; v_addr text; t record; v_office text;
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
  select nullif(trim(value), '') into v_office from portal_settings where key = 'office_email';
  if v_office is not null then
    insert into email_outbox (to_email, subject, html, kind) values
      (v_office, 'Keys can be released — ' || coalesce(v_addr, 'a unit'),
       '<p>The security deposit and first month''s rent for <b>' || repair_esc(v_addr) || '</b> (' || repair_esc(l.tenants_label) || ') are paid. The keys can be released now, even before the lease start date (' || coalesce(to_char(l.start_date, 'FMMM/FMDD/YYYY'), 'not set') || ').</p><p>Record the hand-over on the Move-ins page.</p>', 'keys_ready');
  end if;
  for t in select x.name, x.email from lease_tenants lt join tenants x on x.id = lt.tenant_id where lt.lease_id = l.id and nullif(trim(x.email), '') is not null loop
    insert into email_outbox (to_email, subject, html, kind) values (t.email, 'Your keys are ready',
      '<p>Hi ' || repair_esc(split_part(t.name, ' ', 1)) || ',</p><p>Your security deposit and first month''s rent are paid. Your keys for <b>' || repair_esc(v_addr) || '</b> are ready. You can move in early with no extra charge.</p><p>Call ' || repair_esc((select value from portal_settings where key = 'org_phone')) || ' to arrange pick-up.</p><p>2nd Chance Housing</p>', 'keys_ready');
  end loop;
  return new;
end;
$$;

create or replace function apply_staff_set_status(p_id uuid, p_status text, p_notes text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare r rental_applications; v_changed boolean;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if p_status not in ('new', 'reviewing', 'on_hold', 'waitlisted', 'approved', 'declined', 'withdrawn') then raise exception 'Unknown status %', p_status; end if;
  select * into r from rental_applications where id = p_id for update;
  if r.id is null then raise exception 'Application not found'; end if;
  v_changed := r.status is distinct from p_status;
  if v_changed and p_status = 'approved' and r.id_verified_at is null then raise exception 'Verify the ID first (name, address and date of birth).'; end if;
  if v_changed and p_status = 'approved' and r.docs_offline_at is null and exists (select 1 from jsonb_array_elements(r.media) m where m->>'scene' in ('id_front', 'id_back', 'ssn_card')) then
    raise exception 'Move the ID images offline first.'; end if;
  update rental_applications
     set status = p_status, staff_notes = coalesce(p_notes, staff_notes),
         decided_at = case when v_changed and p_status in ('approved', 'declined') then now() else decided_at end,
         decided_by = case when v_changed and p_status in ('approved', 'declined') then auth.email() else decided_by end
   where id = p_id returning * into r;
  insert into apply_access_log (staff_email, action, application_id, detail)
  values (auth.email(), 'status', p_id, case when v_changed then p_status else 'notes saved (' || p_status || ')' end);
  if v_changed and p_status = 'approved' and nullif(trim(coalesce(r.applicant->>'email', '')), '') is not null then
    insert into email_outbox (to_email, subject, html, kind) values (r.applicant->>'email', 'You''re approved — welcome to 2nd Chance Housing',
      '<p>Hi ' || repair_esc(split_part(r.applicant->>'name', ' ', 1)) || ',</p><p>Good news: your application is approved. Next we''ll prepare your lease. You''ll get an email with a private link to review and sign it online.</p>' ||
      '<p>Your keys are handed over as soon as the security deposit and first month''s rent are paid, even before the lease start date.</p><p>Questions? Call (262) 236-5443.</p><p>2nd Chance Housing</p>', 'approval');
  end if;
  return to_jsonb(r) - 'ssn_cipher';
end;
$$;

-- 9. A lease signed online cannot start a second tenancy on a unit that already has an active or future lease
-- held by someone else. (The same tenants re-signing keep working: they land on their existing lease, as before.)
CREATE OR REPLACE FUNCTION public.lease_from_signing(p_doc uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  d lease_signing_docs; v_lease uuid; v_unit uuid; v_unitnum text; v_rent numeric; v_dep numeric; v_start date; v_end date; v_type text;
  s record; v_tid uuid; v_names text; v_old uuid;
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
  -- A tenant who already has a lease on this unit (active or future) re-signs onto it: no second lease, no second deposit or first-month charge.
  select l.id into v_old from leases l
   where l.unit_id = v_unit and l.status in ('active', 'future') and l.signing_doc_id is distinct from d.id
     and exists (select 1 from lease_tenants lt join tenants t on t.id = lt.tenant_id join lease_signing_signers sg on sg.doc_id = d.id
                  where lt.lease_id = l.id and (lower(t.name) = lower(sg.name) or lower(t.email) = lower(sg.email)))
   order by l.start_date desc limit 1;
  if v_old is null and exists (select 1 from leases l where l.unit_id = v_unit and l.status in ('active', 'future') and l.signing_doc_id is distinct from d.id) then
    raise exception 'Unit % already has an active or future lease. End or correct that lease first, then run this one again.', v_unitnum; end if;
  if v_old is not null then
    v_lease := v_old;
    update leases set signing_doc_id = d.id, application_id = coalesce(application_id, d.application_id), co_application_ids = d.co_application_ids, rent = coalesce(v_rent, rent),
           lease_type = v_type, end_date = case when v_type = 'fixed' then coalesce(v_end, end_date) end, tenants_label = v_names,
           correction_note = trim(coalesce(correction_note || ' ', '') || 'Re-signed on 2ndchinc.org (document ' || upper(left(d.id::text, 8)) || '); no new move-in charges.')
     where id = v_lease;
  else
  insert into leases (unit_id, rental_label, tenants_label, start_date, end_date, lease_type, status, rent, rent_start, deposit_held,
                      signing_doc_id, application_id, co_application_ids, correction_note)
  values (v_unit, '2ndchinc.org lease', v_names, v_start, case when v_type = 'fixed' then v_end end, v_type,
          case when v_start > current_date then 'future' else 'active' end, v_rent, v_start, 0, d.id, d.application_id, d.co_application_ids,
          'Created from the lease signed online (document ' || upper(left(d.id::text, 8)) || ').')
  returning id into v_lease;
  end if;
  for s in select * from lease_signing_signers where doc_id = d.id order by position loop
    -- Match on name AND email: two people may share one email (a parent and an adult child) and must stay two people.
    select id into v_tid from tenants where lower(email) = lower(s.email) and lower(name) = lower(s.name) limit 1;
    if v_tid is null then
      insert into tenants (name, email, phone) values (s.name, lower(s.email), s.phone) returning id into v_tid;
    else
      update tenants set phone = coalesce(phone, s.phone) where id = v_tid;
    end if;
    insert into lease_tenants (lease_id, tenant_id) values (v_lease, v_tid) on conflict do nothing;
  end loop;
  if v_old is null and coalesce(v_dep, 0) > 0 then
    insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, description, amount, source)
    values (v_lease, 'Security Deposit Liability', current_date, 'charge', 'Charge', 'Security deposit', v_dep, 'move_in');
  end if;
  if v_old is null and coalesce(v_rent, 0) > 0 then
    insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, description, amount, source)
    values (v_lease, 'Rent Income', v_start, 'charge', 'Charge', 'Rent (first month)', v_rent, 'move_in');
  end if;
  if v_old is null then update leases set move_in_charges_posted = true where id = v_lease; end if;
  insert into lease_files (lease_id, kind, status, file_path, dated, note)
  values (v_lease, 'signed_lease', 'on_file', 'lease-signing:' || d.executed_pdf_path, current_date, 'Signed online; executed copy in the system.');
  if v_old is null then update condo_units set occupancy = 'tenant' where id = (select condo_unit_id from rental_units where id = v_unit); end if;
  if v_old is null then perform letter_queue_to_tenants('2c-welcome', v_lease, 'welcome'); end if;
  return v_lease;
end;
$function$;


revoke all on function lease_from_signing(uuid) from public, anon, authenticated;
grant execute on function lease_from_signing(uuid) to service_role;
