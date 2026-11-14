-- Housing assistance: the rent split between the tenant and an agency (Stephen, 10/7/2026).
-- Many 2nd Chance tenants use a voucher or another program that pays part of the rent. The lease rent stays the
-- full rent; the agency's share is a receivable from the agency, not a debt of the tenant.
--
-- How it posts:
--   * Every rent charge on an assisted lease (billing on the 1st, the first month at move-in) gets, automatically,
--     a matching NEGATIVE line on the tenant's ledger (kind 'assistance', "Housing assistance — <agency> portion")
--     and a 'due' line on assistance_ledger (what the agency owes). A prorated rent charge gets a prorated share.
--   * So every existing balance, late fee, Pay-or-Vacate notice, autopay amount and receipt (all of them add up
--     lease_ledger_entries) already uses ONLY the tenant's portion. Nothing else had to change for that.
--   * Agency (HAP) payments post to assistance_ledger, never to the tenant's ledger.
--   * If the agency doesn't pay, the tenant is NOT charged automatically. Staff may move an amount to the tenant,
--     with a reason, which posts a tenant charge and an assistance adjustment.
--   * Turning on a Section 8 (HCV) or public-housing record marks the lease as a federally covered tenancy
--     (leases.federal_program) if it isn't already, so notices use the 30-day rules.

create table if not exists housing_assistance (
  id uuid primary key default gen_random_uuid(),
  lease_id uuid not null references leases(id),
  program text not null check (program in ('hcv', 'public_housing', 'state_local', 'nonprofit', 'other')),
  agency_name text not null,
  agency_contact_name text,
  agency_contact_email text,
  agency_contact_phone text,
  case_number text,                       -- voucher / HAP contract / case number
  agency_portion numeric(12,2) not null check (agency_portion > 0),
  start_date date not null,
  end_date date,
  status text not null default 'active' check (status in ('draft', 'active', 'ended')),
  notes text,
  created_by text,
  created_at timestamptz not null default now(),
  updated_by text,
  updated_at timestamptz not null default now(),
  check (end_date is null or end_date >= start_date)
);
create index if not exists housing_assistance_lease_idx on housing_assistance (lease_id, status);

create table if not exists assistance_ledger (
  id bigint generated always as identity primary key,
  assistance_id uuid not null references housing_assistance(id),
  lease_id uuid not null references leases(id),
  entry_date date not null,
  kind text not null check (kind in ('due', 'payment', 'adjustment', 'writeoff')),
  amount numeric(12,2) not null,          -- positive = the agency owes more; payments and write-offs are negative
  method text,
  reference text,                         -- check / EFT / HAP payment number
  description text,
  rent_entry_id bigint unique references lease_ledger_entries(id),   -- the rent charge a 'due' line came from (one per charge)
  lease_ledger_entry_id bigint references lease_ledger_entries(id),  -- the tenant-ledger line it pairs with, if any
  created_by text,
  created_at timestamptz not null default now()
);
create index if not exists assistance_ledger_idx on assistance_ledger (assistance_id, entry_date, id);

alter table housing_assistance enable row level security;
alter table assistance_ledger enable row level security;
-- No policies: everything goes through the functions below.

create or replace function assistance_program_label(p text)
returns text language sql immutable as $$
  select case p when 'hcv' then 'Section 8 Housing Choice Voucher' when 'public_housing' then 'Public housing / project-based'
    when 'state_local' then 'State or local rent assistance' when 'nonprofit' then 'Nonprofit / charity' else 'Other assistance' end;
$$;

-- The active assistance record covering a lease on a day.
create or replace function assistance_for(p_lease uuid, p_day date)
returns housing_assistance
language sql stable security definer set search_path = public as $$
  select a.* from housing_assistance a
  where a.lease_id = p_lease and a.status = 'active' and a.start_date <= p_day and (a.end_date is null or a.end_date >= p_day)
  order by a.start_date desc limit 1;
$$;
revoke all on function assistance_for(uuid, date) from public, anon, authenticated;

-- What the tenant themselves pays each month now: lease rent minus the active agency portion.
create or replace function lease_tenant_rent(p_lease uuid)
returns numeric
language sql stable security definer set search_path = public as $$
  select greatest(coalesce(l.rent, 0) - coalesce((assistance_for(l.id, current_date)).agency_portion, 0), 0)
  from leases l where l.id = p_lease;
$$;
revoke all on function lease_tenant_rent(uuid) from public, anon, authenticated;
grant execute on function lease_tenant_rent(uuid) to service_role;

-- Post the agency's share of one rent charge. Idempotent (one share per charge). Returns the share posted (0 if none).
create or replace function assistance_apply_to_charge(p_entry bigint, p_assistance uuid, p_by text)
returns numeric
language plpgsql volatile security definer set search_path = public as $$
declare e lease_ledger_entries; a housing_assistance; v_rent numeric; v_share numeric; v_credit bigint;
begin
  select * into e from lease_ledger_entries where id = p_entry;
  if e.id is null or e.kind <> 'charge' or e.gl_account not in ('Rent Income', 'Rent Charge') or e.amount <= 0 then return 0; end if;
  if exists (select 1 from assistance_ledger where rent_entry_id = p_entry) then return 0; end if;
  select * into a from housing_assistance where id = p_assistance;
  if a.id is null or a.lease_id <> e.lease_id then return 0; end if;
  select rent into v_rent from leases where id = e.lease_id;
  -- A full month's charge gets the full agency portion; a prorated charge gets the same fraction of it.
  v_share := case when coalesce(v_rent, 0) > 0 then round(a.agency_portion * least(e.amount / v_rent, 1), 2) else a.agency_portion end;
  v_share := least(v_share, e.amount);
  if v_share <= 0 then return 0; end if;
  insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, description, amount, source, correction_note)
  values (e.lease_id, e.gl_account, e.entry_date, 'assistance', 'Housing assistance', 'Housing assistance — ' || a.agency_name || ' portion', -v_share, 'assistance',
          'Paid by ' || a.agency_name || ' (' || assistance_program_label(a.program) || '), not by the tenant. Owed by the agency on the assistance ledger.')
  returning id into v_credit;
  insert into assistance_ledger (assistance_id, lease_id, entry_date, kind, amount, description, rent_entry_id, lease_ledger_entry_id, created_by)
  values (a.id, e.lease_id, e.entry_date, 'due', v_share, coalesce(e.description, 'Rent') || ' — agency portion', e.id, v_credit, coalesce(p_by, 'system'));
  return v_share;
end;
$$;
revoke all on function assistance_apply_to_charge(bigint, uuid, text) from public, anon, authenticated;

-- Automatic: rent charged by billing (the 1st) or at move-in (first month). Staff-entered or earlier charges are
-- covered by "Post for a month" on the staff page, so older history is never touched by itself.
create or replace function assistance_on_rent_charge()
returns trigger
language plpgsql security definer set search_path = public as $$
declare a housing_assistance;
begin
  a := assistance_for(new.lease_id, new.entry_date);
  if a.id is not null then perform assistance_apply_to_charge(new.id, a.id, 'system'); end if;
  return null;
end;
$$;
drop trigger if exists assistance_on_rent_charge on lease_ledger_entries;
create trigger assistance_on_rent_charge after insert on lease_ledger_entries
  for each row when (new.kind = 'charge' and new.gl_account in ('Rent Income', 'Rent Charge') and new.source in ('billing', 'move_in') and new.amount > 0)
  execute function assistance_on_rent_charge();

create or replace function assistance_row(a housing_assistance)
returns jsonb
language sql stable security definer set search_path = public as $$
  select to_jsonb(a) || jsonb_build_object(
    'program_label', assistance_program_label(a.program),
    'unit', (select ru.unit_number from leases l join rental_units ru on ru.id = l.unit_id where l.id = a.lease_id),
    'address', (select ru.address from leases l join rental_units ru on ru.id = l.unit_id where l.id = a.lease_id),
    'tenants', (select tenants_label from leases where id = a.lease_id),
    'lease_status', (select status from leases where id = a.lease_id),
    'rent', (select rent from leases where id = a.lease_id),
    'tenant_portion', greatest((select coalesce(rent, 0) from leases where id = a.lease_id) - a.agency_portion, 0),
    'tenant_balance', (select coalesce(sum(amount), 0) from lease_ledger_entries where lease_id = a.lease_id),
    'agency_balance', (select coalesce(sum(amount), 0) from assistance_ledger where assistance_id = a.id),
    'last_payment', (select jsonb_build_object('date', x.entry_date, 'amount', -x.amount, 'reference', x.reference) from assistance_ledger x
                     where x.assistance_id = a.id and x.kind = 'payment' order by x.entry_date desc, x.id desc limit 1),
    'ledger', coalesce((select jsonb_agg(to_jsonb(x) order by x.entry_date, x.id) from assistance_ledger x where x.assistance_id = a.id), '[]'::jsonb),
    'unposted_months', coalesce((select jsonb_agg(distinct to_char(date_trunc('month', e.entry_date), 'YYYY-MM-DD'))
      from lease_ledger_entries e where e.lease_id = a.lease_id and e.kind = 'charge' and e.gl_account in ('Rent Income', 'Rent Charge') and e.amount > 0
       and e.entry_date >= a.start_date and (a.end_date is null or e.entry_date <= a.end_date)
       and not exists (select 1 from assistance_ledger x where x.rent_entry_id = e.id)), '[]'::jsonb));
$$;
revoke all on function assistance_row(housing_assistance) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Staff
create or replace function assistance_staff_list()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'records', coalesce((select jsonb_agg(assistance_row(a) order by a.status = 'ended', a.agency_name, a.start_date desc) from housing_assistance a), '[]'::jsonb),
    'agencies', coalesce((select jsonb_agg(jsonb_build_object('agency', g.agency_name, 'leases', g.n, 'monthly', g.monthly, 'owed', g.owed) order by g.agency_name)
       from (select a.agency_name, count(*) filter (where a.status = 'active') n, coalesce(sum(a.agency_portion) filter (where a.status = 'active'), 0) monthly,
                    coalesce((select sum(x.amount) from assistance_ledger x join housing_assistance b on b.id = x.assistance_id where b.agency_name = a.agency_name), 0) owed
             from housing_assistance a group by a.agency_name) g), '[]'::jsonb),
    'leases', coalesce((select jsonb_agg(jsonb_build_object('id', l.id, 'unit', ru.unit_number, 'address', ru.address, 'tenants', l.tenants_label, 'rent', l.rent,
         'status', l.status, 'federal_program', l.federal_program, 'federal_program_note', l.federal_program_note,
         'has_record', exists (select 1 from housing_assistance a where a.lease_id = l.id and a.status <> 'ended'))
       order by nullif(regexp_replace(coalesce(ru.unit_number, ''), '\D', '', 'g'), '')::int nulls last, ru.unit_number)
       from leases l join rental_units ru on ru.id = l.unit_id where l.status in ('active', 'future')), '[]'::jsonb));
end;
$$;
revoke all on function assistance_staff_list() from public, anon;
grant execute on function assistance_staff_list() to authenticated;

-- Add (p_id null) or edit a record. p: {lease_id, program, agency_name, agency_contact_name, agency_contact_email,
-- agency_contact_phone, case_number, agency_portion, start_date, end_date, status, notes}
create or replace function assistance_staff_save(p_id uuid, p jsonb)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare a housing_assistance; l leases; v_portion numeric := nullif(p->>'agency_portion', '')::numeric;
  v_start date := nullif(p->>'start_date', '')::date; v_end date := nullif(p->>'end_date', '')::date;
  v_status text := coalesce(nullif(p->>'status', ''), 'active'); v_lease uuid := nullif(p->>'lease_id', '')::uuid; v_fed text;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if p_id is not null then
    select * into a from housing_assistance where id = p_id for update;
    if a.id is null then raise exception 'Assistance record not found'; end if;
    v_lease := a.lease_id;   -- a record never moves to another lease
  end if;
  select * into l from leases where id = v_lease;
  if l.id is null then raise exception 'Choose the lease.'; end if;
  if coalesce(p->>'program', '') not in ('hcv', 'public_housing', 'state_local', 'nonprofit', 'other') then raise exception 'Choose the program.'; end if;
  if length(coalesce(trim(p->>'agency_name'), '')) < 2 then raise exception 'Enter the agency''s name (e.g. HACM, Milwaukee County Housing).'; end if;
  if v_portion is null or v_portion <= 0 then raise exception 'Enter the agency''s monthly portion.'; end if;
  if coalesce(l.rent, 0) > 0 and v_portion > l.rent then raise exception 'The agency portion (%) can''t be more than the lease rent (%).', v_portion, l.rent; end if;
  if v_start is null then raise exception 'Enter the date the assistance starts (the HAP contract effective date).'; end if;
  if v_end is not null and v_end < v_start then raise exception 'The end date is before the start date.'; end if;
  if v_status not in ('draft', 'active', 'ended') then raise exception 'Bad status'; end if;
  if v_status = 'active' and exists (select 1 from housing_assistance b where b.lease_id = v_lease and b.status = 'active' and b.id is distinct from p_id
       and daterange(b.start_date, b.end_date, '[]') && daterange(v_start, v_end, '[]')) then
    raise exception 'This lease already has active assistance for those dates. End that one first (for a recertification, end the old record the day before the new portion starts).';
  end if;
  if p_id is null then
    insert into housing_assistance (lease_id, program, agency_name, agency_contact_name, agency_contact_email, agency_contact_phone, case_number, agency_portion,
      start_date, end_date, status, notes, created_by, updated_by)
    values (v_lease, p->>'program', trim(p->>'agency_name'), nullif(trim(coalesce(p->>'agency_contact_name', '')), ''), lower(nullif(trim(coalesce(p->>'agency_contact_email', '')), '')),
      nullif(trim(coalesce(p->>'agency_contact_phone', '')), ''), nullif(trim(coalesce(p->>'case_number', '')), ''), round(v_portion, 2), v_start, v_end, v_status,
      nullif(trim(coalesce(p->>'notes', '')), ''), lower(auth.email()), lower(auth.email()))
    returning * into a;
  else
    update housing_assistance set program = p->>'program', agency_name = trim(p->>'agency_name'),
      agency_contact_name = nullif(trim(coalesce(p->>'agency_contact_name', '')), ''), agency_contact_email = lower(nullif(trim(coalesce(p->>'agency_contact_email', '')), '')),
      agency_contact_phone = nullif(trim(coalesce(p->>'agency_contact_phone', '')), ''), case_number = nullif(trim(coalesce(p->>'case_number', '')), ''),
      agency_portion = round(v_portion, 2), start_date = v_start, end_date = v_end, status = v_status, notes = nullif(trim(coalesce(p->>'notes', '')), ''),
      updated_by = lower(auth.email()), updated_at = now()
    where id = p_id returning * into a;
  end if;
  -- A voucher or public-housing tenancy is federally covered: 30-day notices (lease_notice_rules). Set it, never clear it.
  if a.status = 'active' and a.program in ('hcv', 'public_housing') and l.federal_program is null then
    v_fed := case when a.program = 'hcv' then 'section8' else 'other_federal' end;
    update leases set federal_program = v_fed,
      federal_program_note = coalesce(federal_program_note, a.agency_name || coalesce(' ' || a.case_number, '') || ' (set from housing assistance)') where id = l.id;
  end if;
  return assistance_row(a) || jsonb_build_object('federal_program_set', v_fed);
end;
$$;
revoke all on function assistance_staff_save(uuid, jsonb) from public, anon;
grant execute on function assistance_staff_save(uuid, jsonb) to authenticated;

create or replace function assistance_staff_end(p_id uuid, p_end date, p_note text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare a housing_assistance;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if p_end is null then raise exception 'Enter the last day the agency pays.'; end if;
  update housing_assistance set status = 'ended', end_date = greatest(p_end, start_date), updated_by = lower(auth.email()), updated_at = now(),
    notes = concat_ws(E'\n', notes, nullif('Ended ' || to_char(p_end, 'FMMM/FMDD/YYYY') || coalesce(': ' || nullif(trim(coalesce(p_note, '')), ''), ''), ''))
  where id = p_id and status <> 'ended' returning * into a;
  if a.id is null then raise exception 'Record not found or already ended.'; end if;
  return assistance_row(a);
end;
$$;
revoke all on function assistance_staff_end(uuid, date, text) from public, anon;
grant execute on function assistance_staff_end(uuid, date, text) to authenticated;

-- Post the agency share for rent charges already on the ledger in one month (e.g. charged before the record existed).
create or replace function assistance_staff_post_month(p_id uuid, p_month date)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare a housing_assistance; e record; v_total numeric := 0; v_n int := 0; v numeric; m date := date_trunc('month', p_month)::date;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into a from housing_assistance where id = p_id;
  if a.id is null then raise exception 'Record not found'; end if;
  if a.status = 'draft' then raise exception 'Make the record active first.'; end if;
  for e in select id from lease_ledger_entries where lease_id = a.lease_id and kind = 'charge' and gl_account in ('Rent Income', 'Rent Charge') and amount > 0
             and date_trunc('month', entry_date) = m and entry_date >= a.start_date and (a.end_date is null or entry_date <= a.end_date) order by entry_date, id loop
    v := assistance_apply_to_charge(e.id, a.id, lower(auth.email()));
    if v > 0 then v_total := v_total + v; v_n := v_n + 1; end if;
  end loop;
  if v_n = 0 then raise exception 'No rent charge in % is waiting for the agency share (or it was already posted).', to_char(m, 'FMMonth YYYY'); end if;
  return jsonb_build_object('charges', v_n, 'posted', v_total);
end;
$$;
revoke all on function assistance_staff_post_month(uuid, date) from public, anon;
grant execute on function assistance_staff_post_month(uuid, date) to authenticated;

-- An agency payment (one HAP check can cover several tenants): p_items [{assistance_id, amount}].
create or replace function assistance_staff_payment(p_items jsonb, p_date date, p_method text, p_ref text, p_note text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare it jsonb; a housing_assistance; v_amt numeric; v_total numeric := 0; v_n int := 0;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if p_date is null then raise exception 'Enter the date the payment was received.'; end if;
  if coalesce(p_method, '') not in ('check', 'eft', 'ach', 'other') then raise exception 'Choose how the agency paid.'; end if;
  for it in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    v_amt := nullif(it->>'amount', '')::numeric;
    continue when v_amt is null or v_amt = 0;
    if v_amt < 0 or v_amt > 20000 then raise exception 'Each amount must be between $0 and $20,000.'; end if;
    select * into a from housing_assistance where id = (it->>'assistance_id')::uuid;
    if a.id is null then raise exception 'Assistance record not found'; end if;
    insert into assistance_ledger (assistance_id, lease_id, entry_date, kind, amount, method, reference, description, created_by)
    values (a.id, a.lease_id, p_date, 'payment', -round(v_amt, 2), p_method, nullif(trim(coalesce(p_ref, '')), ''),
            'Payment from ' || a.agency_name || coalesce(' — ' || nullif(trim(coalesce(p_note, '')), ''), ''), lower(auth.email()));
    v_total := v_total + round(v_amt, 2); v_n := v_n + 1;
  end loop;
  if v_n = 0 then raise exception 'Enter at least one amount.'; end if;
  return jsonb_build_object('lines', v_n, 'total', v_total);
end;
$$;
revoke all on function assistance_staff_payment(jsonb, date, text, text, text) from public, anon;
grant execute on function assistance_staff_payment(jsonb, date, text, text, text) to authenticated;

-- Adjust what the agency owes: 'writeoff' (the agency will never pay it and we absorb it) or 'adjustment'
-- (a correction either way). Neither touches the tenant.
create or replace function assistance_staff_adjust(p_id uuid, p_kind text, p_amount numeric, p_reason text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare a housing_assistance;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if p_kind not in ('adjustment', 'writeoff') then raise exception 'Bad kind'; end if;
  if p_amount is null or p_amount = 0 or abs(p_amount) > 20000 then raise exception 'Enter the amount.'; end if;
  if p_kind = 'writeoff' and p_amount < 0 then raise exception 'Enter a write-off as a positive amount.'; end if;
  if length(coalesce(trim(p_reason), '')) < 5 then raise exception 'Say why (it stays on the record).'; end if;
  select * into a from housing_assistance where id = p_id;
  if a.id is null then raise exception 'Record not found'; end if;
  insert into assistance_ledger (assistance_id, lease_id, entry_date, kind, amount, description, created_by)
  values (a.id, a.lease_id, current_date, p_kind, case when p_kind = 'writeoff' then -round(p_amount, 2) else round(p_amount, 2) end,
          case when p_kind = 'writeoff' then 'Written off: ' else 'Adjustment: ' end || trim(p_reason), lower(auth.email()));
  return assistance_row(a);
end;
$$;
revoke all on function assistance_staff_adjust(uuid, text, numeric, text) from public, anon;
grant execute on function assistance_staff_adjust(uuid, text, numeric, text) to authenticated;

-- The agency won't pay an amount and the tenant owes it (e.g. the voucher ended, or the tenant's share changed
-- retroactively). Moves it from the agency to the tenant: a tenant charge + an assistance adjustment. Never automatic.
create or replace function assistance_staff_move_to_tenant(p_id uuid, p_amount numeric, p_reason text)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare a housing_assistance; v_owed numeric; v_entry bigint;
begin
  if not staff_session_staff() then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if length(coalesce(trim(p_reason), '')) < 10 then raise exception 'Say why the tenant owes this (the tenant sees it on their ledger).'; end if;
  select * into a from housing_assistance where id = p_id for update;
  if a.id is null then raise exception 'Record not found'; end if;
  select coalesce(sum(amount), 0) into v_owed from assistance_ledger where assistance_id = a.id;
  if p_amount is null or p_amount <= 0 then raise exception 'Enter the amount.'; end if;
  if round(p_amount, 2) > v_owed then raise exception 'The agency owes only % on this record.', v_owed; end if;
  insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, description, amount, source, correction_note)
  values (a.lease_id, 'Rent Income', current_date, 'charge', 'Charge', 'Rent — not paid by ' || a.agency_name || ': ' || left(trim(p_reason), 200), round(p_amount, 2), 'assistance',
          'Moved from the agency receivable to the tenant by ' || lower(auth.email()) || ' on ' || to_char(now() at time zone 'America/Chicago', 'FMMM/FMDD/YYYY') || '.')
  returning id into v_entry;
  insert into assistance_ledger (assistance_id, lease_id, entry_date, kind, amount, description, lease_ledger_entry_id, created_by)
  values (a.id, a.lease_id, current_date, 'adjustment', -round(p_amount, 2), 'Moved to the tenant: ' || trim(p_reason), v_entry, lower(auth.email()));
  return assistance_row(a);
end;
$$;
revoke all on function assistance_staff_move_to_tenant(uuid, numeric, text) from public, anon;
grant execute on function assistance_staff_move_to_tenant(uuid, numeric, text) to authenticated;

-- ---------------------------------------------------------------------------
-- Tenant: their own split. Agency name and phone only; no agency contact person, email or case number.
create or replace function assistance_mine()
returns jsonb
language plpgsql stable security definer set search_path = public as $$
begin
  if not exists (select 1 from resident_me()) then raise exception 'Sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object(
      'lease_id', a.lease_id, 'unit', ru.unit_number, 'address', ru.address, 'status', a.status,
      'program', assistance_program_label(a.program), 'agency', a.agency_name, 'agency_phone', a.agency_contact_phone,
      'rent', l.rent, 'agency_portion', a.agency_portion, 'your_portion', greatest(coalesce(l.rent, 0) - a.agency_portion, 0),
      'start_date', a.start_date, 'end_date', a.end_date) order by a.start_date desc)
    from housing_assistance a join leases l on l.id = a.lease_id join rental_units ru on ru.id = l.unit_id
    where a.status <> 'draft' and l.status in ('active', 'future', 'past')
      and (a.status = 'active' or a.end_date > current_date - 365)
      and exists (select 1 from lease_tenants lt where lt.lease_id = a.lease_id and lt.tenant_id in (select resident_me()))), '[]'::jsonb);
end;
$$;
revoke all on function assistance_mine() from public, anon;
grant execute on function assistance_mine() to authenticated;
