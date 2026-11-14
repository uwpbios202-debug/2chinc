-- ===========================================================================
-- Royal Orleans association ledger — the complete history, line for line.
-- ===========================================================================
-- Loaded from the "Ownership account ledger by account" report by
-- a one-time importer, which refuses to produce output unless
-- every section and account reconciles to the report's own totals.
--
-- One condo_ledger_accounts row per ownership account (a unit plus
-- the owner billed), linked to the matching condo_ownerships row.
-- Every charge, payment, credit, refund and reversal is a condo_ledger_entries
-- row, keeping the original wording, running balance and report row so
-- any figure can be traced back to the export.
--
-- Fixing earlier mistakes is part of the point of this system, but the
-- original is never lost: legacy_owner_label keeps the name as printed,
-- ownership_id says who it really belongs to, and correction_note records who
-- decided and why (e.g. Unit 18's history was printed under the wrong owner;
-- it is Dolly Williams' from 8/2016). An account ruled out entirely is kept
-- and flagged `excluded` with the reason — history is never deleted.
-- Locked like the rest of the schema: RLS on, no policies.
-- ===========================================================================

create table if not exists condo_ledger_accounts (
  id uuid primary key default gen_random_uuid(),
  unit_id uuid not null references condo_units(id),
  ownership_id uuid references condo_ownerships(id),
  legacy_owner_label text not null,      -- the owner name exactly as originally printed
  legacy_balance numeric(12,2),          -- the original "Ownership account balance" at export
  correction_note text,                    -- why ownership_id differs from what was originally printed
  excluded boolean not null default false,
  excluded_reason text,
  source text not null,                    -- export file name
  imported_at timestamptz not null default now(),
  unique (unit_id, legacy_owner_label, source)
);

create table if not exists condo_ledger_entries (
  id bigint generated always as identity primary key,
  account_id uuid not null references condo_ledger_accounts(id) on delete cascade,
  gl_account text not null,                -- income section, e.g. "Association Fee Income"
  entry_date date not null,
  kind text not null check (kind in ('charge', 'payment', 'credit', 'refund', 'reversal', 'other')),
  raw_type text not null,                  -- the original wording, e.g. "Manual check payment successful (#3421)"
  method text,                             -- cash, check, card, eft, money_order, cashiers_check
  check_number text,
  description text,
  amount numeric(12,2) not null,           -- + increases what the owner owes, - reduces it
  legacy_running_balance numeric(12,2),
  source_row integer not null
);
create index if not exists condo_ledger_entries_account_idx on condo_ledger_entries (account_id, entry_date);

alter table condo_ledger_accounts enable row level security;
alter table condo_ledger_entries enable row level security;

-- Balance per account as recorded here; must equal legacy_balance.
create or replace view condo_ledger_balances with (security_invoker = true) as
  select a.id as account_id, u.unit_number, a.legacy_owner_label, a.excluded,
         coalesce(sum(e.amount), 0)::numeric(12,2) as balance,
         a.legacy_balance,
         min(e.entry_date) as first_entry, max(e.entry_date) as last_entry, count(e.id) as entries
  from condo_ledger_accounts a
  join condo_units u on u.id = a.unit_id
  left join condo_ledger_entries e on e.account_id = a.id
  group by a.id, u.unit_number;
revoke all on condo_ledger_balances from public, anon, authenticated;

-- Staff: a unit's full ledger (all accounts, oldest first, with a running
-- balance per account).
create or replace function condo_staff_unit_ledger(p_unit_number text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'account_id', a.id,
      'owner', coalesce((select o.name from condo_ownerships s join condo_owners o on o.id = s.owner_id where s.id = a.ownership_id), a.legacy_owner_label),
      'legacy_owner_label', a.legacy_owner_label, 'correction_note', a.correction_note,
      'excluded', a.excluded, 'excluded_reason', a.excluded_reason,
      'legacy_balance', a.legacy_balance,
      'entries', (select coalesce(jsonb_agg(jsonb_build_object(
          'date', x.entry_date, 'gl', x.gl_account, 'kind', x.kind, 'type', x.raw_type, 'description', x.description,
          'amount', x.amount, 'balance', x.running)
          order by x.entry_date, x.id), '[]'::jsonb)
        from (select e.*, sum(e.amount) over (order by e.entry_date, e.id) as running
              from condo_ledger_entries e where e.account_id = a.id) x))
      order by (select min(entry_date) from condo_ledger_entries where account_id = a.id))
    from condo_ledger_accounts a join condo_units u on u.id = a.unit_id
    where u.unit_number = p_unit_number), '[]'::jsonb);
end;
$$;
revoke all on function condo_staff_unit_ledger(text) from public, anon;
grant execute on function condo_staff_unit_ledger(text) to authenticated;
