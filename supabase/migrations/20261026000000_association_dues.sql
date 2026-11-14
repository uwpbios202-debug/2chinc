-- ===========================================================================
-- Royal Orleans association: dues going forward, late fees, collections,
-- staff ledger tools, and the owner's own balance and statement.
-- ===========================================================================
-- The history (2011–2026) is the original, loaded by 20261003010000_condo_ledger.
-- From here on this system posts the charges itself, the same way as before
-- configured (read from the ledger, every account, 2025–2026):
--   1st   dues charge = the ownership's fee ($215 for every unit)
--   10th  $25 late fee if the account still owes anything
--   11th  1.15% of the whole account balance (late fees included, so it
--         compounds). The base is a setting: 'balance' (the original way) or
--         'charges' (everything except earlier late fees).
-- All amounts and days are portal_settings rows, so the board can change them
-- without code.
--
-- Nothing is ever deleted: a wrong entry is reversed by a new entry, and a
-- waived late fee is a credit with a reason. Every entry this system makes
-- says where it came from (origin), who entered it and why.
-- ===========================================================================

alter table condo_ledger_entries add column if not exists origin text not null default 'legacy';
alter table condo_ledger_entries drop constraint if exists condo_ledger_entries_origin_check;
alter table condo_ledger_entries add constraint condo_ledger_entries_origin_check check (origin in ('legacy', 'billing', 'staff'));
alter table condo_ledger_entries add column if not exists entered_by text;
alter table condo_ledger_entries add column if not exists correction_note text;
alter table condo_ledger_entries add column if not exists reverses_entry_id bigint references condo_ledger_entries(id);
alter table condo_ledger_entries add column if not exists created_at timestamptz not null default now();
alter table condo_ledger_entries alter column source_row drop not null;
alter table condo_ledger_entries drop constraint if exists condo_ledger_entries_kind_check;
alter table condo_ledger_entries add constraint condo_ledger_entries_kind_check
  check (kind in ('charge', 'payment', 'credit', 'refund', 'reversal', 'late_fee', 'other'));

-- The one account per unit that new charges go on. Unit 18 has two accounts
-- for Dolly Williams (the two original labels); both count toward what she owes,
-- but only the newer one is billed, as before.
alter table condo_ledger_accounts add column if not exists billing_account boolean not null default false;
create unique index if not exists condo_ledger_accounts_one_billing on condo_ledger_accounts (unit_id) where billing_account;

update condo_ledger_accounts a set billing_account = true
where a.id in (
  select distinct on (a2.unit_id) a2.id
  from condo_ledger_accounts a2 join condo_ownerships s on s.id = a2.ownership_id
  where s.is_current and not a2.excluded
  order by a2.unit_id, (select max(entry_date) from condo_ledger_entries e where e.account_id = a2.id) desc nulls last
)
and not exists (select 1 from condo_ledger_accounts b where b.unit_id = a.unit_id and b.billing_account);

insert into portal_settings (key, value) values
  ('dues_default', '215'),
  ('dues_late_flat_day', '10'),
  ('dues_late_flat', '25'),
  ('dues_late_pct_day', '11'),
  ('dues_late_pct', '1.15'),
  ('dues_late_pct_base', 'balance'),
  ('dues_past_due_email', 'on'),
  ('dues_pay_instructions', 'Mail a check or money order payable to ROCA1 to 6626 North Bourbon Street, Milwaukee, WI 53224, and write your unit number on it.')
on conflict (key) do nothing;

-- Collections: every step taken on a delinquent account, oldest first.
create table if not exists condo_collection_steps (
  id bigint generated always as identity primary key,
  unit_id uuid not null references condo_units(id),
  account_id uuid references condo_ledger_accounts(id),
  step text not null check (step in ('note', 'reminder', 'demand_letter', 'payment_plan', 'attorney', 'lien', 'foreclosure', 'judgment', 'resolved', 'written_off')),
  step_date date not null default current_date,
  amount numeric(12,2),                    -- e.g. the amount demanded, plan payment, judgment amount
  note text,
  entered_by text,
  created_at timestamptz not null default now()
);
create index if not exists condo_collection_steps_unit_idx on condo_collection_steps (unit_id, step_date);
alter table condo_collection_steps enable row level security;

-- ---------------------------------------------------------------------------
create or replace function condo_setting(p_key text, p_default text)
returns text language sql stable security definer set search_path = public as $$
  select coalesce((select value from portal_settings where key = p_key), p_default);
$$;
revoke all on function condo_setting(text, text) from public, anon, authenticated;

create or replace function condo_account_balance(p_account uuid, p_as_of date default null)
returns numeric language sql stable security definer set search_path = public as $$
  select coalesce(sum(amount), 0)::numeric(12,2) from condo_ledger_entries
  where account_id = p_account and (p_as_of is null or entry_date <= p_as_of);
$$;
revoke all on function condo_account_balance(uuid, date) from public, anon, authenticated;

-- The account new charges go on for a unit. Follows ownership changes: if the
-- current owner has no account yet, one is opened for them.
create or replace function condo_billing_account(p_unit uuid)
returns uuid
language plpgsql volatile security definer set search_path = public
as $$
declare v_own condo_ownerships; v_acct uuid; v_name text;
begin
  select * into v_own from condo_ownerships where unit_id = p_unit and is_current order by start_date desc nulls last limit 1;
  if v_own.id is null then return null; end if;
  select id into v_acct from condo_ledger_accounts where unit_id = p_unit and billing_account and ownership_id = v_own.id;
  if v_acct is not null then return v_acct; end if;
  update condo_ledger_accounts set billing_account = false where unit_id = p_unit and billing_account;
  select id into v_acct from condo_ledger_accounts where unit_id = p_unit and ownership_id = v_own.id and not excluded
    order by imported_at desc limit 1;
  if v_acct is null then
    select name into v_name from condo_owners where id = v_own.owner_id;
    insert into condo_ledger_accounts (unit_id, ownership_id, legacy_owner_label, source, correction_note)
    values (p_unit, v_own.id, v_name, '2ndchinc', 'Opened by this system when the ownership began.')
    returning id into v_acct;
  end if;
  update condo_ledger_accounts set billing_account = true where id = v_acct;
  return v_acct;
end;
$$;
revoke all on function condo_billing_account(uuid) from public, anon, authenticated;

-- 1st of the month: post dues. Idempotent: skips an account that already has
-- a dues charge dated in that month (the original, or an earlier run).
create or replace function condo_billing_post_month(p_month date)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare m date := date_trunc('month', p_month)::date; r record; v_acct uuid; n int := 0; skipped int := 0;
begin
  for r in select s.unit_id, coalesce(s.fee, condo_setting('dues_default', '215')::numeric) as fee, s.fee_frequency
           from condo_ownerships s where s.is_current and coalesce(s.start_date, m) <= m + 27
  loop
    if coalesce(r.fee_frequency, 'Monthly') <> 'Monthly' or r.fee <= 0 then skipped := skipped + 1; continue; end if;
    v_acct := condo_billing_account(r.unit_id);
    if exists (select 1 from condo_ledger_entries e where e.account_id = v_acct and e.kind = 'charge'
               and e.gl_account = 'Association Fee Income' and date_trunc('month', e.entry_date) = m) then
      skipped := skipped + 1; continue;
    end if;
    insert into condo_ledger_entries (account_id, gl_account, entry_date, kind, raw_type, description, amount, origin, entered_by)
    values (v_acct, 'Association Fee Income', m, 'charge', 'Charge', 'Association Fees', r.fee, 'billing', 'monthly billing');
    n := n + 1;
  end loop;
  return jsonb_build_object('month', m, 'dues_charges', n, 'skipped', skipped);
end;
$$;
revoke all on function condo_billing_post_month(date) from public, anon, authenticated;

-- Late fees for one day: the flat fee on dues_late_flat_day, the percentage
-- fee on dues_late_pct_day. Each at most once per account per day.
create or replace function condo_post_late_fees(p_day date)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare
  d int := extract(day from p_day);
  flat_day int := condo_setting('dues_late_flat_day', '10')::int;
  pct_day int := condo_setting('dues_late_pct_day', '11')::int;
  flat numeric := condo_setting('dues_late_flat', '25')::numeric;
  pct numeric := condo_setting('dues_late_pct', '1.15')::numeric;
  pct_base text := condo_setting('dues_late_pct_base', 'balance');
  r record; v_base numeric; v_fee numeric; n_flat int := 0; n_pct int := 0;
begin
  if d <> flat_day and d <> pct_day then return jsonb_build_object('day', p_day, 'late_fees', 0); end if;
  for r in select a.id, condo_account_balance(a.id, p_day) as bal from condo_ledger_accounts a where a.billing_account and not a.excluded
  loop
    continue when r.bal <= 0;
    if d = flat_day and flat > 0 and not exists (select 1 from condo_ledger_entries where account_id = r.id and gl_account = 'Late Fee Income'
                                                  and entry_date = p_day and origin = 'billing' and description = 'Late fee') then
      insert into condo_ledger_entries (account_id, gl_account, entry_date, kind, raw_type, description, amount, origin, entered_by)
      values (r.id, 'Late Fee Income', p_day, 'late_fee', 'Charge', 'Late fee', flat, 'billing', 'monthly billing');
      n_flat := n_flat + 1;
    end if;
    if d = pct_day and pct > 0 and not exists (select 1 from condo_ledger_entries where account_id = r.id and gl_account = 'Late Fee Income'
                                                and entry_date = p_day and origin = 'billing' and description like 'Late fee %') then
      v_base := case when pct_base = 'charges'
                     then (select coalesce(sum(amount), 0) from condo_ledger_entries where account_id = r.id and entry_date <= p_day
                           and not (gl_account = 'Late Fee Income' and amount > 0))
                     else condo_account_balance(r.id, p_day) end;
      v_fee := round(v_base * pct / 100, 2);
      if v_fee > 0 then
        insert into condo_ledger_entries (account_id, gl_account, entry_date, kind, raw_type, description, amount, origin, entered_by)
        values (r.id, 'Late Fee Income', p_day, 'late_fee', 'Charge', 'Late fee ' || pct || '% of ' || to_char(v_base, 'FM$999,999,990.00'), v_fee, 'billing', 'monthly billing');
        n_pct := n_pct + 1;
      end if;
    end if;
  end loop;
  return jsonb_build_object('day', p_day, 'flat_fees', n_flat, 'percent_fees', n_pct);
end;
$$;
revoke all on function condo_post_late_fees(date) from public, anon, authenticated;

-- Everyone who owes on a date: current owners (all their accounts for the
-- unit), with email and preference, for the past-due email and staff digest.
create or replace function condo_past_due(p_as_of date)
returns table (unit_number text, address text, owner_name text, email text, communications_preference text, balance numeric, dues numeric)
language sql stable security definer set search_path = public as $$
  select u.unit_number, u.address, o.name, o.email, o.communications_preference,
         (select coalesce(sum(e.amount), 0) from condo_ledger_entries e join condo_ledger_accounts a on a.id = e.account_id
          where a.ownership_id = s.id and not a.excluded and e.entry_date <= p_as_of)::numeric(12,2),
         coalesce(s.fee, condo_setting('dues_default', '215')::numeric)
  from condo_ownerships s join condo_units u on u.id = s.unit_id join condo_owners o on o.id = s.owner_id
  where s.is_current
    and (select coalesce(sum(e.amount), 0) from condo_ledger_entries e join condo_ledger_accounts a on a.id = e.account_id
         where a.ownership_id = s.id and not a.excluded and e.entry_date <= p_as_of) > 0
  order by nullif(regexp_replace(u.unit_number, '\D', '', 'g'), '')::int;
$$;
revoke all on function condo_past_due(date) from public, anon, authenticated;

-- ---------------------------------------------------------------------------
-- Ledger JSON shared by the staff and owner views.
create or replace function condo_account_json(p_account uuid, p_staff boolean)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'account_id', a.id,
    'owner', coalesce((select o.name from condo_ownerships s join condo_owners o on o.id = s.owner_id where s.id = a.ownership_id), a.legacy_owner_label),
    'is_current_owner', coalesce((select s.is_current from condo_ownerships s where s.id = a.ownership_id), false),
    'legacy_owner_label', a.legacy_owner_label, 'correction_note', a.correction_note,
    'excluded', a.excluded, 'excluded_reason', a.excluded_reason, 'billing_account', a.billing_account,
    'legacy_balance', a.legacy_balance,
    'balance', condo_account_balance(a.id),
    'entries', (select coalesce(jsonb_agg(jsonb_build_object(
        'id', x.id, 'date', x.entry_date, 'gl', x.gl_account, 'kind', x.kind, 'type', x.raw_type, 'description', x.description,
        'method', x.method, 'check_number', x.check_number,
        'amount', x.amount, 'balance', x.running, 'origin', x.origin, 'note', x.correction_note,
        'entered_by', case when p_staff then x.entered_by end, 'reverses', x.reverses_entry_id,
        'reversed', exists (select 1 from condo_ledger_entries r where r.reverses_entry_id = x.id))
        order by x.entry_date, x.id), '[]'::jsonb)
      from (select e.*, sum(e.amount) over (order by e.entry_date, e.id) as running
            from condo_ledger_entries e where e.account_id = a.id) x))
  from condo_ledger_accounts a where a.id = p_account;
$$;
revoke all on function condo_account_json(uuid, boolean) from public, anon, authenticated;

-- Staff: a unit's full ledger (replaces the read-only version).
create or replace function condo_staff_unit_ledger(p_unit_number text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(condo_account_json(a.id, true)
      order by a.billing_account desc, (select max(entry_date) from condo_ledger_entries where account_id = a.id) desc nulls last)
    from condo_ledger_accounts a join condo_units u on u.id = a.unit_id
    where u.unit_number = p_unit_number), '[]'::jsonb);
end;
$$;
revoke all on function condo_staff_unit_ledger(text) from public, anon;
grant execute on function condo_staff_unit_ledger(text) to authenticated;

-- Staff: every unit with its balance, delinquency and collections status.
create or replace function condo_staff_dues_overview()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'settings', (select jsonb_object_agg(key, value) from portal_settings where key like 'dues_%'),
    'units', coalesce((select jsonb_agg(x order by nullif(regexp_replace(x->>'unit_number', '\D', '', 'g'), '')::int) from (
      select jsonb_build_object(
        'unit_id', u.id, 'unit_number', u.unit_number, 'address', u.address, 'pin', u.pin,
        'owner', o.name, 'owner_email', o.email, 'dues', coalesce(s.fee, condo_setting('dues_default', '215')::numeric),
        'balance', (select coalesce(sum(e.amount), 0) from condo_ledger_entries e join condo_ledger_accounts a on a.id = e.account_id
                    where a.ownership_id = s.id and not a.excluded),
        'former_owner_balance', (select coalesce(sum(e.amount), 0) from condo_ledger_entries e join condo_ledger_accounts a on a.id = e.account_id
                    left join condo_ownerships s2 on s2.id = a.ownership_id
                    where a.unit_id = u.id and not a.excluded and not coalesce(s2.is_current, false)),
        'last_payment', (select jsonb_build_object('date', e.entry_date, 'amount', -e.amount) from condo_ledger_entries e
                    join condo_ledger_accounts a on a.id = e.account_id
                    where a.ownership_id = s.id and e.kind = 'payment' and e.amount < 0 order by e.entry_date desc, e.id desc limit 1),
        'late_fees_12mo', (select coalesce(sum(e.amount), 0) from condo_ledger_entries e join condo_ledger_accounts a on a.id = e.account_id
                    where a.ownership_id = s.id and e.gl_account = 'Late Fee Income' and e.amount > 0 and e.entry_date > current_date - 365),
        'collection', (select jsonb_build_object('step', c.step, 'date', c.step_date, 'note', c.note) from condo_collection_steps c
                    where c.unit_id = u.id order by c.step_date desc, c.id desc limit 1)
      ) as x
      from condo_ownerships s join condo_units u on u.id = s.unit_id join condo_owners o on o.id = s.owner_id
      where s.is_current) q), '[]'::jsonb)
  );
end;
$$;
revoke all on function condo_staff_dues_overview() from public, anon;
grant execute on function condo_staff_dues_overview() to authenticated;

-- Staff: record a payment, charge, credit, refund or late-fee waiver.
-- p_amount is always entered as a positive number; the sign follows the kind.
create or replace function condo_staff_post_entry(
  p_account uuid, p_kind text, p_date date, p_amount numeric, p_gl text default null,
  p_method text default null, p_check_number text default null, p_description text default null, p_note text default null)
returns bigint
language plpgsql volatile security definer set search_path = public
as $$
declare v_id bigint; v_gl text; v_amt numeric; v_desc text; v_kind text := p_kind;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if not exists (select 1 from condo_ledger_accounts where id = p_account) then raise exception 'Account not found'; end if;
  if p_amount is null or p_amount <= 0 then raise exception 'Enter an amount greater than zero'; end if;
  if p_date is null or p_date > current_date + 31 then raise exception 'Enter a date (not more than a month ahead)'; end if;
  if p_kind in ('credit', 'waive_late_fee') and coalesce(trim(p_note), '') = '' then raise exception 'Say why: a credit or waiver needs a reason'; end if;
  if p_kind = 'payment' and coalesce(p_method, '') not in ('check', 'money_order', 'cashiers_check', 'cash', 'eft', 'card', 'zelle', 'other') then
    raise exception 'Choose how it was paid';
  end if;
  case p_kind
    when 'payment' then v_amt := -p_amount; v_gl := coalesce(nullif(p_gl, ''), 'Association Fee Income'); v_desc := coalesce(nullif(p_description, ''), 'Payment');
    when 'charge'  then v_amt := p_amount;  v_gl := coalesce(nullif(p_gl, ''), 'Association Fee Income'); v_desc := coalesce(nullif(p_description, ''), 'Charge');
    when 'credit'  then v_amt := -p_amount; v_gl := coalesce(nullif(p_gl, ''), 'Association Fee Income'); v_desc := coalesce(nullif(p_description, ''), 'Credit');
    when 'refund'  then v_amt := p_amount;  v_gl := coalesce(nullif(p_gl, ''), 'Association Fee Income'); v_desc := coalesce(nullif(p_description, ''), 'Refund');
    when 'waive_late_fee' then v_amt := -p_amount; v_gl := 'Late Fee Income'; v_desc := 'Late fee waived'; v_kind := 'credit';
    else raise exception 'Unknown entry type';
  end case;
  insert into condo_ledger_entries (account_id, gl_account, entry_date, kind, raw_type, method, check_number, description, amount, origin, entered_by, correction_note)
  values (p_account, v_gl, p_date, v_kind,
          case p_kind when 'payment' then 'Payment (' || replace(p_method, '_', ' ') || coalesce(' #' || nullif(p_check_number, ''), '') || ')' else initcap(replace(p_kind, '_', ' ')) end,
          case when p_kind = 'payment' then p_method end, nullif(p_check_number, ''), v_desc, v_amt, 'staff', auth.email(), nullif(trim(p_note), ''))
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function condo_staff_post_entry(uuid, text, date, numeric, text, text, text, text, text) from public, anon;
grant execute on function condo_staff_post_entry(uuid, text, date, numeric, text, text, text, text, text) to authenticated;

-- Staff: reverse an entry (bounced check, posted to the wrong unit, ...).
-- The original stays; an equal and opposite entry points back at it.
create or replace function condo_staff_reverse_entry(p_entry bigint, p_note text)
returns bigint
language plpgsql volatile security definer set search_path = public
as $$
declare e condo_ledger_entries; v_id bigint;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  if coalesce(trim(p_note), '') = '' then raise exception 'Say why the entry is being reversed'; end if;
  select * into e from condo_ledger_entries where id = p_entry;
  if e.id is null then raise exception 'Entry not found'; end if;
  if e.reverses_entry_id is not null then raise exception 'That entry is itself a reversal'; end if;
  if exists (select 1 from condo_ledger_entries where reverses_entry_id = p_entry) then raise exception 'That entry was already reversed'; end if;
  insert into condo_ledger_entries (account_id, gl_account, entry_date, kind, raw_type, description, amount, origin, entered_by, correction_note, reverses_entry_id)
  values (e.account_id, e.gl_account, current_date, 'reversal', 'Reversal', 'Reverses ' || coalesce(e.description, e.raw_type) || ' of ' || to_char(e.entry_date, 'FMMM/FMDD/YYYY'),
          -e.amount, 'staff', auth.email(), trim(p_note), e.id)
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function condo_staff_reverse_entry(bigint, text) from public, anon;
grant execute on function condo_staff_reverse_entry(bigint, text) to authenticated;

-- Staff: collections log for a unit.
create or replace function condo_staff_collections(p_unit_number text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'step', c.step, 'date', c.step_date, 'amount', c.amount, 'note', c.note,
                                                       'entered_by', c.entered_by, 'created_at', c.created_at) order by c.step_date, c.id)
                   from condo_collection_steps c join condo_units u on u.id = c.unit_id where u.unit_number = p_unit_number), '[]'::jsonb);
end;
$$;
revoke all on function condo_staff_collections(text) from public, anon;
grant execute on function condo_staff_collections(text) to authenticated;

create or replace function condo_staff_add_collection_step(p_unit_number text, p_step text, p_date date, p_amount numeric, p_note text)
returns bigint
language plpgsql volatile security definer set search_path = public
as $$
declare v_unit uuid; v_id bigint;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select id into v_unit from condo_units where unit_number = p_unit_number;
  if v_unit is null then raise exception 'Unit not found'; end if;
  if p_step = 'note' and coalesce(trim(p_note), '') = '' then raise exception 'Write the note'; end if;
  insert into condo_collection_steps (unit_id, account_id, step, step_date, amount, note, entered_by)
  values (v_unit, (select id from condo_ledger_accounts where unit_id = v_unit and billing_account), p_step, coalesce(p_date, current_date),
          p_amount, nullif(trim(p_note), ''), auth.email())
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function condo_staff_add_collection_step(text, text, date, numeric, text) from public, anon;
grant execute on function condo_staff_add_collection_step(text, text, date, numeric, text) to authenticated;

-- Owner: their own balance and ledger for each unit they currently own
-- (every account of their ownership, e.g. Unit 18's two).
create or replace function condo_my_account()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare v_owner uuid := condo_owner_for_email(auth.email());
begin
  if not condo_session_ok() then raise exception 'Two-step sign-in required' using errcode = '42501'; end if;
  if v_owner is null then raise exception 'No current ownership on file for this email' using errcode = '42501'; end if;
  return jsonb_build_object(
    'owner', (select name from condo_owners where id = v_owner),
    'pay_instructions', condo_setting('dues_pay_instructions', ''),
    'office_phone', condo_setting('org_phone', condo_setting('office_phone', '')),
    'late_policy', jsonb_build_object('flat', condo_setting('dues_late_flat', '25'), 'flat_day', condo_setting('dues_late_flat_day', '10'),
                                      'pct', condo_setting('dues_late_pct', '1.15'), 'pct_day', condo_setting('dues_late_pct_day', '11')),
    'units', coalesce((select jsonb_agg(jsonb_build_object(
        'unit_number', u.unit_number, 'address', u.address, 'pin', u.pin,
        'dues', coalesce(s.fee, condo_setting('dues_default', '215')::numeric),
        'balance', (select coalesce(sum(e.amount), 0) from condo_ledger_entries e join condo_ledger_accounts a on a.id = e.account_id
                    where a.ownership_id = s.id and not a.excluded),
        'accounts', (select coalesce(jsonb_agg(condo_account_json(a.id, false) order by a.billing_account desc), '[]'::jsonb)
                     from condo_ledger_accounts a where a.ownership_id = s.id and not a.excluded))
        order by nullif(regexp_replace(u.unit_number, '\D', '', 'g'), '')::int)
      from condo_ownerships s join condo_units u on u.id = s.unit_id
      where s.owner_id = v_owner and s.is_current), '[]'::jsonb));
end;
$$;
revoke all on function condo_my_account() from public, anon;
grant execute on function condo_my_account() to authenticated;
