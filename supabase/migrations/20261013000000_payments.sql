-- Payments: free, push-based payments (Zelle and other apps, bank transfer)
-- reported by the tenant and VERIFIED from the landlord's side.
--
--   payment_reports  the tenant's claim ("I paid $900 by Zelle on 10/1"),
--                    optional screenshot; pending until verified.
--   bank_receipts    what the landlord's side shows: rows from a Chase
--                    statement (CSV), parsed payment-alert emails (Chase Zelle,
--                    Cash App, PayPal), or Stripe. Deduplicated by fingerprint.
--   payments_auto_match()  pairs pending reports with receipts by amount,
--                    date (within 4 days) and payer name / account number in
--                    the memo, then posts the verified payment to the ledger.
-- Nothing a tenant uploads is trusted as proof; only receipts or staff verify.

create table if not exists payment_reports (
  id uuid primary key default gen_random_uuid(),
  tenant_id uuid not null references tenants(id),
  lease_id uuid references leases(id),
  land_contract_id uuid references land_contracts(id),
  method text not null check (method in ('zelle', 'cashapp', 'paypal', 'bank_transfer', 'money_order', 'check', 'cash', 'other')),
  amount numeric(12,2) not null check (amount > 0),
  paid_on date not null,
  confirmation_code text,
  payer_name text,
  screenshot_path text,
  note text,
  status text not null default 'pending' check (status in ('pending', 'verified', 'rejected')),
  verified_by text,
  verified_at timestamptz,
  verification_source text check (verification_source in ('bank_csv', 'email_alert', 'stripe', 'staff')),
  bank_receipt_id uuid,
  ledger_entry_id bigint,
  reject_reason text,
  created_at timestamptz not null default now()
);

create table if not exists bank_receipts (
  id uuid primary key default gen_random_uuid(),
  source text not null check (source in ('chase_csv', 'email_alert', 'stripe', 'manual')),
  account text,
  posted_on date not null,
  amount numeric(12,2) not null,
  description text,
  payer_name text,
  reference text,
  fingerprint text not null unique,
  raw jsonb,
  matched_report_id uuid references payment_reports(id),
  assigned_lease_id uuid references leases(id),
  ignored boolean not null default false,
  created_at timestamptz not null default now()
);
alter table payment_reports add constraint payment_reports_receipt_fk foreign key (bank_receipt_id) references bank_receipts(id) not valid;
alter table payment_reports enable row level security;
alter table bank_receipts enable row level security;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('payment-proofs', 'payment-proofs', false, 10485760, array['image/jpeg', 'image/png', 'image/webp', 'image/heic', 'application/pdf'])
on conflict (id) do update set public = false;
drop policy if exists "payment-proofs resident upload" on storage.objects;
create policy "payment-proofs resident upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'payment-proofs' and (storage.foldername(name))[1]::uuid in (select resident_me()));
drop policy if exists "payment-proofs read" on storage.objects;
create policy "payment-proofs read" on storage.objects for select to authenticated
  using (bucket_id = 'payment-proofs' and ((storage.foldername(name))[1]::uuid in (select resident_me()) or (condo_session_ok() and condo_is_staff())));

-- Where tenants send money (shown only to signed-in residents).
insert into portal_settings (key, value) values
  ('pay_zelle_to', ''), ('pay_zelle_name', '2nd Chance Housing Inc.'), ('pay_cashapp_tag', ''), ('pay_paypal_link', ''),
  ('pay_instructions', 'Put your account number in the memo so we can match your payment.')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- Verify = post to the ledger once, link everything.
-- ---------------------------------------------------------------------------
create or replace function payment_post(p_report uuid, p_receipt uuid, p_source text, p_by text)
returns void
language plpgsql volatile security definer set search_path = public
as $$
declare r payment_reports; v_entry bigint; v_label text;
begin
  select * into r from payment_reports where id = p_report for update;
  if r.id is null or r.status <> 'pending' then return; end if;
  v_label := initcap(replace(r.method, '_', ' ')) || ' payment';
  if r.lease_id is not null then
    insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, method, check_number, description, amount, source, correction_note)
    values (r.lease_id, 'Rent Income', r.paid_on, 'payment', v_label || ' (verified)', r.method, r.confirmation_code,
            'Payment by ' || coalesce(r.payer_name, (select name from tenants where id = r.tenant_id)), -r.amount, 'payment_report',
            'Verified via ' || p_source || coalesce(' by ' || p_by, '') || ' on ' || to_char(now(), 'YYYY-MM-DD'))
    returning id into v_entry;
  elsif r.land_contract_id is not null then
    insert into land_contract_ledger (contract_id, entry_date, kind, raw_type, description, amount, source, correction_note)
    values (r.land_contract_id, r.paid_on, 'payment', v_label || ' (verified)', 'Payment by ' || coalesce(r.payer_name, ''), -r.amount, 'payment_report',
            'Verified via ' || p_source);
  end if;
  update payment_reports set status = 'verified', verified_at = now(), verified_by = p_by, verification_source = p_source,
         bank_receipt_id = p_receipt, ledger_entry_id = v_entry where id = r.id;
  if p_receipt is not null then update bank_receipts set matched_report_id = r.id where id = p_receipt; end if;
end;
$$;
revoke all on function payment_post(uuid, uuid, text, text) from public, anon, authenticated;

-- Pair pending reports with unmatched receipts. A receipt matches a report
-- when the amount is equal, the dates are within 4 days, and the payer name
-- shares a word with the tenant's name, or the memo carries the account
-- number or the confirmation code. Exactly one candidate on each side, or no
-- auto-match (left for staff).
create or replace function payments_auto_match()
returns int
language plpgsql volatile security definer set search_path = public
as $$
declare rec record; n int := 0;
begin
  for rec in
    with cand as (
      select b.id as receipt_id, r.id as report_id, b.source
      from bank_receipts b
      join payment_reports r on r.status = 'pending' and r.amount = b.amount and abs(b.posted_on - r.paid_on) <= 4
      join tenants t on t.id = r.tenant_id
      left join leases l on l.id = r.lease_id
      where b.matched_report_id is null and not b.ignored and b.amount > 0
        and (
          exists (select 1 from regexp_split_to_table(lower(t.name), '\s+') w where length(w) >= 3 and lower(coalesce(b.payer_name, '') || ' ' || coalesce(b.description, '')) like '%' || w || '%')
          or (l.legacy_lease_number is not null and coalesce(b.description, '') || coalesce(b.reference, '') like '%' || l.legacy_lease_number || '%')
          or (r.confirmation_code is not null and length(r.confirmation_code) >= 5 and coalesce(b.description, '') || coalesce(b.reference, '') ilike '%' || r.confirmation_code || '%')
          or (r.payer_name is not null and length(r.payer_name) >= 3 and lower(coalesce(b.payer_name, '') || ' ' || coalesce(b.description, '')) like '%' || lower(r.payer_name) || '%')
        )
    )
    select c.* from cand c
    where (select count(*) from cand x where x.receipt_id = c.receipt_id) = 1
      and (select count(*) from cand x where x.report_id = c.report_id) = 1
  loop
    perform payment_post(rec.report_id, rec.receipt_id, case rec.source when 'chase_csv' then 'bank_csv' when 'email_alert' then 'email_alert' when 'stripe' then 'stripe' else 'staff' end, 'system');
    n := n + 1;
  end loop;
  return n;
end;
$$;
revoke all on function payments_auto_match() from public, anon, authenticated;
grant execute on function payments_auto_match() to service_role;

-- ---------------------------------------------------------------------------
-- Resident
-- ---------------------------------------------------------------------------
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
  select l.id into v_lease from leases l where l.status = 'active' and exists (select 1 from lease_tenants x where x.lease_id = l.id and x.tenant_id = any(v_ids)) order by l.start_date desc limit 1;
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
revoke all on function resident_report_payment(text, numeric, date, text, text, text, text) from public, anon;
grant execute on function resident_report_payment(text, numeric, date, text, text, text, text) to authenticated;

create or replace function resident_payment_reports()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not exists (select resident_me()) then raise exception 'Resident two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', id, 'method', method, 'amount', amount, 'paid_on', paid_on, 'status', status,
      'confirmation_code', confirmation_code, 'reject_reason', reject_reason, 'created_at', created_at) order by created_at desc)
    from payment_reports where tenant_id in (select resident_me())), '[]'::jsonb);
end;
$$;
revoke all on function resident_payment_reports() from public, anon;
grant execute on function resident_payment_reports() to authenticated;

-- ---------------------------------------------------------------------------
-- Staff
-- ---------------------------------------------------------------------------
create or replace function payments_staff_import(p_source text, p_rows jsonb)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare x jsonb; v_new int := 0; v_matched int;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if p_source not in ('chase_csv', 'manual') then raise exception 'Unknown source'; end if;
  for x in select * from jsonb_array_elements(p_rows) loop
    if (x->>'amount')::numeric > 0 then   -- deposits only
      insert into bank_receipts (source, account, posted_on, amount, description, payer_name, reference, fingerprint, raw)
      values (p_source, x->>'account', (x->>'posted_on')::date, (x->>'amount')::numeric, x->>'description', x->>'payer_name', x->>'reference',
              p_source || '|' || (x->>'posted_on') || '|' || (x->>'amount') || '|' || coalesce(x->>'description', '') || '|' || coalesce(x->>'reference', ''), x)
      on conflict (fingerprint) do nothing;
      if found then v_new := v_new + 1; end if;
    end if;
  end loop;
  v_matched := payments_auto_match();
  return jsonb_build_object('new_receipts', v_new, 'matched', v_matched);
end;
$$;

create or replace function payments_staff_queue()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'reports', coalesce((select jsonb_agg(to_jsonb(r) || jsonb_build_object('tenant', t.name, 'account_number', l.legacy_lease_number,
        'unit', u.unit_number, 'receipt', (select to_jsonb(b) - 'raw' from bank_receipts b where b.id = r.bank_receipt_id)) order by r.created_at desc)
      from payment_reports r join tenants t on t.id = r.tenant_id left join leases l on l.id = r.lease_id left join rental_units u on u.id = l.unit_id
      where r.created_at > now() - interval '120 days'), '[]'::jsonb),
    'unmatched_receipts', coalesce((select jsonb_agg(to_jsonb(b) - 'raw' order by b.posted_on desc)
      from bank_receipts b where b.matched_report_id is null and b.assigned_lease_id is null and not b.ignored and b.posted_on > current_date - 120), '[]'::jsonb));
end;
$$;

create or replace function payments_staff_decide(p_report uuid, p_action text, p_receipt uuid, p_reason text)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if p_action = 'verify' then
    perform payment_post(p_report, p_receipt, case when p_receipt is null then 'staff' else 'bank_csv' end, auth.email());
  elsif p_action = 'reject' then
    update payment_reports set status = 'rejected', reject_reason = nullif(trim(coalesce(p_reason, '')), ''), verified_by = auth.email(), verified_at = now()
     where id = p_report and status = 'pending';
  else raise exception 'Unknown action'; end if;
  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function payments_staff_import(text, jsonb) from public, anon;
revoke all on function payments_staff_queue() from public, anon;
revoke all on function payments_staff_decide(uuid, text, uuid, text) from public, anon;
grant execute on function payments_staff_import(text, jsonb) to authenticated;
grant execute on function payments_staff_queue() to authenticated;
grant execute on function payments_staff_decide(uuid, text, uuid, text) to authenticated;
