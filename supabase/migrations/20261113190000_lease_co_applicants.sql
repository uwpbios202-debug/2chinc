-- Up to four tenants on one lease, chosen from their own applications (Stephen, 10/21/2026).
-- The lease builder lets staff add other applicants (up to 3 besides the one the lease was started from). The first application stays in
-- application_id; the others are kept in co_application_ids, on the signing document and on the lease it creates. Every place that asks
-- "does this application already have a lease?" now counts the co-applicants too, so their approved applications neither show up as
-- "needs a lease" nor get purged for having none. Each function below is the live definition with only that condition widened.

alter table lease_signing_docs add column if not exists co_application_ids uuid[] not null default '{}';
alter table leases add column if not exists co_application_ids uuid[] not null default '{}';

CREATE OR REPLACE FUNCTION public.apply_purge_due()
 RETURNS TABLE(session_id uuid, application_id uuid)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  select s.id, null::uuid from apply_sessions s
   where s.submitted_at is null
     and case when exists (select 1 from apply_drafts d where d.session_id = s.id)
              then (select max(d.updated_at) from apply_drafts d where d.session_id = s.id) < now() - interval '45 days'
              else s.created_at < now() - interval '7 days' end
  union all
  select a.session_id, a.id from rental_applications a
   where a.status in ('declined', 'withdrawn') and coalesce(a.decided_at, a.created_at) < now() - interval '90 days'
  union all
  select a.session_id, a.id from rental_applications a
   where a.status = 'approved' and coalesce(a.decided_at, a.created_at) < now() - interval '1 year'
     and a.existing_lease_id is null
     and not exists (select 1 from leases l where (l.application_id = a.id or a.id = any(l.co_application_ids)))
     and not exists (select 1 from lease_signing_docs d where (d.application_id = a.id or a.id = any(d.co_application_ids)) and d.status <> 'void');
$function$;

CREATE OR REPLACE FUNCTION public.apply_staff_set_unit(p_id uuid, p_unit text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare r rental_applications; v_unit rental_units;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into r from rental_applications where id = p_id for update;
  if r.id is null then raise exception 'Application not found'; end if;
  select * into v_unit from rental_units where unit_number = p_unit and managed_by <> 'owner';
  if v_unit.id is null then raise exception 'Unit % is not a unit we lease.', p_unit; end if;
  if exists (select 1 from leases l where l.unit_id = v_unit.id and l.status in ('active', 'future')) then raise exception 'Unit % already has a lease.', p_unit; end if;
  if exists (select 1 from lease_signing_docs d where (d.application_id = p_id or p_id = any(d.co_application_ids)) and d.status <> 'void') then
    raise exception 'A lease was already sent to sign for this application. Void it first, then change the unit.'; end if;
  update rental_applications
     set applicant = jsonb_set(applicant || case when applicant ? 'units_requested' then '{}'::jsonb else jsonb_build_object('units_requested', coalesce(applicant->'units', '[]'::jsonb)) end,
                               '{units}', jsonb_build_array(p_unit))
   where id = p_id returning * into r;
  insert into apply_access_log (staff_email, action, application_id, detail) values (auth.email(), 'unit', p_id, 'lease unit set to ' || p_unit);
  return jsonb_build_object('units', r.applicant->'units');
end;
$function$;

CREATE OR REPLACE FUNCTION public.apply_staff_supersede(p_old uuid, p_new uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare o rental_applications; n rental_applications;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if p_old = p_new then raise exception 'An application cannot replace itself.'; end if;
  select * into o from rental_applications where id = p_old for update;
  select * into n from rental_applications where id = p_new for update;
  if o.id is null or n.id is null then raise exception 'Application not found'; end if;
  if o.status = 'superseded' then raise exception 'The old application was already replaced.'; end if;
  if n.status in ('superseded', 'declined') then raise exception 'The new application must be an active one (not replaced or declined).'; end if;
  if o.status = 'declined' then raise exception 'A declined application stays on record as declined; it cannot be replaced.'; end if;
  if o.created_at >= n.created_at then raise exception 'The replaced application must be the older one.'; end if;
  if exists (select 1 from lease_signing_docs d where (d.application_id = p_old or p_old = any(d.co_application_ids)) and d.status <> 'void') then
    raise exception 'A lease was already sent to sign for the old application. Void it first.'; end if;
  update rental_applications set status = 'superseded', superseded_prev_status = o.status, superseded_by = p_new, superseded_at = now(),
         superseded_by_email = auth.email(), superseded_reason = nullif(trim(coalesce(p_reason, '')), '') where id = p_old;
  update rental_applications set supersedes_id = p_old where id = p_new;
  insert into apply_access_log (staff_email, action, application_id, detail)
    values (auth.email(), 'supersede', p_old, 'replaced by ' || p_new || ' (was ' || o.status || ')' || case when nullif(trim(coalesce(p_reason, '')), '') is null then '' else ': ' || trim(p_reason) end);
  return jsonb_build_object('old', p_old, 'new', p_new);
end;
$function$;

CREATE OR REPLACE FUNCTION public.staff_today()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v jsonb := '[]'::jsonb;
  n int;
  d int;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;

  -- Leasing
  select count(*) into n from rental_applications where status in ('new', 'reviewing');
  v := v || jsonb_build_object('key', 'applications', 'grp', 'Leasing', 'label', 'Applications to review', 'n', n, 'href', '/leasing/applications/', 'urgent', false);

  select count(*) into n from rental_applications a
   where a.status = 'approved'
     and a.existing_lease_id is null
     and not exists (select 1 from lease_signing_docs s where (s.application_id = a.id or a.id = any(s.co_application_ids)) and s.status <> 'void');
  v := v || jsonb_build_object('key', 'approved_no_lease', 'grp', 'Leasing', 'label', 'Approved, lease not sent yet', 'n', n, 'href', '/leasing/applications/', 'urgent', n > 0);

  select count(*) into n from lease_signing_docs where status = 'sent';
  v := v || jsonb_build_object('key', 'awaiting_tenant', 'grp', 'Leasing', 'label', 'Leases waiting for the tenant to sign', 'n', n, 'href', '/leasing/applications/', 'urgent', false);

  select count(*) into n from email_log e left join tenants t on t.id = e.tenant_id
   where e.status in ('bounced', 'complained') and e.sent_at > now() - interval '30 days' and (t.id is null or lower(coalesce(t.email, '')) = lower(e.to_email));
  v := v || jsonb_build_object('key', 'email_bounces', 'grp', 'Residents', 'label', 'Emails that bounced (fix the address)', 'n', n, 'href', '/staff/reports/', 'urgent', n > 0);

  select count(*) into n from issue_reports where status = 'new';
  v := v || jsonb_build_object('key', 'problem_reports', 'grp', 'Residents', 'label', 'Problem reports to look at', 'n', n, 'href', '/staff/reports/', 'urgent', n > 0);

  select count(*) into n from lease_signing_docs where status = 'awaiting_agent';
  v := v || jsonb_build_object('key', 'countersign', 'grp', 'Leasing', 'label', 'Leases to countersign', 'n', n, 'href', '/leasing/countersign/', 'urgent', n > 0);

  select count(*), min(l.end_date - current_date) into n, d from leases l
   where l.status = 'active' and l.end_date between current_date and current_date + 60
     and not exists (select 1 from lease_renewals r where r.lease_id = l.id and r.status in ('offered', 'accepted', 'signed', 'declined', 'non_renewal'))
     and not exists (select 1 from move_outs m where m.lease_id = l.id and m.status <> 'closed');
  v := v || jsonb_build_object('key', 'renewals', 'grp', 'Leasing', 'label', 'Leases ending within 60 days, no renewal decision', 'n', n, 'href', '/leasing/renewals/',
                               'urgent', coalesce(d, 99) <= 30, 'note', case when n > 0 then 'first one ends in ' || d || ' day' || case when d = 1 then '' else 's' end end);

  -- Move-ins and move-outs
  select count(*) into n from move_in_checklists where status = 'submitted';
  v := v || jsonb_build_object('key', 'move_in_checklists', 'grp', 'Move-ins & move-outs', 'label', 'Move-in checklists to review', 'n', n, 'href', '/inspections/move-in/', 'urgent', false);

  select count(*) into n from leases where keys_ready_at is not null and keys_released_at is null;
  v := v || jsonb_build_object('key', 'keys', 'grp', 'Move-ins & move-outs', 'label', 'Paid in full, keys not handed over', 'n', n, 'href', '/inspections/move-in/', 'urgent', n > 0);

  select count(*) into n from move_out_checklists where status = 'submitted';
  v := v || jsonb_build_object('key', 'move_out_checklists', 'grp', 'Move-ins & move-outs', 'label', 'Move-out checklists to review', 'n', n, 'href', '/inspections/move-out/', 'urgent', false);

  -- Wis. Stat. 704.28: the deposit statement is due 21 days after the tenant leaves.
  select count(*), min(deposit_due_by - current_date) into n, d from move_outs
   where status in ('vacated', 'inspected') and deposit_due_by is not null and deposit_due_by - current_date <= 7;
  v := v || jsonb_build_object('key', 'deposit_deadline', 'grp', 'Move-ins & move-outs', 'label', 'Deposit statements due within 7 days', 'n', n, 'href', '/inspections/move-out/',
                               'urgent', n > 0, 'note', case when n > 0 then case when d < 0 then 'one is ' || -d || ' day' || case when d = -1 then '' else 's' end || ' late'
                                                                            when d = 0 then 'one is due today' else 'next due in ' || d || ' day' || case when d = 1 then '' else 's' end end end);

  -- Residents
  select count(*) into n from maintenance_requests where status = 'new';
  v := v || jsonb_build_object('key', 'repairs_new', 'grp', 'Residents', 'label', 'New repair requests', 'n', n, 'href', '/maintenance/', 'urgent', n > 0);

  select count(*) into n from maintenance_requests where status in ('scheduled', 'in_progress');
  v := v || jsonb_build_object('key', 'repairs_open', 'grp', 'Residents', 'label', 'Repairs scheduled or in progress', 'n', n, 'href', '/maintenance/', 'urgent', false);

  select count(distinct tenant_id) into n from tenant_messages where from_resident and read_at is null;
  v := v || jsonb_build_object('key', 'messages', 'grp', 'Residents', 'label', 'Residents with unread messages', 'n', n, 'href', '/resident/messages/', 'urgent', n > 0);

  select count(*) into n from tenant_contact_changes where status = 'pending';
  v := v || jsonb_build_object('key', 'contact_changes', 'grp', 'Residents', 'label', 'Contact changes to approve', 'n', n, 'href', '/resident/messages/', 'urgent', false);

  select count(*) into n from guest_requests where status = 'pending';
  v := v || jsonb_build_object('key', 'guests', 'grp', 'Residents', 'label', 'Guest requests to decide', 'n', n, 'href', '/parking/', 'urgent', false);

  -- Money
  select count(*) into n from payment_reports where status = 'pending';
  v := v || jsonb_build_object('key', 'payments', 'grp', 'Money', 'label', 'Reported payments to verify', 'n', n, 'href', '/accounting/tenant-side/payments/', 'urgent', n > 0);

  select count(*) into n from bank_receipts b
   where b.matched_report_id is null and b.assigned_lease_id is null and not b.ignored
     and b.status not in ('posted', 'stripe_payout', 'ignored') and b.posted_on > current_date - 120;
  v := v || jsonb_build_object('key', 'bank', 'grp', 'Money', 'label', 'Bank deposits to match', 'n', n, 'href', '/accounting/bank/', 'urgent', false);

  select count(*) into n from charge_disputes where status = 'open';
  v := v || jsonb_build_object('key', 'disputes', 'grp', 'Money', 'label', 'Charge questions to answer', 'n', n, 'href', '/accounting/disputes/', 'urgent', n > 0);

  -- ROCA1
  select count(*) into n from condo_violations where status in ('open', 'hearing_requested');
  v := v || jsonb_build_object('key', 'violations', 'grp', 'ROCA1', 'label', 'Violations needing a next step', 'n', n, 'href', '/association-owners/roca1/violations/', 'urgent', false);

  select count(*) into n from roca_resolutions where status = 'voting';
  v := v || jsonb_build_object('key', 'votes', 'grp', 'ROCA1', 'label', 'Board votes open', 'n', n, 'href', '/association-owners/roca1/board/', 'urgent', false);

  select count(*) into n from roca_distributions where status = 'calculated';
  v := v || jsonb_build_object('key', 'distributions', 'grp', 'ROCA1', 'label', 'Rent deductions to approve', 'n', n, 'href', '/association-owners/roca1/distributions/', 'urgent', false);

  select count(*) into n from roca_rent_splits where status = 'zelle_due';
  v := v || jsonb_build_object('key', 'zelle_owners', 'grp', 'ROCA1', 'label', 'Zelle payments to send to owners', 'n', n, 'href', '/association-owners/roca1/distributions/', 'urgent', n > 0);
  return jsonb_build_object('as_of', now(), 'items', v);
end;
$function$;

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

