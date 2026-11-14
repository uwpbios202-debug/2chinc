-- Land contract version of the rent cycle (Wisconsin).
--
-- Confirmed timeline:
--   1st                    installment due (posted by billing_post_month)
--   1st - 3 days           payment reminder (same as tenants)
--   due + 10 days (11th)   payment default under the contract ("default ... which
--                          continues for a period of 10 days following the due date");
--                          Notice of Default and Right to Cure prepared for the agent
--                          to sign and mail, and emailed to the purchasers. Cure period
--                          30 days (the vendor's 2025 notice practice).
--   cure deadline          if not cured: staff alert to decide; purchasers told what
--                          happens: the vendor may accelerate the balance and file for
--                          strict foreclosure in Milwaukee County Circuit Court; the
--                          court sets a redemption period of at least 7 working days
--                          (Wis. Stat. 846.30); the judgment is final only after an
--                          order confirming no redemption.
-- Other obligations (taxes, insurance): default 10 days after written notice.

insert into portal_settings (key, value) values
  ('lc_default_days', '10'),
  ('lc_cure_days', '30'),
  ('lc_foreclosure_text', 'If the default is not cured, the Vendor may declare the full unpaid balance due and ask the Milwaukee County Circuit Court for a judgment of strict foreclosure. If the court grants it, the court sets a redemption period of at least 7 working days (Wis. Stat. § 846.30) in which you can still pay the full amount owed. If you do not, the court confirms the foreclosure, your interest in the property ends, and payments already made can be kept by the Vendor as provided in the land contract.')
on conflict (key) do nothing;

alter table notices add column if not exists land_contract_id uuid references land_contracts(id);

insert into letter_templates (legacy_id, recipient, name, subject, description, html, fields) values (
  'lc-default-notice', 'Land contract purchaser', 'Land Contract — Notice of Default and Right to Cure', 'Default Notice — Land Contract',
  'Formal written notice of payment default under a Wisconsin land contract, with the amount to cure and the cure deadline.',
  '<p style="text-align: center"><strong>DEFAULT NOTICE — LAND CONTRACT</strong></p>
<p style="text-align: center">NOTICE OF DEFAULT AND RIGHT TO CURE</p>
<p>Date: [[Current_Date]]</p>
<p>From: [[Vendor_Name]] (Vendor/Seller), [[Vendor_Address]]</p>
<p>To: [[Purchasers]] (Purchasers/Buyers)</p>
<p>Property: [[Property_Address]] · Parcel [[Parcel_PIN]] · Milwaukee County, Wisconsin</p>
<p>Land contract dated [[Contract_Date]], recorded [[Recorded_On]] as [[Recorded_Document]].</p>
<p>This is formal written notice that you are in default under the land contract. The payment due on [[Due_Date]] was not received within [[Default_Days]] days after its due date, as the contract requires.</p>
<p><strong>Amount required to cure the default</strong></p>
<p>Past-due installments: [[Past_Due_Installments]]</p>
<p>Late fees recorded on your account: [[Late_Fees]]</p>
<p>Total amount due to cure: [[Total_To_Cure]]</p>
<p>Under the contract, interest accrues at [[Default_Interest_Rate]] per year on amounts in default from the date of default.</p>
<p><strong>Right to cure.</strong> You may cure this default by paying the total amount due by [[Cure_Deadline]]. Pay through your resident portal, by Zelle, or to the Vendor''s payment address above.</p>
<p><strong>What happens next.</strong> [[Foreclosure_Text]]</p>
<p>Questions or a payment plan: call [[Sender_Phone]].</p>
<p>[[Vendor_Name]], by its agent</p>
<p>[[Sender_Signature]]</p>',
  array['Current_Date','Vendor_Name','Vendor_Address','Purchasers','Property_Address','Parcel_PIN','Contract_Date','Recorded_On','Recorded_Document','Due_Date','Default_Days','Past_Due_Installments','Late_Fees','Total_To_Cure','Default_Interest_Rate','Cure_Deadline','Foreclosure_Text','Sender_Phone','Sender_Signature']
) on conflict (legacy_id) do update set html = excluded.html, fields = excluded.fields, subject = excluded.subject, description = excluded.description;

-- Land contracts with past-due installments as of a date. Installments and
-- their payments are on the 'Rent Income' account (or none, for payments
-- verified in this system); late fees on 'Late Fee Income'. Lines before the
-- first installment date are the 2019-2020 rental period and are excluded.
create or replace function lc_unpaid(p_as_of date)
returns table (contract_id uuid, property text, past_due_installments numeric, late_fees numeric, total numeric, buyers jsonb, oldest_due date)
language sql stable security definer set search_path = public as $$
  with x as (
    select c.id, p.street, c.monthly_payment,
           greatest(coalesce(sum(e.amount) filter (where coalesce(e.legacy_gl, 'Rent Income') = 'Rent Income' and e.kind <> 'rent_due'
             and e.entry_date >= coalesce(c.first_payment_date, '1900-01-01') and e.entry_date <= p_as_of), 0), 0) as inst,
           greatest(coalesce(sum(e.amount) filter (where e.legacy_gl = 'Late Fee Income' and e.entry_date <= p_as_of), 0), 0) as fees
    from land_contracts c join rental_properties p on p.id = c.property_id left join land_contract_ledger e on e.contract_id = c.id
    where c.status = 'active' group by c.id, p.street, c.monthly_payment)
  select x.id, x.street, x.inst, x.fees, x.inst + x.fees,
         (select jsonb_agg(jsonb_build_object('name', t.name, 'email', t.email)) from land_contract_buyers b join tenants t on t.id = b.tenant_id where b.contract_id = x.id),
         (date_trunc('month', p_as_of) - make_interval(months => greatest(ceil(x.inst / nullif(x.monthly_payment, 0))::int - 1, 0)))::date
  from x where x.inst > 0;
$$;
revoke all on function lc_unpaid(date) from public, anon, authenticated;
grant execute on function lc_unpaid(date) to service_role;

create or replace function lc_notice_context(p_contract uuid, p_sender_email text, p_as_of date, p_cure_deadline date)
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
declare c land_contracts; p rental_properties; u record; v_sender text; v_phone text;
begin
  select * into c from land_contracts where id = p_contract;
  select * into p from rental_properties where id = c.property_id;
  select * into u from lc_unpaid(p_as_of) where contract_id = p_contract;
  select coalesce(a.name, s.name), coalesce(a.phone_mobile, s.phone_mobile) into v_sender, v_phone
    from condo_staff s left join lease_agents a on lower(a.email) = lower(s.email) where lower(s.email) = lower(p_sender_email);
  return jsonb_build_object(
    'Current_Date', to_char(p_as_of, 'FMMonth FMDD, YYYY'), 'Vendor_Name', coalesce(c.seller, ''), 'Vendor_Address', coalesce(c.vendor_payment_address, ''),
    'Purchasers', (select string_agg(t.name, ' & ' order by t.name) from land_contract_buyers b join tenants t on t.id = b.tenant_id where b.contract_id = c.id),
    'Property_Address', concat_ws(', ', p.street, p.city, p.state || ' ' || coalesce(p.zip, '')), 'Parcel_PIN', coalesce(c.parcel_pin, ''),
    'Contract_Date', to_char(c.contract_date, 'FMMonth FMDD, YYYY'), 'Recorded_On', coalesce(to_char(c.recorded_on, 'FMMonth FMDD, YYYY'), ''),
    'Recorded_Document', coalesce(c.recorded_document, ''), 'Due_Date', to_char(coalesce(u.oldest_due, date_trunc('month', p_as_of)::date), 'FMMonth FMDD, YYYY'),
    'Default_Days', coalesce(c.grace_days, 10)::text, 'Past_Due_Installments', to_char(coalesce(u.past_due_installments, 0), 'FM$999,990.00'),
    'Late_Fees', to_char(coalesce(u.late_fees, 0), 'FM$999,990.00'), 'Total_To_Cure', to_char(coalesce(u.total, 0), 'FM$999,990.00'),
    'Default_Interest_Rate', coalesce(trim(to_char(c.default_interest_rate * 100, 'FM990.0')) || '%', ''), 'Cure_Deadline', to_char(p_cure_deadline, 'FMMonth FMDD, YYYY'),
    'Foreclosure_Text', (select value from portal_settings where key = 'lc_foreclosure_text'),
    'Sender_Name', coalesce(v_sender, ''), 'Sender_Phone', coalesce(v_phone, (select value from portal_settings where key = 'office_phone')));
end;
$$;
revoke all on function lc_notice_context(uuid, text, date, date) from public, anon, authenticated;
grant execute on function lc_notice_context(uuid, text, date, date) to service_role;

-- Drafts list and resident access include land-contract notices.
create or replace function rent_cycle_staff_status()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not (condo_session_ok() and condo_is_staff()) then raise exception 'Staff two-step sign-in required' using errcode = '42501'; end if;
  return jsonb_build_object(
    'drafts', coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'subject', n.subject, 'batch', n.batch,
        'lease_label', coalesce(u.address || ' — ' || l.tenants_label, p.street || ' — ' || c.buyers_label), 'created', n.sent_at) order by n.sent_at)
      from notices n left join leases l on l.id = n.lease_id left join rental_units u on u.id = l.unit_id
      left join land_contracts c on c.id = n.land_contract_id left join rental_properties p on p.id = c.property_id where n.status = 'draft'), '[]'::jsonb),
    'runs', coalesce((select jsonb_agg(to_jsonb(r) order by r.ran_at desc) from (select * from rent_cycle_runs order by ran_at desc limit 30) r), '[]'::jsonb));
end;
$$;

create or replace function resident_can_read_notice(p_path text)
returns boolean
language sql stable security definer set search_path = public
as $$
  select condo_session_ok() and exists (
    select 1 from notices n where n.pdf_path = p_path and not n.voided and n.status = 'sent' and (
      exists (select 1 from lease_tenants lt where lt.lease_id = n.lease_id and lt.tenant_id in (select resident_me()))
      or exists (select 1 from land_contract_buyers b where b.contract_id = n.land_contract_id and b.tenant_id in (select resident_me()))));
$$;

create or replace function resident_notices()
returns jsonb
language plpgsql stable security definer set search_path = public
as $$
begin
  if not exists (select resident_me()) then raise exception 'Resident two-step sign-in required' using errcode = '42501'; end if;
  return coalesce((select jsonb_agg(jsonb_build_object('id', n.id, 'subject', n.subject, 'name', n.template_name, 'sent_at', n.sent_at, 'pdf_path', n.pdf_path) order by n.sent_at desc)
    from notices n where not n.voided and n.status = 'sent' and (
      exists (select 1 from lease_tenants lt where lt.lease_id = n.lease_id and lt.tenant_id in (select resident_me()))
      or exists (select 1 from land_contract_buyers b where b.contract_id = n.land_contract_id and b.tenant_id in (select resident_me())))), '[]'::jsonb);
end;
$$;

alter table notices add column if not exists cure_deadline date;
