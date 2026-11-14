-- Stage 7 (tenant-journey-spec): lease ending — renew or not.
--  * Staff set the renewal rent and term (12 or 6 months, or month to month)
--    and send the offer; the tenant accepts and signs online (Lease Renewal
--    Agreement through the existing online signing, countersigned by the agent)
--    or says they're moving out (Stage 8).
--  * On signing, the same lease continues with the new term; a rent change is
--    scheduled for the new term's first day (ledger stays continuous).
--  * Reminders: staff digest of fixed-term leases ending within 90 days (1st and
--    15th); tenant follow-ups 7 and 14 days after an unanswered offer; staff
--    alert when the answer-by date passes.
--  * Non-renewal notice (lease for a term ends on its own; the notice confirms
--    it in writing) and, for month-to-month tenancies, the Notice of Change of
--    Rent (at least 28 days ahead, effective the 1st of a month).

alter table lease_signing_docs add column if not exists renewal_id uuid;
alter table lease_files drop constraint if exists lease_files_kind_check;
alter table lease_files add constraint lease_files_kind_check check (kind in ('signed_lease', 'addendum', 'rent_increase', 'renewal', 'other'));

create table if not exists lease_renewals (
  id uuid primary key default gen_random_uuid(),
  lease_id uuid not null references leases(id) on delete cascade,
  status text not null default 'offered' check (status in ('offered', 'accepted', 'signed', 'declined', 'non_renewal', 'withdrawn', 'expired')),
  current_rent numeric(10, 2),
  new_rent numeric(10, 2),
  term text check (term in ('12', '6', 'mtm')),
  new_start date,
  new_end date,
  respond_by date,
  offered_at timestamptz,
  offered_by text,
  follow_ups int not null default 0,
  last_follow_up_at timestamptz,
  overdue_alerted_at timestamptz,
  answered_at timestamptz,
  signing_doc_id uuid references lease_signing_docs(id),
  notice_id uuid references notices(id),
  note text,
  created_at timestamptz not null default now()
);
alter table lease_renewals enable row level security;
create index if not exists lease_renewals_lease_idx on lease_renewals (lease_id, created_at desc);
alter table lease_signing_docs drop constraint if exists lease_signing_docs_renewal_fkey;
alter table lease_signing_docs add constraint lease_signing_docs_renewal_fkey foreign key (renewal_id) references lease_renewals(id);

create table if not exists lease_rent_changes (
  id uuid primary key default gen_random_uuid(),
  lease_id uuid not null references leases(id) on delete cascade,
  new_rent numeric(10, 2) not null,
  effective_on date not null,
  reason text not null check (reason in ('renewal', 'rent_change')),
  renewal_id uuid references lease_renewals(id),
  notice_id uuid references notices(id),
  created_by text,
  created_at timestamptz not null default now(),
  applied_at timestamptz,
  canceled_at timestamptz
);
alter table lease_rent_changes enable row level security;

-- Daily (rent cycle, before billing): apply rent changes that are due.
create or replace function leases_apply_rent_changes(p_as_of date)
returns int
language plpgsql volatile security definer set search_path = public as $$
declare r record; n int := 0;
begin
  for r in select * from lease_rent_changes where applied_at is null and canceled_at is null and effective_on <= p_as_of order by effective_on loop
    update leases set rent = r.new_rent where id = r.lease_id;
    update lease_rent_changes set applied_at = now() where id = r.id;
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke all on function leases_apply_rent_changes(date) from public, anon, authenticated;
grant execute on function leases_apply_rent_changes(date) to service_role;

-- Templates ---------------------------------------------------------------------

insert into letter_templates (legacy_id, recipient, name, subject, description, html, fields) values
('2c-renewal-offer', 'Tenant', '2nd Chance — Lease Renewal Offer', 'Your lease renewal offer',
 'Emailed when staff send a renewal offer; the tenant answers in the portal.',
 '<p>[[Current_Date]]</p>
<p>Dear [[Tenant_First_Name]],</p>
<p>It has been a pleasure having you as a resident. Your current lease for <b>[[Unit_Address]]</b> ends on <b>[[Lease_End_Date]]</b>. We value you and want to keep you with us, so we are offering to renew:</p>
<ul><li><b>Term:</b> [[Renewal_Term_Text]]</li><li><b>Rent:</b> [[Renewal_Rent]] a month (now [[Lease_Rent]]), starting [[Renewal_Start]]</li><li>Everything else in your lease stays the same.</li></ul>
<p>Please answer by <b>[[Respond_By]]</b> in your resident portal: <a href="[[Portal_URL]]#renewal">[[Portal_URL]]#renewal</a>. You can accept and sign online, or tell us you are moving out.</p>
<p>If you have any questions, message us in the portal or call [[Org_Phone]]. We look forward to continuing our relationship.</p>
<p>Sincerely,</p><p>[[Sender_Signature]]</p>',
 array['Current_Date', 'Tenant_First_Name', 'Unit_Address', 'Lease_End_Date', 'Renewal_Term_Text', 'Renewal_Rent', 'Lease_Rent', 'Renewal_Start', 'Respond_By', 'Portal_URL', 'Org_Phone', 'Sender_Signature']),
('2c-renewal-agreement', 'Tenant', '2nd Chance — Lease Renewal Agreement', 'Lease Renewal Agreement',
 'Signed online when the tenant accepts a renewal offer.',
 '<h1 style="text-align: center">Lease Renewal Agreement</h1>
<p><b>Landlord:</b> 2nd Chance Housing Inc., agent for the owner &nbsp; <b>Tenant(s):</b> [[Lease_All_Tenants]]</p>
<p><b>Premises:</b> [[Unit_Address]]</p>
<p>The Residential Rental Agreement for the Premises that began on [[Lease_Start_Date]] (the "Lease") is renewed on these terms:</p>
<p><b>1. Term.</b> [[Renewal_Term_Text]].</p>
<p><b>2. Rent.</b> [[Renewal_Rent]] per month, due on or before the 1st day of each month, starting [[Renewal_Start]].</p>
<p><b>3. Security deposit.</b> The security deposit of [[Lease_Security_Deposit]] continues to be held under the Lease.</p>
<p><b>4. Everything else stays the same.</b> All other terms of the Lease, including its Rules and Regulations and addenda, remain in full effect for the renewal term.</p>
<p><b>5. Electronic signatures.</b> The parties agree to sign this Agreement electronically, and an electronic signature has the same effect as a handwritten one.</p>',
 array['Lease_All_Tenants', 'Unit_Address', 'Lease_Start_Date', 'Renewal_Term_Text', 'Renewal_Rent', 'Renewal_Start', 'Lease_Security_Deposit']),
('2c-non-renewal', 'Tenant', '2nd Chance — Notice of Nonrenewal', 'Notice of Nonrenewal of Lease',
 'Confirms in writing that a lease for a term will not be renewed.',
 '<p style="text-align: center"><strong>NOTICE OF NONRENEWAL OF LEASE</strong></p>
<p>[[Current_Date]]</p>
<p>To: [[Lease_All_Tenants]]</p>
<p>[[Unit_Address]]</p>
<p>Your lease for the premises above ends on <b>[[Lease_End_Date]]</b> and will not be renewed. As your lease says, a lease for a term ends automatically on its last day; this notice confirms it in writing.</p>
<p>You must move out and return all keys by 11:59 p.m. on <b>[[Lease_End_Date]]</b>.</p>
<p>[[NonRenewal_Note]]</p>
<p>Please enter your forwarding address on the Move-out page of your resident portal so we can return your security deposit, with an itemized statement of anything withheld, within 21 days as required by Wis. Stat. § 704.28. Move-out instructions are on that page too.</p>
<p>If you have questions, call us at [[Org_Phone]].</p>
<p>[[Sender_Signature]]</p>',
 array['Current_Date', 'Lease_All_Tenants', 'Unit_Address', 'Lease_End_Date', 'NonRenewal_Note', 'Org_Phone', 'Sender_Signature']),
('2c-rent-change', 'Tenant', '2nd Chance — Notice of Change of Rent', 'Notice of Change of Rent',
 'Month-to-month tenancies: changes the rent with at least 28 days'' notice, effective the 1st of a month.',
 '<p style="text-align: center"><strong>NOTICE OF CHANGE OF RENT</strong></p>
<p>[[Current_Date]]</p>
<p>To: [[Lease_All_Tenants]]</p>
<p>[[Unit_Address]]</p>
<p>This is notice that, effective <b>[[Effective_Date]]</b>, the rent for the unit you occupy at the address above changes from [[Lease_Rent]] to <b>[[New_Rent]]</b> per month, payable on or before the 1st day of the month.</p>
<p>This notice is given at least 28 days before the change takes effect, at the start of a rental period, as required for a month-to-month tenancy. All other terms of your rental agreement stay the same.</p>
<p>[[Rent_Change_Note]]</p>
<p>If you have questions, call us at [[Org_Phone]].</p>
<p>[[Sender_Signature]]</p>',
 array['Current_Date', 'Lease_All_Tenants', 'Unit_Address', 'Effective_Date', 'Lease_Rent', 'New_Rent', 'Rent_Change_Note', 'Org_Phone', 'Sender_Signature'])
on conflict (legacy_id) do update set html = excluded.html, fields = excluded.fields, subject = excluded.subject, description = excluded.description, name = excluded.name;

create or replace function renewal_term_text(p_term text, p_start date, p_end date)
returns text
language sql immutable as $$
  select case when p_term = 'mtm' then 'Month to month starting ' || to_char(p_start, 'FMMonth FMDD, YYYY') ||
              ' (either party may end it with at least 28 days'' written notice before the end of a calendar month)'
         else p_term || ' months, from ' || to_char(p_start, 'FMMonth FMDD, YYYY') || ' through ' || to_char(p_end, 'FMMonth FMDD, YYYY') end;
$$;

create or replace function renewal_ctx(r lease_renewals)
returns jsonb
language sql stable as $$
  select jsonb_build_object('Renewal_Term_Text', renewal_term_text(r.term, r.new_start, r.new_end),
    'Renewal_Rent', to_char(r.new_rent, 'FM$999,990.00'), 'Renewal_Start', to_char(r.new_start, 'FMMonth FMDD, YYYY'),
    'Respond_By', to_char(r.respond_by, 'FMMonth FMDD, YYYY'));
$$;

-- Staff ----------------------------------------------------------------------------

create or replace function renewals_staff_list()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('lease_id', l.id, 'address', u.address, 'tenants', l.tenants_label, 'lease_type', l.lease_type,
      'start_date', l.start_date, 'end_date', l.end_date, 'rent', l.rent, 'days_left', l.end_date - current_date,
      'renewal', (select to_jsonb(r) from lease_renewals r where r.lease_id = l.id order by r.created_at desc limit 1),
      'pending_rent_change', (select to_jsonb(c) from lease_rent_changes c where c.lease_id = l.id and c.applied_at is null and c.canceled_at is null order by c.effective_on limit 1))
    order by l.lease_type, l.end_date nulls last, u.address)
    from leases l join rental_units u on u.id = l.unit_id where l.status = 'active'), '[]'::jsonb);
end;
$$;

create or replace function renewal_staff_offer(p_lease uuid, p_rent numeric, p_term text, p_respond_by date)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare l leases; r lease_renewals; v_start date; v_end date; t record; n int := 0;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into l from leases where id = p_lease and status = 'active';
  if l.id is null then raise exception 'Lease not found.'; end if;
  if l.lease_type <> 'fixed' or l.end_date is null then raise exception 'Only a lease for a term has an end date to renew. Use "Change rent" for month-to-month.'; end if;
  if p_term not in ('12', '6', 'mtm') then raise exception 'Choose the renewal term.'; end if;
  if p_rent is null or p_rent < 100 or p_rent > 10000 then raise exception 'Enter the renewal rent.'; end if;
  if p_respond_by is null or p_respond_by < current_date or p_respond_by >= l.end_date then raise exception 'The answer-by date must be between today and the lease end date.'; end if;
  if exists (select 1 from lease_renewals where lease_id = p_lease and status in ('accepted', 'signed', 'non_renewal')) then raise exception 'This lease already has a signed renewal or a non-renewal.'; end if;
  update lease_renewals set status = 'withdrawn' where lease_id = p_lease and status = 'offered';
  v_start := l.end_date + 1;
  v_end := case p_term when '12' then (v_start + interval '12 months' - interval '1 day')::date when '6' then (v_start + interval '6 months' - interval '1 day')::date end;
  insert into lease_renewals (lease_id, status, current_rent, new_rent, term, new_start, new_end, respond_by, offered_at, offered_by)
  values (p_lease, 'offered', l.rent, round(p_rent, 2), p_term, v_start, v_end, p_respond_by, now(), auth.email()) returning * into r;
  for t in select x.name, x.email from lease_tenants lt join tenants x on x.id = lt.tenant_id where lt.lease_id = p_lease and x.email is not null loop
    insert into email_outbox (to_email, subject, html, kind) values (t.email, 'Your lease renewal offer',
      letter_render_ctx('2c-renewal-offer', p_lease, renewal_ctx(r) || jsonb_build_object('Tenant_First_Name', split_part(t.name, ' ', 1))), 'renewal');
    n := n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'id', r.id, 'emailed', n);
end;
$$;

-- Non-renewal: returns the notice for the notices function to PDF, file and email.
create or replace function renewal_staff_non_renewal(p_lease uuid, p_note text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare l leases; v_id uuid;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into l from leases where id = p_lease and status = 'active';
  if l.id is null or l.lease_type <> 'fixed' or l.end_date is null then raise exception 'Only a lease for a term can be non-renewed. A month-to-month tenancy ends with a 28-day notice (Notices page).'; end if;
  if l.end_date < current_date then raise exception 'This lease already ended.'; end if;
  if exists (select 1 from lease_renewals where lease_id = p_lease and status in ('accepted', 'signed')) then raise exception 'The tenant already accepted a renewal.'; end if;
  update lease_renewals set status = 'withdrawn' where lease_id = p_lease and status = 'offered';
  insert into lease_renewals (lease_id, status, current_rent, offered_by, note, answered_at) values (p_lease, 'non_renewal', l.rent, auth.email(), nullif(trim(p_note), ''), now())
  returning id into v_id;
  return jsonb_build_object('ok', true, 'renewal_id', v_id, 'lease_id', p_lease, 'template_id', (select id from letter_templates where legacy_id = '2c-non-renewal'),
    'subject', 'Notice of Nonrenewal of Lease', 'days_left', l.end_date - current_date,
    'html', letter_render_ctx('2c-non-renewal', p_lease, jsonb_build_object('_keep_signature', true, 'NonRenewal_Note', coalesce(nullif(trim(p_note), ''), ''))));
end;
$$;

-- Month-to-month rent change: at least 28 days ahead, effective the 1st.
create or replace function rent_change_staff(p_lease uuid, p_new_rent numeric, p_effective date, p_note text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare l leases; v_id uuid;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into l from leases where id = p_lease and status = 'active';
  if l.id is null then raise exception 'Lease not found.'; end if;
  if l.lease_type <> 'at_will' then raise exception 'During a lease for a term the rent changes at renewal. Send a renewal offer instead.'; end if;
  if p_new_rent is null or p_new_rent < 100 or p_new_rent > 10000 or p_new_rent = l.rent then raise exception 'Enter the new rent.'; end if;
  if p_effective is null or extract(day from p_effective) <> 1 then raise exception 'The change must start on the 1st of a month (the start of a rental period).'; end if;
  if p_effective < current_date + 28 then raise exception 'The change must be at least 28 days from today: the earliest is %.',
    to_char((date_trunc('month', current_date + 28) + case when extract(day from current_date + 28) = 1 then interval '0' else interval '1 month' end)::date, 'FMMonth FMDD, YYYY'); end if;
  update lease_rent_changes set canceled_at = now() where lease_id = p_lease and applied_at is null and canceled_at is null and reason = 'rent_change';
  insert into lease_rent_changes (lease_id, new_rent, effective_on, reason, created_by) values (p_lease, round(p_new_rent, 2), p_effective, 'rent_change', auth.email()) returning id into v_id;
  return jsonb_build_object('ok', true, 'change_id', v_id, 'lease_id', p_lease, 'template_id', (select id from letter_templates where legacy_id = '2c-rent-change'),
    'subject', 'Notice of Change of Rent',
    'html', letter_render_ctx('2c-rent-change', p_lease, jsonb_build_object('_keep_signature', true, 'Effective_Date', to_char(p_effective, 'FMMonth FMDD, YYYY'),
      'New_Rent', to_char(round(p_new_rent, 2), 'FM$999,990.00'), 'Rent_Change_Note', coalesce(nullif(trim(p_note), ''), ''))));
end;
$$;

-- The notices function links a filed notice back (non-renewal or rent change).
create or replace function notice_link_back(p_kind text, p_id uuid, p_notice uuid)
returns void
language plpgsql volatile security definer set search_path = public as $$
begin
  if p_kind = 'renewal' then update lease_renewals set notice_id = p_notice where id = p_id;
  elsif p_kind = 'rent_change' then update lease_rent_changes set notice_id = p_notice where id = p_id;
  elsif p_kind = 'repair' then update maintenance_requests set entry_notice_id = p_notice where id = p_id;
  end if;
end;
$$;
revoke all on function notice_link_back(text, uuid, uuid) from public, anon, authenticated;
grant execute on function notice_link_back(text, uuid, uuid) to service_role;

-- Resident ---------------------------------------------------------------------------

create or replace function resident_renewal()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare r lease_renewals; l leases;
begin
  if not exists (select 1 from resident_me()) then raise exception 'Resident two-step sign-in required' using errcode = '42501'; end if;
  select x.* into r from lease_renewals x join leases y on y.id = x.lease_id
  where resident_lease_ok(x.lease_id) and y.status = 'active' and x.status in ('offered', 'accepted', 'signed', 'declined', 'non_renewal')
  order by x.created_at desc limit 1;
  if r.id is null then return null; end if;
  select * into l from leases where id = r.lease_id;
  return to_jsonb(r) - 'offered_by' - 'follow_ups' - 'last_follow_up_at' - 'overdue_alerted_at' || jsonb_build_object(
    'term_text', case when r.term is not null then renewal_term_text(r.term, r.new_start, r.new_end) end,
    'end_date', l.end_date, 'address', (select address from rental_units where id = l.unit_id),
    'signing_waiting', exists (select 1 from lease_signing_docs d join lease_signing_signers s on s.doc_id = d.id
                               where d.id = r.signing_doc_id and d.status = 'sent' and lower(s.email) = lower(auth.email()) and s.signed_at is null));
end;
$$;

-- Accept: the lease-signing function calls this (as the resident) to get the
-- renewal agreement to sign. Returns the document material.
create or replace function resident_renewal_accept(p_id uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r lease_renewals; l leases;
begin
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

-- Called by lease-signing when the renewal agreement is fully signed.
create or replace function renewal_from_signing(p_doc uuid)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare d lease_signing_docs; r lease_renewals; l leases; v_addr text; t record;
begin
  select * into d from lease_signing_docs where id = p_doc and status = 'signed';
  if d.id is null or d.renewal_id is null then raise exception 'Not a signed renewal.'; end if;
  select * into r from lease_renewals where id = d.renewal_id;
  if r.status = 'signed' then return jsonb_build_object('ok', true, 'already', true); end if;
  select * into l from leases where id = r.lease_id;
  update leases set end_date = r.new_end, lease_type = case when r.term = 'mtm' then 'at_will' else 'fixed' end where id = l.id;
  if r.new_rent is distinct from l.rent then
    insert into lease_rent_changes (lease_id, new_rent, effective_on, reason, renewal_id, created_by) values (l.id, r.new_rent, r.new_start, 'renewal', r.id, 'renewal');
  end if;
  insert into lease_files (lease_id, kind, status, file_path, dated, note)
  values (l.id, 'renewal', 'on_file', 'lease-signing:' || d.executed_pdf_path, current_date, 'Lease Renewal Agreement signed online: ' || renewal_term_text(r.term, r.new_start, r.new_end) || ', rent ' || to_char(r.new_rent, 'FM$999,990.00') || '.');
  update lease_renewals set status = 'signed', signing_doc_id = d.id where id = r.id;
  select address into v_addr from rental_units where id = l.unit_id;
  insert into email_outbox (to_email, subject, html, kind) select value, 'Renewal signed — ' || v_addr,
    '<p>The lease for <b>' || repair_esc(v_addr) || '</b> (' || repair_esc(l.tenants_label) || ') is renewed: ' || renewal_term_text(r.term, r.new_start, r.new_end) ||
    ', rent ' || to_char(r.new_rent, 'FM$999,990.00') || '. The rent change is scheduled for ' || to_char(r.new_start, 'FMMM/FMDD/YYYY') || '.</p>', 'renewal_staff'
  from portal_settings where key = 'office_email';
  return jsonb_build_object('ok', true);
end;
$$;
revoke all on function renewal_from_signing(uuid) from public, anon, authenticated;
grant execute on function renewal_from_signing(uuid) to service_role;

-- Daily: digest, follow-ups, overdue answers, offers past the lease end.
create or replace function renewals_daily(p_as_of date)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare r record; n_follow int := 0; n_overdue int := 0; v_digest text; t record;
begin
  -- Follow up 7 and 14 days after an unanswered offer.
  for r in select x.* from lease_renewals x where x.status = 'offered'
           and ((x.follow_ups = 0 and x.offered_at::date <= p_as_of - 7) or (x.follow_ups = 1 and x.offered_at::date <= p_as_of - 14)) loop
    for t in select y.name, y.email from lease_tenants lt join tenants y on y.id = lt.tenant_id where lt.lease_id = r.lease_id and y.email is not null loop
      insert into email_outbox (to_email, subject, html, kind) values (t.email, 'Reminder: your lease renewal offer',
        tenant_email_wrap(split_part(t.name, ' ', 1), '<p>We haven''t heard back about your lease renewal offer (' || to_char(r.new_rent, 'FM$999,990.00') ||
          ' a month, ' || renewal_term_text(r.term, r.new_start, r.new_end) || '). Please answer by <b>' || to_char(r.respond_by, 'FMMonth FMDD') ||
          '</b> in your resident portal: <a href="' || (select value from portal_settings where key = 'resident_url') || '#renewal">Renewal</a>.</p>'), 'renewal');
    end loop;
    update lease_renewals set follow_ups = follow_ups + 1, last_follow_up_at = now() where id = r.id;
    n_follow := n_follow + 1;
  end loop;
  -- Answer-by date passed: tell staff once.
  for r in select x.*, u.address from lease_renewals x join leases l on l.id = x.lease_id join rental_units u on u.id = l.unit_id
           where x.status = 'offered' and x.respond_by < p_as_of and x.overdue_alerted_at is null loop
    insert into email_outbox (to_email, subject, html, kind) select value, 'No answer to renewal offer — ' || r.address,
      '<p>The renewal offer for <b>' || repair_esc(r.address) || '</b> had an answer-by date of ' || to_char(r.respond_by, 'FMMM/FMDD') || ' and the tenant hasn''t answered. Call them, or send a non-renewal notice on the Renewals page.</p>', 'renewal_staff'
    from portal_settings where key = 'office_email';
    update lease_renewals set overdue_alerted_at = now() where id = r.id;
    n_overdue := n_overdue + 1;
  end loop;
  update lease_renewals x set status = 'expired' from leases l where l.id = x.lease_id and x.status = 'offered' and l.end_date < p_as_of;
  -- Digest on the 1st and 15th: leases for a term ending within 90 days with no offer or decision yet.
  if extract(day from p_as_of) in (1, 15) then
    select string_agg('<li>' || repair_esc(u.address) || ' — ' || repair_esc(l.tenants_label) || ': ends ' || to_char(l.end_date, 'FMMM/FMDD/YYYY') ||
                      ' (' || (l.end_date - p_as_of) || ' days)</li>', '' order by l.end_date) into v_digest
    from leases l join rental_units u on u.id = l.unit_id
    where l.status = 'active' and l.lease_type = 'fixed' and l.end_date between p_as_of and p_as_of + 90
      and not exists (select 1 from lease_renewals x where x.lease_id = l.id and x.status in ('offered', 'accepted', 'signed', 'declined', 'non_renewal'));
    if v_digest is not null then
      insert into email_outbox (to_email, subject, html, kind) select value, 'Leases ending in the next 90 days',
        '<p>These leases end soon and have no renewal offer or non-renewal yet:</p><ul>' || v_digest || '</ul><p>Set the renewal rent and send offers on the Renewals page.</p>', 'renewal_staff'
      from portal_settings where key = 'office_email';
    end if;
  end if;
  return jsonb_build_object('follow_ups', n_follow, 'overdue_alerts', n_overdue, 'digest', v_digest is not null);
end;
$$;
revoke all on function renewals_daily(date) from public, anon, authenticated;
grant execute on function renewals_daily(date) to service_role;

revoke all on function renewals_staff_list() from public, anon;
revoke all on function renewal_staff_offer(uuid, numeric, text, date) from public, anon;
revoke all on function renewal_staff_non_renewal(uuid, text) from public, anon;
revoke all on function rent_change_staff(uuid, numeric, date, text) from public, anon;
revoke all on function resident_renewal() from public, anon;
revoke all on function resident_renewal_accept(uuid) from public, anon;
revoke all on function resident_renewal_decline(uuid, text) from public, anon;
grant execute on function renewals_staff_list() to authenticated;
grant execute on function renewal_staff_offer(uuid, numeric, text, date) to authenticated;
grant execute on function renewal_staff_non_renewal(uuid, text) to authenticated;
grant execute on function rent_change_staff(uuid, numeric, date, text) to authenticated;
grant execute on function resident_renewal() to authenticated;
grant execute on function resident_renewal_accept(uuid) to authenticated;
grant execute on function resident_renewal_decline(uuid, text) to authenticated;
