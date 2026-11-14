-- Stage 8 (tenant-journey-spec): move out.
--  * Tenant gives written notice to vacate in the portal (month to month: at
--    least 28 days, ending on the last day of a month; a lease for a term ends
--    on its end date, earlier is an early move-out the tenant stays liable for)
--    with a forwarding address, and follows the move-out checklist.
--  * Website sends the Move-Out Procedure letter, the inspection time, and a
--    reminder 3 days before; staff inspect room by room next to the move-in
--    checklist and photos; the final ledger and the security deposit
--    itemization (Wis. Stat. 704.28: within 21 days of surrender, to the
--    forwarding address) are built and sent; nonprofit policy can absorb a
--    balance the tenant owes.
--  * Former tenants keep read-only access (rule 16): 28 days after a voluntary
--    move-out, 60 days after the sheriff's removal; then the sign-in is removed.
--  * The unit goes back to vacant and staff are reminded to list it (Stage 1).

create table if not exists move_outs (
  id uuid primary key default gen_random_uuid(),
  lease_id uuid not null references leases(id) on delete cascade,
  type text not null default 'voluntary' check (type in ('voluntary', 'non_renewal', 'evicted', 'abandoned')),
  status text not null default 'notice' check (status in ('notice', 'scheduled', 'vacated', 'inspected', 'deposit_sent', 'closed')),
  notice_received_at timestamptz,
  notice_by text,
  move_out_date date,
  early boolean not null default false,
  reason text,
  forwarding_address text,
  forwarding_updated_at timestamptz,
  tenant_tasks jsonb not null default '{}'::jsonb,
  inspection_at timestamptz,
  keys_returned_on date,
  surrendered_on date,
  sheriff_removal_on date,
  checklist jsonb not null default '{}'::jsonb,
  inspection_note text,
  inspected_by text,
  deductions jsonb not null default '[]'::jsonb,
  deposit_held numeric(10, 2),
  unpaid_balance numeric(10, 2),
  refund_amount numeric(10, 2),
  balance_due numeric(10, 2),
  absorb_balance boolean not null default false,
  deposit_due_by date,
  letter_notice_id uuid references notices(id),
  finalized_at timestamptz,
  finalized_by text,
  refund_method text,
  refund_ref text,
  refund_sent_on date,
  access_ends_at timestamptz,
  access_removed_at timestamptz,
  reminded jsonb not null default '{}'::jsonb,
  staff_note text,
  created_by text,
  created_at timestamptz not null default now(),
  closed_at timestamptz
);
alter table move_outs enable row level security;
create unique index if not exists move_outs_open_idx on move_outs (lease_id) where status <> 'closed';

-- Staff can add move-out inspection photos to the private move-in bucket
-- (<lease id>/moveout/<room>/<file>), next to the move-in photos.
drop policy if exists "move-in staff upload" on storage.objects;
create policy "move-in staff upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'move-in' and staff_session_staff());

-- Former tenants: residents whose access window is still open.
create or replace function resident_tenant_ids(p_email text)
returns setof uuid
language sql stable security definer set search_path = public
as $$
  select t.id from tenants t
  where lower(t.email) = lower(p_email)
    and (exists (select 1 from lease_tenants lt join leases l on l.id = lt.lease_id where lt.tenant_id = t.id and l.status in ('active', 'future'))
      or exists (select 1 from land_contract_buyers b join land_contracts c on c.id = b.contract_id where b.tenant_id = t.id and c.status = 'active')
      or exists (select 1 from lease_tenants lt join move_outs m on m.lease_id = lt.lease_id
                 where lt.tenant_id = t.id and m.access_ends_at > now() and m.access_removed_at is null));
$$;

-- Writes in the portal need a current tenancy; former tenants are read-only
-- (they can still update their forwarding address for the deposit).
create or replace function resident_require_current()
returns void
language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from resident_me() x join tenants t on t.id = x
                 where exists (select 1 from lease_tenants lt join leases l on l.id = lt.lease_id where lt.tenant_id = t.id and l.status in ('active', 'future'))
                    or exists (select 1 from land_contract_buyers b join land_contracts c on c.id = b.contract_id where b.tenant_id = t.id and c.status = 'active')) then
    raise exception 'Your tenancy has ended, so the portal is read-only now. Call the office at % if you need anything.',
      (select value from portal_settings where key = 'org_phone') using errcode = '42501';
  end if;
end;
$$;
revoke all on function resident_require_current() from public, anon;
grant execute on function resident_require_current() to authenticated;

create or replace function move_out_access_end(m move_outs)
returns timestamptz
language sql immutable as $$
  select case when m.type = 'evicted' then (coalesce(m.sheriff_removal_on, m.surrendered_on) + 61)::timestamptz
              else (m.surrendered_on + 29)::timestamptz end;   -- through the 28th / 60th day
$$;

-- Templates -------------------------------------------------------------------------

insert into letter_templates (legacy_id, recipient, name, subject, description, html, fields) values
('2c-move-out-info', 'Tenant', '2nd Chance — Move-Out Procedure', 'Your move-out steps',
 'Sent when the tenant gives notice to vacate (or staff record a move-out).',
 '<p style="text-align: center"><strong>TENANT MOVE-OUT PROCEDURE</strong></p>
<p>[[Current_Date]]</p>
<p>To: [[Lease_All_Tenants]]<br>[[Unit_Address]]</p>
<p>Thank you for renting with us. As your tenancy ends, please follow these steps so everything goes smoothly.</p>
<p><b>1. Move-out date.</b> All personal belongings must be removed and the unit vacated by 11:59 p.m. on <b>[[Move_Out_Date]]</b>. [[Early_Note]]</p>
<p><b>2. Keys.</b> Return all keys (unit, mailbox and room keys) by then, in person only, in the unit. Call or text [[Org_Phone]] at least 2 hours before you return them; leave a message if no one answers.</p>
<p><b>3. Cleaning.</b> Leave the unit clean and rentable: remove all belongings and trash; clean the stove, oven, refrigerator (defrost it) and microwave; sweep and mop all floors; wipe down all surfaces; clean the bathroom thoroughly; replace burned-out light bulbs. As your lease says, property left behind is treated as abandoned and disposed of (prescription medicine and medical equipment are held 7 days), and removing it may be charged.</p>
<p><b>4. Forwarding address.</b> We have: [[Forwarding_Address]]. Keep it up to date in your resident portal. That is where we send your security deposit.</p>
<p><b>5. Inspection and your deposit.</b> After you move out we inspect the unit and compare it with your move-in checklist. The reasonable cost of damage, waste or neglect beyond normal wear and tear, and any unpaid rent or charges, may be deducted from your security deposit. Within 21 days after your tenancy ends we will return your deposit with a written, itemized statement of anything withheld (Wis. Stat. § 704.28). If you''d like a walk-through with us before you move out, call at least 48 hours before your move-out date.</p>
<p><b>6. Utilities.</b> Contact the utility, phone and cable companies to stop services in your name.</p>
<p>You can still see your account and final statement in the resident portal for 28 days after you move out.</p>
<p>Sincerely,</p><p>[[Sender_Signature]]</p>',
 array['Current_Date', 'Lease_All_Tenants', 'Unit_Address', 'Move_Out_Date', 'Early_Note', 'Org_Phone', 'Forwarding_Address', 'Sender_Signature']),
('2c-deposit-itemization', 'Tenant', '2nd Chance — Security Deposit Itemization (21-Day)', 'Notice to Return Security Deposit',
 'Built on the Move-outs page from the final ledger and inspection: refund or itemized deductions within 21 days.',
 '<p style="text-align: center"><strong>NOTICE TO RETURN SECURITY DEPOSIT — TWENTY-ONE DAY</strong></p>
<p style="text-align: center">Wis. Stat. § 704.28</p>
<p>[[Current_Date]]</p>
<p>To: [[Lease_All_Tenants]]</p>
<p>[[Forwarding_Address]]</p>
<p>Former premises: [[Unit_Address]]</p>
<p>Tenancy ended: [[Surrender_Date]]</p>
<p>This letter accounts for your security deposit, as required by Wisconsin law. Each item withheld is listed with the amount withheld as reasonable compensation for it. Normal wear and tear is not charged. Where a repair cost was not yet known, a good-faith estimate is used, as your lease allows.</p>
[[Itemization]]
<p>[[Outcome_Text]]</p>
<p>If you have questions about this statement, call us at [[Org_Phone]].</p>
<p>[[Sender_Signature]]</p>',
 array['Current_Date', 'Lease_All_Tenants', 'Forwarding_Address', 'Unit_Address', 'Surrender_Date', 'Itemization', 'Outcome_Text', 'Org_Phone', 'Sender_Signature'])
on conflict (legacy_id) do update set html = excluded.html, fields = excluded.fields, subject = excluded.subject, description = excluded.description, name = excluded.name;

-- Resident ----------------------------------------------------------------------------

create or replace function resident_move_out()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare l leases; m move_outs; v_earliest date;
begin
  if not exists (select 1 from resident_me()) then raise exception 'Resident two-step sign-in required' using errcode = '42501'; end if;
  select x.* into m from move_outs x where resident_lease_ok(x.lease_id) order by x.created_at desc limit 1;
  select x.* into l from leases x where x.id = coalesce(m.lease_id, (select y.id from leases y where y.status in ('active') and resident_lease_ok(y.id) order by y.start_date desc limit 1));
  if l.id is null then return null; end if;
  v_earliest := (date_trunc('month', current_date + 28) + interval '1 month' - interval '1 day')::date;   -- first month-end at least 28 days away
  return jsonb_build_object('lease_id', l.id, 'lease_type', l.lease_type, 'end_date', l.end_date, 'lease_status', l.status,
    'address', (select address from rental_units where id = l.unit_id), 'earliest_mtm_date', v_earliest,
    'deposit_held', l.deposit_held, 'balance', (select coalesce(sum(amount), 0) from lease_ledger_entries where lease_id = l.id),
    'former', l.status = 'past',
    'move_out', case when m.id is null then null else jsonb_build_object('id', m.id, 'type', m.type, 'status', m.status, 'move_out_date', m.move_out_date,
      'early', m.early, 'forwarding_address', m.forwarding_address, 'tenant_tasks', m.tenant_tasks, 'inspection_at', m.inspection_at,
      'surrendered_on', m.surrendered_on, 'deposit_due_by', m.deposit_due_by, 'refund_amount', m.refund_amount, 'balance_due', m.balance_due,
      'absorb_balance', m.absorb_balance, 'refund_sent_on', m.refund_sent_on, 'access_ends_at', m.access_ends_at,
      'letter_pdf', (select pdf_path from notices where id = m.letter_notice_id)) end);
end;
$$;

create or replace function resident_move_out_notice(p_date date, p_forwarding text, p_reason text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare l leases; m move_outs; v_type text := 'voluntary'; v_early boolean := false; v_last date; t record; v_addr text;
begin
  perform resident_require_current();
  select y.* into l from leases y where y.status = 'active' and resident_lease_ok(y.id) order by y.start_date desc limit 1;
  if l.id is null then raise exception 'No active lease found.'; end if;
  if exists (select 1 from move_outs where lease_id = l.id and status <> 'closed') then raise exception 'You already gave notice. Call the office to change it.'; end if;
  if length(trim(coalesce(p_forwarding, ''))) < 10 then raise exception 'Enter your full forwarding address (street, city, state, ZIP). We mail your security deposit there.'; end if;
  if p_date is null then raise exception 'Choose your move-out date.'; end if;
  if l.lease_type = 'at_will' then
    v_last := (date_trunc('month', p_date) + interval '1 month' - interval '1 day')::date;
    if p_date <> v_last then raise exception 'A month-to-month tenancy can only end on the last day of a month. Choose %.', to_char(v_last, 'FMMonth FMDD, YYYY'); end if;
    if p_date < current_date + 28 then raise exception 'You must give at least 28 days'' notice before the end of the month. The earliest date is %.',
      to_char((date_trunc('month', current_date + 28) + interval '1 month' - interval '1 day')::date, 'FMMonth FMDD, YYYY'); end if;
  else
    if p_date < current_date then raise exception 'Choose a date from today on.'; end if;
    if p_date > l.end_date then raise exception 'Your lease ends on %. To stay longer, accept a renewal offer or talk to the office.', to_char(l.end_date, 'FMMonth FMDD, YYYY'); end if;
    v_early := p_date < l.end_date;
  end if;
  if exists (select 1 from lease_renewals where lease_id = l.id and status = 'non_renewal') then v_type := 'non_renewal'; end if;
  insert into move_outs (lease_id, type, notice_received_at, notice_by, move_out_date, early, reason, forwarding_address, forwarding_updated_at, created_by)
  values (l.id, v_type, now(), auth.email(), p_date, v_early, nullif(left(trim(p_reason), 1000), ''), left(trim(p_forwarding), 300), now(), auth.email())
  returning * into m;
  update lease_renewals set status = 'declined', answered_at = coalesce(answered_at, now()) where lease_id = l.id and status = 'offered';
  perform move_out_send_info(m.id);
  select address into v_addr from rental_units where id = l.unit_id;
  insert into email_outbox (to_email, subject, html, kind) select value, 'Notice to vacate — ' || v_addr,
    '<p>' || repair_esc(l.tenants_label) || ' gave written notice in the portal to move out of <b>' || repair_esc(v_addr) || '</b> on <b>' || to_char(p_date, 'FMMM/FMDD/YYYY') || '</b>' ||
    case when v_early then ' — before the lease end date (' || to_char(l.end_date, 'FMMM/FMDD/YYYY') || '), so they remain liable for rent until the unit is re-rented' else '' end || '.</p>' ||
    '<p>Forwarding address: ' || repair_esc(left(trim(p_forwarding), 300)) || '</p>' || coalesce('<p>Reason: <i>' || repair_esc(nullif(left(trim(p_reason), 1000), '')) || '</i></p>', '') ||
    '<p>Schedule the move-out inspection on the Move-outs page.</p>', 'move_out_staff'
  from portal_settings where key = 'office_email';
  return jsonb_build_object('ok', true, 'id', m.id, 'early', v_early);
end;
$$;

-- Forwarding address (also for former tenants) and the move-out task list.
create or replace function resident_move_out_update(p_forwarding text, p_tasks jsonb)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare m move_outs;
begin
  select x.* into m from move_outs x where resident_lease_ok(x.lease_id) and x.status <> 'closed' order by x.created_at desc limit 1;
  if m.id is null then raise exception 'No move-out in progress.' using errcode = '42501'; end if;
  if p_forwarding is not null then
    if m.letter_notice_id is not null then raise exception 'Your deposit statement was already sent. Call the office if your address changed.'; end if;
    if length(trim(p_forwarding)) < 10 then raise exception 'Enter your full forwarding address.'; end if;
    update move_outs set forwarding_address = left(trim(p_forwarding), 300), forwarding_updated_at = now() where id = m.id;
    insert into email_outbox (to_email, subject, html, kind) select value, 'Forwarding address updated',
      '<p>New forwarding address for the move-out at lease ' || upper(left(m.lease_id::text, 8)) || ': ' || repair_esc(left(trim(p_forwarding), 300)) || '</p>', 'move_out_staff'
    from portal_settings where key = 'office_email';
  end if;
  if p_tasks is not null then update move_outs set tenant_tasks = p_tasks where id = m.id; end if;
  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function resident_move_out() from public, anon;
revoke all on function resident_move_out_notice(date, text, text) from public, anon;
revoke all on function resident_move_out_update(text, jsonb) from public, anon;
grant execute on function resident_move_out() to authenticated;
grant execute on function resident_move_out_notice(date, text, text) to authenticated;
grant execute on function resident_move_out_update(text, jsonb) to authenticated;

-- Move-Out Procedure letter to every tenant on the lease.
create or replace function move_out_send_info(p_id uuid)
returns void
language plpgsql volatile security definer set search_path = public as $$
declare m move_outs; l leases; t record;
begin
  select * into m from move_outs where id = p_id;
  select * into l from leases where id = m.lease_id;
  for t in select x.name, x.email from lease_tenants lt join tenants x on x.id = lt.tenant_id where lt.lease_id = l.id and x.email is not null loop
    insert into email_outbox (to_email, subject, html, kind) values (t.email, 'Your move-out steps',
      letter_render_ctx('2c-move-out-info', l.id, jsonb_build_object('Tenant_First_Name', split_part(t.name, ' ', 1),
        'Move_Out_Date', to_char(m.move_out_date, 'FMMonth FMDD, YYYY'),
        'Early_Note', case when m.early then 'This is before your lease ends on ' || to_char(l.end_date, 'FMMonth FMDD, YYYY') ||
          '. Under your lease you remain responsible for rent until the unit is re-rented; we will make reasonable efforts to re-rent it and credit the rent we receive.' else '' end,
        'Forwarding_Address', coalesce(m.forwarding_address, 'none yet — please add it in the portal'))), 'move_out');
  end loop;
end;
$$;
revoke all on function move_out_send_info(uuid) from public, anon, authenticated;

-- Staff -------------------------------------------------------------------------------

create or replace function moveouts_staff_list()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'move_outs', coalesce((select jsonb_agg(to_jsonb(m) || jsonb_build_object('address', u.address, 'tenants', l.tenants_label, 'lease_type', l.lease_type, 'end_date', l.end_date,
        'rent', l.rent, 'lease_deposit', l.deposit_held, 'balance', (select coalesce(sum(amount), 0) from lease_ledger_entries where lease_id = l.id),
        'days_to_deadline', m.deposit_due_by - current_date, 'letter_pdf', (select pdf_path from notices where id = m.letter_notice_id)) order by m.status = 'closed', coalesce(m.move_out_date, current_date))
      from move_outs m join leases l on l.id = m.lease_id join rental_units u on u.id = l.unit_id
      where m.status <> 'closed' or m.closed_at > now() - interval '30 days'), '[]'::jsonb),
    'unrecorded', coalesce((select jsonb_agg(jsonb_build_object('lease_id', l.id, 'address', u.address, 'tenants', l.tenants_label, 'end_date', l.end_date,
        'why', (select r.status from lease_renewals r where r.lease_id = l.id order by r.created_at desc limit 1)) order by l.end_date)
      from leases l join rental_units u on u.id = l.unit_id where l.status = 'active' and not exists (select 1 from move_outs m where m.lease_id = l.id and m.status <> 'closed')
        and (exists (select 1 from lease_renewals r where r.lease_id = l.id and r.status in ('declined', 'non_renewal')) or (l.lease_type = 'fixed' and l.end_date < current_date))), '[]'::jsonb),
    'leases', coalesce((select jsonb_agg(jsonb_build_object('lease_id', l.id, 'label', u.address || ' — ' || l.tenants_label) order by u.address)
      from leases l join rental_units u on u.id = l.unit_id where l.status = 'active'
        and not exists (select 1 from move_outs m where m.lease_id = l.id and m.status <> 'closed')), '[]'::jsonb),
    'rooms', (select value::jsonb from portal_settings where key = 'move_in_rooms'));
end;
$$;

-- Staff start a move-out (paper notice, non-renewal, eviction, abandonment).
create or replace function moveout_staff_start(p_lease uuid, p_type text, p_date date, p_forwarding text, p_sheriff_on date, p_note text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare l leases; v_id uuid;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into l from leases where id = p_lease and status = 'active';
  if l.id is null then raise exception 'Lease not found.'; end if;
  if p_type not in ('voluntary', 'non_renewal', 'evicted', 'abandoned') then raise exception 'Choose why the tenancy is ending.'; end if;
  if p_date is null then raise exception 'Enter the move-out date.'; end if;
  if p_type = 'evicted' and p_sheriff_on is null then raise exception 'Enter the date of the sheriff''s removal.'; end if;
  insert into move_outs (lease_id, type, notice_received_at, notice_by, move_out_date, early, forwarding_address, forwarding_updated_at, sheriff_removal_on, staff_note, created_by)
  values (p_lease, p_type, now(), auth.email(), p_date, l.lease_type = 'fixed' and p_date < l.end_date and p_type = 'voluntary',
          nullif(trim(p_forwarding), ''), case when nullif(trim(p_forwarding), '') is not null then now() end, p_sheriff_on, nullif(trim(p_note), ''), auth.email())
  returning id into v_id;
  update lease_renewals set status = 'declined', answered_at = coalesce(answered_at, now()) where lease_id = p_lease and status = 'offered';
  if p_type in ('voluntary', 'non_renewal') then perform move_out_send_info(v_id); end if;
  return jsonb_build_object('ok', true, 'id', v_id);
exception when unique_violation then raise exception 'This lease already has a move-out in progress.';
end;
$$;

create or replace function moveout_staff_schedule(p_id uuid, p_at timestamptz)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare m move_outs; v_addr text; t record;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into m from move_outs where id = p_id and status in ('notice', 'scheduled', 'vacated');
  if m.id is null then raise exception 'Move-out not found or already inspected.'; end if;
  if p_at is null or p_at < now() then raise exception 'Choose a time in the future.'; end if;
  if m.keys_returned_on is null and p_at < now() + interval '12 hours' then raise exception 'The tenant still has the keys, so the inspection must be at least 12 hours from now (12-hour notice).'; end if;
  update move_outs set inspection_at = p_at, status = case when status = 'notice' then 'scheduled' else status end where id = p_id;
  select u.address into v_addr from leases l join rental_units u on u.id = l.unit_id where l.id = m.lease_id;
  for t in select x.name, x.email from lease_tenants lt join tenants x on x.id = lt.tenant_id where lt.lease_id = m.lease_id and x.email is not null loop
    insert into email_outbox (to_email, subject, html, kind) values (t.email, 'Your move-out inspection',
      tenant_email_wrap(split_part(t.name, ' ', 1), '<p>We will inspect <b>' || repair_esc(v_addr) || '</b> on <b>' ||
        to_char(p_at at time zone 'America/Chicago', 'FMDay, FMMonth FMDD "at" FMHH12:MI AM') || '</b>. You are welcome to be there. ' ||
        case when m.keys_returned_on is null then 'This is at least 12 hours'' notice to enter. ' else '' end ||
        'We compare the unit with your move-in checklist; your deposit statement follows within 21 days after your tenancy ends.</p>'), 'move_out');
  end loop;
  return jsonb_build_object('ok', true);
end;
$$;

-- Keys back / surrender: tenancy ends; the 21-day clock and the access window start.
create or replace function moveout_staff_vacated(p_id uuid, p_keys_on date, p_surrendered_on date)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare m move_outs; l leases; v_addr text;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into m from move_outs where id = p_id and status in ('notice', 'scheduled', 'vacated');
  if m.id is null then raise exception 'Move-out not found or already past this step.'; end if;
  if p_surrendered_on is null or p_surrendered_on > current_date then raise exception 'Enter the date the tenancy ended (surrender), not in the future.'; end if;
  update move_outs set keys_returned_on = p_keys_on, surrendered_on = p_surrendered_on, deposit_due_by = p_surrendered_on + 21,
    status = 'vacated' where id = p_id returning * into m;
  update move_outs set access_ends_at = move_out_access_end(m) where id = p_id;
  update leases set status = 'past' where id = m.lease_id returning * into l;
  update condo_units set occupancy = 'vacant' where id = (select condo_unit_id from rental_units where id = l.unit_id);
  update lease_rent_changes set canceled_at = now() where lease_id = l.id and applied_at is null and canceled_at is null;
  select address into v_addr from rental_units where id = l.unit_id;
  insert into email_outbox (to_email, subject, html, kind) select value, 'Unit vacant — list it again: ' || v_addr,
    '<p><b>' || repair_esc(v_addr) || '</b> is vacant as of ' || to_char(p_surrendered_on, 'FMMM/FMDD/YYYY') || '. The deposit statement is due by <b>' ||
    to_char(p_surrendered_on + 21, 'FMMM/FMDD/YYYY') || '</b>. Once it''s ready to show, add it back to Available Units on the website and the application.</p>', 'move_out_staff'
  from portal_settings where key = 'office_email';
  return jsonb_build_object('ok', true, 'deposit_due_by', p_surrendered_on + 21, 'access_ends_at', move_out_access_end(m));
end;
$$;

create or replace function moveout_staff_detail(p_id uuid)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare m move_outs; l leases;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into m from move_outs where id = p_id;
  select * into l from leases where id = m.lease_id;
  return jsonb_build_object('move_out', to_jsonb(m), 'rooms', (select value::jsonb from portal_settings where key = 'move_in_rooms'),
    'move_in', (select jsonb_build_object('status', c.status, 'data', c.data, 'decided_at', c.decided_at) from move_in_checklists c where c.lease_id = l.id),
    'deposit_held', l.deposit_held, 'rent', l.rent,
    'ledger', (select jsonb_agg(jsonb_build_object('date', e.entry_date, 'desc', e.description, 'account', e.gl_account, 'amount', e.amount) order by e.entry_date, e.id) from lease_ledger_entries e where e.lease_id = l.id),
    'balance', (select coalesce(sum(amount), 0) from lease_ledger_entries where lease_id = l.id),
    'suggested_credit', case when not m.early and m.surrendered_on is not null and m.surrendered_on < (date_trunc('month', m.surrendered_on) + interval '1 month' - interval '1 day')::date
        and exists (select 1 from lease_ledger_entries e where e.lease_id = l.id and e.kind = 'charge' and e.gl_account = 'Rent Income' and date_trunc('month', e.entry_date) = date_trunc('month', m.surrendered_on))
      then round(l.rent * (extract(day from (date_trunc('month', m.surrendered_on) + interval '1 month' - interval '1 day')) - extract(day from m.surrendered_on))
                 / extract(day from (date_trunc('month', m.surrendered_on) + interval '1 month' - interval '1 day')), 2) end);
end;
$$;

create or replace function moveout_staff_inspection(p_id uuid, p_checklist jsonb, p_note text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare m move_outs; p text;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into m from move_outs where id = p_id and status in ('vacated', 'inspected');
  if m.id is null then raise exception 'Record the keys and the end of the tenancy first.'; end if;
  for p in select jsonb_array_elements_text(coalesce(r.value->'photos', '[]'::jsonb)) from jsonb_each(coalesce(p_checklist->'rooms', '{}'::jsonb)) r loop
    if left(p, 45) <> m.lease_id::text || '/moveout/' then raise exception 'Photo not recognised.'; end if;
  end loop;
  update move_outs set checklist = coalesce(p_checklist, '{}'::jsonb), inspection_note = nullif(trim(p_note), ''), inspected_by = auth.email(), status = 'inspected' where id = p_id;
  return jsonb_build_object('ok', true);
end;
$$;

-- Deposit accounting: deductions (desc, amount, category), with unpaid rent and
-- charges from the ledger. Saves and returns the itemization letter for the
-- notices function (PDF on letterhead, emailed; print and mail to the
-- forwarding address).
create or replace function moveout_staff_deposit(p_id uuid, p_deductions jsonb, p_absorb boolean)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare m move_outs; l leases; d jsonb; v_ded numeric := 0; v_unpaid numeric; v_dep numeric; v_net numeric; v_items text := ''; v_out text; v_html text;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into m from move_outs where id = p_id and status in ('vacated', 'inspected');
  if m.id is null then raise exception 'Finish the inspection first (or the deposit statement was already sent).'; end if;
  if m.forwarding_address is null then raise exception 'There is no forwarding address. Ask the tenant to add it in the portal, or enter their last known address.'; end if;
  select * into l from leases where id = m.lease_id;
  for d in select * from jsonb_array_elements(coalesce(p_deductions, '[]'::jsonb)) loop
    if length(trim(coalesce(d->>'desc', ''))) < 3 or (d->>'amount') is null then raise exception 'Every line needs a description and an amount.'; end if;
    if coalesce(d->>'category', 'damage') not in ('damage', 'cleaning', 'other', 'credit') then raise exception 'Unknown category.'; end if;
    v_ded := v_ded + (d->>'amount')::numeric;
    v_items := v_items || '<li>' || repair_esc(trim(d->>'desc')) || ': ' || to_char((d->>'amount')::numeric, 'FM$999,990.00') || '</li>';
  end loop;
  v_dep := coalesce(l.deposit_held, 0);
  v_unpaid := greatest((select coalesce(sum(amount), 0) from lease_ledger_entries where lease_id = l.id), 0);
  v_net := v_dep - v_unpaid - v_ded;
  update move_outs set deductions = coalesce(p_deductions, '[]'::jsonb), deposit_held = v_dep, unpaid_balance = v_unpaid,
    refund_amount = greatest(v_net, 0), balance_due = greatest(-v_net, 0), absorb_balance = coalesce(p_absorb, false) where id = p_id;
  v_out := case when v_net > 0 then 'A refund of <b>' || to_char(v_net, 'FM$999,990.00') || '</b> is enclosed / being sent to the address above.'
                when v_net = 0 then 'Your security deposit covered the amounts above in full. Nothing is owed by either party.'
                when coalesce(p_absorb, false) then 'The amounts above are more than your security deposit by ' || to_char(-v_net, 'FM$999,990.00') ||
                  '. Under 2nd Chance Housing''s nonprofit policy, we are absorbing this balance. You owe nothing further, and we are not seeking damages or double rent.'
                else 'The amounts above are more than your security deposit. A balance of <b>' || to_char(-v_net, 'FM$999,990.00') ||
                  '</b> is due. Please pay it in your resident portal or call us to arrange payment. We are not seeking damages or double rent.' end;
  v_html := letter_render_ctx('2c-deposit-itemization', l.id, jsonb_build_object('_keep_signature', true,
    'Forwarding_Address', m.forwarding_address, 'Surrender_Date', to_char(m.surrendered_on, 'FMMonth FMDD, YYYY'), 'Outcome_Text', '[[OUTCOME]]'));
  -- Itemization and outcome are built here from escaped values, so they go in unescaped.
  v_html := replace(replace(v_html, '[[OUTCOME]]', v_out), '[[Itemization]]',
    '<p><b>Security deposit held: ' || to_char(v_dep, 'FM$999,990.00') || '</b></p>' ||
    '<p><b>Unpaid rent and charges on your account: ' || to_char(v_unpaid, 'FM$999,990.00') || '</b></p>' ||
    case when v_items <> '' then '<p><b>Deductions:</b></p><ul>' || v_items || '</ul>' else '<p>No deductions for damage or cleaning.</p>' end ||
    '<p><b>' || case when v_net >= 0 then 'Amount returned to you: ' || to_char(v_net, 'FM$999,990.00') else 'Balance after the deposit: ' || to_char(-v_net, 'FM$999,990.00') end || '</b></p>');
  return jsonb_build_object('ok', true, 'lease_id', l.id, 'deposit_held', v_dep, 'unpaid_balance', v_unpaid, 'deductions', v_ded, 'net', v_net,
    'template_id', (select id from letter_templates where legacy_id = '2c-deposit-itemization'), 'subject', 'Notice to Return Security Deposit', 'html', v_html);
end;
$$;

-- After the statement is sent: post the final ledger and move on.
create or replace function moveout_staff_finalize(p_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare m move_outs; d jsonb; v_bal numeric;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into m from move_outs where id = p_id and status in ('vacated', 'inspected');
  if m.id is null or m.letter_notice_id is null then raise exception 'Send the deposit statement first.'; end if;
  for d in select * from jsonb_array_elements(m.deductions) loop
    insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, description, amount, source)
    values (m.lease_id, case d->>'category' when 'cleaning' then 'Cleaning and Maint Income' when 'credit' then 'Rent Income' else 'Repairs Income' end, current_date,
            case when (d->>'amount')::numeric < 0 then 'credit' else 'charge' end, 'Move-out', 'Move-out: ' || trim(d->>'desc'), (d->>'amount')::numeric, 'move_out');
  end loop;
  if coalesce(m.deposit_held, 0) > 0 then
    insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, description, amount, source)
    values (m.lease_id, 'Security Deposit Liability', current_date, 'credit', 'Deposit applied', 'Security deposit applied', -m.deposit_held, 'move_out');
  end if;
  select coalesce(sum(amount), 0) into v_bal from lease_ledger_entries where lease_id = m.lease_id;
  if v_bal > 0 and m.absorb_balance then
    insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, description, amount, source, correction_note)
    values (m.lease_id, 'Rent Income', current_date, 'credit', 'Write-off', 'Balance absorbed — nonprofit policy', -v_bal, 'move_out', 'Absorbed by ' || auth.email() || ' per nonprofit policy.');
  end if;
  update leases set deposit_held = 0 where id = m.lease_id;
  update move_outs set status = 'deposit_sent', finalized_at = now(), finalized_by = auth.email() where id = p_id;
  return jsonb_build_object('ok', true, 'ledger_balance', (select coalesce(sum(amount), 0) from lease_ledger_entries where lease_id = m.lease_id));
end;
$$;

-- Refund paid out (or nothing to refund): close the move-out.
create or replace function moveout_staff_close(p_id uuid, p_method text, p_ref text, p_sent_on date)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare m move_outs;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into m from move_outs where id = p_id and status = 'deposit_sent';
  if m.id is null then raise exception 'Finalize the deposit statement first.'; end if;
  if coalesce(m.refund_amount, 0) > 0 then
    if coalesce(trim(p_method), '') = '' or p_sent_on is null then raise exception 'Record how and when the refund was sent.'; end if;
    insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, description, amount, source)
    values (m.lease_id, 'Security Deposit Liability', p_sent_on, 'refund', 'Deposit refund', 'Deposit refund (' || trim(p_method) || coalesce(' ' || nullif(trim(p_ref), ''), '') || ')', m.refund_amount, 'move_out');
  end if;
  update move_outs set status = 'closed', closed_at = now(), refund_method = nullif(trim(p_method), ''), refund_ref = nullif(trim(p_ref), ''), refund_sent_on = p_sent_on where id = p_id;
  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function moveouts_staff_list() from public, anon;
revoke all on function moveout_staff_start(uuid, text, date, text, date, text) from public, anon;
revoke all on function moveout_staff_schedule(uuid, timestamptz) from public, anon;
revoke all on function moveout_staff_vacated(uuid, date, date) from public, anon;
revoke all on function moveout_staff_detail(uuid) from public, anon;
revoke all on function moveout_staff_inspection(uuid, jsonb, text) from public, anon;
revoke all on function moveout_staff_deposit(uuid, jsonb, boolean) from public, anon;
revoke all on function moveout_staff_finalize(uuid) from public, anon;
revoke all on function moveout_staff_close(uuid, text, text, date) from public, anon;
grant execute on function moveouts_staff_list() to authenticated;
grant execute on function moveout_staff_start(uuid, text, date, text, date, text) to authenticated;
grant execute on function moveout_staff_schedule(uuid, timestamptz) to authenticated;
grant execute on function moveout_staff_vacated(uuid, date, date) to authenticated;
grant execute on function moveout_staff_detail(uuid) to authenticated;
grant execute on function moveout_staff_inspection(uuid, jsonb, text) to authenticated;
grant execute on function moveout_staff_deposit(uuid, jsonb, boolean) to authenticated;
grant execute on function moveout_staff_finalize(uuid) to authenticated;
grant execute on function moveout_staff_close(uuid, text, text, date) to authenticated;

-- Notices link-back now includes the deposit statement.
create or replace function notice_link_back(p_kind text, p_id uuid, p_notice uuid)
returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if p_kind = 'renewal' then update lease_renewals set notice_id = p_notice where id = p_id;
  elsif p_kind = 'rent_change' then update lease_rent_changes set notice_id = p_notice where id = p_id;
  elsif p_kind = 'repair' then update maintenance_requests set entry_notice_id = p_notice where id = p_id;
  elsif p_kind = 'move_out' then update move_outs set letter_notice_id = p_notice where id = p_id;
  end if;
end;
$$;
revoke all on function notice_link_back(text, uuid, uuid) from public, anon, authenticated;
grant execute on function notice_link_back(text, uuid, uuid) to service_role;

-- Daily (rent cycle): reminders, deadline warnings, unrecorded endings, and
-- access removal. Returns the sign-ins to delete (auth user ids).
create or replace function moveouts_daily(p_as_of date)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare m record; v_remove jsonb := '[]'::jsonb; n_rem int := 0; n_dl int := 0; t record; v_uid uuid;
begin
  -- 3 days before the move-out date: reminder to the tenant.
  for m in select x.*, u.address from move_outs x join leases l on l.id = x.lease_id join rental_units u on u.id = l.unit_id
           where x.status in ('notice', 'scheduled') and x.move_out_date = p_as_of + 3 and not (x.reminded ? 'three_days') loop
    for t in select y.name, y.email from lease_tenants lt join tenants y on y.id = lt.tenant_id where lt.lease_id = m.lease_id and y.email is not null loop
      insert into email_outbox (to_email, subject, html, kind) values (t.email, 'Moving out in 3 days',
        tenant_email_wrap(split_part(t.name, ' ', 1), '<p>Your move-out date is <b>' || to_char(m.move_out_date, 'FMDay, FMMonth FMDD') || '</b>. Remember: remove everything, clean, ' ||
          'and call or text ' || (select value from portal_settings where key = 'org_phone') || ' at least 2 hours before you return all keys in person. ' ||
          'Check that your forwarding address in the portal is right: that''s where your deposit goes.</p>'), 'move_out');
    end loop;
    update move_outs set reminded = reminded || '{"three_days": true}' where id = m.id;
    n_rem := n_rem + 1;
  end loop;
  -- Deposit deadline: warn staff 7 and 2 days before.
  for m in select x.*, u.address from move_outs x join leases l on l.id = x.lease_id join rental_units u on u.id = l.unit_id
           where x.status in ('vacated', 'inspected') and x.deposit_due_by is not null and x.deposit_due_by - p_as_of in (7, 2)
             and not (x.reminded ? ('deadline_' || (x.deposit_due_by - p_as_of))) loop
    insert into email_outbox (to_email, subject, html, kind) select value, 'Deposit statement due in ' || (m.deposit_due_by - p_as_of) || ' days — ' || m.address,
      '<p>The security deposit statement for <b>' || repair_esc(m.address) || '</b> must be sent by <b>' || to_char(m.deposit_due_by, 'FMMM/FMDD/YYYY') ||
      '</b> (21 days after the tenancy ended, Wis. Stat. § 704.28). Finish it on the Move-outs page.</p>', 'move_out_staff'
    from portal_settings where key = 'office_email';
    update move_outs set reminded = reminded || jsonb_build_object('deadline_' || (m.deposit_due_by - p_as_of), true) where id = m.id;
    n_dl := n_dl + 1;
  end loop;
  -- Access window over: remove the sign-in unless the person is still a tenant, owner, staff or agent elsewhere.
  for m in select x.* from move_outs x where x.access_ends_at <= now() and x.access_removed_at is null loop   -- real time, not the as-of date
    for t in select y.email from lease_tenants lt join tenants y on y.id = lt.tenant_id where lt.lease_id = m.lease_id and y.email is not null loop
      if not exists (select 1 from resident_tenant_ids(t.email) where true)
         and not exists (select 1 from condo_staff where lower(email) = lower(t.email))
         and not exists (select 1 from lease_agents where lower(email) = lower(t.email))
         and condo_owner_for_email(t.email) is null then
        select id into v_uid from auth.users where lower(email) = lower(t.email);
        if v_uid is not null then v_remove := v_remove || jsonb_build_array(v_uid); end if;
      end if;
    end loop;
    update move_outs set access_removed_at = now() where id = m.id;
  end loop;
  return jsonb_build_object('reminders', n_rem, 'deadline_warnings', n_dl, 'remove_user_ids', v_remove);
end;
$$;
revoke all on function moveouts_daily(date) from public, anon, authenticated;
grant execute on function moveouts_daily(date) to service_role;

-- Former tenants are read-only: guard every portal write ---------------------
create or replace function resident_create_request(p_category text, p_subject text, p_description text, p_entry text,
                                                   p_has_pets boolean, p_pets_note text, p_photos text[])
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare v_ids uuid[] := array(select resident_me()); v_lease uuid; v_unit text; r maintenance_requests; v_tenant text;
begin
  perform resident_require_current();
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
create or replace function resident_request_comment(p_id uuid, p_note text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
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
  return jsonb_build_object('ok', true);
end;
$$;
create or replace function resident_request_confirm(p_id uuid, p_fixed boolean, p_note text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
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
create or replace function resident_move_in_save(p_lease uuid, p_data jsonb, p_prior_list boolean, p_submit boolean)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare l leases; v_status text; v_problem text; p text; v_addr text;
begin
  perform resident_require_current();
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
create or replace function resident_message_send(p_body text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_tenant uuid; v_name text; v_unit text;
begin
  perform resident_require_current();
  select x into v_tenant from resident_me() x limit 1;
  if v_tenant is null then raise exception 'Resident two-step sign-in required' using errcode = '42501'; end if;
  if length(trim(coalesce(p_body, ''))) < 2 then raise exception 'Write your message first.'; end if;
  if (select count(*) from tenant_messages where tenant_id = v_tenant and from_resident and created_at > now() - interval '1 hour') >= 20 then
    raise exception 'Too many messages in an hour. Please call the office.'; end if;
  insert into tenant_messages (tenant_id, from_resident, body, by_email) values (v_tenant, true, left(trim(p_body), 4000), auth.email());
  select t.name, (select u.address from lease_tenants lt join leases l on l.id = lt.lease_id join rental_units u on u.id = l.unit_id
                  where lt.tenant_id = t.id and l.status in ('active', 'future') limit 1) into v_name, v_unit from tenants t where t.id = v_tenant;
  insert into email_outbox (to_email, subject, html, kind) select value, 'Message from ' || v_name || coalesce(' — ' || v_unit, ''),
    '<p><i>' || repair_esc(left(trim(p_body), 4000)) || '</i></p><p>Reply on the Messages page (replies are emailed to the tenant and kept in their portal).</p>', 'message_staff'
  from portal_settings where key = 'office_email';
  return jsonb_build_object('ok', true);
end;
$$;
create or replace function resident_profile_save(p_alt_phone text, p_emergency_name text, p_emergency_phone text, p_emergency_relation text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare digits text;
begin
  perform resident_require_current();
  if not exists (select 1 from resident_me()) then raise exception 'Resident two-step sign-in required' using errcode = '42501'; end if;
  foreach digits in array array[coalesce(p_alt_phone, ''), coalesce(p_emergency_phone, '')] loop
    if digits <> '' and length(regexp_replace(digits, '\D', '', 'g')) not in (10, 11) then raise exception 'Enter phone numbers with area code, like (414) 555-0123.'; end if;
  end loop;
  if coalesce(trim(p_emergency_name), '') <> '' and coalesce(trim(p_emergency_phone), '') = '' then raise exception 'Add your emergency contact''s phone number.'; end if;
  update tenants set alt_phone = nullif(trim(p_alt_phone), ''), emergency_name = nullif(trim(p_emergency_name), ''),
    emergency_phone = nullif(trim(p_emergency_phone), ''), emergency_relation = nullif(trim(p_emergency_relation), ''), profile_confirmed_at = now()
  where id in (select resident_me());
  return jsonb_build_object('ok', true);
end;
$$;
create or replace function resident_profile_confirm()
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
begin
  perform resident_require_current();
  if not exists (select 1 from resident_me()) then raise exception 'Resident two-step sign-in required' using errcode = '42501'; end if;
  update tenants set profile_confirmed_at = now() where id in (select resident_me());
  return jsonb_build_object('ok', true);
end;
$$;
create or replace function resident_contact_change(p_field text, p_new text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare t tenants; v_new text := trim(coalesce(p_new, ''));
begin
  perform resident_require_current();
  select * into t from tenants where id in (select resident_me()) order by created_at limit 1;
  if t.id is null then raise exception 'Resident two-step sign-in required' using errcode = '42501'; end if;
  if p_field = 'phone' then
    if length(regexp_replace(v_new, '\D', '', 'g')) <> 10 then raise exception 'Enter a 10-digit mobile number, like (414) 555-0123.'; end if;
    if regexp_replace(v_new, '\D', '', 'g') = regexp_replace(coalesce(t.phone, ''), '\D', '', 'g') then raise exception 'That''s already your number.'; end if;
  elsif p_field = 'email' then
    v_new := lower(v_new);
    if v_new !~ '^[^@\s]+@[^@\s]+\.[a-z]{2,}$' then raise exception 'Enter a valid email address.'; end if;
    if v_new = lower(coalesce(t.email, '')) then raise exception 'That''s already your email.'; end if;
  else raise exception 'Unknown field';
  end if;
  update tenant_contact_changes set status = 'declined', note = 'Replaced by a newer request', decided_at = now()
  where status = 'pending' and field = p_field and lower(requested_by) = lower(auth.email());
  insert into tenant_contact_changes (requested_by, field, old_value, new_value)
  values (lower(auth.email()), p_field, case when p_field = 'phone' then t.phone else t.email end, v_new);
  insert into email_outbox (to_email, subject, html, kind) select value, 'Contact change to confirm — ' || t.name,
    '<p>' || repair_esc(t.name) || ' asked to change their ' || case when p_field = 'phone' then 'mobile number' else 'email' end ||
    ' from <b>' || repair_esc(coalesce(case when p_field = 'phone' then t.phone else t.email end, '—')) || '</b> to <b>' || repair_esc(v_new) ||
    '</b>. It is also a sign-in factor, so call the tenant at a number you already have to confirm, then approve it on the Messages page.</p>', 'contact_change'
  from portal_settings where key = 'office_email';
  return jsonb_build_object('ok', true);
end;
$$;
create or replace function resident_renewal_accept(p_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r lease_renewals; l leases;
begin
  perform resident_require_current();
  select * into r from lease_renewals where id = p_id;
  if r.id is null or not resident_lease_ok(r.lease_id) then raise exception 'Offer not found.' using errcode = '42501'; end if;
  if r.status <> 'offered' then raise exception 'This offer was already answered.'; end if;
  select * into l from leases where id = r.lease_id;
  if current_date > l.end_date then raise exception 'This offer expired when your lease ended. Message the office.'; end if;
  update lease_renewals set status = 'accepted', answered_at = now() where id = p_id;
  return jsonb_build_object('lease_id', l.id, 'unit_label', (select address from rental_units where id = l.unit_id),
    'html', letter_render_ctx('2c-renewal-agreement', l.id, renewal_ctx(r)),
    'agent_id', (select id from lease_agents where active and signature_path is not null order by created_at limit 1),
    'signers', (select jsonb_agg(jsonb_build_object('name', t.name, 'email', t.email, 'phone', t.phone) order by t.name)
                from lease_tenants lt join tenants t on t.id = lt.tenant_id where lt.lease_id = l.id and t.email is not null));
end;
$$;
create or replace function resident_renewal_decline(p_id uuid, p_note text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r lease_renewals; v_addr text;
begin
  perform resident_require_current();
  select * into r from lease_renewals where id = p_id;
  if r.id is null or not resident_lease_ok(r.lease_id) then raise exception 'Offer not found.' using errcode = '42501'; end if;
  if r.status <> 'offered' then raise exception 'This offer was already answered.'; end if;
  update lease_renewals set status = 'declined', answered_at = now(), note = nullif(left(trim(p_note), 1000), '') where id = p_id;
  select address into v_addr from rental_units where id = (select unit_id from leases where id = r.lease_id);
  insert into email_outbox (to_email, subject, html, kind) select value, 'Not renewing — ' || v_addr,
    '<p>The tenant at <b>' || repair_esc(v_addr) || '</b> said they will not renew and are moving out.' ||
    coalesce('</p><p><i>' || repair_esc(nullif(left(trim(p_note), 1000), '')) || '</i>', '') || '</p><p>Their move-out appears on the Move-outs page once they give notice.</p>', 'renewal_staff'
  from portal_settings where key = 'office_email';
  return jsonb_build_object('ok', true);
end;
$$;

-- Former tenants still see their last lease and final statement ---------------
create or replace function resident_home()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v_ids uuid[] := array(select resident_me());
begin
  if cardinality(v_ids) = 0 then raise exception 'Resident two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'name', (select name from tenants where id = v_ids[1]),
    'settings', (select jsonb_object_agg(key, value) from portal_settings),
    'leases', coalesce((select jsonb_agg(jsonb_build_object(
        'id', l.id, 'status', l.status, 'former', l.status = 'past', 'keys_ready_at', l.keys_ready_at, 'keys_released_at', l.keys_released_at, 'move_in_charges_posted', l.move_in_charges_posted, 'account_number', coalesce(l.legacy_lease_number, upper(left(l.id::text, 8))), 'address', coalesce(u.address, p.street), 'unit_number', u.unit_number,
        'start_date', l.start_date, 'end_date', l.end_date, 'lease_type', l.lease_type, 'rent', l.rent, 'deposit_held', l.deposit_held,
        'balance', (select coalesce(sum(amount), 0) from lease_ledger_entries where lease_id = l.id),
        'tenants', (select jsonb_agg(t.name order by t.name) from lease_tenants x join tenants t on t.id = x.tenant_id where x.lease_id = l.id),
        'history', (select jsonb_agg(jsonb_build_object('date', e.entry_date, 'kind', e.kind, 'type', e.raw_type, 'memo', e.description, 'account', e.gl_account, 'amount', e.amount) order by e.entry_date, e.id)
                    from lease_ledger_entries e where e.lease_id = l.id),
        'files', (select jsonb_agg(jsonb_build_object('kind', f.kind, 'status', f.status, 'dated', f.dated, 'note', f.note) order by f.dated) from lease_files f where f.lease_id = l.id)))
      from leases l join rental_units u on u.id = l.unit_id join rental_properties p on p.id = u.property_id
      where (l.status in ('active', 'future') or exists (select 1 from move_outs mo where mo.lease_id = l.id and mo.access_ends_at > now() and mo.access_removed_at is null))
        and exists (select 1 from lease_tenants x where x.lease_id = l.id and x.tenant_id = any(v_ids))), '[]'::jsonb),
    'land_contracts', coalesce((select jsonb_agg(jsonb_build_object(
        'id', c.id, 'property', p.name, 'street', p.street, 'monthly_payment', c.monthly_payment, 'contract_date', c.contract_date,
        'maturity_date', c.maturity_date, 'interest_rate', c.interest_rate, 'purchase_price', c.purchase_price,
        'principal_now', (select s.ending_balance from land_contract_schedule s where s.contract_id = c.id and s.due_date <= current_date order by s.n desc limit 1),
        'balance', (select coalesce(sum(amount), 0) from land_contract_ledger where contract_id = c.id),
        'history', (select jsonb_agg(jsonb_build_object('date', e.entry_date, 'kind', e.kind, 'type', e.raw_type, 'memo', e.description, 'amount', e.amount) order by e.entry_date, e.id)
                    from land_contract_ledger e where e.contract_id = c.id)))
      from land_contracts c join rental_properties p on p.id = c.property_id
      where c.status = 'active' and exists (select 1 from land_contract_buyers b where b.contract_id = c.id and b.tenant_id = any(v_ids))), '[]'::jsonb),
    'signing', coalesce((select jsonb_agg(jsonb_build_object('doc_id', d.id, 'title', d.title, 'unit_label', d.unit_label, 'status', d.status,
        'created_at', d.created_at, 'executed_at', d.executed_at, 'executed_pdf_path', d.executed_pdf_path, 'you_signed', s.signed_at is not null) order by d.created_at desc)
      from lease_signing_docs d join lease_signing_signers s on s.doc_id = d.id
      where lower(s.email) = lower(auth.email()) and d.status <> 'void'), '[]'::jsonb),
    'requests', coalesce((select jsonb_agg(jsonb_build_object('id', r.id, 'number', r.number, 'subject', r.subject, 'description', r.description,
        'status', r.status, 'created_at', r.created_at, 'photos', r.photos, 'entry_permission', r.entry_permission,
        'updates', (select jsonb_agg(jsonb_build_object('at', u2.at, 'status', u2.status, 'note', u2.note) order by u2.at)
                    from maintenance_request_updates u2 where u2.request_id = r.id and u2.visible_to_resident)) order by r.created_at desc)
      from maintenance_requests r where r.tenant_id = any(v_ids)), '[]'::jsonb),
    'announcements', coalesce((select jsonb_agg(jsonb_build_object('title', a.title, 'body', a.body, 'created_on', a.created_on) order by a.created_on desc)
      from announcements a where a.status = 'current' and (a.expires_on is null or a.expires_on >= current_date)), '[]'::jsonb),
    'contacts', coalesce((select jsonb_agg(jsonb_build_object('name', v.name, 'category', coalesce(v.resident_category, v.category), 'email', v.email,
        'phone', coalesce(v.phone, v.mobile)) order by v.name) from vendors v where v.show_to_residents), '[]'::jsonb)
  );
end;
$$;
