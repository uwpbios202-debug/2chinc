-- Stage 2 (tenant-journey-spec): lease signed -> move-in payment -> keys.
-- When a lease signed online is executed (all tenants + the agent), the
-- system creates the tenancy: tenants, lease (future or active), move-in
-- charges (security deposit + first month's rent), the signed lease on file,
-- and marks the unit tenant-occupied. When the move-in charges are fully paid,
-- staff are told the keys can be released (rule 7: even before the start date)
-- and the tenant is told their keys are ready.

alter table leases add column if not exists signing_doc_id uuid references lease_signing_docs(id);
alter table leases add column if not exists application_id uuid references rental_applications(id);
alter table leases add column if not exists move_in_charges_posted boolean not null default false;
alter table leases add column if not exists keys_ready_at timestamptz;
alter table leases add column if not exists keys_released_at timestamptz;
alter table leases add column if not exists keys_released_by text;
create unique index if not exists leases_signing_doc_idx on leases (signing_doc_id) where signing_doc_id is not null;

-- Residents include tenants whose lease starts in the future.
create or replace function resident_tenant_ids(p_email text)
returns setof uuid
language sql stable security definer set search_path = public
as $$
  select t.id from tenants t
  where lower(t.email) = lower(p_email)
    and (exists (select 1 from lease_tenants lt join leases l on l.id = lt.lease_id where lt.tenant_id = t.id and l.status in ('active', 'future'))
      or exists (select 1 from land_contract_buyers b join land_contracts c on c.id = b.contract_id where b.tenant_id = t.id and c.status = 'active'));
$$;

-- Build the tenancy from an executed signing document. Idempotent.
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
  return v_lease;
end;
$$;
revoke all on function lease_from_signing(uuid) from public, anon, authenticated;
grant execute on function lease_from_signing(uuid) to service_role;

-- Keys: once the move-in charges are fully paid, tell staff and the tenant.
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
     '<p>The security deposit and first month''s rent for <b>' || v_addr || '</b> (' || l.tenants_label || ') are paid. The keys can be released now, even before the lease start date (' || to_char(l.start_date, 'FMMM/FMDD/YYYY') || ').</p><p>Record the hand-over on the Rentals page.</p>', 'keys_ready');
  for t in select x.name, x.email from lease_tenants lt join tenants x on x.id = lt.tenant_id where lt.lease_id = l.id and x.email is not null loop
    insert into email_outbox (to_email, subject, html, kind) values (t.email, 'Your keys are ready',
      '<p>Hi ' || split_part(t.name, ' ', 1) || ',</p><p>Your security deposit and first month''s rent are paid. Your keys for <b>' || v_addr || '</b> are ready. You can move in early with no extra charge.</p><p>Call ' || coalesce((select value from portal_settings where key = 'org_phone'), '') || ' to arrange pick-up.</p><p>2nd Chance Housing</p>', 'keys_ready');
  end loop;
  return new;
end;
$$;
drop trigger if exists lease_ledger_keys_ready on lease_ledger_entries;
create trigger lease_ledger_keys_ready after insert on lease_ledger_entries for each row execute function lease_keys_ready_check();

-- Staff: move-ins (keys pending / ready) and the hand-over.
create or replace function move_in_staff_list()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('lease_id', l.id, 'address', u.address, 'tenants', l.tenants_label, 'start_date', l.start_date, 'status', l.status,
      'rent', l.rent, 'balance', (select coalesce(sum(amount), 0) from lease_ledger_entries where lease_id = l.id),
      'keys_ready_at', l.keys_ready_at, 'keys_released_at', l.keys_released_at, 'keys_released_by', l.keys_released_by) order by l.start_date)
    from leases l join rental_units u on u.id = l.unit_id where l.move_in_charges_posted and (l.keys_released_at is null or l.keys_released_at > now() - interval '30 days')), '[]'::jsonb);
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
  return jsonb_build_object('ok', true);
end;
$$;
revoke all on function move_in_staff_list() from public, anon;
revoke all on function lease_keys_released(uuid) from public, anon;
grant execute on function move_in_staff_list() to authenticated;
grant execute on function lease_keys_released(uuid) to authenticated;

-- Future leases become active on their start date (run daily by the rent cycle).
create or replace function leases_activate_due(p_as_of date)
returns int
language sql volatile security definer set search_path = public as $$
  with u as (update leases set status = 'active' where status = 'future' and start_date <= p_as_of returning 1) select count(*)::int from u;
$$;
revoke all on function leases_activate_due(date) from public, anon, authenticated;
grant execute on function leases_activate_due(date) to service_role;

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
        'id', l.id, 'status', l.status, 'keys_ready_at', l.keys_ready_at, 'keys_released_at', l.keys_released_at, 'move_in_charges_posted', l.move_in_charges_posted, 'account_number', coalesce(l.legacy_lease_number, upper(left(l.id::text, 8))), 'address', coalesce(u.address, p.street), 'unit_number', u.unit_number,
        'start_date', l.start_date, 'end_date', l.end_date, 'lease_type', l.lease_type, 'rent', l.rent, 'deposit_held', l.deposit_held,
        'balance', (select coalesce(sum(amount), 0) from lease_ledger_entries where lease_id = l.id),
        'tenants', (select jsonb_agg(t.name order by t.name) from lease_tenants x join tenants t on t.id = x.tenant_id where x.lease_id = l.id),
        'history', (select jsonb_agg(jsonb_build_object('date', e.entry_date, 'kind', e.kind, 'type', e.raw_type, 'memo', e.description, 'account', e.gl_account, 'amount', e.amount) order by e.entry_date, e.id)
                    from lease_ledger_entries e where e.lease_id = l.id),
        'files', (select jsonb_agg(jsonb_build_object('kind', f.kind, 'status', f.status, 'dated', f.dated, 'note', f.note) order by f.dated) from lease_files f where f.lease_id = l.id)))
      from leases l join rental_units u on u.id = l.unit_id join rental_properties p on p.id = u.property_id
      where l.status in ('active', 'future') and exists (select 1 from lease_tenants x where x.lease_id = l.id and x.tenant_id = any(v_ids))), '[]'::jsonb),
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
revoke all on function resident_home() from public, anon;
grant execute on function resident_home() to authenticated;

-- Tenants whose lease starts in the future can report their move-in payment.
create or replace function resident_report_payment(p_method text, p_amount numeric, p_paid_on date, p_code text, p_payer text, p_screenshot text, p_note text)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare v_ids uuid[] := array(select resident_me()); v_lease uuid; v_lc uuid; r payment_reports; v_matched int;
begin
  if cardinality(v_ids) = 0 then raise exception 'Resident two-step sign-in required' using errcode = '42501'; end if;
  if p_amount is null or p_amount <= 0 or p_amount > 20000 then raise exception 'Enter the amount you paid.'; end if;
  if p_paid_on is null or p_paid_on > current_date + 1 or p_paid_on < current_date - 60 then raise exception 'Enter the date you paid (within the last 60 days).'; end if;
  if p_screenshot is not null and split_part(p_screenshot, '/', 1)::uuid <> all(v_ids) then raise exception 'Bad file path'; end if;
  select l.id into v_lease from leases l where l.status in ('active', 'future') and exists (select 1 from lease_tenants x where x.lease_id = l.id and x.tenant_id = any(v_ids)) order by l.start_date desc limit 1;
  if v_lease is null then
    select c.id into v_lc from land_contracts c where c.status = 'active' and exists (select 1 from land_contract_buyers b where b.contract_id = c.id and b.tenant_id = any(v_ids)) limit 1;
  end if;
  insert into payment_reports (tenant_id, lease_id, land_contract_id, method, amount, paid_on, confirmation_code, payer_name, screenshot_path, note)
  values (v_ids[1], v_lease, v_lc, case when p_method in ('zelle', 'cashapp', 'paypal', 'bank_transfer', 'money_order', 'check', 'cash', 'other') then p_method else 'other' end,
          round(p_amount, 2), p_paid_on, nullif(trim(coalesce(p_code, '')), ''), nullif(trim(coalesce(p_payer, '')), ''), p_screenshot, left(nullif(trim(coalesce(p_note, '')), ''), 500))
  returning * into r;
  v_matched := payments_auto_match();   -- the bank record may already be in
  return jsonb_build_object('id', r.id, 'status', (select status from payment_reports where id = r.id));
end;
$$;
