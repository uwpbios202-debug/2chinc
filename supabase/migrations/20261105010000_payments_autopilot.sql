-- ===========================================================================
-- Payments autopilot (Stephen, 10/6/2026): money that lands in the bank posts itself.
--
-- Receipt-first: every deposit (Plaid bank feed, Chase CSV, alert email, Stripe) becomes a
-- bank_receipt. The system finds who it belongs to WITHOUT the tenant reporting it:
--   1. the account number (lease number / unit number / tax key) in the memo
--   2. a payer alias learned before ("Pat Smith always pays for lease 02906314")
--   3. the payer's name matching exactly one active tenant (or current owner)
-- and posts it to the right ledger, then the tenant or owner gets the usual
-- "payment received" email. Doubtful ones (two possible leases, an odd amount, a return,
-- a payer nobody knows) wait in a short staff queue; assigning one teaches an alias so the
-- next payment from that payer posts by itself.
--
-- Owners and tenants have SEPARATE bank accounts: each bank account is tagged tenant or
-- owner, and a deposit can only post to its own side (rent never lands on dues).
-- Nothing is deleted. Every automatic post says it was automatic and where it came from.
-- ===========================================================================

create table if not exists bank_accounts (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  kind text not null check (kind in ('tenant', 'owner')),
  institution text,
  mask text,
  plaid_item_id text unique,
  plaid_account_id text,
  access_token_enc text,          -- AES-GCM, key in the bank-feed function's secrets; never readable by the site
  cursor text,                    -- Plaid transactions/sync cursor
  last_synced_at timestamptz,
  last_error text,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
alter table bank_accounts enable row level security;

alter table bank_receipts drop constraint if exists bank_receipts_source_check;
alter table bank_receipts add constraint bank_receipts_source_check check (source in ('chase_csv', 'email_alert', 'stripe', 'manual', 'plaid'));
alter table bank_receipts add column if not exists bank_account_id uuid references bank_accounts(id);
alter table bank_receipts add column if not exists provider_id text;       -- e.g. the Plaid transaction id
alter table bank_receipts add column if not exists status text not null default 'new' check (status in ('new', 'posted', 'needs_review', 'ignored'));
alter table bank_receipts add column if not exists confidence text;         -- how it was matched
alter table bank_receipts add column if not exists review_reason text;
alter table bank_receipts add column if not exists posted_at timestamptz;
create unique index if not exists bank_receipts_provider_idx on bank_receipts (provider_id) where provider_id is not null;
create index if not exists bank_receipts_status_idx on bank_receipts (status, posted_on desc);

alter table payment_reports drop constraint if exists payment_reports_verification_source_check;
alter table payment_reports add constraint payment_reports_verification_source_check
  check (verification_source in ('bank_csv', 'email_alert', 'stripe', 'staff', 'bank_feed'));

create table if not exists payer_aliases (
  id bigint generated always as identity primary key,
  scope text not null check (scope in ('tenant', 'owner')),
  alias text not null,                                  -- payer_norm() of the name on the deposit
  lease_id uuid references leases(id),
  land_contract_id uuid references land_contracts(id),
  condo_account_id uuid references condo_ledger_accounts(id),
  created_by text,
  created_at timestamptz not null default now(),
  check (num_nonnulls(lease_id, land_contract_id, condo_account_id) = 1),
  unique (scope, alias)
);
alter table payer_aliases enable row level security;

-- ---------------------------------------------------------------------------
create or replace function payer_norm(p text)
returns text language sql immutable as $$
  select trim(regexp_replace(regexp_replace(lower(coalesce(p, '')),
    '\m(zelle|payment|from|ach|credit|deposit|online|transfer|via|paypal|cash app|cashapp|inst xfer|web id|ppd|cc|llc|inc|unit|apt|rent|dues|memo|ref)\M', ' ', 'g'),
    '[^a-z ]', ' ', 'g'));
$$;
create or replace function payer_tokens(p text)
returns text[] language sql immutable as $$
  select coalesce(array_agg(distinct w) filter (where length(w) >= 2), '{}') from regexp_split_to_table(payer_norm(p), '\s+') w;
$$;

create or replace function bank_receipt_method(p_text text)
returns text language sql immutable as $$
  select case when p_text ~* 'zelle' then 'zelle' when p_text ~* 'paypal|venmo' then 'paypal' when p_text ~* 'cash ?app|square' then 'cashapp'
              when p_text ~* 'check|chk|cheque' then 'check' when p_text ~* 'money order' then 'money_order' else 'bank_transfer' end;
$$;

-- ---------------------------------------------------------------------------
-- Who could this deposit belong to? One row per candidate, best first (rank 1 = strongest).
create or replace function bank_candidates(p_receipt uuid)
returns table (target_kind text, target_id uuid, label text, why text, rank int)
language plpgsql stable security definer set search_path = public
as $$
declare b bank_receipts; v_scope text; v_text text; v_tokens text[]; v_norm text;
begin
  select * into b from bank_receipts where id = p_receipt;
  if b.id is null then return; end if;
  v_scope := coalesce((select kind from bank_accounts where id = b.bank_account_id), 'tenant');
  v_text := coalesce(b.description, '') || ' ' || coalesce(b.reference, '') || ' ' || coalesce(b.payer_name, '');
  v_norm := payer_norm(coalesce(nullif(b.payer_name, ''), b.description));
  v_tokens := payer_tokens(coalesce(nullif(b.payer_name, ''), b.description));

  if v_scope = 'tenant' then
    return query
    with active as (
      select l.id, l.legacy_lease_number num, l.tenants_label, coalesce(ru.unit_number, '') unit, l.rent
      from leases l left join rental_units ru on ru.id = l.unit_id where l.status = 'active'),
    by_acct as (
      select a.id, 'lease'::text k, 1 r, 'account number ' || a.num || ' in the memo' w, a.tenants_label || ' (unit ' || a.unit || ')' lab
      from active a where a.num is not null and length(a.num) >= 5 and v_text ~ ('(^|[^0-9])0*' || ltrim(a.num, '0') || '([^0-9]|$)')),
    by_alias as (
      select al.lease_id id, 'lease'::text k, 2 r, 'known payer' w, a.tenants_label || ' (unit ' || a.unit || ')' lab
      from payer_aliases al join active a on a.id = al.lease_id where al.scope = 'tenant' and al.alias = v_norm and v_norm <> ''),
    by_name as (
      select a.id, 'lease'::text k, 3 r, 'payer name matches the tenant' w, a.tenants_label || ' (unit ' || a.unit || ')' lab
      from active a
      where cardinality(v_tokens) >= 2 and not exists (
        select 1 from unnest(v_tokens) t where not exists (select 1 from unnest(payer_tokens(a.tenants_label)) x where x = t))
      union
      select a.id, 'lease'::text, 3, 'payer name matches a tenant on the lease', a.tenants_label || ' (unit ' || a.unit || ')'
      from active a join lease_tenants lt on lt.lease_id = a.id join tenants t2 on t2.id = lt.tenant_id
      where cardinality(v_tokens) >= 2 and not exists (
        select 1 from unnest(v_tokens) t where not exists (select 1 from unnest(payer_tokens(t2.name)) x where x = t))),
    by_contract as (
      select c.id, 'land_contract'::text k, 3 r, 'payer name matches the buyer' w, c.buyers_label lab
      from land_contracts c where c.status = 'active' and cardinality(v_tokens) >= 2 and not exists (
        select 1 from unnest(v_tokens) t where not exists (select 1 from unnest(payer_tokens(c.buyers_label)) x where x = t))
      union
      select al.land_contract_id, 'land_contract', 2, 'known payer', c.buyers_label
      from payer_aliases al join land_contracts c on c.id = al.land_contract_id where al.scope = 'tenant' and al.alias = v_norm and v_norm <> '' and c.status = 'active')
    select d.k, d.id, d.lab, d.w, d.r from (
      select distinct on (x.k, x.id) x.k, x.id, x.lab, x.w, x.r from (
        select * from by_acct union all select * from by_alias union all select * from by_name union all select * from by_contract) x
      order by x.k, x.id, x.r) d
    order by d.r, d.lab;
  else
    return query
    with cur as (
      select a.id acct, u.unit_number, u.pin, o.name owner_name, o.id owner_id
      from condo_units u join condo_ownerships s on s.unit_id = u.id and s.is_current join condo_owners o on o.id = s.owner_id
      join condo_ledger_accounts a on a.unit_id = u.id and a.billing_account and not a.excluded),
    by_acct as (
      select c.acct id, 'condo'::text k, 1 r, case when c.pin is not null and v_text like '%' || c.pin || '%' then 'tax key ' || c.pin || ' in the memo' else 'unit ' || c.unit_number || ' in the memo' end w,
             'Unit ' || c.unit_number || ' (' || c.owner_name || ')' lab
      from cur c where (c.pin is not null and length(c.pin) >= 6 and v_text like '%' || c.pin || '%')
        or v_text ~* ('(unit|apt|#)\s*' || c.unit_number || '([^0-9]|$)')),
    by_alias as (
      select al.condo_account_id, 'condo'::text, 2, 'known payer', 'Unit ' || c.unit_number || ' (' || c.owner_name || ')'
      from payer_aliases al join cur c on c.acct = al.condo_account_id where al.scope = 'owner' and al.alias = v_norm and v_norm <> ''),
    by_name as (
      select c.acct, 'condo'::text, 3, 'payer name matches the owner', 'Unit ' || c.unit_number || ' (' || c.owner_name || ')'
      from cur c where cardinality(v_tokens) >= 2 and not exists (
        select 1 from unnest(v_tokens) t where not exists (select 1 from unnest(payer_tokens(c.owner_name)) x where x = t)))
    select d.k, d.id, d.lab, d.w, d.r from (
      select distinct on (x.k, x.id) x.k, x.id, x.lab, x.w, x.r from (
        select * from by_acct union all select * from by_alias union all select * from by_name) x
      order by x.k, x.id, x.r) d
    order by d.r, d.lab;
  end if;
end;
$$;
revoke all on function bank_candidates(uuid) from public, anon, authenticated;
grant execute on function bank_candidates(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- Post one receipt to one target (creates a verified payment report, reusing payment_post and its email).
create or replace function bank_post_receipt(p_receipt uuid, p_kind text, p_target uuid, p_how text, p_by text)
returns uuid
language plpgsql volatile security definer set search_path = public
as $$
declare b bank_receipts; v_report uuid; v_tenant uuid; v_owner uuid; v_method text; v_lease uuid; v_contract uuid; v_acct uuid;
begin
  select * into b from bank_receipts where id = p_receipt for update;
  if b.id is null or b.status = 'posted' then return null; end if;
  v_method := bank_receipt_method(coalesce(b.description, '') || ' ' || coalesce(b.payer_name, ''));
  if p_kind = 'lease' then
    v_lease := p_target;
    select lt.tenant_id into v_tenant from lease_tenants lt join tenants t on t.id = lt.tenant_id where lt.lease_id = v_lease
      order by (select count(*) from unnest(payer_tokens(b.payer_name)) w where lower(t.name) like '%' || w || '%') desc, t.created_at limit 1;
  elsif p_kind = 'land_contract' then
    v_contract := p_target;
    select bu.tenant_id into v_tenant from land_contract_buyers bu where bu.contract_id = v_contract order by bu.tenant_id limit 1;
  elsif p_kind = 'condo' then
    v_acct := p_target;
    select s.owner_id into v_owner from condo_ledger_accounts a join condo_ownerships s on s.unit_id = a.unit_id and s.is_current where a.id = v_acct limit 1;
  else raise exception 'Unknown target'; end if;
  if v_tenant is null and v_owner is null then raise exception 'No payer found for that target'; end if;
  insert into payment_reports (tenant_id, owner_id, lease_id, land_contract_id, condo_account_id, method, amount, paid_on, confirmation_code, payer_name, note, status)
  values (v_tenant, v_owner, v_lease, v_contract, v_acct, v_method, b.amount, b.posted_on, nullif(left(coalesce(b.reference, ''), 40), ''), nullif(b.payer_name, ''),
          'Posted automatically from the bank deposit (' || p_how || ')', 'pending')
  returning id into v_report;
  perform payment_post(v_report, p_receipt, 'bank_feed', p_by);
  update bank_receipts set status = 'posted', confidence = p_how, posted_at = now(), review_reason = null, matched_report_id = v_report where id = p_receipt;
  return v_report;
end;
$$;
revoke all on function bank_post_receipt(uuid, text, uuid, text, text) from public, anon, authenticated;
grant execute on function bank_post_receipt(uuid, text, uuid, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- The autopilot: run after every deposit import. Returns what it did.
create or replace function bank_autopilot()
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare r record; c record; n_top int; v_posted int := 0; v_review int := 0; v_ignored int := 0; v_matched int; v_reason text; v_bal numeric; v_cap numeric; v_scope text;
begin
  v_matched := payments_auto_match();      -- tenant-reported payments still pair first
  for r in select * from bank_receipts where status in ('new', 'needs_review') and matched_report_id is null and not ignored order by posted_on, created_at loop
    v_scope := coalesce((select kind from bank_accounts where id = r.bank_account_id), 'tenant');
    if r.amount <= 0 then
      if coalesce(r.description, '') ~* 'return|reversal|chargeback|dispute|nsf|unauthorized' then
        update bank_receipts set status = 'needs_review', review_reason = 'A returned or reversed payment: check the ledger', confidence = null where id = r.id;
        v_review := v_review + 1;
      else
        update bank_receipts set status = 'ignored', review_reason = 'Money out' where id = r.id; v_ignored := v_ignored + 1;
      end if;
      continue;
    end if;
    select count(*) into n_top from bank_candidates(r.id) x where x.rank = (select min(y.rank) from bank_candidates(r.id) y);
    select * into c from bank_candidates(r.id) order by rank limit 1;
    v_reason := null;
    if c.target_id is null then
      v_reason := 'Nobody matches this payer yet';
    elsif n_top > 1 then
      v_reason := 'More than one possible match (' || n_top || ')';
    else
      -- sanity: not more than the balance plus three months of rent or dues
      if c.target_kind = 'lease' then
        v_bal := coalesce((select sum(amount) from lease_ledger_entries where lease_id = c.target_id), 0);
        v_cap := greatest(v_bal, 0) + 3 * coalesce((select rent from leases where id = c.target_id), 0);
      elsif c.target_kind = 'condo' then
        v_bal := coalesce((select sum(e.amount) from condo_ledger_entries e join condo_ledger_accounts a2 on a2.id = e.account_id
                           where a2.ownership_id = (select ownership_id from condo_ledger_accounts where id = c.target_id) and not a2.excluded), 0);
        v_cap := greatest(v_bal, 0) + 3 * coalesce(nullif(condo_setting('dues_default', '215'), '')::numeric, 215);
      else
        v_cap := 1e9;
      end if;
      if r.amount > v_cap then v_reason := 'Amount is more than the balance plus three months'; end if;
    end if;
    if v_reason is null then
      begin
        perform bank_post_receipt(r.id, c.target_kind, c.target_id,
          case c.rank when 1 then 'account number in memo' when 2 then 'known payer' else 'payer name' end, 'autopilot');
        v_posted := v_posted + 1;
      exception when others then
        update bank_receipts set status = 'needs_review', review_reason = left('Could not post: ' || sqlerrm, 200) where id = r.id; v_review := v_review + 1;
      end;
    else
      update bank_receipts set status = 'needs_review', review_reason = v_reason, confidence = null where id = r.id;
      v_review := v_review + 1;
    end if;
  end loop;
  return jsonb_build_object('paired_with_reports', v_matched, 'posted', v_posted, 'needs_review', v_review, 'ignored', v_ignored);
end;
$$;
revoke all on function bank_autopilot() from public, anon, authenticated;
grant execute on function bank_autopilot() to service_role;

-- Importing deposits (Chase CSV, email alerts, the feed) always ends with the autopilot.
create or replace function payments_staff_import(p_source text, p_rows jsonb)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare x jsonb; v_new int := 0; v_res jsonb;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if p_source not in ('chase_csv', 'manual') then raise exception 'Unknown source'; end if;
  for x in select * from jsonb_array_elements(p_rows) loop
    insert into bank_receipts (source, account, posted_on, amount, description, payer_name, reference, fingerprint, raw, bank_account_id)
    values (p_source, x->>'account', (x->>'posted_on')::date, (x->>'amount')::numeric, x->>'description', x->>'payer_name', x->>'reference',
            p_source || '|' || (x->>'posted_on') || '|' || (x->>'amount') || '|' || coalesce(x->>'description', '') || '|' || coalesce(x->>'reference', ''), x,
            nullif(x->>'bank_account_id', '')::uuid)
    on conflict (fingerprint) do nothing;
    if found then v_new := v_new + 1; end if;
  end loop;
  v_res := bank_autopilot();
  return jsonb_build_object('new_receipts', v_new) || v_res;
end;
$$;

-- ---------------------------------------------------------------------------
-- Staff: a short queue for what the autopilot could not decide, plus what it posted.
create or replace function bank_staff_overview()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'accounts', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'name', a.name, 'kind', a.kind, 'institution', a.institution, 'mask', a.mask,
        'connected', a.plaid_item_id is not null, 'last_synced_at', a.last_synced_at, 'last_error', a.last_error, 'active', a.active) order by a.kind, a.name) from bank_accounts a), '[]'::jsonb),
    'queue', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'posted_on', b.posted_on, 'amount', b.amount, 'payer', b.payer_name, 'description', b.description,
        'reason', b.review_reason, 'kind', coalesce((select kind from bank_accounts where id = b.bank_account_id), 'tenant'),
        'candidates', coalesce((select jsonb_agg(jsonb_build_object('kind', c.target_kind, 'id', c.target_id, 'label', c.label, 'why', c.why) order by c.rank, c.label)
                                from (select * from bank_candidates(b.id) order by rank limit 5) c), '[]'::jsonb)) order by b.posted_on desc)
      from bank_receipts b where b.status = 'needs_review'), '[]'::jsonb),
    'recent', coalesce((select jsonb_agg(jsonb_build_object('id', b.id, 'posted_on', b.posted_on, 'amount', b.amount, 'payer', b.payer_name, 'how', b.confidence, 'posted_at', b.posted_at,
        'source', b.source) order by b.posted_at desc) from (select * from bank_receipts where status = 'posted' order by posted_at desc limit 30) b), '[]'::jsonb));
end;
$$;
revoke all on function bank_staff_overview() from public, anon;
grant execute on function bank_staff_overview() to authenticated;

create or replace function bank_staff_assign(p_receipt uuid, p_kind text, p_target uuid, p_remember boolean)
returns void
language plpgsql volatile security definer set search_path = public
as $$
declare b bank_receipts; v_scope text; v_norm text;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into b from bank_receipts where id = p_receipt;
  if b.id is null then raise exception 'Deposit not found'; end if;
  v_scope := coalesce((select kind from bank_accounts where id = b.bank_account_id), 'tenant');
  if (v_scope = 'owner') <> (p_kind = 'condo') then raise exception 'That deposit is in the % bank account; it can only post to the % side', v_scope, case v_scope when 'owner' then 'owner dues' else 'tenant rent' end; end if;
  perform bank_post_receipt(p_receipt, p_kind, p_target, 'assigned by staff', auth.email());
  v_norm := payer_norm(coalesce(nullif(b.payer_name, ''), b.description));
  if p_remember and v_norm <> '' then
    insert into payer_aliases (scope, alias, lease_id, land_contract_id, condo_account_id, created_by)
    values (v_scope, v_norm, case when p_kind = 'lease' then p_target end, case when p_kind = 'land_contract' then p_target end, case when p_kind = 'condo' then p_target end, auth.email())
    on conflict (scope, alias) do update set lease_id = excluded.lease_id, land_contract_id = excluded.land_contract_id, condo_account_id = excluded.condo_account_id, created_by = excluded.created_by;
  end if;
  perform bank_autopilot();    -- other waiting deposits from this payer can post now
end;
$$;
revoke all on function bank_staff_assign(uuid, text, uuid, boolean) from public, anon;
grant execute on function bank_staff_assign(uuid, text, uuid, boolean) to authenticated;

create or replace function bank_staff_ignore(p_receipt uuid, p_reason text)
returns void
language plpgsql volatile security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  update bank_receipts set status = 'ignored', ignored = true, review_reason = coalesce(nullif(trim(p_reason), ''), 'Not a rent or dues payment') where id = p_receipt and status <> 'posted';
end;
$$;
revoke all on function bank_staff_ignore(uuid, text) from public, anon;
grant execute on function bank_staff_ignore(uuid, text) to authenticated;
