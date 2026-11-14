-- ONE-TIME ledger update (Stephen, 10/11/2026): Units 4 and 12 paid their October rent before the earlier tools closed, but the payments were never posted.
--   Unit 12 (Dianne Small, Glen Hierrezuelo): $925.00, balance 925.00 -> 0.00.
--   Unit 4 (Ashley Williams): $2,150.00 = the $1,250.00 owed + $900.00 paid ahead; the balance becomes a $900.00 credit (applied to the next charge).
--   Unit 16 has NOT paid and is left alone.
-- Posted through payment_post like any staff-verified payment (verified, receipt line in the ledger). The "Payment received" emails that the
-- posting queues are removed so tenants are not emailed about a back-dated payment. Run by hand in the live database; not a migration.
do $$
declare r record; v_report uuid;
begin
  for r in
    select l.id lease_id, l.tenants_label, x.amt, (select lt.tenant_id from lease_tenants lt where lt.lease_id = l.id order by lt.tenant_id limit 1) tenant_id
      from (values ('12', 925.00::numeric), ('4', 2150.00::numeric)) x(unit, amt)
      join rental_units u on u.unit_number = x.unit
      join leases l on l.unit_id = u.id and l.status = 'active'
  loop
    insert into payment_reports (tenant_id, lease_id, method, amount, paid_on, payer_name, note, status)
    values (r.tenant_id, r.lease_id, 'bank_transfer', r.amt, date '2026-10-05', r.tenants_label,
            'October 2026 rent paid before the cut-over; posted by Stephen Henry 10/11/2026.', 'pending')
    returning id into v_report;
    perform payment_post(v_report, null, 'staff', 'Stephen Henry');
  end loop;
  delete from email_outbox where kind = 'receipt' and created_at >= now();
end $$;
