-- Fix (same day): older fees were paid or credited with lines that do not name the fee, so a fee is open only up to what is still
-- owed on that GL, counted from the NEWEST fee back (payments and credits are taken as having paid the oldest fees first).
create or replace function lease_fee_open(p_lease uuid)
returns jsonb
language sql stable security definer set search_path = public
as $$
  with fees as (
    select e.id, e.entry_date, e.gl_account, e.description, e.amount,
      e.amount - coalesce((select -sum(c.amount) from lease_ledger_entries c where c.lease_id = e.lease_id and c.kind = 'credit'
                           and c.correction_note like 'Credits fee line ' || e.id || '.%'), 0) as left_on_line,
      greatest((select coalesce(sum(g.amount), 0) from lease_ledger_entries g where g.lease_id = e.lease_id and g.gl_account = e.gl_account), 0) as gl_owed
    from lease_ledger_entries e
    where e.lease_id = p_lease and e.kind = 'charge' and e.amount > 0
      and e.gl_account not in ('Rent Income', 'Rent Charge', 'Security Deposit Liability', 'Pet Rent Income')),
  ranked as (
    select f.*, coalesce(sum(greatest(left_on_line, 0)) over (partition by gl_account order by entry_date desc, id desc
                rows between unbounded preceding and 1 preceding), 0) as newer
    from fees f),
  opened as (select r.*, least(greatest(left_on_line, 0), greatest(gl_owed - newer, 0)) as open_amt from ranked r)
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'date', entry_date, 'gl', gl_account, 'description', description, 'amount', amount,
           'open', open_amt) order by entry_date desc, id desc), '[]'::jsonb)
  from opened where open_amt > 0;
$$;
revoke all on function lease_fee_open(uuid) from public, anon, authenticated;

create or replace function condo_fee_open(p_unit_number text)
returns jsonb
language sql stable security definer set search_path = public
as $$
  with fees as (
    select e.id, e.account_id, e.entry_date, e.gl_account, e.description, e.amount,
      e.amount - coalesce((select -sum(c.amount) from condo_ledger_entries c where c.account_id = e.account_id and c.kind = 'credit'
                           and c.correction_note like 'Credits fee line ' || e.id || '.%'), 0) as left_on_line,
      greatest((select coalesce(sum(g.amount), 0) from condo_ledger_entries g where g.account_id = e.account_id and g.gl_account = e.gl_account), 0) as gl_owed
    from condo_ledger_entries e join condo_ledger_accounts a on a.id = e.account_id join condo_units u on u.id = a.unit_id
    where u.unit_number = p_unit_number and not a.excluded and e.kind = 'charge' and e.amount > 0
      and e.gl_account <> 'Association Fee Income'
      and not exists (select 1 from condo_ledger_entries r where r.reverses_entry_id = e.id)),
  ranked as (
    select f.*, coalesce(sum(greatest(left_on_line, 0)) over (partition by account_id, gl_account order by entry_date desc, id desc
                rows between unbounded preceding and 1 preceding), 0) as newer
    from fees f),
  opened as (select r.*, least(greatest(left_on_line, 0), greatest(gl_owed - newer, 0)) as open_amt from ranked r)
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'account', account_id, 'date', entry_date, 'gl', gl_account, 'description', description,
           'amount', amount, 'open', open_amt) order by entry_date desc, id desc), '[]'::jsonb)
  from opened where open_amt > 0;
$$;
revoke all on function condo_fee_open(text) from public, anon, authenticated;
