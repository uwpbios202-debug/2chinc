-- Applications loaded for people who already have a lease (10/9/2026).
-- existing_lease_id: the lease the person already holds; such an application is not "waiting for a lease"
-- on Today and is never purged as an approval that did not become a lease.
-- source: 'site' (applied on 2ndchinc.org) or 'legacy' (loaded from the application printout).

alter table rental_applications add column if not exists existing_lease_id uuid references leases(id);
alter table rental_applications add column if not exists source text not null default 'site' check (source in ('site', 'legacy'));

create or replace function staff_today()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
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
     and not exists (select 1 from lease_signing_docs s where s.application_id = a.id and s.status <> 'void');
  v := v || jsonb_build_object('key', 'approved_no_lease', 'grp', 'Leasing', 'label', 'Approved, lease not sent yet', 'n', n, 'href', '/leasing/applications/', 'urgent', n > 0);

  select count(*) into n from lease_signing_docs where status = 'sent';
  v := v || jsonb_build_object('key', 'awaiting_tenant', 'grp', 'Leasing', 'label', 'Leases waiting for the tenant to sign', 'n', n, 'href', '/leasing/applications/', 'urgent', false);

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

  return jsonb_build_object('as_of', now(), 'items', v);
end;
$$;

revoke all on function staff_today() from public, anon;
grant execute on function staff_today() to authenticated;

create or replace function apply_purge_due()
returns table (session_id uuid, application_id uuid)
language sql stable security definer set search_path = public
as $$
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
     and not exists (select 1 from leases l where l.application_id = a.id)
     and not exists (select 1 from lease_signing_docs d where d.application_id = a.id and d.status <> 'void');
$$;

-- "We do not care about your past" (Stephen, 10/9/2026): the application no longer asks for an address
-- (many applicants are homeless). Verifying an ID is now a spelling check of the name and date of birth only.
create or replace function apply_staff_verify_identity(p_id uuid, p_checks jsonb)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare ok boolean;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  ok := coalesce((p_checks->>'name')::boolean, false) and coalesce((p_checks->>'dob')::boolean, false);
  update rental_applications set id_checks = p_checks,
         id_verified_at = case when ok then now() else null end, id_verified_by = case when ok then auth.email() else null end
   where id = p_id;
  if not found then raise exception 'Application not found'; end if;
  insert into apply_access_log (staff_email, action, application_id, detail) values (auth.email(), 'status', p_id, 'identity checks: ' || p_checks::text);
  return jsonb_build_object('verified', ok);
end;
$$;
revoke all on function apply_staff_verify_identity(uuid, jsonb) from public, anon;
grant execute on function apply_staff_verify_identity(uuid, jsonb) to authenticated;
