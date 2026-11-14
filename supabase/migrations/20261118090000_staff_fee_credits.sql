-- Fee credit button for staff, tenants and owners (Stephen, 11/3/2026). Staff pick an open fee line (late fee, interest, repairs,
-- cleaning, legal, fines, other; never rent, dues or the security deposit), enter an amount and a reason, and a credit line is posted
-- on the same GL account. The credit names the line it credits ("Credits fee line N.") so a fee is never credited twice, and a credit
-- never exceeds what is still owed on that GL (a fee already paid cannot be turned into rent or dues credit). Original lines are kept.
-- No new tables.

create or replace function lease_fee_open(p_lease uuid)
returns jsonb
language sql stable security definer set search_path = public
as $$
  with fees as (
    select e.id, e.entry_date, e.gl_account, e.description, e.amount,
      e.amount - coalesce((select -sum(c.amount) from lease_ledger_entries c where c.lease_id = e.lease_id and c.kind = 'credit'
                           and c.correction_note like 'Credits fee line ' || e.id || '.%'), 0) as left_on_line,
      (select coalesce(sum(g.amount), 0) from lease_ledger_entries g where g.lease_id = e.lease_id and g.gl_account = e.gl_account) as gl_owed
    from lease_ledger_entries e
    where e.lease_id = p_lease and e.kind = 'charge' and e.amount > 0
      and e.gl_account not in ('Rent Income', 'Rent Charge', 'Security Deposit Liability', 'Pet Rent Income'))
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'date', entry_date, 'gl', gl_account, 'description', description, 'amount', amount,
           'open', least(left_on_line, greatest(gl_owed, 0))) order by entry_date desc, id desc), '[]'::jsonb)
  from fees where least(left_on_line, gl_owed) > 0;
$$;
revoke all on function lease_fee_open(uuid) from public, anon, authenticated;

create or replace function lease_staff_open_fees(p_lease uuid)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return lease_fee_open(p_lease);
end $$;
revoke all on function lease_staff_open_fees(uuid) from public, anon;
grant execute on function lease_staff_open_fees(uuid) to authenticated, service_role;

create or replace function lease_staff_credit_fee(p_entry bigint, p_amount numeric, p_reason text)
returns bigint
language plpgsql volatile security definer set search_path = public
as $$
declare e lease_ledger_entries; v_open numeric; v_amt numeric := round(p_amount, 2); v_id bigint;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into e from lease_ledger_entries where id = p_entry;
  if e.id is null then raise exception 'Fee not found'; end if;
  perform 1 from leases where id = e.lease_id for update;  -- one credit at a time per lease
  select (x->>'open')::numeric into v_open from jsonb_array_elements(lease_fee_open(e.lease_id)) x where (x->>'id')::bigint = e.id;
  if v_open is null then raise exception 'Nothing is left to credit on that fee'; end if;
  if v_amt is null or v_amt <= 0 then raise exception 'Enter an amount greater than zero'; end if;
  if v_amt > v_open then raise exception 'Up to % can be credited on that fee', to_char(v_open, 'FM$999,990.00'); end if;
  if length(coalesce(trim(p_reason), '')) < 3 then raise exception 'Say why the fee is credited'; end if;
  insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, description, amount, source, correction_note)
  values (e.lease_id, e.gl_account, current_date, 'credit', 'Fee credit',
          'Credit: ' || coalesce(e.description, e.gl_account) || ' of ' || to_char(e.entry_date, 'FMMM/FMDD/YYYY'), -v_amt, 'staff',
          'Credits fee line ' || e.id || '. ' || trim(p_reason) || ' (by ' || auth.email() || ')')
  returning id into v_id;
  return v_id;
end $$;
revoke all on function lease_staff_credit_fee(bigint, numeric, text) from public, anon;
grant execute on function lease_staff_credit_fee(bigint, numeric, text) to authenticated, service_role;

-- Owners (association ledger): open fee lines on the unit's accounts that are not excluded.
create or replace function condo_fee_open(p_unit_number text)
returns jsonb
language sql stable security definer set search_path = public
as $$
  with fees as (
    select e.id, e.account_id, e.entry_date, e.gl_account, e.description, e.amount,
      e.amount - coalesce((select -sum(c.amount) from condo_ledger_entries c where c.account_id = e.account_id and c.kind = 'credit'
                           and c.correction_note like 'Credits fee line ' || e.id || '.%'), 0) as left_on_line,
      (select coalesce(sum(g.amount), 0) from condo_ledger_entries g where g.account_id = e.account_id and g.gl_account = e.gl_account) as gl_owed
    from condo_ledger_entries e join condo_ledger_accounts a on a.id = e.account_id join condo_units u on u.id = a.unit_id
    where u.unit_number = p_unit_number and not a.excluded and e.kind = 'charge' and e.amount > 0
      and e.gl_account <> 'Association Fee Income'
      and not exists (select 1 from condo_ledger_entries r where r.reverses_entry_id = e.id))
  select coalesce(jsonb_agg(jsonb_build_object('id', id, 'account', account_id, 'date', entry_date, 'gl', gl_account, 'description', description,
           'amount', amount, 'open', least(left_on_line, greatest(gl_owed, 0))) order by entry_date desc, id desc), '[]'::jsonb)
  from fees where least(left_on_line, gl_owed) > 0;
$$;
revoke all on function condo_fee_open(text) from public, anon, authenticated;

create or replace function condo_staff_open_fees(p_unit_number text)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return condo_fee_open(p_unit_number);
end $$;
revoke all on function condo_staff_open_fees(text) from public, anon;
grant execute on function condo_staff_open_fees(text) to authenticated, service_role;

create or replace function condo_staff_credit_fee(p_entry bigint, p_amount numeric, p_reason text)
returns bigint
language plpgsql volatile security definer set search_path = public
as $$
declare e condo_ledger_entries; v_unit text; v_open numeric; v_amt numeric := round(p_amount, 2); v_id bigint;
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  select * into e from condo_ledger_entries where id = p_entry;
  if e.id is null then raise exception 'Fee not found'; end if;
  perform 1 from condo_ledger_accounts where id = e.account_id for update;
  select u.unit_number into v_unit from condo_ledger_accounts a join condo_units u on u.id = a.unit_id where a.id = e.account_id;
  select (x->>'open')::numeric into v_open from jsonb_array_elements(condo_fee_open(v_unit)) x where (x->>'id')::bigint = e.id;
  if v_open is null then raise exception 'Nothing is left to credit on that fee'; end if;
  if v_amt is null or v_amt <= 0 then raise exception 'Enter an amount greater than zero'; end if;
  if v_amt > v_open then raise exception 'Up to % can be credited on that fee', to_char(v_open, 'FM$999,990.00'); end if;
  if length(coalesce(trim(p_reason), '')) < 3 then raise exception 'Say why the fee is credited'; end if;
  insert into condo_ledger_entries (account_id, gl_account, entry_date, kind, raw_type, description, amount, origin, entered_by, correction_note)
  values (e.account_id, e.gl_account, current_date, 'credit', 'Fee credit',
          'Credit: ' || coalesce(e.description, e.gl_account) || ' of ' || to_char(e.entry_date, 'FMMM/FMDD/YYYY'), -v_amt, 'staff', auth.email(),
          'Credits fee line ' || e.id || '. ' || trim(p_reason))
  returning id into v_id;
  return v_id;
end $$;
revoke all on function condo_staff_credit_fee(bigint, numeric, text) from public, anon;
grant execute on function condo_staff_credit_fee(bigint, numeric, text) to authenticated, service_role;
