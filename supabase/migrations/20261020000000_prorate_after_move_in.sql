-- Stage 2 rule (confirmed by Stephen 10/4/2026): full rent to move in, and the
-- following month prorated. A lease starting on the 15th pays a full month at
-- move-in (15th through the 14th of next month); next month's bill covers only
-- the 15th through month end. Leases starting on the 1st are unchanged.

create or replace function billing_post_month(p_month date)
returns jsonb
language plpgsql volatile security definer set search_path = public
as $$
declare m date := date_trunc('month', p_month)::date; n_rent int := 0; n_credit int := 0; n_lc int := 0; r record;
  v_amt numeric; v_desc text; v_dim int; v_days int;
begin
  for r in select l.id, l.rent, l.start_date, l.move_in_charges_posted from leases l
           where l.status = 'active' and coalesce(l.rent, 0) > 0 and coalesce(l.start_date, m) <= m + 27
             and (l.end_date is null or l.end_date >= m)
             and not exists (select 1 from lease_ledger_entries e where e.lease_id = l.id and e.kind = 'charge'
                             and e.gl_account in ('Rent Income', 'Rent Charge') and date_trunc('month', e.entry_date) = m)
  loop
    -- Move-in rule (tenant-journey-spec): a full month's rent is paid to move in,
    -- covering the start date through the same day next month; the following
    -- month is billed only for the days left after that.
    v_amt := r.rent; v_desc := 'Rent';
    if r.move_in_charges_posted and extract(day from r.start_date) > 1
       and m = (date_trunc('month', r.start_date) + interval '1 month')::date then
      v_dim := extract(day from (m + interval '1 month' - interval '1 day'))::int;
      v_days := v_dim - least(extract(day from r.start_date)::int - 1, v_dim);
      v_amt := round(r.rent * v_days / v_dim, 2);
      v_desc := 'Rent (prorated ' || to_char(m + (v_dim - v_days), 'FMMM/FMDD') || '–' || to_char(m + v_dim - 1, 'FMMM/FMDD') || ', ' || v_days || ' of ' || v_dim || ' days)';
    end if;
    if v_amt > 0 then
      insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, description, amount, source)
      values (r.id, 'Rent Income', m, 'charge', 'Charge', v_desc, v_amt, 'billing');
      n_rent := n_rent + 1;
    end if;
  end loop;
  -- Work in lieu of rent: monthly in-kind credit for ACTIVE agreements.
  for r in select w.id, w.lease_id, w.monthly_credit, w.title from work_agreements w join leases l on l.id = w.lease_id
           where w.status = 'active' and coalesce(w.monthly_credit, 0) > 0 and l.status = 'active'
             and (w.start_date is null or w.start_date <= m) and (w.end_date is null or w.end_date >= m)
             and not exists (select 1 from lease_ledger_entries e where e.lease_id = w.lease_id and e.kind = 'in_kind'
                             and e.source = 'billing' and date_trunc('month', e.entry_date) = m)
  loop
    insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, description, amount, source, correction_note)
    values (r.lease_id, 'Rent Income', m, 'in_kind', 'Work in lieu of rent', r.title, -r.monthly_credit, 'billing',
            'Monthly in-kind credit under the work agreement; credited for the previous month''s work.');
    insert into work_logs (lease_id, agreement_id, work_date, description, value, ledger_entry_id)
    values (r.lease_id, r.id, m, 'Monthly credit: ' || r.title, r.monthly_credit, currval(pg_get_serial_sequence('lease_ledger_entries', 'id')));
    n_credit := n_credit + 1;
  end loop;
  -- Land contract installments.
  for r in select c.id, c.monthly_payment from land_contracts c
           where c.status = 'active' and coalesce(c.monthly_payment, 0) > 0 and (c.first_payment_date is null or c.first_payment_date <= m)
             and not exists (select 1 from land_contract_ledger e where e.contract_id = c.id and e.kind = 'installment_due' and date_trunc('month', e.entry_date) = m)
  loop
    insert into land_contract_ledger (contract_id, entry_date, kind, legacy_gl, raw_type, description, amount, source)
    values (r.id, m, 'installment_due', 'Rent Income', 'Charge', 'Installment', r.monthly_payment, 'billing');
    n_lc := n_lc + 1;
  end loop;
  return jsonb_build_object('month', m, 'rent_charges', n_rent, 'work_credits', n_credit, 'land_contract_installments', n_lc);
end;
$$;
