-- Tenant late fees (Stephen, 10/11/2026): rent unpaid on the 2nd with NO attempt to pay gets the lease's late fee (leases.late_fee, $75
-- unless set otherwise) automatically. A payment that is pending (a bank payment in flight, or a fresh "I've paid" report) holds the
-- fee back; when that payment fails, is returned, or a chargeback is lost, the rent is unpaid again with nothing pending and the fee posts
-- at that moment. Once per lease per month. The notice amount stays rent only (lease_rent_due never counts late fees).
--
-- Runs daily from the 2nd (rent-cycle job "late_fees") and immediately when a pending payment fails (rent-cycle action "catchup").
-- Only leases that started before the month began, so a mid-month move-in is never charged a late fee on the 2nd.

create or replace function rent_late_fees(p_day date)
returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  u record; v_month date := date_trunc('month', p_day)::date; v_fee numeric; v_posted jsonb := '[]'::jsonb;
begin
  if extract(day from p_day) < 2 then return jsonb_build_object('day', p_day, 'posted', v_posted); end if;
  for u in select r.lease_id, r.rent_due, r.pending_reported from rent_unpaid(p_day) r
  loop
    continue when u.pending_reported >= u.rent_due;                     -- a payment is pending: hold
    select l.late_fee into v_fee from leases l where l.id = u.lease_id and l.status = 'active' and l.start_date < v_month;
    continue when v_fee is null or v_fee <= 0;
    continue when exists (select 1 from lease_ledger_entries e where e.lease_id = u.lease_id and e.gl_account = 'Late Fee Income'
                          and e.kind = 'charge' and e.entry_date >= v_month and e.entry_date <= p_day);   -- already charged this month
    insert into lease_ledger_entries (lease_id, gl_account, entry_date, kind, raw_type, description, amount, source)
    values (u.lease_id, 'Late Fee Income', p_day, 'charge', 'Charge', 'Late fee: rent due on the 1st was not paid', v_fee, 'rent_cycle');
    v_posted := v_posted || jsonb_build_array(jsonb_build_object('lease_id', u.lease_id, 'amount', v_fee));
  end loop;
  return jsonb_build_object('day', p_day, 'posted', v_posted);
end;
$$;
revoke all on function rent_late_fees(date) from public, anon, authenticated;
grant execute on function rent_late_fees(date) to service_role;
