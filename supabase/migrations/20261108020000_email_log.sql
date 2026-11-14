-- Email delivery log and bounce watch (10/9/2026).
--
-- Every email sent through the provider (Resend) has an id. The function resend-webhook receives the provider's
-- events (delivered, opened, bounced, complained, delayed) and keeps one row per email here, matched to a tenant by
-- the address. The launch email to tenants (kind 'launch') is logged when it is sent by the function tenant-email.
-- "Opened" is only a hint (images blocked, Apple Mail privacy prefetch); a tenant has really read it when they register
-- or sign in, which the staff screen shows next to it.
--
-- Staff read this at /staff/reports/ ("Email delivery"); a bounce adds a Today item until the tenant's address is fixed.

create table if not exists email_log (
  id bigint generated always as identity primary key,
  resend_id text unique,
  kind text not null default 'other',            -- 'launch' for the move-off email, else 'other'
  tenant_id uuid references tenants(id) on delete set null,
  to_email text not null,
  subject text,
  sent_at timestamptz not null default now(),
  status text not null default 'sent' check (status in ('sent', 'delivered', 'delayed', 'bounced', 'complained', 'failed')),
  delivered_at timestamptz,
  first_opened_at timestamptz,
  open_count int not null default 0,
  bounced_at timestamptz,
  bounce_reason text,
  last_event text,
  last_event_at timestamptz,
  note text
);
create index if not exists email_log_kind_idx on email_log (kind, sent_at desc);
create index if not exists email_log_to_idx on email_log (lower(to_email));
alter table email_log enable row level security;
-- No policies: the edge functions (service role) and the staff functions below only.

-- Service role: apply one provider event to an email's row (creates the row if we did not log the send).
create or replace function email_log_event(p_resend_id text, p_event text, p_at timestamptz, p_to text, p_subject text, p_reason text)
returns void
language plpgsql volatile security definer set search_path = public
as $$
declare v_tenant uuid;
begin
  if p_resend_id is null then return; end if;
  if not exists (select 1 from email_log where resend_id = p_resend_id) then
    select t.id into v_tenant from tenants t where lower(t.email) = lower(p_to) order by t.id limit 1;
    insert into email_log (resend_id, kind, tenant_id, to_email, subject, sent_at) values (p_resend_id, 'other', v_tenant, coalesce(p_to, ''), p_subject, coalesce(p_at, now()))
    on conflict (resend_id) do nothing;
  end if;
  update email_log set
    last_event = p_event, last_event_at = coalesce(p_at, now()),
    status = case
      when p_event = 'email.bounced' then 'bounced'
      when p_event = 'email.complained' then 'complained'
      when p_event = 'email.failed' then 'failed'
      when p_event = 'email.delivery_delayed' and status in ('sent', 'delayed') then 'delayed'
      when p_event = 'email.delivered' and status in ('sent', 'delayed') then 'delivered'
      else status end,
    delivered_at = case when p_event = 'email.delivered' then coalesce(delivered_at, coalesce(p_at, now())) else delivered_at end,
    first_opened_at = case when p_event = 'email.opened' then coalesce(first_opened_at, coalesce(p_at, now())) else first_opened_at end,
    open_count = open_count + case when p_event = 'email.opened' then 1 else 0 end,
    bounced_at = case when p_event = 'email.bounced' then coalesce(p_at, now()) else bounced_at end,
    bounce_reason = case when p_event = 'email.bounced' then left(coalesce(p_reason, ''), 400) else bounce_reason end
   where resend_id = p_resend_id;
end;
$$;
revoke all on function email_log_event(text, text, timestamptz, text, text, text) from public, anon, authenticated;
grant execute on function email_log_event(text, text, timestamptz, text, text, text) to service_role;

-- Service role: record an email as sent (called by tenant-email).
create or replace function email_log_sent(p_resend_id text, p_kind text, p_tenant uuid, p_to text, p_subject text)
returns void
language sql volatile security definer set search_path = public
as $$
  insert into email_log (resend_id, kind, tenant_id, to_email, subject) values (p_resend_id, coalesce(p_kind, 'other'), p_tenant, p_to, p_subject)
  on conflict (resend_id) do update set kind = excluded.kind, tenant_id = excluded.tenant_id;
$$;
revoke all on function email_log_sent(text, text, uuid, text, text) from public, anon, authenticated;
grant execute on function email_log_sent(text, text, uuid, text, text) to service_role;

-- Staff: the launch emails, one row per tenant on an active or future lease, with whether they have registered or signed in.
create or replace function email_staff_launch_status()
returns jsonb
language plpgsql stable security definer set search_path = public, auth
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(x order by (x->>'unit')::int nulls last, x->>'name') from (
    select distinct on (t.id) jsonb_build_object(
      'tenant_id', t.id, 'name', t.name, 'email', t.email, 'unit', u.unit_number,
      'sent_to', e.to_email, 'sent_at', e.sent_at, 'status', e.status, 'delivered_at', e.delivered_at, 'first_opened_at', e.first_opened_at,
      'open_count', e.open_count, 'bounce_reason', e.bounce_reason, 'last_event', e.last_event,
      'email_changed_since', (e.to_email is not null and lower(e.to_email) <> lower(coalesce(t.email, ''))),
      'registered_at', c.used_at,
      'last_sign_in', (select max(a.last_sign_in_at) from auth.users a where lower(a.email) = lower(t.email))) as x
      from leases l join lease_tenants lt on lt.lease_id = l.id join tenants t on t.id = lt.tenant_id join rental_units u on u.id = l.unit_id
      left join lateral (select * from email_log e2 where e2.kind = 'launch' and e2.tenant_id = t.id order by e2.sent_at desc limit 1) e on true
      left join tenant_reg_codes c on c.tenant_id = t.id
     where l.status in ('active', 'future')
     order by t.id, l.start_date desc) s), '[]'::jsonb);
end;
$$;
revoke all on function email_staff_launch_status() from public, anon;
grant execute on function email_staff_launch_status() to authenticated;

-- Today: emails that bounced and whose address has not been fixed.
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

  return jsonb_build_object('as_of', now(), 'items', v);
end;
$$;

revoke all on function staff_today() from public, anon;
grant execute on function staff_today() to authenticated;

-- Service role: everyone on an active or future lease (one row per person), for the launch email.
create or replace function tenants_on_leases()
returns table (id uuid, name text, email text)
language sql stable security definer set search_path = public
as $$
  select distinct on (t.id) t.id, t.name, t.email
    from leases l join lease_tenants lt on lt.lease_id = l.id join tenants t on t.id = lt.tenant_id
   where l.status in ('active', 'future')
   order by t.id, l.start_date desc;
$$;
revoke all on function tenants_on_leases() from public, anon, authenticated;
grant execute on function tenants_on_leases() to service_role;
