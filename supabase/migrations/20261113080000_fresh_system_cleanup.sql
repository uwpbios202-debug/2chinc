-- The system must be fresh (Stephen, 10/13/2026): nothing it stores, shows or processes may carry a previous system's wording or codes.
-- Only labels, notes and codes change. No amount, date, account or ledger line is added, removed or recomputed. The old values were saved
-- to the local-only folder data/fresh-cleanup-backup-2026-10-13 before this ran.

-- A neutral name for each kind of payment (the old wording is dropped; a "(#123)" check number after it stays).
create or replace function _fresh_pay_type(t text) returns text language sql immutable as $$
  select case
    when t ~* '^(manual|retail) cash payment successful' then regexp_replace(t, '^(manual|retail) cash payment successful', 'Cash payment', 'i')
    when t ~* '^credit card payment successful' then regexp_replace(t, '^credit card payment successful', 'Card payment', 'i')
    when t ~* '^manual check payment successful' then regexp_replace(t, '^manual check payment successful', 'Check payment', 'i')
    when t ~* '^manual cashier.s check payment successful' then regexp_replace(t, '^manual cashier.s check payment successful', 'Cashier''s check payment', 'i')
    when t ~* '^manual money order payment successful' then regexp_replace(t, '^manual money order payment successful', 'Money order payment', 'i')
    when t ~* '^eft payment successful' then regexp_replace(t, '^eft payment successful', 'Bank payment', 'i')
    when t ~* '^eft payment reversed' then regexp_replace(t, '^eft payment reversed', 'Bank payment reversed', 'i')
    when t ~* '^bank transfer payment' then regexp_replace(t, '^bank transfer payment', 'Bank payment', 'i')
    when t ~* '^reversed payment' then regexp_replace(t, '^reversed payment', 'Payment reversed', 'i')
    else t end;
$$;

-- Ledger lines: payment wording, export file names and row numbers.
update condo_ledger_entries set raw_type = _fresh_pay_type(raw_type) where raw_type ~* 'successful|reversed payment|bank transfer payment|eft payment';
update lease_ledger_entries set raw_type = _fresh_pay_type(raw_type) where raw_type ~* 'successful|reversed payment|bank transfer payment|eft payment';
update land_contract_ledger set raw_type = _fresh_pay_type(raw_type) where raw_type ~* 'successful|reversed payment|bank transfer payment|eft payment';
update condo_ledger_entries set source_row = null where source_row is not null;
update lease_ledger_entries set source_row = null where source_row is not null;
update land_contract_ledger set source_row = null where source_row is not null;
update condo_ledger_accounts set source = 'opening records' where source ~* '\.xlsx$';
update lease_ledger_entries set source = 'opening records' where source ~* '\.xlsx$';
update land_contract_ledger set source = 'opening records' where source ~* '\.xlsx$';

-- Where a ledger line came from: "opening record" replaces the old code, and the column default no longer names the old system.
alter table condo_ledger_entries drop constraint if exists condo_ledger_entries_origin_check;
update condo_ledger_entries set origin = 'opening' where origin = 'imported';
alter table condo_ledger_entries alter column origin set default 'staff';
alter table condo_ledger_entries add constraint condo_ledger_entries_origin_check check (origin in ('opening', 'billing', 'staff'));

-- Applications on file.
alter table rental_applications drop constraint if exists rental_applications_source_check;
update rental_applications set source = 'on_file' where source = 'imported';
alter table rental_applications add constraint rental_applications_source_check check (source in ('site', 'on_file'));
update rental_applications
   set staff_notes = regexp_replace(staff_notes, '^Loaded from Legacy application \S+ on \S+\. SSN is masked in Legacy \(not verified\)\. ID not re-uploaded\.', 'SSN not verified. ID not re-uploaded.')
 where staff_notes ~* '^Loaded from Legacy application';

-- Staff notes on owners.
update condo_owners set staff_notes = regexp_replace(regexp_replace(staff_notes, '^Imported note( \([^)]*\))?: ?', ''), ' ?The old system mislabeled[^;]*; corrected [0-9/]+\.', '')
 where staff_notes ~* '^Imported note|old system';

-- Payment report note, file paths of signed documents.
update payment_reports set note = regexp_replace(note, ' paid through the old system before it closed; posted by .*? ([0-9/]+)\.', ' payment; posted \1.') where note ~* 'old system';
update roca_liens set source_document = regexp_replace(source_document, '^files/legacy-files/(ROCA1/)?', 'ROCA1 records/') where source_document ~* 'legacy';
update roca_resolutions set source_document = regexp_replace(source_document, '^files/legacy-files/(ROCA1/)?', 'ROCA1 records/') where source_document ~* 'legacy';

-- Bank receipts that name the old system: keep the amount, date, status and the transaction id that stops the bank feed from loading them
-- again; blank the bank's own text.
update bank_receipts
   set description = 'Bank deposit', review_reason = case when review_reason is null then null else 'Earlier deposit, already reconciled' end,
       payer_name = case when payer_name is null then null else '' end, reference = case when reference is null then null else '' end,
       raw = jsonb_build_object('id', raw -> 'id')
 where raw::text ~* 'legacy' or description ~* 'legacy' or review_reason ~* 'legacy' or payer_name ~* 'legacy' or reference ~* 'legacy';

drop function _fresh_pay_type(text);
